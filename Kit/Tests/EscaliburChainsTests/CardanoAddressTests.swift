import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburCore

/// Enderecos da Cardano contra os vetores da CIP-19 (cardano-foundation/CIPs,
/// `CIP-0019/README.md`, "Test Vectors") e os do wallet-core da Trust Wallet
/// (`tests/chains/Cardano/AddressTests.cpp`, `Validation`).
@Suite("Cardano: enderecos")
struct CardanoAddressTests {
    // CIP-19: addr_vk1w0l2sr2... e stake_vk1px4j0r2... em bytes.
    static let paymentKey = "73fea80d424276ad0978d4fe5310e8bc2d485f5f6bb3bf87612989f112ad5a7d"
    static let stakeKey = "09ab278d49b7b86a055185c474c4942281ddfa05a54684c7e8a6f230625aee57"

    static let mainnet: [UInt8: String] = [
        0x0: "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x",
        0x1: "addr1z8phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gten0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgs9yc0hh",
        0x2: "addr1yx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzerkr0vd4msrxnuwnccdxlhdjar77j6lg0wypcc9uar5d2shs2z78ve",
        0x3: "addr1x8phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gt7r0vd4msrxnuwnccdxlhdjar77j6lg0wypcc9uar5d2shskhj42g",
        0x4: "addr1gx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer5pnz75xxcrzqf96k",
        0x5: "addr128phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gtupnz75xxcrtw79hu",
        0x6: "addr1vx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzers66hrl8",
        0x7: "addr1w8phkx6acpnf78fuvxn0mkew3l0fd058hzquvz7w36x4gtcyjy7wx",
    ]

    @Test("CIP-19: endereco base a partir das duas chaves")
    func baseFromKeys() throws {
        #expect(try CardanoAddress.base(paymentKey: Hex.decode(Self.paymentKey)!, stakeKey: Hex.decode(Self.stakeKey)!) == Self.mainnet[0])
        #expect(try Address.from(publicKey: Hex.decode(Self.paymentKey + Self.stakeKey)!, chain: .cardano) == Self.mainnet[0])
        #expect(throws: Address.Problem.self) { try Address.from(publicKey: Hex.decode(Self.paymentKey)!, chain: .cardano) }
    }

    @Test("CIP-19: os oito tipos da rede principal; destino so com pagamento por chave, base ou enterprise")
    func types() throws {
        for (type, text) in Self.mainnet {
            guard case .success(let address) = CardanoAddress.parse(text) else { Issue.record("tipo \(type)"); continue }
            #expect(address.type == type)
            #expect(address.networkID == 1)
            #expect(address.bech32 == text)
            let result = Address.validate(text, for: .cardano)
            if [0, 2, 6].contains(type) {
                #expect(result == .success(Address.Destination(address: text, tag: nil)), "tipo \(type)")
            } else {
                #expect(result == .failure(.unsupportedType), "tipo \(type)")
            }
        }
    }

    @Test("Stake, rede de teste e Byron: da Cardano, mas recusados como destino")
    func otherKinds() {
        let refused = [
            "stake1uyehkck0lajq8gr28t9uxnuvgcqrc6070x3k9r8048z8y5gh6ffgw",
            "addr_test1qz2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgs68faae",
            // wallet-core, MnemonicToAddressV3: endereco Byron (Icarus) de m/44'/1815'/0'/0/1.
            "Ae2tdPwUPEZ7dnds6ZyhQdmgkrDFFPSDh8jG9RAhswcXt1bRauNw5jczjpV",
        ]
        for text in refused {
            #expect(Address.validate(text, for: .cardano) == .failure(.unsupportedType), "\(text.prefix(12))")
            #expect(Address.guessChain(text)?.id == "cardano")
        }
    }

    @Test("Checksum, truncado e caixa")
    func checksum() {
        // wallet-core, Validation: o mesmo endereco sem o ultimo caractere.
        let truncated = "addr1q8043m5heeaydnvtmmkyuhe6qv5havvhsf0d26q3jygsspxlyfpyk6yqkw0yhtyvtr0flekj84u64az82cufmqn65zdsylzk2"
        #expect(Address.validate(truncated, for: .cardano) == .failure(.badChecksum))
        var swapped = Array(Self.mainnet[0]!)
        swapped[20] = swapped[20] == "q" ? "p" : "q"
        #expect(Address.validate(String(swapped), for: .cardano) == .failure(.badChecksum))
        #expect(Address.validate("", for: .cardano) == .failure(.empty))
        #expect(Address.validate("addr", for: .cardano) == .failure(.malformed))
        // Tudo maiusculo e o mesmo endereco; caixa mista e invalida no bech32.
        let upper = Self.mainnet[0]!.uppercased()
        #expect(Address.sameRecipient(upper, Self.mainnet[0]!, chain: .cardano))
        #expect(Address.canonicalRecipient(upper, chain: .cardano) == Self.mainnet[0])
    }

    @Test("Endereco colado na rede errada: cada lado diz de qual rede ele e")
    func otherNetwork() {
        let cardano = Self.mainnet[0]!
        #expect(Address.validate(cardano, for: .ethereum) == .failure(.otherNetwork(.cardano)))
        #expect(Address.validate(cardano, for: .bitcoin) == .failure(.otherNetwork(.cardano)))
        #expect(Address.validate(cardano, for: .solana) == .failure(.otherNetwork(.cardano)))
        #expect(Address.validate(cardano, for: .xrpl) == .failure(.otherNetwork(.cardano)))
        #expect(Address.validate("0x52908400098527886E0F7030069857D2E4169EE7", for: .cardano) == .failure(.otherNetwork(.ethereum)))
        #expect(Address.validate("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", for: .cardano) == .failure(.otherNetwork(.bitcoin)))
        #expect(Address.validate("GAAZI4TCR3TY5OJHCTJC2A4QSY6CJWJH5IAJTGKIN2ER7LBNVKOCCWN7", for: .cardano) == .failure(.otherNetwork(.stellar)))
        #expect(Address.guessChain(cardano)?.id == "cardano")
    }

    @Test("Envenenamento: o prefixo addr1 e o cabecalho nao contam como coincidencia")
    func poisoning() {
        let known = Self.mainnet[0]!
        #expect(AddressPoisoning.body(known, chain: .cardano) == String(known.dropFirst(6)))
        #expect(AddressPoisoning.lookalike(Self.mainnet[2]!, among: [known], chain: .cardano) == nil)
    }
}
