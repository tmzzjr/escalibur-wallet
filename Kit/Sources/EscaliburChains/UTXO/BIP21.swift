import EscaliburCore
import Foundation

/// URI de pagamento (BIP-21): `bitcoin:`, `litecoin:` e `dogecoin:`.
///
/// Parse estrito, porque a URI vem de QR ou de link, isto e, de um estranho:
/// - tamanho limitado antes de qualquer trabalho;
/// - o esquema decide a rede, e endereco de outra rede e recusado;
/// - `amount` so em decimal com ponto e ate 8 casas, sem sinal nem expoente;
/// - parametro `req-` desconhecido invalida a URI inteira (regra do BIP);
/// - parametro repetido, percent-encoding quebrado, UTF-8 invalido, caractere de
///   controle ou de direcao de texto no rotulo: recusado. Um rotulo com U+202E
///   reordena o que a tela mostra, e o dono le outra coisa.
public struct BIP21URI: Equatable, Sendable {
    public let chain: Chain
    public let destination: Address.Destination
    /// Valor pedido na unidade da rede (satoshi, litoshi, koinu).
    public let amount: BigUInt?
    public let label: String?
    public let message: String?

    public enum Problem: Error, Equatable, Sendable {
        case tooLong
        case unknownScheme
        /// A URI e de outra rede UTXO.
        case wrongChain(Chain)
        case invalidAddress(Address.Problem)
        case invalidAmount
        case duplicateParameter(String)
        case unsupportedRequiredParameter(String)
        case invalidEncoding
        case parameterTooLong(String)
        case malformed
    }

    /// Teto da URI inteira. Cabe endereco, valor, rotulo, mensagem e ainda uma
    /// fatura Lightning, que a carteira ignora.
    public static let maxLength = 2048
    /// Teto de rotulo e mensagem depois de decodificados.
    public static let maxTextLength = 256

    static let schemes: [(String, Chain)] = [("bitcoin", .bitcoin), ("litecoin", .litecoin), ("dogecoin", .dogecoin)]

    /// Le a URI. `expected` e a rede da tela de envio aberta: URI de outra rede e
    /// recusada com o motivo, em vez de trocar a rede por conta propria.
    public static func parse(_ text: String, expected: Chain? = nil) throws -> BIP21URI {
        guard text.utf8.count <= maxLength else { throw Problem.tooLong }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { throw Problem.unknownScheme }
        let scheme = trimmed[..<colon].lowercased()
        guard let chain = schemes.first(where: { $0.0 == scheme })?.1 else { throw Problem.unknownScheme }
        if let expected, expected.id != chain.id { throw Problem.wrongChain(chain) }

        let rest = trimmed[trimmed.index(after: colon)...]
        let addressPart: Substring
        let query: Substring?
        if let mark = rest.firstIndex(of: "?") {
            addressPart = rest[..<mark]
            query = rest[rest.index(after: mark)...]
        } else {
            addressPart = rest
            query = nil
        }
        // O endereco vai cru: nada de percent-encoding, barras ou fragmento nele.
        guard !addressPart.isEmpty, addressPart.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw Problem.malformed
        }
        let destination: Address.Destination
        switch Address.validate(String(addressPart), for: chain) {
        case .success(let d): destination = d
        case .failure(let problem): throw Problem.invalidAddress(problem)
        }

        var amount: BigUInt?
        var label: String?
        var message: String?
        var seen = Set<String>()
        if let query {
            guard !query.contains("#") else { throw Problem.malformed }
            for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
                guard !pair.isEmpty else { throw Problem.malformed }
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts[0])
                let rawValue = parts.count == 2 ? String(parts[1]) : ""
                guard !key.isEmpty else { throw Problem.malformed }
                guard seen.insert(key).inserted else { throw Problem.duplicateParameter(key) }
                switch key {
                case "amount":
                    amount = try parseAmount(rawValue, chain: chain)
                case "label":
                    label = try decodeText(rawValue, key: key)
                case "message":
                    message = try decodeText(rawValue, key: key)
                case "address":
                    // Um segundo endereco na query e ambiguidade que so serve a golpe.
                    throw Problem.malformed
                default:
                    if key.hasPrefix("req-") { throw Problem.unsupportedRequiredParameter(key) }
                    // Parametro opcional desconhecido (lightning, pj...) e ignorado, como
                    // manda o BIP.
                }
            }
        }
        return BIP21URI(chain: chain, destination: destination, amount: amount, label: label, message: message)
    }

    /// Decimal na unidade cheia (BTC, LTC, DOGE) para a unidade da rede. So digitos e
    /// um ponto, ate 8 casas, maior que zero e ate o MAX_MONEY da rede.
    static func parseAmount(_ text: String, chain: Chain) throws -> BigUInt {
        let decimals = chain.nativeDecimals
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw Problem.invalidAmount }
        let whole = String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        let isDigits = { (s: String) in s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
        guard !(whole.isEmpty && fraction.isEmpty), isDigits(whole), isDigits(fraction), fraction.count <= decimals,
              whole.count <= 12
        else { throw Problem.invalidAmount }
        let padded = (whole.isEmpty ? "0" : whole) + fraction + String(repeating: "0", count: decimals - fraction.count)
        guard let value = BigUInt(decimal: padded), !value.isZero,
              let units = value.uint64, units <= UTXORules.for(chain).maxMoney
        else { throw Problem.invalidAmount }
        return value
    }

    /// Percent-decoding do RFC 3986 (sem `+` virando espaco), UTF-8 valido, sem
    /// controle nem caractere de direcao.
    static func decodeText(_ raw: String, key: String) throws -> String {
        var bytes = [UInt8]()
        var iterator = Array(raw.utf8).makeIterator()
        while let byte = iterator.next() {
            if byte == 0x25 {  // %
                guard let high = iterator.next(), let low = iterator.next(),
                      let decoded = Hex.decode(String(decoding: [high, low], as: UTF8.self)), decoded.count == 1
                else { throw Problem.invalidEncoding }
                bytes.append(decoded[0])
            } else {
                bytes.append(byte)
            }
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw Problem.invalidEncoding }
        guard text.count <= maxTextLength else { throw Problem.parameterTooLong(key) }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF:
                throw Problem.invalidEncoding
            default:
                continue
            }
        }
        return text
    }
}
