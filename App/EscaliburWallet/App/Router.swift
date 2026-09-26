import EscaliburChains
import SwiftUI

/// Navegacao do app: aba atual, pilhas, e os fluxos em tela cheia.
@MainActor
@Observable
final class Router {
    enum Tab: Hashable { case wallet, market, trade, activity, settings }
    enum TradeMode: Hashable { case now, limit }

    enum Flow: Identifiable, Hashable {
        case send(Asset?)
        var id: String {
            switch self {
            case .send(let asset): return "send:\(asset?.id ?? "")"
            }
        }
    }

    var tab: Tab = .wallet
    var tradeMode: TradeMode = .now
    var walletPath = NavigationPath()
    var marketPath = NavigationPath()
    var flow: Flow?
    /// Envelope aberto pelo sistema (AirDrop, Arquivos) esperando o app destravar.
    var incomingEnvelope: URL?

    func present(_ flow: Flow) { self.flow = flow }
}
