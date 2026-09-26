import Foundation
import Testing
@testable import EscaliburKeys
import EscaliburChains
import EscaliburCore

/// Da frase ao endereco, em cada rede, contra valores publicados por outras
/// implementacoes (BIP-84, Trust Wallet Core, SEP-0005, Phantom). Se um destes
/// quebrar, uma carteira importada aqui mostraria saldo zero em outro endereco.
@Suite("Enderecos a partir da frase")
struct AddressVectorTests {
    static let abandon = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    static func address(_ phrase: String, _ chain: Chain, path: String? = nil, passphrase: String = "") throws -> String {
        let seed = try BIP39.seed(phrase: BIP39.canonical(phrase), passphrase: passphrase)
        defer { seed.wipe() }
        let master = try HDKey.master(seed: seed, curve: chain.family.curve)
        let derivation = path.flatMap(DerivationPath.init) ?? DefaultPaths.path(for: chain)
        let key = try master.derive(derivation)
        defer { key.wipe(); master.wipe() }
        return try Address.from(publicKey: key.publicKey(), chain: chain)
    }

    @Test("Bitcoin BIP-84 (vetor do proprio BIP)")
    func bitcoin() throws {
        #expect(try Self.address(Self.abandon, .bitcoin) == "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
        #expect(try Self.address(Self.abandon, .bitcoin, path: "m/84'/0'/0'/0/1") == "bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g")
        #expect(try Self.address(Self.abandon, .bitcoin, path: "m/84'/0'/0'/1/0") == "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el")
    }

    @Test("Ethereum m/44'/60'/0'/0/0")
    func ethereum() throws {
        #expect(try Self.address(Self.abandon, .ethereum) == "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        #expect(try Self.address(Self.abandon, .base) == "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
    }

    @Test("Solana m/44'/501'/0'/0' (Phantom)")
    func solana() throws {
        #expect(try Self.address(Self.abandon, .solana) == "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
    }

    @Test("XRP Ledger m/44'/144'/0'/0/0")
    func xrpl() throws {
        #expect(try Self.address(Self.abandon, .xrpl) == "rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3")
    }

    @Test("Stellar SEP-0005, vetor 1")
    func stellar() throws {
        let phrase = "illness spike retreat truth genius clock brain pass fit cave bargain toe"
        #expect(try Self.address(phrase, .stellar) == "GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6")
        #expect(try Self.address(phrase, .stellar, path: "m/44'/148'/1'") == "GBAW5XGWORWVFE2XTJYDTLDHXTY2Q2MO73HYCGB3XMFMQ562Q2W2GJQX")
    }

    @Test("Tron m/44'/195'/0'/0/0")
    func tron() throws {
        #expect(try Self.address(Self.abandon, .tron) == "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH")
    }

    @Test("Litecoin BIP-84 e Dogecoin BIP-44")
    func litecoinDogecoin() throws {
        #expect(try Self.address(Self.abandon, .litecoin) == "ltc1qjmxnz78nmc8nq77wuxh25n2es7rzm5c2rkk4wh")
        #expect(try Self.address(Self.abandon, .dogecoin) == "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC")
    }

    @Test("Derivacao publica (xpub) bate com a privada")
    func publicDerivation() throws {
        let seed = try BIP39.seed(phrase: BIP39.canonical(Self.abandon))
        let master = try HDKey.master(seed: seed, curve: .secp256k1)
        let account = try master.derive(DerivationPath("m/84'/0'/0'")!)
        let xpub = try ExtendedPublicKey(publicKey: account.publicKey(), chainCode: account.chainCode.withUnsafeBytes { Array($0) })
        for index: UInt32 in 0..<5 {
            let viaPublic = try xpub.derive([0, index]).publicKey
            let viaPrivate = try account.derive(DerivationPath(components: [0, index])).publicKey()
            #expect(viaPublic == viaPrivate)
        }
        #expect(try Address.from(publicKey: xpub.derive([0, 0]).publicKey, chain: .bitcoin) == "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
    }

    @Test("Validacao recusa a rede errada com o motivo")
    func validation() {
        #expect(Address.validate("0x9858EfFD232B4033E47d90003D41EC34EcaEda94", for: .xrpl) == .failure(.otherNetwork(.ethereum)))
        #expect(Address.validate("0x9858efFD232B4033E47d90003D41EC34EcaEda94", for: .ethereum) == .failure(.badChecksum))
        #expect(Address.validate("0x9858effd232b4033e47d90003d41ec34ecaeda94", for: .ethereum) == .success(.init(address: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94", tag: nil)))
        #expect(Address.validate("rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3", for: .xrpl) == .success(.init(address: "rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3", tag: nil)))
        #expect(Address.validate("bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu", for: .litecoin) == .failure(.otherNetwork(.bitcoin)))
        #expect(Address.validate("bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyv", for: .bitcoin) == .failure(.badChecksum))
        // X-address das fixtures do ripple-address-codec: tag maxima embutida.
        #expect(Address.validate("XVLhHMPHU98es4dbozjVtdWzVrDjtV18pX8yuPT7y4xaEHi", for: .xrpl) == .success(.init(address: "rGWrZyQqhTp9Xu7G5Pkayo7bXjH4k4QYpf", tag: 4_294_967_295)))
        // Ida e volta com tag comum e sem tag.
        let withTag = XRPLAddress.xAddress(classic: "rGWrZyQqhTp9Xu7G5Pkayo7bXjH4k4QYpf", tag: 12345)!
        #expect(Address.validate(withTag, for: .xrpl) == .success(.init(address: "rGWrZyQqhTp9Xu7G5Pkayo7bXjH4k4QYpf", tag: 12345)))
        let noTag = XRPLAddress.xAddress(classic: "rGWrZyQqhTp9Xu7G5Pkayo7bXjH4k4QYpf", tag: nil)!
        #expect(Address.validate(noTag, for: .xrpl) == .success(.init(address: "rGWrZyQqhTp9Xu7G5Pkayo7bXjH4k4QYpf", tag: nil)))
    }
}
