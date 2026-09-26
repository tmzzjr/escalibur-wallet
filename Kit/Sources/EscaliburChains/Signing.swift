import EscaliburCore
import Foundation

// O contrato entre as redes e o assinador.
//
// EscaliburChains monta a transacao e diz, byte a byte, o que precisa ser assinado.
// EscaliburKeys deriva a chave, assina, confere a assinatura e devolve. Nenhum lado
// faz o trabalho do outro: a rede nunca ve chave privada, e o assinador nunca decide
// o que assinar.

/// Como a assinatura e feita e em que formato ela volta.
public enum SignatureScheme: String, Sendable, Codable {
    /// ECDSA secp256k1, low-S, em DER. Bitcoin, Litecoin, Dogecoin, XRP Ledger.
    case ecdsaDER
    /// ECDSA secp256k1, low-S, `r || s` (64 bytes) mais o id de recuperacao. EVM, Tron.
    case ecdsaRecoverable
    /// Ed25519 sobre a mensagem inteira (nao sobre um digesto). Solana, Stellar, TON.
    case ed25519
    /// Schnorr BIP-340 com a chave ajustada pelo BIP-86. Taproot.
    case schnorrBIP340
}

/// Uma assinatura que a transacao precisa.
public struct SigningRequest: Sendable, Equatable {
    /// Qual chave: o caminho a partir da seed da carteira.
    public let path: DerivationPath
    public let curve: Curve
    public let scheme: SignatureScheme
    /// Digesto de 32 bytes (ECDSA, Schnorr) ou a mensagem inteira (Ed25519),
    /// **sempre calculado localmente** a partir dos campos da transacao.
    public let payload: [UInt8]
    /// A chave publica que a chave derivada tem de ter: 33 bytes comprimidos na
    /// secp256k1, 32 na Ed25519. O assinador recusa se nao bater, e isso pega caminho
    /// errado antes de uma assinatura sair com a chave de outra conta.
    public let expectedPublicKey: [UInt8]

    public init(path: DerivationPath, curve: Curve, scheme: SignatureScheme, payload: [UInt8], expectedPublicKey: [UInt8]) {
        self.path = path
        self.curve = curve
        self.scheme = scheme
        self.payload = payload
        self.expectedPublicKey = expectedPublicKey
    }
}

/// O que o assinador devolve para cada `SigningRequest`, na mesma ordem.
public struct ProducedSignature: Sendable, Equatable {
    /// DER (ecdsaDER), `r || s` (ecdsaRecoverable), 64 bytes (ed25519, schnorr).
    public let bytes: [UInt8]
    /// So em ecdsaRecoverable: 0 ou 1.
    public let recoveryID: UInt8?

    public init(bytes: [UInt8], recoveryID: UInt8? = nil) {
        self.bytes = bytes
        self.recoveryID = recoveryID
    }
}

/// A transacao pronta para transmitir.
public struct SignedTransaction: Sendable, Equatable, Codable {
    public let chainID: String
    public let raw: [UInt8]
    /// A forma que o provedor da rede recebe: hex, base64, JSON. Transmitir sempre
    /// estes mesmos bytes, nunca reassinar: na Solana e no XRP Ledger com Ed25519 a
    /// reassinatura muda o id da transacao.
    public let encoded: String
    /// O identificador que o explorador de blocos entende.
    public let id: String

    public init(chainID: String, raw: [UInt8], encoded: String, id: String) {
        self.chainID = chainID
        self.raw = raw
        self.encoded = encoded
        self.id = id
    }
}

/// Uma transacao que sabe dizer o que precisa ser assinado e se montar depois.
public protocol SignableTransaction: Sendable {
    var chain: Chain { get }
    var signingRequests: [SigningRequest] { get }
    func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction
}

public enum SigningError: Error, Equatable, Sendable {
    case wrongSignatureCount
    case malformedSignature
    case expired
}

// MARK: Plano

/// Um lote de transacoes que passou pela validacao e pode ser assinado.
///
/// **O inicializador e interno a EscaliburChains.** Nenhum outro modulo, nem os motores
/// de EscaliburEngines nem o app, constroi um plano: ele so nasce dos planejadores das
/// redes, que conferem a intencao do dono contra o que vai ser assinado. De fora, so
/// duas composicoes existem, as duas sobre planos ja validados aqui: somar avisos
/// (`addingWarnings`) e encadear planos para assinar de uma vez (`sequence`). O
/// assinador de EscaliburKeys so aceita este tipo, entao "assinar sem validar" nao
/// compila.
public struct SigningPlan: Sendable {
    public let id: UUID
    public let walletID: UUID
    public let chain: Chain
    /// O que a tela de revisao mostra, ja decodificado. Nunca o JSON do provedor.
    public let review: PlanReview
    public let transactions: [any SignableTransaction]
    public let createdAt: Date

    /// Um plano vale 60 segundos. Passou disso, recota e reconstroi: nonce, taxa e
    /// cotacao ficam velhos, e uma assinatura sobre dado velho nao sai.
    public static let lifetime: TimeInterval = 60

    init(walletID: UUID, chain: Chain, review: PlanReview, transactions: [any SignableTransaction], createdAt: Date = .now) {
        self.init(id: UUID(), walletID: walletID, chain: chain, review: review, transactions: transactions, createdAt: createdAt)
    }

    private init(id: UUID, walletID: UUID, chain: Chain, review: PlanReview, transactions: [any SignableTransaction], createdAt: Date) {
        self.id = id
        self.walletID = walletID
        self.chain = chain
        self.review = review
        self.transactions = transactions
        self.createdAt = createdAt
    }

    public func isExpired(now: Date = .now) -> Bool {
        now.timeIntervalSince(createdAt) > Self.lifetime
    }

    // MARK: Composicao

    public enum CompositionError: Error, Equatable, Sendable {
        /// Nenhum plano para encadear.
        case empty
        /// Planos de carteiras ou de redes diferentes nao se assinam juntos.
        case mixedPlans
    }

    /// O mesmo plano com avisos a mais, os que so o motor sabe (endereco parecido com
    /// um ja usado, primeiro envio). Transacoes, destino, titulo, linhas, identidade e
    /// prazo nao mudam; aviso repetido nao entra.
    public func addingWarnings(_ warnings: [PlanReview.Warning]) -> SigningPlan {
        let fresh = warnings.reduce(into: [PlanReview.Warning]()) { out, warning in
            if !review.warnings.contains(warning), !out.contains(warning) { out.append(warning) }
        }
        guard !fresh.isEmpty else { return self }
        let updated = PlanReview(
            kind: review.kind, title: review.title, lines: review.lines, warnings: review.warnings + fresh,
            transactionCount: review.transactionCount, recipient: review.recipient, recipientTag: review.recipientTag,
            outgoing: review.outgoing, incomingMinimum: review.incomingMinimum, beneficiary: review.beneficiary
        )
        return SigningPlan(id: id, walletID: walletID, chain: chain, review: updated, transactions: transactions, createdAt: createdAt)
    }

    /// Planos ja validados, assinados de uma vez e transmitidos na ordem dada (a
    /// autorizacao antes da troca, as pernas de uma divisao, as ofertas encadeadas).
    ///
    /// A revisao e a soma das revisoes: as linhas de abertura (`lead`), depois as de
    /// cada plano, com "Etapa n ·" na frente quando `stepPrefix`, sem as de rotulo em
    /// `omitting` (o que a abertura ja resume). Os avisos de todos entram, sem
    /// repeticao. O prazo conta do plano mais antigo.
    public static func sequence(
        _ plans: [SigningPlan], kind: PlanReview.Kind, title: String, lead: [PlanReview.Line],
        stepPrefix: Bool = false, omitting labels: Set<String> = []
    ) throws -> SigningPlan {
        guard let first = plans.first else { throw CompositionError.empty }
        guard plans.allSatisfy({ $0.walletID == first.walletID && $0.chain.id == first.chain.id }) else {
            throw CompositionError.mixedPlans
        }
        var lines = lead
        for (index, plan) in plans.enumerated() {
            for line in plan.review.lines where !labels.contains(line.label) {
                lines.append(PlanReview.Line(stepPrefix ? "Etapa \(index + 1) · \(line.label)" : line.label, line.value, verbatim: line.verbatim))
            }
        }
        var warnings: [PlanReview.Warning] = []
        for warning in plans.flatMap(\.review.warnings) where !warnings.contains(warning) { warnings.append(warning) }
        let transactions = plans.flatMap(\.transactions)
        let review = PlanReview(kind: kind, title: title, lines: lines, warnings: warnings, transactionCount: transactions.count)
        return SigningPlan(
            walletID: first.walletID, chain: first.chain, review: review, transactions: transactions,
            createdAt: plans.map(\.createdAt).min() ?? first.createdAt
        )
    }
}

/// O resumo que a tela de revisao mostra, montado pela validacao.
public struct PlanReview: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case send, swap, approve, limitOrder, cancelOrder, trustline, revoke
    }

    public struct Line: Sendable, Equatable {
        public let label: String
        public let value: String
        /// Valor que se confere caractere por caractere (endereco, tag): vai para a
        /// placa clara, em mono.
        public let verbatim: Bool

        public init(_ label: String, _ value: String, verbatim: Bool = false) {
            self.label = label
            self.value = value
            self.verbatim = verbatim
        }
    }

    public enum Warning: Sendable, Equatable {
        case firstSendToAddress
        case lookalikeAddress(known: String)
        case noDestinationTag
        case destinationIsContract
        case highPriceImpact(percent: Double)
        case unlimitedApproval
        case highFee(percentOfAmount: Double)
        case unverifiedToken(symbol: String)
        case activatesAccount(minimum: String)
    }

    /// Quanto de qual ativo, em unidades da rede. O ativo e o `Asset.id` da lista
    /// (`TokenRegistry`), o mesmo que a tela usa.
    public struct Movement: Sendable, Equatable {
        public let assetID: String
        public let amount: BigUInt

        public init(assetID: String, amount: BigUInt) {
            self.assetID = assetID
            self.amount = amount
        }
    }

    public let kind: Kind
    /// "Enviar 50 XRP", "Trocar 0,5 ETH por USDC".
    public let title: String
    public let lines: [Line]
    public let warnings: [Warning]
    /// Quantas transacoes o dono vai assinar neste plano.
    public let transactionCount: Int
    /// Num envio: o destino exatamente como entrou na transacao, e a tag, o memo ou o
    /// comentario que foi junto. O app confere contra o que o dono digitou antes de
    /// mostrar a revisao e de novo antes de assinar (`Address.sameRecipient`).
    public let recipient: String?
    public let recipientTag: String?
    /// O que sai da carteira: no envio, o valor enviado; na troca e na ordem, o valor
    /// vendido. Preenchido so pelo planejador, das transacoes que ele montou; o app
    /// confere contra o ativo e o valor pedidos antes de revisar e antes de assinar.
    public let outgoing: Movement?
    /// Na troca e na ordem: o minimo que entra, garantido pela transacao.
    public let incomingMinimum: Movement?
    /// Na troca e na ordem: quem recebe o que entra. Sempre a propria conta do dono.
    public let beneficiary: String?

    public init(
        kind: Kind, title: String, lines: [Line], warnings: [Warning] = [], transactionCount: Int = 1,
        recipient: String? = nil, recipientTag: String? = nil,
        outgoing: Movement? = nil, incomingMinimum: Movement? = nil, beneficiary: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.lines = lines
        self.warnings = warnings
        self.transactionCount = transactionCount
        self.recipient = recipient
        self.recipientTag = recipientTag
        self.outgoing = outgoing
        self.incomingMinimum = incomingMinimum
        self.beneficiary = beneficiary
    }
}
