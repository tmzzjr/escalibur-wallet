import EscaliburChains
import EscaliburCore
import Foundation

// As leituras da DEX nativa do XRP Ledger que a troca precisa: o livro de ofertas de um
// par e a linha de confianca da conta com um emissor.
//
// As duas seguem a regra do resto do leitor: dois servidores, no mesmo ledger validado,
// com respostas iguais. No mesmo ledger o livro e a linha sao deterministicos, entao
// qualquer diferenca e mentira ou defeito, e a leitura e recusada.

/// Um lado de um livro de ofertas: XRP, ou moeda com emissor.
public enum XRPLBookAsset: Sendable, Hashable {
    case xrp
    case issued(currency: XRPLCurrency, issuer: String)

    var json: StrictJSON {
        switch self {
        case .xrp:
            return .object(["currency": .string("XRP")])
        case .issued(let currency, let issuer):
            return .object(["currency": .string(currency.code), "issuer": .string(issuer)])
        }
    }

    func matches(_ amount: XRPLAmount) -> Bool {
        switch (self, amount) {
        case (.xrp, .xrp): return true
        case (.issued(let currency, let issuer), .issued(let issued)):
            return issued.currency == currency && issued.issuerAddress == issuer
        default: return false
        }
    }
}

/// Uma oferta do livro, vista por quem a aceita: o que recebe e o que paga.
///
/// Quando o dono da oferta nao tem saldo para ela inteira, o rippled informa a parte
/// com fundos (`taker_gets_funded`, `taker_pays_funded`), e e ela que vale aqui.
public struct XRPLBookOffer: Sendable, Equatable {
    public let takerGets: XRPLAmount
    public let takerPays: XRPLAmount

    public init(takerGets: XRPLAmount, takerPays: XRPLAmount) {
        self.takerGets = takerGets
        self.takerPays = takerPays
    }
}

/// A linha de confianca da conta com um emissor, numa moeda.
public struct XRPLTrustLine: Sendable, Equatable {
    public let currency: XRPLCurrency
    public let issuer: String
    /// Do ponto de vista da conta: positivo e o que ela tem do token.
    public let balance: XRPLDecimal
    /// Quanto a conta aceita receber do emissor.
    public let limit: XRPLDecimal
}

extension XRPLReader {
    /// Teto de ofertas lidas por consulta.
    public static let maxBookOffers = 50

    /// As melhores ofertas que entregam `gets` a quem paga com `pays`, em dois servidores
    /// no mesmo ledger validado, oferta por oferta iguais.
    ///
    /// Serve para cotar. O que protege o dono nao e este numero, e o minimo gravado na
    /// oferta que ele assina; um servidor mentindo aqui faz, no pior caso, a troca ser
    /// recusada pela propria rede.
    public func bookOffers(gets: XRPLBookAsset, pays: XRPLBookAsset, limit: Int = 20) async throws -> [XRPLBookOffer] {
        guard gets != pays, (1...Self.maxBookOffers).contains(limit) else { throw ReaderError.invalidInput("livro") }
        let transport = self.transport
        return try await agreeingAtValidatedLedger(field: "book_offers") { provider, ledger in
            let result = try Self.checked(try await Self.call(transport, provider.baseURL, "book_offers", [
                "taker_gets": gets.json, "taker_pays": pays.json, "ledger_index": .int(ledger), "limit": .int(limit),
            ]), "book_offers")
            return try Self.parseBook(result, gets: gets, pays: pays, ledger: ledger)
        }
    }

    /// A linha de confianca de `account` com `issuer` em `currency`, ou nil quando ela nao
    /// existe. Dois servidores, no mesmo ledger validado, iguais.
    public func trustLine(account: String, currency: XRPLCurrency, issuer: String) async throws -> XRPLTrustLine? {
        guard XRPLAddress.accountID(account) != nil, XRPLAddress.accountID(issuer) != nil else {
            throw ReaderError.invalidInput("endereco")
        }
        let transport = self.transport
        return try await agreeingAtValidatedLedger(field: "account_lines") { provider, ledger in
            let result = try Self.checked(try await Self.call(transport, provider.baseURL, "account_lines", [
                "account": .string(account), "peer": .string(issuer), "ledger_index": .int(ledger),
            ]), "account_lines")
            return try Self.parseTrustLine(result, account: account, currency: currency, issuer: issuer, ledger: ledger)
        }
    }

    /// Le o ledger validado num servidor e faz a mesma leitura, nesse ledger, em dois
    /// servidores. As duas respostas tem de ser iguais.
    private func agreeingAtValidatedLedger<T: Sendable & Equatable>(
        field: String, _ read: @escaping @Sendable (Provider, UInt32) async throws -> T
    ) async throws -> T {
        let providers = await pool.available()
        let transport = self.transport
        let ledger = try await Quorum.first(providers, pool: pool) { provider in
            try Self.parseValidatedLedger(try Self.checked(try await Self.call(transport, provider.baseURL, "ledger", [
                "ledger_index": .string("validated"),
            ]), "ledger"))
        }
        let readings = try await Quorum.collect(providers, pool: pool, count: 2) { provider in
            try await read(provider, ledger)
        }
        guard readings[0].value == readings[1].value else { throw ReaderError.providersDisagree(field: field) }
        return readings[0].value
    }

    // MARK: Parse

    static func parseBook(_ result: StrictJSON, gets: XRPLBookAsset, pays: XRPLBookAsset, ledger: UInt32) throws -> [XRPLBookOffer] {
        try requireLedger(result, ledger, "book_offers")
        let offers = try result.field("offers", "book_offers").array("book_offers.offers")
        guard offers.count <= maxBookOffers else { throw ReaderError.implausibleValue(field: "book_offers.offers") }
        return try offers.enumerated().map { index, offer in
            let path = "book_offers.offers[\(index)]"
            let getsField = try offer.optionalField("taker_gets_funded") ?? offer.field("TakerGets", path)
            let paysField = try offer.optionalField("taker_pays_funded") ?? offer.field("TakerPays", path)
            let takerGets = try amount(getsField, path + ".TakerGets")
            let takerPays = try amount(paysField, path + ".TakerPays")
            // Oferta de outro par nao e cotacao do que foi pedido.
            guard gets.matches(takerGets), pays.matches(takerPays) else { throw ReaderError.responseMismatch(field: path) }
            return XRPLBookOffer(takerGets: takerGets, takerPays: takerPays)
        }
    }

    static func parseTrustLine(
        _ result: StrictJSON, account: String, currency: XRPLCurrency, issuer: String, ledger: UInt32
    ) throws -> XRPLTrustLine? {
        try requireLedger(result, ledger, "account_lines")
        guard try result.field("account", "account_lines").string("account_lines.account") == account else {
            throw ReaderError.responseMismatch(field: "account_lines.account")
        }
        var found: XRPLTrustLine?
        for (index, line) in try result.field("lines", "account_lines").array("account_lines.lines").enumerated() {
            let path = "account_lines.lines[\(index)]"
            guard try line.field("account", path).string(path + ".account") == issuer else {
                throw ReaderError.responseMismatch(field: path + ".account")
            }
            let code = try line.field("currency", path).string(path + ".currency")
            guard code == currency.code else { continue }
            guard found == nil else { throw ReaderError.malformed(field: path) }
            found = XRPLTrustLine(
                currency: currency, issuer: issuer,
                balance: try decimal(try line.field("balance", path), path + ".balance"),
                limit: try decimal(try line.field("limit", path), path + ".limit")
            )
        }
        return found
    }

    /// Quando o servidor diz em que ledger respondeu, tem de ser o pedido.
    private static func requireLedger(_ result: StrictJSON, _ ledger: UInt32, _ method: String) throws {
        if let reported = result.optionalField("ledger_index") {
            guard try reported.uint32(method + ".ledger_index") == ledger else {
                throw ReaderError.responseMismatch(field: method + ".ledger_index")
            }
        }
    }

    /// Amount do JSON do rippled pelo leitor da propria rede (`XRPLAmount.fromJSON`):
    /// texto de drops, ou `{currency, issuer, value}`.
    private static func amount(_ value: StrictJSON, _ path: String) throws -> XRPLAmount {
        let object: Any
        switch value {
        case .string(let text):
            object = text
        case .object(let fields):
            var plain: [String: Any] = [:]
            for key in ["currency", "issuer", "value"] {
                guard let field = fields[key] else { throw ReaderError.malformed(field: path) }
                plain[key] = try field.string(path + "." + key)
            }
            object = plain
        default:
            throw ReaderError.malformed(field: path)
        }
        do {
            let amount = try XRPLAmount.fromJSON(object)
            guard !amount.isZero else { throw ReaderError.implausibleValue(field: path) }
            if case .issued(let issued) = amount, issued.value.isNegative { throw ReaderError.implausibleValue(field: path) }
            return amount
        } catch let error as ReaderError {
            throw error
        } catch {
            throw ReaderError.malformed(field: path)
        }
    }

    private static func decimal(_ value: StrictJSON, _ path: String) throws -> XRPLDecimal {
        do {
            return try XRPLDecimal(try value.string(path))
        } catch let error as ReaderError {
            throw error
        } catch {
            throw ReaderError.malformed(field: path)
        }
    }
}
