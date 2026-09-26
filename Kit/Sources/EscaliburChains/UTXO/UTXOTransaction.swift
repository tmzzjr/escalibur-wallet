import EscaliburCore
import Foundation

// A transacao das redes UTXO (Bitcoin, Litecoin, Dogecoin), byte a byte.
//
// Serializacao do Bitcoin Core (primitives/transaction.h) com a extensao do BIP-144
// para witness. O parser e estrito de proposito: CompactSize nao canonico, flag de
// witness desconhecida, witness declarada e toda vazia, ou byte sobrando no fim sao
// recusados, exatamente como o no recusa. Uma transacao anterior que o provedor
// entrega "quase certa" nao tem txid confiavel, e o txid e o que prova o valor.

// MARK: Identificador

/// O id de uma transacao (txid ou wtxid).
///
/// Guardado na ordem dos bytes da serializacao. O texto que exploradores e APIs
/// mostram e o inverso (a convencao `uint256::GetHex` do Bitcoin Core), e confundir
/// as duas ordens aponta para uma transacao que nao existe.
public struct UTXOTxID: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// Os 32 bytes na ordem em que aparecem no outpoint serializado.
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    /// A partir do hex de explorador (bytes invertidos).
    public init?(hex: String) {
        guard hex.count == 64, !hex.hasPrefix("0x"), let raw = Hex.decode(hex), raw.count == 32 else { return nil }
        bytes = raw.reversed()
    }

    /// O hex que exploradores e provedores usam.
    public var hex: String { Hex.encode(bytes.reversed()) }

    public var description: String { hex }

    /// Ordem do BIP-69: o hex de explorador em ordem lexicografica.
    public static func < (a: UTXOTxID, b: UTXOTxID) -> Bool {
        a.bytes.reversed().lexicographicallyPrecedes(b.bytes.reversed())
    }
}

/// Uma saida de transacao anterior: txid e indice.
public struct UTXOOutpoint: Hashable, Sendable, CustomStringConvertible {
    public let txid: UTXOTxID
    public let vout: UInt32

    public init(txid: UTXOTxID, vout: UInt32) {
        self.txid = txid
        self.vout = vout
    }

    public var description: String { "\(txid.hex):\(vout)" }
}

// MARK: Transacao

public struct UTXOTxIn: Equatable, Sendable {
    public var outpoint: UTXOOutpoint
    public var scriptSig: [UInt8]
    public var sequence: UInt32
    /// Pilha de witness (BIP-141). Vazia em entrada que nao e segwit.
    public var witness: [[UInt8]]

    public init(outpoint: UTXOOutpoint, scriptSig: [UInt8] = [], sequence: UInt32, witness: [[UInt8]] = []) {
        self.outpoint = outpoint
        self.scriptSig = scriptSig
        self.sequence = sequence
        self.witness = witness
    }
}

public struct UTXOTxOut: Equatable, Sendable {
    /// Campo de 64 bits do formato de fio, em satoshis. Soma de valores sempre com
    /// verificacao de estouro (ver `UTXOPlanner`).
    public var value: UInt64
    public var scriptPubKey: [UInt8]

    public init(value: UInt64, scriptPubKey: [UInt8]) {
        self.value = value
        self.scriptPubKey = scriptPubKey
    }
}

public struct UTXOTransaction: Equatable, Sendable {
    /// `int32` no Core; aqui o padrao de bits, que e o que vai para o fio.
    public var version: UInt32
    public var inputs: [UTXOTxIn]
    public var outputs: [UTXOTxOut]
    public var lockTime: UInt32

    public enum ParseError: Error, Equatable, Sendable {
        case truncated
        case nonCanonicalCompactSize
        case sizeTooLarge
        case noInputs
        case unknownWitnessFlag
        /// Flag de witness presente e todas as pilhas vazias: o Core recusa.
        case superfluousWitness
        case trailingBytes
    }

    /// Teto de tamanho aceito no parse: o peso maximo de um bloco. Uma "transacao
    /// anterior" maior que isso so pode ser tentativa de esgotar memoria.
    public static let maxSerializedSize = 4_000_000

    public init(version: UInt32, inputs: [UTXOTxIn], outputs: [UTXOTxOut], lockTime: UInt32) {
        self.version = version
        self.inputs = inputs
        self.outputs = outputs
        self.lockTime = lockTime
    }

    /// Alguma entrada carrega witness? So entao a serializacao usa marker e flag.
    public var hasWitness: Bool { inputs.contains { !$0.witness.isEmpty } }

    // MARK: Serializacao

    /// Com witness (BIP-144) quando alguma entrada tem, sem quando nenhuma tem.
    public func serialized() -> [UInt8] { serialize(includeWitness: true) }

    /// Sem witness: e o que o txid cobre.
    public func serializedWithoutWitness() -> [UInt8] { serialize(includeWitness: false) }

    func serialize(includeWitness: Bool) -> [UInt8] {
        var w = UTXOByteWriter()
        let witness = includeWitness && hasWitness
        w.uint32(version)
        if witness { w.bytes([0x00, 0x01]) }
        w.compactSize(UInt64(inputs.count))
        for input in inputs {
            w.bytes(input.outpoint.txid.bytes)
            w.uint32(input.outpoint.vout)
            w.varBytes(input.scriptSig)
            w.uint32(input.sequence)
        }
        w.compactSize(UInt64(outputs.count))
        for output in outputs { w.output(output) }
        if witness {
            for input in inputs {
                w.compactSize(UInt64(input.witness.count))
                for item in input.witness { w.varBytes(item) }
            }
        }
        w.uint32(lockTime)
        return w.data
    }

    /// dSHA256 da serializacao sem witness. Mudar a witness nao muda o txid, e e
    /// por isso que ele serve de referencia para o outpoint.
    public var txid: UTXOTxID { UTXOTxID(bytes: Hash.sha256d(serializedWithoutWitness()))! }

    /// dSHA256 da serializacao completa (BIP-141). Igual ao txid sem witness.
    public var wtxid: UTXOTxID { UTXOTxID(bytes: Hash.sha256d(serialized()))! }

    /// Peso (BIP-141): tamanho sem witness vezes 3 mais o tamanho completo.
    public var weight: Int { serializedWithoutWitness().count * 3 + serialized().count }

    /// Tamanho virtual, arredondado para cima.
    public var virtualSize: Int { (weight + 3) / 4 }

    // MARK: Parse

    /// Le uma transacao crua, com ou sem witness, e recusa qualquer desvio do formato.
    public init(parsing raw: [UInt8]) throws {
        guard raw.count <= Self.maxSerializedSize else { throw ParseError.sizeTooLarge }
        var r = UTXOByteReader(raw)
        version = try r.uint32()
        var inputCount = try r.compactSize()
        var witnessFlag: UInt8 = 0
        if inputCount == 0 {
            // Com zero entradas lidas, o proximo byte e a flag do BIP-144. Uma
            // transacao sem entrada de verdade e invalida de qualquer modo.
            witnessFlag = try r.uint8()
            guard witnessFlag != 0 else { throw ParseError.noInputs }
            guard witnessFlag == 1 else { throw ParseError.unknownWitnessFlag }
            inputCount = try r.compactSize()
            guard inputCount > 0 else { throw ParseError.noInputs }
        }
        // Cada entrada ocupa pelo menos 41 bytes: contagem maior que o restante e
        // mentira do cabecalho, recusada antes de reservar memoria.
        guard inputCount <= UInt64(r.remaining / 41) else { throw ParseError.truncated }
        var inputs = [UTXOTxIn]()
        inputs.reserveCapacity(Int(inputCount))
        for _ in 0..<inputCount {
            let txid = UTXOTxID(bytes: try r.bytes(32))!
            let vout = try r.uint32()
            let scriptSig = try r.varBytes()
            let sequence = try r.uint32()
            inputs.append(UTXOTxIn(outpoint: UTXOOutpoint(txid: txid, vout: vout), scriptSig: scriptSig, sequence: sequence))
        }
        let outputCount = try r.compactSize()
        guard outputCount <= UInt64(r.remaining / 9) else { throw ParseError.truncated }
        var outputs = [UTXOTxOut]()
        outputs.reserveCapacity(Int(outputCount))
        for _ in 0..<outputCount {
            let value = try r.uint64()
            outputs.append(UTXOTxOut(value: value, scriptPubKey: try r.varBytes()))
        }
        if witnessFlag == 1 {
            for index in inputs.indices {
                let items = try r.compactSize()
                guard items <= UInt64(r.remaining) else { throw ParseError.truncated }
                var stack = [[UInt8]]()
                for _ in 0..<items { stack.append(try r.varBytes()) }
                inputs[index].witness = stack
            }
            guard inputs.contains(where: { !$0.witness.isEmpty }) else { throw ParseError.superfluousWitness }
        }
        lockTime = try r.uint32()
        guard r.remaining == 0 else { throw ParseError.trailingBytes }
        self.inputs = inputs
        self.outputs = outputs
    }

    public init(hex: String) throws {
        guard let raw = Hex.decode(hex) else { throw ParseError.truncated }
        try self.init(parsing: raw)
    }
}

// MARK: Bytes

/// Escrita little-endian e CompactSize, como o `CDataStream` do Core.
struct UTXOByteWriter {
    private(set) var data: [UInt8] = []

    mutating func uint8(_ v: UInt8) { data.append(v) }
    mutating func uint32(_ v: UInt32) { data.append(contentsOf: v.littleEndianByteArray) }
    mutating func uint64(_ v: UInt64) { data.append(contentsOf: v.littleEndianByteArray) }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }

    mutating func compactSize(_ n: UInt64) {
        switch n {
        case 0..<0xFD: data.append(UInt8(n))
        case 0xFD...0xFFFF:
            data.append(0xFD)
            data.append(contentsOf: UInt16(n).littleEndianByteArray)
        case 0x1_0000...0xFFFF_FFFF:
            data.append(0xFE)
            data.append(contentsOf: UInt32(n).littleEndianByteArray)
        default:
            data.append(0xFF)
            data.append(contentsOf: n.littleEndianByteArray)
        }
    }

    mutating func varBytes(_ b: [UInt8]) {
        compactSize(UInt64(b.count))
        data.append(contentsOf: b)
    }

    mutating func output(_ o: UTXOTxOut) {
        uint64(o.value)
        varBytes(o.scriptPubKey)
    }

    static func compactSizeLength(_ n: Int) -> Int {
        switch n {
        case 0..<0xFD: return 1
        case 0xFD...0xFFFF: return 3
        case 0x1_0000...0xFFFF_FFFF: return 5
        default: return 9
        }
    }
}

/// Leitura que nunca passa do fim e recusa CompactSize nao canonico.
struct UTXOByteReader {
    private let data: [UInt8]
    private var offset = 0

    init(_ data: [UInt8]) { self.data = data }

    var remaining: Int { data.count - offset }

    mutating func uint8() throws -> UInt8 {
        guard remaining >= 1 else { throw UTXOTransaction.ParseError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw UTXOTransaction.ParseError.truncated }
        defer { offset += n }
        return Array(data[offset..<offset + n])
    }

    mutating func uint16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func uint32() throws -> UInt32 {
        let b = try bytes(4)
        return b.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    mutating func uint64() throws -> UInt64 {
        let b = try bytes(8)
        return b.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    /// CompactSize com as regras do `ReadCompactSize` do Core: forma minima e teto
    /// de 32 MiB (MAX_SIZE).
    mutating func compactSize() throws -> UInt64 {
        let first = try uint8()
        let value: UInt64
        switch first {
        case 0xFD:
            value = UInt64(try uint16())
            guard value >= 0xFD else { throw UTXOTransaction.ParseError.nonCanonicalCompactSize }
        case 0xFE:
            value = UInt64(try uint32())
            guard value > 0xFFFF else { throw UTXOTransaction.ParseError.nonCanonicalCompactSize }
        case 0xFF:
            value = try uint64()
            guard value > 0xFFFF_FFFF else { throw UTXOTransaction.ParseError.nonCanonicalCompactSize }
        default:
            value = UInt64(first)
        }
        guard value <= 0x0200_0000 else { throw UTXOTransaction.ParseError.sizeTooLarge }
        return value
    }

    mutating func varBytes() throws -> [UInt8] {
        let n = try compactSize()
        guard n <= UInt64(remaining) else { throw UTXOTransaction.ParseError.truncated }
        return try bytes(Int(n))
    }
}
