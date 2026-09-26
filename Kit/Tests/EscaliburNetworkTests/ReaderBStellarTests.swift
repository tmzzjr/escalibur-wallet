import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Leitor da Stellar contra respostas gravadas da Horizon (FixturesB/LEIA-ME.txt).
@Suite("ReaderB Stellar: respostas gravadas")
struct ReaderBStellarTests {
    typealias T = ReaderBTest

    static let owner = "GA5XIGA5C7QTPTWXQHY6MCJRMTRZDOSHR6EFIBNDQTCQHG262N4GGKTM"
    static let memoAccount = "GDQP2KPQGKIHYJGXNUIYOMHARUARCA7DJT5FO2FFOOKY3B2WSQHG4W37"
    static let missingAccount = "GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6"
    static let offerAccount = "GB3FQB7JYQ37PVYL3DE7ZWYMQCDXZFQBLA23HHJOYA3MIOHCSLT3BCYY"
    static let usdc = try! StellarAsset(code: "USDC", issuer: "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN")
    static let sequence = "2390162185805648"

    static func id(_ address: String) throws -> StellarAccountID {
        try #require(StellarAccountID(address: address))
    }

    static func reader(_ transport: ReaderBFakeTransport) -> StellarReader {
        StellarReader(transport: transport, providers: T.horizonProviders)
    }

    /// As duas Horizon respondendo a mesma conta, cada uma com a sua gravacao.
    static func accountTransport(sdf: Data? = nil, lobstr: Data? = nil) throws -> ReaderBFakeTransport {
        let transport = ReaderBFakeTransport()
        transport.on("horizon-a.test/accounts/\(owner)", data: try sdf ?? T.fixture("horizon-account.json"))
        transport.on("horizon-b.test/accounts/\(owner)", data: try lobstr ?? T.fixture("horizon-account-lobstr.json"))
        return transport
    }

    // MARK: Conta do dono

    @Test("Conta do dono: sequence em dois provedores, saldos, reservas e trustlines")
    func ownerAccount() async throws {
        let state = try #require(try await Self.reader(try Self.accountTransport()).ownerAccount(try Self.id(Self.owner)))
        #expect(state.account.address == Self.owner)
        #expect(state.sequence == 2_390_162_185_805_648)
        #expect(state.balance == 39_999_808)
        #expect(state.subentryCount == 3)
        #expect(state.sellingLiabilities == 0 && state.numSponsoring == 0 && state.numSponsored == 0)
        #expect(state.trustlines.map(\.asset.code) == ["PYUSD", "USDC", "USDT0"])
        let usdc = try #require(state.trustline(for: Self.usdc))
        #expect(usdc.balance == 2 && usdc.limit == BigUInt(UInt64(Int64.max)) && usdc.isAuthorized)
    }

    @Test("Sequence divergente: vale o registro local; sem ele, recusa")
    func sequenceConsensus() async throws {
        let ahead = try T.fixture("horizon-account-lobstr.json", replacing: [("\"sequence\": \"\(Self.sequence)\"", "\"sequence\": \"2390162185805649\"")])
        let reader = Self.reader(try Self.accountTransport(lobstr: ahead))
        let owner = try Self.id(Self.owner)
        await #expect(throws: ChainReaderError.providersDisagree) { try await reader.ownerAccount(owner) }
        await #expect(throws: ChainReaderError.providersDisagree) { try await reader.ownerAccount(owner, localSequence: 7) }
        #expect(try await reader.ownerAccount(owner, localSequence: 2_390_162_185_805_649)?.sequence == 2_390_162_185_805_649)
        #expect(try await reader.ownerAccount(owner, localSequence: 2_390_162_185_805_648)?.sequence == 2_390_162_185_805_648)
    }

    @Test("Um provedor fora do ar: sem consenso, sem sequence")
    func sequenceNeedsTwo() async throws {
        let transport = try Self.accountTransport()
        transport.on("horizon-b.test/accounts/\(Self.owner)", status: 503)
        await #expect(throws: ChainReaderError.notEnoughSources(needed: 2, got: 1)) {
            try await Self.reader(transport).ownerAccount(try Self.id(Self.owner))
        }
    }

    @Test("Conta que nao existe: nil nos dois; existe num e nao no outro, recusa")
    func ownerMissing() async throws {
        let transport = try Self.accountTransport()
        transport.on("horizon-a.test/accounts/\(Self.owner)", status: 404)
        transport.on("horizon-b.test/accounts/\(Self.owner)", status: 404)
        #expect(try await Self.reader(transport).ownerAccount(try Self.id(Self.owner)) == nil)
        transport.on("horizon-b.test/accounts/\(Self.owner)", data: try T.fixture("horizon-account-lobstr.json"))
        await #expect(throws: ChainReaderError.providersDisagree) { try await Self.reader(transport).ownerAccount(try Self.id(Self.owner)) }
    }

    @Test("Resposta estrita: campo faltando, valor com casas demais, conta trocada")
    func strictAccount() async throws {
        let owner = try Self.id(Self.owner)
        let noSequence = try T.fixture("horizon-account.json", replacing: [("\"sequence\":", "\"sequencia\":")])
        await #expect(throws: ChainReaderError.notEnoughSources(needed: 2, got: 1)) {
            try await Self.reader(try Self.accountTransport(sdf: noSequence)).ownerAccount(owner)
        }
        #expect(throws: ChainReaderError.malformedResponse(field: "sequence")) {
            _ = try ReaderDecode.json(HorizonAccount.self, from: noSequence)
        }
        let record = try ReaderDecode.json(HorizonAccount.self, from: try T.fixture("horizon-account.json"))
        #expect(throws: ChainReaderError.mismatchedResponse) { try StellarReader.state(record, expected: try Self.id(Self.memoAccount)) }
        let tooPrecise = try ReaderDecode.json(HorizonAccount.self, from: try T.fixture("horizon-account.json", replacing: [("\"154.0697710\"", "\"154.06977101\"")]))
        #expect(throws: ChainReaderError.malformedResponse(field: "balances.0")) { try StellarReader.state(tooPrecise, expected: owner) }
    }

    // MARK: Destino

    @Test("Destino com config.memo_required: basta um provedor dizer")
    func destinationMemo() async throws {
        let transport = ReaderBFakeTransport()
        transport.on("horizon-a.test/accounts/\(Self.memoAccount)", data: try T.fixture("horizon-account-memo-required.json"))
        transport.on("horizon-b.test/accounts/\(Self.memoAccount)", data: try T.fixture("horizon-account-memo-required.json"))
        let both = try await Self.reader(transport).destination(Self.memoAccount)
        #expect(both.exists && both.memoRequired)
        #expect(both.trustline(for: Self.usdc) != nil)

        // Um provedor esconde a entrada de dados: continua obrigatorio.
        transport.on("horizon-a.test/accounts/\(Self.memoAccount)", data: try T.fixture(
            "horizon-account-memo-required.json", replacing: [("\"config.memo_required\": \"MQ==\"", "\"outra\": \"MQ==\"")]
        ))
        #expect(try await Self.reader(transport).destination(Self.memoAccount).memoRequired)

        let plain = try await Self.reader(try Self.accountTransport()).destination(Self.owner)
        #expect(plain.exists && !plain.memoRequired)
    }

    @Test("Destino inexistente (404 nos dois) e endereco muxed consulta a conta base")
    func destinationMissing() async throws {
        let transport = ReaderBFakeTransport()
        // O corpo do 404 gravado (horizon-account-404.json) nem chega a ser lido: o
        // cliente HTTP ja devolve o status.
        #expect(try JSONSerialization.jsonObject(with: try T.fixture("horizon-account-404.json")) is [String: Any])
        transport.on("horizon-a.test/accounts/\(Self.missingAccount)", status: 404)
        transport.on("horizon-b.test/accounts/\(Self.missingAccount)", status: 404)
        #expect(try await Self.reader(transport).destination(Self.missingAccount) == .missing)

        let muxed = StellarKey.muxedAddress(publicKey: try Self.id(Self.owner).publicKey, id: 42)
        let state = try await Self.reader(try Self.accountTransport()).destination(muxed)
        #expect(state.exists)
        await #expect(throws: ChainReaderError.mismatchedResponse) { try await Self.reader(transport).destination("nao-e-endereco") }
    }

    // MARK: Rede, ofertas e cotacao

    @Test("Rede: reserva e taxa base do ultimo ledger, p90 do fee_stats")
    func networkState() async throws {
        let transport = ReaderBFakeTransport()
        transport.on("horizon-a.test/ledgers", data: try T.fixture("horizon-ledgers.json"))
        transport.on("horizon-a.test/fee_stats", data: try T.fixture("horizon-fee-stats.json"))
        let state = try await Self.reader(transport).networkState()
        #expect(state == StellarNetworkState(baseReserve: 5_000_000, baseFee: 100, feeChargedP90: 9_236))
        let query = try #require(transport.requests.first?.url.query)
        #expect(query.contains("order=desc") && query.contains("limit=1"))
    }

    @Test("Ofertas abertas da conta")
    func offers() async throws {
        let transport = ReaderBFakeTransport()
        transport.on("horizon-a.test/accounts/\(Self.offerAccount)/offers", data: try T.fixture("horizon-offers.json"))
        let offers = try await Self.reader(transport).offers(try Self.id(Self.offerAccount))
        #expect(offers.count == 3)
        let first = try #require(offers.first)
        #expect(first.id == 1_859_051_262)
        #expect(first.selling == Self.usdc && first.buying == .native)
        #expect(first.amount == 658_336_200)
        #expect(first.priceNumerator == 5_000_000 && first.priceDenominator == 1_097_227)
        // As ofertas de outra conta, entregues como se fossem desta: recusadas.
        transport.on("horizon-a.test/accounts/\(Self.owner)/offers", data: try T.fixture("horizon-offers.json"))
        await #expect(throws: ChainReaderError.mismatchedResponse) { try await Self.reader(transport).offers(try Self.id(Self.owner)) }
    }

    @Test("Cotacao strict send: a melhor rota para o par e o valor pedidos")
    func quote() async throws {
        let transport = ReaderBFakeTransport()
        transport.on("horizon-a.test/paths/strict-send", data: try T.fixture("horizon-paths-strict-send.json"))
        let reader = Self.reader(transport)
        let quote = try #require(try await reader.quoteStrictSend(send: .native, amount: 1_000_000_000, receive: Self.usdc))
        #expect(quote.receiveAmount == 219_572_909)
        #expect(quote.path.map(\.code) == ["yXLM"])
        let query = try #require(transport.requests.first?.url.query)
        #expect(query.contains("source_asset_type=native") && query.contains("source_amount=100.0000000"))
        #expect(query.contains("destination_assets=USDC:\(Self.usdc.issuer!.address)") || query.contains("destination_assets=USDC%3A"))
        // A resposta e para 100 XLM: pedir outro valor (ou outro ativo) nao usa essa rota.
        #expect(try await reader.quoteStrictSend(send: .native, amount: 1_000_000_001, receive: Self.usdc) == nil)
        let fake = try StellarAsset(code: "USDC", issuer: Self.missingAccount)
        #expect(try await reader.quoteStrictSend(send: .native, amount: 1_000_000_000, receive: fake) == nil)
    }

    // MARK: Transmissao

    /// Um envio real assinado com a chave do vetor SEP-0005 (so no teste).
    static func signedPayment() throws -> SignedTransaction {
        let secret = "SBGWSG6BTNCKCOB3DIFBGCVMUPQFYPA2G4O34RMTB343OYPXU5DJDVMN"
        let raw = try #require(StellarKey.decode(secret, version: 18 << 3))
        let seed = SecureBytes(capacity: 32)
        seed.replaceAll(with: raw)
        let key = try Ed25519.publicKey(of: seed)
        let source = try StellarSource(path: DefaultPaths.path(for: .stellar), publicKey: key)
        let context = StellarPlanContext(
            walletID: UUID(), source: source,
            account: StellarAccountState(account: source.account, sequence: 1_000, balance: 100_000_000, subentryCount: 0),
            network: StellarNetworkState(baseReserve: 5_000_000, baseFee: 100, feeChargedP90: 100),
            allowedAssets: []
        )
        let plan = try StellarPlanner.planSendNative(
            amount: 10_000_000, to: owner, destination: StellarDestinationState(exists: true), context: context
        )
        let transaction = try #require(plan.transactions.first)
        let signature = try Ed25519.sign(try #require(transaction.signingRequests.first).payload, seed: seed)
        return try transaction.assemble(with: [ProducedSignature(bytes: signature)])
    }

    @Test("Transmissao: formulario tx=<base64>, mesmos bytes, hash conferido")
    func broadcast() async throws {
        let signed = try Self.signedPayment()
        let accepted = try T.fixture("horizon-transaction.json", replacing: [
            ("f374929844a4725abdbb61bda497b8c99833d877ec224ee6d41af00cb23601cb", signed.id),
        ])
        let transport = ReaderBFakeTransport()
        // A SDF devolve o hash de outra transacao: nao conta. A LOBSTR confirma.
        transport.on("horizon-a.test/transactions", data: try T.fixture("horizon-transaction.json"))
        transport.on("horizon-b.test/transactions", data: accepted)
        let submission = try await Self.reader(transport).broadcast(signed)
        #expect(submission.hash == signed.id && submission.provider == "lobstr" && submission.ledger == 64_620_554)
        #expect(transport.requests.count == 2)
        for request in transport.requests {
            #expect(request.contentType == "application/x-www-form-urlencoded")
            let body = String(decoding: try #require(request.body), as: UTF8.self)
            #expect(body.hasPrefix("tx=") && !body.contains("+") && !body.contains("/"))
            #expect(body.dropFirst(3).removingPercentEncoding == signed.encoded)
        }
    }

    @Test("Envelope que nao fecha com o id, ou de outra rede, nao sai")
    func broadcastRefusesInconsistent() async throws {
        let good = try Self.signedPayment()
        let transport = ReaderBFakeTransport()
        let reader = Self.reader(transport)
        for signed in [
            SignedTransaction(chainID: "stellar", raw: good.raw, encoded: good.encoded, id: String(repeating: "0", count: 64)),
            SignedTransaction(chainID: "xrpl", raw: good.raw, encoded: good.encoded, id: good.id),
            SignedTransaction(chainID: "stellar", raw: good.raw, encoded: "AAAA" + good.encoded, id: good.id),
        ] {
            await #expect(throws: ChainReaderError.signedTransactionInconsistent) { try await reader.broadcast(signed) }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Status nos dois provedores: confirmada, desconhecida, divergente")
    func status() async throws {
        let hash = "f374929844a4725abdbb61bda497b8c99833d877ec224ee6d41af00cb23601cb"
        let transport = ReaderBFakeTransport()
        transport.on("horizon-a.test/transactions/\(hash)", data: try T.fixture("horizon-transaction.json"))
        transport.on("horizon-b.test/transactions/\(hash)", data: try T.fixture("horizon-transaction.json"))
        let reader = Self.reader(transport)
        #expect(try await reader.status(hash: hash) == .confirmed(height: 64_620_554, confirmations: nil))
        transport.on("horizon-b.test/transactions/\(hash)", status: 404)
        #expect(try await reader.status(hash: hash) == .pending)
        transport.on("horizon-a.test/transactions/\(hash)", status: 404)
        #expect(try await reader.status(hash: hash) == .notFound)
        transport.on("horizon-a.test/transactions/\(hash)", data: try T.fixture("horizon-transaction.json", replacing: [("\"successful\": true", "\"successful\": false")]))
        transport.on("horizon-b.test/transactions/\(hash)", data: try T.fixture("horizon-transaction.json"))
        await #expect(throws: ChainReaderError.providersDisagree) { try await reader.status(hash: hash) }
    }

    // MARK: Historico

    @Test("Historico: pagamentos em duas direcoes, saldo reivindicavel de desconhecido, poeira")
    func history() async throws {
        let transport = ReaderBFakeTransport()
        // Um dos pagamentos recebidos vira 0,0000001 XLM: o spam classico.
        transport.on("horizon-a.test/accounts/\(Self.owner)/operations", data: try T.fixture(
            "horizon-operations.json", replacing: [("\"amount\": \"1.4999600\"", "\"amount\": \"0.0000001\"")]
        ))
        transport.on("horizon-a.test/accounts/\(Self.owner)/trades", data: Data("{\"_embedded\":{\"records\":[]}}".utf8))
        let items = try await Self.reader(transport).history(try Self.id(Self.owner), listedAssets: [Self.usdc])
        #expect(items.count == 30)

        let sent = try #require(items.first { $0.id == "277545846139256833" })
        #expect(sent.kind == .send && sent.movements == [.init(asset: .native, amount: 84_217_966_990, incoming: false)])
        #expect(sent.counterparty?.hasPrefix("GAQZU7") == true && sent.status == .confirmed(confirmations: nil))
        #expect(sent.transactionHash?.count == 64)

        let usdcIn = try #require(items.first { $0.id == "277545309268332545" })
        #expect(usdcIn.kind == .receive && usdcIn.suspicion == nil)
        #expect(usdcIn.movements.first?.asset == .issued(code: "USDC", issuer: Self.usdc.issuer!.address))

        let claimable = try #require(items.first { $0.kind == .claimableBalance })
        #expect(claimable.suspicion == .unsolicitedClaimable)

        let dust = try #require(items.first { $0.movements.first?.amount == 1 })
        #expect(dust.kind == .receive && dust.suspicion == .dust)

        // Do mais novo para o mais velho.
        let dates = items.compactMap(\.date)
        #expect(dates == dates.sorted(by: >))
    }

    @Test("Trades de oferta executada e operacoes de oferta")
    func historyTrades() async throws {
        let transport = ReaderBFakeTransport()
        transport.on("horizon-a.test/accounts/\(Self.offerAccount)/operations", data: try T.fixture("horizon-operations-offers.json"))
        transport.on("horizon-a.test/accounts/\(Self.offerAccount)/trades", data: try T.fixture("horizon-trades.json"))
        let items = try await Self.reader(transport).history(try Self.id(Self.offerAccount), listedAssets: [Self.usdc])
        #expect(items.count == 10)
        #expect(items.filter { $0.kind == .offer }.count == 6)
        let trade = try #require(items.first { $0.kind == .trade })
        // base_is_seller falso e esta conta do lado counter: entregou USDC, recebeu XLM.
        #expect(trade.movements == [
            .init(asset: .issued(code: "USDC", issuer: Self.usdc.issuer!.address), amount: 38_037, incoming: false),
            .init(asset: .native, amount: 173_042, incoming: true),
        ])
        #expect(trade.transactionHash == nil && trade.suspicion == nil)
    }
}
