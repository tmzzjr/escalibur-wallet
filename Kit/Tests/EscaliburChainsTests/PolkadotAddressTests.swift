import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// SS58 contra vetores publicados: a conta //Alice do Substrate (chave publica
/// d43593c7...a27d, `subkey inspect //Alice`, nos tres formatos) e os enderecos do
/// wallet-core da Trust Wallet (`rust/tw_tests/tests/chains/polkadot/polkadot_address.rs`,
/// `tests/common/CoinAddressDerivationTests.cpp`).
@Suite("Polkadot: enderecos SS58")
struct PolkadotAddressTests {
    static let alice = [UInt8](hex: "d43593c715fdd31c61141abd04a99fd6822c8558854ccde39a5684e7a56da27d")!
    static let alicePolkadot = "15oF4uVJwmo4TdGW7VfQxNLavjCXviqxT9S1MgbjMNHr6Sp5"
    static let aliceKusama = "HNZata7iMYWmk5RvZRTiAsSDhV8366zq2YGb3tLH5Upf74F"
    static let aliceGeneric = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"

    @Test("A conta //Alice nos prefixos 0, 2 e 42")
    func aliceVectors() throws {
        #expect(PolkadotAddress(accountID: Self.alice)?.ss58 == Self.alicePolkadot)
        #expect(PolkadotAddress.encode(Self.alice, prefix: 2) == Self.aliceKusama)
        #expect(PolkadotAddress.encode(Self.alice, prefix: 42) == Self.aliceGeneric)
        #expect(try Address.from(publicKey: Self.alice, chain: .polkadot) == Self.alicePolkadot)
        guard case .success(let decoded) = PolkadotAddress.decode(Self.aliceKusama) else { Issue.record("Kusama nao decodificou"); return }
        #expect(decoded.prefix == 2 && decoded.accountID == Self.alice)
    }

    @Test("Chaves do wallet-core dao os enderecos dele")
    func trustWalletKeys() throws {
        let cases: [(seed: String, polkadot: String, kusama: String?)] = [
            ("4646464646464646464646464646464646464646464646464646464646464646",
             "16PpFrXrC6Ko3pYcyMAx6gPMp3mFFaxgyYMt4G5brkgNcSz8", "Hy8mqcexg5FMwMYnQvzrUvD723qMxDjMRU9HdNCnTsMAypY"),
            ("70a794d4f1019c3ce002f33062f45029c4f930a56b3d20ec477f7668c6bbc37f",
             "14Ztd3KJDaB9xyJtRkREtSZDdhLSbm7UUKt8Z7AwSv7q85G2", nil),
        ]
        for item in cases {
            let seed = SecureBytes(capacity: 32)
            defer { seed.wipe() }
            seed.replaceAll(with: [UInt8](hex: item.seed)!)
            let key = try Ed25519.publicKey(of: seed)
            #expect(try Address.from(publicKey: key, chain: .polkadot) == item.polkadot)
            if let kusama = item.kusama { #expect(PolkadotAddress.encode(key, prefix: 2) == kusama) }
        }
    }

    @Test("Validos: ed25519, sr25519 e prefixo de dois bytes lido")
    func valid() {
        for text in ["12dyy3fArMPDXLsnRtapTqZsC2KCEimeqs1dop4AEERaKC6x", "15KRsCq9LLNmCxNFhGk55s5bEyazKefunDxUH24GFZwsTxyu",
                     "15AeCjMpcSt3Fwa47jJBd7JzQ395Kr2cuyF5Zp4UBf1g9ony", Self.alicePolkadot] {
            #expect(Address.validate(text, for: .polkadot) == .success(Address.Destination(address: text, tag: nil)))
        }
        guard case .success(let decoded) = PolkadotAddress.decode("cEYtw6AVMB27hFUs4gVukajLM7GqxwxUfJkbPY3rNToHMcCgb") else {
            Issue.record("prefixo de dois bytes nao decodificou")
            return
        }
        #expect(decoded.prefix == 64)
        #expect(Address.validate("  \(Self.alicePolkadot)\n", for: .polkadot) == .success(Address.Destination(address: Self.alicePolkadot, tag: nil)))
    }

    @Test("Outras redes do ecossistema sao recusadas, com o prefixo dito")
    func otherPrefixes() {
        for text in ["FHKAe66mnbk8ke8zVWE9hFVFrJN1mprFPVmD5rrevotkcDZ", "EJ5UJ12GShfh7EWrcNZFLiYU79oogdtXFUuDDZzk7Wb2vCe", Self.aliceKusama] {
            #expect(Address.validate(text, for: .polkadot) == .failure(.malformed))
            #expect(PolkadotAddress.foreignPrefix(text) == 2)
        }
        #expect(Address.validate(Self.aliceGeneric, for: .polkadot) == .failure(.malformed))
        #expect(Address.validate("5FqqU2rytGPhcwQosKRtW1E3ha6BJKAjHgtcodh71dSyXhoZ", for: .polkadot) == .failure(.malformed))
        #expect(PolkadotAddress.foreignPrefix(Self.aliceGeneric) == 42)
        #expect(PolkadotAddress.foreignPrefix(Self.alicePolkadot) == nil)
    }

    @Test("Checksum, texto cortado e endereco de outra rede")
    func invalid() {
        #expect(Address.validate("", for: .polkadot) == .failure(.empty))
        // Uma letra trocada no meio: o base58 continua valido, o checksum nao.
        var chars = Array(Self.alicePolkadot)
        chars[20] = chars[20] == "a" ? "b" : "a"
        #expect(Address.validate(String(chars), for: .polkadot) == .failure(.badChecksum))
        #expect(Address.validate(String(Self.alicePolkadot.dropLast(3)), for: .polkadot) == .failure(.malformed))
        #expect(Address.validate("5DhgpiQ6za7k5osGUFXpKgjiLQKYYRDWmNH9eX4og9Q48huk...", for: .polkadot) == .failure(.malformed))
        #expect(Address.validate("1ES14c7qLb5CYhLMUekctxLgc1FV2Ti9DA", for: .polkadot) == .failure(.otherNetwork(.bitcoin)))
        #expect(Address.validate("0x52908400098527886E0F7030069857D2E4169EE7", for: .polkadot) == .failure(.otherNetwork(.ethereum)))
    }

    @Test("Endereco da Polkadot colado em outra rede e reconhecido")
    func guessedFromOtherChains() {
        #expect(Address.guessChain(Self.alicePolkadot) == .polkadot)
        #expect(Address.validate(Self.alicePolkadot, for: .solana) == .failure(.otherNetwork(.polkadot)))
        #expect(Address.validate(Self.alicePolkadot, for: .bitcoin) == .failure(.otherNetwork(.polkadot)))
        #expect(Address.guessChain(Self.aliceKusama) == nil)
    }

    @Test("Comparacao de destino e sosia sem o 1 do prefixo")
    func recipientAndLookalike() {
        #expect(Address.sameRecipient(Self.alicePolkadot, " \(Self.alicePolkadot) ", chain: .polkadot))
        #expect(!Address.sameRecipient(Self.alicePolkadot, "16PpFrXrC6Ko3pYcyMAx6gPMp3mFFaxgyYMt4G5brkgNcSz8", chain: .polkadot))
        #expect(AddressPoisoning.body(Self.alicePolkadot, chain: .polkadot) == String(Self.alicePolkadot.dropFirst()).lowercased())
    }

    @Test("Rede registrada: familia, curva, caminho e explorador")
    func registration() {
        let chain = Chain.polkadot
        #expect(Chain.find("polkadot") == chain)
        #expect(chain.family.curve == .ed25519 && chain.coinType == 354 && chain.nativeDecimals == 10)
        #expect(chain.coingeckoID == "polkadot" && chain.nativeSymbol == "DOT")
        #expect(DefaultPaths.path(for: chain).description == "m/44'/354'/0'/0'/0'")
        #expect(DefaultPaths.path(for: chain, account: 3).description == "m/44'/354'/3'/0'/0'")
        #expect(chain.explorerURL(tx: "0xab")?.absoluteString == "https://assethub-polkadot.subscan.io/extrinsic/0xab")
    }
}
