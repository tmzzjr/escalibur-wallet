import EscaliburChains
import EscaliburCore
import EscaliburEngines
import Foundation
import UserNotifications

/// As pontes da carteira: guardadas nos metadados cifrados (`BridgeRecord`, sem segredo) e
/// acompanhadas enquanto o app esta aberto e destrancado. A chegada so conta com a entrega
/// conferida no destino em dois RPCs (`BridgeEngine.progress`).
@MainActor
@Observable
final class BridgeCenter {
    static let shared = BridgeCenter()
    nonisolated static let category = "ponte"

    /// O ultimo andamento lido de cada ponte em curso, por id.
    private(set) var progress: [UUID: BridgeEngine.Progress] = [:]
    private var checking = false

    func records(_ session: AppSession) -> [BridgeRecord] {
        guard let wallet = session.selectedWallet else { return [] }
        return (session.metadata.bridges ?? []).filter { $0.walletID == wallet.id }.sorted { $0.createdAt > $1.createdAt }
    }

    /// As em curso primeiro; das terminadas, as 5 mais recentes.
    func visible(_ session: AppSession) -> [BridgeRecord] {
        let all = records(session)
        return all.filter { $0.state == .pending } + all.filter { $0.state != .pending }.prefix(5)
    }

    func add(_ record: BridgeRecord, session: AppSession) {
        var list = session.metadata.bridges ?? []
        list.removeAll { $0.depositTxHash == record.depositTxHash }
        list.append(record)
        // Guarda as 50 mais recentes: o resto ja esta na Atividade das duas redes.
        session.metadata.bridges = Array(list.sorted { $0.createdAt > $1.createdAt }.prefix(50))
        try? session.persist()
        progress[record.id] = .depositPending
    }

    func forget(_ id: UUID, session: AppSession) {
        session.metadata.bridges?.removeAll { $0.id == id }
        try? session.persist()
        progress[id] = nil
    }

    /// Le o andamento das pontes em curso. Chegada e reembolso conferidos ficam gravados.
    func refresh(session: AppSession) async {
        guard !checking, session.phase == .unlocked else { return }
        checking = true
        defer { checking = false }
        for record in records(session) where record.state == .pending {
            guard let read = try? await BridgeEngine.shared.progress(record) else { continue }
            progress[record.id] = read
            switch read {
            case .arrived(let hash, let amount):
                settle(record.id, state: .arrived, hash: hash, amount: amount, session: session)
                await notifyArrival(record, amount: amount)
            case .refunded(let hash):
                settle(record.id, state: .refunded, hash: hash, amount: nil, session: session)
            case .depositFailed:
                settle(record.id, state: .failed, hash: nil, amount: nil, session: session)
            default:
                break
            }
        }
    }

    private func settle(_ id: UUID, state: BridgeRecord.State, hash: String?, amount: BigUInt?, session: AppSession) {
        guard var list = session.metadata.bridges, let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].state = state
        list[index].settledTxHash = hash
        list[index].receivedAmount = amount?.decimalString
        session.metadata.bridges = list
        try? session.persist()
    }

    private func notifyArrival(_ record: BridgeRecord, amount: BigUInt) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized, let to = record.to else { return }
        let content = UNMutableNotificationContent()
        // Sem valor nem moeda (pentest de 14/10/2026, B1): a tela bloqueada nao conta o
        // que a carteira tem. O valor esta na lista de pontes, com o app aberto.
        content.title = String(localized: "Sua ponte chegou")
        content.body = String(localized: "Conferido na \(to.chain.name). Abra a Escalibur para ver.")
        content.sound = .default
        content.categoryIdentifier = Self.category
        try? await center.add(UNNotificationRequest(identifier: "ponte.\(record.id.uuidString)", content: content, trigger: nil))
    }
}

/// O texto do andamento de uma ponte, para a lista e o painel.
enum BridgeText {
    static func status(_ record: BridgeRecord, _ progress: BridgeEngine.Progress?) -> (title: String, detail: String, done: Bool) {
        let from = record.from?.chain.name ?? record.fromChainID
        let to = record.to?.chain.name ?? record.toChainID
        switch record.state {
        case .arrived:
            let amount = record.receivedAmount.flatMap(BigUInt.init(decimal:)).map {
                Fmt.crypto($0, decimals: record.to.map { record.asset.decimals(on: $0) } ?? 18, symbol: record.asset.symbol)
            } ?? record.asset.symbol
            return (String(localized: "Chegou na \(to)"), String(localized: "\(amount), conferido na rede de destino."), true)
        case .refunded:
            return (String(localized: "Devolvido na \(from)"), String(localized: "Nenhum relayer entregou no prazo, e o Across devolveu o depósito para a sua conta."), true)
        case .failed:
            return (String(localized: "O depósito não saiu"), String(localized: "A transação falhou na \(from). Só a taxa de rede foi cobrada."), true)
        case .pending:
            switch progress {
            case .depositPending?, nil:
                return (String(localized: "Confirmando na \(from)"), String(localized: "O depósito está entrando na rede."), false)
            case .needsClaim?:
                return (String(localized: "A entrega da Circle falhou"), String(localized: "O USDC queimado só pode ser cunhado para a sua conta. Abra de novo mais tarde; se continuar assim, a carteira resgata com a sua assinatura."), false)
            case .mismatch?:
                return (String(localized: "A entrega não confere"), String(localized: "O destino mostrou algo diferente do que você assinou. Confira a Atividade das duas redes."), false)
            default:
                if record.route == .usdt0 {
                    return (String(localized: "A caminho da Tron"), String(localized: "A LayerZero espera a confirmação na \(from) e o contrato da Tether entrega o USDT na sua conta Tron, em uns minutos."), false)
                }
                if record.route.isCCTP {
                    return (String(localized: "A caminho da \(to)"), record.route == .cctpFast
                        ? String(localized: "A Circle atesta e entrega em menos de 1 minuto.")
                        : String(localized: "A Circle espera a finalidade da \(from), uns 20 minutos, e entrega."), false)
                }
                return (String(localized: "A caminho da \(to)"), String(localized: "Um relayer do Across entrega em segundos."), false)
            }
        }
    }
}
