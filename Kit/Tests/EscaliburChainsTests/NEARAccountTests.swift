import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// Contas NEAR: as regras do `near-account-id` (validation.rs) e os casos dos testes do
/// wallet-core da Trust Wallet (tests/chains/NEAR/AccountTests.cpp e AddressTests.cpp),
/// os tipos que a carteira aceita e recusa, e a convivencia com as outras redes.
@Suite("NEAR: contas")
struct NEARAccountTests {
    static let implicit = "917b3d268d4b58f7fec1b150bd68d69be3ee5d4cc39855e341538465bb77860d"

    static func kind(_ text: String) -> NEARAccountID.Kind? {
        guard case .success(let account) = NEARAccountID.parse(text) else { return nil }
        return account.kind
    }

    @Test("Validas e invalidas, pelos vetores do wallet-core e pela gramatica da rede")
    func grammar() {
        for valid in ["9902c136629fc630416e50d4f2fef6aff867ea7e.lockup.near", "app_1.alice.near", "test-trust.vlad.near",
                      "deadbeef", "alice.near", "bob.tg", "near", "aa", "a-b_c.d-e", Self.implicit] {
            #expect(Self.kind(valid) != nil, "\(valid)")
        }
        for invalid in ["a", "!?:", "11111111111111111111111111111111222222222222222222222222222222223", "Alice.near",
                        "alice..near", ".alice", "alice.", "-alice.near", "alice_.near", "ali ce.near",
                        "EOS65QzSGJ579GPNKtZoZkChTzsxR4B48RCfiS82m2ymJR6VZCjT"] {
            #expect(Self.kind(invalid) == nil, "\(invalid)")
        }
    }

    @Test("Tipo pelo formato: implicita, com nome; Ethereum, deterministica, universal e system recusadas")
    func kinds() {
        #expect(Self.kind(Self.implicit) == .implicit)
        #expect(Self.kind("9685af3fe2dc231e5069ccff8ec6950eb961d42ebb9116a8ab9c0d38f9e45249") == .implicit)
        #expect(Self.kind("madturk.near") == .named)
        // 62 ou 63 hex nao e implicita (o wallet-core recusa como endereco): e um nome, que
        // so segue se existir.
        #expect(Self.kind(String(Self.implicit.dropLast())) == .named)
        #expect(Self.kind(String(Self.implicit.dropLast(2))) == .named)
        #expect(NEARAccountID.parse(Self.implicit.uppercased()) == .failure(.malformed))
        #expect(NEARAccountID.parse("0x9858effd232b4033e47d90003d41ec34ecaeda94") == .failure(.malformed))
        #expect(NEARAccountID.parse("0s9858effd232b4033e47d90003d41ec34ecaeda94") == .failure(.unsupportedType))
        #expect(NEARAccountID.parse("0u" + String(repeating: "a", count: 52)) == .failure(.unsupportedType))
        #expect(NEARAccountID.parse("system") == .failure(.unsupportedType))
    }

    @Test("A conta implicita e a chave publica em hex (vetor do wallet-core, NEARAddress.FromPrivateKey)")
    func implicitFromKey() throws {
        let full = try #require(Base58.bitcoin.decode("3hoMW1HvnRLSFCLZnvPzWeoGwtdHzke34B2cTHM8rhcbG3TbuLKtShTv3DvyejnXKXKBiV7YPkLeqUHN1ghnqpFv"))
        let seed = SecureBytes(capacity: 32)
        defer { seed.wipe() }
        seed.replaceAll(with: Array(full.prefix(32)))
        let key = try Ed25519.publicKey(of: seed)
        #expect(try Address.from(publicKey: key, chain: .near) == Self.implicit)
        #expect(NEARAccountID(implicitPublicKey: key)?.implicitPublicKey == key)
        #expect(throws: Address.Problem.malformed) { try Address.from(publicKey: Array(key.prefix(31)), chain: .near) }
    }

    @Test("Address.validate: espacos em volta saem, o texto fica como a rede escreve")
    func validate() {
        #expect(Address.validate("  alice.near\n", for: .near) == .success(Address.Destination(address: "alice.near", tag: nil)))
        #expect(Address.validate(Self.implicit, for: .near) == .success(Address.Destination(address: Self.implicit, tag: nil)))
        #expect(Address.validate("", for: .near) == .failure(.empty))
        #expect(Address.canonicalRecipient(" alice.near", chain: .near) == "alice.near")
        #expect(Address.sameRecipient("alice.near", "alice.near ", chain: .near))
        #expect(!Address.sameRecipient("alice.near", "alice.tg", chain: .near))
    }

    @Test("Outras redes: o endereco EVM diz Ethereum; a conta NEAR e reconhecida nas outras telas")
    func otherNetworks() {
        #expect(Address.validate("0x9858EfFD232B4033E47d90003D41EC34EcaEda94", for: .near) == .failure(.otherNetwork(.ethereum)))
        #expect(Address.validate("0x9858effd232b4033e47d90003d41ec34ecaeda94", for: .near) == .failure(.otherNetwork(.ethereum)))
        // Endereco bech32 e Cardano so tem minusculas e digitos: e nome NEAR valido pela
        // gramatica, e mesmo assim a tela diz de que rede ele e.
        #expect(Address.validate("bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu", for: .near) == .failure(.otherNetwork(.bitcoin)))
        #expect(Address.validate("ltc1qjmxnz78nmc8nq77wuxh25n2es7rzm5c2rkk4wh", for: .near) == .failure(.otherNetwork(.litecoin)))
        #expect(Address.validate("HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk", for: .near) == .failure(.otherNetwork(.solana)))
        #expect(Address.guessChain("alice.near") == .near)
        #expect(Address.guessChain("bob.tg") == .near)
        // Nome solto nao diz a rede. A conta implicita tambem nao: 64 hex sem prefixo e o
        // endereco da Sui ou da Aptos sem o 0x (SuiPlannerTests espera "malformado" ai), e
        // o 0x com 64 hex continua sem palpite.
        #expect(Address.guessChain("binance") == nil)
        #expect(Address.guessChain(Self.implicit) == nil)
        #expect(Address.guessChain("0x" + Self.implicit) == nil)
        for chain in [Chain.ethereum, .bitcoin, .solana, .sui, .ton, .xrpl, .stellar, .tron, .cardano, .polkadot] {
            #expect(Address.validate(Self.implicit, for: chain) == .failure(.malformed), "\(chain.id)")
            #expect(Address.validate("alice.near", for: chain) == .failure(.otherNetwork(.near)), "\(chain.id)")
        }
        // Os enderecos das outras redes continuam com o palpite de antes.
        #expect(Address.guessChain("0x9858EfFD232B4033E47d90003D41EC34EcaEda94") == .ethereum)
        #expect(Address.guessChain("HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk") == .solana)
    }

    @Test("Envenenamento: conta implicita parecida e pega; nome curto nao tem pontas para comparar")
    func poisoning() {
        let lookalike = "917b" + String(repeating: "0", count: 56) + "860d"
        #expect(AddressPoisoning.lookalike(lookalike, among: [Self.implicit], chain: .near) == Self.implicit)
        #expect(AddressPoisoning.lookalike("alicf.near", among: ["alice.near"], chain: .near) == nil)
        #expect(AddressPoisoning.lookalike(Self.implicit, among: [Self.implicit], chain: .near) == nil)
    }

    @Test("Rede registrada: familia, curva, caminho, casas e explorador")
    func chain() {
        #expect(Chain.find("near") == .near)
        #expect(Chain.near.family.curve == .ed25519 && Chain.near.coinType == 397 && Chain.near.nativeDecimals == 24)
        #expect(Chain.near.coingeckoID == "near" && Chain.near.destinationTag == .none)
        #expect(DefaultPaths.path(for: .near).description == "m/44'/397'/0'")
        #expect(DefaultPaths.path(for: .near, account: 2).description == "m/44'/397'/2'")
        #expect(Chain.near.explorerURL(tx: "8VhtMYxX6hRaD827eaQcptC7Nw623n8FXuf17CdokwTg")?.absoluteString == "https://nearblocks.io/txns/8VhtMYxX6hRaD827eaQcptC7Nw623n8FXuf17CdokwTg")
    }
}
