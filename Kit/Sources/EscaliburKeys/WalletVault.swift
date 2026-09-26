import CryptoKit
import EscaliburCore
import Foundation

/// O segredo de uma carteira: a entropia BIP-39, o idioma e a 25a palavra.
///
/// Guarda-se a entropia (16 a 32 bytes), nao as palavras: e o menor segredo que
/// reconstroi a frase e a seed, e o registro fica do mesmo tamanho para qualquer
/// carteira.
public struct WalletSecret: Sendable {
    public let entropy: SecureBytes
    public let language: BIP39Language
    public let passphrase: SecureBytes

    public init(entropy: SecureBytes, language: BIP39Language, passphrase: SecureBytes) {
        self.entropy = entropy
        self.language = language
        self.passphrase = passphrase
    }

    /// A partir de uma frase ja canonica e validada. Fica com a 25a palavra (quem
    /// chama passa uma copia e nao a zera depois), gravada ja em NFKD: a seed de hoje
    /// e a de qualquer outra carteira BIP-39 sao a mesma, e derivar nunca precisa
    /// normalizar de novo.
    public static func from(phrase: SecureBytes, language: BIP39Language, passphrase: SecureBytes? = nil) throws -> WalletSecret {
        let entropy = try BIP39.entropy(fromPhrase: phrase, language: language)
        var stored = passphrase ?? SecureBytes(capacity: 1)
        if let passphrase, passphrase.withUnsafeBytes({ raw in raw.contains { $0 >= 0x80 } }) {
            stored = BIP39.nfkd(passphrase)
            passphrase.wipe()
        }
        return WalletSecret(entropy: entropy, language: language, passphrase: stored)
    }

    public func phrase() throws -> SecureBytes {
        try BIP39.phrase(fromEntropy: entropy, language: language)
    }

    /// A seed de 64 bytes. A 25a palavra entra aqui, sempre.
    public func seed() throws -> SecureBytes {
        let words = try phrase()
        defer { words.wipe() }
        return try BIP39.seed(phrase: words, passphrase: passphrase)
    }

    public func wipe() {
        entropy.wipe()
        passphrase.wipe()
    }
}

/// Um cofre por carteira: DEK propria, embrulhada por uma chave derivada da RK.
///
/// ```
/// RK ─HKDF(salt_w, "…/v1/dek" ‖ id)─► KEK_w ─► DEK_w ─HKDF(salt_s, "…/v1/seed")─► registro
/// ```
///
/// Com uma DEK por carteira: trocar o PIN nao toca nenhum registro, apagar uma
/// carteira destroi so a dela, e uma camada extra numa carteira (carteira-cofre) nao
/// muda as outras. Cada gravacao sorteia salts novos, entao a chave de cada cifra
/// nunca se repete e o nonce fixo em zero e seguro, como no formato do Escalibur.
public final class WalletVault: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case notFound
        case corrupted
        case passphraseTooLong
    }

    static let version: UInt8 = 1
    static let recordLength = 320
    static let maxPassphraseBytes = 256

    let store: any SecretStore

    public init(store: any SecretStore) {
        self.store = store
    }

    static func account(_ id: UUID) -> String { "seed.\(id.uuidString.lowercased())" }

    public func exists(_ id: UUID) -> Bool { store.exists(Self.account(id)) }

    public func delete(_ id: UUID) throws { try store.delete(Self.account(id)) }

    // MARK: Gravar

    public func save(_ secret: WalletSecret, walletID: UUID, rk: SecureBytes) throws {
        guard secret.passphrase.count <= Self.maxPassphraseBytes else { throw Failure.passphraseTooLong }
        let record = SecureBytes(capacity: Self.recordLength)
        record.append(Self.version)
        record.append(UInt8(BIP39Language.allCases.firstIndex(of: secret.language) ?? 0))
        record.append(UInt8(secret.entropy.count))
        secret.entropy.withUnsafeBytes { record.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        UInt16(secret.passphrase.count).bigEndianByteArray.withUnsafeBufferPointer { record.append(contentsOf: $0) }
        secret.passphrase.withUnsafeBytes { record.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        // Tamanho fixo: o registro nao conta se ha 25a palavra nem quantas palavras.
        while record.count < Self.recordLength { record.append(0) }
        defer { record.wipe() }

        let walletSalt = try Self.randomBytes(32)
        let seedSalt = try Self.randomBytes(32)
        let dek = try SecureBytes.random(count: 32)
        defer { dek.wipe() }

        let kek = Self.kek(rk: rk, salt: walletSalt, walletID: walletID)
        let wrapped = try dek.withUnsafeData {
            try ChaChaPoly.seal($0, using: kek, nonce: Self.zeroNonce, authenticating: Self.aad(walletID, type: 0x01))
        }
        let seedKey = Self.seedKey(dek: dek, salt: seedSalt)
        let sealed = try record.withUnsafeData {
            try ChaChaPoly.seal($0, using: seedKey, nonce: Self.zeroNonce, authenticating: Self.aad(walletID, type: 0x02))
        }

        var blob = Data([Self.version])
        blob += walletSalt
        blob += wrapped.ciphertext + wrapped.tag
        blob += seedSalt
        blob += sealed.ciphertext + sealed.tag

        let account = Self.account(walletID)
        if store.exists(account) {
            try store.update(blob, account: account)
        } else {
            try store.add(blob, account: account, protection: .standard, context: nil)
        }
    }

    // MARK: Abrir

    /// Abre o registro. Chamar so dentro de uma operacao que zera tudo no fim
    /// (assinar, revelar, exportar): nada daqui fica em memoria entre operacoes.
    public func open(walletID: UUID, rk: SecureBytes) throws -> WalletSecret {
        guard let blob = try store.read(Self.account(walletID), context: nil) else { throw Failure.notFound }
        let bytes = [UInt8](blob)
        let expected = 1 + 32 + 48 + 32 + Self.recordLength + 16
        guard bytes.count == expected, bytes[0] == Self.version else { throw Failure.corrupted }
        let walletSalt = Array(bytes[1..<33])
        let wrapped = Array(bytes[33..<81])
        let seedSalt = Array(bytes[81..<113])
        let sealed = Array(bytes[113...])

        let kek = Self.kek(rk: rk, salt: walletSalt, walletID: walletID)
        guard var dekData = try? ChaChaPoly.open(
            ChaChaPoly.SealedBox(nonce: Self.zeroNonce, ciphertext: Data(wrapped.prefix(32)), tag: Data(wrapped.suffix(16))),
            using: kek, authenticating: Self.aad(walletID, type: 0x01)
        ) else { throw Failure.corrupted }
        let dek = SecureBytes.consuming(&dekData)
        defer { dek.wipe() }

        guard var plain = try? ChaChaPoly.open(
            ChaChaPoly.SealedBox(nonce: Self.zeroNonce, ciphertext: Data(sealed.prefix(Self.recordLength)), tag: Data(sealed.suffix(16))),
            using: Self.seedKey(dek: dek, salt: seedSalt), authenticating: Self.aad(walletID, type: 0x02)
        ) else { throw Failure.corrupted }
        let record = SecureBytes.consuming(&plain)
        defer { record.wipe() }

        return try record.withUnsafeBytes { raw -> WalletSecret in
            let r = raw.bindMemory(to: UInt8.self)
            guard r.count == Self.recordLength, r[0] == Self.version else { throw Failure.corrupted }
            let languageIndex = Int(r[1])
            let entropyLength = Int(r[2])
            guard BIP39Language.allCases.indices.contains(languageIndex), [16, 20, 24, 28, 32].contains(entropyLength) else {
                throw Failure.corrupted
            }
            let entropy = SecureBytes(capacity: entropyLength)
            entropy.append(contentsOf: UnsafeBufferPointer(rebasing: r[3..<(3 + entropyLength)]))
            let at = 3 + entropyLength
            let passLength = Int(r[at]) << 8 | Int(r[at + 1])
            guard passLength <= Self.maxPassphraseBytes, at + 2 + passLength <= r.count else {
                entropy.wipe()
                throw Failure.corrupted
            }
            let passphrase = SecureBytes(capacity: max(passLength, 1))
            passphrase.append(contentsOf: UnsafeBufferPointer(rebasing: r[(at + 2)..<(at + 2 + passLength)]))
            return WalletSecret(entropy: entropy, language: BIP39Language.allCases[languageIndex], passphrase: passphrase)
        }
    }

    // MARK: Chaves

    static let zeroNonce = try! ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12))  // swiftlint:disable:this force_try

    static func kek(rk: SecureBytes, salt: [UInt8], walletID: UUID) -> SymmetricKey {
        let ikm = rk.withUnsafeBytes { SymmetricKey(data: $0) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt,
            info: Array("escalibur-wallet/v1/dek".utf8) + uuidBytes(walletID), outputByteCount: 32
        )
    }

    static func seedKey(dek: SecureBytes, salt: [UInt8]) -> SymmetricKey {
        let ikm = dek.withUnsafeBytes { SymmetricKey(data: $0) }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Array("escalibur-wallet/v1/seed".utf8), outputByteCount: 32)
    }

    static func aad(_ id: UUID, type: UInt8) -> Data {
        Data(uuidBytes(id) + [version, type])
    }

    static func uuidBytes(_ id: UUID) -> [UInt8] {
        withUnsafeBytes(of: id.uuid) { Array($0) }
    }

    static func randomBytes(_ count: Int) throws -> [UInt8] {
        try SecureBytes.random(count: count).withUnsafeBytes { Array($0) }
    }
}

/// A chave de indice: protege os metadados (nomes, enderecos, xpubs, catalogo,
/// historico de ordens), que sao dado de privacidade, nao segredo. Vive em memoria
/// enquanto o app esta destrancado.
public enum IndexCipher {
    public static func key(from rk: SecureBytes) -> SymmetricKey {
        let ikm = rk.withUnsafeBytes { SymmetricKey(data: $0) }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: [UInt8](), info: Array("escalibur-wallet/v1/index".utf8), outputByteCount: 32)
    }

    /// Cifra com subchave por gravacao: `salt(32) ‖ ciphertext ‖ tag`.
    public static func seal(_ plain: Data, key: SymmetricKey) throws -> Data {
        let salt = try WalletVault.randomBytes(32)
        let subkey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Array("escalibur-wallet/v1/metadados".utf8), outputByteCount: 32)
        let sealed = try ChaChaPoly.seal(plain, using: subkey, nonce: WalletVault.zeroNonce)
        return Data(salt) + sealed.ciphertext + sealed.tag
    }

    public static func open(_ blob: Data, key: SymmetricKey) throws -> Data {
        guard blob.count >= 48 else { throw WalletVault.Failure.corrupted }
        let salt = [UInt8](blob.prefix(32))
        let subkey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: Array("escalibur-wallet/v1/metadados".utf8), outputByteCount: 32)
        let body = blob.dropFirst(32)
        return try ChaChaPoly.open(
            ChaChaPoly.SealedBox(nonce: WalletVault.zeroNonce, ciphertext: body.dropLast(16), tag: body.suffix(16)),
            using: subkey
        )
    }
}

extension SecureBytes {
    /// Move o conteudo de um `Data` que saiu de uma API para o buffer seguro, e zera
    /// a origem.
    static func consuming(_ data: inout Data) -> SecureBytes {
        let out = SecureBytes(capacity: max(data.count, 1))
        data.withUnsafeMutableBytes { raw in
            out.append(contentsOf: raw.bindMemory(to: UInt8.self).withMemoryRebound(to: UInt8.self) { UnsafeBufferPointer($0) })
            if let base = raw.baseAddress { memset_s(base, raw.count, 0, raw.count) }
        }
        return out
    }
}
