import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Litecoin e Dogecoin contra os provedores reais, pela lista do app. So com
/// ESCALIBUR_REDE=1. Num IP que a Blockcypher e a Blockchair cortaram, passar aqui prova
/// a contingencia: Blockbook e Bitcore respondem no lugar delas.
@Suite("Litecoin e Dogecoin ao vivo", .enabled(if: ReaderBTest.live))
struct ReaderBUTXOFallbackLiveTests {
    static let dogeAddress = "DDrRHGaBYqLULgbphrRxzw8LwM1iasW4Mx"
    /// Endereco comum (12 transacoes, saldo zero): o Bitcore demora em enderecos de
    /// corretora, com centenas de milhares de transacoes.
    static let ltcAddress = "Ld8Nrg2LGHEVjNRi17D811Kb4r7wT2B97V"

    @Test("Cada provedor novo responde sozinho: altura, uso, saldo e taxa")
    func eachProvider() async throws {
        for (chain, address) in [(Chain.dogecoin, Self.dogeAddress), (Chain.litecoin, Self.ltcAddress)] {
            for provider in UTXOReader.providers(for: chain) where ["atomic", "bitcore"].contains(provider.name) {
                let reader = try UTXOReader(chain: chain, providers: [provider])
                let height = try await reader.tipHeight()
                #expect(height > 1_000_000, "\(chain.id) \(provider.name)")
                #expect(try await reader.isUsed(address), "\(chain.id) \(provider.name)")
                _ = try await reader.balance(addresses: [address])
                Live.note("\(chain.id) \(provider.name): altura \(height)")
            }
        }
    }

    @Test("Pela lista do app: saldo, taxa de duas fontes e moedas conferidas")
    func appProviders() async throws {
        for (chain, address) in [(Chain.dogecoin, Self.dogeAddress), (Chain.litecoin, Self.ltcAddress)] {
            let reader = try UTXOReader(chain: chain)
            _ = try await reader.balance(addresses: [address])
            let fees = try await reader.feeLevels()
            #expect(fees.sources.count >= 2)
            Live.note("\(chain.id): taxa de \(fees.sources), rapida \(fees.fast.satPerKvB) sat/kvB")
        }
        let owner = try ReaderBTest.derived(
            publicKeyHex: "03f176840d250f67afc1f9de7c461de2adf681e533cadb26dea58b37939ff5adf0", chain: .dogecoin, kind: .p2pkh
        )
        let reading = try await UTXOReader(chain: .dogecoin).coins(for: [owner])
        #expect(!reading.coins.isEmpty)
    }
}
