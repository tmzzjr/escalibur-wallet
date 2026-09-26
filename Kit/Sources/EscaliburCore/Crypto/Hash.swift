import CommonCrypto
import CryptoKit
import Foundation

/// As funcoes de hash e de derivacao que as redes usam, num lugar so.
///
/// SHA-2 e HMAC vem do CryptoKit; PBKDF2 do CommonCrypto; Keccak e RIPEMD-160 sao
/// deste repositorio (ver os arquivos proprios). Nada daqui guarda estado.
public enum Hash {
    public static func sha256<D: ContiguousBytes>(_ data: D) -> [UInt8] {
        data.withUnsafeBytes { Array(SHA256.hash(data: $0)) }
    }

    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }

    public static func sha256d(_ bytes: [UInt8]) -> [UInt8] {
        sha256(sha256(bytes))
    }

    public static func sha512(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA512.hash(data: bytes))
    }

    /// Os primeiros 32 bytes do SHA-512, o "SHA-512Half" do XRP Ledger.
    public static func sha512Half(_ bytes: [UInt8]) -> [UInt8] {
        Array(sha512(bytes).prefix(32))
    }

    public static func keccak256(_ bytes: [UInt8]) -> [UInt8] {
        Keccak.hash256(bytes)
    }

    public static func ripemd160(_ bytes: [UInt8]) -> [UInt8] {
        RIPEMD160.hash(bytes)
    }

    /// ripemd160(sha256(x)): o identificador de chave publica do Bitcoin.
    public static func hash160(_ bytes: [UInt8]) -> [UInt8] {
        ripemd160(sha256(bytes))
    }

    public static func hmacSHA512(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// HMAC-SHA512 com a chave e a mensagem vindo de buffers seguros, e a saida
    /// escrita direto num `SecureBytes`. E o passo de derivacao BIP-32 e SLIP-10.
    public static func hmacSHA512(key: [UInt8], secureData: SecureBytes) -> SecureBytes {
        let out = SecureBytes(capacity: 64)
        let code = secureData.withUnsafeBytes { raw in
            HMAC<SHA512>.authenticationCode(for: raw, using: SymmetricKey(data: key))
        }
        code.withUnsafeBytes { raw in
            out.append(contentsOf: raw.bindMemory(to: UInt8.self))
        }
        return out
    }

    public static func hmacSHA512(secureKey: SecureBytes, secureData: SecureBytes) -> SecureBytes {
        let out = SecureBytes(capacity: 64)
        let key = secureKey.withUnsafeBytes { SymmetricKey(data: $0) }
        let code = secureData.withUnsafeBytes { raw in
            HMAC<SHA512>.authenticationCode(for: raw, using: key)
        }
        code.withUnsafeBytes { raw in
            out.append(contentsOf: raw.bindMemory(to: UInt8.self))
        }
        return out
    }

    /// PBKDF2-HMAC-SHA512. A senha entra e o resultado sai em buffer seguro.
    public static func pbkdf2SHA512(password: SecureBytes, salt: [UInt8], rounds: UInt32, length: Int) throws -> SecureBytes {
        let out = SecureBytes(capacity: length)
        var scratch = [UInt8](repeating: 0, count: length)
        defer { scratch.resetBytes() }
        let status = password.withUnsafeBytes { raw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                raw.count,
                salt,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                rounds,
                &scratch,
                length
            )
        }
        guard status == kCCSuccess else { throw CryptoError.keyDerivationFailed(code: Int32(status)) }
        out.replaceAll(with: scratch)
        return out
    }

    /// Comparacao em tempo constante sobre o conteudo.
    public static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
