import EscaliburChains
import Testing

@Suite("Link de pagamento")
struct PaymentLinkTests {
    let usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
    let to = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"

    @Test("QR de token EIP-681: o destino e o address=, nunca o contrato")
    func tokenRequest() throws {
        let reading = try PaymentLink.read("ethereum:\(usdc)@8453/transfer?address=\(to)&uint256=1.5e6")
        #expect(reading.address == to)
        #expect(reading.address != usdc)
        #expect(reading.chainID == "base")
        let noChain = try PaymentLink.read("ethereum:pay-\(usdc)/transfer?address=\(to.lowercased())&uint256=1")
        #expect(noChain.address == to)
        #expect(noChain.chainID == nil)
    }

    @Test("EIP-681 nativo, com rede")
    func nativeRequest() throws {
        let reading = try PaymentLink.read("  ethereum:\(to)@137?value=1e18\n")
        #expect(reading.address == to)
        #expect(reading.chainID == "polygon")
    }

    @Test("EIP-681 recusado nao vira endereco")
    func refused() {
        #expect(throws: PaymentLink.Problem.invalidEthereumRequest(.ensNotSupported)) {
            try PaymentLink.read("ethereum:vitalik.eth?value=1")
        }
        #expect(throws: PaymentLink.Problem.invalidEthereumRequest(.unsupportedFunction("approve"))) {
            try PaymentLink.read("ethereum:\(usdc)/approve?address=\(to)&uint256=1")
        }
        #expect(throws: PaymentLink.Problem.tooLong) {
            try PaymentLink.read("bitcoin:" + String(repeating: "a", count: 600))
        }
    }

    @Test("Outros esquemas: so o endereco")
    func otherSchemes() throws {
        #expect(try PaymentLink.read("bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?amount=0.1&label=x").address
            == "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq")
        #expect(try PaymentLink.read("solana:7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU?amount=1").address
            == "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU")
        #expect(try PaymentLink.read("rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh").address == "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh")
    }
}
