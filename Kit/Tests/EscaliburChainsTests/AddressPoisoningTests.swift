import EscaliburCore
import Testing
@testable import EscaliburChains

@Suite("Endereco parecido (envenenamento)")
struct AddressPoisoningTests {
    let ethereum = Chain.all.first { $0.id == "ethereum" }!
    let bitcoin = Chain.all.first { $0.id == "bitcoin" }!

    @Test("EVM: pontas iguais e meio diferente e parecido; o prefixo 0x nao conta")
    func evm() {
        let real = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
        let fake = "0xd8dA000000000000000000000000000000A96045"
        #expect(AddressPoisoning.lookalike(fake, among: [real], chain: ethereum) == real)
        // So o 0x e uma ponta: nao e parecido.
        #expect(AddressPoisoning.lookalike("0x1111111111111111111111111111111111116045", among: [real], chain: ethereum) == nil)
        // A mesma conta em outra caixa nao e parecida, e a propria.
        #expect(AddressPoisoning.lookalike(real.lowercased(), among: [real], chain: ethereum) == nil)
    }

    @Test("O desafio pede o meio onde os dois diferem, nunca as pontas copiadas")
    func differingSegment() throws {
        let real = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
        let fake = "0xd8dA000000000000000000000000000000A96045"
        let segment = try #require(AddressPoisoning.differingSegment(fake, from: real, chain: ethereum))
        #expect(segment.start == 6)
        #expect(segment.text(in: fake) == "000000")
        #expect(segment.text(in: fake).lowercased() != segment.text(in: real).lowercased())
        #expect(!fake.hasSuffix(segment.text(in: fake)))
        // Diferenca so perto do fim: o trecho encosta no fim e ainda a inclui.
        let late = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96099"
        let tail = try #require(AddressPoisoning.differingSegment(late, from: real, chain: ethereum))
        #expect(tail.text(in: late) == "A96099")
        // Bech32: o prefixo bc1q fica fora.
        let btcReal = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        let btcFake = "bc1qw50xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx8f3t4"
        #expect(AddressPoisoning.differingSegment(btcFake, from: btcReal, chain: bitcoin)?.text(in: btcFake) == "xxxxxx")
        #expect(AddressPoisoning.differingSegment(real, from: real, chain: ethereum) == nil)
    }

    @Test("Bitcoin bech32: bc1q nao conta como coincidencia")
    func bech32() {
        let real = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        #expect(AddressPoisoning.body(real, chain: bitcoin).hasPrefix("w508"))
        let fake = "bc1qw50xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx8f3t4"
        #expect(AddressPoisoning.lookalike(fake, among: [real], chain: bitcoin) == real)
    }

    @Test("Uma ponta so, longa, tambem e parecida: 2+6, 0+10 e 10+0 avisam; 4 numa ponta, em hexadecimal, nao")
    func singleEnd() {
        let real = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
        // Duas no comeco e seis no fim: as duas pontas juntas deixavam passar.
        #expect(AddressPoisoning.lookalike("0xd811111111111111111111111111111111A96045", among: [real], chain: ethereum) == real)
        // Dez no fim, nada no comeco; dez no comeco, nada no fim.
        #expect(AddressPoisoning.lookalike("0x111111111111111111111111111111D37aA96045", among: [real], chain: ethereum) == real)
        #expect(AddressPoisoning.lookalike("0xd8dA6BF269111111111111111111111111111111", among: [real], chain: ethereum) == real)
        // Cinco no fim ja avisa; quatro numa ponta so, ao acaso, nao.
        #expect(AddressPoisoning.lookalike("0x1111111111111111111111111111111111196045", among: [real], chain: ethereum) == real)
        #expect(AddressPoisoning.lookalike("0x1111111111111111111111111111111111116045", among: [real], chain: ethereum) == nil)
        // Conta com nome na NEAR termina igual por desenho.
        #expect(AddressPoisoning.lookalike("someone-else-wallet.near", among: ["my-own-main-wallet.near"], chain: .near) == nil)
    }

    @Test("Tron: o T inicial nao conta")
    func tron() {
        let real = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
        let fake = "TR7NHzzzzzzzzzzzzzzzzzzzzzzzgjLj6t"
        #expect(AddressPoisoning.lookalike(fake, among: [real], chain: .tron) == real)
        // O T e mais tres no fim: nada. Quatro no fim, em base58, ja marcam (B-5).
        #expect(AddressPoisoning.lookalike("TXYZ" + String(repeating: "z", count: 27) + "j6t", among: [real], chain: .tron) == nil)
        #expect(AddressPoisoning.lookalike("TXYZzzzzzzzzzzzzzzzzzzzzzzzzzzLj6t", among: [real], chain: .tron) == real)
    }

    // MARK: B-5: sosias que casam o que a tela mostra

    @Test("O corpo comeca depois do prefixo fixo da rede: e por ele que a tela abrevia")
    func bodySegment() {
        func start(_ address: String, _ chain: Chain) -> Int { AddressPoisoning.bodySegment(address, chain: chain).start }
        #expect(start("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", bitcoin) == 4)
        #expect(start("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", bitcoin) == 1)
        #expect(start("ltc1qg82tw8v8xtq7kj2r3wj8h0f2zcnd7qkzl8dsgh", .litecoin) == 5)
        #expect(start("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", ethereum) == 2)
        #expect(start("TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", .tron) == 1)
        #expect(start("addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x", .cardano) == 6)
        #expect(start("7EcDhSYGxXyscszYEp35KHN8vvw3svAuLKTzXwCFLtV", .solana) == 0)
        // Conta pelo texto sem os espacos das pontas, como ele e mostrado.
        let segment = AddressPoisoning.bodySegment(" bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4\n", chain: bitcoin)
        #expect(segment.text(in: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4") == "w508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
    }

    @Test("Com 32 simbolos ou mais, 4 numa ponta ja marcam; em hexadecimal continuam 5")
    func wideSingleEnd() {
        // Bitcoin bech32: so os 4 do fim, que a tela mostra, iguais. Tres nao.
        let btc = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        #expect(AddressPoisoning.lookalike("bc1q" + String(repeating: "x", count: 34) + "f3t4", among: [btc], chain: bitcoin) == btc)
        #expect(AddressPoisoning.lookalike("bc1q" + String(repeating: "x", count: 35) + "3t4", among: [btc], chain: bitcoin) == nil)
        // O prefixo da rede nao conta: ltc1q e mais tres do corpo nao sao quatro.
        let ltc = "ltc1qg82tw8v8xtq7kj2r3wj8h0f2zcnd7qkzl8dsgh"
        #expect(AddressPoisoning.lookalike("ltc1qg82" + String(repeating: "x", count: 35), among: [ltc], chain: .litecoin) == nil)
        #expect(AddressPoisoning.lookalike("ltc1qg82t" + String(repeating: "x", count: 34), among: [ltc], chain: .litecoin) == ltc)
        // Cardano: addr1q e o cabecalho vem de graca; so os 4 do fim iguais ja marcam.
        let ada = "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x"
        #expect(AddressPoisoning.lookalike("addr1q" + String(repeating: "z", count: 93) + "5a3x", among: [ada], chain: .cardano) == ada)
        #expect(AddressPoisoning.lookalike("addr1q" + String(repeating: "z", count: 94) + "a3x", among: [ada], chain: .cardano) == nil)
        // Stellar (base32), Solana (base58) e TON amigavel (base64): a mesma regra.
        let xlm = "GAAZI4TCR3TY5OJHCTJC2A4QSY6CJWJH5IAJTGKIN2ER7LBNVKOCCWN7"
        #expect(AddressPoisoning.lookalike("G" + String(repeating: "Z", count: 51) + "CWN7", among: [xlm], chain: .stellar) == xlm)
        let sol = "7EcDhSYGxXyscszYEp35KHN8vvw3svAuLKTzXwCFLtV"
        #expect(AddressPoisoning.lookalike("7EcD" + String(repeating: "z", count: 39), among: [sol], chain: .solana) == sol)
        let ton = "UQ" + String(repeating: "A", count: 42) + "qEBI"
        #expect(AddressPoisoning.lookalike("UQ" + String(repeating: "z", count: 42) + "qEBI", among: [ton], chain: .ton) == ton)
        // Hexadecimal: 4 no fim nao, 5 sim (EVM no teste de cima; Sui, Aptos e TON crua aqui).
        let sui = "0x" + String(repeating: "a", count: 59) + "12345"
        #expect(AddressPoisoning.lookalike("0x" + String(repeating: "b", count: 60) + "2345", among: [sui], chain: .sui) == nil)
        #expect(AddressPoisoning.lookalike("0x" + String(repeating: "b", count: 59) + "12345", among: [sui], chain: .sui) == sui)
        #expect(AddressPoisoning.lookalike("0x" + String(repeating: "b", count: 60) + "2345", among: [sui], chain: .aptos) == nil)
        let raw = "0:" + String(repeating: "a", count: 59) + "12345"
        #expect(AddressPoisoning.lookalike("0:" + String(repeating: "b", count: 60) + "2345", among: [raw], chain: .ton) == nil)
        #expect(AddressPoisoning.lookalike("0:" + String(repeating: "b", count: 59) + "12345", among: [raw], chain: .ton) == raw)
    }

    @Test("Cardano: mesma credencial de stake, outro pagamento e 3 iguais no fim marcam")
    func cardanoSameStake() throws {
        // Gerados para o teste (bech32 do CIP-19, cabecalho 0x01): os tres primeiros com a
        // mesma credencial de stake, o ultimo com outra. Com o stake do dono, a segunda
        // metade do endereco e igual a dele, e so o checksum muda no fim.
        let known = "addr1qyyv6jg54hqxmy82f7cavszujss9aheq20ljak444elvc3cn9e3fuvg9skagnx0kn35pqfe2gkqwqhtzxuj5vsn7xypqtjphcz"
        let sameStakeTail3 = "addr1q9ujytw4uyyr880u83qcw2kr7jdklhwpcg6ctmpve5m0tasn9e3fuvg9skagnx0kn35pqfe2gkqwqhtzxuj5vsn7xypqqwfhcz"
        let sameStakeTail2 = "addr1q88g743le87x4taxtfrcuvtlpl0nrefp8saz25tsfp78qpqn9e3fuvg9skagnx0kn35pqfe2gkqwqhtzxuj5vsn7xypq5zq6cz"
        let otherStakeTail3 = "addr1qx9jca5y85fd5yccunc9mklvzlvc2yfnh208gyec97udx6ltajgsm80cpl2z2jmvx7x924g9nq7v606sz4k7np6fag0qd47hcz"
        let parsed = try [known, sameStakeTail3, sameStakeTail2, otherStakeTail3].map { try CardanoAddress.parse($0).get() }
        #expect(parsed[0].stakeHash == parsed[1].stakeHash && parsed[0].stakeHash == parsed[2].stakeHash)
        #expect(parsed[0].stakeHash != parsed[3].stakeHash)
        #expect(Set(parsed.map(\.paymentHash)).count == 4)
        #expect(AddressPoisoning.lookalike(sameStakeTail3, among: [known], chain: .cardano) == known)
        // Dois no fim, ou tres com outro stake: nada, como antes.
        #expect(AddressPoisoning.lookalike(sameStakeTail2, among: [known], chain: .cardano) == nil)
        #expect(AddressPoisoning.lookalike(otherStakeTail3, among: [known], chain: .cardano) == nil)
        // Os vetores do CIP-19 de tipo 0 e 1 tem o mesmo stake e fins diferentes: nada.
        let cip19Type0 = "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x"
        let cip19Type1 = "addr1z8phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gten0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgs9yc0hh"
        #expect(AddressPoisoning.lookalike(cip19Type1, among: [cip19Type0], chain: .cardano) == nil)
    }

    /// Pares ao acaso: a taxa de falso positivo da regra, medida com enderecos de verdade
    /// de cada rede (bytes aleatorios codificados pelo codigo do app), 10 mil por rede, em
    /// todos os 49.995.000 pares de cada uma. Medido em 16/10/2026 com esta semente:
    ///
    ///     rede                      pares marcados   por milhao de pares
    ///     Bitcoin bech32 (bc1q)           90               1,8
    ///     Bitcoin base58 (1...)          126               2,5
    ///     Litecoin bech32 (ltc1q)         98               2,0
    ///     Dogecoin (D...)                105               2,1
    ///     Tron (T...)                    113               2,3
    ///     XRP Ledger (r...)              126               2,5
    ///     Solana                         118               2,4
    ///     Stellar (G...)                 411               8,2
    ///     Cardano (addr1q...)            447               8,9
    ///     Polkadot (1...)                264               5,3
    ///     TON amigavel (UQ...)           314               6,3
    ///     Ethereum (hex, 5)               89               1,8
    ///     Sui (hex, 5)                    99               2,0
    ///     NEAR implicita (hex, 5)         98               2,0
    ///
    /// Os 20 bits dao perto de 2 por milhao (uma ponta ou a outra, 2^-20 cada). Stellar,
    /// Cardano, TON e Polkadot ficam acima porque o primeiro caractere do corpo carrega
    /// poucos bits: na Stellar e na TON sao 2 bits da chave (4 valores), na Cardano 3 bits
    /// do cabecalho e 2 da credencial, na Polkadot o primeiro digito de um numero de 34
    /// bytes. Mesmo assim, menos de 1 em 100 mil pares: com 50 enderecos conhecidos, na
    /// pior rede, um aviso a toa a cada 2 mil envios para endereco novo.
    @Test("Falso positivo ao acaso: desprezivel em toda rede")
    func randomPairs() {
        var random = SplitMix64(seed: 0x0E5C_A11B_0B5E_55ED)
        let count = 10_000
        let generators: [(Chain, (inout SplitMix64) -> String)] = [
            (bitcoin, { UTXOScript.address(for: [0x00, 0x14] + $0.bytes(20), chain: .bitcoin)! }),
            (bitcoin, { UTXOScript.address(for: [0x76, 0xA9, 0x14] + $0.bytes(20) + [0x88, 0xAC], chain: .bitcoin)! }),
            (.litecoin, { UTXOScript.address(for: [0x00, 0x14] + $0.bytes(20), chain: .litecoin)! }),
            (.dogecoin, { UTXOScript.address(for: [0x76, 0xA9, 0x14] + $0.bytes(20) + [0x88, 0xAC], chain: .dogecoin)! }),
            (.tron, { Base58.bitcoin.encodeCheck([TronAddress.prefix] + $0.bytes(20)) }),
            (.xrpl, { Base58.ripple.encodeCheck([0x00] + $0.bytes(20)) }),
            (.solana, { Base58.bitcoin.encode($0.bytes(32)) }),
            (.stellar, { StellarKey.encode(version: StellarKey.accountVersion, payload: $0.bytes(32)) }),
            (.cardano, { CardanoAddress(bytes: [0x01] + $0.bytes(56)).bech32 }),
            (.polkadot, { PolkadotAddress.encode($0.bytes(32), prefix: 0) }),
            (.ton, { TONAddress(workchain: 0, hash: $0.bytes(32)).friendly(bounceable: false) }),
            (ethereum, { "0x" + Hex.encode($0.bytes(20)) }),
            (.sui, { "0x" + Hex.encode($0.bytes(32)) }),
            (.near, { Hex.encode($0.bytes(32)) }),
        ]
        for (chain, generate) in generators {
            let addresses = (0..<count).map { _ in generate(&random) }
            let (flagged, pairs) = Self.falsePositives(addresses, chain: chain)
            let rate = Double(flagged) / Double(pairs)
            #expect(rate < 1.5e-5, "\(chain.name), \(addresses[0].prefix(4)): \(flagged) de \(pairs) pares")
        }
    }

    // MARK: B-6: endereco M da Stellar com o ID trocado

    @Test("Stellar: a mesma conta base com outro ID e dita, com o trecho do ID depois da chave")
    func stellarOtherID() throws {
        let key = StellarStrKeyTests.sep23Key
        let base = try StellarKey.accountID(key)
        let mine = StellarKey.muxedAddress(publicKey: key, id: 1_234_567)
        let attacker = StellarKey.muxedAddress(publicKey: key, id: 7_654_321)
        let mineKnown = AddressPoisoning.SameAccount(known: mine, knownID: 1_234_567)
        // Para o parecido, a mesma conta, nao um sosia; o ID trocado e a outra conferencia.
        #expect(AddressPoisoning.lookalike(attacker, among: [mine], chain: .stellar) == nil)
        #expect(AddressPoisoning.sameAccountOtherID(attacker, among: [base, mine], chain: .stellar) == mineKnown)
        #expect(AddressPoisoning.sameAccountOtherID(" \(attacker)\n", among: [mine], chain: .stellar) == mineKnown)
        // Os vetores do SEP-0023: ID 0 e ID 2^63 da mesma chave.
        let m0 = "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJUAAAAAAAAAAAACJUQ"
        let mBig = "MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVAAAAAAAAAAAAAJLK"
        #expect(AddressPoisoning.sameAccountOtherID(mBig, among: [m0], chain: .stellar) == .init(known: m0, knownID: 0))
        // O M de sempre, mesmo com outro M da conta tambem conhecido: nada a conferir.
        #expect(AddressPoisoning.sameAccountOtherID(mine, among: [attacker, mine], chain: .stellar) == nil)
        // Sem ID dos dois lados, outra conta ou outra rede: nada.
        #expect(AddressPoisoning.sameAccountOtherID(attacker, among: [base], chain: .stellar) == nil)
        #expect(AddressPoisoning.sameAccountOtherID(base, among: [mine], chain: .stellar) == nil)
        #expect(AddressPoisoning.sameAccountOtherID(attacker, among: [mine], chain: ethereum) == nil)
        let stranger = StellarKey.muxedAddress(publicKey: [UInt8](repeating: 7, count: 32), id: 1_234_567)
        #expect(AddressPoisoning.sameAccountOtherID(attacker, among: [stranger], chain: .stellar) == nil)

        // O contato G salvo com o ID no memo e o mesmo par (conta, ID) de um M.
        let contact = [(address: base, tag: "1234567")]
        #expect(AddressPoisoning.sameAccountOtherID(attacker, among: [], tagged: contact, chain: .stellar) == .init(known: base, knownID: 1_234_567))
        #expect(AddressPoisoning.sameAccountOtherID(mine, among: [], tagged: contact, chain: .stellar) == nil)
        #expect(AddressPoisoning.sameAccountOtherID(attacker, among: [], tagged: [(address: base, tag: "memo de texto")], chain: .stellar) == nil)
        // E o destino G com o memo do envio, contra um M conhecido.
        #expect(AddressPoisoning.sameAccountOtherID(base, tag: "7654321", among: [mine], chain: .stellar) == mineKnown)
        #expect(AddressPoisoning.sameAccountOtherID(base, tag: "1234567", among: [mine], chain: .stellar) == nil)

        // Para seguir: o numero do ID, em qualquer algarismo do teclado, ou os 6 ultimos do
        // endereco, nunca o que a tela mostra do conhecido.
        #expect(AddressPoisoning.muxedIDConfirmed("7654321", address: attacker))
        #expect(AddressPoisoning.muxedIDConfirmed(" 7 654 321 ", address: attacker))
        #expect(AddressPoisoning.muxedIDConfirmed("٧٦٥٤٣٢١", address: attacker))  // arabicos orientais
        #expect(AddressPoisoning.muxedIDConfirmed("۷۶۵۴۳۲۱", address: attacker))  // persas
        #expect(AddressPoisoning.muxedIDConfirmed("७६५४३२१", address: attacker))  // devanagari
        #expect(!AddressPoisoning.muxedIDConfirmed("+7654321", address: attacker))
        #expect(!AddressPoisoning.muxedIDConfirmed("7654321²", address: attacker))
        #expect(!AddressPoisoning.muxedIDConfirmed("1234567", address: attacker))
        #expect(!AddressPoisoning.muxedIDConfirmed(String(mine.suffix(6)), address: attacker))
        #expect(!AddressPoisoning.muxedIDConfirmed("", address: attacker))
        #expect(!AddressPoisoning.muxedIDConfirmed("0", address: base))
        #expect(AddressPoisoning.idConfirmed("٠٠١٢", id: 12) && !AddressPoisoning.idConfirmed("12a", id: 12))
        // Os 6 ultimos do colado tambem valem, mas so porque nao estao na tela: o trecho
        // escondido do ID vai ate o fim do endereco e os cobre, e o campo do endereco colado
        // some enquanto o desafio esta na tela (SendModel.challengeOnScreen, no App).
        #expect(AddressPoisoning.muxedIDConfirmed(String(attacker.suffix(6)).lowercased(), address: attacker))
        let hidden = try #require(AddressPoisoning.muxedIDSegment(attacker))
        #expect(hidden.start + hidden.length == attacker.count && hidden.length >= 6)

        // Sem historico, o trecho escondido de um M e o fim (o meio e a chave, igual nos dois).
        let middle = try #require(AddressPoisoning.middleSegment(attacker))
        #expect(middle.text(in: attacker) == middle.text(in: mine))
        let blind = try #require(AddressPoisoning.blindSegment(attacker, chain: .stellar))
        #expect(blind == AddressPoisoning.Segment(start: 63, length: 6))
        #expect(blind.text(in: attacker) != blind.text(in: mine))
        #expect(AddressPoisoning.blindSegment(base, chain: .stellar) == AddressPoisoning.middleSegment(base))
        #expect(AddressPoisoning.blindSegment("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", chain: bitcoin)
            == AddressPoisoning.middleSegment("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"))

        // O trecho do ID: do caractere 53 ao fim. Antes dele, os dois sao iguais.
        let segment = try #require(AddressPoisoning.muxedIDSegment(attacker))
        #expect(segment == AddressPoisoning.Segment(start: 53, length: 16))
        #expect(attacker.prefix(53) == mine.prefix(53))
        #expect(segment.text(in: attacker) != segment.text(in: mine))
        #expect(AddressPoisoning.muxedIDSegment(mine) == segment)
        #expect(AddressPoisoning.muxedIDSegment(base) == nil)
        #expect(AddressPoisoning.muxedIDSegment("M123") == nil)
    }

    // MARK: B-9: NEAR com nome

    @Test("NEAR: o registro do nome (.near, .tg) sai do corpo, e a ponta so vale entre implicitas")
    func nearNames() {
        // Os registros que o app reconhece como da NEAR sao os que saem do corpo.
        #expect(NEARAccountID.registrySuffixes == [".near", ".tg"])
        #expect(AddressPoisoning.bodySegment("alexis-exchange.near", chain: .near) == AddressPoisoning.Segment(start: 0, length: 15))
        #expect(AddressPoisoning.body("app_1.alice.near", chain: .near) == "app_1.alice")
        #expect(AddressPoisoning.body("hot-wallet-user.tg", chain: .near) == "hot-wallet-user")
        #expect(AddressPoisoning.body("near", chain: .near) == "near")

        // Falsos positivos que deixam de acontecer: o ".near" (ou o ".tg") era a ponta do
        // fim, e somava com o comeco do nome.
        #expect(AddressPoisoning.lookalike("alexis-exchange.near", among: ["alexander-wallet.near"], chain: .near) == nil)
        #expect(AddressPoisoning.lookalike("bob-savings-account.tg", among: ["bob-trading-desk.tg"], chain: .near) == nil)
        // Nome de 64 letras nao e conta implicita: 5 iguais no fim nao bastam. Pelo
        // tamanho, antes, bastavam.
        let longName = String(repeating: "q", count: 59) + "54321"
        let otherName = String(repeating: "w", count: 59) + "54321"
        #expect(longName.count == 64 && NEARAccountID.parse(longName).map(\.kind) == .success(.named))
        #expect(AddressPoisoning.lookalike(otherName, among: [longName], chain: .near) == nil)

        // O sosia de conta implicita continua marcado, com 5 numa ponta (hexadecimal).
        let implicit = String(repeating: "1", count: 59) + "a5c3e"
        #expect(AddressPoisoning.lookalike(String(repeating: "7", count: 59) + "a5c3e", among: [implicit], chain: .near) == implicit)
        #expect(AddressPoisoning.lookalike(String(repeating: "7", count: 60) + "5c3e", among: [implicit], chain: .near) == nil)
        #expect(AddressPoisoning.lookalike("2b9f" + String(repeating: "0", count: 56) + "c3e1", among: ["2b9f" + String(repeating: "d", count: 56) + "c3e1"], chain: .near) != nil)
        // Nome parecido continua parecido pelas duas pontas do nome; o mesmo nome em outro
        // registro tambem, e o trecho do desafio cai no registro.
        #expect(AddressPoisoning.lookalike("alice-wellet.near", among: ["alice-wallet.near"], chain: .near) == "alice-wallet.near")
        #expect(AddressPoisoning.lookalike("binance-hot-wallet.tg", among: ["binance-hot-wallet.near"], chain: .near) == "binance-hot-wallet.near")
        let segment = AddressPoisoning.differingSegment("binance-hot-wallet.tg", from: "binance-hot-wallet.near", chain: .near)
        #expect(segment?.text(in: "binance-hot-wallet.tg") == "let.tg")
        // A mesma conta nao e parecida com ela mesma.
        #expect(AddressPoisoning.lookalike("binance-hot-wallet.near", among: ["binance-hot-wallet.near"], chain: .near) == nil)
    }

    @Test("NEAR: nome que imita outro nome, ou o comeco de uma implicita, continua marcado")
    func nearNameMimics() {
        // O nome feito dos 59 primeiros hex de uma implicita, mais ".near": entre nome e
        // implicita, a ponta so com 5 vale sobre o corpo.
        let implicit = NEARAccountTests.implicit
        let mimic = String(implicit.prefix(59)) + ".near"
        #expect(NEARAccountID.parse(mimic).map(\.kind) == .success(.named))
        #expect(AddressPoisoning.lookalike(mimic, among: [implicit], chain: .near) == implicit)
        #expect(AddressPoisoning.lookalike(implicit, among: [mimic], chain: .near) == mimic)
        // Um nome de 64 que troca uma letra da implicita por uma que nao e hex.
        for fake in ["g" + implicit.dropFirst(), "9g" + implicit.dropFirst(2), String(implicit.dropLast()) + "g"] {
            #expect(AddressPoisoning.lookalike(fake, among: [implicit], chain: .near) == implicit, "\(fake)")
        }
        // Nomes que imitam um nome: uma ou duas edicoes, ou o nome inteiro com algo no fim.
        let hot = "coinbase-hot-wallet.near"
        for fake in ["coinbase-hot-wallets.near", "coinbase-hot-wallet1.near", "coinbase-hot-wa11et.near", "c0inbase-hot-wallet.near",
                     "coinbase-hot-walet.near", "xcoinbase-hot-wallet.near", "coinbase-hot-wallet-tg.near", "coinbase-hot-wallet.tg"] {
            #expect(AddressPoisoning.lookalike(fake, among: [hot], chain: .near) == hot, "\(fake)")
        }
        #expect(AddressPoisoning.lookalike("binance-deposit-02.near", among: ["binance-deposit-01.near"], chain: .near) == "binance-deposit-01.near")
        #expect(AddressPoisoning.lookalike("binance-hot.near", among: ["binance-hot-wallet.near"], chain: .near) == "binance-hot-wallet.near")
        // E os falsos positivos que o registro tirou continuam fora.
        #expect(AddressPoisoning.lookalike("alexis-exchange.near", among: ["alexander-wallet.near"], chain: .near) == nil)
        #expect(AddressPoisoning.lookalike("bob-savings-account.tg", among: ["bob-trading-desk.tg"], chain: .near) == nil)
        #expect(AddressPoisoning.lookalike("someone-else-wallet.near", among: ["my-own-main-wallet.near"], chain: .near) == nil)
        #expect(AddressPoisoning.lookalike("alice-savings.near", among: ["alice-spending.near"], chain: .near) == nil)
        // Distancia de edicao, com limite.
        #expect(AddressPoisoning.editDistance("coinbase-hot-wallet", "coinbase-hot-wa11et", limit: 2) == 2)
        #expect(AddressPoisoning.editDistance("wallet", "wallets", limit: 2) == 1)
        #expect(AddressPoisoning.editDistance("abc", "abc", limit: 2) == 0)
        #expect(AddressPoisoning.editDistance("alexis-exchange", "alexander-wallet", limit: 2) == 3)
    }

    /// Tres trocas ou mais por sosias visuais (0 por o, 1 por l, rn por m...) escapavam da
    /// distancia de edicao. Com o nome dobrado como o olho le, deixam de escapar.
    ///
    /// Falso positivo nome contra nome, medido em 16/10/2026 com as amostras do revisor
    /// (contas com nome de 16 caracteres ou mais, todos os pares, por `lookalike`):
    ///
    ///     amostra                          nomes      pares    marcados   por par
    ///     contas reais da mainnet           319      50.721       59      1,2e-3
    ///     nomes plausiveis (sinteticos)    2404   2.888.406     2124      7,4e-4
    ///
    /// A dobra visual nao acrescenta nenhum par nas contas reais e 6 nos plausiveis
    /// (2,1e-6 por par), como "larissa_clark" e "larissa_davis" (o "cl" lido como "d").
    /// Dobrando tambem 2, 6, 8 e 9, eram 13; com o "_" ainda, 120.
    /// Quase todo o resto vem das duas pontas iguais, que ja valiam no main: nomes da NEAR
    /// repetem comeco e fim ("...-wallet", "alex...") por desenho.
    @Test("NEAR: sosias visuais em tres trocas ou mais tambem sao marcados")
    func nearVisualMimics() {
        #expect(AddressPoisoning.visualFold("c0inbase-h0t-wa11et") == AddressPoisoning.visualFold("coinbase-hot-wallet"))
        #expect(AddressPoisoning.visualFold("bitflnex-rnain") == "bltflnex-maln")
        #expect(AddressPoisoning.visualFold("vvallet_cl") == "wallet_d")
        let hot = "coinbase-hot-wallet.near"
        for fake in ["coinbase-h0t-wa11et.near", "c0inbase-h0t-wa11et.near", "colnbase-hot-wa1let.near", "c0lnbase-h0t-vva11et.near"] {
            #expect(AddressPoisoning.lookalike(fake, among: [hot], chain: .near) == hot, "\(fake)")
        }
        #expect(AddressPoisoning.lookalike("binanse-dep0sit-07.near", among: ["binance-deposit-01.near"], chain: .near) == "binance-deposit-01.near")
        #expect(AddressPoisoning.lookalike("bitflnex-rnain-acct.near", among: ["bitfinex-main-acct.near"], chain: .near) == "bitfinex-main-acct.near")
        #expect(AddressPoisoning.lookalike("kraken-dep0slt-acct5.near", among: ["kraken-deposit-accts.near"], chain: .near) == "kraken-deposit-accts.near")
        // Nomes diferentes de verdade continuam sem marca.
        #expect(AddressPoisoning.lookalike("alexis-exchange.near", among: ["alexander-wallet.near"], chain: .near) == nil)
        #expect(AddressPoisoning.lookalike("anna-oliveira-01.near", among: ["maria-ferreira-01.near"], chain: .near) == nil)
        #expect(AddressPoisoning.lookalike("ahmed-2265-vault.near", among: ["ahmed-4246-vault.near"], chain: .near) != nil)  // duas pontas, como no main
        #expect(AddressPoisoning.lookalike("camila-5948.near", among: ["camila_9998.near"], chain: .near) == nil)
    }

    /// Os pares marcados entre todos os pares de `addresses`. So pode marcar o par com 4 ou
    /// mais caracteres iguais numa ponta do corpo: a regra de ponta so pede 4 ou 5, e a das
    /// duas pontas (3 e 3, com 7 no total) tem uma delas com 4. Esses pares saem de baldes
    /// pelos 4 primeiros e pelos 4 ultimos do corpo, e so eles passam por `lookalike`; o
    /// resto conta no total, sem marcar. A regra do stake da Cardano pede o mesmo stake,
    /// que bytes ao acaso nao repetem, e a dos nomes da NEAR so vale entre dois nomes (as
    /// contas da NEAR aqui sao implicitas).
    static func falsePositives(_ addresses: [String], chain: Chain) -> (flagged: Int, pairs: Int) {
        let n = addresses.count
        var buckets: [String: [Int]] = [:]
        for (index, address) in addresses.enumerated() {
            let body = AddressPoisoning.body(address, chain: chain)
            buckets["<" + body.prefix(4), default: []].append(index)
            buckets[">" + body.suffix(4), default: []].append(index)
        }
        var candidates = Set<Int>()
        for members in buckets.values where members.count > 1 {
            for a in 0..<members.count {
                for b in (a + 1)..<members.count { candidates.insert(members[a] * n + members[b]) }
            }
        }
        let flagged = candidates.filter { pair in
            AddressPoisoning.lookalike(addresses[pair / n], among: [addresses[pair % n]], chain: chain) != nil
        }.count
        return (flagged, n * (n - 1) / 2)
    }
}

/// SplitMix64: os mesmos enderecos "ao acaso" a cada execucao do teste.
struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func bytes(_ count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        while out.count < count {
            var value = next()
            for _ in 0..<min(8, count - out.count) {
                out.append(UInt8(truncatingIfNeeded: value))
                value >>= 8
            }
        }
        return out
    }
}
