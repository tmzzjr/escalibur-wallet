import Foundation
import Security

/// Quanto vale a senha de um envelope, contado sobre os bytes, sem nunca virar
/// `String`.
///
/// A estimativa e conservadora e simples: palavras sorteadas da lista BIP-39 valem
/// 11 bits cada; o resto e contado por pedacos (sequencia de letras, ano, digitos,
/// simbolos), porque "Bitcoin2024!" tem 12 caracteres e quase nenhuma entropia.
///
/// O piso de 60 bits vale para todo envelope lacrado por esta carteira. Com o piso
/// de 256 MiB, isso passa de milhares de anos para um atacante com o arquivo e um
/// datacenter; abaixo disso, um arquivo que foi parar na nuvem vira questao de meses.
public enum PasswordStrength {
    public static let minimumBits = 60.0

    public enum Verdict: Equatable, Sendable {
        case strong
        /// So digitos, e poucos: PIN nao e senha de envelope.
        case digitsOnly
        case weak(bits: Double)
    }

    public static func verdict(_ password: SecureBytes) -> Verdict {
        let onlyDigits = password.withUnsafeBytes { raw in raw.count > 0 && raw.allSatisfy { (0x30...0x39).contains($0) } }
        if onlyDigits, password.count <= 12 { return .digitsOnly }
        let value = bits(password)
        return value >= minimumBits ? .strong : .weak(bits: value)
    }

    public static func bits(_ password: SecureBytes) -> Double {
        password.withUnsafeBytes { bits(bytes: $0) }
    }

    static func bits(bytes raw: UnsafeRawBufferPointer) -> Double {
        guard raw.count > 0 else { return 0 }
        if let words = wordsBits(raw) { return words }

        var total = 0.0
        var index = 0
        while index < raw.count {
            let byte = raw[index]
            if isLetter(byte) {
                var end = index
                var upper = false
                while end < raw.count, isLetter(raw[end]) { upper = upper || (0x41...0x5A).contains(raw[end]); end += 1 }
                let run = end - index
                // Sequencia de letras: palavra de dicionario (cerca de 15 bits) se for
                // longa, senao letra por letra.
                total += run >= 4 ? 15 + (upper ? 1 : 0) : Double(run) * 4.7
                index = end
            } else if (0x30...0x39).contains(byte) {
                var end = index
                while end < raw.count, (0x30...0x39).contains(raw[end]) { end += 1 }
                let run = end - index
                let isYear = run == 4 && raw[index] == 0x31 && raw[index + 1] == 0x39
                    || run == 4 && raw[index] == 0x32 && raw[index + 1] == 0x30
                total += isYear ? 7 : Double(run) * 3.32
                index = end
            } else if byte >= 0x80 {
                // Um caractere fora do ASCII (acento, emoji): conta como um simbolo.
                var end = index + 1
                while end < raw.count, raw[end] & 0xC0 == 0x80 { end += 1 }
                total += 5
                index = end
            } else {
                total += byte == 0x20 ? 1 : 5
                index += 1
            }
        }
        return total
    }

    /// Tres ou mais palavras da lista BIP-39 inglesa separadas por espaco: 11 bits
    /// cada. Qualquer outra coisa: nil, e a contagem por pedacos decide.
    static func wordsBits(_ raw: UnsafeRawBufferPointer) -> Double? {
        var count = 0
        var token = [UInt8]()
        defer { wipe(&token) }
        func closes() -> Bool {
            defer { wipe(&token); token.removeAll(keepingCapacity: true) }
            guard !token.isEmpty, englishWords.contains(token) else { return false }
            count += 1
            return true
        }
        for byte in raw {
            if byte == 0x20 {
                guard closes() else { return nil }
            } else {
                token.append((0x41...0x5A).contains(byte) ? byte + 0x20 : byte)
            }
        }
        guard closes(), count >= 3 else { return nil }
        return Double(count) * 11
    }

    private static let englishWords: Set<[UInt8]> = {
        guard let list = try? WordlistStore.shared.wordlist(for: .english) else { return [] }
        return Set(list.words.map { Array($0.utf8) })
    }()

    private static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { if let base = $0.baseAddress { memset_s(base, $0.count, 0, $0.count) } }
    }

    /// Seis palavras BIP-39 sorteadas: 66 bits. Nenhuma pode estar na frase da
    /// propria carteira, para o papel da frase nunca abrir o envelope.
    public static func suggestion(avoiding phrase: SecureBytes?, count: Int = 6) throws -> [String] {
        let list = try WordlistStore.shared.wordlist(for: .english)
        var avoid = Set<Int>()
        if let phrase {
            phrase.withUnsafeBytes { raw in
                var token = [UInt8]()
                for byte in raw + [0x20] {
                    if byte == 0x20 {
                        if let position = list.position(of: String(decoding: token, as: UTF8.self)) { avoid.insert(Int(position)) }
                        wipe(&token)
                        token.removeAll(keepingCapacity: true)
                    } else {
                        token.append(byte)
                    }
                }
            }
        }
        var chosen: [Int] = []
        while chosen.count < count {
            var bytes = [UInt8](repeating: 0, count: 2)
            guard SecRandomCopyBytes(kSecRandomDefault, 2, &bytes) == errSecSuccess else { throw CryptoError.randomnessUnavailable }
            // 2048 divide 65536: pegar 11 bits de 16 nao tem vies.
            let index = (Int(bytes[0]) << 8 | Int(bytes[1])) & 0x7FF
            if !avoid.contains(index), !chosen.contains(index) { chosen.append(index) }
        }
        return chosen.map { list.words[$0] }
    }

    /// A senha usa duas ou mais palavras da propria frase? Quem achar o papel da
    /// frase teria meio caminho andado.
    public static func reusesPhrase(_ password: SecureBytes, phrase: SecureBytes) -> Bool {
        func tokens(_ secret: SecureBytes) -> [[UInt8]] {
            secret.withUnsafeBytes { raw in
                var out: [[UInt8]] = []
                var token = [UInt8]()
                for byte in raw {
                    if isLetter(byte) { token.append((0x41...0x5A).contains(byte) ? byte + 0x20 : byte) } else if !token.isEmpty { out.append(token); token = [] }
                }
                if !token.isEmpty { out.append(token) }
                return out
            }
        }
        var typed = tokens(password)
        var words = tokens(phrase)
        defer {
            for index in typed.indices { wipe(&typed[index]) }
            for index in words.indices { wipe(&words[index]) }
        }
        let set = Set(words)
        return typed.filter { set.contains($0) }.count >= 2
    }
}
