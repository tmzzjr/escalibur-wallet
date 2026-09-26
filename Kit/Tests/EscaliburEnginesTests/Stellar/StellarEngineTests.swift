@testable import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// Os motores da Stellar contra respostas gravadas da Horizon (Fixtures/stellar), sem rede.
@Suite("Motores Stellar com respostas gravadas")
struct StellarEngineTests {
    static let owner = TestAccounts.stellarAddress
    static let memoRequired = "GDQP2KPQGKIHYJGXNUIYOMHARUARCA7DJT5FO2FFOOKY3B2WSQHG4W37"
    static let plain = "GB3FQB7JYQ37PVYL3DE7ZWYMQCDXZFQBLA23HHJOYA3MIOHCSLT3BCYY"
    static let missing = "GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6"
    static let paid = "GAQZU7Y7GB3E4XOA3ZXEZDOTIEIWQRYOAIVJ6STY2YTUQAGZL3GYJCXG"
    static let usdc = TokenRegistry.tokens.first { $0.chainID == "stellar" && $0.symbol == "USDC" }!
    static let xlm = Asset.native(.stellar)

    static let providers = [
        EngineFixture.provider("sdf", "https://horizon-a.test"),
        EngineFixture.provider("lobstr", "https://horizon-b.test"),
    ]

    /// Horizon de mentira com as gravacoes. `owner` troca a conta do dono (as duas
    /// Horizons), `paths` troca as cotacoes.
    static func network(
        owner: [String: Data]? = nil, operations: Data? = nil, paths: [String: String] = [:],
        submission: @escaping @Sendable (Data) -> Data? = { _ in nil }
    ) throws -> FakeHTTP {
        let fake = FakeHTTP()
        for (host, name) in [("horizon-a.test", "sdf"), ("horizon-b.test", "lobstr")] {
            fake.on("\(host)/accounts/\(Self.owner)", data: try owner?[name] ?? EngineFixture.data("stellar", "account-dono-\(name).json"))
            fake.on("\(host)/accounts/\(memoRequired)", data: try EngineFixture.data("stellar", "account-memo-\(name).json"))
            fake.on("\(host)/accounts/\(plain)", data: try EngineFixture.data("stellar", "account-comum-\(name).json"))
            fake.on("\(host)/accounts/\(missing)", status: 404)
            fake.on("\(host)/transactions/69178363c4d302d79d513e3bf2e9f19d0464b986514b479fb40babf608e29eb3",
                    data: try EngineFixture.data("stellar", "transaction-\(name).json"))
            fake.on("\(host)/ledgers", data: try EngineFixture.data("stellar", "ledgers.json"))
            fake.on("\(host)/fee_stats", data: try EngineFixture.data("stellar", "fee_stats.json"))
            fake.on("\(host)/accounts/\(Self.owner)/operations", data: try operations ?? EngineFixture.data("stellar", "operations-dono.json"))
            fake.on("\(host)/accounts/\(Self.owner)/trades", data: try EngineFixture.data("stellar", "trades-dono.json"))
            var recorded: [String: Data] = [:]
            for (amount, file) in [
                ("100.0000000", "paths-xlm-usdc.json"), ("0.1000000", "paths-xlm-usdc-referencia.json"),
                ("10.0000000", "paths-usdc-xlm.json"), ("0.0100000", "paths-usdc-xlm-referencia.json"),
            ] {
                recorded[amount] = try EngineFixture.data("stellar", paths[amount] ?? file)
            }
            let byAmount = recorded
            fake.on("\(host)/paths/strict-send") { url, _ in
                let amount = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "source_amount" }?.value
                guard let amount, let data = byAmount[amount] else { throw HTTPClient.Failure.status(404) }
                return data
            }
            fake.on("\(host)/transactions") { _, body in
                guard let body, let answer = submission(body) else { throw HTTPClient.Failure.status(400) }
                return answer
            }
        }
        return fake
    }

    static func reader(_ fake: FakeHTTP) -> StellarReader { StellarReader(transport: fake, providers: providers) }

    static func request(
        to destination: String, amount: BigUInt, asset: Asset = xlm, tag: String? = nil, sendAll: Bool = false
    ) -> SendRequest {
        SendRequest(
            walletID: UUID(), chain: .stellar, asset: asset, account: TestAccounts.stellar, destination: destination, tag: tag,
            amount: amount, sendAll: sendAll, feeLevel: .normal, utxoUsage: nil
        )
    }

    static func operations(_ plan: SigningPlan) throws -> [StellarOperation.Body] {
        try #require(plan.transactions.first as? StellarTransaction).tx.operations.map(\.body)
    }

    // MARK: Destino

    @Test("Destino: memo obrigatorio pelo SEP-29, conta comum, e conta que nao existe com o minimo do planejador")
    func destination() async throws {
        let engine = StellarSendEngine(reader: Self.reader(try Self.network()))
        let memo = try await engine.destination(Self.memoRequired, chain: .stellar)
        #expect(memo.exists && memo.requiresTag && memo.note != nil)
        let plain = try await engine.destination(Self.plain, chain: .stellar)
        #expect(plain.exists && !plain.requiresTag && plain.activationMinimum == nil)
        let missing = try await engine.destination(Self.missing, chain: .stellar)
        #expect(!missing.exists && missing.activationMinimum == 10_000_000)
        #expect(missing.note?.contains("1 XLM") == true)
    }

    // MARK: Maximo e plano

    @Test("Maximo: XLM livre menos a taxa; USDC pelo saldo da linha; a taxa e a mesma do plano")
    func spendable() async throws {
        let fake = try Self.network()
        let engine = StellarSendEngine(reader: Self.reader(fake))
        let native = try await engine.spendable(Self.request(to: Self.plain, amount: 0, sendAll: true))
        let account = try #require(try await Self.reader(fake).ownerAccount(StellarAccountID(address: Self.owner)!))
        let network = try await Self.reader(fake).networkState()
        let fee = try #require(StellarEngineSupport.feePerOperation(network))
        #expect(fee == 9_236)  // p90 cobrado da gravacao
        #expect(native.amount == account.spendable(baseReserve: network.baseReserve) - fee)
        #expect(native.reserveNote?.contains("reservados pela rede") == true)

        // Enviar tudo monta exatamente esse valor, com a taxa por operacao igual a daqui.
        let plan = try await engine.plan(Self.request(to: Self.plain, amount: native.amount, sendAll: true))
        let transaction = try #require(plan.transactions.first as? StellarTransaction)
        #expect(BigUInt(UInt64(transaction.tx.fee)) == fee)
        guard case .payment(_, .native, let amount) = try Self.operations(plan).first else { Issue.record("esperava pagamento"); return }
        #expect(BigUInt(UInt64(amount)) == native.amount)

        let usdc = try await engine.spendable(Self.request(to: Self.plain, amount: 0, asset: Self.usdc, sendAll: true))
        #expect(usdc.amount == 3_185_300_002)
    }

    @Test("Plano: destino e memo na revisao; so digitos vira memo ID, o resto memo de texto")
    func memoRules() async throws {
        let engine = StellarSendEngine(reader: Self.reader(try Self.network()))
        let byID = try await engine.plan(Self.request(to: Self.memoRequired, amount: 20_000_000, tag: "12345"))
        #expect(byID.review.recipient == Self.memoRequired && byID.review.recipientTag == "12345")
        #expect(try #require(byID.transactions.first as? StellarTransaction).tx.memo == .id(12_345))

        let byText = try await engine.plan(Self.request(to: Self.memoRequired, amount: 20_000_000, tag: "007"))
        #expect(byText.review.recipientTag == "007")
        #expect(try #require(byText.transactions.first as? StellarTransaction).tx.memo == .text(Array("007".utf8)))

        await #expect(throws: SendEngineError.message(StellarPlanError.memoRequired.reason)) {
            _ = try await engine.plan(Self.request(to: Self.memoRequired, amount: 20_000_000))
        }
        await #expect(throws: SendEngineError.self) {
            _ = try await engine.plan(Self.request(to: Self.plain, amount: 20_000_000, tag: String(repeating: "x", count: 29)))
        }
    }

    @Test("Conta nova: CreateAccount a partir do minimo, com o aviso de ativacao; abaixo dele, recusa")
    func createAccount() async throws {
        let engine = StellarSendEngine(reader: Self.reader(try Self.network()))
        let plan = try await engine.plan(Self.request(to: Self.missing, amount: 10_000_000))
        #expect(plan.review.recipient == Self.missing)
        guard case .createAccount(let created, 10_000_000) = try Self.operations(plan).first else { Issue.record("esperava CreateAccount"); return }
        #expect(created.address == Self.missing)
        #expect(plan.review.warnings.contains { if case .activatesAccount = $0 { return true } else { return false } })
        await #expect(throws: SendEngineError.message(StellarEngineSupport.text(.belowAccountMinimum(minimum: 0)))) {
            _ = try await engine.plan(Self.request(to: Self.missing, amount: 9_999_999))
        }
        await #expect(throws: SendEngineError.message(StellarPlanError.destinationMissing.reason)) {
            _ = try await engine.plan(Self.request(to: Self.missing, amount: 10_000_000, asset: Self.usdc))
        }
    }

    @Test("USDC da lista: pagamento do ativo com codigo e emissor, para destino com a linha aberta")
    func sendAsset() async throws {
        let engine = StellarSendEngine(reader: Self.reader(try Self.network()))
        let plan = try await engine.plan(Self.request(to: Self.memoRequired, amount: 1_000_000, asset: Self.usdc, tag: "99"))
        #expect(plan.review.recipient == Self.memoRequired && plan.review.recipientTag == "99")
        guard case .payment(_, let asset, 1_000_000) = try Self.operations(plan).first else { Issue.record("esperava pagamento"); return }
        #expect(asset.code == "USDC" && asset.issuer?.address == "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN")

        let fake = Asset(chainID: "stellar", kind: .issued(code: "USDC", issuer: Self.plain), symbol: "USDC", name: "USD Coin",
                         decimals: 7, coingeckoID: nil, isStablecoin: true)
        await #expect(throws: SendEngineError.self) {
            _ = try await engine.plan(Self.request(to: Self.memoRequired, amount: 1_000_000, asset: fake, tag: "99"))
        }
    }

    // MARK: Transmissao e acompanhamento

    /// Um envelope com a transacao do plano e uma assinatura de mentira: a Horizon de
    /// mentira nao confere assinatura, e o motor tambem nao (quem confere e o assinador).
    static func signed(_ plan: SigningPlan) throws -> SignedTransaction {
        let transaction = try #require(plan.transactions.first as? StellarTransaction)
        let envelope = try StellarEnvelope(
            tx: transaction.tx, signatures: [try StellarDecoratedSignature(hint: [0, 0, 0, 0], signature: [UInt8](repeating: 0, count: 64))]
        )
        return SignedTransaction(chainID: "stellar", raw: envelope.xdr, encoded: envelope.base64, id: Hex.encode(envelope.hash))
    }

    @Test("Transmissao: o hash devolvido e o calculado do envelope; a Horizon dizer outro e recusa")
    func broadcast() async throws {
        let plan = try await StellarSendEngine(reader: Self.reader(try Self.network())).plan(Self.request(to: Self.plain, amount: 20_000_000))
        let signed = try Self.signed(plan)
        let honest = try Self.network(submission: { _ in Data("{\"hash\":\"\(signed.id)\",\"ledger\":64624700,\"successful\":true}".utf8) })
        #expect(try await StellarSendEngine(reader: Self.reader(honest)).broadcast([signed], chain: .stellar) == signed.id)

        let liar = try Self.network(submission: { _ in Data("{\"hash\":\"\(String(repeating: "0", count: 64))\",\"ledger\":1,\"successful\":true}".utf8) })
        await #expect(throws: SendEngineError.self) {
            _ = try await StellarSendEngine(reader: Self.reader(liar)).broadcast([signed], chain: .stellar)
        }
        let tampered = SignedTransaction(chainID: "stellar", raw: signed.raw, encoded: signed.encoded, id: String(repeating: "1", count: 64))
        await #expect(throws: SendEngineError.message(NetworkFailureText.inconsistent)) {
            _ = try await StellarSendEngine(reader: Self.reader(honest)).broadcast([tampered], chain: .stellar)
        }
    }

    @Test("Acompanhamento: as duas Horizons dizem incluida, e o ledger fechado ja e final")
    func status() async throws {
        let engine = StellarSendEngine(reader: Self.reader(try Self.network()))
        let status = await engine.status("69178363c4d302d79d513e3bf2e9f19d0464b986514b479fb40babf608e29eb3", chain: .stellar)
        #expect(status == .confirmed(detail: "Incluída no ledger 64.624.666, que já é final."))
        #expect(await engine.status(String(repeating: "a", count: 64), chain: .stellar) == .pending)
    }

    // MARK: Atividade

    @Test("Atividade: poeira de enderecos parecidos com remetentes reais escondida; parecido com destino ja pago tambem")
    func activity() async throws {
        // O remetente real dos 2.000 XLM (5e1e3b50...) e trocado por um texto com o comeco
        // e o fim do destino que a conta ja pagou: o golpe do endereco parecido.
        let lookalike = "GAQZU7Y2KJ3OWEBQ4XY5ZQ6AVRMNB2HTKDLXNSE4KWT7PZQ3VAGYJCXG"
        let operations = try EngineFixture.data(
            "stellar", "operations-dono.json", replacing: [("GBTKIPIUB3XQFFIJQBTGDK7T22CVCLN6EZJINRTT7GWVKAFMYYJRU3CV", lookalike)]
        )
        let source = StellarActivitySource(reader: Self.reader(try Self.network(operations: operations)))
        let entries = try await source.history(chain: .stellar, account: TestAccounts.stellar, usage: nil)
        #expect(entries.count == 30)
        func entry(_ hash: String) throws -> ActivityEntry { try #require(entries.first { $0.hash.hasPrefix(hash) }) }

        // 0,001 XLM de GDRHXK... (parecido com GDRHJE..., que mandou 702.904 XLM): poeira.
        #expect(try entry("5d7b0bb52f").suspicious)
        #expect(try !entry("dd755131eb").suspicious && entry("dd755131eb").amount == 7_029_046_097_624)
        #expect(try entry("4ff972e5aa").suspicious)  // 0,0000001 XLM
        #expect(try entry("5e1e3b504a").suspicious && entry("5e1e3b504a").counterparty == lookalike)
        // USDC recebido e da lista: aparece, com o ativo da lista.
        #expect(try !entry("69178363c4").suspicious && entry("69178363c4").asset == Self.usdc)
        // O que a conta mandou aparece sempre.
        #expect(try entry("f92c60a0e9").direction == .sent && !entry("f92c60a0e9").suspicious)
        #expect(entries.allSatisfy { $0.id.hasPrefix("stellar:") && $0.status == .confirmed })
    }
}

/// A troca e a ordem limite na DEX da Stellar.
@Suite("Troca na Stellar com respostas gravadas")
struct StellarTradeTests {
    typealias S = StellarEngineTests

    static func request(sell: Asset = S.xlm, buy: Asset = S.usdc, amount: BigUInt = 1_000_000_000, bps: Int = 50) -> TradeRequest {
        TradeRequest(walletID: UUID(), chain: .stellar, account: TestAccounts.stellar, sell: sell, buy: buy, amountIn: amount, slippageBasisPoints: bps)
    }

    @Test("Cotacao: a melhor rota da Horizon, o minimo pela tolerancia e o impacto contra uma troca pequena")
    func quote() async throws {
        let engine = StellarTradeEngine(reader: S.reader(try S.network()))
        let quote = try await engine.quote(Self.request())
        #expect(quote.expectedOut == 217_308_710)
        #expect(quote.minimumOut == 216_222_166)  // 217.308.710 x 9.950 / 10.000, para baixo
        let impact = try #require(quote.priceImpactPercent)
        #expect(impact > 0.05 && impact < 0.2)
        #expect(!quote.needsApproval && quote.legs.count == 1 && quote.providersCompared == 1)
        #expect(engine.supportsLimitOrders && !engine.limitCustodyNote.contains("—"))
    }

    @Test("Plano: path payment para a propria conta, com destMin igual ao minimo da cotacao")
    func plan() async throws {
        let engine = StellarTradeEngine(reader: S.reader(try S.network()))
        let request = Self.request()
        let quote = try await engine.quote(request)
        let plan = try await engine.plan(request, quote: quote)
        #expect(plan.review.kind == .swap)
        let swap = try #require(StellarTradeEngine.swap(in: plan))
        #expect(swap.destMin == quote.minimumOut && swap.sendAmount == request.amountIn)
        #expect(swap.destination.address == S.owner)
        // A conta ja tem a linha de USDC: uma operacao so.
        #expect(try S.operations(plan).count == 1)

        // Outra tolerancia depois da cotacao: o minimo mudaria, recusa.
        await #expect(throws: SendEngineError.message(TradeMath.priceMoved)) {
            _ = try await engine.plan(Self.request(bps: 100), quote: quote)
        }
    }

    @Test("Conta sem a linha do ativo comprado: ChangeTrust e path payment na mesma transacao")
    func opensTrustline() async throws {
        // A gravacao da conta, sem a linha de USDC (troca feita aqui, nas duas Horizons).
        var owner: [String: Data] = [:]
        for name in ["sdf", "lobstr"] {
            let text = String(decoding: try EngineFixture.data("stellar", "account-dono-\(name).json"), as: UTF8.self)
            var json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            json["balances"] = (json["balances"] as? [[String: Any]])?.filter { $0["asset_code"] as? String != "USDC" }
            owner[name] = try JSONSerialization.data(withJSONObject: json)
        }
        let engine = StellarTradeEngine(reader: S.reader(try S.network(owner: owner)))
        let quote = try await engine.quote(Self.request())
        let plan = try await engine.plan(Self.request(), quote: quote)
        let operations = try S.operations(plan)
        #expect(operations.count == 2)
        guard case .changeTrust(let asset, _) = operations[0] else { Issue.record("esperava ChangeTrust primeiro"); return }
        #expect(asset.code == "USDC")
        #expect(StellarTradeEngine.swap(in: plan)?.destMin == quote.minimumOut)
    }

    @Test("Preco que piorou alem do minimo entre a cotacao e o plano, e cotacao vencida: recusa antes de assinar")
    func stalePrice() async throws {
        let quote = try await StellarTradeEngine(reader: S.reader(try S.network())).quote(Self.request())
        // A rota agora entrega menos que o minimo (troca feita aqui na gravacao).
        let worse = try S.network(paths: ["100.0000000": "paths-xlm-usdc-referencia.json"])
        await #expect(throws: SendEngineError.message(TradeMath.priceMoved)) {
            _ = try await StellarTradeEngine(reader: S.reader(worse)).plan(Self.request(), quote: quote)
        }
        let expired = TradeQuote(
            sell: quote.sell, buy: quote.buy, amountIn: quote.amountIn, expectedOut: quote.expectedOut, minimumOut: quote.minimumOut,
            priceImpactPercent: nil, networkFeeFiat: nil, providerFeeNote: nil, legs: [], alternatives: [], providersCompared: 1,
            needsApproval: false, expiresAt: Date().addingTimeInterval(-1)
        )
        await #expect(throws: SendEngineError.self) {
            _ = try await StellarTradeEngine(reader: S.reader(try S.network())).plan(Self.request(), quote: expired)
        }
        await #expect(throws: SendEngineError.self) {
            _ = try await StellarTradeEngine(reader: S.reader(try S.network())).quote(Self.request(bps: 600))
        }
    }

    @Test("Ordem limite: ManageSellOffer com o preco calculado do minimo digitado")
    func limitOrder() async throws {
        let engine = StellarTradeEngine(reader: S.reader(try S.network()))
        let plan = try await engine.planLimitOrder(LimitOrderRequest(
            walletID: UUID(), chain: .stellar, account: TestAccounts.stellar, sell: S.usdc, buy: S.xlm,
            amountIn: 100_000_000, minimumOut: 500_000_000, validFor: 86_400
        ))
        #expect(plan.review.kind == .limitOrder)
        guard case .manageSellOffer(let selling, let buying, 100_000_000, let price, 0) = try S.operations(plan).first else {
            Issue.record("esperava ManageSellOffer"); return
        }
        #expect(selling.code == "USDC" && buying.isNative)
        #expect(price.n == 5 && price.d == 1)
    }
}
