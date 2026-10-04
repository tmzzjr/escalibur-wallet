import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// A Atividade de Bitcoin, Litecoin e Dogecoin, pelo `UTXOReader.history`.
///
/// O historico e de todos os enderecos com uso da conta (recebimento e troco), achados
/// pela mesma varredura do envio. O leitor ja marca a poeira de desconhecido; aqui se
/// soma a regra do endereco parecido com um da carteira ou com um destino ja pago.
struct UTXOActivitySource: ActivitySource {
    let chain: Chain
    let reader: UTXOReader

    /// As ultimas transacoes, como a tela mostra.
    static let limit = 20

    init(chain: Chain, reader: UTXOReader) {
        self.chain = chain
        self.reader = reader
    }

    init?(chain: Chain) {
        guard chain.family == .utxo, let reader = try? UTXOReader(chain: chain) else { return nil }
        self.init(chain: chain, reader: reader)
    }

    func history(chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async throws -> [ActivityEntry] {
        guard chain == self.chain else { throw SendEngineError.message(NetworkFailureText.wrongAccount) }
        do {
            let utxoAccount = try UTXOEngineSupport.account(account, chain: chain)
            let discovery = try await UTXODiscoveryCache.discover(
                utxoAccount, usage: usage, reader: reader, maxAge: UTXODiscoveryCache.displayLifetime
            )
            let items = try await reader.history(discovery, limit: Self.limit)
            return ChainActivityEntries.entries(
                items, chain: chain, own: discovery.scanned.map(\.address),
                resolve: { $0 == .native ? Asset.native(chain) : nil }
            )
        } catch {
            throw UTXOEngineSupport.translate(error, chain: chain)
        }
    }
}
