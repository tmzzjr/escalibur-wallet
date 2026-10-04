@testable import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburEngines
@testable import EscaliburNetwork

/// Moeda custom na Stellar: o PYUSD da Paxos (fora da lista na Stellar), que a conta das
/// gravacoes ja aceita. O destino ganha a linha de confianca no proprio teste.
@Suite("Moeda custom: envio na Stellar")
struct StellarCustomAssetTests {
    typealias S = StellarEngineTests
    static let issuer = "GDQE7IXJ4HUHV6RQHIUPRJSEZE4DRS5WY577O2FY6YQ5LVWZ7JZTU2V5"

    static func pyusd(origin: Asset.Origin? = .custom) -> Asset {
        Asset(chainID: "stellar", kind: .issued(code: "PYUSD", issuer: issuer), symbol: "PYUSD", name: "PYUSD", decimals: 7,
              coingeckoID: nil, isStablecoin: false, origin: origin)
    }

    /// As Horizons gravadas, com o destino aceitando PYUSD.
    static func network() throws -> FakeHTTP {
        let fake = try S.network()
        for (host, name) in [("horizon-a.test", "sdf"), ("horizon-b.test", "lobstr")] {
            var account = try #require(JSONSerialization.jsonObject(with: EngineFixture.data("stellar", "account-memo-\(name).json")) as? [String: Any])
            var balances = account["balances"] as? [[String: Any]] ?? []
            balances.insert([
                "balance": "0.0000000", "limit": "922337203685.4775807", "buying_liabilities": "0.0000000",
                "selling_liabilities": "0.0000000", "last_modified_ledger": 64521253, "is_authorized": true,
                "is_authorized_to_maintain_liabilities": true, "asset_type": "credit_alphanum12", "asset_code": "PYUSD", "asset_issuer": issuer,
            ], at: 0)
            account["balances"] = balances
            fake.on("\(host)/accounts/\(S.memoRequired)", data: try JSONSerialization.data(withJSONObject: account))
        }
        return fake
    }

    @Test("Pagamento da moeda custom: codigo e emissor salvos, aviso de nao verificado, mesma conferencia do app")
    func payment() async throws {
        let engine = StellarSendEngine(reader: S.reader(try Self.network()))
        let asset = Self.pyusd()
        let plan = try await engine.plan(S.request(to: S.memoRequired, amount: 1_000_000, asset: asset, tag: "99"))
        guard case .payment(_, let sent, 1_000_000) = try S.operations(plan).first else { Issue.record("esperava pagamento"); return }
        #expect(sent.code == "PYUSD" && sent.issuer?.address == Self.issuer)
        #expect(plan.review.warnings.contains(.unverifiedToken(symbol: "PYUSD")))
        try PlanIntentCheck.send(plan.review, asset: asset, amount: 1_000_000, ceiling: 1_000_000, chain: .stellar)
    }

    @Test("Fora da lista e sem ser moeda custom: recusado como antes")
    func notCustom() async throws {
        let engine = StellarSendEngine(reader: S.reader(try Self.network()))
        await #expect(throws: SendEngineError.self) {
            _ = try await engine.plan(S.request(to: S.memoRequired, amount: 1_000_000, asset: Self.pyusd(origin: .discovered), tag: "99"))
        }
    }
}
