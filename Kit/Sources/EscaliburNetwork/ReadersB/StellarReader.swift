import EscaliburChains
import EscaliburCore
import Foundation

/// Leitura de estado, cotacao, transmissao e historico da Stellar, pela Horizon.
///
/// Provedores: Horizon da SDF e da LOBSTR (`Endpoints.stellar`), nessa ordem.
///
/// Consenso (docs/seguranca.md §5.5):
/// - `sequence` da propria conta: os dois provedores tem de concordar. Divergindo,
///   vale o registro local de envios; sem ele, recusa;
/// - destino: os dois sao consultados. Existencia tem de concordar, e basta um dizer
///   que o memo e obrigatorio (SEP-29) para ser obrigatorio: um provedor que esconde
///   o `config.memo_required` faria o deposito numa exchange se perder;
/// - rede, cotacao e ofertas: um provedor. O planejamento poe teto na taxa, confere a
///   reserva numa faixa e calcula o minimo da troca a partir da tolerancia.
public struct StellarReader: Sendable {
    let pool: ProviderPool
    let transport: ChainReaderTransport

    public init(transport: ChainReaderTransport = HTTPReaderTransport(), providers: [ProviderPool.Provider] = Endpoints.stellar) {
        self.transport = transport
        self.pool = ProviderPool(providers)
    }

    /// Uma rota tem no maximo 5 ativos intermediarios (limite do protocolo, `path<5>`).
    static let maxPathLength = 5
    /// Ate quantas casas a Horizon escreve valores (stroops).
    static let decimals = 7

    // MARK: HTTP

    private func get<T: Decodable>(_ type: T.Type, _ provider: ProviderPool.Provider, _ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        let url = try ReaderURL.make(provider.baseURL, path, query: query)
        return try ReaderDecode.json(T.self, from: try await transport.fetch(url))
    }

    private func first<T: Sendable>(_ operation: @Sendable (ProviderPool.Provider) async throws -> T) async throws -> T {
        try await pool.first(operation)
    }

    /// Os dois primeiros provedores, cada um com a sua resposta ou o seu erro.
    private func both<T: Sendable>(_ operation: @escaping @Sendable (ProviderPool.Provider) async throws -> T) async throws -> [T] {
        let providers = Array(pool.providers.prefix(2))
        guard providers.count == 2 else { throw ChainReaderError.notEnoughSources(needed: 2, got: providers.count) }
        let results = try await ReaderConcurrency.map(providers, limit: 2) { provider -> T? in try? await operation(provider) }
        for (provider, result) in zip(providers, results) {
            if result == nil { await pool.reportFailure(provider) } else { await pool.reportSuccess(provider) }
        }
        let answers = results.compactMap { $0 }
        guard answers.count == 2 else { throw ChainReaderError.notEnoughSources(needed: 2, got: answers.count) }
        return answers
    }

    // MARK: Conta

    enum AccountAnswer: Sendable {
        case missing
        case found(StellarAccountState, data: [String: String])
    }

    private func account(_ id: StellarAccountID, at provider: ProviderPool.Provider) async throws -> AccountAnswer {
        let record: HorizonAccount
        do {
            record = try await get(HorizonAccount.self, provider, "accounts/\(id.address)")
        } catch HTTPClient.Failure.status(404) {
            return .missing
        }
        return .found(try Self.state(record, expected: id), data: record.data)
    }

    static func state(_ record: HorizonAccount, expected: StellarAccountID) throws -> StellarAccountState {
        guard record.accountId == expected.address else { throw ChainReaderError.mismatchedResponse }
        guard let sequence = Int64(record.sequence), sequence >= 0, record.sequence.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            throw ChainReaderError.malformedResponse(field: "sequence")
        }
        var native: (balance: BigUInt, selling: BigUInt)?
        var trustlines: [StellarTrustline] = []
        for (index, entry) in record.balances.enumerated() {
            let field = "balances.\(index)"
            switch entry.assetType {
            case "native":
                guard native == nil, let selling = entry.sellingLiabilities, entry.buyingLiabilities != nil else {
                    throw ChainReaderError.malformedResponse(field: field)
                }
                native = (try DecimalUnits.parse(entry.balance, decimals: decimals, field: field),
                          try DecimalUnits.parse(selling, decimals: decimals, field: field))
            case "credit_alphanum4", "credit_alphanum12":
                guard let code = entry.assetCode, let issuer = entry.assetIssuer, let limit = entry.limit,
                      let buying = entry.buyingLiabilities, let selling = entry.sellingLiabilities, let authorized = entry.isAuthorized,
                      let asset = try? StellarAsset(code: code, issuer: issuer),
                      (code.utf8.count <= 4) == (entry.assetType == "credit_alphanum4")
                else { throw ChainReaderError.malformedResponse(field: field) }
                trustlines.append(StellarTrustline(
                    asset: asset,
                    balance: try DecimalUnits.parse(entry.balance, decimals: decimals, field: field),
                    limit: try DecimalUnits.parse(limit, decimals: decimals, field: field),
                    buyingLiabilities: try DecimalUnits.parse(buying, decimals: decimals, field: field),
                    sellingLiabilities: try DecimalUnits.parse(selling, decimals: decimals, field: field),
                    isAuthorized: authorized
                ))
            case "liquidity_pool_shares":
                // Cota de pool: subentrada, mas nao e ativo que a carteira envia.
                continue
            default:
                throw ChainReaderError.malformedResponse(field: field)
            }
        }
        guard let native else { throw ChainReaderError.malformedResponse(field: "balances.native") }
        return StellarAccountState(
            account: expected, sequence: sequence, balance: native.balance, subentryCount: record.subentryCount,
            sellingLiabilities: native.selling, numSponsoring: record.numSponsoring, numSponsored: record.numSponsored,
            trustlines: trustlines
        )
    }

    /// O estado da conta da carteira, com a `sequence` confirmada por dois provedores.
    ///
    /// nil quando os dois dizem que a conta nao existe (ainda nao recebeu 1 XLM).
    /// `localSequence`: a sequence da ultima transacao que este aparelho transmitiu.
    /// Se os provedores divergem, vale o que bate com ela; se nenhum bate, recusa.
    public func ownerAccount(_ id: StellarAccountID, localSequence: Int64? = nil) async throws -> StellarAccountState? {
        let answers = try await both { provider in try await self.account(id, at: provider) }
        switch (answers[0], answers[1]) {
        case (.missing, .missing):
            return nil
        case (.found(let a, _), .found(let b, _)):
            if a.sequence == b.sequence { return a }
            if let localSequence {
                if a.sequence == localSequence { return a }
                if b.sequence == localSequence { return b }
            }
            throw ChainReaderError.providersDisagree
        default:
            throw ChainReaderError.providersDisagree
        }
    }

    /// O destino de um envio: existe, que linhas de confianca tem, e se exige memo.
    /// Aceita `G...` e `M...` (a conta base do muxed e a consultada).
    public func destination(_ address: String) async throws -> StellarDestinationState {
        guard let muxed = StellarMuxedAccount(address: address) else { throw ChainReaderError.mismatchedResponse }
        let id = muxed.account
        let answers = try await both { provider in try await self.account(id, at: provider) }
        switch (answers[0], answers[1]) {
        case (.missing, .missing):
            return .missing
        case (.found(let a, let dataA), .found(_, let dataB)):
            let memo = StellarDestinationState.memoRequired(dataEntries: dataA)
                || StellarDestinationState.memoRequired(dataEntries: dataB)
            return StellarDestinationState(exists: true, trustlines: a.trustlines, memoRequired: memo)
        default:
            throw ChainReaderError.providersDisagree
        }
    }

    // MARK: Rede

    /// Reserva e taxa base do ultimo ledger fechado, e o p90 cobrado (`/fee_stats`).
    public func networkState() async throws -> StellarNetworkState {
        let ledger = try await first { provider in
            try await self.get(HorizonPage<HorizonLedger>.self, provider, "ledgers", [
                URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "limit", value: "1"),
            ])
        }
        guard ledger.embedded.records.count == 1, let latest = ledger.embedded.records.first else {
            throw ChainReaderError.malformedResponse(field: "_embedded.records")
        }
        let stats = try await first { provider in try await self.get(HorizonFeeStats.self, provider, "fee_stats") }
        let p90 = try ReaderDecode.unsigned(stats.feeCharged.p90, field: "fee_charged.p90")
        return StellarNetworkState(
            baseReserve: BigUInt(latest.baseReserveInStroops), baseFee: BigUInt(latest.baseFeeInStroops), feeChargedP90: BigUInt(p90)
        )
    }

    // MARK: Ofertas

    /// Ofertas abertas da conta, para mostrar e para `StellarPlanner.planCancelOrder`.
    public func offers(_ id: StellarAccountID) async throws -> [StellarOpenOffer] {
        let page = try await first { provider in
            try await self.get(HorizonPage<HorizonOffer>.self, provider, "accounts/\(id.address)/offers", [
                URLQueryItem(name: "limit", value: "200"), URLQueryItem(name: "order", value: "asc"),
            ])
        }
        return try page.embedded.records.enumerated().map { index, record in
            let field = "offers.\(index)"
            guard record.seller == id.address else { throw ChainReaderError.mismatchedResponse }
            guard let offerID = Int64(record.id), offerID > 0, record.priceR.n > 0, record.priceR.d > 0 else {
                throw ChainReaderError.malformedResponse(field: field)
            }
            return StellarOpenOffer(
                id: offerID, selling: try record.selling.asset(field: field), buying: try record.buying.asset(field: field),
                amount: try DecimalUnits.parse(record.amount, decimals: Self.decimals, field: field),
                priceNumerator: record.priceR.n, priceDenominator: record.priceR.d
            )
        }
    }

    // MARK: Cotacao de troca

    /// Cotacao de path payment strict send: entregando exatamente `amount` de `send`,
    /// quanto de `receive` chega, e por qual rota. A melhor das rotas devolvidas.
    ///
    /// O que protege o dono nao e este numero: `StellarPlanner.planSwap` calcula o
    /// minimo a partir dele e da tolerancia, e a rede garante o minimo. Um provedor
    /// mentindo aqui faz, no pior caso, a troca falhar ou sair pela rota pior dentro
    /// da tolerancia. nil quando nao ha rota.
    public func quoteStrictSend(send: StellarAsset, amount: BigUInt, receive: StellarAsset) async throws -> StellarPathQuote? {
        guard !amount.isZero, send != receive else { return nil }
        let sourceAmount = DecimalUnits.format(amount, decimals: Self.decimals)
        let destination = receive.issuer.map { "\(receive.code):\($0.address)" } ?? "native"
        let query = Self.assetQuery(send, prefix: "source_") + [
            URLQueryItem(name: "source_amount", value: sourceAmount), URLQueryItem(name: "destination_assets", value: destination),
        ]
        let page = try await first { provider in
            try await self.get(HorizonPage<HorizonPath>.self, provider, "paths/strict-send", query)
        }
        var best: StellarPathQuote?
        for (index, record) in page.embedded.records.enumerated() {
            let field = "paths.\(index)"
            let source = try HorizonAssetFields(type: record.sourceAssetType, code: record.sourceAssetCode, issuer: record.sourceAssetIssuer).asset(field: field)
            let destination = try HorizonAssetFields(
                type: record.destinationAssetType, code: record.destinationAssetCode, issuer: record.destinationAssetIssuer
            ).asset(field: field)
            // Rota para outro par, ou outro valor, nao e cotacao do que foi pedido.
            guard source == send, destination == receive,
                  try DecimalUnits.parse(record.sourceAmount, decimals: Self.decimals, field: field) == amount
            else { continue }
            let path = try record.path.map { try $0.asset(field: field) }
            guard path.count <= Self.maxPathLength, !path.contains(send), !path.contains(receive) else { continue }
            let received = try DecimalUnits.parse(record.destinationAmount, decimals: Self.decimals, field: field)
            if received > (best?.receiveAmount ?? BigUInt()) {
                best = StellarPathQuote(sendAsset: send, sendAmount: amount, receiveAsset: receive, receiveAmount: received, path: path)
            }
        }
        return best
    }

    static func assetQuery(_ asset: StellarAsset, prefix: String) -> [URLQueryItem] {
        guard let issuer = asset.issuer else { return [URLQueryItem(name: "\(prefix)asset_type", value: "native")] }
        return [
            URLQueryItem(name: "\(prefix)asset_type", value: asset.code.utf8.count <= 4 ? "credit_alphanum4" : "credit_alphanum12"),
            URLQueryItem(name: "\(prefix)asset_code", value: asset.code),
            URLQueryItem(name: "\(prefix)asset_issuer", value: issuer.address),
        ]
    }

    // MARK: Transmissao

    /// Transmite o envelope assinado (`POST /transactions`, formulario `tx=<base64>`).
    ///
    /// Antes, confere que o envelope decodifica, que o base64 e o dos bytes, e que o
    /// hash calculado localmente (com a passphrase compilada) e o `id`. Tenta os
    /// provedores em ordem, sempre com os mesmos bytes, ate um aceitar; a resposta tem
    /// de trazer esse mesmo hash e `successful`.
    public func broadcast(_ signed: SignedTransaction) async throws -> StellarSubmission {
        guard signed.chainID == Chain.stellar.id, Data(signed.raw).base64EncodedString() == signed.encoded,
              let envelope = try? StellarEnvelope.decode(signed.raw), envelope.xdr == signed.raw,
              Hex.encode(envelope.hash) == signed.id
        else { throw ChainReaderError.signedTransactionInconsistent }
        let body = ReaderURL.formBody([("tx", signed.encoded)])
        let id = signed.id
        var lastError: Error = ChainReaderError.broadcastRejected
        for provider in pool.providers {
            do {
                let url = try ReaderURL.make(provider.baseURL, "transactions")
                let data = try await transport.send(url, body: body, contentType: "application/x-www-form-urlencoded", timeout: 30)
                let result = try ReaderDecode.json(HorizonTransaction.self, from: data)
                guard result.hash.lowercased() == id, result.successful else { throw ChainReaderError.mismatchedResponse }
                await pool.reportSuccess(provider)
                return StellarSubmission(hash: id, ledger: result.ledger, provider: provider.name)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Onde a transacao esta, na opiniao dos dois provedores (`ChainTransactionStatus.combine`).
    public func status(hash: String) async throws -> ChainTransactionStatus {
        let hash = hash.lowercased()
        guard hash.count == 64, Hex.decode(hash) != nil else { throw ChainReaderError.signedTransactionInconsistent }
        let answers = try await both { provider -> ChainTransactionStatus in
            do {
                let tx = try await self.get(HorizonTransaction.self, provider, "transactions/\(hash)")
                guard tx.hash.lowercased() == hash else { throw ChainReaderError.mismatchedResponse }
                return tx.successful ? .confirmed(height: tx.ledger, confirmations: nil) : .failed(height: tx.ledger)
            } catch HTTPClient.Failure.status(404) {
                return .notFound
            }
        }
        return try ChainTransactionStatus.combine(answers[0], answers[1])
    }

    // MARK: Historico

    /// As ultimas operacoes da conta e os trades das ofertas dela.
    ///
    /// `/accounts/{G}/operations` ja inclui tudo o que `/payments` traz (payment, path
    /// payments, create_account, account_merge) e mais ofertas, linhas de confianca e
    /// saldos reivindicaveis; consultar os dois duplicaria cada pagamento. Os trades
    /// (`/accounts/{G}/trades`) cobrem as ofertas executadas na transacao de outros.
    ///
    /// Marcados como suspeitos: ativo fora de `listedAssets`, valor de ate 0,01 unidade
    /// vindo de quem a conta nunca pagou, e saldo reivindicavel de desconhecido.
    public func history(
        _ id: StellarAccountID, limit: Int = 30, listedAssets: [StellarAsset] = [], knownCounterparties: Set<String> = []
    ) async throws -> [ChainActivity] {
        let count = String(min(max(limit, 1), 200))
        let operations = try await first { provider in
            try await self.get(HorizonPage<HorizonOperation>.self, provider, "accounts/\(id.address)/operations", [
                URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "limit", value: count),
                URLQueryItem(name: "include_failed", value: "false"),
            ])
        }
        let trades = try await first { provider in
            try await self.get(HorizonPage<HorizonTrade>.self, provider, "accounts/\(id.address)/trades", [
                URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "limit", value: count),
            ])
        }
        return try StellarHistory.activities(
            account: id, operations: operations.embedded.records, trades: trades.embedded.records,
            limit: limit, listedAssets: listedAssets, knownCounterparties: knownCounterparties
        )
    }
}

// MARK: Tipos publicos

/// Uma oferta aberta da conta no livro da DEX.
public struct StellarOpenOffer: Sendable, Equatable {
    public let id: Int64
    public let selling: StellarAsset
    public let buying: StellarAsset
    /// Quanto de `selling` ainda esta a venda, em stroops.
    public let amount: BigUInt
    /// Preco `n/d` de `buying` por unidade de `selling`, como gravado no ledger.
    public let priceNumerator: Int32
    public let priceDenominator: Int32
}

/// Uma cotacao de path payment strict send.
public struct StellarPathQuote: Sendable, Equatable {
    public let sendAsset: StellarAsset
    public let sendAmount: BigUInt
    public let receiveAsset: StellarAsset
    /// Quanto chegaria agora pela rota. Entra em `planSwap` como `quotedReceive`.
    public let receiveAmount: BigUInt
    /// Ativos intermediarios, na ordem. Entra em `planSwap` como `path`.
    public let path: [StellarAsset]
}

/// Transacao aceita e incluida num ledger.
public struct StellarSubmission: Sendable, Equatable {
    public let hash: String
    public let ledger: UInt32
    public let provider: String
}

// MARK: Formato da Horizon

struct HorizonPage<Record: Decodable & Sendable>: Decodable, Sendable {
    struct Embedded: Decodable, Sendable { let records: [Record] }
    let embedded: Embedded
    enum CodingKeys: String, CodingKey { case embedded = "_embedded" }
}

struct HorizonAccount: Decodable, Sendable {
    struct Balance: Decodable, Sendable {
        let assetType: String
        let assetCode: String?
        let assetIssuer: String?
        let balance: String
        let limit: String?
        let buyingLiabilities: String?
        let sellingLiabilities: String?
        let isAuthorized: Bool?

        enum CodingKeys: String, CodingKey {
            case balance, limit
            case assetType = "asset_type"
            case assetCode = "asset_code"
            case assetIssuer = "asset_issuer"
            case buyingLiabilities = "buying_liabilities"
            case sellingLiabilities = "selling_liabilities"
            case isAuthorized = "is_authorized"
        }
    }

    let accountId: String
    let sequence: String
    let subentryCount: UInt32
    let numSponsoring: UInt32
    let numSponsored: UInt32
    let balances: [Balance]
    let data: [String: String]

    enum CodingKeys: String, CodingKey {
        case sequence, balances, data
        case accountId = "account_id"
        case subentryCount = "subentry_count"
        case numSponsoring = "num_sponsoring"
        case numSponsored = "num_sponsored"
    }
}

struct HorizonLedger: Decodable, Sendable {
    let sequence: UInt32
    let baseFeeInStroops: UInt64
    let baseReserveInStroops: UInt64

    enum CodingKeys: String, CodingKey {
        case sequence
        case baseFeeInStroops = "base_fee_in_stroops"
        case baseReserveInStroops = "base_reserve_in_stroops"
    }
}

struct HorizonFeeStats: Decodable, Sendable {
    struct Charged: Decodable, Sendable { let p90: String }
    let feeCharged: Charged
    enum CodingKeys: String, CodingKey { case feeCharged = "fee_charged" }
}

/// Os tres campos com que a Horizon descreve um ativo.
struct HorizonAssetFields: Decodable, Sendable {
    let type: String
    let code: String?
    let issuer: String?

    init(type: String, code: String?, issuer: String?) {
        self.type = type
        self.code = code
        self.issuer = issuer
    }

    enum CodingKeys: String, CodingKey {
        case type = "asset_type"
        case code = "asset_code"
        case issuer = "asset_issuer"
    }

    func asset(field: String) throws -> StellarAsset {
        switch type {
        case "native":
            guard code == nil, issuer == nil else { throw ChainReaderError.malformedResponse(field: field) }
            return .native
        case "credit_alphanum4", "credit_alphanum12":
            guard let code, let issuer, (code.utf8.count <= 4) == (type == "credit_alphanum4"),
                  let asset = try? StellarAsset(code: code, issuer: issuer)
            else { throw ChainReaderError.malformedResponse(field: field) }
            return asset
        default:
            throw ChainReaderError.malformedResponse(field: field)
        }
    }
}

struct HorizonOffer: Decodable, Sendable {
    struct Price: Decodable, Sendable {
        let n: Int32
        let d: Int32
    }
    let id: String
    let seller: String
    let selling: HorizonAssetFields
    let buying: HorizonAssetFields
    let amount: String
    let priceR: Price

    enum CodingKeys: String, CodingKey {
        case id, seller, selling, buying, amount
        case priceR = "price_r"
    }
}

struct HorizonPath: Decodable, Sendable {
    let sourceAssetType: String
    let sourceAssetCode: String?
    let sourceAssetIssuer: String?
    let sourceAmount: String
    let destinationAssetType: String
    let destinationAssetCode: String?
    let destinationAssetIssuer: String?
    let destinationAmount: String
    let path: [HorizonAssetFields]

    enum CodingKeys: String, CodingKey {
        case path
        case sourceAssetType = "source_asset_type"
        case sourceAssetCode = "source_asset_code"
        case sourceAssetIssuer = "source_asset_issuer"
        case sourceAmount = "source_amount"
        case destinationAssetType = "destination_asset_type"
        case destinationAssetCode = "destination_asset_code"
        case destinationAssetIssuer = "destination_asset_issuer"
        case destinationAmount = "destination_amount"
    }
}

struct HorizonTransaction: Decodable, Sendable {
    let hash: String
    let ledger: UInt32
    let successful: Bool
}
