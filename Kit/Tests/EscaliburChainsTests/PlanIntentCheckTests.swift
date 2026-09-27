import EscaliburCore
import Testing
@testable import EscaliburChains

@Suite("Plano contra o pedido (auditoria 2, M1)")
struct PlanIntentCheckTests {
    let base = Chain.base
    let owner = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
    var eth: Asset { .native(base) }
    var usdc: Asset { TokenRegistry.tokens.first { $0.chainID == "base" && $0.symbol == "USDC" }! }

    func review(out: PlanReview.Movement?, in incoming: PlanReview.Movement? = nil, beneficiary: String? = nil) -> PlanReview {
        PlanReview(kind: .swap, title: "t", lines: [], outgoing: out, incomingMinimum: incoming, beneficiary: beneficiary)
    }

    @Test("Envio de valor exato: ativo e valor iguais, nada a mais")
    func exactSend() throws {
        try PlanIntentCheck.send(review(out: .init(assetID: usdc.id, amount: 5_000_000)), asset: usdc, amount: 5_000_000, ceiling: 9_000_000, chain: base)
        #expect(throws: PlanIntentCheck.Mismatch.wrongAmount) {
            try PlanIntentCheck.send(review(out: .init(assetID: usdc.id, amount: 5_000_001)), asset: usdc, amount: 5_000_000, ceiling: 9_000_000, chain: base)
        }
        #expect(throws: PlanIntentCheck.Mismatch.wrongAsset) {
            try PlanIntentCheck.send(review(out: .init(assetID: eth.id, amount: 5_000_000)), asset: usdc, amount: 5_000_000, ceiling: 9_000_000, chain: base)
        }
        #expect(throws: PlanIntentCheck.Mismatch.missingMovement) {
            try PlanIntentCheck.send(review(out: nil), asset: usdc, amount: 5_000_000, ceiling: 9_000_000, chain: base)
        }
        // Contrato em outra caixa na EVM e o mesmo token.
        try PlanIntentCheck.send(review(out: .init(assetID: usdc.id.uppercased(), amount: 1)), asset: usdc, amount: 1, ceiling: 1, chain: base)
    }

    @Test("Enviar tudo: no maximo o saldo mostrado")
    func sendAll() throws {
        try PlanIntentCheck.send(review(out: .init(assetID: eth.id, amount: 990)), asset: eth, amount: nil, ceiling: 1_000, chain: base)
        #expect(throws: PlanIntentCheck.Mismatch.wrongAmount) {
            try PlanIntentCheck.send(review(out: .init(assetID: eth.id, amount: 1_001)), asset: eth, amount: nil, ceiling: 1_000, chain: base)
        }
    }

    @Test("Troca: vende o pedido, garante o minimo, e o que entra e do dono")
    func trade() throws {
        let good = review(out: .init(assetID: eth.id, amount: 1_000), in: .init(assetID: usdc.id, amount: 2_500), beneficiary: owner.lowercased())
        try PlanIntentCheck.trade(good, sell: eth, amountIn: 1_000, buy: usdc, minimumOut: 2_500, owner: owner, chain: base)
        let cases: [(PlanReview, PlanIntentCheck.Mismatch)] = [
            (review(out: .init(assetID: eth.id, amount: 1_001), in: .init(assetID: usdc.id, amount: 2_500), beneficiary: owner), .wrongAmount),
            (review(out: .init(assetID: usdc.id, amount: 1_000), in: .init(assetID: usdc.id, amount: 2_500), beneficiary: owner), .wrongAsset),
            (review(out: .init(assetID: eth.id, amount: 1_000), in: .init(assetID: eth.id, amount: 2_500), beneficiary: owner), .wrongBuyAsset),
            (review(out: .init(assetID: eth.id, amount: 1_000), in: .init(assetID: usdc.id, amount: 2_499), beneficiary: owner), .belowMinimum),
            (review(out: .init(assetID: eth.id, amount: 1_000), in: .init(assetID: usdc.id, amount: 2_500),
                    beneficiary: "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"), .wrongBeneficiary),
            (review(out: .init(assetID: eth.id, amount: 1_000), in: .init(assetID: usdc.id, amount: 2_500), beneficiary: nil), .wrongBeneficiary),
            (review(out: .init(assetID: eth.id, amount: 1_000), in: nil, beneficiary: owner), .missingMovement),
        ]
        for (plan, expected) in cases {
            #expect(throws: expected) {
                try PlanIntentCheck.trade(plan, sell: eth, amountIn: 1_000, buy: usdc, minimumOut: 2_500, owner: owner, chain: base)
            }
        }
    }

    @Test("Tag: numero no XRP Ledger, texto exato na Stellar, TON e Tron (B7)")
    func tags() throws {
        let xrpl = try #require(Chain.find("xrpl"))
        let stellar = try #require(Chain.find("stellar"))
        #expect(PlanIntentCheck.sameTag("123", "0123", chain: xrpl))
        #expect(!PlanIntentCheck.sameTag("123", "124", chain: xrpl))
        #expect(!PlanIntentCheck.sameTag("abc", "abc", chain: xrpl))
        // Stellar: "0123" de texto nao e o ID 123.
        #expect(!PlanIntentCheck.sameTag("123", "0123", chain: stellar))
        #expect(PlanIntentCheck.sameTag("0123", "0123", chain: stellar))
        #expect(PlanIntentCheck.sameTag(nil, "", chain: stellar))
        #expect(!PlanIntentCheck.sameTag(nil, "5", chain: stellar))
        #expect(!PlanIntentCheck.sameTag("5", nil, chain: xrpl))
    }
}
