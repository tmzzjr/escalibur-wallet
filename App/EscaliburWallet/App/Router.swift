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
    /// Ativo que a aba Trocar deve abrir escolhido, vindo do detalhe de uma moeda.
    /// `sell` verdadeiro: vender este ativo; falso: comprar.
    var tradePreset: (asset: Asset, sell: Bool)?
    /// Envelope aberto pelo sistema (AirDrop, Arquivos) esperando o app destravar.
    var incomingEnvelope: URL?
    /// Moeda de um alerta de preco tocado: o Mercado abre a pagina dela.
    var pendingCoinID: String?

    func present(_ flow: Flow) { self.flow = flow }
}
