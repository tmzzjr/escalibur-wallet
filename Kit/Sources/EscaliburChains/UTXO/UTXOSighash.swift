import EscaliburCore
import Foundation

/// O digesto que cada entrada assina.
///
/// Dois algoritmos, ambos calculados aqui a partir dos campos da transacao, nunca
/// recebidos de fora:
/// - **Legado** (`SignatureHash` com `SigVersion::BASE` do Core): P2PKH, que e o que
///   o Dogecoin usa. Nao compromete o valor da entrada; por isso a transacao
///   anterior inteira e conferida antes (ver `UTXOPreviousOutput`).
/// - **BIP-143** (segwit v0): P2WPKH e P2SH-P2WPKH. Compromete o valor, e uma
///   assinatura sobre valor errado simplesmente nao vale na rede.
public enum UTXOSighash {
    public static let all: UInt32 = 0x01
    public static let none: UInt32 = 0x02
    public static let single: UInt32 = 0x03
    public static let anyoneCanPay: UInt32 = 0x80

    // MARK: Legado

    /// Digesto legado, byte a byte como o `CTransactionSignatureSerializer` do Core,
    /// inclusive o caso historico de SIGHASH_SINGLE sem saida correspondente, que
    /// devolve o numero 1 em vez de falhar.
    ///
    /// `scriptCode` e o script que a entrada gasta (o scriptPubKey anterior, no
    /// P2PKH). OP_CODESEPARATOR e removido dele, como no Core.
    public static func legacy(transaction tx: UTXOTransaction, inputIndex: Int, scriptCode: [UInt8], hashType: UInt32) -> [UInt8] {
        let one = [UInt8(1)] + [UInt8](repeating: 0, count: 31)
        guard inputIndex >= 0, inputIndex < tx.inputs.count else { return one }
        let base = hashType & 0x1F
        let anyoneCanPay = hashType & anyoneCanPay != 0
        let hashSingle = base == single
        let hashNone = base == none
        if hashSingle, inputIndex >= tx.outputs.count { return one }

        var w = UTXOByteWriter()
        w.uint32(tx.version)
        let inputIndices = anyoneCanPay ? [inputIndex] : Array(tx.inputs.indices)
        w.compactSize(UInt64(inputIndices.count))
        for i in inputIndices {
            let input = tx.inputs[i]
            w.bytes(input.outpoint.txid.bytes)
            w.uint32(input.outpoint.vout)
            if i == inputIndex {
                w.bytes(serializedScriptCode(scriptCode))
            } else {
                w.compactSize(0)
            }
            w.uint32(i != inputIndex && (hashSingle || hashNone) ? 0 : input.sequence)
        }
        let outputCount = hashNone ? 0 : (hashSingle ? inputIndex + 1 : tx.outputs.count)
        w.compactSize(UInt64(outputCount))
        for i in 0..<outputCount {
            if hashSingle && i != inputIndex {
                // CTxOut() vazio: valor -1 e script vazio.
                w.uint64(UInt64.max)
                w.compactSize(0)
            } else {
                w.output(tx.outputs[i])
            }
        }
        w.uint32(tx.lockTime)
        w.uint32(hashType)
        return Hash.sha256d(w.data)
    }

    /// O scriptCode com CompactSize, sem os OP_CODESEPARATOR. Percorre o script com
    /// a mesma leitura de opcode do Core (`GetScriptOp`), para nao apagar um byte
    /// 0xab que esteja dentro de um push de dados. Script truncado no meio de um
    /// push e reproduzido como o Core reproduz: ate o ponto em que a leitura parou.
    static func serializedScriptCode(_ script: [UInt8]) -> [UInt8] {
        let codeSeparator: UInt8 = 0xAB
        var separators = 0
        var pc = 0
        while let (opcode, next) = scriptOp(script, at: pc) {
            if opcode == codeSeparator { separators += 1 }
            pc = next
        }
        var w = UTXOByteWriter()
        w.compactSize(UInt64(script.count - separators))
        var begin = 0
        pc = 0
        var stoppedAt = 0
        while true {
            guard let (opcode, next) = scriptOp(script, at: pc) else {
                stoppedAt = scriptOpStop(script, at: pc)
                break
            }
            if opcode == codeSeparator {
                w.bytes(Array(script[begin..<(next - 1)]))
                begin = next
            }
            pc = next
        }
        if begin != script.count {
            w.bytes(Array(script[begin..<max(begin, min(stoppedAt, script.count))]))
        }
        return w.data
    }

    /// Le um opcode em `pc`. Devolve o opcode e a posicao seguinte, ou `nil` no fim
    /// ou num push que passa do fim.
    private static func scriptOp(_ s: [UInt8], at pc: Int) -> (UInt8, Int)? {
        guard pc < s.count else { return nil }
        let opcode = s[pc]
        var p = pc + 1
        var size = 0
        switch opcode {
        case 0x00..<0x4C: size = Int(opcode)
        case 0x4C:
            guard s.count - p >= 1 else { return nil }
            size = Int(s[p]); p += 1
        case 0x4D:
            guard s.count - p >= 2 else { return nil }
            size = Int(s[p]) | Int(s[p + 1]) << 8; p += 2
        case 0x4E:
            guard s.count - p >= 4 else { return nil }
            size = (0..<4).reduce(0) { $0 | Int(s[p + $1]) << (8 * $1) }; p += 4
        default: size = 0
        }
        guard s.count - p >= size else { return nil }
        return (opcode, p + size)
    }

    /// Onde o `GetScriptOp` do Core deixa o iterador quando falha: depois do
    /// opcode e dos bytes de tamanho que conseguiu ler.
    private static func scriptOpStop(_ s: [UInt8], at pc: Int) -> Int {
        guard pc < s.count else { return pc }
        let opcode = s[pc]
        let p = pc + 1
        switch opcode {
        case 0x4C: return s.count - p >= 1 ? p + 1 : p
        case 0x4D: return s.count - p >= 2 ? p + 2 : p
        case 0x4E: return s.count - p >= 4 ? p + 4 : p
        default: return p
        }
    }

    // MARK: BIP-143

    /// Digesto segwit v0 (BIP-143).
    ///
    /// `scriptCode` e o script sem o CompactSize: no P2WPKH e P2SH-P2WPKH,
    /// `76a914{hash160(pub)}88ac`. `amount` e o valor da saida gasta.
    public static func segwitV0(transaction tx: UTXOTransaction, inputIndex: Int, scriptCode: [UInt8], amount: UInt64, hashType: UInt32) -> [UInt8] {
        precondition(inputIndex >= 0 && inputIndex < tx.inputs.count, "indice de entrada fora da transacao")
        let parts = bip143Parts(tx, inputIndex: inputIndex, hashType: hashType)
        let input = tx.inputs[inputIndex]
        var w = UTXOByteWriter()
        w.uint32(tx.version)
        w.bytes(parts.hashPrevouts)
        w.bytes(parts.hashSequence)
        w.bytes(input.outpoint.txid.bytes)
        w.uint32(input.outpoint.vout)
        w.varBytes(scriptCode)
        w.uint64(amount)
        w.uint32(input.sequence)
        w.bytes(parts.hashOutputs)
        w.uint32(tx.lockTime)
        w.uint32(hashType)
        return Hash.sha256d(w.data)
    }

    /// Os tres digestos intermediarios, expostos para conferir contra o BIP.
    static func bip143Parts(_ tx: UTXOTransaction, inputIndex: Int, hashType: UInt32) -> (hashPrevouts: [UInt8], hashSequence: [UInt8], hashOutputs: [UInt8]) {
        let zero = [UInt8](repeating: 0, count: 32)
        let base = hashType & 0x1F
        let anyoneCanPay = hashType & anyoneCanPay != 0

        var prevouts = zero
        if !anyoneCanPay {
            var w = UTXOByteWriter()
            for input in tx.inputs {
                w.bytes(input.outpoint.txid.bytes)
                w.uint32(input.outpoint.vout)
            }
            prevouts = Hash.sha256d(w.data)
        }
        var sequences = zero
        if !anyoneCanPay, base != single, base != none {
            var w = UTXOByteWriter()
            for input in tx.inputs { w.uint32(input.sequence) }
            sequences = Hash.sha256d(w.data)
        }
        var outputs = zero
        if base != single, base != none {
            var w = UTXOByteWriter()
            for output in tx.outputs { w.output(output) }
            outputs = Hash.sha256d(w.data)
        } else if base == single, inputIndex < tx.outputs.count {
            var w = UTXOByteWriter()
            w.output(tx.outputs[inputIndex])
            outputs = Hash.sha256d(w.data)
        }
        return (prevouts, sequences, outputs)
    }
}
