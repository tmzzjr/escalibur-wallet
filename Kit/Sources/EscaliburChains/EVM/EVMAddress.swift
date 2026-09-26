import EscaliburCore
import Foundation

/// Um endereco EVM: 20 bytes, exibido sempre com o checksum EIP-55.
///
/// Guardar o endereco como bytes, e nao como texto, tira de cena a comparacao por
/// caixa: `0xabc...` e `0xABC...` sao o mesmo destino, e uma allowlist comparada por
/// texto deixaria passar o mesmo router escrito com outra caixa, ou barraria o certo.
public struct EVMAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    /// 0x000...000. Mandar valor ou token para ca e queimar.
    public static let zero = EVMAddress(uncheckedBytes: [UInt8](repeating: 0, count: 20))

    public init?(bytes: [UInt8]) {
        guard bytes.count == 20 else { return nil }
        self.bytes = bytes
    }

    init(uncheckedBytes: [UInt8]) {
        precondition(uncheckedBytes.count == 20)
        bytes = uncheckedBytes
    }

    /// Texto `0x` com 40 digitos. Caixa mista precisa bater com o EIP-55; tudo
    /// minusculo ou tudo maiusculo nao carrega checksum e e aceito, como em toda
    /// carteira (a interface pede confirmacao extra nesse caso, docs/blockchain.md 2.2).
    public init(_ text: String) throws {
        switch Address.validateEVM(text) {
        case .success(let destination):
            guard let bytes = Hex.decode(destination.address), bytes.count == 20 else { throw Address.Problem.malformed }
            self.bytes = bytes
        case .failure(let problem):
            throw problem
        }
    }

    /// Endereco a partir da chave publica secp256k1 (33 ou 65 bytes).
    public init(publicKey: [UInt8]) throws {
        bytes = try Address.evmAccount(publicKey)
    }

    /// O texto que se mostra e se confere: EIP-55.
    public var checksummed: String { Address.eip55(bytes) }

    public var description: String { checksummed }

    public var isZero: Bool { bytes.allSatisfy { $0 == 0 } }

    /// A palavra ABI de 32 bytes: 12 zeros e os 20 do endereco.
    var abiWord: [UInt8] { [UInt8](repeating: 0, count: 12) + bytes }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(text)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "endereco EVM invalido"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(checksummed)
    }
}

/// A conta que assina: caminho, chave publica comprimida e o endereco que sai dela.
///
/// O endereco nunca e informado separado da chave: ele e derivado aqui, e o
/// assinador confere a chave publica antes de assinar. Um endereco "do dono" que
/// viesse de fora poderia ser de outra conta.
public struct EVMAccount: Sendable, Equatable {
    public let path: DerivationPath
    /// 33 bytes, comprimida.
    public let publicKey: [UInt8]
    public let address: EVMAddress

    public init(path: DerivationPath, publicKey: [UInt8]) throws {
        let compressed = try Secp256k1.reformat(publicKey: publicKey, compressed: true)
        self.path = path
        self.publicKey = compressed
        self.address = try EVMAddress(publicKey: compressed)
    }
}
