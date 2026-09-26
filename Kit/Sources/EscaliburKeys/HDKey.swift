import EscaliburChains
import EscaliburCore
import Foundation

/// Uma chave estendida privada: 32 bytes de chave e 32 de chain code, os dois em
/// buffer seguro.
///
/// O chain code nao e segredo sozinho, mas junto de uma chave filha nao endurecida
/// ele reconstroi a chave mae. Por isso mora na mesma regiao zeravel que a chave.
public final class HDKey: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case invalidSeed
        case nonHardenedEd25519
        case invalidChild(UInt32)
        /// Caminho vazio devolveria a propria chave mestra, e quem chama costuma zerar
        /// o que recebe: zeraria a mestra, ou assinaria com ela.
        case emptyPath
    }

    /// BIP-32 sobre secp256k1; SLIP-10 sobre Ed25519 (so derivacao endurecida).
    public let curve: Curve
    /// A chave privada (32 bytes).
    public let key: SecureBytes
    /// O chain code (32 bytes).
    public let chainCode: SecureBytes
    public let depth: UInt8
    public let parentFingerprint: [UInt8]
    public let index: UInt32

    init(curve: Curve, key: SecureBytes, chainCode: SecureBytes, depth: UInt8, parentFingerprint: [UInt8], index: UInt32) {
        self.curve = curve
        self.key = key
        self.chainCode = chainCode
        self.depth = depth
        self.parentFingerprint = parentFingerprint
        self.index = index
    }

    /// Apaga chave e chain code agora, sem esperar o `deinit`.
    public func wipe() {
        key.wipe()
        chainCode.wipe()
    }

    // MARK: Raiz

    public static func master(seed: SecureBytes, curve: Curve) throws -> HDKey {
        guard (16...64).contains(seed.count) else { throw Failure.invalidSeed }
        let hmacKey = curve == .secp256k1 ? Array("Bitcoin seed".utf8) : Array("ed25519 seed".utf8)
        let i = Hash.hmacSHA512(key: hmacKey, secureData: seed)
        defer { i.wipe() }
        let (key, chain) = split(i)
        if curve == .secp256k1, !Secp256k1.isValidPrivateKey(key) {
            // Probabilidade menor que 2^-127. O BIP-32 manda descartar a seed.
            key.wipe()
            chain.wipe()
            throw Failure.invalidSeed
        }
        return HDKey(curve: curve, key: key, chainCode: chain, depth: 0, parentFingerprint: [0, 0, 0, 0], index: 0)
    }

    // MARK: Filhos

    public func derive(_ path: DerivationPath) throws -> HDKey {
        guard !path.components.isEmpty else { throw Failure.emptyPath }
        var current = self
        for component in path.components {
            let next = try current.child(component)
            if current !== self { current.wipe() }
            current = next
        }
        return current
    }

    public func child(_ index: UInt32) throws -> HDKey {
        let hardened = index >= DerivationPath.hardenedOffset
        if curve == .ed25519, !hardened { throw Failure.nonHardenedEd25519 }

        let data = SecureBytes(capacity: 37)
        defer { data.wipe() }
        if hardened {
            data.append(0x00)
            key.withUnsafeBytes { data.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        } else {
            let pub = try Secp256k1.publicKey(of: key, compressed: true)
            pub.withUnsafeBufferPointer { data.append(contentsOf: $0) }
        }
        index.bigEndianByteArray.withUnsafeBufferPointer { data.append(contentsOf: $0) }

        let i = Hash.hmacSHA512(secureKey: chainCode, secureData: data)
        defer { i.wipe() }
        let (il, chain) = Self.split(i)

        switch curve {
        case .ed25519:
            return HDKey(curve: curve, key: il, chainCode: chain, depth: depth &+ 1, parentFingerprint: try fingerprint(), index: index)
        case .secp256k1:
            // k_filho = IL + k_pai (mod n). A biblioteca recusa IL >= n e resultado
            // zero, que sao os dois casos que o BIP-32 manda pular.
            let childKey = SecureBytes(capacity: 32)
            key.withUnsafeBytes { childKey.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
            do {
                try il.withUnsafeBytes { try Secp256k1.tweakAdd(privateKey: childKey, tweak: $0) }
            } catch {
                childKey.wipe()
                chain.wipe()
                il.wipe()
                throw Failure.invalidChild(index)
            }
            il.wipe()
            return HDKey(curve: curve, key: childKey, chainCode: chain, depth: depth &+ 1, parentFingerprint: try fingerprint(), index: index)
        }
    }

    // MARK: Publico

    /// Chave publica: 33 bytes comprimidos em secp256k1; 32 bytes em Ed25519.
    public func publicKey() throws -> [UInt8] {
        switch curve {
        case .secp256k1: return try Secp256k1.publicKey(of: key, compressed: true)
        case .ed25519: return try Ed25519.publicKey(of: key)
        }
    }

    /// Os quatro primeiros bytes do hash160 da chave publica. Para Ed25519 o SLIP-10
    /// usa o mesmo calculo sobre `0x00 || pub`.
    public func fingerprint() throws -> [UInt8] {
        switch curve {
        case .secp256k1: return Array(Hash.hash160(try publicKey()).prefix(4))
        case .ed25519: return Array(Hash.hash160([0x00] + (try publicKey())).prefix(4))
        }
    }

    /// Serializacao xpub (ou ypub/zpub pela versao). Chave publica, pode sair do
    /// aparelho: e o que uma carteira de so leitura precisa.
    public func extendedPublicKey(version: [UInt8] = [0x04, 0x88, 0xB2, 0x1E]) throws -> String {
        precondition(curve == .secp256k1)
        var payload = version
        payload.append(depth)
        payload += parentFingerprint
        payload += index.bigEndianByteArray
        payload += chainCode.withUnsafeBytes { Array($0) }
        payload += try publicKey()
        return Base58.bitcoin.encodeCheck(payload)
    }

    /// Serializacao xprv. Existe para os vetores oficiais do BIP-32 e so para eles:
    /// nenhuma tela do app exibe ou exporta chave privada estendida.
    package func extendedPrivateKeyForTesting() -> String {
        var payload: [UInt8] = [0x04, 0x88, 0xAD, 0xE4]
        payload.append(depth)
        payload += parentFingerprint
        payload += index.bigEndianByteArray
        payload += chainCode.withUnsafeBytes { Array($0) }
        payload.append(0x00)
        payload += key.withUnsafeBytes { Array($0) }
        defer { payload.resetBytes() }
        return Base58.bitcoin.encodeCheck(payload)
    }

    private static func split(_ i: SecureBytes) -> (SecureBytes, SecureBytes) {
        let left = SecureBytes(capacity: 32)
        let right = SecureBytes(capacity: 32)
        i.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            left.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[0..<32]))
            right.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[32..<64]))
        }
        return (left, right)
    }
}
