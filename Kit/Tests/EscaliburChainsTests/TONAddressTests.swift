import EscaliburChains
import EscaliburCore
import Foundation
import Testing

@Suite("TON enderecos")
struct TONAddressTests {
    // trustwallet/wallet-core rust/tw_tests/tests/chains/ton/ton_address.rs: WALLET_1.
    static let raw = "0:8a8627861a5dd96c9db3ce0807b122da5ed473934ce7568a5b4b1c361cbb28ae"
    static let bounceable = "EQCKhieGGl3ZbJ2zzggHsSLaXtRzk0znVopbSxw2HLsorkdl"
    static let nonBounceable = "UQCKhieGGl3ZbJ2zzggHsSLaXtRzk0znVopbSxw2HLsorhqg"
    static let bounceableTestnet = "kQCKhieGGl3ZbJ2zzggHsSLaXtRzk0znVopbSxw2HLsorvzv"
    static let nonBounceableTestnet = "0QCKhieGGl3ZbJ2zzggHsSLaXtRzk0znVopbSxw2HLsorqEq"

    @Test("Raw e amigavel, nos dois sentidos (wallet-core ton_address.rs)")
    func conversions() throws {
        let address = try TONTestSupport.address(Self.raw)
        #expect(address.raw == Self.raw)
        #expect(address.friendly(bounceable: true) == Self.bounceable)
        #expect(address.friendly(bounceable: false) == Self.nonBounceable)
        #expect(address.friendly(bounceable: true, testnet: true) == Self.bounceableTestnet)
        #expect(address.friendly(bounceable: false, testnet: true) == Self.nonBounceableTestnet)
        for text in [Self.bounceable, Self.nonBounceable, Self.bounceableTestnet, Self.nonBounceableTestnet] {
            #expect(try TONTestSupport.address(text) == address)
        }
        let parsed = try TONAddress.parse(Self.nonBounceableTestnet).get()
        #expect(parsed.bounceable == false)
        #expect(parsed.testnet)
        #expect(try TONAddress.parse(Self.raw).get().bounceable == nil)
    }

    @Test("Validacao: raw e amigavel entram, testnet e checksum errado nao")
    func validation() {
        #expect(Address.validate(Self.raw, for: .ton) == .success(Address.Destination(address: Self.raw, tag: nil)))
        #expect(Address.validate(Self.bounceable, for: .ton) == .success(Address.Destination(address: Self.bounceable, tag: nil)))
        #expect(Address.validate(" \(Self.nonBounceable)\n", for: .ton) == .success(Address.Destination(address: Self.nonBounceable, tag: nil)))
        // Raw em maiusculas vira minusculas; masterchain e aceita.
        #expect(Address.validate(Self.raw.uppercased(), for: .ton) == .success(Address.Destination(address: Self.raw, tag: nil)))
        #expect((try? Address.validate("-1:" + String(Self.raw.dropFirst(2)), for: .ton).get()) != nil)
        // Base64 padrao (+ e /) e aceito e sai url-safe, com a mesma flag.
        // wallet-core ton_address.rs: "EQAN6Dr3vziti1Kp9D3aEFqJX4bBVfCaV57Z+9jwKTBXICv8".
        #expect(Address.validate("EQAN6Dr3vziti1Kp9D3aEFqJX4bBVfCaV57Z+9jwKTBXICv8", for: .ton)
            == .success(Address.Destination(address: "EQAN6Dr3vziti1Kp9D3aEFqJX4bBVfCaV57Z-9jwKTBXICv8", tag: nil)))

        #expect(Address.validate(Self.bounceableTestnet, for: .ton) == .failure(.unsupportedType))
        #expect(Address.validate(Self.nonBounceableTestnet, for: .ton) == .failure(.unsupportedType))
        // Ultimo caractere trocado: o CRC16 nao fecha.
        #expect(Address.validate(String(Self.bounceable.dropLast()) + "m", for: .ton) == .failure(.badChecksum))
        #expect(Address.validate(String(Self.bounceable.dropLast()), for: .ton) == .failure(.malformed))
        #expect(Address.validate("1:" + String(Self.raw.dropFirst(2)), for: .ton) == .failure(.unsupportedType))
        #expect(Address.validate("0:" + String(Self.raw.dropFirst(3)), for: .ton) == .failure(.malformed))
        #expect(Address.validate("", for: .ton) == .failure(.empty))
        // Endereco de outra rede: a mensagem diz qual.
        #expect(Address.validate("0x9858EfFD232B4033E47d90003D41EC34EcaEda94", for: .ton) == .failure(.otherNetwork(.ethereum)))
        #expect(Address.guessChain(Self.nonBounceable) == .ton)
        #expect(Address.guessChain(Self.raw) == .ton)
    }

    @Test("Endereco V4R2 da chave publica (wallet-core ton_address.rs, test_ton_address_derive)")
    func walletAddressFromKey() throws {
        let vectors: [(String, String)] = [
            ("5849481021e305dfdf9f0eaf87e07f15efec3fde8d8ed639c9fcf0bc351d998b", "UQAACKJfEIfI5vkht_w3NYk8k-OU5Xl_jq9XNmmkcPaUO-tB"),
            ("4a22d994755145e4a4ce7263bdb3a8a70e449c1fccdd299f80df862bd4dcb930", "UQA3fRa_AHKBo1Lu8QF5xm_fiCLi197NfoPbeta0VJyvKa76"),
            ("287d4c0fcc445173fe211e4ade3518c75cff7a9dd79070f54395058cdd53e485", "UQCbJ0QdlDmC0ofyCtH15PHBzrj9sMLoLjNjkgTYaxR8gn9z"),
            ("136e464280c4222a99ac34d5077a2edf11e4468a076741e495d9f31ca7939a1f", "UQAliC8yJh-Ru2uwEWgEaEV9LHEs0-c1blYr_XZe7CpEwm9D"),
            ("f15bb09a2cf37f6e6b6515be4000cdf271338c56fb1ec81848f2f1407b3a4003", "UQCeAQaIFwwjmcJkYfqGiyHo2ag7qUMMfsUi28HLWmtpA7zF"),
            ("532005268411b3b4ac85b080c8a3bc4a52600be75f758013302745ac05ac18f0", "UQDD0YS5pQSe3fgHEKd-D7qTieRxmSknlQQW6fb7IFu7ky9T"),
            ("15e5a13ec259bb4515105ba0a84ee93eaa9f56f6fdf73bf6179d1ed80b6a399c", "UQAx8JmUT4p14RUAu9gpXqmTzkQz4e3GZz8VQjqWXFDxG6-S"),
            ("9b503ff85debe95093acf0f9b057607a0a5be91cb47e2e6ec342d7825c7fafbc", "UQD91HEk-TJVublA57dgkSwgrRORj48ubEIfjEPZIjQ08oZl"),
            ("97075969876382280ff7598738b3fd2c1748f9a549dd6f5d6aa5694c21deddce", "UQBrL2lNG3ThmYbf9gaA_-tsPfdrcGy27LP0M-qg-1TpG_wR"),
            ("fbfbc640c4cd4649161a935562217f1caecf6e7f3a2818921f9ee336741a48cb", "UQAzCS7JoSiOi1BdH4nFkuvUwbBjxUzPx1AhQKwiwXAv27Xs"),
        ]
        for (seed, expected) in vectors {
            let publicKey = try TONTestSupport.publicKey(seed: seed)
            #expect(try TONAddress.walletAddress(publicKey: publicKey) == expected)
            #expect(try Address.from(publicKey: publicKey, chain: .ton) == expected)
        }
        #expect(throws: Address.Problem.malformed) { try TONAddress.walletAddress(publicKey: [1, 2, 3]) }
    }

    @Test("V4R2 e V5R1 para as mesmas chaves, iguais ao ton-core")
    func bothVersions() throws {
        // Fixtures/ton/ton-core-vectors.json (WalletContractV4 e WalletContractV5R1 do @ton/ton).
        for vector in try TONCoreVectors.load().wallets {
            let publicKey = try TONTestSupport.publicKey(seed: vector.seed)
            #expect(publicKey.hex == vector.publicKey)
            let v4 = try TONWallet(publicKey: publicKey, version: .v4r2)
            #expect(v4.address.raw == vector.v4r2.raw)
            #expect(v4.address.friendly(bounceable: true) == vector.v4r2.bounceable)
            #expect(v4.address.friendly(bounceable: false) == vector.v4r2.nonBounceable)
            #expect(v4.walletID == 698_983_191)
            let v5 = try TONWallet(publicKey: publicKey, version: .v5r1)
            #expect(v5.address.raw == vector.v5r1.raw)
            #expect(v5.address.friendly(bounceable: false) == vector.v5r1.nonBounceable)
            #expect(v5.walletID == 2_147_483_409)
        }
        // wallet-core rust/chains/tw_ton/tests/address.rs: endereco V5R1 da rede principal.
        let key = try TONTestSupport.publicKey(seed: "3570e35f54cfb843f2cfaf2b8cae7ceeb7b32225d7dbbd86f611056d74d9073e")
        #expect(try TONWallet(publicKey: key, version: .v5r1).address.friendly(bounceable: false) == "UQAU3o5-Sp1MYRpw3U7b_wmARxqI49LxiFhEoVCxpUKjTYXk")
    }

    @Test("Da frase ao endereco em m/44'/607'/0' (wallet-core tests/chains/TheOpenNetwork/TWAnyAddressTests.cpp)")
    func fromMnemonic() throws {
        let phrase = "stuff diamond cycle federal scan spread pigeon people engage teach snack grain"
        let seed = try BIP39.seed(phrase: BIP39.canonical(phrase))
        defer { seed.wipe() }
        let path = DefaultPaths.path(for: .ton)
        #expect(path.description == "m/44'/607'/0'")
        let privateKey = TONTestSupport.slip10(seed: seed.withUnsafeBytes { Array($0) }, path: path)
        let publicKey = try TONTestSupport.publicKey(seed: privateKey.hex)
        #expect(try Address.from(publicKey: publicKey, chain: .ton) == "UQDYW_1eScJVxtitoBRksvoV9cCYo4uKGWLVNIHB1JqRRyQx")
    }

    @Test("Candidatos da importacao: Trust/Tonkeeper/MyTonWallet e Ledger Live")
    func importCandidates() {
        let candidates = TONDerivationScheme.importCandidates()
        #expect(candidates.map(\.path.description) == ["m/44'/607'/0'", "m/44'/607'/0'", "m/44'/607'/0'/0'/0'/0'"])
        #expect(candidates.map(\.version) == [.v4r2, .v5r1, .v4r2])
        #expect(candidates.allSatisfy { $0.path.isFullyHardened })
        #expect(TONDerivationScheme.importCandidates(account: 2).map(\.path.description)
            == ["m/44'/607'/2'", "m/44'/607'/2'", "m/44'/607'/0'/0'/2'/0'"])
        #expect(TONWalletVersion.default == .v4r2)
    }
}
