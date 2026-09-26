import EscaliburCore
import Foundation

/// Um caminho de derivacao como `m/44'/60'/0'/0/0`.
///
/// Aceita `'`, `h` e `H` como marca de endurecido, porque os tres aparecem em
/// documentacao de carteira, e sempre escreve com `'`.
public struct DerivationPath: Hashable, Sendable, CustomStringConvertible, Codable {
    public static let hardenedOffset: UInt32 = 0x8000_0000

    public let components: [UInt32]

    public init(components: [UInt32]) { self.components = components }

    public init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "m" else { return nil }
        var out = [UInt32]()
        for part in parts.dropFirst() {
            var body = Substring(part)
            var hardened = false
            if let last = body.last, last == "'" || last == "h" || last == "H" {
                hardened = true
                body = body.dropLast()
            }
            guard !body.isEmpty, body.allSatisfy(\.isASCIIDigit), let value = UInt32(body),
                  value < Self.hardenedOffset
            else { return nil }
            out.append(hardened ? value | Self.hardenedOffset : value)
        }
        components = out
    }

    public var description: String {
        (["m"] + components.map { $0 >= Self.hardenedOffset ? "\($0 - Self.hardenedOffset)'" : "\($0)" })
            .joined(separator: "/")
    }

    public var isFullyHardened: Bool { components.allSatisfy { $0 >= Self.hardenedOffset } }

    public static func hardened(_ value: UInt32) -> UInt32 { value | hardenedOffset }

    public func appending(_ index: UInt32) -> DerivationPath {
        DerivationPath(components: components + [index])
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let path = DerivationPath(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "caminho invalido"))
        }
        self = path
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
