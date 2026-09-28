import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburCore
@testable import EscaliburKeys

/// Da frase ao endereco da Cardano contra vetores publicados por tres fontes:
/// - CIP-3 (cardano-foundation/CIPs, `CIP-0003/Icarus.md`, "Test vectors"): a chave mestra
///   Icarus, com e sem 25a palavra;
/// - wallet-core da Trust Wallet (`tests/chains/Cardano/AddressTests.cpp`,
///   `MnemonicToAddressV3`): chaves de pagamento e de stake em m/1852'/1815'/0'/0/0 e
///   m/1852'/1815'/0'/2/0, e os enderecos base de tres indices e de outra frase;
/// - CIP-19 (`CIP-0019/README.md`, "Test Vectors"): a chave de pagamento
///   `addr_vk1w0l2sr2...` e a de m/1852'/1815'/0'/0/0 da frase "test walk nut ...".
/// Se um destes quebrar, a mesma frase abriria outra conta aqui.
@Suite("Cardano a partir da frase")
struct CardanoDerivationTests {
    static let cip3Phrase = "eight country switch draw meat scout mystery blade tip drift useless good keep usage title"
    static let costDash = "cost dash dress stove morning robust group affair stomach vacant route volume yellow salute laugh"

    static func secret(_ phrase: String, passphrase: String? = nil) throws -> WalletSecret {
        let pass = passphrase.map { text -> SecureBytes in
            let bytes = SecureBytes(capacity: max(text.utf8.count, 1))
            bytes.replaceAll(with: Array(text.utf8))
            return bytes
        }
        return try WalletSecret.from(phrase: BIP39.canonical(phrase), language: .english, passphrase: pass)
    }

    static func master(_ phrase: String, passphrase: String? = nil) throws -> CardanoKey {
        let secret = try secret(phrase, passphrase: passphrase)
        defer { secret.wipe() }
        return try CardanoKey.icarusMaster(entropy: secret.entropy, passphrase: secret.passphrase)
    }

    @Test("CIP-3: chave mestra Icarus, sem e com 25a palavra")
    func cip3() throws {
        let plain = try Self.master(Self.cip3Phrase)
        defer { plain.wipe() }
        let a = plain.hexForTesting()
        #expect(a.kL + a.kR + a.chainCode == "c065afd2832cd8b087c4d9ab7011f481ee1e0721e78ea5dd609f3ab3f156d245d176bd8fd4ec60b4731c3918a2a72a0226c0cd119ec35b47e4d55884667f552a23f7fdcd4a10c6cd2c7393ac61d877873e248f417634aa3d812af327ffe9d620")

        let withFoo = try Self.master(Self.cip3Phrase, passphrase: "foo")
        defer { withFoo.wipe() }
        let b = withFoo.hexForTesting()
        #expect(b.kL + b.kR + b.chainCode == "70531039904019351e1afb361cd1b312a4d0565d4ff9f8062d38acf4b15cce41d7b5738d9c893feea55512a3004acb0d222c35d3e3d5cde943a15a9824cbac59443cf67e589614076ba01e354b1a432e0e6db3b59e37fc56b5fb0222970a010e")
    }

    @Test("wallet-core: chaves de pagamento e de stake, e o endereco base")
    func walletCore() throws {
        let master = try Self.master(Self.costDash)
        defer { master.wipe() }
        let payment = try master.derive(DerivationPath("m/1852'/1815'/0'/0/0")!)
        let stake = try master.derive(DerivationPath("m/1852'/1815'/0'/2/0")!)
        defer { payment.wipe(); stake.wipe() }
        let p = payment.hexForTesting()
        #expect(p.kL == "e8c8c5b2df13f3abed4e6b1609c808e08ff959d7e6fc3d849e3f2880550b5744")
        #expect(p.kR == "37aa559095324d78459b9bb2da069da32337e1cc5da78f48e1bd084670107f31")
        #expect(p.chainCode == "10f3245ddf9132ecef98c670272ef39c03a232107733d4a1d28cb53318df26fa")
        let s = stake.hexForTesting()
        #expect(s.kL == "e0d152bb611cb9ff34e945e4ff627e6fba81da687a601a879759cd76530b5744")
        #expect(s.kR == "424db69a75edd4780a5fbc05d1a3c84ac4166ff8e424808481dd8e77627ce5f5")
        #expect(s.chainCode == "bf2eea84515a4e16c4ff06c92381822d910b5cbf9e9c144e1fb76a6291af7276")
        #expect(Hex.encode(try payment.publicKey()) == "fafa7eb4146220db67156a03a5f7a79c666df83eb31abbfbe77c85e06d40da31")
        #expect(Hex.encode(try stake.publicKey()) == "f4b8d5201961e68f2e177ba594101f513ee70fe70a41324e8ea8eb787ffda6f4")

        let stakeKey = try stake.publicKey()
        let expected = [
            "addr1qxxe304qg9py8hyyqu8evfj4wln7dnms943wsugpdzzsxnkvvjljtzuwxvx0pnwelkcruy95ujkq3aw6rl0vvg32x35qc92xkq",
            "addr1q9068st87h22h3l6w6t5evnlm067rag94llqya2hkjrsd3wvvjljtzuwxvx0pnwelkcruy95ujkq3aw6rl0vvg32x35qpmxzjt",
            "addr1qxteqxsgxrs4he9d28lh70qu7qfz7saj6dmxwsqyle2yp3xvvjljtzuwxvx0pnwelkcruy95ujkq3aw6rl0vvg32x35quehtx3",
        ]
        for (index, address) in expected.enumerated() {
            let key = try master.derive(DerivationPath("m/1852'/1815'/0'/0/\(index)")!)
            defer { key.wipe() }
            #expect(try CardanoAddress.base(paymentKey: key.publicKey(), stakeKey: stakeKey) == address)
        }
    }

    @Test("A conta da carteira: caminho CIP-1852, endereco base, chave de pagamento")
    func accountDeriver() throws {
        let vectors = [
            (Self.costDash, "addr1qxxe304qg9py8hyyqu8evfj4wln7dnms943wsugpdzzsxnkvvjljtzuwxvx0pnwelkcruy95ujkq3aw6rl0vvg32x35qc92xkq"),
            // wallet-core, mesmo arquivo: mnemonicALDemo (12 palavras).
            ("civil void tool perfect avocado sweet immense fluid arrow aerobic boil flash",
             "addr1q94zzrtl32tjp8j96auatnhxd2y35fnk6wuxqvqm9364vp9spdkjdsmyfhvfagjzh4uzp9zs6p5djw89jac2g0ujs2eqsuy7pu"),
        ]
        #expect(DefaultPaths.path(for: .cardano).description == "m/1852'/1815'/0'/0/0")
        #expect(DefaultPaths.path(for: .cardano, account: 3).description == "m/1852'/1815'/3'/0/0")
        for (phrase, address) in vectors {
            let secret = try Self.secret(phrase)
            defer { secret.wipe() }
            let (accounts, _) = try AccountDeriver.derive(secret, chains: [.cardano])
            let account = try #require(accounts.first)
            #expect(account.chainID == "cardano")
            #expect(account.address == address)
            #expect(account.path == DerivationPath("m/1852'/1815'/0'/0/0"))
            guard case .success(let parsed) = CardanoAddress.parse(account.address) else { Issue.record("endereco"); continue }
            #expect(parsed.paymentHash == CardanoAddress.keyHash(account.publicKey))
        }
    }

    @Test("CIP-19: a chave de pagamento dos vetores e a da frase test walk")
    func cip19PaymentKey() throws {
        let master = try Self.master("test walk nut penalty hip pave soap entry language right filter choice")
        defer { master.wipe() }
        let payment = try master.derive(DerivationPath("m/1852'/1815'/0'/0/0")!)
        defer { payment.wipe() }
        // addr_vk1w0l2sr2zgfm26ztc6nl9xy8ghsk5sh6ldwemlpmp9xylzy4dtf7st80zhd em bytes.
        #expect(Hex.encode(try payment.publicKey()) == "73fea80d424276ad0978d4fe5310e8bc2d485f5f6bb3bf87612989f112ad5a7d")
    }

    @Test("Assinador: plano da Cardano assinado com a chave Icarus, transacao que verifica")
    func signer() throws {
        let store = MemoryStore()
        let vault = WalletVault(store: store)
        let rk = try SecureBytes.random(count: 32)
        let keep = rk.withUnsafeBytes { Array($0) }
        let id = UUID()
        let secret = try Self.secret(Self.costDash)
        try vault.save(secret, walletID: id, rk: rk)
        let (accounts, _) = try AccountDeriver.derive(secret, chains: [.cardano])
        let account = try #require(accounts.first { $0.chainID == "cardano" })

        let now = Date()
        let slot = UInt64(Int64(now.timeIntervalSince1970) - 1_591_566_291)
        let state = CardanoSpendState(
            utxos: [CardanoUTXO(transactionID: String(repeating: "ab", count: 32), index: 1, lovelace: 10_000_000, hasTokens: false, hasReferenceScript: false)],
            parameters: CardanoProtocolParameters(minFeeA: 44, minFeeB: 155_381, coinsPerUTxOByte: 4_310, maxTxSize: 16_384),
            tipSlot: slot
        )
        let plan = try CardanoPlanner.planSend(
            walletID: id, source: CardanoSource(path: account.path, publicKey: account.publicKey, address: account.address),
            to: "addr1q94zzrtl32tjp8j96auatnhxd2y35fnk6wuxqvqm9364vp9spdkjdsmyfhvfagjzh4uzp9zs6p5djw89jac2g0ujs2eqsuy7pu",
            amount: 2_000_000, state: state, now: now
        )
        let restored = SecureBytes(capacity: 32)
        restored.replaceAll(with: keep)
        let signed = try Signer.sign(plan, rootKey: restored, vault: vault)
        let transaction = try #require(signed.first)
        let parsed = try CardanoSignedTransaction.parse(transaction.raw)
        #expect(parsed.signaturesVerify)
        #expect(parsed.witnesses.first?.publicKey == account.publicKey)
        #expect(transaction.id == Hex.encode(parsed.body.hash))
        #expect(transaction.encoded == Hex.encode(transaction.raw))

        // O caminho de outra conta com a chave desta: nada e assinado.
        let wrong = try CardanoPlanner.planSend(
            walletID: id, source: CardanoSource(path: DerivationPath("m/1852'/1815'/1'/0/0")!, publicKey: account.publicKey, address: account.address),
            to: "addr1q94zzrtl32tjp8j96auatnhxd2y35fnk6wuxqvqm9364vp9spdkjdsmyfhvfagjzh4uzp9zs6p5djw89jac2g0ujs2eqsuy7pu",
            amount: 2_000_000, state: state, now: now
        )
        let again = SecureBytes(capacity: 32)
        again.replaceAll(with: keep)
        #expect(throws: Signer.Failure.unexpectedKey) { try Signer.sign(wrong, rootKey: again, vault: vault) }
    }
}
