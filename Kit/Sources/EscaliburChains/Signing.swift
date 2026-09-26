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
/// **O inicializador e `package`.** Fora deste pacote (no app) nao existe maneira
/// de construir um plano: ele so nasce das funcoes de validacao das redes, que
/// conferem a intencao do dono contra o que vai ser assinado. O assinador de
/// EscaliburKeys so aceita este tipo, entao "assinar sem validar" nao compila.
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

    package init(walletID: UUID, chain: Chain, review: PlanReview, transactions: [any SignableTransaction], createdAt: Date = .now) {
        self.id = UUID()
        self.walletID = walletID
        self.chain = chain
        self.review = review
        self.transactions = transactions
        self.createdAt = createdAt
    }

    public func isExpired(now: Date = .now) -> Bool {
        now.timeIntervalSince(createdAt) > Self.lifetime
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

    public let kind: Kind
    /// "Enviar 50 XRP", "Trocar 0,5 ETH por USDC".
    public let title: String
    public let lines: [Line]
    public let warnings: [Warning]
    /// Quantas transacoes o dono vai assinar neste plano.
    public let transactionCount: Int

    public init(kind: Kind, title: String, lines: [Line], warnings: [Warning] = [], transactionCount: Int = 1) {
        self.kind = kind
        self.title = title
        self.lines = lines
        self.warnings = warnings
        self.transactionCount = transactionCount
    }
}
