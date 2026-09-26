import EscaliburChains
import EscaliburCore
import Foundation

// O que os tres motores da Solana tem em comum: a conta do dono conferida, o ativo
// resolvido contra a lista compilada, a transacao assinada relida dos bytes e o
// registro, so em memoria, do que foi planejado e transmitido nesta sessao.

// MARK: Rede e conta do dono

enum SolanaEngineGuard {
    /// Os motores da Solana so atendem a rede Solana; o registro ja garante, e cada
    /// entrada confere de novo.
    static func chain(_ chain: Chain) throws {
        guard chain == .solana else { throw SolanaEngineProblem.wrongChain }
    }

    /// A conta Solana do dono, conferida: a chave publica guardada nos metadados gera
    /// exatamente o endereco guardado. Metadado corrompido ou de outra rede nunca vira
    /// plano, porque o plano seria de outra conta.
    static func owner(_ account: DerivedAccount) throws -> SolanaOwner {
        guard account.chainID == Chain.solana.id, let key = try? SolanaPublicKey(bytes: account.publicKey), key.base58 == account.address else {
            throw SolanaEngineProblem.accountMismatch
        }
        return SolanaOwner(path: account.path, publicKey: key)
    }

    /// O destino digitado, como chave. Programas da lista e mints da lista sao
    /// recusados aqui, sem consultar a rede: o valor ficaria preso numa conta que nao
    /// devolve nada.
    static func destination(_ text: String) throws -> SolanaPublicKey {
        guard case .success(let destination) = Address.validate(text, for: .solana),
              let key = try? SolanaPublicKey(base58: destination.address)
        else { throw SolanaEngineProblem.invalidDestination }
        if SolanaProgram(id: key) != nil { throw SolanaEngineProblem.destinationIsProgram }
        let listedMint = TokenRegistry.tokens.contains { $0.chainID == Chain.solana.id && $0.kind == .token(contract: key.base58) }
        if listedMint || key == SolanaWrappedSOL.mint { throw SolanaEngineProblem.destinationIsMint }
        return key
    }
}

// MARK: Ativo

/// Um ativo da Solana que os motores aceitam: SOL ou um token da lista compilada.
enum SolanaEngineAsset: Equatable {
    case sol
    /// Token da `TokenRegistry`, com o mint compilado. Mint que nao esta na lista,
    /// ou esta com outras casas, nao chega aqui.
    case token(mint: SolanaPublicKey, listed: Asset)

    init(_ asset: Asset) throws {
        guard asset.chainID == Chain.solana.id else { throw SolanaEngineProblem.assetNotSupported }
        switch asset.kind {
        case .native:
            guard asset.decimals == Chain.solana.nativeDecimals else { throw SolanaEngineProblem.assetNotSupported }
            self = .sol
        case .token(let contract):
            // Comparacao exata do texto do mint: base58 distingue maiusculas, e a busca
            // da lista (`TokenRegistry.find`) ignora a caixa por causa dos contratos EVM.
            guard let listed = TokenRegistry.tokens.first(where: { $0.chainID == asset.chainID && $0.kind == asset.kind }),
                  listed.decimals == asset.decimals, let mint = try? SolanaPublicKey(base58: contract)
            else { throw SolanaEngineProblem.assetNotSupported }
            self = .token(mint: mint, listed: listed)
        case .issued:
            throw SolanaEngineProblem.assetNotSupported
        }
    }

    /// O mint na troca: SOL passa pelo SOL embrulhado, como a Jupiter espera.
    var swapMint: SolanaPublicKey {
        switch self {
        case .sol: return SolanaWrappedSOL.mint
        case .token(let mint, _): return mint
        }
    }

    var symbol: String {
        switch self {
        case .sol: return Chain.solana.nativeSymbol
        case .token(_, let listed): return listed.symbol
        }
    }

    var decimals: Int {
        switch self {
        case .sol: return Chain.solana.nativeDecimals
        case .token(_, let listed): return listed.decimals
        }
    }
}

// MARK: Recusas proprias dos motores

/// Recusas que nascem nos motores, antes ou depois do planejador. A tela recebe
/// cada uma ja traduzida por `SolanaEngineMessages`.
enum SolanaEngineProblem: Error, Equatable, Sendable, CaseIterable {
    case wrongChain
    case accountMismatch
    case assetNotSupported
    /// Token cujo mint, lido da rede, nao bate com a lista compilada (casas).
    case tokenNotVerified
    case invalidDestination
    /// A Solana nao tem tag nem memo de destino neste contrato.
    case tagNotSupported
    case destinationIsTokenAccount
    case destinationIsMint
    case destinationIsProgram
    /// O plano que voltou nao e o que foi pedido (rede, carteira, destino, conta).
    case planMismatch
    case quoteMismatch
    case quoteExpired
    case slippageOutOfRange
    case amountOutOfRange
    case priceImpactTooHigh
    case nothingToSpend
    case limitOrdersUnavailable
    case signedMismatch
}

// MARK: Transacao assinada

/// A transacao assinada, relida dos proprios bytes antes de sair do aparelho: uma
/// assinatura, valida para o pagador, e o id calculado aqui. O id que a tela mostra
/// e que o acompanhamento consulta sai daqui, nunca de resposta de provedor.
struct SolanaSignedEnvelope {
    let id: String
    let message: SolanaMessage
    let messageBytes: [UInt8]
    let signer: SolanaPublicKey

    init(_ signed: SignedTransaction) throws {
        guard signed.chainID == Chain.solana.id else { throw SolanaEngineProblem.signedMismatch }
        // O base64 que vai para o provedor tem de ser exatamente os bytes assinados.
        guard Data(base64Encoded: signed.encoded).map(Array.init) == signed.raw else { throw SolanaEngineProblem.signedMismatch }
        let wire: SolanaWireTransaction
        do { wire = try SolanaWireTransaction(bytes: signed.raw) } catch { throw SolanaEngineProblem.signedMismatch }
        // Esta carteira so monta transacao com um signatario, o dono pagando a taxa.
        guard wire.signatures.count == 1, wire.message.header.numRequiredSignatures == 1, let signer = wire.message.staticAccountKeys.first,
              wire.verifySignatures(), let id = wire.id, id == signed.id
        else { throw SolanaEngineProblem.signedMismatch }
        self.id = id
        self.message = wire.message
        self.messageBytes = wire.messageBytes
        self.signer = signer
    }
}

// MARK: Registro da sessao

/// O que este aparelho planejou e transmitiu na Solana nesta sessao, so em memoria.
///
/// Guarda duas coisas: o `lastValidBlockHeight` de cada blockhash que entrou num
/// plano (a transacao assinada nao carrega esse numero, e o acompanhamento precisa
/// dele para dizer "venceu" com certeza), e os bytes assinados de cada transacao
/// transmitida, para reenviar exatamente os mesmos bytes enquanto a rede nao a ve.
/// Nada vai para disco; ao fechar o app o acompanhamento recomeca sem prazo, e sem
/// prazo o motor nunca declara uma transacao vencida.
actor SolanaTransferBook {
    static let shared = SolanaTransferBook()

    /// Planos e transmissoes lembrados. Um envio vive menos de dois minutos; 32 cobre
    /// com folga uma sessao de uso sem crescer sem limite.
    let capacity: Int
    /// Intervalo minimo entre dois reenvios dos mesmos bytes.
    let resendInterval: TimeInterval

    init(capacity: Int = 32, resendInterval: TimeInterval = 2) {
        self.capacity = capacity
        self.resendInterval = resendInterval
    }

    struct Transfer: Sendable {
        let signed: SignedTransaction
        let lastValidBlockHeight: UInt64?
        var lastSent: Date
    }

    private var validity: [SolanaBlockhash: UInt64] = [:]
    private var validityOrder: [SolanaBlockhash] = []
    private var transfers: [String: Transfer] = [:]
    private var transferOrder: [String] = []

    /// Lembra o prazo de cada transacao do plano. Duas leituras do mesmo blockhash
    /// com prazos diferentes ficam com o maior: dizer "venceu" cedo demais levaria o
    /// dono a enviar de novo com a primeira ainda podendo entrar.
    func planned(_ plan: SigningPlan) {
        for case let transaction as SolanaTransaction in plan.transactions {
            let blockhash = transaction.message.recentBlockhash
            if let known = validity[blockhash] {
                validity[blockhash] = max(known, transaction.lastValidBlockHeight)
            } else {
                validity[blockhash] = transaction.lastValidBlockHeight
                validityOrder.append(blockhash)
                if validityOrder.count > capacity { validity[validityOrder.removeFirst()] = nil }
            }
        }
    }

    /// Registra uma transmissao aceita. O prazo vem do plano que a montou; sem ele,
    /// o acompanhamento nunca declara vencimento.
    func sent(_ envelope: SolanaSignedEnvelope, signed: SignedTransaction, lastValidBlockHeight: UInt64? = nil, at date: Date = .now) {
        let deadline = lastValidBlockHeight ?? validity[envelope.message.recentBlockhash]
        if transfers[envelope.id] == nil {
            transferOrder.append(envelope.id)
            if transferOrder.count > capacity { transfers[transferOrder.removeFirst()] = nil }
        }
        transfers[envelope.id] = Transfer(signed: signed, lastValidBlockHeight: deadline, lastSent: date)
    }

    func transfer(_ id: String) -> Transfer? { transfers[id] }

    /// Reserva a vez de reenviar: devolve os bytes se o ultimo envio foi ha mais de
    /// `resendInterval`, e marca agora como o ultimo.
    func claimResend(_ id: String, now: Date = .now) -> SignedTransaction? {
        guard var transfer = transfers[id], now.timeIntervalSince(transfer.lastSent) >= resendInterval else { return nil }
        transfer.lastSent = now
        transfers[id] = transfer
        return transfer.signed
    }

    func finished(_ id: String) {
        transfers[id] = nil
        transferOrder.removeAll { $0 == id }
    }
}

// MARK: Taxa

enum SolanaFeeCeiling {
    /// Teto da taxa de rede de uma transacao de uma assinatura com `units` de CU: a
    /// taxa base mais a prioridade sugerida, limitada pelos tetos compilados de
    /// `SolanaLimits`. O planejador usa o mesmo preco e os mesmos tetos; o limite de
    /// CU dele e o consumo simulado, que costuma ficar abaixo do padrao usado aqui.
    /// So para o "quanto pode sair": quem decide se a transacao cabe no saldo e o
    /// planejador, com o estado lido na hora.
    static func fee(_ state: SolanaNetworkState, units: UInt32) -> BigUInt {
        let price = min(state.suggestedComputeUnitPrice, SolanaLimits.maxComputeUnitPrice)
        let priority = min(SolanaLimits.priorityFee(microLamportsPerUnit: price, units: units), BigUInt(SolanaLimits.maxPriorityFeeLamports))
        return BigUInt(SolanaLimits.lamportsPerSignature) + priority
    }
}
