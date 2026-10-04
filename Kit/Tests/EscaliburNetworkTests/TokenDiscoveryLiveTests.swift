import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Os indexadores e as fontes da moeda custom, ao vivo: so com ESCALIBUR_REDE=1.
@Suite("Tokens fora da lista ao vivo", .enabled(if: Live.enabled))
struct TokenDiscoveryLiveTests {
    @Test("Cada indexador EVM sem chave responde a lista de tokens da conta publica de teste")
    func indexers() async throws {
        let owner = try EVMAddress("0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        for (chain, provider) in Endpoints.evmTokenIndex.sorted(by: { $0.key < $1.key }) {
            let tokens = try await TokenIndex.fetch(provider, owner: owner, transport: HTTPClient.shared)
            #expect(tokens.count <= TokenIndex.maxTokens, "\(chain)")
        }
    }

    @Test("Moeda custom: o NOT na TON, o SOLO no XRP Ledger e o AQUA na Stellar")
    func inspector() async throws {
        let ton = try await TokenInspector.shared.inspect(chain: .ton, kind: .token(contract: "EQAvlWFDxGF2lXm67y4yzC17wYKD9A0guwPkMs1gOsM__NOT"))
        #expect(ton.asset.decimals == 9)
        let solo = try await TokenInspector.shared.inspect(chain: .xrpl, kind: .issued(code: "534F4C4F00000000000000000000000000000000", issuer: "rsoLo2S1kiGeCcn6hCUXVrCpGMWLrRrLZz"))
        #expect(solo.asset.symbol == "SOLO")
        let aqua = try await TokenInspector.shared.inspect(chain: .stellar, kind: .issued(code: "AQUA", issuer: "GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA"))
        #expect(aqua.asset.decimals == 7)
    }
}
