import EscaliburCore
import Foundation

/// Um endereco Tron em bytes: o prefixo 0x41 seguido dos 20 bytes da conta, que sao
/// os mesmos da EVM (keccak256 da chave expandida, ultimos 20 bytes).
///
/// Dentro da transacao o endereco vai sempre com os 21 bytes; na ABI de um contrato
/// TRC-20 ele vai sem o 0x41, como endereco EVM. Misturar as duas formas e o jeito
/// de mandar dinheiro para uma conta que ninguem controla, entao as duas saem daqui
/// por nome (`bytes` e `account20`), nunca por fatia feita na mao.
public struct TronAddress: Hashable, Sendable, CustomStringConvertible {
    /// Prefixo da rede principal. Fonte: java-tron, `DecodeUtil.addressPreFixByte`
    /// (0x41), o mesmo que da o "T" inicial no base58.
    public static let prefix: UInt8 = 0x41

    /// Os 21 bytes, com o 0x41.
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 21, bytes[0] == Self.prefix else { return nil }
        self.bytes = bytes
    }

    /// A partir dos 20 bytes da conta, como vem da ABI.
    public init?(account20: [UInt8]) {
        guard account20.count == 20 else { return nil }
        self.bytes = [Self.prefix] + account20
    }

    /// Endereco "T..." com checksum conferido.
    public init?(base58 text: String) {
        guard case .success = Address.validateTron(text), let payload = Base58.bitcoin.decodeCheck(text) else { return nil }
        self.init(bytes: payload)
    }

    /// Aceita as duas formas que a API HTTP do java-tron devolve: base58 com
    /// `visible: true` e hex com o 41 na frente com `visible: false`.
    public init?(_ text: String) {
        if text.count == 42, text.hasPrefix("41"), let raw = Hex.decode(text) {
            self.init(bytes: raw)
        } else {
            self.init(base58: text)
        }
    }

    /// O endereco de uma chave publica secp256k1 (33 ou 65 bytes).
    public init(publicKey: [UInt8]) throws {
        self.bytes = [Self.prefix] + (try Address.evmAccount(publicKey))
    }

    /// Os 20 bytes da conta, sem o 0x41: a forma que entra na ABI.
    public var account20: [UInt8] { Array(bytes.dropFirst()) }

    public var base58: String { Base58.bitcoin.encodeCheck(bytes) }

    /// Hex com o 41, como a API devolve com `visible: false`.
    public var hex: String { Hex.encode(bytes) }

    public var description: String { base58 }
}
