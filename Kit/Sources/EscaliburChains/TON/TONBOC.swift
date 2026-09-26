import EscaliburCore
import Foundation

/// Bag of Cells: a serializacao binaria de uma arvore de celulas.
///
/// E o que vai para a rede (a mensagem externa assinada, em base64) e o que vem dela
/// (resultado de get method, codigo de contrato). A escrita segue a ordem do ton-core
/// (`src/boc/cell/serialization.ts` e `utils/topologicalSort.ts`), para que o mesmo
/// conteudo produza os mesmos bytes que as outras carteiras produzem.
///
/// Formato (`crypto/tl/boc.tlb` do ton-blockchain/ton):
/// `b5ee9c72`, flags e tamanho das referencias, tamanho dos offsets, numero de
/// celulas, de raizes e de ausentes, tamanho total, indices das raizes, indice
/// opcional, as celulas, e o CRC32C opcional em little-endian.
public enum TONBOC {
    static let magic: [UInt8] = [0xB5, 0xEE, 0x9C, 0x72]

    /// Limites de leitura. O BOC que a carteira le e pequeno (codigo de contrato, um
    /// endereco devolvido por get method); um BOC enorme vindo da rede e recusado
    /// antes de alocar memoria para ele.
    public static let maxParseBytes = 256 * 1024
    public static let maxParseCells = 4096

    // MARK: Escrita

    /// Serializa uma raiz. O padrao (com CRC32C, sem indice) e o do ton-core.
    public static func serialize(_ root: TONCell, crc32c: Bool = true, index: Bool = false) -> [UInt8] {
        let cells = topologicalOrder(root)
        var position = [[UInt8]: Int]()
        for (i, cell) in cells.enumerated() { position[cell.hash] = i }

        let sizeBytes = max(1, (bitLength(cells.count) + 7) / 8)
        var totalCellSize = 0
        var offsets = [Int]()
        for cell in cells {
            totalCellSize += 2 + (cell.bitCount + 7) / 8 + cell.refs.count * sizeBytes
            offsets.append(totalCellSize)
        }
        let offsetBytes = max(1, (bitLength(totalCellSize) + 7) / 8)

        var out = magic
        out.append((index ? 0x80 : 0) | (crc32c ? 0x40 : 0) | UInt8(sizeBytes))
        out.append(UInt8(offsetBytes))
        out += bigEndian(cells.count, width: sizeBytes)
        out += bigEndian(1, width: sizeBytes)             // raizes
        out += bigEndian(0, width: sizeBytes)             // ausentes
        out += bigEndian(totalCellSize, width: offsetBytes)
        out += bigEndian(0, width: sizeBytes)             // a raiz e a celula 0
        if index {
            for offset in offsets { out += bigEndian(offset, width: offsetBytes) }
        }
        for cell in cells {
            out.append(cell.refsDescriptor)
            out.append(cell.bitsDescriptor)
            out += cell.paddedData
            for ref in cell.refs {
                // A posicao sempre existe: toda filha entrou na ordenacao.
                out += bigEndian(position[ref.hash] ?? 0, width: sizeBytes)
            }
        }
        if crc32c {
            out += CRC32C.checksum(out).littleEndianByteArray
        }
        return out
    }

    public static func serializeBase64(_ root: TONCell, crc32c: Bool = true) -> String {
        Data(serialize(root, crc32c: crc32c)).base64EncodedString()
    }

    /// Ordem topologica igual a do ton-core: raiz primeiro, cada celula antes das
    /// filhas, celulas iguais (mesmo hash) uma vez so.
    static func topologicalOrder(_ root: TONCell) -> [TONCell] {
        var visited = Set<[UInt8]>()
        var postOrder = [TONCell]()
        func visit(_ cell: TONCell) {
            guard visited.insert(cell.hash).inserted else { return }
            for ref in cell.refs.reversed() { visit(ref) }
            postOrder.append(cell)
        }
        visit(root)
        return postOrder.reversed()
    }

    static func bitLength(_ value: Int) -> Int {
        value == 0 ? 0 : Int.bitWidth - value.leadingZeroBitCount
    }

    static func bigEndian(_ value: Int, width: Int) -> [UInt8] {
        (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * (width - 1 - $0))) }
    }

    // MARK: Leitura

    /// Le todas as raizes. So celulas comuns, e bibliotecas: celula exotica de outro
    /// tipo (prova de Merkle, podada) nao aparece no que a carteira precisa ler.
    public static func parse(_ bytes: [UInt8]) throws -> [TONCell] {
        guard bytes.count <= maxParseBytes else { throw TONCellError.malformedBOC("grande demais") }
        var reader = ByteReader(bytes)
        guard try reader.take(4) == magic else { throw TONCellError.malformedBOC("magica") }
        let flags = try reader.byte()
        let hasIndex = flags & 0x80 != 0
        let hasCRC = flags & 0x40 != 0
        let sizeBytes = Int(flags & 0x07)
        guard flags & 0x18 == 0 else { throw TONCellError.malformedBOC("flags reservadas") }
        guard (1...4).contains(sizeBytes) else { throw TONCellError.malformedBOC("tamanho de referencia") }
        let offsetBytes = Int(try reader.byte())
        guard (1...8).contains(offsetBytes) else { throw TONCellError.malformedBOC("tamanho de offset") }
        let cellCount = try reader.integer(sizeBytes)
        let rootCount = try reader.integer(sizeBytes)
        let absent = try reader.integer(sizeBytes)
        let totalSize = try reader.integer(offsetBytes)
        guard cellCount >= 1, cellCount <= maxParseCells else { throw TONCellError.malformedBOC("numero de celulas") }
        guard rootCount >= 1, rootCount <= cellCount else { throw TONCellError.malformedBOC("numero de raizes") }
        guard absent == 0 else { throw TONCellError.malformedBOC("celulas ausentes") }
        guard totalSize >= 0, totalSize <= bytes.count else { throw TONCellError.malformedBOC("tamanho total") }

        var roots = [Int]()
        for _ in 0..<rootCount {
            let root = try reader.integer(sizeBytes)
            guard root < cellCount else { throw TONCellError.malformedBOC("raiz fora do limite") }
            roots.append(root)
        }
        if hasIndex { _ = try reader.take(cellCount * offsetBytes) }

        let cellStart = reader.offset
        var raw = [(data: [UInt8], bits: Int, refs: [Int], exotic: Bool)]()
        raw.reserveCapacity(cellCount)
        for index in 0..<cellCount {
            let d1 = try reader.byte()
            let d2 = try reader.byte()
            let refCount = Int(d1 & 0x07)
            let exotic = d1 & 0x08 != 0
            guard d1 & 0x10 == 0, d1 >> 5 == 0 else { throw TONCellError.malformedBOC("celula com nivel ou hashes") }
            guard refCount <= TONCell.maxRefs else { throw TONCellError.malformedBOC("referencias demais") }
            let byteCount = (Int(d2) + 1) / 2
            let data = try reader.take(byteCount)
            var bits = byteCount * 8
            if d2 % 2 == 1 {
                // O ultimo byte esta incompleto: o bit 1 mais a direita e a marca de fim.
                // A celula apaga a marca ao ser criada (so guarda os `bits` uteis).
                guard let last = data.last, last != 0 else { throw TONCellError.malformedBOC("sem marca de fim") }
                bits -= last.trailingZeroBitCount + 1
            }
            guard bits <= TONCell.maxBits else { throw TONCellError.malformedBOC("bits demais") }
            var refs = [Int]()
            for _ in 0..<refCount {
                let ref = try reader.integer(sizeBytes)
                // Referencia sempre para frente: garante que nao ha ciclo.
                guard ref > index, ref < cellCount else { throw TONCellError.malformedBOC("referencia fora de ordem") }
                refs.append(ref)
            }
            if exotic {
                // So biblioteca: tipo 2, sem filhas, 8 + 256 bits.
                guard refCount == 0, bits == 264, data.first == 0x02 else {
                    throw TONCellError.malformedBOC("celula exotica nao suportada")
                }
            }
            raw.append((data, bits, refs, exotic))
        }
        guard reader.offset - cellStart == totalSize else { throw TONCellError.malformedBOC("tamanho das celulas") }

        if hasCRC {
            let body = Array(bytes[0..<reader.offset])
            let stored = try reader.take(4)
            let expected = CRC32C.checksum(body).littleEndianByteArray
            guard stored == expected else { throw TONCellError.malformedBOC("CRC32C") }
        }
        guard reader.isAtEnd else { throw TONCellError.malformedBOC("bytes sobrando") }

        var built = [TONCell?](repeating: nil, count: cellCount)
        for index in stride(from: cellCount - 1, through: 0, by: -1) {
            let entry = raw[index]
            if entry.exotic {
                built[index] = try TONCell.library(codeHash: Array(entry.data.dropFirst()))
                continue
            }
            let refs = try entry.refs.map { ref -> TONCell in
                guard let cell = built[ref] else { throw TONCellError.malformedBOC("referencia") }
                return cell
            }
            built[index] = try TONCell(data: entry.data, bitCount: entry.bits, refs: refs)
        }
        return try roots.map { root in
            guard let cell = built[root] else { throw TONCellError.malformedBOC("raiz") }
            return cell
        }
    }

    /// Le um BOC de raiz unica.
    public static func parseRoot(_ bytes: [UInt8]) throws -> TONCell {
        let roots = try parse(bytes)
        guard roots.count == 1 else { throw TONCellError.malformedBOC("mais de uma raiz") }
        return roots[0]
    }

    /// Le um BOC em base64 (padrao ou url-safe) de raiz unica.
    public static func parseRoot(base64 text: String) throws -> TONCell {
        var normalized = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 { normalized.append("=") }
        guard let data = Data(base64Encoded: normalized) else { throw TONCellError.malformedBOC("base64") }
        return try parseRoot(Array(data))
    }
}

/// Leitor de bytes que nunca le alem do fim.
private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw TONCellError.malformedBOC("fim inesperado") }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, bytes.count - offset >= count else { throw TONCellError.malformedBOC("fim inesperado") }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func integer(_ width: Int) throws -> Int {
        try take(width).reduce(0) { $0 << 8 | Int($1) }
    }
}

/// CRC-32C (Castagnoli, polinomio refletido 0x82F63B78), o checksum opcional do BOC.
/// Vetor: CRC32C("123456789") = 0xE3069283 (RFC 3720, apendice B.4).
public enum CRC32C {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1 }
        return crc
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
