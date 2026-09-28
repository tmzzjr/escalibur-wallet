import Foundation
import Testing
@testable import EscaliburKeys
import EscaliburChains
import EscaliburCore

/// Da frase ao endereco da Polkadot contra o vetor do wallet-core da Trust Wallet
/// (`swift/Tests/CoinAddressDerivationTests.swift`, caso `.polkadot`): SLIP-10 Ed25519 em
/// m/44'/354'/0'/0'/0'. Se este quebrar, a mesma frase abriria outra conta aqui e na
/// Trust Wallet.
///
/// A mesma frase NAO abre a mesma conta na Ledger nem nas carteiras sr25519. Conferido com
/// o polkadot-js 17 para a frase deste teste: a Ledger (app da Zondax,
/// `os_derive_bip32_with_seed_no_throw(HDW_NORMAL, CX_CURVE_Ed25519, ...)`, a derivacao
/// BIP32-Ed25519 que o `hdLedger` reproduz) da 14Gr3Rp3CaH6iA3nF3nDWeyjbYb7vdBSZExD3z148T3WnZh9,
/// e o sr25519 da Polkadot.js, da Nova e da Talisman da 16FUHt4KjtXGR8emH6KJo42ZFCmPxgq6KMvzLP3GeBt24gH3.
@Suite("Polkadot a partir da frase")
struct PolkadotDerivationTests {
    static let phrase = "shoot island position soft burden budget tooth cruel issue economy destroy above"
    static let address = "13nN6BGAoJwd7Nw1XxeBCx5YcBXuYnL94Mh7i3xBprqVSsFk"

    @Test("Vetor do wallet-core: caminho padrao m/44'/354'/0'/0'/0'")
    func trustWalletVector() throws {
        #expect(DefaultPaths.path(for: .polkadot).description == "m/44'/354'/0'/0'/0'")
        #expect(try AddressVectorTests.address(Self.phrase, .polkadot) == Self.address)
        // Conta 1 e a frase "abandon ... about", pela mesma derivacao numa implementacao
        // independente (SLIP-10 com o HMAC do node:crypto, conferida contra o vetor acima).
        #expect(try AddressVectorTests.address(Self.phrase, .polkadot, path: "m/44'/354'/1'/0'/0'") == "12DcRt3tBLbzCqnDJPF8HMxXF39B1wJ7dt87kGPcC8St8fHT")
        #expect(try AddressVectorTests.address(AddressVectorTests.abandon, .polkadot) == "14E9StbjYhJiAfsNMEcq5tETq79Q6EqaGyebdziY214hNWDH")
    }

    @Test("A conta da carteira nova sai do mesmo caminho, e a chave da o endereco")
    func accountDeriver() throws {
        let secret = try WalletSecret.from(phrase: BIP39.canonical(Self.phrase), language: .english)
        defer { secret.wipe() }
        let (accounts, _) = try AccountDeriver.derive(secret, chains: [.polkadot])
        let account = try #require(accounts.first)
        #expect(account.address == Self.address)
        #expect(account.path == DerivationPath("m/44'/354'/0'/0'/0'"))
        #expect(PolkadotAddress(accountID: account.publicKey)?.ss58 == account.address)
    }

    @Test("Assinador: plano da Polkadot assinado com a chave SLIP-10, extrinsic que verifica")
    func signer() throws {
        let vault = WalletVault(store: MemoryStore())
        let rk = try SecureBytes.random(count: 32)
        let keep = rk.withUnsafeBytes { Array($0) }
        let id = UUID()
        let secret = try WalletSecret.from(phrase: BIP39.canonical(Self.phrase), language: .english)
        try vault.save(secret, walletID: id, rk: rk)
        let (accounts, _) = try AccountDeriver.derive(secret, chains: [.polkadot])
        let account = try #require(accounts.first)
        let state = PolkadotChainState(
            checkpoint: PolkadotCheckpoint(number: 21_173_079, hash: [UInt8](repeating: 9, count: 32)),
            runtime: PolkadotRuntimeState(specName: "statemint", specVersion: 2_005_000, transactionVersion: 15, genesisHash: PolkadotRuntime.genesisHash),
            sender: PolkadotAccountInfo(nonce: 2, free: 50_000_000_000), destination: PolkadotAccountInfo(nonce: 0, free: 10_000_000_000),
            fee: 8_808_355
        )
        let destination = "15oF4uVJwmo4TdGW7VfQxNLavjCXviqxT9S1MgbjMNHr6Sp5"
        let plan = try PolkadotPlanner.planSend(
            walletID: id, owner: PolkadotOwner(path: account.path, publicKey: account.publicKey), to: destination,
            amount: 10_000_000_000, state: state
        )
        let restored = SecureBytes(capacity: 32)
        restored.replaceAll(with: keep)
        let signed = try #require(try Signer.sign(plan, rootKey: restored, vault: vault).first)
        let parsed = try PolkadotSignedExtrinsic.parse(signed)
        let transfer = try #require(plan.transactions.first as? PolkadotTransfer)
        #expect(parsed.sender.ss58 == account.address && parsed.destination.ss58 == destination && parsed.nonce == 2)
        #expect(Ed25519.verify(signature: parsed.signature, message: transfer.fields.signingMessage, publicKey: account.publicKey))
        #expect(Array(signed.raw.suffix(transfer.fields.call.count)) == transfer.fields.call)

        // O caminho de outra conta com a chave desta: nada e assinado.
        let wrong = try PolkadotPlanner.planSend(
            walletID: id, owner: PolkadotOwner(path: DerivationPath("m/44'/354'/1'/0'/0'")!, publicKey: account.publicKey),
            to: destination, amount: 10_000_000_000, state: state
        )
        let again = SecureBytes(capacity: 32)
        again.replaceAll(with: keep)
        #expect(throws: Signer.Failure.unexpectedKey) { try Signer.sign(wrong, rootKey: again, vault: vault) }
    }
}
