import EscaliburChains
import EscaliburCore
import Foundation

/// Um movimento da conta, para a aba Atividade. Neutro de rede: cada leitor traduz o
/// indexador da sua rede para isto.
///
/// Tudo aqui e exibicao. Nada deste tipo alimenta transacao: o ativo vem da lista
/// curada (nunca do simbolo que o indexador manda), o link do explorador e montado com
/// o modelo compilado da rede (nunca um link de resposta), e a contraparte e so texto.
/// A interface nao oferece "copiar endereco" a partir de um recebimento de desconhecido
/// (docs/seguranca.md §4.10): e o vetor do envenenamento de endereco.
public struct ActivityItem: Sendable, Equatable, Identifiable {
    public enum Direction: String, Sendable, Equatable {
        case sent
        case received
        /// Saiu um ativo e entrou outro na mesma transacao.
        case swap
        /// Acao da conta sem transferencia de valor (aprovacao, linha de confianca,
        /// oferta, stake) ou envio para si mesmo.
        case other
    }

    public enum Status: String, Sendable, Equatable {
        case pending, confirmed, failed
    }

    /// Unico dentro da rede: hash mais o indice do movimento na transacao.
    public let id: String
    public let chainID: String
    public let direction: Direction
    /// Ativo da lista curada (`TokenRegistry`) ou a moeda nativa.
    public let asset: Asset
    /// Nas unidades da rede. No XRP Ledger, sempre o `delivered_amount`.
    public let amount: BigUInt
    /// Na troca: o que entrou (o que saiu fica em `asset`/`amount`).
    public let receivedAsset: Asset?
    public let receivedAmount: BigUInt?
    /// Quem mandou (recebimento) ou para quem foi (envio). So texto de exibicao.
    public let counterparty: String?
    public let date: Date
    public let status: Status
    /// Taxa paga pelo dono, na moeda nativa. `nil` quando quem pagou foi outro.
    public let fee: BigUInt?
    public let hash: String
    public let explorerURL: URL?
    /// XRP Ledger: pagamento com tfPartialPayment. A tela marca mesmo com o valor certo,
    /// porque e o formato do golpe (docs/seguranca.md §4.8).
    public let isPartialPayment: Bool

    public init(
        id: String, chainID: String, direction: Direction, asset: Asset, amount: BigUInt,
        receivedAsset: Asset? = nil, receivedAmount: BigUInt? = nil, counterparty: String?, date: Date,
        status: Status, fee: BigUInt?, hash: String, explorerURL: URL?, isPartialPayment: Bool = false
    ) {
        self.id = id
        self.chainID = chainID
        self.direction = direction
        self.asset = asset
        self.amount = amount
        self.receivedAsset = receivedAsset
        self.receivedAmount = receivedAmount
        self.counterparty = counterparty
        self.date = date
        self.status = status
        self.fee = fee
        self.hash = hash
        self.explorerURL = explorerURL
        self.isPartialPayment = isPartialPayment
    }
}

/// O que ficou fora da lista, por motivo. Recebimentos que qualquer um pode empurrar
/// para o historico de qualquer conta: sao o material do envenenamento de endereco e
/// dos tokens de golpe (docs/seguranca.md §4.10). A tela mostra so a contagem.
public struct SuspiciousSummary: Sendable, Equatable {
    /// Transferencias de valor zero (o `transferFrom` de 0 que planta o endereco sosia).
    public var zeroValue = 0
    /// Tokens fora da lista curada, inclusive os que copiam nome e simbolo dos reais.
    public var unknownAsset = 0
    /// Po: recebimento abaixo do limite de exibicao do ativo.
    public var dust = 0
    /// O indexador marcou como golpe. So serve para esconder, nunca para liberar.
    public var flaggedByProvider = 0

    public init() {}

    public var total: Int { zeroValue + unknownAsset + dust + flaggedByProvider }
}

/// Os ultimos movimentos de uma conta numa rede.
public struct ActivityPage: Sendable, Equatable {
    public let chainID: String
    /// Mais recente primeiro, no maximo `ActivityRules.pageSize`.
    public let items: [ActivityItem]
    public let suspicious: SuspiciousSummary
    /// `false` quando parte da consulta falhou (ex.: o indexador nao entregou as
    /// transferencias de token a tempo). A tela diz "historico parcial" em vez de fingir
    /// que nao houve movimento.
    public let isComplete: Bool
    public let fetchedAt: Date

    public init(chainID: String, items: [ActivityItem], suspicious: SuspiciousSummary, isComplete: Bool = true, fetchedAt: Date = .now) {
        self.chainID = chainID
        self.items = items
        self.suspicious = suspicious
        self.isComplete = isComplete
        self.fetchedAt = fetchedAt
    }

    public var suspiciousCount: Int { suspicious.total }
}

/// As regras de filtragem, as mesmas em todas as redes.
///
/// So recebimentos sao filtrados. O que a propria conta fez (envio, aprovacao, troca)
/// aparece sempre: foi o dono que assinou, e esconder isso esconderia um dreno.
enum ActivityRules {
    static let pageSize = 30

    enum Suspicion { case zeroValue, unknownAsset, dust, flaggedByProvider }

    /// Limite de po para recebimento: 0,0001 da unidade (0,01 em stablecoin). Os golpes
    /// vistos ao vivo em 25/09/2026 mandam 1 drop no XRP Ledger e 1 nanoton na TON, com
    /// um comentario de link; os de stablecoin mandam centavos de endereco sosia.
    static func dustLimit(for asset: Asset) -> BigUInt {
        let places = asset.isStablecoin ? max(0, asset.decimals - 2) : max(0, asset.decimals - 4)
        return BigUInt.power(of: 10, places)
    }

    /// `nil` se o recebimento pode aparecer; senao, o motivo para esconder.
    static func judgeIncoming(asset: Asset?, amount: BigUInt, flaggedByProvider: Bool = false) -> Suspicion? {
        guard let asset else { return .unknownAsset }
        if amount.isZero { return .zeroValue }
        if flaggedByProvider { return .flaggedByProvider }
        if amount < dustLimit(for: asset) { return .dust }
        return nil
    }

    static func count(_ suspicion: Suspicion, in summary: inout SuspiciousSummary) {
        switch suspicion {
        case .zeroValue: summary.zeroValue += 1
        case .unknownAsset: summary.unknownAsset += 1
        case .dust: summary.dust += 1
        case .flaggedByProvider: summary.flaggedByProvider += 1
        }
    }

    /// Mais recente primeiro, sem repetir id, cortado no tamanho da pagina.
    static func page(chainID: String, items: [ActivityItem], suspicious: SuspiciousSummary, complete: Bool = true) -> ActivityPage {
        var seen = Set<String>()
        let unique = items.sorted { $0.date > $1.date }.filter { seen.insert($0.id).inserted }
        return ActivityPage(chainID: chainID, items: Array(unique.prefix(pageSize)), suspicious: suspicious, isComplete: complete)
    }
}
