import EscaliburChains
import EscaliburCore
import Foundation

/// Chave estendida da Cardano: BIP32-Ed25519 (Khovratovich e Law, derivacao V2), a partir
/// da chave mestra Icarus (CIP-3). E o esquema das carteiras Shelley pela CIP-1852:
/// Eternl, Yoroi, Lace, Typhon, Daedalus (carteira Shelley) e Trust Wallet abrem a mesma
/// conta com a mesma frase. Ledger usa outra chave mestra, e a Trezor com 24 palavras
/// tambem (CIP-3, "Trezor"), entao a conta delas e outra.
///
/// Diferente das outras redes, a chave mestra nao sai da seed BIP-39: sai da entropia.
///
/// ```
/// mestra = PBKDF2-HMAC-SHA512(senha = 25a palavra, sal = entropia, 4096, 96 bytes)
///          kL = [0..32) com bits ajustados, kR = [32..64), chain code = [64..96)
/// filha endurecida:  Z = HMAC-SHA512(c, 00 || kL || kR || i), c' = HMAC(c, 01 || ...)
/// filha normal:      Z = HMAC-SHA512(c, 02 || A  || i),       c' = HMAC(c, 03 || ...)
///                    kL' = kL + 8 * Z[0..28),  kR' = kR + Z[32..64) mod 2^256
/// ```
/// com `i` em 4 bytes little-endian. Tudo em `SecureBytes`; nada de chave em `String`.
public final class CardanoKey: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case invalidEntropy
        /// Caminho vazio devolveria a propria mestra, que quem chama zeraria.
        case emptyPath
    }

    /// kL || kR, 64 bytes.
    let extended: SecureBytes
    let chainCode: SecureBytes

    init(extended: SecureBytes, chainCode: SecureBytes) {
        self.extended = extended
        self.chainCode = chainCode
    }

    public func wipe() {
        extended.wipe()
        chainCode.wipe()
    }

    // MARK: Raiz

    /// A mestra Icarus da CIP-3. A 25a palavra entra como senha do PBKDF2, em bytes UTF-8
    /// (a carteira ja guarda em NFKD).
    public static func icarusMaster(entropy: SecureBytes, passphrase: SecureBytes) throws -> CardanoKey {
        guard [16, 20, 24, 28, 32].contains(entropy.count) else { throw Failure.invalidEntropy }
        let raw = try Hash.pbkdf2SHA512(password: passphrase, salt: entropy, rounds: 4096, length: 96)
        defer { raw.wipe() }
        let extended = SecureBytes(capacity: 64)
        let chainCode = SecureBytes(capacity: 32)
        raw.withUnsafeBytes { bytes in
            extended.fill(count: 64) { destination in
                destination.copyMemory(from: bytes.baseAddress!, byteCount: 64)
                let k = destination.assumingMemoryBound(to: UInt8.self)
                // Os bits do escalar: multiplo de 8, e o terceiro bit mais alto zerado
                // (Icarus), para as somas da derivacao nunca passarem de 2^255.
                k[0] &= 0xF8
                k[31] &= 0x1F
                k[31] |= 0x40
            }
            chainCode.append(contentsOf: UnsafeBufferPointer(rebasing: bytes.bindMemory(to: UInt8.self)[64..<96]))
        }
        return CardanoKey(extended: extended, chainCode: chainCode)
    }

    // MARK: Filhos

    public func derive(_ path: DerivationPath) throws -> CardanoKey {
        guard !path.components.isEmpty else { throw Failure.emptyPath }
        var current = self
        for component in path.components {
            let next = try current.child(component)
            if current !== self { current.wipe() }
            current = next
        }
        return current
    }

    public func child(_ index: UInt32) throws -> CardanoKey {
        let hardened = index >= DerivationPath.hardenedOffset
        let indexBytes = index.littleEndianByteArray
        let zData = SecureBytes(capacity: 69)
        let cData = SecureBytes(capacity: 69)
        defer {
            zData.wipe()
            cData.wipe()
        }
        if hardened {
            zData.append(0x00)
            cData.append(0x01)
            extended.withUnsafeBytes { key in
                zData.append(contentsOf: key.bindMemory(to: UInt8.self))
                cData.append(contentsOf: key.bindMemory(to: UInt8.self))
            }
        } else {
            let publicKey = try self.publicKey()
            zData.append(0x02)
            cData.append(0x03)
            publicKey.withUnsafeBufferPointer {
                zData.append(contentsOf: $0)
                cData.append(contentsOf: $0)
            }
        }
        indexBytes.withUnsafeBufferPointer {
            zData.append(contentsOf: $0)
            cData.append(contentsOf: $0)
        }
        let z = Hash.hmacSHA512(secureKey: chainCode, secureData: zData)
        let c = Hash.hmacSHA512(secureKey: chainCode, secureData: cData)
        defer {
            z.wipe()
            c.wipe()
        }

        let childExtended = SecureBytes(capacity: 64)
        extended.withUnsafeBytes { keyRaw in
            z.withUnsafeBytes { zRaw in
                let k = keyRaw.bindMemory(to: UInt8.self)
                let zz = zRaw.bindMemory(to: UInt8.self)
                childExtended.fill(count: 64) { destination in
                    let out = destination.assumingMemoryBound(to: UInt8.self)
                    // kL' = kL + 8 * zL, com zL = os 28 primeiros bytes de Z.
                    var carry: UInt16 = 0
                    for i in 0..<28 {
                        carry = carry + UInt16(k[i]) + (UInt16(zz[i]) << 3)
                        out[i] = UInt8(truncatingIfNeeded: carry)
                        carry >>= 8
                    }
                    for i in 28..<32 {
                        carry = carry + UInt16(k[i])
                        out[i] = UInt8(truncatingIfNeeded: carry)
                        carry >>= 8
                    }
                    // kR' = kR + zR mod 2^256.
                    carry = 0
                    for i in 0..<32 {
                        carry = carry + UInt16(k[32 + i]) + UInt16(zz[32 + i])
                        out[32 + i] = UInt8(truncatingIfNeeded: carry)
                        carry >>= 8
                    }
                }
            }
        }
        let childChain = SecureBytes(capacity: 32)
        c.withUnsafeBytes { raw in
            childChain.append(contentsOf: UnsafeBufferPointer(rebasing: raw.bindMemory(to: UInt8.self)[32..<64]))
        }
        return CardanoKey(extended: childExtended, chainCode: childChain)
    }

    // MARK: Publico e assinatura

    /// A chave publica Ed25519 (32 bytes): kL * B.
    public func publicKey() throws -> [UInt8] {
        try Ed25519.publicKey(extendedKey: extended)
    }

    func sign(_ message: [UInt8]) throws -> [UInt8] {
        try Ed25519.signExtended(message, extendedKey: extended)
    }

    /// Serializacao para os vetores publicados (kL, kR e chain code em hex) e so para
    /// eles: nenhuma tela exibe ou exporta chave privada.
    package func hexForTesting() -> (kL: String, kR: String, chainCode: String) {
        let key = extended.withUnsafeBytes { Array($0) }
        let chain = chainCode.withUnsafeBytes { Array($0) }
        return (Hex.encode(key.prefix(32)), Hex.encode(key.suffix(32)), Hex.encode(chain))
    }

    // MARK: Conta

    /// A conta Cardano de uma carteira: pagamento em m/1852'/1815'/i'/0/0, stake em
    /// m/1852'/1815'/i'/2/0, endereco base da rede principal. Guarda-se a chave publica de
    /// pagamento, a que assina os envios.
    public static func derivedAccount(_ secret: WalletSecret, chain: Chain = .cardano, account: UInt32 = 0) throws -> DerivedAccount {
        let master = try icarusMaster(entropy: secret.entropy, passphrase: secret.passphrase)
        defer { master.wipe() }
        let path = DefaultPaths.path(for: chain, account: account)
        let accountKey = try master.derive(DerivationPath(components: Array(path.components.prefix(3))))
        defer { accountKey.wipe() }
        let payment = try accountKey.derive(DerivationPath(components: [0, 0]))
        defer { payment.wipe() }
        let stake = try accountKey.derive(DerivationPath(components: [2, 0]))
        defer { stake.wipe() }
        let paymentKey = try payment.publicKey()
        let address = try Address.from(publicKey: paymentKey + (try stake.publicKey()), chain: chain)
        return DerivedAccount(chainID: chain.id, path: path, address: address, publicKey: paymentKey, accountXPub: nil)
    }
}

/// A parte do assinador que e so da Cardano.
enum CardanoSigning {
    /// A mestra Icarus, so se o plano tem pedido da Cardano. Sai da entropia, entao tem de
    /// ser tirada antes de o segredo ser zerado.
    static func master(for plan: SigningPlan, secret: WalletSecret) throws -> CardanoKey? {
        let needed = plan.transactions.contains { $0.signingRequests.contains { $0.scheme == .ed25519Cardano } }
        return needed ? try CardanoKey.icarusMaster(entropy: secret.entropy, passphrase: secret.passphrase) : nil
    }

    /// Deriva, confere a chave publica esperada, assina e verifica antes de devolver.
    static func sign(_ request: SigningRequest, master: CardanoKey?) throws -> ProducedSignature {
        guard let master, request.curve == .ed25519 else { throw Signer.Failure.unsupportedScheme(.ed25519Cardano) }
        let key = try master.derive(request.path)
        defer { key.wipe() }
        let publicKey = try key.publicKey()
        guard Hash.constantTimeEqual(publicKey, request.expectedPublicKey) else { throw Signer.Failure.unexpectedKey }
        let signature = try key.sign(request.payload)
        guard Ed25519.verify(signature: signature, message: request.payload, publicKey: publicKey) else {
            throw Signer.Failure.verificationFailed
        }
        return ProducedSignature(bytes: signature)
    }
}
