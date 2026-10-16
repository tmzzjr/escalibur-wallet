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
///
/// O esquema diz a rede, e nao so no EIP-681: "litecoin:3J98..." ou "bitcoincash:1Boat..."
/// eram lidos como um endereco qualquer, e a tela de Bitcoin aceitava, porque a Litecoin
/// antiga e o Bitcoin Cash usam enderecos com a forma dos do Bitcoin (auditoria 4, B-4).
/// Agora a leitura diz a rede e a familia do esquema, e esquema de rede que o app nao tem
/// (ou que ele nao conhece) e recusado.
public enum PaymentLink {
    public struct Reading: Equatable, Sendable {
        public let address: String
        /// A rede que o link pede, quando ele diz: o `@chain_id` do EIP-681, ou o esquema
        /// de uma rede de esquema proprio ("litecoin:" e a Litecoin, "ripple:" o XRP
        /// Ledger). Quem le recusa o link cuja rede nao e a da tela. Nil sem esquema, e no
        /// "ethereum:" sem `@chain_id`, que serve a qualquer rede EVM.
        public let chainID: String?
        /// A familia que o esquema indica: `.evm` no "ethereum:", com ou sem `@chain_id`, e
        /// a da rede nos outros. Nil sem esquema.
        public let family: ChainFamily?
        /// A tag de destino ou o memo que o link traz: `dt` do XRP Ledger, `text` da TON,
        /// `memo` do SEP-7. Nil quando nao traz.
        public let tag: String?

        init(address: String, chainID: String?, family: ChainFamily?, tag: String? = nil) {
            self.address = address
            self.chainID = chainID
            self.family = family
            self.tag = tag
        }

        init(address: String, chain: Chain, tag: String? = nil) {
            self.init(address: address, chainID: chain.id, family: chain.family, tag: tag)
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
        /// O esquema do link (o valor, em minusculas) e de uma rede em que o app nao envia,
        /// como "bitcoincash", cujos enderecos tem a forma dos do Bitcoin, ou de nenhuma que
        /// ele conheca. O resto do link nunca vira destino da rede da tela (auditoria 4, B-4).
        case unsupportedNetwork(String)
        /// Esquema que o app nao conhece: o resto nunca e lido como endereco da tela.
        case unknownScheme(String)
    }

    public static let maxLength = 512
    static let maxTagLength = 64

    /// As redes de esquema proprio. O "ethereum:" (EIP-681), o "web+stellar:" (SEP-7) e o
    /// "ton://transfer/" tem leitura propria; o "ton:" daqui so cobre o "ton://" de outra
    /// acao, que nao traz endereco e continua recusado pela validacao.
    static let schemes: [String: Chain] = [
        "bitcoin": .bitcoin, "litecoin": .litecoin, "dogecoin": .dogecoin,
        "solana": .solana, "xrpl": .xrpl, "ripple": .xrpl, "tron": .tron, "ton": .ton,
        "stellar": .stellar, "cardano": .cardano, "sui": .sui, "aptos": .aptos, "near": .near, "polkadot": .polkadot,
    ]

    /// Redes conhecidas que a Escalibur nao envia, com enderecos que se parecem com os de
    /// uma rede que ela envia (o Bitcoin Cash legado e o do Bitcoin).
    static let unsupported: Set<String> = ["bitcoincash", "bchtest", "ecash", "bitcoinsv", "monero", "zcash", "dash"]

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
                return Reading(address: recipient.description, chainID: request.chain?.id, family: .evm)
            }
        }
        if lower.hasPrefix("web+stellar:") { return try stellarRequest(trimmed) }
        if lower.hasPrefix("ton://transfer/") {
            let rest = trimmed.dropFirst("ton://transfer/".count)
            let address = String(rest.prefix { $0 != "?" && $0 != "/" })
            return Reading(address: address, chain: .ton, tag: try tag("text", in: trimmed))
        }
        var body = Substring(trimmed)
        var chain: Chain?
        if let colon = body.firstIndex(of: ":"), colon != body.startIndex, body[..<colon].allSatisfy({ $0.isLetter }) {
            // Esquema que nao e de uma rede do app recusa: ler o resto como endereco da tela
            // e o que mandava "bitcoincash:1Boat..." para o Bitcoin.
            let scheme = body[..<colon].lowercased()
            guard let known = Self.schemes[scheme] else {
                throw Self.unsupported.contains(scheme) ? Problem.unsupportedNetwork(scheme) : Problem.unknownScheme(scheme)
            }
            chain = known
            body = body[body.index(after: colon)...]
        }
        if body.hasPrefix("pay-") { body = body.dropFirst(4) }
        let address = String(body.prefix { $0 != "?" && $0 != "@" && $0 != "/" })
        let found = chain == .xrpl ? try tag("dt", in: trimmed) : nil
        // O X-address ja traz a tag dele: um `dt` junto e uma segunda tag disputando o
        // credito, sem leitura segura.
        if found != nil, address.hasPrefix("X") { throw Problem.invalidTag }
        guard let chain else { return Reading(address: address, chainID: nil, family: nil) }
        return Reading(address: address, chain: chain, tag: found)
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
            return Reading(address: destination, chain: .stellar)
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
        return Reading(address: destination, chain: .stellar, tag: memo)
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
