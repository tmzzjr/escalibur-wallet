import EscaliburChains
import EscaliburCore
import Foundation

/// O unico lugar do app onde uma chave privada assina alguma coisa.
///
/// Recebe um `SigningPlan` (que so existe se passou pela validacao da rede) e a RK
/// recem-destrancada por presenca do dono. Sincrono de ponta a ponta, sem `await`:
/// funcao assincrona guarda variaveis locais num contexto no heap que e liberado sem
/// zerar, e aqui as variaveis locais sao a seed e as chaves (docs/seguranca.md §2.9).
///
/// ```
/// rk ─► DEK ─► registro ─► frase ─► seed ─► chave de cada pedido ─► assinatura
///   cada etapa zera a anterior; a seed e as chaves somem no fim do plano
/// ```
public enum Signer {
    public enum Failure: Error, Equatable, Sendable {
        case expired
        /// A chave derivada nao e a que a transacao espera: caminho errado ou
        /// carteira errada. Nada foi assinado.
        case unexpectedKey
        /// A assinatura produzida nao verificou. Com nonce deterministico, uma
        /// assinatura defeituosa pode entregar a chave; ela nunca sai daqui.
        case verificationFailed
        case unsupportedScheme(SignatureScheme)
        /// A passphrase digitada nao e a da carteira (carteira com passphrase e "pedir a
        /// passphrase para enviar"). Nada foi assinado.
        case passphraseMismatch
    }

    /// Assina todas as transacoes do plano, na ordem. Consome e zera a RK.
    ///
    /// `passphrase`: a passphrase que o dono acabou de digitar, numa carteira com
    /// passphrase que pede a passphrase para enviar (pedido do dono, 16/10/2026). Ela e
    /// conferida com a do cofre, as duas em NFKD e em tempo constante, antes de nascer
    /// qualquer chave; nao confere, nada e assinado. O chamador continua dono do buffer.
    /// Sem valor padrao: cada chamador diz se pede a passphrase (nil so quando a carteira nao
    /// pede), e um chamador novo nao fura a regra esquecendo o parametro (revisao de 16/10/2026).
    public static func sign(_ plan: SigningPlan, rootKey rk: SecureBytes, vault: WalletVault,
                            passphrase typed: SecureBytes?) throws -> [SignedTransaction] {
        defer { rk.wipe() }
        guard !plan.isExpired() else { throw Failure.expired }

        let secret = try vault.open(walletID: plan.walletID, rk: rk)
        rk.wipe()
        defer { secret.wipe() }
        if let typed {
            // As duas em NFKD, como a conferencia da passphrase (ConfirmPassphraseView): a do
            // cofre ja e NFKD desde a criacao, a digitada vem do teclado em NFC.
            let stored = BIP39.nfkd(secret.passphrase), given = BIP39.nfkd(typed)
            defer { stored.wipe(); given.wipe() }
            guard stored.count > 0, Hash.constantTimeEqual(stored, given) else { throw Failure.passphraseMismatch }
        }
        // Cardano: a mestra Icarus sai da entropia (CIP-3), antes de o segredo ser zerado.
        let cardano = try CardanoSigning.master(for: plan, secret: secret)
        defer { cardano?.wipe() }
        let seed = try secret.seed()
        secret.wipe()
        defer { seed.wipe() }

        var masters: [Curve: HDKey] = [:]
        defer { masters.values.forEach { $0.wipe() } }

        var signed: [SignedTransaction] = []
        for transaction in plan.transactions {
            var signatures: [ProducedSignature] = []
            for request in transaction.signingRequests {
                if request.scheme == .ed25519Cardano {
                    signatures.append(try CardanoSigning.sign(request, master: cardano))
                    continue
                }
                let master: HDKey
                if let cached = masters[request.curve] {
                    master = cached
                } else {
                    master = try HDKey.master(seed: seed, curve: request.curve)
                    masters[request.curve] = master
                }
                let key = try master.derive(request.path)
                defer { key.wipe() }
                signatures.append(try sign(request, with: key))
            }
            signed.append(try transaction.assemble(with: signatures))
        }
        return signed
    }

    static func sign(_ request: SigningRequest, with key: HDKey) throws -> ProducedSignature {
        let publicKey = try key.publicKey()
        guard Hash.constantTimeEqual(publicKey, request.expectedPublicKey) else { throw Failure.unexpectedKey }

        switch request.scheme {
        case .ecdsaDER:
            let der = try Secp256k1.signDER(digest: request.payload, privateKey: key.key)
            guard Secp256k1.verifyDER(signature: der, digest: request.payload, publicKey: publicKey) else {
                throw Failure.verificationFailed
            }
            return ProducedSignature(bytes: der)
        case .ecdsaRecoverable:
            let (compact, recovery) = try Secp256k1.signRecoverable(digest: request.payload, privateKey: key.key)
            let recovered = try Secp256k1.recover(digest: request.payload, compact: compact, recoveryID: recovery, compressed: true)
            guard recovered == publicKey else { throw Failure.verificationFailed }
            return ProducedSignature(bytes: compact, recoveryID: recovery)
        case .ed25519:
            let signature = try Ed25519.sign(request.payload, seed: key.key)
            guard Ed25519.verify(signature: signature, message: request.payload, publicKey: publicKey) else {
                throw Failure.verificationFailed
            }
            return ProducedSignature(bytes: signature)
        case .schnorrBIP340:
            throw Failure.unsupportedScheme(.schnorrBIP340)
        case .ed25519Cardano:
            // Chave BIP32-Ed25519, que o HDKey nao deriva: so pelo CardanoSigning.
            throw Failure.unsupportedScheme(.ed25519Cardano)
        }
    }
}

public enum AccountDeriver {
    /// Deriva o endereco padrao de cada rede.
    public static func derive(_ secret: WalletSecret, chains: [Chain] = Chain.all) throws -> (accounts: [DerivedAccount], fingerprint: [UInt8]) {
        let seed = try secret.seed()
        defer { seed.wipe() }
        let secp = try HDKey.master(seed: seed, curve: .secp256k1)
        let ed = try HDKey.master(seed: seed, curve: .ed25519)
        defer { secp.wipe(); ed.wipe() }

        var accounts: [DerivedAccount] = []
        for chain in chains {
            if chain.family == .cardano {
                if let account = try? CardanoKey.derivedAccount(secret, chain: chain) { accounts.append(account) }
                continue
            }
            let path = DefaultPaths.path(for: chain)
            let master = chain.family.curve == .secp256k1 ? secp : ed
            let key = try master.derive(path)
            defer { key.wipe() }
            let publicKey = try key.publicKey()
            guard let address = try? Address.from(publicKey: publicKey, chain: chain) else { continue }
            var xpub: ExtendedPublicKey?
            if chain.family == .utxo {
                let accountPath = DerivationPath(components: Array(path.components.prefix(3)))
                let account = try master.derive(accountPath)
                defer { account.wipe() }
                xpub = try ExtendedPublicKey(publicKey: account.publicKey(), chainCode: account.chainCode.withUnsafeBytes { Array($0) })
            }
            accounts.append(DerivedAccount(chainID: chain.id, path: path, address: address, publicKey: publicKey, accountXPub: xpub))
        }
        return (accounts, try secp.fingerprint())
    }
}
