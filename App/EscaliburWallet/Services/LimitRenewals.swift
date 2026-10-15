import EscaliburChains
import EscaliburCore
import EscaliburEngines
import Foundation
import UserNotifications

/// Uma ordem limite que o dono pediu para refazer quando vencer.
///
/// Sem servidor, e com a chave so no iPhone, nada refaz a ordem sozinho: quem assina e o
/// dono. O app guarda os dados da ordem nos metadados cifrados (rede, ativos, valor,
/// preco e prazo; nada de segredo), avisa com uma notificacao local quando o prazo
/// acaba e, na abertura seguinte, pergunta se refaz. Refazer passa pela mesma revisao,
/// voz, PIN ou Face ID e assinatura de qualquer ordem.
struct LimitRenewal: Codable, Equatable, Hashable, Identifiable {
    /// O id da ordem na rede: o UID da CoW.
    let orderID: String
    let walletID: UUID
    let chainID: String
    let sellAssetID: String
    let buyAssetID: String
    let amountIn: BigUInt
    let minimumOut: BigUInt
    let validFor: TimeInterval
    let expiresAt: Date

    var id: String { orderID }
}

/// Uma ordem vencida, pronta para a pergunta: o que ainda falta vender (ela pode ter
/// saido em parte) e o minimo pelo mesmo preco.
struct DueRenewal: Identifiable, Equatable {
    let record: LimitRenewal
    let chain: Chain
    let sell: Asset
    let buy: Asset
    let amountIn: BigUInt
    let minimumOut: BigUInt
    /// Quanto da ordem vencida chegou a sair, de 0 a 1.
    let filledFraction: Double

    var id: String { record.orderID }

    /// O minimo pelo que falta vender, no preco da ordem: para cima, nunca abaixo dele.
    static func minimum(_ record: LimitRenewal, remaining: BigUInt) -> BigUInt {
        guard !record.amountIn.isZero else { return 0 }
        return (record.minimumOut * remaining + record.amountIn - BigUInt(1)) / record.amountIn
    }
}

@MainActor
@Observable
final class LimitRenewalCenter {
    static let shared = LimitRenewalCenter()
    nonisolated static let category = "ordem-limite"

    /// So as redes com andamento de ordem lido da rede: a CoW. No XRP Ledger e na
    /// Stellar a oferta que some pode ter executado, e o app nao saberia se refaz.
    static func supports(_ chain: Chain) -> Bool { CoWProtocol.supports(chain) }

    private(set) var due: [DueRenewal] = []
    /// Deixadas para depois nesta abertura do app.
    var postponed: Set<String> = []
    private var checking = false

    var pending: [DueRenewal] { due.filter { !postponed.contains($0.id) } }

    func isRenewing(_ orderID: String, session: AppSession) -> Bool {
        session.metadata.limitRenewals?.contains { $0.orderID == orderID } == true
    }

    /// Depois de a ordem ir para a rede: guarda os dados e agenda o aviso do fim do prazo,
    /// lido do proprio UID (os ultimos 4 bytes sao o `validTo`).
    func register(orderID: String, request: LimitOrderRequest, session: AppSession) {
        guard Self.supports(request.chain), orderID.hasPrefix("0x"), let uid = Hex.decode(orderID),
              let validTo = CoWProtocol.validTo(ofUID: uid) else { return }
        let record = LimitRenewal(
            orderID: orderID, walletID: request.walletID, chainID: request.chain.id, sellAssetID: request.sell.id,
            buyAssetID: request.buy.id, amountIn: request.amountIn, minimumOut: request.minimumOut,
            validFor: request.validFor ?? CoWProtocol.untilCancelledValidity, expiresAt: Date(timeIntervalSince1970: TimeInterval(validTo))
        )
        var list = session.metadata.limitRenewals ?? []
        list.removeAll { $0.orderID == orderID }
        list.append(record)
        session.metadata.limitRenewals = list
        try? session.persist()
        Self.scheduleNotice(record)
    }

    func forget(_ orderID: String, session: AppSession) {
        session.metadata.limitRenewals?.removeAll { $0.orderID == orderID }
        try? session.persist()
        due.removeAll { $0.id == orderID }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.noticeID(orderID)])
    }

    /// Le na rede as ordens vencidas da carteira escolhida. Executada ou cancelada sai da
    /// lista; vencida com algo a vender vira pergunta; sem resposta da rede, fica para a
    /// proxima vez.
    func refresh(session: AppSession) async {
        guard !checking, session.phase == .unlocked, let wallet = session.selectedWallet, !wallet.isWatchOnly else { return }
        #if DEBUG
        if previewing { return }
        #endif
        checking = true
        defer { checking = false }
        let now = Date()
        var found: [DueRenewal] = []
        for record in session.metadata.limitRenewals ?? [] where record.walletID == wallet.id && record.expiresAt <= now {
            guard let chain = Chain.all.first(where: { $0.id == record.chainID }), let engine = TradeEngines.engine(for: chain), let account = wallet.account(chain),
                  let sell = Self.listed(record.sellAssetID, chain: chain), let buy = Self.listed(record.buyAssetID, chain: chain)
            else {
                forget(record.orderID, session: session)
                continue
            }
            guard let progress = try? await engine.orderProgress(id: record.orderID, account: account) else { continue }
            switch progress.state {
            case .filled, .cancelled:
                forget(record.orderID, session: session)
            case .open:
                continue
            case .expired:
                let sold = min(progress.soldSell, record.amountIn)
                let remaining = record.amountIn - sold
                guard !remaining.isZero else {
                    forget(record.orderID, session: session)
                    continue
                }
                found.append(DueRenewal(
                    record: record, chain: chain, sell: sell, buy: buy, amountIn: remaining,
                    minimumOut: DueRenewal.minimum(record, remaining: remaining), filledFraction: progress.fraction
                ))
            }
        }
        due = found
    }

    #if DEBUG
    /// `-tela refazer`: uma ordem vencida de mentira, so para conferir o desenho.
    func preview(_ item: DueRenewal) {
        previewing = true
        due = [item]
    }

    private var previewing = false
    #endif

    static func listed(_ id: String, chain: Chain) -> Asset? {
        TokenRegistry.assets(on: chain).first { $0.id == id }
    }

    // MARK: Aviso

    static func noticeID(_ orderID: String) -> String { "ordem-limite.\(orderID)" }

    /// O aviso nao diz ativo nem valor: a tela bloqueada nao conta o que a carteira tem.
    static func scheduleNotice(_ record: LimitRenewal) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "O prazo de uma ordem limite acabou")
        content.body = String(localized: "Abra a Escalibur: se ainda faltar vender, o app pergunta se refaz com o mesmo preço.")
        content.categoryIdentifier = category
        content.userInfo = ["ordem": record.orderID]
        let interval = max(60, record.expiresAt.timeIntervalSinceNow + 60)
        let request = UNNotificationRequest(
            identifier: noticeID(record.orderID), content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }
}
