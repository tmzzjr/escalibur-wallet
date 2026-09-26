import EscaliburCore
import Foundation

// O decodificador ABI estrito.
//
// Ele existe para ler calldata que outra pessoa montou (a de um router de swap, a de
// um dApp) e dizer exatamente o que ela faz. Um decodificador tolerante e um
// decodificador que dois programas leem diferente: se a carteira aceita um offset
// que aponta para tras, ou lixo no preenchimento, ela pode mostrar um valor na tela
// enquanto o contrato le outro. Por isso so a **codificacao canonica** passa, a
// mesma que o solc e as bibliotecas de referencia produzem:
//
// - cada offset aponta exatamente para o fim do dado dinamico anterior (sem
//   lacuna, sem sobreposicao, sem voltar para a cabeca);
// - preenchimento e sempre zero; `uint<N>`, `address` e `bytes<N>` sem bit sobrando;
//   `int<N>` com extensao de sinal exata; bool so 0 ou 1;
// - comprimento de bytes, string e array cabe no que resta do buffer, conferido
//   antes de alocar qualquer coisa;
// - string e UTF-8 valido;
// - nenhum byte sobra no fim.
//
// Como cada byte e lido uma vez so, a decodificacao e linear no tamanho da entrada:
// calldata maliciosa nao consegue fazer o app alocar mais que ela mesma.

extension ABI {
    /// Decodifica `abi.encode(...)` de `types`. Recusa qualquer byte sobrando.
    public static func decode(_ types: [ABIType], from data: [UInt8]) throws -> [ABIValue] {
        let (values, trailing) = try decodePrefix(types, from: data)
        guard trailing.isEmpty else { throw ABIError.trailingBytes(trailing.count) }
        return values
    }

    /// Como `decode`, mas devolve os bytes que sobram depois da codificacao em vez de
    /// recusar. Existe para routers que anexam dados ao fim da calldata: quem chama
    /// tem de olhar o que sobrou e decidir, nunca ignorar.
    public static func decodePrefix(_ types: [ABIType], from data: [UInt8]) throws -> (values: [ABIValue], trailing: [UInt8]) {
        for type in types { try type.validate() }
        guard data.count <= maxEncodedSize else { throw ABIError.typeTooLarge }
        let reader = ABIReader(data: data)
        let (values, end) = try reader.decodeTuple(types, at: 0)
        return (values, Array(data[end...]))
    }
}

struct ABIReader {
    let data: [UInt8]

    /// Decodifica uma tupla que comeca em `base`. Devolve os valores e a posicao
    /// logo depois do ultimo byte que ela ocupa (cabeca mais rabo).
    func decodeTuple(_ types: [ABIType], at base: Int) throws -> ([ABIValue], Int) {
        var headSize = 0
        for type in types {
            let (sum, overflow) = headSize.addingReportingOverflow(try type.headSize())
            guard !overflow else { throw ABIError.typeTooLarge }
            headSize = sum
        }
        guard base <= data.count, headSize <= data.count - base else { throw ABIError.truncated }

        var head = base
        var tail = base + headSize
        var values = [ABIValue]()
        values.reserveCapacity(types.count)
        for type in types {
            if type.isDynamic {
                let offset = try readSize(at: head)
                // A codificacao canonica poe cada dado dinamico logo depois do
                // anterior. Qualquer outro valor e lacuna, sobreposicao ou ponteiro
                // para a cabeca, e a carteira nao decide entre leituras possiveis.
                guard offset == tail - base else { throw ABIError.nonCanonicalOffset }
                let (value, end) = try decodeDynamic(type, at: tail)
                values.append(value)
                tail = end
                head += 32
            } else {
                values.append(try decodeStatic(type, at: head))
                head += try type.headSize()
            }
        }
        return (values, tail)
    }

    /// Tipo dinamico no endereco `position`. Devolve o valor e onde ele termina.
    func decodeDynamic(_ type: ABIType, at position: Int) throws -> (ABIValue, Int) {
        switch type {
        case .bytes, .string:
            let length = try readSize(at: position)
            let start = position + 32
            let padded = (length + 31) / 32 * 32
            guard padded <= data.count - start else { throw ABIError.lengthOutOfBounds }
            let raw = Array(data[start..<(start + length)])
            guard data[(start + length)..<(start + padded)].allSatisfy({ $0 == 0 }) else { throw ABIError.dirtyPadding }
            if case .string = type {
                guard ABIReader.isValidUTF8(raw) else { throw ABIError.invalidUTF8 }
                return (.string(String(decoding: raw, as: UTF8.self)), start + padded)
            }
            return (.bytes(raw), start + padded)
        case .array(let element):
            let count = try readSize(at: position)
            let start = position + 32
            // Cada elemento ocupa pelo menos 32 bytes na cabeca. Conferir antes de
            // montar a lista de tipos evita que um comprimento de 2^32 aloque memoria.
            let elementHead = try element.headSize()
            let (needed, overflow) = count.multipliedReportingOverflow(by: elementHead)
            guard !overflow, needed <= data.count - start else { throw ABIError.lengthOutOfBounds }
            let (items, end) = try decodeTuple(Array(repeating: element, count: count), at: start)
            return (.array(items), end)
        case .fixedArray(let element, let count):
            let (items, end) = try decodeTuple(Array(repeating: element, count: count), at: position)
            return (.array(items), end)
        case .tuple(let components):
            let (items, end) = try decodeTuple(components, at: position)
            return (.tuple(items), end)
        default:
            throw ABIError.typeMismatch(expected: type.description)
        }
    }

    /// Tipo estatico no endereco `position` da cabeca (os limites ja foram
    /// conferidos por quem chamou).
    func decodeStatic(_ type: ABIType, at position: Int) throws -> ABIValue {
        switch type {
        case .address:
            let word = self.word(at: position)
            guard word.prefix(12).allSatisfy({ $0 == 0 }) else { throw ABIError.dirtyPadding }
            return .address(EVMAddress(uncheckedBytes: Array(word.suffix(20))))
        case .uint(let bits):
            let value = BigUInt(bigEndian: word(at: position))
            guard value.bitWidth <= bits else { throw ABIError.dirtyPadding }
            return .uint(value)
        case .int(let bits):
            let value = ABISignedInteger.fromWord(word(at: position))
            // Fora da faixa de int<N> significa que os bits altos nao sao a extensao
            // exata do sinal.
            guard value.fits(bits: bits) else { throw ABIError.dirtyPadding }
            return .int(value)
        case .bool:
            let word = self.word(at: position)
            guard word.prefix(31).allSatisfy({ $0 == 0 }), word[31] <= 1 else { throw ABIError.invalidBool }
            return .bool(word[31] == 1)
        case .fixedBytes(let size):
            let word = self.word(at: position)
            guard word.suffix(32 - size).allSatisfy({ $0 == 0 }) else { throw ABIError.dirtyPadding }
            return .fixedBytes(Array(word.prefix(size)))
        case .fixedArray(let element, let count):
            let (items, _) = try decodeTuple(Array(repeating: element, count: count), at: position)
            return .array(items)
        case .tuple(let components):
            let (items, _) = try decodeTuple(components, at: position)
            return .tuple(items)
        default:
            throw ABIError.typeMismatch(expected: type.description)
        }
    }

    func word(at position: Int) -> [UInt8] {
        Array(data[position..<(position + 32)])
    }

    /// Uma palavra usada como offset ou comprimento. Precisa caber no buffer: tudo
    /// acima disso e invalido por definicao, e ler como numero enorme so serviria
    /// para estourar conta mais adiante.
    func readSize(at position: Int) throws -> Int {
        guard position >= 0, position <= data.count - 32 else { throw ABIError.truncated }
        let word = self.word(at: position)
        guard word.prefix(28).allSatisfy({ $0 == 0 }) else { throw ABIError.lengthOutOfBounds }
        let value = word.suffix(4).reduce(0) { $0 << 8 | Int($1) }
        guard value <= data.count else { throw ABIError.lengthOutOfBounds }
        return value
    }

    /// UTF-8 estrito pelo decodificador da biblioteca padrao: recusa sequencia
    /// incompleta, forma longa, surrogate e ponto acima de U+10FFFF.
    static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        var iterator = bytes.makeIterator()
        var parser = Unicode.UTF8.ForwardParser()
        while true {
            switch parser.parseScalar(from: &iterator) {
            case .valid: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }
}
