import EscaliburCore
import Foundation

/// Pedido de pagamento `ethereum:` (ERC-681), lido de QR code ou link.
///
/// Leitura estrita, porque o URI chega de fora e decide destino e valor:
/// - so endereco hex (`0x` + 40 digitos), com checksum EIP-55 conferido se vier em
///   caixa mista; nome ENS e recusado (resolver nome e trabalho de rede, e o golpe
///   classico e o nome parecido);
/// - `chain_id`, se vier, tem de ser uma das redes compiladas; sem ele, a rede fica
///   `nil` e a interface escolhe e mostra;
/// - so pagamento nativo ou `transfer` de ERC-20; qualquer outra funcao e recusada;
/// - numero inteiro, sem sinal, aceita notacao cientifica exata (`2.014e18`), e nada
///   que arredonde;
/// - parametro repetido, desconhecido ou com `%` e recusado;
/// - `gas`, `gasLimit` e `gasPrice` sao lidos (para validar a forma) e descartados:
///   a carteira estima a taxa sozinha.
public struct EIP681Request: Sendable, Equatable {
    public enum Payment: Sendable, Equatable {
        /// Pagamento no nativo da rede, `amount` em wei.
        case native(recipient: EVMAddress, amount: BigUInt?)
        /// `transfer` de ERC-20, `amount` em unidades atomicas do token. A interface
        /// so mostra valor se o contrato estiver na lista curada, com os decimais dela.
        case token(contract: EVMAddress, recipient: EVMAddress, amount: BigUInt?)
    }

    public enum Problem: Error, Equatable, Sendable {
        case notEthereumURI
        case ensNotSupported
        case invalidAddress(Address.Problem)
        case invalidChainID
        case unsupportedChain(String)
        case unsupportedFunction(String)
        case invalidParameter(String)
        case duplicateParameter(String)
        case unknownParameter(String)
        case missingParameter(String)
        case invalidNumber(String)
        /// `value` diferente de zero junto de `transfer`.
        case valueWithTokenTransfer
    }

    public let chain: Chain?
    public let payment: Payment

    public static func parse(_ uri: String) throws -> EIP681Request {
        let text = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        // O esquema e insensivel a caixa (QR alfanumerico vem em maiusculas).
        guard text.lowercased().hasPrefix("ethereum:") else { throw Problem.notEthereumURI }
        var rest = Substring(text.dropFirst("ethereum:".count))
        if rest.hasPrefix("pay-") { rest = rest.dropFirst(4) }
        guard !rest.contains("%") else { throw Problem.invalidParameter("%") }

        // Endereco alvo.
        let targetEnd = rest.firstIndex { $0 == "@" || $0 == "/" || $0 == "?" } ?? rest.endIndex
        let targetText = String(rest[..<targetEnd])
        // Sem `0x` e nome ENS pela gramatica da ERC-681. Com `0x`, tem de ser endereco.
        guard targetText.lowercased().hasPrefix("0x") else { throw Problem.ensNotSupported }
        let target = try address(targetText)
        rest = rest[targetEnd...]

        // chain_id.
        var chain: Chain?
        if rest.hasPrefix("@") {
            rest = rest.dropFirst()
            let end = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
            let digits = rest[..<end]
            guard !digits.isEmpty, digits.count <= 20, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }), digits.first != "0",
                  let id = UInt64(digits)
            else { throw Problem.invalidChainID }
            guard let known = Chain.evmChains.first(where: { $0.evmChainID == id }) else { throw Problem.unsupportedChain(String(digits)) }
            chain = known
            rest = rest[end...]
        }

        // Funcao.
        var function: String?
        if rest.hasPrefix("/") {
            rest = rest.dropFirst()
            let end = rest.firstIndex(of: "?") ?? rest.endIndex
            function = String(rest[..<end])
            rest = rest[end...]
            guard function == "transfer" else { throw Problem.unsupportedFunction(function ?? "") }
        }

        // Parametros.
        var parameters = [String: String]()
        if rest.hasPrefix("?") {
            rest = rest.dropFirst()
            for pair in rest.split(separator: "&", omittingEmptySubsequences: false) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw Problem.invalidParameter(String(pair)) }
                let key = String(parts[0])
                guard parameters[key] == nil else { throw Problem.duplicateParameter(key) }
                parameters[key] = String(parts[1])
            }
        } else if !rest.isEmpty {
            throw Problem.invalidParameter(String(rest))
        }

        // gas, gasLimit e gasPrice: forma conferida, valor descartado.
        for key in ["gas", "gasLimit", "gasPrice"] {
            if let value = parameters.removeValue(forKey: key) { _ = try number(value) }
        }
        let value = try parameters.removeValue(forKey: "value").map(number)

        if function == "transfer" {
            guard value == nil || value?.isZero == true else { throw Problem.valueWithTokenTransfer }
            guard let recipientText = parameters.removeValue(forKey: "address") else { throw Problem.missingParameter("address") }
            let recipient = try address(recipientText)
            let amount = try parameters.removeValue(forKey: "uint256").map(number)
            if let unknown = parameters.keys.sorted().first { throw Problem.unknownParameter(unknown) }
            return EIP681Request(chain: chain, payment: .token(contract: target, recipient: recipient, amount: amount))
        }
        if let unknown = parameters.keys.sorted().first { throw Problem.unknownParameter(unknown) }
        return EIP681Request(chain: chain, payment: .native(recipient: target, amount: value))
    }

    static func address(_ text: String) throws -> EVMAddress {
        do {
            return try EVMAddress(text)
        } catch let problem as Address.Problem {
            throw Problem.invalidAddress(problem)
        }
    }

    /// `DIGITS [ "." DIGITS ] [ ("e" | "E") DIGITS ]`, com resultado inteiro e menor
    /// que 2^256. Sinal nao e aceito: valor negativo nao existe, e `+` em URL vira
    /// espaco em metade dos leitores.
    static func number(_ text: String) throws -> BigUInt {
        let invalid = Problem.invalidNumber(text)
        let lower = text.lowercased()
        let parts = lower.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
        let mantissa = parts[0]
        var exponent = 0
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].count <= 3, parts[1].allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let value = Int(parts[1]), value <= 78
            else { throw invalid }
            exponent = value
        }
        let pieces = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integer = pieces[0]
        let fraction = pieces.count == 2 ? pieces[1] : ""
        guard !integer.isEmpty, integer.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { throw invalid }
        guard pieces.count == 1 || !fraction.isEmpty, fraction.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { throw invalid }
        // So inteiro: as casas depois do ponto tem de caber no expoente.
        guard fraction.count <= exponent else { throw invalid }
        let digits = String(integer) + String(fraction) + String(repeating: "0", count: exponent - fraction.count)
        guard digits.count <= 100, let result = BigUInt(decimal: digits), result.bitWidth <= 256 else { throw invalid }
        return result
    }
}
