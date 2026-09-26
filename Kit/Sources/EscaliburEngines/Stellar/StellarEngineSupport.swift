import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// O que os motores da Stellar tem em comum: a conta que assina, os ativos da lista
/// curada, o memo, a taxa e as frases de erro.
enum StellarEngineSupport {
    // MARK: Conta

    /// A conta que assina, a partir da conta derivada: caminho SEP-0005 e a chave que da
    /// o proprio endereco.
    static func source(_ account: DerivedAccount) throws -> StellarSource {
        guard account.chainID == Chain.stellar.id, let source = try? StellarSource(path: account.path, publicKey: account.publicKey),
              source.account.address == account.address
        else { throw SendEngineError.message(NetworkFailureText.wrongAccount) }
        return source
    }

    // MARK: Ativos

    /// Os ativos emitidos da lista curada (`TokenRegistry`), com codigo e emissor.
    static var curated: [(asset: Asset, stellar: StellarAsset)] {
        TokenRegistry.tokens.compactMap { asset in
            guard asset.chainID == Chain.stellar.id, case .issued(let code, let issuer) = asset.kind,
                  let stellar = try? StellarAsset(code: code, issuer: issuer)
            else { return nil }
            return (asset, stellar)
        }
    }

    static var allowedAssets: [StellarAsset] { curated.map(\.stellar) }

    /// O ativo da Stellar para um `Asset` da carteira: o XLM ou um da lista curada.
    static func stellar(_ asset: Asset) throws -> StellarAsset {
        guard asset.chainID == Chain.stellar.id else { throw SendEngineError.message("Este ativo não é da rede Stellar.") }
        switch asset.kind {
        case .native:
            return .native
        case .issued(let code, let issuer):
            guard let match = curated.first(where: { $0.stellar.code == code && $0.stellar.issuer?.address == issuer }) else {
                throw SendEngineError.message("\(asset.symbol) deste emissor não está na lista de ativos da carteira.")
            }
            return match.stellar
        case .token:
            throw SendEngineError.message("Este ativo não é da rede Stellar.")
        }
    }

    /// O `Asset` da carteira para uma referencia do historico; nil fora da lista.
    static func asset(_ reference: ChainActivity.AssetRef) -> Asset? {
        switch reference {
        case .native:
            return Asset.native(.stellar)
        case .issued(let code, let issuer):
            return curated.first { $0.stellar.code == code && $0.stellar.issuer?.address == issuer }?.asset
        }
    }

    // MARK: Memo

    /// O memo a partir do que o dono digitou.
    ///
    /// So digitos, sem zero a esquerda e cabendo em 64 bits: memo ID, que e o que as
    /// corretoras de Stellar usam para identificar deposito. Qualquer outro texto: memo
    /// de texto, ate 28 bytes, byte a byte como foi digitado. "007" fica texto, porque o
    /// ID 7 perderia os zeros que a corretora mostrou. A revisao mostra o tipo escolhido.
    static func memo(_ tag: String?) throws -> StellarMemo {
        guard let tag, !tag.isEmpty else { return .none }
        let digits = tag.utf8.allSatisfy { (0x30...0x39).contains($0) }
        if digits, tag == "0" || !tag.hasPrefix("0"), let id = UInt64(tag) { return .id(id) }
        do {
            return try StellarMemo.fromText(tag)
        } catch {
            throw SendEngineError.message("O memo de texto cabe até \(StellarMemo.maxTextBytes) caracteres. Confira com quem pediu o memo.")
        }
    }

    // MARK: Taxa e reserva

    /// A taxa por operacao que `StellarPlanner` usa: max(100, taxa base, p90 cobrado),
    /// limitada ao teto. Repetida aqui para dizer o maximo sem montar plano; o teste
    /// confere contra a taxa gravada no plano. nil quando a taxa base passa do teto, e o
    /// planejador recusaria.
    static func feePerOperation(_ network: StellarNetworkState) -> BigUInt? {
        guard network.baseFee <= StellarLimits.maxFeePerOperation else { return nil }
        return min(max(StellarLimits.minFeePerOperation, network.baseFee, network.feeChargedP90), StellarLimits.maxFeePerOperation)
    }

    /// O minimo que cria uma conta: duas reservas de base, como em
    /// `StellarPlanner.planSendNative` (hoje 1 XLM).
    static func activationMinimum(_ network: StellarNetworkState) throws -> BigUInt {
        guard let reserve = network.baseReserve.uint64, StellarLimits.baseReserveRange.contains(reserve) else {
            throw StellarPlanError.suspiciousNetworkState
        }
        return network.baseReserve * BigUInt(2)
    }

    static func xlm(_ stroops: BigUInt) -> String {
        EngineFormat.amount(stroops, decimals: StellarAmount.decimals, symbol: "XLM")
    }

    // MARK: Transmissao

    /// O hash calculado aqui do envelope assinado, com a passphrase compilada.
    static func localHash(_ signed: SignedTransaction) throws -> String {
        guard signed.chainID == Chain.stellar.id, Data(signed.raw).base64EncodedString() == signed.encoded,
              let envelope = try? StellarEnvelope.decode(signed.raw), envelope.xdr == signed.raw
        else { throw SendEngineError.message(NetworkFailureText.inconsistent) }
        let hash = Hex.encode(envelope.hash)
        guard hash == signed.id.lowercased() else { throw SendEngineError.message(NetworkFailureText.inconsistent) }
        return hash
    }

    /// Transmite pela Horizon e devolve o hash calculado aqui.
    ///
    /// A Horizon so responde quando o ledger fecha. Recusa depois disso pode ser de uma
    /// transacao que entrou e falhou, e ai a taxa foi cobrada; a frase diz isso em vez de
    /// prometer que nada saiu.
    static func broadcast(_ signed: SignedTransaction, reader: StellarReader) async throws -> String {
        let hash = try localHash(signed)
        do {
            let submission = try await reader.broadcast(signed)
            guard submission.hash == hash else { throw ChainReaderError.signedTransactionInconsistent }
        } catch ChainReaderError.signedTransactionInconsistent {
            throw SendEngineError.message(NetworkFailureText.inconsistent)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw SendEngineError.message(
                "A rede não confirmou a transação. Se ela entrou num ledger e falhou, só a taxa foi cobrada. Confira na Atividade antes de tentar de novo."
            )
        }
        return hash
    }

    // MARK: Erros

    /// A frase de um plano recusado. Quase todas vem do proprio planejador; as duas que
    /// la carregam valores ganham aqui uma frase sem numero.
    static func text(_ error: StellarPlanError) -> String {
        switch error {
        case .insufficientBalance(_, _, let asset):
            return asset.isNative
                ? "XLM livre insuficiente para este valor mais a taxa da rede. Parte do saldo fica reservada pela rede."
                : "Saldo de \(asset.code) insuficiente, ou falta XLM livre para a taxa da rede."
        case .belowAccountMinimum:
            return "A conta de destino ainda não existe. O primeiro envio precisa ser do mínimo que cria a conta."
        default:
            return error.reason
        }
    }

    static func translate(_ error: Error) -> Error {
        if let planError = error as? StellarPlanError { return SendEngineError.message(text(planError)) }
        return NetworkFailureText.error(error)
    }

    static let accountMissing = "Esta conta ainda não existe na Stellar. Ela passa a existir quando receber o primeiro XLM."
}
