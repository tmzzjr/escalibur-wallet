import EscaliburCore
import Foundation

/// Nome e simbolo de um token SPL, na conta de metadados da Metaplex (Token Metadata).
///
/// So exibicao: o que esta ali foi escrito por quem criou o token. A conta e o endereco
/// derivado de ("metadata", programa da Metaplex, mint), e o mint gravado nela tem de ser
/// o perguntado. Formato (mpl-token-metadata, `Metadata`): chave (1 byte, 4 = MetadataV1),
/// autoridade (32), mint (32), nome (u32 + bytes), simbolo (u32 + bytes), uri.
public enum SolanaMetaplex {
    /// metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s (docs.metaplex.com, "Token Metadata").
    public static let programID = try! SolanaPublicKey(base58: "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s")

    public static func metadataAddress(mint: SolanaPublicKey) -> SolanaPublicKey? {
        try? SolanaPDA.findProgramAddress(
            seeds: [Array("metadata".utf8), programID.bytes, mint.bytes], programID: programID
        ).address
    }

    public struct Metadata: Equatable, Sendable {
        public let mint: SolanaPublicKey
        public let name: String
        public let symbol: String
    }

    /// Le a conta crua. Tamanho fora do formato, chave que nao e de metadados ou texto
    /// que nao e UTF-8 viram nil. Os campos vem completados com zeros, que saem.
    public static func parse(_ data: [UInt8]) -> Metadata? {
        guard data.count >= 1 + 32 + 32 + 4, data[0] == 4 else { return nil }
        guard let mint = try? SolanaPublicKey(bytes: Array(data[33..<65])) else { return nil }
        var offset = 65
        func text(limit: Int) -> String? {
            guard offset + 4 <= data.count else { return nil }
            let length = Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
            offset += 4
            guard length >= 0, length <= limit, offset + length <= data.count else { return nil }
            let raw = data[offset..<(offset + length)].filter { $0 != 0 }
            offset += length
            return String(bytes: raw, encoding: .utf8)
        }
        guard let name = text(limit: 200), let symbol = text(limit: 50) else { return nil }
        return Metadata(mint: mint, name: name, symbol: symbol)
    }
}
