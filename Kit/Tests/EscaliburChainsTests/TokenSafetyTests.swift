import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

/// Token fora da lista: o filtro de golpe, a forma da moeda custom colada pelo dono e a
/// compatibilidade do `Asset` com o cache gravado antes da origem existir. Os nomes de
/// golpe sao os que chegaram de verdade na conta publica de teste do BIP-39 ("abandon ...
/// about") na Base, na OP e na Polygon (Blockscout, 04/10/2026).
@Suite("Tokens fora da lista: filtro de golpe e moeda custom")
struct TokenSafetyTests {
    static func reasons(
        _ symbol: String, _ name: String, chain: Chain = .base, contract: String = "0x1111111111111111111111111111111111111111",
        amount: BigUInt = BigUInt(1_000_000_000_000_000_000), decimals: Int = 18
    ) -> [TokenSafety.Reason] {
        TokenSafety.reasons(
            symbol: symbol, name: name, chainID: chain.id, kind: .token(contract: contract), amount: amount, decimals: decimals,
            unsolicited: TokenSafety.arrivesUnsolicited(chain)
        )
    }

    // MARK: Filtro

    @Test("Isca de verdade: site, arroba, claim, visit, reward e emoji")
    func baitFromTheWild() {
        #expect(Self.reasons("Telegram @CheckSeedAndNancyBot", "Telegram @CheckSeedAndNancyBot").contains(.link))
        let badrp = Self.reasons("www.badrp.co ✅", "www.badrp.co ✅ Reward inside! ✅")
        #expect(badrp.contains(.link) && badrp.contains(.bait))
        #expect(Self.reasons("Airdrop: degen.gifts/?claim", "Degen", decimals: 0).contains(.link))
        #expect(Self.reasons("Claim on https://t.ly/OPT", "Optimism (OP)").contains(.link))
        #expect(Self.reasons("$Visit Reward at [ airdrop.li ]", "$30,000,000 Blastup").contains(.bait))
        #expect(Self.reasons("bridge for 14500 $POL(polbridge.vercel.a", "MATIC").contains(.bait))
        #expect(Self.reasons("RAFFLE TICKET", "@ MetaWin.to").contains(.link))
    }

    @Test("Simbolo que imita stablecoin ou moeda nativa, com letra cirilica, cifrao ou largura cheia")
    func imitation() {
        // "UЅDС" com S e C cirilicos, como chegou na Base.
        #expect(Self.reasons("UЅDС", "UЅDС TOKEN").contains(.imitation))
        #expect(Self.reasons("$USDT", "Tether").contains(.imitation))
        #expect(Self.reasons("ＵＳＤＴ", "Tether").contains(.imitation))
        #expect(Self.reasons("USD₮", "Tether USD", chain: .ton, contract: "EQAvlWFDxGF2lXm67y4yzC17wYKD9A0guwPkMs1gOsM__NOT").contains(.imitation))
        #expect(Self.reasons("ETH", "Ether").contains(.imitation))
        #expect(TokenSafety.normalizedSymbol("UЅDС") == "USDC")
        // Ponte conhecida nao e imitacao: o sufixo muda o simbolo.
        #expect(Self.reasons("USDC.e", "Bridged USDC").isEmpty)
        // O proprio USDC da lista nunca e imitacao de si mesmo.
        #expect(TokenSafety.reasons(
            symbol: "USDC", name: "USD Coin", chainID: "ethereum", kind: .token(contract: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"),
            amount: BigUInt(1_000_000), decimals: 6, unsolicited: true
        ).isEmpty)
    }

    @Test("Poeira so conta onde o token chega sem pedir")
    func dust() {
        // BUSD.e na Avalanche: 500000000 com 18 casas, 0,0000000005 unidade.
        #expect(Self.reasons("BUSD.e", "Binance USD", chain: .avalanche, amount: BigUInt(500_000_000)) == [.dust])
        #expect(Self.reasons("OpenAI", "OpenAI", amount: BigUInt(9_000_000_000_000_000_000)).isEmpty)
        // XRP Ledger e Stellar: so com linha de confianca aberta pelo dono.
        #expect(!TokenSafety.arrivesUnsolicited(.xrpl) && !TokenSafety.arrivesUnsolicited(.stellar))
        let xrpl = TokenSafety.reasons(
            symbol: "SOLO", name: "SOLO", chainID: "xrpl", kind: .issued(code: "SOLO", issuer: "rsoLo2S1kiGeCcn6hCUXVrCpGMWLrRrLZz"),
            amount: BigUInt(1), decimals: 6, unsolicited: false
        )
        #expect(xrpl.isEmpty)
    }

    @Test("Caractere invisivel e de direcao de texto")
    func hiddenCharacters() {
        #expect(Self.reasons("US\u{200B}DC", "USD Coin").contains(.hiddenCharacters))
        #expect(Self.reasons("ABC", "\u{202E}cba").contains(.hiddenCharacters))
        #expect(TokenSafety.clean("Nome\u{202E} com\nquebra  e   espacos", limit: 40) == "Nome com quebra e espacos")
        #expect(TokenSafety.clean(String(repeating: "A", count: 100), limit: 16).count == 16)
    }

    // MARK: Moeda custom

    @Test("EVM: endereco minusculo vira EIP-55; checksum errado e token da lista sao recusados")
    func customEVM() throws {
        let kind = try CustomToken.kind(chain: .ethereum, address: " 0x58bdc4310db1b19854ca9066deed7e3df4f2ec9b ")
        #expect(kind == .token(contract: "0x58bDC4310db1b19854Ca9066deEd7E3dF4F2Ec9B"))
        #expect(throws: CustomToken.Problem.invalidAddress) {
            _ = try CustomToken.kind(chain: .ethereum, address: "0x58BDC4310db1b19854Ca9066deEd7E3dF4F2Ec9B")
        }
        #expect(throws: CustomToken.Problem.invalidAddress) {
            _ = try CustomToken.kind(chain: .ethereum, address: "0x0000000000000000000000000000000000000000")
        }
        do {
            _ = try CustomToken.kind(chain: .ethereum, address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
            Issue.record("USDC da lista virou custom")
        } catch CustomToken.Problem.alreadyListed(let listed) {
            #expect(listed.symbol == "USDC" && listed.isVerified)
        }
        #expect(throws: CustomToken.Problem.unsupportedChain) { _ = try CustomToken.kind(chain: .bitcoin, address: "bc1q") }
    }

    @Test("Solana, Tron e TON: mint, contrato e mestre na forma canonica")
    func customOtherFamilies() throws {
        #expect(try CustomToken.kind(chain: .solana, address: "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263")
            == .token(contract: "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263"))
        #expect(throws: CustomToken.Problem.notAToken) {
            _ = try CustomToken.kind(chain: .solana, address: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
        }
        #expect(throws: CustomToken.Problem.invalidAddress) { _ = try CustomToken.kind(chain: .solana, address: "0x1234") }
        #expect(try CustomToken.kind(chain: .tron, address: "TQGaH1PigTUJsSbCootv52Hi92Gx2Hbmw8") == .token(contract: "TQGaH1PigTUJsSbCootv52Hi92Gx2Hbmw8"))
        #expect(throws: CustomToken.Problem.invalidAddress) { _ = try CustomToken.kind(chain: .tron, address: "TQGaH1PigTUJsSbCootv52Hi92Gx2Hbmw9") }
        // Mestre do NOT em forma crua: vira a forma amigavel que a lista usa.
        let not = try CustomToken.kind(chain: .ton, address: "0:2f956143c461769579baef2e32cc2d7bc18283f40d20bb03e432cd603ac33ffc")
        #expect(not == .token(contract: "EQAvlWFDxGF2lXm67y4yzC17wYKD9A0guwPkMs1gOsM__NOT"))
        // O USDT da TON em forma crua ainda e o da lista.
        #expect(throws: CustomToken.Problem.self) {
            _ = try CustomToken.kind(chain: .ton, address: "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe")
        }
    }

    @Test("XRP Ledger e Stellar: codigo mais emissor; XRP, codigo invalido e token da lista recusados")
    func customIssued() throws {
        #expect(try CustomToken.kind(chain: .xrpl, code: "534f4c4f00000000000000000000000000000000", issuer: "rsoLo2S1kiGeCcn6hCUXVrCpGMWLrRrLZz")
            == .issued(code: "534F4C4F00000000000000000000000000000000", issuer: "rsoLo2S1kiGeCcn6hCUXVrCpGMWLrRrLZz"))
        #expect(CustomToken.xrplSymbol("534F4C4F00000000000000000000000000000000") == "SOLO")
        #expect(throws: CustomToken.Problem.invalidCode) {
            _ = try CustomToken.kind(chain: .xrpl, code: "XRP", issuer: "rsoLo2S1kiGeCcn6hCUXVrCpGMWLrRrLZz")
        }
        #expect(throws: CustomToken.Problem.invalidAddress) {
            _ = try CustomToken.kind(chain: .xrpl, code: "USD", issuer: "rsoLo2S1kiGeCcn6hCUXVrCpGMWLrRrLZy")
        }
        #expect(throws: CustomToken.Problem.self) {
            _ = try CustomToken.kind(chain: .xrpl, code: "524C555344000000000000000000000000000000", issuer: "rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De")
        }
        #expect(try CustomToken.kind(chain: .stellar, code: "AQUA", issuer: "GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA")
            == .issued(code: "AQUA", issuer: "GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA"))
        #expect(throws: CustomToken.Problem.invalidCode) {
            _ = try CustomToken.kind(chain: .stellar, code: "MUITOLONGO1234", issuer: "GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA")
        }
        #expect(throws: CustomToken.Problem.self) {
            _ = try CustomToken.kind(chain: .stellar, code: "USDC", issuer: "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN")
        }
    }

    @Test("Envio de moeda custom: EVM, Solana e Stellar sim; Tron, TON e XRP Ledger dizem por que nao")
    func sendAvailability() {
        for chain in [Chain.ethereum, .base, .solana, .stellar] { #expect(CustomToken.sendUnavailableReason(chain) == nil) }
        for chain in [Chain.tron, .ton, .xrpl] {
            let reason = CustomToken.sendUnavailableReason(chain) ?? ""
            #expect(!reason.isEmpty && !reason.contains("—") && !reason.contains("–"))
        }
    }

    @Test("Texto ABI de name() e symbol(): string e bytes32 dos tokens antigos")
    func abiText() throws {
        let string = try #require([UInt8](hex: "0000000000000000000000000000000000000000000000000000000000000020"
            + "0000000000000000000000000000000000000000000000000000000000000003" + "4b59430000000000000000000000000000000000000000000000000000000000"))
        #expect(CustomToken.decodeABIText(string) == "KYC")
        // MKR: symbol() devolve bytes32.
        let mkr = try #require([UInt8](hex: "4d4b520000000000000000000000000000000000000000000000000000000000"))
        #expect(CustomToken.decodeABIText(mkr) == "MKR")
        #expect(CustomToken.decodeABIText([UInt8](repeating: 1, count: 40)) == nil)
    }

    // MARK: Asset

    @Test("Asset sem origem (cache antigo) decodifica como da lista; a custom vai e volta")
    func assetCompatibility() throws {
        let old = #"{"chainID":"ethereum","kind":{"native":{}},"symbol":"ETH","name":"Ether","decimals":18,"coingeckoID":"ethereum","isStablecoin":false}"#
        let decoded = try JSONDecoder().decode(Asset.self, from: Data(old.utf8))
        #expect(decoded == .native(.ethereum) && decoded.origin == nil && decoded.isVerified)
        let custom = CustomToken.asset(chain: .base, kind: .token(contract: "0x58bDC4310db1b19854Ca9066deEd7E3dF4F2Ec9B"), symbol: "USDC\u{202E}",
                                       name: "USD Coin", decimals: 6)
        #expect(custom.isCustom && custom.symbol == "USDC" && custom.coingeckoID == nil)
        #expect(try JSONDecoder().decode(Asset.self, from: JSONEncoder().encode(custom)) == custom)
        // Mesmo simbolo da lista, outra origem: nunca e o mesmo ativo.
        let listed = try #require(TokenRegistry.assets(on: .base).first { $0.symbol == "USDC" })
        #expect(custom != listed && custom.id != listed.id)
    }

    @Test("O envio de moeda custom passa pela mesma conferencia de ativo e valor")
    func intentCheck() throws {
        let custom = CustomToken.asset(chain: .ethereum, kind: .token(contract: "0x58bDC4310db1b19854Ca9066deEd7E3dF4F2Ec9B"), symbol: "ABC",
                                       name: "Abc", decimals: 6)
        let movement = PlanReview.Movement.token(.ethereum, contract: "0x58bdc4310db1b19854ca9066deed7e3df4f2ec9b", BigUInt(5))
        let review = PlanReview(kind: .send, title: "Enviar", lines: [], outgoing: movement)
        try PlanIntentCheck.send(review, asset: custom, amount: BigUInt(5), ceiling: BigUInt(5), chain: .ethereum)
        #expect(throws: PlanIntentCheck.Mismatch.wrongAmount) {
            try PlanIntentCheck.send(review, asset: custom, amount: BigUInt(6), ceiling: BigUInt(6), chain: .ethereum)
        }
        // Outro contrato com o mesmo simbolo nao passa.
        let other = CustomToken.asset(chain: .ethereum, kind: .token(contract: "0x1111111111111111111111111111111111111111"), symbol: "ABC",
                                      name: "Abc", decimals: 6)
        #expect(throws: PlanIntentCheck.Mismatch.wrongAsset) {
            try PlanIntentCheck.send(review, asset: other, amount: BigUInt(5), ceiling: BigUInt(5), chain: .ethereum)
        }
    }
}
