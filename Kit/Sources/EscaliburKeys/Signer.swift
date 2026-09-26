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
    }

    /// Assina todas as transacoes do plano, na ordem. Consome e zera a RK.
    public static func sign(_ plan: SigningPlan, rootKey rk: SecureBytes, vault: WalletVault) throws -> [SignedTransaction] {
        defer { rk.wipe() }
        guard !plan.isExpired() else { throw Failure.expired }

        let secret = try vault.open(walletID: plan.walletID, rk: rk)
        rk.wipe()
        defer { secret.wipe() }
        let seed = try secret.seed()
        secret.wipe()
        defer { seed.wipe() }

        var masters: [Curve: HDKey] = [:]
        defer { masters.values.forEach { $0.wipe() } }

        var signed: [SignedTransaction] = []
        for transaction in plan.transactions {
            var signatures: [ProducedSignature] = []
            for request in transaction.signingRequests {
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
        }
    }
}

/// As contas publicas de uma carteira, derivadas uma vez na criacao ou importacao e
/// guardadas nos metadados. Mostrar saldo e receber nunca abrem a seed depois disso.
public struct DerivedAccount: Sendable, Codable, Hashable {
    public let chainID: String
    public let path: DerivationPath
    public let address: String
    public let publicKey: [UInt8]
    /// So nas redes UTXO: a xpub da conta (`m/84'/0'/0'`), para derivar enderecos
    /// de recebimento e troco sem a seed. Nunca sai do aparelho.
    public let accountXPub: ExtendedPublicKey?

    public init(chainID: String, path: DerivationPath, address: String, publicKey: [UInt8], accountXPub: ExtendedPublicKey?) {
        self.chainID = chainID
        self.path = path
        self.address = address
        self.publicKey = publicKey
        self.accountXPub = accountXPub
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
