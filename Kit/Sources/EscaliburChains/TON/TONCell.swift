import EscaliburCore
import Foundation

// Celulas TON: a unidade de tudo o que a rede guarda e assina.
//
// Uma celula tem ate 1023 bits e ate 4 referencias para outras celulas. Contrato,
// dados, mensagem e assinatura sao arvores de celulas, e o que a carteira assina e o
// hash de representacao da celula do corpo. Errar um bit aqui muda o hash: a
// assinatura sai valida para uma mensagem que o contrato nunca vai aceitar, ou,
// pior, o endereco derivado aponta para uma conta que ninguem controla.
//
// Referencia: "Cells, BoC" em docs.ton.org (tvm/cells) e ton-core/src/boc.

public enum TONCellError: Error, Equatable, Sendable {
    /// Passou de 1023 bits.
    case bitOverflow
    /// Passou de 4 referencias.
    case refOverflow
    /// Valor maior que o campo reservado para ele.
    case valueTooLarge
    /// Profundidade maior que 1024.
    case depthOverflow
    /// Leitura alem do fim da celula.
    case sliceUnderflow
    /// Endereco num formato que a carteira nao le (externo, anycast, var).
    case unsupportedAddress
    /// BOC invalido: o texto diz o que falhou.
    case malformedBOC(String)
    /// O BOC constante do contrato nao bate com o hash compilado.
    case codeHashMismatch
}

/// Uma celula imutavel, com hash e profundidade calculados na criacao.
public struct TONCell: Sendable, Hashable, CustomStringConvertible {
    public static let maxBits = 1023
    public static let maxRefs = 4
    static let maxDepth = 1024

    /// Os bits, alinhados a esquerda. O ultimo byte tem zeros depois de `bitCount`.
    public let data: [UInt8]
    public let bitCount: Int
    public let refs: [TONCell]
    /// So a celula de biblioteca (tipo 2, nivel 0) e aceita como exotica: e como o
    /// codigo da carteira jetton do USDT aparece no state init.
    public let isExotic: Bool
    /// Hash de representacao (SHA-256), o identificador da celula na rede.
    public let hash: [UInt8]
    /// Profundidade: 0 sem referencias, senao 1 + a maior das filhas.
    public let depth: Int

    /// A celula vazia: zero bits, nenhuma referencia.
    public static let empty = TONCell(uncheckedData: [], bitCount: 0, refs: [], isExotic: false)

    init(uncheckedData data: [UInt8], bitCount: Int, refs: [TONCell], isExotic: Bool) {
        self.data = data
        self.bitCount = bitCount
        self.refs = refs
        self.isExotic = isExotic
        self.depth = refs.isEmpty ? 0 : (refs.map(\.depth).max() ?? 0) + 1
        self.hash = Hash.sha256(Self.representation(data: data, bitCount: bitCount, refs: refs, isExotic: isExotic))
    }

    /// Cria e confere os limites. `data` pode ter bytes a mais; eles sao cortados.
    public init(data: [UInt8], bitCount: Int, refs: [TONCell] = []) throws {
        guard bitCount >= 0, bitCount <= Self.maxBits, data.count * 8 >= bitCount else { throw TONCellError.bitOverflow }
        guard refs.count <= Self.maxRefs else { throw TONCellError.refOverflow }
        guard refs.allSatisfy({ $0.depth < Self.maxDepth }) else { throw TONCellError.depthOverflow }
        self.init(uncheckedData: Self.clean(data, bitCount: bitCount), bitCount: bitCount, refs: refs, isExotic: false)
    }

    /// Celula de biblioteca: aponta para um codigo publicado na rede pelo hash. O
    /// state init da carteira jetton do USDT usa isso no lugar do codigo inteiro.
    public static func library(codeHash: [UInt8]) throws -> TONCell {
        guard codeHash.count == 32 else { throw TONCellError.valueTooLarge }
        return TONCell(uncheckedData: [0x02] + codeHash, bitCount: 264, refs: [], isExotic: true)
    }

    /// Descritor 1: numero de referencias, marca de exotica e nivel (sempre 0 aqui).
    var refsDescriptor: UInt8 { Self.refsDescriptor(refCount: refs.count, isExotic: isExotic) }

    /// Descritor 2: bytes cheios mais bytes comecados. Impar quer dizer que o ultimo
    /// byte esta incompleto e leva a marca de fim.
    var bitsDescriptor: UInt8 { Self.bitsDescriptor(bitCount: bitCount) }

    var paddedData: [UInt8] { Self.padded(data, bitCount: bitCount) }

    static func refsDescriptor(refCount: Int, isExotic: Bool) -> UInt8 {
        UInt8(refCount) + (isExotic ? 8 : 0)
    }

    static func bitsDescriptor(bitCount: Int) -> UInt8 {
        UInt8((bitCount + 7) / 8 + bitCount / 8)
    }

    /// Os dados com a marca de fim: um bit 1 logo depois do ultimo bit util, quando o
    /// comprimento nao e multiplo de 8. E assim que a rede sabe onde a celula acaba.
    static func padded(_ data: [UInt8], bitCount: Int) -> [UInt8] {
        var out = Array(data.prefix((bitCount + 7) / 8))
        if bitCount % 8 != 0 {
            out[out.count - 1] |= UInt8(0x80) >> UInt8(bitCount % 8)
        }
        return out
    }

    static func clean(_ data: [UInt8], bitCount: Int) -> [UInt8] {
        var out = Array(data.prefix((bitCount + 7) / 8))
        if bitCount % 8 != 0 {
            out[out.count - 1] &= ~(UInt8(0xFF) >> UInt8(bitCount % 8))
        }
        return out
    }

    /// d1 d2 dados, profundidade de cada filha (2 bytes) e hash de cada filha.
    static func representation(data: [UInt8], bitCount: Int, refs: [TONCell], isExotic: Bool) -> [UInt8] {
        var out: [UInt8] = [refsDescriptor(refCount: refs.count, isExotic: isExotic), bitsDescriptor(bitCount: bitCount)]
        out += padded(data, bitCount: bitCount)
        for ref in refs { out += [UInt8(ref.depth >> 8), UInt8(ref.depth & 0xFF)] }
        for ref in refs { out += ref.hash }
        return out
    }

    public func beginParse() -> TONCellSlice { TONCellSlice(self) }

    public static func == (a: TONCell, b: TONCell) -> Bool { a.hash == b.hash }
    public func hash(into hasher: inout Hasher) { hasher.combine(hash) }

    public var description: String { "TONCell(\(bitCount) bits, \(refs.count) refs, \(Hex.encode(hash)))" }
}

// MARK: Construtor

/// Monta uma celula bit a bit. Cada escrita confere o limite antes de escrever:
/// estourar 1023 bits ou 4 referencias e erro, nunca truncamento.
public struct TONCellBuilder: Sendable {
    public private(set) var data: [UInt8] = []
    public private(set) var bitCount = 0
    public private(set) var refs: [TONCell] = []

    public init() {}

    public var availableBits: Int { TONCell.maxBits - bitCount }
    public var availableRefs: Int { TONCell.maxRefs - refs.count }

    public mutating func storeBit(_ bit: Bool) throws {
        guard bitCount < TONCell.maxBits else { throw TONCellError.bitOverflow }
        if bitCount % 8 == 0 { data.append(0) }
        if bit { data[bitCount / 8] |= UInt8(0x80) >> UInt8(bitCount % 8) }
        bitCount += 1
    }

    /// Inteiro sem sinal em `bits` bits, big-endian.
    public mutating func storeUInt(_ value: UInt64, bits: Int) throws {
        guard bits >= 0, bits <= 64 else { throw TONCellError.valueTooLarge }
        guard bits == 64 || value >> UInt64(bits) == 0 else { throw TONCellError.valueTooLarge }
        guard bits <= availableBits else { throw TONCellError.bitOverflow }
        for i in stride(from: bits - 1, through: 0, by: -1) {
            try storeBit((value >> UInt64(i)) & 1 == 1)
        }
    }

    /// Inteiro com sinal em complemento de dois (o workchain -1 vira 0xFF em 8 bits).
    public mutating func storeInt(_ value: Int64, bits: Int) throws {
        guard bits >= 1, bits <= 64 else { throw TONCellError.valueTooLarge }
        if bits < 64 {
            let limit = Int64(1) << Int64(bits - 1)
            guard value >= -limit, value < limit else { throw TONCellError.valueTooLarge }
        }
        let pattern = UInt64(bitPattern: value) & (bits == 64 ? UInt64.max : (UInt64(1) << UInt64(bits)) - 1)
        try storeUInt(pattern, bits: bits)
    }

    public mutating func storeBigUInt(_ value: BigUInt, bits: Int) throws {
        guard value.bitWidth <= bits else { throw TONCellError.valueTooLarge }
        guard bits <= availableBits else { throw TONCellError.bitOverflow }
        guard let bytes = value.bigEndianBytes(padTo: (bits + 7) / 8) else { throw TONCellError.valueTooLarge }
        let skip = bytes.count * 8 - bits
        for i in skip..<(bytes.count * 8) {
            try storeBit((bytes[i / 8] >> UInt8(7 - i % 8)) & 1 == 1)
        }
    }

    public mutating func storeBytes(_ bytes: [UInt8]) throws {
        guard bytes.count * 8 <= availableBits else { throw TONCellError.bitOverflow }
        if bitCount % 8 == 0 {
            data += bytes
            bitCount += bytes.count * 8
            return
        }
        for byte in bytes { try storeUInt(UInt64(byte), bits: 8) }
    }

    /// `Coins` / `VarUInteger 16`: 4 bits com o tamanho em bytes, depois o valor.
    /// Cabe ate 2^120 - 1 nanoton, muito acima de todo o TON que existe.
    public mutating func storeCoins(_ value: BigUInt) throws {
        let bytes = value.bigEndianBytes
        guard bytes.count <= 15 else { throw TONCellError.valueTooLarge }
        try storeUInt(UInt64(bytes.count), bits: 4)
        try storeBytes(bytes)
    }

    /// `MsgAddressInt` (`addr_std`) ou `addr_none` quando `nil`.
    public mutating func storeAddress(_ address: TONAddress?) throws {
        guard let address else {
            try storeUInt(0, bits: 2)
            return
        }
        try storeUInt(0b100, bits: 3)          // addr_std$10, sem anycast
        try storeInt(Int64(address.workchain), bits: 8)
        try storeBytes(address.hash)
    }

    public mutating func storeRef(_ cell: TONCell) throws {
        guard refs.count < TONCell.maxRefs else { throw TONCellError.refOverflow }
        guard cell.depth < TONCell.maxDepth else { throw TONCellError.depthOverflow }
        refs.append(cell)
    }

    /// `Maybe ^Cell`: um bit, e a referencia quando presente.
    public mutating func storeMaybeRef(_ cell: TONCell?) throws {
        if let cell {
            try storeBit(true)
            try storeRef(cell)
        } else {
            try storeBit(false)
        }
    }

    /// Acrescenta os bits e as referencias de outro construtor.
    public mutating func storeBuilder(_ other: TONCellBuilder) throws {
        try storeBits(other.data, count: other.bitCount)
        for ref in other.refs { try storeRef(ref) }
    }

    /// Acrescenta o conteudo de uma celula comum (bits e referencias).
    public mutating func storeCellContents(_ cell: TONCell) throws {
        guard !cell.isExotic else { throw TONCellError.valueTooLarge }
        try storeBits(cell.data, count: cell.bitCount)
        for ref in cell.refs { try storeRef(ref) }
    }

    mutating func storeBits(_ bits: [UInt8], count: Int) throws {
        guard count <= availableBits else { throw TONCellError.bitOverflow }
        if bitCount % 8 == 0, count % 8 == 0 {
            try storeBytes(Array(bits.prefix(count / 8)))
            return
        }
        for i in 0..<count {
            try storeBit((bits[i / 8] >> UInt8(7 - i % 8)) & 1 == 1)
        }
    }

    /// Texto em bytes, continuando em celulas encadeadas pela primeira referencia
    /// quando nao cabe ("string tail", o formato do comentario de transferencia).
    public mutating func storeStringTail(_ bytes: [UInt8]) throws {
        let fits = availableBits / 8
        if bytes.count <= fits {
            try storeBytes(bytes)
            return
        }
        try storeBytes(Array(bytes.prefix(fits)))
        var tail = TONCellBuilder()
        try tail.storeStringTail(Array(bytes.dropFirst(fits)))
        try storeRef(tail.build())
    }

    public func build() -> TONCell {
        TONCell(uncheckedData: TONCell.clean(data, bitCount: bitCount), bitCount: bitCount, refs: refs, isExotic: false)
    }
}

// MARK: Leitor

/// Le uma celula em ordem. Toda leitura confere o que resta: celula vinda da rede
/// (resultado de get method) e dado externo, e um BOC malformado nao pode derrubar
/// o app nem virar endereco inventado.
public struct TONCellSlice: Sendable {
    public let cell: TONCell
    public private(set) var bitOffset = 0
    public private(set) var refOffset = 0

    public init(_ cell: TONCell) { self.cell = cell }

    public var remainingBits: Int { cell.bitCount - bitOffset }
    public var remainingRefs: Int { cell.refs.count - refOffset }

    public mutating func loadBit() throws -> Bool {
        guard remainingBits >= 1 else { throw TONCellError.sliceUnderflow }
        let bit = (cell.data[bitOffset / 8] >> UInt8(7 - bitOffset % 8)) & 1 == 1
        bitOffset += 1
        return bit
    }

    public mutating func loadUInt(bits: Int) throws -> UInt64 {
        guard bits >= 0, bits <= 64 else { throw TONCellError.valueTooLarge }
        guard remainingBits >= bits else { throw TONCellError.sliceUnderflow }
        var value: UInt64 = 0
        for _ in 0..<bits { value = value << 1 | (try loadBit() ? 1 : 0) }
        return value
    }

    public mutating func loadInt(bits: Int) throws -> Int64 {
        guard bits >= 1, bits <= 64 else { throw TONCellError.valueTooLarge }
        let raw = try loadUInt(bits: bits)
        if bits == 64 { return Int64(bitPattern: raw) }
        let sign = UInt64(1) << UInt64(bits - 1)
        return raw & sign == 0 ? Int64(raw) : Int64(raw) - Int64(sign << 1)
    }

    public mutating func loadBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remainingBits >= count * 8 else { throw TONCellError.sliceUnderflow }
        var out = [UInt8]()
        out.reserveCapacity(count)
        for _ in 0..<count { out.append(UInt8(try loadUInt(bits: 8))) }
        return out
    }

    public mutating func loadBigUInt(bits: Int) throws -> BigUInt {
        guard bits >= 0, remainingBits >= bits else { throw TONCellError.sliceUnderflow }
        var bytes = [UInt8](repeating: 0, count: (bits + 7) / 8)
        let skip = bytes.count * 8 - bits
        for i in skip..<(bytes.count * 8) where try loadBit() {
            bytes[i / 8] |= UInt8(0x80) >> UInt8(i % 8)
        }
        return BigUInt(bigEndian: bytes)
    }

    public mutating func loadCoins() throws -> BigUInt {
        let length = Int(try loadUInt(bits: 4))
        return try loadBigUInt(bits: length * 8)
    }

    /// `addr_none` devolve `nil`; `addr_std` sem anycast devolve o endereco; o resto
    /// (externo, anycast, `addr_var`) e recusado.
    public mutating func loadAddress() throws -> TONAddress? {
        let tag = try loadUInt(bits: 2)
        switch tag {
        case 0b00:
            return nil
        case 0b10:
            guard try !loadBit() else { throw TONCellError.unsupportedAddress }
            let workchain = Int8(try loadInt(bits: 8))
            let hash = try loadBytes(32)
            return TONAddress(workchain: workchain, hash: hash)
        default:
            throw TONCellError.unsupportedAddress
        }
    }

    public mutating func loadRef() throws -> TONCell {
        guard remainingRefs >= 1 else { throw TONCellError.sliceUnderflow }
        defer { refOffset += 1 }
        return cell.refs[refOffset]
    }

    public mutating func loadMaybeRef() throws -> TONCell? {
        try loadBit() ? try loadRef() : nil
    }

    /// Le um texto em "string tail": os bytes desta celula e das encadeadas.
    public mutating func loadStringTail() throws -> [UInt8] {
        guard remainingBits % 8 == 0 else { throw TONCellError.sliceUnderflow }
        var out = try loadBytes(remainingBits / 8)
        var next = remainingRefs == 1 ? try loadRef() : nil
        var guardCount = 0
        while let cell = next {
            guardCount += 1
            guard guardCount <= TONCell.maxDepth, cell.bitCount % 8 == 0, cell.refs.count <= 1 else {
                throw TONCellError.sliceUnderflow
            }
            var slice = cell.beginParse()
            out += try slice.loadBytes(cell.bitCount / 8)
            next = cell.refs.first
        }
        return out
    }
}
