import EscaliburChains
import EscaliburCore
import Foundation

// A API publica do Across (`app.across.to/api`), sem chave. Formato conferido ao vivo em
// 12/10/2026 (docs.across.to, "Suggested Fees" e "Deposit Status").
//
// - `GET /suggested-fees`: o `outputAmount` (valor menos a taxa do relayer), o
//   `timestamp` que vai como `quoteTimestamp`, o `fillDeadline`, o relayer exclusivo e o
//   prazo dele, os limites da rota e o SpokePool de cada lado.
// - `GET /deposit/status`: se o deposito foi entregue (`filled`), esta esperando, venceu
//   (`expired`) ou voltou (`refunded`), com a transacao de cada passo.
//
// A API nao monta calldata para o app. O que ela sugere e conferido contra o pedido e a
// lista compilada: tokens, redes, SpokePool, taxa ate o teto, prazos dentro da janela.

public enum AcrossClientError: Error, Equatable, Sendable {
    case badResponse(String)
    case mismatch(String)
    case amountTooLow
}

/// O que o Across conta de um deposito.
public struct AcrossDepositStatus: Sendable, Equatable {
    public enum State: String, Sendable { case pending, filled, expired, refunded }
    public let state: State
    public let fillTxHash: String?
    public let refundTxHash: String?
}

public struct AcrossClient: Sendable {
    let client: HTTPClient
    let base: URL

    public init(client: HTTPClient = .shared, base: URL = Endpoints.bridge["across"]!.baseURL) {
        self.client = client
        self.base = base
    }

    struct FeesResponse: Decodable {
        struct Limits: Decodable { let minDeposit, maxDeposit, maxDepositInstant: String }
        struct Token: Decodable { let address: String; let chainId: UInt64; let decimals: Int? }
        let outputAmount: String
        let timestamp: String
        let fillDeadline: String
        let exclusiveRelayer: String
        let exclusivityDeadline: UInt64
        let estimatedFillTimeSec: Int?
        let isAmountTooLow: Bool
        let spokePoolAddress: String
        let destinationSpokePoolAddress: String
        let limits: Limits
        let inputToken: Token
        let outputToken: Token
    }

    public func quote(
        inputToken: EVMAddress, outputToken: EVMAddress, originChainID: UInt64, destinationChainID: UInt64, amount: BigUInt
    ) async throws -> AcrossQuote {
        var components = URLComponents(url: base.appendingPathComponent("suggested-fees"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "inputToken", value: TradeWire.lower(inputToken)),
            URLQueryItem(name: "outputToken", value: TradeWire.lower(outputToken)),
            URLQueryItem(name: "originChainId", value: String(originChainID)),
            URLQueryItem(name: "destinationChainId", value: String(destinationChainID)),
            // Sem depositante nem destinatario: a API nao precisa saber quem pergunta
            // (docs/privacidade.md). O app poe a propria conta na calldata que ele monta.
            URLQueryItem(name: "amount", value: amount.decimalString),
            // O USDC e o USDT da BNB tem 18 casas, e os das outras redes 6: sem isto a API
            // recusa a rota (guia de migracao da BNB do Across). As casas de cada lado sao as
            // compiladas no app (`BridgeAsset.decimals(on:)`), e o validador compara e cobra a
            // taxa na unidade da origem; o `outputAmount` vem na unidade do destino.
            URLQueryItem(name: "allowUnmatchedDecimals", value: "true"),
        ]
        let data = try await client.get(components.url!, timeout: 10)
        return try Self.quote(data, inputToken: inputToken, outputToken: outputToken, originChainID: originChainID,
                              destinationChainID: destinationChainID, amount: amount, now: Date())
    }

    static func address(_ text: String) -> EVMAddress? {
        guard text.hasPrefix("0x"), let bytes = Hex.decode(String(text.dropFirst(2))) else { return nil }
        return EVMAddress(bytes: bytes)
    }

    /// Confere a sugestao contra o pedido. Os prazos sao conferidos contra o relogio do
    /// aparelho com folga; o contrato confere de novo contra o do bloco.
    static func quote(
        _ data: Data, inputToken: EVMAddress, outputToken: EVMAddress, originChainID: UInt64, destinationChainID: UInt64,
        amount: BigUInt, now: Date
    ) throws -> AcrossQuote {
        let response: FeesResponse
        do { response = try JSONDecoder().decode(FeesResponse.self, from: data) } catch { throw AcrossClientError.badResponse("taxa") }
        guard !response.isAmountTooLow else { throw AcrossClientError.amountTooLow }
        guard address(response.inputToken.address) == inputToken, response.inputToken.chainId == originChainID,
              address(response.outputToken.address) == outputToken, response.outputToken.chainId == destinationChainID
        else { throw AcrossClientError.mismatch("tokens") }
        // As casas de cada lado, como a API diz (o validador exige as compiladas): o que chega
        // vem nas casas do destino, e so se compara ao que sai na unidade da origem.
        let inputDecimals = response.inputToken.decimals, outputDecimals = response.outputToken.decimals
        guard let output = BigUInt(decimal: response.outputAmount), !output.isZero,
              Self.comparable(output, from: outputDecimals, to: inputDecimals) <= amount,
              outputDecimals.flatMap { out in inputDecimals.map { BridgeAsset.fits(output, outputDecimals: out, within: amount, inputDecimals: $0) } } ?? true,
              let timestamp = UInt32(response.timestamp), let deadline = UInt32(response.fillDeadline),
              let minDeposit = BigUInt(decimal: response.limits.minDeposit),
              let maxDeposit = BigUInt(decimal: response.limits.maxDeposit),
              let maxInstant = BigUInt(decimal: response.limits.maxDepositInstant),
              let spoke = address(response.spokePoolAddress), let destinationSpoke = address(response.destinationSpokePoolAddress)
        else { throw AcrossClientError.badResponse("taxa") }
        let clock = UInt32(now.timeIntervalSince1970)
        // A cotacao e de agora (o contrato aceita uma janela; 10 min e folga para relogio
        // torto), e o prazo de entrega fica entre 10 min e 1 dia.
        guard timestamp <= clock + 120, clock < timestamp + 600 else { throw AcrossClientError.mismatch("horário da cotação") }
        guard deadline >= clock + 600, deadline <= clock + 86_400 else { throw AcrossClientError.mismatch("prazo de entrega") }
        let relayer = address(response.exclusiveRelayer)
        guard let relayer else { throw AcrossClientError.badResponse("relayer") }
        let exclusive = relayer.isZero ? nil : relayer
        let exclusivity = UInt32(clamping: response.exclusivityDeadline)
        // Exclusividade: so com relayer, e terminando antes do prazo de entrega.
        guard (exclusive == nil) == (exclusivity == 0), exclusivity <= deadline else { throw AcrossClientError.mismatch("exclusividade") }
        return AcrossQuote(
            inputAmount: amount, outputAmount: output, quoteTimestamp: timestamp, fillDeadline: deadline, exclusiveRelayer: exclusive,
            exclusivityDeadline: exclusivity, estimatedFillSeconds: response.estimatedFillTimeSec, maxDeposit: maxDeposit,
            maxDepositInstant: maxInstant, minDeposit: minDeposit, spokePool: spoke, destinationSpokePool: destinationSpoke,
            inputDecimals: inputDecimals, outputDecimals: outputDecimals
        )
    }

    /// O valor do destino na unidade da origem; sem as casas na resposta, o valor como veio
    /// (e a comparacao so passa com casas iguais).
    static func comparable(_ output: BigUInt, from outputDecimals: Int?, to inputDecimals: Int?) -> BigUInt {
        guard let outputDecimals, let inputDecimals, (0...36).contains(outputDecimals), (0...36).contains(inputDecimals) else { return output }
        return BridgeAsset.rescale(output, from: outputDecimals, to: inputDecimals)
    }

    // MARK: Andamento

    struct StatusResponse: Decodable {
        let status: String
        let fillTx: String?
        let depositRefundTxHash: String?
    }

    public func status(originChainID: UInt64, depositTxHash: String) async throws -> AcrossDepositStatus {
        var components = URLComponents(url: base.appendingPathComponent("deposit/status"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "originChainId", value: String(originChainID)),
            URLQueryItem(name: "depositTxHash", value: depositTxHash),
        ]
        return try Self.status(try await client.get(components.url!, timeout: 8))
    }

    static func status(_ data: Data) throws -> AcrossDepositStatus {
        guard let response = try? JSONDecoder().decode(StatusResponse.self, from: data) else { throw AcrossClientError.badResponse("andamento") }
        let state = AcrossDepositStatus.State(rawValue: response.status) ?? .pending
        func hash(_ text: String?) -> String? {
            guard let text, text.hasPrefix("0x"), text.count == 66, Hex.decode(String(text.dropFirst(2))) != nil else { return nil }
            return text.lowercased()
        }
        return AcrossDepositStatus(state: state, fillTxHash: hash(response.fillTx), refundTxHash: hash(response.depositRefundTxHash))
    }
}
