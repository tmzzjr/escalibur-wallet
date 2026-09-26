import CryptoKit
import Foundation

/// Ed25519 sobre o CryptoKit. Solana, Stellar e TON.
///
/// O CryptoKit aleatoriza a assinatura Ed25519 (uma assinatura diferente a cada
/// chamada, todas validas pela RFC 8032). Para as redes isso nao muda nada: o no
/// confere a assinatura, nao a compara com outra. O que muda e o teste: vetores de
/// transacao assinada sao conferidos pela verificacao, e a mensagem assinada e
/// comparada byte a byte.
public enum Ed25519 {
    public enum Failure: Error { case invalidSeed, invalidPublicKey }

    public static func publicKey(of seed: SecureBytes) throws -> [UInt8] {
        guard seed.count == 32 else { throw Failure.invalidSeed }
        let key = try seed.withUnsafeBytes { try Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
        return Array(key.publicKey.rawRepresentation)
    }

    public static func sign(_ message: [UInt8], seed: SecureBytes) throws -> [UInt8] {
        guard seed.count == 32 else { throw Failure.invalidSeed }
        let key = try seed.withUnsafeBytes { try Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
        return Array(try key.signature(for: message))
    }

    public static func verify(signature: [UInt8], message: [UInt8], publicKey: [UInt8]) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}
