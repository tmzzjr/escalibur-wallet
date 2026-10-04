import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// A Atividade da Stellar, pelo `StellarReader.history`.
///
/// O leitor ja marca ativo fora da lista, poeira de desconhecido e saldo reivindicavel
/// nao pedido; aqui se soma a regra do endereco parecido com o da conta ou com um
/// destino ja pago.
struct StellarActivitySource: ActivitySource {
    let reader: StellarReader

    static let limit = 20

    init(reader: StellarReader = StellarReader()) {
        self.reader = reader
    }

    func history(chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async throws -> [ActivityEntry] {
        guard chain == .stellar else { throw SendEngineError.message(NetworkFailureText.wrongAccount) }
        let source = try StellarEngineSupport.source(account)
        do {
            let items = try await reader.history(
                source.account, limit: Self.limit, listedAssets: StellarEngineSupport.allowedAssets
            )
            return ChainActivityEntries.entries(
                items, chain: .stellar, own: [source.account.address], resolve: StellarEngineSupport.asset
            )
        } catch HTTPClient.Failure.status(404) {
            // Conta que nunca recebeu XLM ainda nao existe na rede, e o Horizon responde
            // 404. Nao ha historico para mostrar; nao e falha de leitura.
            return []
        } catch {
            throw StellarEngineSupport.translate(error)
        }
    }
}
