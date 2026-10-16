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

    @Test("Tag e memo do link vao junto: XRP Ledger dt, TON text, Stellar SEP-7")
    func tagsAndMemos() throws {
        let xrp = try PaymentLink.read("xrpl:rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh?dt=12345")
        #expect(xrp.address == "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh" && xrp.tag == "12345")
        let ton = try PaymentLink.read("ton://transfer/EQD__________________________________________0vo?amount=1&text=dep%C3%B3sito%2042")
        #expect(ton.address == "EQD__________________________________________0vo" && ton.tag == "depósito 42")
        let g = "GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZ"
        let sep7 = try PaymentLink.read("web+stellar:pay?destination=\(g)&amount=10&memo=987&memo_type=MEMO_ID")
        #expect(sep7.address == g && sep7.tag == "987")
        #expect(try PaymentLink.read("web+stellar:pay?destination=\(g)&memo=conta-7").tag == "conta-7")
        #expect(try PaymentLink.read("web+stellar:pay?destination=\(g)").tag == nil)
        // Memo de texto so com numeros iria como memo ID; hash e retorno o app nao envia.
        #expect(throws: PaymentLink.Problem.unsupportedMemo) { try PaymentLink.read("web+stellar:pay?destination=\(g)&memo=987&memo_type=MEMO_TEXT") }
        #expect(throws: PaymentLink.Problem.unsupportedMemo) { try PaymentLink.read("web+stellar:pay?destination=\(g)&memo=abc&memo_type=MEMO_HASH") }
        #expect(throws: PaymentLink.Problem.unsupportedStellarRequest) { try PaymentLink.read("web+stellar:tx?xdr=AAAA") }
        #expect(throws: PaymentLink.Problem.duplicateParameter("dt")) { try PaymentLink.read("xrpl:rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh?dt=1&dt=2") }
        // O destino M (69 caracteres) vai inteiro.
        let m = "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVAAAAAAAAAAAAAJLK"
        #expect(try PaymentLink.read("web+stellar:pay?destination=\(m)").address == m)
        // MEMO_ID so na forma que sai como ID; tag invisivel, com direcao trocada, com espaco
        // nas pontas ou longa demais e recusada, nunca cortada; X-address com dt tambem.
        #expect(throws: PaymentLink.Problem.unsupportedMemo) { try PaymentLink.read("web+stellar:pay?destination=\(g)&memo=007&memo_type=MEMO_ID") }
        #expect(throws: PaymentLink.Problem.unsupportedMemo) { try PaymentLink.read("web+stellar:pay?destination=\(g)&memo=%2B5&memo_type=MEMO_ID") }
        #expect(throws: PaymentLink.Problem.invalidTag) { try PaymentLink.read("xrpl:rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh?dt=12345%E2%80%8B") }
        #expect(throws: PaymentLink.Problem.invalidTag) { try PaymentLink.read("ton://transfer/EQD__________________________________________0vo?text=%E2%80%AE54321") }
        #expect(throws: PaymentLink.Problem.invalidTag) { try PaymentLink.read("ton://transfer/EQD__________________________________________0vo?text=%2042") }
        #expect(throws: PaymentLink.Problem.invalidTag) { try PaymentLink.read("ton://transfer/EQD__________________________________________0vo?text=" + String(repeating: "a", count: 65)) }
        #expect(throws: PaymentLink.Problem.invalidTag) { try PaymentLink.read("xrpl:XVLhHMPHU98es4dbozjVtdWzVrDjtV18pX8yuPT7y4xaEHi?dt=5") }
        // Em outros esquemas, o que nao e tag fica de fora.
        #expect(try PaymentLink.read("bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?amount=0.1&dt=5").tag == nil)
    }

    @Test("Codigo com as palavras de uma carteira, ou SeedQR, nunca vira destino")
    func phrases() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        #expect(throws: PaymentLink.Problem.containsPhrase) { try PaymentLink.read(phrase) }
        #expect(throws: PaymentLink.Problem.containsPhrase) { try PaymentLink.read("  " + phrase.uppercased() + "\n") }
        #expect(throws: PaymentLink.Problem.containsPhrase) { try PaymentLink.read(String(repeating: "0000", count: 12)) }
        #expect(throws: PaymentLink.Problem.containsPhrase) { try PaymentLink.read(String(repeating: "1234", count: 24)) }
        #expect((try? PaymentLink.read("abandon abandon about")) != nil)
    }

    @Test("Regressao B-4: o esquema diz a rede e a familia, com os ids de Chain.swift")
    func schemeNetwork() throws {
        let g = "GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZ"
        let cases: [(link: String, address: String, chain: Chain)] = [
            ("bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?amount=0.1", "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", .bitcoin),
            ("BITCOIN:BC1QAR0SRRR7XFKVY5L643LYDNW9RE59GTZZWF5MDQ", "BC1QAR0SRRR7XFKVY5L643LYDNW9RE59GTZZWF5MDQ", .bitcoin),
            ("litecoin:3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy", "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy", .litecoin),
            ("dogecoin:DH5yaieqoZN36fDVciNyRueRGvGLR3mr7L?amount=5", "DH5yaieqoZN36fDVciNyRueRGvGLR3mr7L", .dogecoin),
            ("solana:7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU", "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU", .solana),
            ("xrpl:rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", .xrpl),
            ("ripple:rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh?dt=7", "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh", .xrpl),
            ("ton://transfer/EQD__________________________________________0vo", "EQD__________________________________________0vo", .ton),
            ("web+stellar:pay?destination=\(g)", g, .stellar),
            ("tron:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", .tron),
        ]
        for item in cases {
            let reading = try PaymentLink.read(item.link)
            #expect(reading.address == item.address, "\(item.link)")
            #expect(reading.chainID == item.chain.id && reading.family == item.chain.family, "\(item.link)")
            // O id e o de uma rede de verdade: a tela compara com o `id` da dela.
            #expect(Chain.find(item.chain.id) == item.chain)
        }
        // O P2SH da Litecoin antiga tem a forma de um endereco de Bitcoin: so o esquema diz
        // a rede, e a tela de Bitcoin recusa pelo `chainID`.
        #expect(try PaymentLink.read("litecoin:3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy").chainID != Chain.bitcoin.id)
        // EIP-681: a familia sempre; a rede, so com `@chain_id`.
        let any = try PaymentLink.read("ethereum:\(to)?value=1")
        #expect(any.chainID == nil && any.family == .evm)
        let base = try PaymentLink.read("ethereum:\(to)@8453?value=1")
        #expect(base.chainID == "base" && base.family == .evm)
        // Sem esquema, nem rede nem familia: a tela valida o endereco como e.
        let plain = try PaymentLink.read("rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh")
        #expect(plain.chainID == nil && plain.family == nil)
        let raw = try PaymentLink.read("0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8")
        #expect(raw.chainID == nil && raw.family == nil)
    }

    @Test("Regressao B-4: esquema de rede que o app nao tem, ou desconhecido, e recusado")
    func unsupportedSchemes() throws {
        // O Bitcoin Cash usa enderecos legados iguais aos do Bitcoin: lido como endereco
        // qualquer, ia para a tela de Bitcoin.
        #expect(throws: PaymentLink.Problem.unsupportedNetwork("bitcoincash")) {
            try PaymentLink.read("bitcoincash:1BoatSLRHtKNngkdXEeobR76b53LETtpyT")
        }
        #expect(throws: PaymentLink.Problem.unsupportedNetwork("bitcoincash")) {
            try PaymentLink.read("BitcoinCash:qpm2qsznhks23z7629mms6s4cwef74vcwvy22gdx6a?amount=1")
        }
        for scheme in ["ecash", "monero", "zcash", "dash"] {
            #expect(throws: PaymentLink.Problem.unsupportedNetwork(scheme)) { try PaymentLink.read("\(scheme):1BoatSLRHtKNngkdXEeobR76b53LETtpyT") }
        }
        for scheme in ["https", "wc", "base"] {
            #expect(throws: PaymentLink.Problem.unknownScheme(scheme)) { try PaymentLink.read("\(scheme):1BoatSLRHtKNngkdXEeobR76b53LETtpyT") }
        }
        // As redes que o app envia continuam lidas pelo esquema delas, com a rede dita.
        let g = "GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZ"
        #expect(try PaymentLink.read("stellar:\(g)").chainID == "stellar")
        for (scheme, id) in [("cardano", "cardano"), ("sui", "sui"), ("aptos", "aptos"), ("near", "near"), ("polkadot", "polkadot")] {
            #expect(try PaymentLink.read("\(scheme):abc").chainID == id)
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
