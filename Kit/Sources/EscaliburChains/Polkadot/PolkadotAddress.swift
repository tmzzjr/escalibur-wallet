import EscaliburCore
import Foundation

/// Endereco SS58 da Polkadot: a conta de 32 bytes (a chave publica Ed25519) com o
/// prefixo de rede 0 e dois bytes de checksum, em base58 (alfabeto do Bitcoin).
///
/// Checksum: os dois primeiros bytes do BLAKE2b-512 de `"SS58PRE" || prefixo || conta`
/// (docs.substrate.io, "SS58 address format"; `sp_core::crypto::Ss58Codec`, e o mesmo
/// calculo do `encodeAddress` do polkadot-js e do wallet-core da Trust Wallet,
/// `rust/tw_ss58_address`). Com o prefixo 0 o endereco sempre comeca com 1.
///
/// A mesma conta tem um texto por rede: 1... na Polkadot, letra maiuscula na Kusama
/// (prefixo 2), 5... no formato generico (42). A carteira so aceita como destino o
/// prefixo da Polkadot: um endereco de outra rede do ecossistema costuma ser de uma
/// exchange ou de um contrato que so credita naquela rede, e o DOT mandado para a mesma
/// chave na Polkadot nao chega a quem o dono pensa.
public struct PolkadotAddress: Hashable, Sendable, CustomStringConvertible {
    /// O prefixo da rede principal da Polkadot (registro ss58-registry, "polkadot").
    public static let polkadotPrefix: UInt16 = 0
    /// Kusama, so para a mensagem de erro dizer de onde e o endereco.
    public static let kusamaPrefix: UInt16 = 2

    /// A conta: a chave publica Ed25519 de 32 bytes.
    public let accountID: [UInt8]

    public init?(accountID: [UInt8]) {
        guard accountID.count == 32 else { return nil }
        self.accountID = accountID
    }

    /// O endereco da Polkadot, que comeca com 1.
    public var ss58: String { Self.encode(accountID, prefix: Self.polkadotPrefix) }

    public var description: String { ss58 }

    /// Codifica uma conta de 32 bytes com um prefixo simples (0 a 63, um byte), o unico
    /// tipo que a carteira produz.
    public static func encode(_ accountID: [UInt8], prefix: UInt16) -> String {
        precondition(prefix < 64 && accountID.count == 32, "SS58: so prefixo simples e conta de 32 bytes")
        let body = [UInt8(prefix)] + accountID
        return Base58.bitcoin.encode(body + checksum(body))
    }

    /// Os dois bytes de checksum de uma conta de 32 bytes.
    static func checksum(_ body: [UInt8]) -> [UInt8] {
        Array(Blake2b.hash(Array("SS58PRE".utf8) + body, outputLength: 64).prefix(2))
    }

    /// Le qualquer SS58 de conta de 32 bytes: prefixo simples (um byte, 0 a 63) ou
    /// completo (dois bytes, 64 a 16.383). Devolve o prefixo e a conta; checksum errado e
    /// `badChecksum`, o resto que nao e SS58 de conta e `malformed`.
    public static func decode(_ text: String) -> Result<(prefix: UInt16, accountID: [UInt8]), Address.Problem> {
        guard (40...50).contains(text.utf8.count), let raw = Base58.bitcoin.decode(text), let first = raw.first else {
            return .failure(.malformed)
        }
        let prefix: UInt16
        let prefixLength: Int
        switch first {
        case 0..<64:
            prefix = UInt16(first)
            prefixLength = 1
        case 64..<128:
            guard raw.count >= 2 else { return .failure(.malformed) }
            let second = raw[1]
            prefix = (UInt16(first & 0x3F) << 2) | UInt16(second >> 6) | (UInt16(second & 0x3F) << 8)
            prefixLength = 2
        default:
            return .failure(.malformed)
        }
        guard raw.count == prefixLength + 32 + 2 else { return .failure(.malformed) }
        let body = Array(raw.prefix(prefixLength + 32))
        guard Array(raw.suffix(2)) == checksum(body) else { return .failure(.badChecksum) }
        return .success((prefix, Array(body.dropFirst(prefixLength))))
    }

    /// Le um destino da Polkadot. Endereco valido de outra rede SS58 (Kusama, parachain,
    /// formato generico) e recusado como `malformed`: o texto nao e um endereco da
    /// Polkadot, e nada o converte em silencio.
    public static func parse(_ text: String) -> Result<PolkadotAddress, Address.Problem> {
        switch decode(text) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let decoded):
            guard decoded.prefix == polkadotPrefix, let address = PolkadotAddress(accountID: decoded.accountID) else {
                return .failure(.malformed)
            }
            return .success(address)
        }
    }

    /// O prefixo de um SS58 valido de outra rede, para a mensagem de erro dizer "este e da
    /// Kusama" em vez de so "invalido". Nil se o texto nao e SS58 valido.
    public static func foreignPrefix(_ text: String) -> UInt16? {
        guard case .success(let decoded) = decode(text), decoded.prefix != polkadotPrefix else { return nil }
        return decoded.prefix
    }

    /// Para `Address.guessChain`: o texto e um endereco da Polkadot.
    static func isPolkadot(_ text: String) -> Bool {
        if case .success = parse(text) { return true }
        return false
    }

    /// Validacao para `Address.validate`: devolve a grafia canonica, a que a carteira
    /// grava e compara.
    static func validateDestination(_ text: String) -> Result<Address.Destination, Address.Problem> {
        switch parse(text) {
        case .success(let address): return .success(Address.Destination(address: address.ss58, tag: nil))
        case .failure(let problem): return .failure(problem)
        }
    }
}
