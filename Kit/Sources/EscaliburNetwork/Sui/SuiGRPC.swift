import EscaliburChains
import EscaliburCore
import Foundation

// O gRPC da Sui (`sui.rpc.v2`) pelo gRPC-Web, que e um POST comum: o URLSession fala com
// ele sem biblioteca de terceiro. A Sui Foundation desligou o JSON-RPC nos nos publicos
// na semana de 27/07/2026 e remove o codigo em meados de outubro de 2026
// (docs.sui.io, "JSON-RPC Migration Guide"); gRPC e GraphQL sao o que fica.
//
// Mensagens e numeros de campo da fonte: MystenLabs/sui-apis, `proto/sui/rpc/v2/`
// (commit 187995d1b57cddc3c67eb0f9d1affd4247ef110b, 21/09/2026).
//
// Enquadramento gRPC-Web (github.com/grpc/grpc, `doc/PROTOCOL-WEB.md`): cada mensagem vai
// num quadro de 1 byte de flag (0x00 dado, 0x80 trailers), 4 bytes de tamanho em
// big-endian e o corpo. A resposta traz os quadros de dado e, no fim, os trailers com
// `grpc-status`. Um erro sem dado nenhum vem so nos cabecalhos HTTP, que o transporte
// nao repassa: resposta sem quadro de dado conta como erro sem codigo.

enum SuiGRPC {
    static let contentType = "application/grpc-web+proto"

    /// Um quadro de dado com a mensagem.
    static func frame(_ message: [UInt8]) -> Data {
        Data([0x00] + UInt32(message.count).bigEndianByteArray + message)
    }

    /// Os corpos dos quadros de dado da resposta. Trailers com `grpc-status` diferente de
    /// zero, quadro comprimido ou truncado sao erro. Nenhum quadro de dado tambem.
    static func messages(_ data: Data, method: String) throws -> [[UInt8]] {
        let bytes = [UInt8](data)
        var offset = 0
        var out: [[UInt8]] = []
        while offset < bytes.count {
            guard bytes.count - offset >= 5 else { throw ReaderError.malformed(field: method + ".frame") }
            let flag = bytes[offset]
            let length = bytes[(offset + 1)..<(offset + 5)].reduce(0) { $0 << 8 | Int($1) }
            offset += 5
            guard length <= bytes.count - offset else { throw ReaderError.malformed(field: method + ".frame") }
            let body = Array(bytes[offset..<(offset + length)])
            offset += length
            switch flag {
            case 0x00:
                out.append(body)
            case 0x80:
                let status = trailerStatus(body)
                guard status == "0" else { throw ReaderError.providerError(code: ReaderError.sanitized("grpc-" + (status ?? "sem-status"))) }
            default:
                // 0x01: mensagem comprimida, que a carteira nunca pede.
                throw ReaderError.malformed(field: method + ".frame")
            }
        }
        guard !out.isEmpty else { throw ReaderError.providerError(code: "grpc") }
        return out
    }

    /// `grpc-status` dos trailers (linhas "nome:valor" separadas por CRLF).
    static func trailerStatus(_ body: [UInt8]) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        // "\r\n" e um caractere so no Swift: `isNewline` pega os tres casos.
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "grpc-status" {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func request(_ provider: ProviderPool.Provider, _ method: String, _ message: [UInt8], timeout: TimeInterval = 10) -> ReaderRequest {
        ReaderRequest(
            method: .post, url: provider.baseURL.adding(path: method), body: frame(message),
            headers: ["Content-Type": contentType, "Accept": contentType, "X-Grpc-Web": "1"], timeout: timeout
        )
    }
}

// MARK: Protobuf

/// Escrita protobuf: so varint e campo com tamanho, que e tudo o que os pedidos usam.
struct SuiProtoWriter {
    private(set) var bytes: [UInt8] = []

    mutating func varint(_ value: UInt64) {
        var rest = value
        while rest >= 0x80 {
            bytes.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
    }

    mutating func uint64(_ field: UInt32, _ value: UInt64) {
        varint(UInt64(field) << 3)
        varint(value)
    }

    mutating func bytes(_ field: UInt32, _ value: [UInt8]) {
        varint(UInt64(field) << 3 | 2)
        varint(UInt64(value.count))
        bytes += value
    }

    mutating func string(_ field: UInt32, _ value: String) { bytes(field, Array(value.utf8)) }
    mutating func message(_ field: UInt32, _ value: SuiProtoWriter) { bytes(field, value.bytes) }

    /// `google.protobuf.FieldMask { repeated string paths = 1; }`.
    static func fieldMask(_ paths: [String]) -> SuiProtoWriter {
        var mask = SuiProtoWriter()
        for path in paths { mask.string(1, path) }
        return mask
    }
}

/// Uma mensagem protobuf lida. Campo desconhecido e ignorado (o servidor pode acrescentar
/// campos), mas campo conhecido no tipo errado, ou repetido onde so cabe um, e erro.
struct SuiProtoMessage {
    enum Value {
        case varint(UInt64)
        case bytes([UInt8])
        case fixed
    }

    let fields: [UInt32: [Value]]
    let path: String

    init(_ bytes: [UInt8], path: String) throws {
        var fields: [UInt32: [Value]] = [:]
        var offset = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard offset < bytes.count, shift < 64 else { throw ReaderError.malformed(field: path) }
                let byte = bytes[offset]
                offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }
        while offset < bytes.count {
            let key = try varint()
            guard key >> 3 > 0, key >> 3 <= UInt64(UInt32.max) else { throw ReaderError.malformed(field: path) }
            let field = UInt32(key >> 3)
            let value: Value
            switch key & 7 {
            case 0:
                value = .varint(try varint())
            case 1, 5:
                let size = key & 7 == 1 ? 8 : 4
                guard bytes.count - offset >= size else { throw ReaderError.malformed(field: path) }
                offset += size
                value = .fixed
            case 2:
                let length = try varint()
                guard length <= UInt64(bytes.count - offset) else { throw ReaderError.malformed(field: path) }
                value = .bytes(Array(bytes[offset..<(offset + Int(length))]))
                offset += Int(length)
            default:
                throw ReaderError.malformed(field: path)
            }
            fields[field, default: []].append(value)
        }
        self.fields = fields
        self.path = path
    }

    private func single(_ field: UInt32, _ name: String) throws -> Value? {
        guard let values = fields[field] else { return nil }
        guard values.count == 1 else { throw ReaderError.malformed(field: path + "." + name) }
        return values[0]
    }

    func uint64(_ field: UInt32, _ name: String) throws -> UInt64? {
        guard let value = try single(field, name) else { return nil }
        guard case .varint(let number) = value else { throw ReaderError.malformed(field: path + "." + name) }
        return number
    }

    func requiredUInt64(_ field: UInt32, _ name: String) throws -> UInt64 {
        guard let value = try uint64(field, name) else { throw ReaderError.malformed(field: path + "." + name) }
        return value
    }

    func bool(_ field: UInt32, _ name: String) throws -> Bool? {
        guard let value = try uint64(field, name) else { return nil }
        guard value <= 1 else { throw ReaderError.malformed(field: path + "." + name) }
        return value == 1
    }

    func bytes(_ field: UInt32, _ name: String) throws -> [UInt8]? {
        guard let value = try single(field, name) else { return nil }
        guard case .bytes(let data) = value else { throw ReaderError.malformed(field: path + "." + name) }
        return data
    }

    func string(_ field: UInt32, _ name: String) throws -> String? {
        guard let data = try bytes(field, name) else { return nil }
        guard let text = String(bytes: data, encoding: .utf8) else { throw ReaderError.malformed(field: path + "." + name) }
        return text
    }

    func requiredString(_ field: UInt32, _ name: String) throws -> String {
        guard let text = try string(field, name) else { throw ReaderError.malformed(field: path + "." + name) }
        return text
    }

    func message(_ field: UInt32, _ name: String) throws -> SuiProtoMessage? {
        guard let data = try bytes(field, name) else { return nil }
        return try SuiProtoMessage(data, path: path + "." + name)
    }

    func requiredMessage(_ field: UInt32, _ name: String) throws -> SuiProtoMessage {
        guard let message = try message(field, name) else { throw ReaderError.malformed(field: path + "." + name) }
        return message
    }

    func messages(_ field: UInt32, _ name: String) throws -> [SuiProtoMessage] {
        try (fields[field] ?? []).enumerated().map { index, value in
            guard case .bytes(let data) = value else { throw ReaderError.malformed(field: path + "." + name) }
            return try SuiProtoMessage(data, path: path + "." + name + "[\(index)]")
        }
    }
}
