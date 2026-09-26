import CryptoKit
import Foundation

/// Base58 com o alfabeto como parametro.
///
/// Bitcoin, Litecoin, Dogecoin, Tron e Solana usam o alfabeto do Bitcoin; o XRP
/// Ledger usa uma permutacao propria que comeca por "rpshnaf". Trocar um pelo outro
/// produz um endereco valido de outra conta, entao o alfabeto nunca e implicito.
public struct Base58: Sendable {
    public let alphabet: [UInt8]
    private let reverse: [Int16]

    public static let bitcoin = Base58("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    public static let ripple = Base58("rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz")

    init(_ alphabet: String) {
        self.alphabet = Array(alphabet.utf8)
        var reverse = [Int16](repeating: -1, count: 256)
        for (index, c) in self.alphabet.enumerated() { reverse[Int(c)] = Int16(index) }
        self.reverse = reverse
    }

    public func encode(_ bytes: [UInt8]) -> String {
        let zeros = bytes.prefix { $0 == 0 }.count
        // Conversao de base 256 para base 58 por divisao repetida.
        var digits = [UInt8]()
        var number = Array(bytes.dropFirst(zeros))
        while !number.isEmpty {
            var remainder = 0
            var quotient = [UInt8]()
            for byte in number {
                let accumulator = remainder * 256 + Int(byte)
                let q = accumulator / 58
                remainder = accumulator % 58
                if !quotient.isEmpty || q > 0 { quotient.append(UInt8(q)) }
            }
            digits.append(alphabet[remainder])
            number = quotient
        }
        let leading = [UInt8](repeating: alphabet[0], count: zeros)
        return String(decoding: leading + digits.reversed(), as: UTF8.self)
    }

    public func decode(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard !chars.isEmpty else { return nil }
        let zeros = chars.prefix { $0 == alphabet[0] }.count
        var bytes = [UInt8]()  // little-endian enquanto acumula
        for c in chars.dropFirst(zeros) {
            let value = reverse[Int(c)]
            guard value >= 0 else { return nil }
            var carry = Int(value)
            for i in 0..<bytes.count {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xFF))
                carry >>= 8
            }
        }
        return [UInt8](repeating: 0, count: zeros) + bytes.reversed()
    }

    /// Base58Check: payload seguido dos quatro primeiros bytes de sha256(sha256(payload)).
    public func encodeCheck(_ payload: [UInt8]) -> String {
        encode(payload + Array(Hash.sha256d(payload).prefix(4)))
    }

    /// Devolve o payload sem o checksum, ou `nil` se o checksum nao fecha.
    public func decodeCheck(_ text: String) -> [UInt8]? {
        guard let raw = decode(text), raw.count >= 5 else { return nil }
        let payload = Array(raw.dropLast(4))
        let checksum = Array(raw.suffix(4))
        guard Hash.constantTimeEqual(Array(Hash.sha256d(payload).prefix(4)), checksum) else { return nil }
        return payload
    }
}
