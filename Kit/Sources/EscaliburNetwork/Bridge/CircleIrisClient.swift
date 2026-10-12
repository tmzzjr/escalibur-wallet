import EscaliburChains
import EscaliburCore
import Foundation

// A Iris, API publica da Circle para o CCTP V2 (`iris-api.circle.com`), sem chave.
// Formato conferido ao vivo em 12/10/2026 e na documentacao (developers.circle.com,
// "Get USDC transfer fees" e "Transfer USDC with the Forwarding Service").
//
// - `GET /v2/burn/USDC/fees/{origem}/{destino}?forward=true`: para cada limiar de
//   finalidade (1000 rapida, 2000 padrao), a taxa do protocolo em bps (`minimumFee`, pode
//   ter casas: 1.3) e a taxa de encaminhamento em unidades de USDC (`forwardFee` low,
//   med, high).
// - `GET /v2/fastBurn/USDC/allowance`: quanto ainda cabe em transferencia rapida agora.
// - `GET /v2/messages/{origem}?transactionHash=`: a mensagem e a attestation da queima,
//   e o estado do encaminhamento (`forwardState`, `forwardTxHash`).
//
// Nada daqui decide para onde vai o dinheiro. A taxa so entra como teto (`maxFee`) que o
// dono ve e assina; a mensagem e conferida campo a campo (CCTPMessage.check) antes de o
// app mostrar "chegou" ou de resgatar por conta propria.

public enum CircleIrisError: Error, Equatable, Sendable {
    case badResponse(String)
    case notFound
}

/// O estado de uma queima na Iris.
public struct CCTPAttested: Sendable, Equatable {
    public enum Forward: Sendable, Equatable {
        case pending
        case complete(txHash: String)
        case failed
    }

    /// Mensagem e attestation prontas. Antes disso, a Circle ainda espera a finalidade.
    public let complete: Bool
    public let message: CCTPMessage?
    public let messageBytes: [UInt8]
    public let attestation: [UInt8]
    public let forward: Forward
}

public struct CircleIrisClient: Sendable {
    let client: HTTPClient
    let base: URL

    public init(client: HTTPClient = .shared, base: URL = Endpoints.bridge["circle"]!.baseURL) {
        self.client = client
        self.base = base
    }

    // MARK: Taxas

    struct FeeEntry: Decodable {
        struct Forward: Decodable { let low, med, high: Decimal }
        let finalityThreshold: Int
        let minimumFee: Decimal
        let forwardFee: Forward?
    }

    public func fees(sourceDomain: UInt32, destinationDomain: UInt32) async throws -> CCTPFees {
        var components = URLComponents(url: base.appendingPathComponent("v2/burn/USDC/fees/\(sourceDomain)/\(destinationDomain)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "forward", value: "true")]
        return try Self.fees(try await client.get(components.url!, timeout: 8))
    }

    static func fees(_ data: Data) throws -> CCTPFees {
        let entries: [FeeEntry]
        do { entries = try JSONDecoder().decode([FeeEntry].self, from: data) } catch { throw CircleIrisError.badResponse("taxas") }
        func level(_ threshold: Int) throws -> CCTPFees.Level? {
            guard let entry = entries.first(where: { $0.finalityThreshold == threshold }) else { return nil }
            // Encaminhamento e obrigatorio: sem a taxa dele, a rota nao serve.
            guard let forward = entry.forwardFee,
                  let bps = TradeDecimal(NSDecimalNumber(decimal: entry.minimumFee).stringValue),
                  let high = BigUInt(decimal: NSDecimalNumber(decimal: forward.high).stringValue)
            else { throw CircleIrisError.badResponse("taxas") }
            // 1% de taxa do protocolo seria 100 bps: muito acima de qualquer valor real
            // (1 a 1,4 bps vistos). Teto contra resposta adulterada.
            guard bps.mantissa <= BigUInt(100) * BigUInt.power(of: 10, bps.scale) else { throw CircleIrisError.badResponse("taxa alta") }
            return .init(protocolBps: bps, forwardFee: high)
        }
        return CCTPFees(fast: try level(Int(CCTPCalldata.fastFinality)), standard: try level(Int(CCTPCalldata.standardFinality)))
    }

    /// Quanto ainda cabe em transferencia rapida, em unidades de USDC.
    public func fastAllowance() async throws -> BigUInt {
        struct Response: Decodable { let allowance: Decimal }
        let data = try await client.get(base.appendingPathComponent("v2/fastBurn/USDC/allowance"), timeout: 8)
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let whole = TradeDecimal(NSDecimalNumber(decimal: response.allowance).stringValue)
        else { throw CircleIrisError.badResponse("limite rápido") }
        // Para baixo: o limite nunca parece maior do que e.
        return whole.scale <= 6
            ? whole.mantissa * BigUInt.power(of: 10, 6 - whole.scale)
            : whole.mantissa / BigUInt.power(of: 10, whole.scale - 6)
    }

    // MARK: Mensagem

    struct MessagesResponse: Decodable {
        struct Message: Decodable {
            let message: String?
            let attestation: String?
            let status: String?
            let cctpVersion: Int?
            let forwardState: String?
            let forwardTxHash: String?
        }
        let messages: [Message]
    }

    public func attested(sourceDomain: UInt32, burnTxHash: String) async throws -> CCTPAttested {
        var components = URLComponents(url: base.appendingPathComponent("v2/messages/\(sourceDomain)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "transactionHash", value: burnTxHash)]
        let data: Data
        do {
            data = try await client.get(components.url!, timeout: 8)
        } catch HTTPClient.Failure.status(404) {
            throw CircleIrisError.notFound
        }
        return try Self.attested(data)
    }

    static func attested(_ data: Data) throws -> CCTPAttested {
        let response: MessagesResponse
        do { response = try JSONDecoder().decode(MessagesResponse.self, from: data) } catch { throw CircleIrisError.badResponse("mensagem") }
        // Uma queima da carteira gera uma mensagem. Mais de uma e transacao que nao e nossa.
        guard response.messages.count == 1, let entry = response.messages.first else { throw CircleIrisError.badResponse("mensagens") }
        guard entry.cctpVersion == nil || entry.cctpVersion == 2 else { throw CircleIrisError.badResponse("versão") }
        let complete = entry.status == "complete"
        func bytes(_ text: String?) -> [UInt8]? {
            guard let text, text.hasPrefix("0x") else { return nil }
            return Hex.decode(String(text.dropFirst(2)))
        }
        let messageBytes = bytes(entry.message) ?? []
        let attestation = bytes(entry.attestation) ?? []
        let message = complete ? try? CCTPMessage(messageBytes) : nil
        if complete, message == nil || attestation.isEmpty { throw CircleIrisError.badResponse("mensagem") }
        let forward: CCTPAttested.Forward
        switch entry.forwardState?.uppercased() {
        case "COMPLETE":
            guard let hash = entry.forwardTxHash, hash.hasPrefix("0x"), hash.count == 66, Hex.decode(String(hash.dropFirst(2))) != nil
            else { throw CircleIrisError.badResponse("encaminhamento") }
            forward = .complete(txHash: hash.lowercased())
        case "FAILED": forward = .failed
        default: forward = .pending
        }
        return CCTPAttested(complete: complete, message: message, messageBytes: messageBytes, attestation: attestation, forward: forward)
    }
}
