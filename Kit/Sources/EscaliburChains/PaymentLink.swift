import EscaliburCore
import Foundation

/// O endereco de um QR ou de um link de pagamento (BIP-21, EIP-681, "xrpl:",
/// "solana:", "ton://transfer/", SEP-7 da Stellar), e a tag ou o memo quando o link
/// traz um. Valor e rotulo do link sao ignorados: o dono digita.
///
/// O EIP-681 passa pela leitura estrita do `EIP681Request`: num pedido de token, o
/// endereco logo depois de "ethereum:" e o contrato, e quem recebe vem em `address=`.
/// Cortar o texto no "/" mandava o token para o proprio contrato (auditoria 2, B5).
///
/// A tag e o memo antes eram descartados sem aviso: o QR de deposito de uma corretora no
/// XRP Ledger virava so o endereco, e o deposito sem tag nao era creditado (auditoria 4,
/// B5). Agora vao para o campo, mostrados para o dono conferir.
public enum PaymentLink {
    public struct Reading: Equatable, Sendable {
        public let address: String
        /// A rede que o link pede, quando ele diz (EIP-681 com `@chain_id`).
        public let chainID: String?
        /// A tag de destino ou o memo que o link traz: `dt` do XRP Ledger, `text` da TON,
        /// `memo` do SEP-7. Nil quando nao traz.
        public let tag: String?

        init(address: String, chainID: String?, tag: String? = nil) {
            self.address = address
            self.chainID = chainID
            self.tag = tag
        }
    }

    public enum Problem: Error, Equatable, Sendable {
        case tooLong
        /// Pedido `ethereum:` que a leitura estrita recusou (ENS, funcao desconhecida,
        /// rede fora da lista, parametro repetido).
        case invalidEthereumRequest(EIP681Request.Problem)
        /// O codigo traz palavras de uma senha de carteira (ou um SeedQR), nao um
        /// endereco: nunca vai para o campo do destino (auditoria 4, C7-13).
        case containsPhrase
        /// Pedido da Stellar que nao e de pagamento (`tx`), ou sem destino.
        case unsupportedStellarRequest
        /// Memo que o app nao envia (hash, retorno), ou memo de texto so com numeros, que o
        /// app enviaria como memo ID: o dono digita o memo a mao, conferindo.
        case unsupportedMemo
        /// O mesmo parametro duas vezes no trecho que o app le.
        case duplicateParameter(String)
        /// Tag ou memo com caractere invisivel, de controle ou espaco nas pontas, longo
        /// demais, ou com duas tags (X-address do XRP Ledger, que ja traz a sua, e um `dt`).
        case invalidTag
    }

    public static let maxLength = 512
    static let maxTagLength = 64

    public static func read(_ text: String) throws -> Reading {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maxLength else { throw Problem.tooLong }
        guard !looksLikePhrase(trimmed) else { throw Problem.containsPhrase }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("ethereum:") {
            let request: EIP681Request
            do { request = try EIP681Request.parse(trimmed) } catch let problem as EIP681Request.Problem {
                throw Problem.invalidEthereumRequest(problem)
            }
            switch request.payment {
            case .native(let recipient, _), .token(_, let recipient, _):
                return Reading(address: recipient.description, chainID: request.chain?.id)
            }
        }
        if lower.hasPrefix("web+stellar:") { return try stellarRequest(trimmed) }
        if lower.hasPrefix("ton://transfer/") {
            let rest = trimmed.dropFirst("ton://transfer/".count)
            let address = String(rest.prefix { $0 != "?" && $0 != "/" })
            return Reading(address: address, chainID: nil, tag: try tag("text", in: trimmed))
        }
        var body = Substring(trimmed)
        var scheme = ""
        if let colon = body.firstIndex(of: ":"), body[..<colon].allSatisfy({ $0.isLetter }) {
            scheme = body[..<colon].lowercased()
            body = body[body.index(after: colon)...]
        }
        if body.hasPrefix("pay-") { body = body.dropFirst(4) }
        let address = String(body.prefix { $0 != "?" && $0 != "@" && $0 != "/" })
        let found = ["xrpl", "ripple"].contains(scheme) ? try tag("dt", in: trimmed) : nil
        // O X-address ja traz a tag dele: um `dt` junto e uma segunda tag disputando o
        // credito, sem leitura segura.
        if found != nil, address.hasPrefix("X") { throw Problem.invalidTag }
        return Reading(address: address, chainID: nil, tag: found)
    }

    /// SEP-7: `web+stellar:pay?destination=G...&memo=...&memo_type=MEMO_ID`. So o destino
    /// e o memo; o memo de texto so com numeros e recusado, porque o app o enviaria como
    /// memo ID (`StellarEngineSupport.memo`).
    static func stellarRequest(_ text: String) throws -> Reading {
        let operation = text.dropFirst("web+stellar:".count).prefix { $0 != "?" }.lowercased()
        guard operation == "pay", let destination = try parameter("destination", in: text), !destination.isEmpty else {
            throw Problem.unsupportedStellarRequest
        }
        guard let memo = try tag("memo", in: text), !memo.isEmpty else {
            return Reading(address: destination, chainID: nil)
        }
        switch (try parameter("memo_type", in: text) ?? "MEMO_TEXT").uppercased() {
        case "MEMO_ID":
            // Na forma que o app envia como ID: so digitos, sem zero a esquerda. "007" ou
            // "+5" sairiam como memo de texto.
            let digits = memo.utf8.allSatisfy { (0x30...0x39).contains($0) }
            guard digits, memo == "0" || !memo.hasPrefix("0"), UInt64(memo) != nil else { throw Problem.unsupportedMemo }
        case "MEMO_TEXT":
            guard !memo.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { throw Problem.unsupportedMemo }
        default:
            throw Problem.unsupportedMemo
        }
        return Reading(address: destination, chainID: nil, tag: memo)
    }

    /// Um parametro da query, decodificado e inteiro (o destino M da Stellar tem 69
    /// caracteres; cortar quebrava o endereco). Repetido e recusado: duas tags no mesmo
    /// link nao tem leitura segura.
    static func parameter(_ name: String, in text: String) throws -> String? {
        guard let question = text.firstIndex(of: "?") else { return nil }
        var found: String?
        for pair in text[text.index(after: question)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.first.map({ $0.lowercased() == name }) == true else { continue }
            guard found == nil else { throw Problem.duplicateParameter(name) }
            let raw = parts.count > 1 ? String(parts[1]) : ""
            found = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        }
        return found
    }

    /// A tag ou o memo do link, que vai para o campo do dono: ate `maxTagLength`, sem
    /// caractere de controle ou de formato (largura zero, direcao do texto, que fazem
    /// "54321" parecer "12345") e sem espaco nas pontas. Fora disso, recusa: nada e cortado
    /// em silencio (revisao da auditoria 4, B-2 e B-3).
    static func tag(_ name: String, in text: String) throws -> String? {
        guard let value = try parameter(name, in: text) else { return nil }
        guard value.count <= maxTagLength, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { throw Problem.invalidTag }
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned: throw Problem.invalidTag
            default: continue
            }
        }
        return value
    }

    /// Doze palavras ou mais separadas por espaco (nenhum endereco tem espaco), ou o
    /// SeedQR padrao: 48 ou 96 digitos, os indices de 12 ou 24 palavras.
    static func looksLikePhrase(_ text: String) -> Bool {
        if Mnemonic.words(in: text).count >= 12 { return true }
        let digits = text.utf8.allSatisfy { (0x30...0x39).contains($0) }
        return digits && (text.utf8.count == 48 || text.utf8.count == 96)
    }
}
