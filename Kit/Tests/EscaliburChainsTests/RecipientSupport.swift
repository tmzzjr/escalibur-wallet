import Testing
@testable import EscaliburChains

/// Todo plano de envio carrega o destino que entrou na transacao, e ele e a mesma
/// conta da linha "Para" que a revisao mostra.
func expectRecipient(_ plan: SigningPlan, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(plan.review.kind == .send, sourceLocation: sourceLocation)
    let shown = plan.review.lines.first { $0.label == "Para" }?.value ?? ""
    #expect(Address.sameRecipient(plan.review.recipient, shown, chain: plan.chain), sourceLocation: sourceLocation)
}

@Suite("Mesmo destino escrito de outro jeito")
struct SameRecipientTests {
    @Test("EVM: caixa do EIP-55 nao muda a conta")
    func evm() {
        let chain = Chain.all.first { $0.id == "ethereum" }!
        let mixed = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
        #expect(Address.sameRecipient(mixed.lowercased(), mixed, chain: chain))
        #expect(!Address.sameRecipient("0x0000000000000000000000000000000000000001", mixed, chain: chain))
        #expect(!Address.sameRecipient(nil, mixed, chain: chain))
    }

    @Test("XRP Ledger: endereco X e o classico sao a mesma conta")
    func xrpl() throws {
        let classic = "rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe"
        let x = try #require(XRPLAddress.xAddress(classic: classic, tag: 12345))
        #expect(Address.sameRecipient(classic, x, chain: .xrpl))
        #expect(!Address.sameRecipient("rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", classic, chain: .xrpl))
    }

    @Test("TON: forma amigavel e forma crua")
    func ton() throws {
        let raw = "0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8"
        guard case .success(let parsed) = TONAddress.parse(raw) else { Issue.record("raw"); return }
        let friendly = parsed.address.friendly(bounceable: false)
        #expect(Address.sameRecipient(raw, friendly, chain: .ton))
        #expect(Address.sameRecipient(parsed.address.friendly(bounceable: true), friendly, chain: .ton))
    }

    @Test("Bitcoin: bech32 em maiusculas e a mesma conta")
    func bech32() {
        let chain = Chain.all.first { $0.id == "bitcoin" }!
        let lower = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        #expect(Address.sameRecipient(lower.uppercased(), lower, chain: chain))
    }
}
