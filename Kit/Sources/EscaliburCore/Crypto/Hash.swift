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

    /// SHA3-256 (FIPS 202), que nao e o Keccak-256 da Ethereum.
    public static func sha3_256(_ bytes: [UInt8]) -> [UInt8] {
        Keccak.sha3_256(bytes)
    }

    public static func ripemd160(_ bytes: [UInt8]) -> [UInt8] {
        RIPEMD160.hash(bytes)
    }

    /// ripemd160(sha256(x)): o identificador de chave publica do Bitcoin.
    public static func hash160(_ bytes: [UInt8]) -> [UInt8] {
        ripemd160(sha256(bytes))
    }

    // MARK: HMAC
    //
    // HMAC sempre pelo CommonCrypto, escrevendo direto no destino. O
    // `HashedAuthenticationCode` do CryptoKit nao tem endereco para zerar, e na
    // derivacao BIP-32 a saida do HMAC E a chave privada filha.

    public static func hmacSHA512(key: [UInt8], data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 64)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA512), key, key.count, data, data.count, &out)
        return out
    }

    public static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, data, data.count, &out)
        return out
    }

    /// HMAC-SHA512 com chave publica e mensagem secreta; saida em buffer seguro.
    public static func hmacSHA512(key: [UInt8], secureData: SecureBytes) -> SecureBytes {
        key.withUnsafeBytes { keyRaw in
            secureData.withUnsafeBytes { dataRaw in
                hmacSHA512Raw(key: keyRaw, data: dataRaw)
            }
        }
    }

    /// HMAC-SHA512 com chave e mensagem secretas; saida em buffer seguro.
    public static func hmacSHA512(secureKey: SecureBytes, secureData: SecureBytes) -> SecureBytes {
        secureKey.withUnsafeBytes { keyRaw in
            secureData.withUnsafeBytes { dataRaw in
                hmacSHA512Raw(key: keyRaw, data: dataRaw)
            }
        }
    }

    private static func hmacSHA512Raw(key: UnsafeRawBufferPointer, data: UnsafeRawBufferPointer) -> SecureBytes {
        let out = SecureBytes(capacity: 64)
        out.fill(count: 64) { destination in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA512), key.baseAddress, key.count, data.baseAddress, data.count, destination)
        }
        return out
    }

    /// PBKDF2-HMAC-SHA512. A senha entra e o resultado sai em buffer seguro.
    /// O mesmo, com o sal em buffer seguro (o sal do BIP-39 carrega a 25a palavra).
    public static func pbkdf2SHA512(password: SecureBytes, salt: SecureBytes, rounds: UInt32, length: Int) throws -> SecureBytes {
        var copy = salt.withUnsafeBytes { Array($0) }
        defer { copy.resetBytes() }
        return try pbkdf2SHA512(password: password, salt: copy, rounds: rounds, length: length)
    }

    public static func pbkdf2SHA512(password: SecureBytes, salt: [UInt8], rounds: UInt32, length: Int) throws -> SecureBytes {
        let out = SecureBytes(capacity: length)
        var status: Int32 = 0
        password.withUnsafeBytes { raw in
            out.fill(count: length) { destination in
                status = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                    raw.count,
                    salt,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                    rounds,
                    destination.assumingMemoryBound(to: UInt8.self),
                    length
                )
            }
        }
        guard status == kCCSuccess else {
            out.wipe()
            throw CryptoError.keyDerivationFailed(code: status)
        }
        return out
    }

    /// Comparacao em tempo constante sobre o conteudo.
    public static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// A mesma comparacao sem copiar os segredos para `Array`.
    public static func constantTimeEqual(_ a: SecureBytes, _ b: SecureBytes) -> Bool {
        a.withUnsafeBytes { x in
            b.withUnsafeBytes { y in
                guard x.count == y.count else { return false }
                var diff: UInt8 = 0
                for i in 0..<x.count { diff |= x[i] ^ y[i] }
                return diff == 0
            }
        }
    }
}
