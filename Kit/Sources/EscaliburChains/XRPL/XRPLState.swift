import EscaliburCore
import Foundation

// O estado publico que o planejamento do XRP Ledger precisa. Dados puros:
// EscaliburNetwork preenche, EscaliburChains so le e decide. Nenhum valor aqui tem
// padrao compilado, porque reserva e taxa mudam por votacao dos validadores, e um
// plano montado com a reserva de 2024 (10 XRP) bloquearia ou liberaria errado hoje.

/// O que vem do `server_info` (ou `server_state`) e do `fee`, no ledger validado.
public struct XRPLLedgerState: Sendable, Equatable {
    /// `validated_ledger.seq`: o ultimo ledger validado. O LastLedgerSequence sai daqui.
    public var validatedLedgerIndex: UInt32
    /// `validated_ledger.reserve_base_xrp`, convertido para drops.
    public var reserveBase: BigUInt
    /// `validated_ledger.reserve_inc_xrp`, em drops: o custo de cada objeto do dono
    /// (linha de confianca, oferta, escrow, ticket...).
    public var reserveIncrement: BigUInt
    /// `fee.drops.open_ledger_fee`: o minimo para entrar no ledger aberto agora.
    public var openLedgerFee: BigUInt

    public init(validatedLedgerIndex: UInt32, reserveBase: BigUInt, reserveIncrement: BigUInt, openLedgerFee: BigUInt) {
        self.validatedLedgerIndex = validatedLedgerIndex
        self.reserveBase = reserveBase
        self.reserveIncrement = reserveIncrement
        self.openLedgerFee = openLedgerFee
    }
}

/// A conta do dono, de `account_info` com `ledger_index: "validated"`.
public struct XRPLAccountState: Sendable, Equatable {
    /// O endereco classico consultado. Tem de ser o da chave que assina.
    public var address: String
    /// `account_data.Sequence` lido em **cada** servidor consultado, pelo menos dois.
    /// Divergencia bloqueia: um servidor que mente o Sequence faz a carteira assinar
    /// uma transacao que fica presa ou que substitui outra.
    public var sequenceReadings: [UInt32]
    /// `account_data.Balance`, em drops.
    public var balance: BigUInt
    /// `account_data.OwnerCount`: quantos objetos prendem reserva hoje.
    public var ownerCount: UInt32
    /// `account_data.Flags`.
    public var flags: UInt32

    public init(address: String, sequenceReadings: [UInt32], balance: BigUInt, ownerCount: UInt32, flags: UInt32 = 0) {
        self.address = address
        self.sequenceReadings = sequenceReadings
        self.balance = balance
        self.ownerCount = ownerCount
        self.flags = flags
    }
}

/// A conta de destino, de `account_info` validado em dois ou mais servidores
/// (docs/seguranca.md §4.8).
public struct XRPLDestinationState: Sendable, Equatable {
    public enum Reading: Sendable, Equatable, Hashable {
        /// `actNotFound`: a conta ainda nao existe no ledger.
        case notFound
        /// A conta existe; `account_data.Flags`.
        case found(flags: UInt32)
    }

    /// O endereco classico consultado. Tem de ser o destino resolvido do que o dono
    /// digitou (um X-address vira o r... correspondente).
    public var address: String
    /// Uma leitura por servidor. Menos de duas, ou leituras diferentes, bloqueia.
    public var readings: [Reading]
    /// `deposit_authorized` (origem = dono, destino = este). So importa quando o
    /// destino tem lsfDepositAuth.
    public var depositPreauthorized: Bool

    public init(address: String, readings: [Reading], depositPreauthorized: Bool = false) {
        self.address = address
        self.readings = readings
        self.depositPreauthorized = depositPreauthorized
    }
}

/// Um token que a carteira aceita: moeda, emissor e o nome que a tela mostra.
///
/// A lista vem do chamador e deve ser compilada no app, nunca de resposta de rede.
/// Qualquer conta pode emitir um "USD"; o que separa o dolar da Bitstamp de um golpe
/// e so o endereco do emissor.
public struct XRPLCuratedAsset: Sendable, Equatable {
    public let currency: XRPLCurrency
    public let issuer: String
    public let issuerName: String

    public init(currency: XRPLCurrency, issuer: String, issuerName: String) throws {
        guard XRPLAddress.accountID(issuer) != nil else { throw XRPLCodecError.invalidAccount(issuer) }
        self.currency = currency
        self.issuer = issuer
        self.issuerName = issuerName
    }
}

// MARK: Intencoes do dono

/// Enviar XRP.
public struct XRPLSendIntent: Sendable, Equatable {
    /// O que o dono digitou ou colou: r... ou X-address.
    public var destination: String
    /// A tag digitada, se houver. Com um X-address que ja traz outra tag, recusa.
    public var destinationTag: UInt32?
    public var drops: BigUInt
    public var memo: String?
    /// O dono viu que o destino pediu para nao receber XRP (lsfDisallowXRP) e confirmou.
    public var acknowledgesDisallowXRP: Bool

    public init(destination: String, destinationTag: UInt32? = nil, drops: BigUInt, memo: String? = nil, acknowledgesDisallowXRP: Bool = false) {
        self.destination = destination
        self.destinationTag = destinationTag
        self.drops = drops
        self.memo = memo
        self.acknowledgesDisallowXRP = acknowledgesDisallowXRP
    }
}

/// Criar uma linha de confianca para um token da lista curada.
public struct XRPLTrustlineIntent: Sendable, Equatable {
    public var currency: XRPLCurrency
    public var issuer: String
    /// Limite em texto decimal ("1000000"). Positivo: limite zero apaga a linha.
    public var limit: String

    public init(currency: XRPLCurrency, issuer: String, limit: String) {
        self.currency = currency
        self.issuer = issuer
        self.limit = limit
    }
}

/// Um lado de uma oferta.
public enum XRPLOfferAsset: Sendable, Equatable {
    case xrp(drops: BigUInt)
    /// Valor em texto decimal; moeda e emissor tem de estar na lista curada.
    case issued(currency: XRPLCurrency, issuer: String, value: String)
}

/// Por quanto tempo a oferta tenta executar.
public enum XRPLTimeInForce: Sendable, Equatable {
    /// Fica no livro ate executar, ser cancelada ou expirar.
    case goodTilExpiration
    /// tfImmediateOrCancel: executa o que der agora e cancela o resto.
    case immediateOrCancel
    /// tfFillOrKill: executa tudo agora ou nada.
    case fillOrKill
}

/// Ordem limite nativa: "voce entrega X, recebe no minimo Y".
public struct XRPLOfferIntent: Sendable, Equatable {
    /// O que o dono entrega (TakerGets).
    public var give: XRPLOfferAsset
    /// O minimo que o dono recebe por isso (TakerPays).
    public var receiveAtLeast: XRPLOfferAsset
    public var expiration: Date
    /// tfSell: entrega todo o X mesmo que receba mais que Y.
    public var sell: Bool
    /// tfPassive: nao consome ofertas que empatam o preco.
    public var passive: Bool
    public var timeInForce: XRPLTimeInForce

    public init(
        give: XRPLOfferAsset, receiveAtLeast: XRPLOfferAsset, expiration: Date,
        sell: Bool = true, passive: Bool = false, timeInForce: XRPLTimeInForce = .goodTilExpiration
    ) {
        self.give = give
        self.receiveAtLeast = receiveAtLeast
        self.expiration = expiration
        self.sell = sell
        self.passive = passive
        self.timeInForce = timeInForce
    }
}

/// Cancelar uma oferta do dono, pelo Sequence da transacao que a criou
/// (`account_offers` devolve como `seq`).
public struct XRPLCancelOfferIntent: Sendable, Equatable {
    public var offerSequence: UInt32

    public init(offerSequence: UInt32) {
        self.offerSequence = offerSequence
    }
}
