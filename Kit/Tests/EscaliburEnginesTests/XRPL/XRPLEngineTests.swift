@testable import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// Rede de mentira do XRP Ledger com as gravacoes (Fixtures/xrpl): rippled e Clio, as
/// leituras de conta e de livro no mesmo ledger validado.
enum XRPLTestNetwork {
    static let owner = "rEb8TK3gBgk5auZkwc6sHnwrGVJH8DuaLh"
    static let exchange = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
    static let plain = "rJb5KsHsDHF1YS5B5DU6QCkH5NsPaKQTcy"
    static let missing = "rrrrrrrrrrrrrrrrrrrrrhoLvTp"
    static let ledger: UInt32 = 107_244_179
    static let validatedTx = "692B5317FE8FB841C8F3F1EBA99E9F525191055F4F107F01876F8C62ECE83D0E"
    static let accounts = [owner: "dono", exchange: "exchange", plain: "comum", missing: "inexistente"]

    static let providers = [
        EngineFixture.provider("rippled", "https://rippled.test"),
        EngineFixture.provider("clio", "https://clio.test"),
    ]

    static func fake(serverInfo: Data? = nil, submit: @escaping @Sendable ([String: Any]) -> Data? = { _ in nil }) throws -> FakeRPC {
        var files: [String: Data] = [:]
        for name in ["ledger-validated", "server_info", "fee", "account_tx-exchange", "tx-validado", "tx-nao-achado"] {
            files[name] = try EngineFixture.data("xrpl", name + ".json")
        }
        for host in ["rippled", "clio"] {
            for label in accounts.values { files["account_info-\(label)-\(host)"] = try EngineFixture.data("xrpl", "account_info-\(label)-\(host).json") }
            for name in ["account_lines-dono", "book_offers-compra-rlusd", "book_offers-venda-rlusd"] {
                files["\(name)-\(host)"] = try EngineFixture.data("xrpl", "\(name)-\(host).json")
            }
        }
        let loaded = files
        let server: @Sendable (String) -> String = { host in host.hasPrefix("clio") ? "clio" : "rippled" }
        let fake = FakeRPC()
        fake.on("ledger", data: loaded["ledger-validated"]!)
        fake.on("server_info", data: serverInfo ?? loaded["server_info"]!)
        fake.on("fee", data: loaded["fee"]!)
        fake.on("account_tx", data: loaded["account_tx-exchange"]!)
        fake.on("account_info") { host, params in
            guard let account = params["account"] as? String, let label = accounts[account] else { return nil }
            return loaded["account_info-\(label)-\(server(host))"]
        }
        fake.on("account_lines") { host, params in
            params["account"] as? String == owner ? loaded["account_lines-dono-\(server(host))"] : nil
        }
        fake.on("book_offers") { host, params in
            let side = (params["taker_gets"] as? [String: Any])?["currency"] as? String == "XRP" ? "venda" : "compra"
            return loaded["book_offers-\(side)-rlusd-\(server(host))"]
        }
        fake.on("tx") { _, params in
            params["transaction"] as? String == validatedTx ? loaded["tx-validado"] : loaded["tx-nao-achado"]
        }
        fake.on("submit") { _, params in submit(params) }
        return fake
    }

    static func reader(_ fake: FakeRPC) -> XRPLReader { XRPLReader(transport: fake, providers: providers) }

    /// A resposta de `submit` que um servidor da, com o hash informado.
    static func submitted(_ result: String, hash: String) -> Data {
        Data("{\"result\":{\"engine_result\":\"\(result)\",\"tx_json\":{\"hash\":\"\(hash)\"},\"status\":\"success\"}}".utf8)
    }

    /// Os bytes da transacao do plano como se estivessem assinados: o motor e o leitor
    /// nao conferem assinatura (quem confere e o assinador), so bytes, codificacao e id.
    static func signed(_ transaction: any SignableTransaction) throws -> SignedTransaction {
        let blob = try #require(transaction as? XRPLTransaction).unsignedBlob
        let id = Hex.encode(Hash.sha512Half([0x54, 0x58, 0x4E, 0x00] + blob)).uppercased()
        return SignedTransaction(chainID: "xrpl", raw: blob, encoded: Hex.encode(blob).uppercased(), id: id)
    }
}

@Suite("Motores XRP Ledger com respostas gravadas")
struct XRPLEngineTests {
    typealias N = XRPLTestNetwork

    static func request(to destination: String, drops: BigUInt = 1_000_000, tag: String? = nil, sendAll: Bool = false) -> SendRequest {
        SendRequest(
            walletID: UUID(), chain: .xrpl, asset: .native(.xrpl), account: TestAccounts.xrpl, destination: destination, tag: tag,
            amount: drops, sendAll: sendAll, feeLevel: .normal, utxoUsage: nil
        )
    }

    @Test("Destino: RequireDest vira tag obrigatoria, DisallowXRP vira nota, conta inexistente leva a reserva base")
    func destination() async throws {
        let engine = XRPLSendEngine(reader: N.reader(try N.fake()))
        let exchange = try await engine.destination(N.exchange, chain: .xrpl)
        #expect(exchange.exists && exchange.requiresTag)
        #expect(exchange.note?.contains("não receber XRP") == true)
        let plain = try await engine.destination(N.plain, chain: .xrpl)
        #expect(plain.exists && !plain.requiresTag && plain.note == nil)
        let missing = try await engine.destination(N.missing, chain: .xrpl)
        #expect(!missing.exists && missing.activationMinimum == 1_000_000)
        #expect(missing.note?.contains("1 XRP") == true)
    }

    @Test("Maximo: saldo menos a reserva menos a taxa, com a reserva dita em texto")
    func spendable() async throws {
        let engine = XRPLSendEngine(reader: N.reader(try N.fake()))
        let spendable = try await engine.spendable(Self.request(to: N.plain, sendAll: true))
        // 99.999.000 drops - 1 XRP de reserva - 12 drops de taxa (10 x 1,2).
        #expect(spendable.amount == 98_998_988)
        #expect(spendable.reserveNote == "1 XRP ficam reservados pela rede enquanto a conta existir.")
        #expect(spendable.feeNote == "Já descontada a taxa da rede, de 0,000012 XRP.")
    }

    @Test("Plano: destino e tag na revisao, LastLedgerSequence do ledger validado + 20, Sequence das duas leituras")
    func plan() async throws {
        let engine = XRPLSendEngine(reader: N.reader(try N.fake()))
        let plan = try await engine.plan(Self.request(to: N.plain, tag: "7"))
        #expect(plan.review.recipient == N.plain && plan.review.recipientTag == "7")
        let transaction = try #require(plan.transactions.first as? XRPLTransaction)
        #expect(transaction.lastLedgerSequence == N.ledger + 20 && transaction.sequence == 568_912)
        guard case .payment(let payment) = transaction.body else { Issue.record("esperava Payment"); return }
        #expect(payment.destinationTag == 7 && payment.amount == .xrp(drops: 1_000_000) && !payment.partialPayment)

        let all = try await engine.plan(Self.request(to: N.plain, drops: 1, sendAll: true))
        guard case .payment(let everything) = try #require(all.transactions.first as? XRPLTransaction).body else { return }
        #expect(everything.amount == .xrp(drops: 98_998_988))
    }

    @Test("Recusas: tag exigida, destino que nao quer XRP, tag que nao e numero, token")
    func refusals() async throws {
        let engine = XRPLSendEngine(reader: N.reader(try N.fake()))
        await #expect(throws: SendEngineError.message(XRPLEngineSupport.text(.destinationTagRequired))) {
            _ = try await engine.plan(Self.request(to: N.exchange))
        }
        await #expect(throws: SendEngineError.message(XRPLEngineSupport.text(.destinationDisallowsXRP))) {
            _ = try await engine.plan(Self.request(to: N.exchange, tag: "1"))
        }
        await #expect(throws: SendEngineError.self) { _ = try await engine.plan(Self.request(to: N.plain, tag: "abc")) }
        await #expect(throws: SendEngineError.message(XRPLEngineSupport.text(.belowActivationReserve(minimum: 0)))) {
            _ = try await engine.plan(Self.request(to: N.missing, drops: 999_999))
        }
    }

    @Test("LastLedgerSequence lido dos bytes serializados, e nada quando o comeco nao e de transacao")
    func lastLedgerFromBlob() async throws {
        let plan = try await XRPLSendEngine(reader: N.reader(try N.fake())).plan(Self.request(to: N.plain, tag: "7"))
        let transaction = try #require(plan.transactions.first as? XRPLTransaction)
        #expect(XRPLEngineSupport.lastLedgerSequence(transaction.unsignedBlob) == transaction.lastLedgerSequence)
        var broken = transaction.unsignedBlob
        broken[0] = 0x11
        #expect(XRPLEngineSupport.lastLedgerSequence(broken) == nil)
        #expect(XRPLEngineSupport.lastLedgerSequence(Array(transaction.unsignedBlob.prefix(6))) == nil)
    }

    @Test("Transmissao: id calculado dos bytes, e o acompanhamento pergunta ate o LastLedgerSequence")
    func broadcastAndStatus() async throws {
        let plan = try await XRPLSendEngine(reader: N.reader(try N.fake())).plan(Self.request(to: N.plain, tag: "7"))
        let signed = try N.signed(try #require(plan.transactions.first))
        let fake = try N.fake(submit: { _ in N.submitted("tesSUCCESS", hash: signed.id) })
        let engine = XRPLSendEngine(reader: N.reader(fake))
        #expect(try await engine.broadcast([signed], chain: .xrpl) == signed.id)

        // Nao achada com a busca completa ate o LastLedgerSequence: venceu sem entrar.
        let status = await engine.status(signed.id, chain: .xrpl)
        #expect(status == .failed(reason: "O prazo venceu antes de a transação entrar num ledger. Nada foi debitado."))
        let asked = fake.calls.filter { $0.method == "tx" }
        #expect(asked.count == 2 && asked.allSatisfy { ($0.params["max_ledger"] as? Int) == Int(N.ledger + 20) })

        let validated = await engine.status(N.validatedTx, chain: .xrpl)
        #expect(validated == .confirmed(detail: "Validada no ledger 107.234.715, que já é final."))
    }

    @Test("Transmissao recusada: prazo ja vencido no ledger validado, e servidor com outro hash")
    func broadcastRefusals() async throws {
        let plan = try await XRPLSendEngine(reader: N.reader(try N.fake())).plan(Self.request(to: N.plain, tag: "7"))
        let signed = try N.signed(try #require(plan.transactions.first))
        // O ledger validado anda alem da validade da transacao (troca feita aqui).
        let later = try EngineFixture.data("xrpl", "server_info.json", replacing: [("\"seq\":107244179", "\"seq\":107244300")])
        let expired = try N.fake(serverInfo: later, submit: { _ in N.submitted("tesSUCCESS", hash: signed.id) })
        await #expect(throws: SendEngineError.message("O prazo da transação venceu antes do envio. Nada foi debitado. Revise de novo.")) {
            _ = try await XRPLSendEngine(reader: N.reader(expired)).broadcast([signed], chain: .xrpl)
        }
        #expect(!expired.calls.contains { $0.method == "submit" })

        let liar = try N.fake(submit: { _ in N.submitted("tesSUCCESS", hash: String(repeating: "A", count: 64)) })
        await #expect(throws: SendEngineError.message(NetworkFailureText.inconsistent)) {
            _ = try await XRPLSendEngine(reader: N.reader(liar)).broadcast([signed], chain: .xrpl)
        }
    }

    @Test("Atividade gravada: pelo delivered_amount, com ids da rede")
    func activity() async throws {
        let exchange = DerivedAccount(
            chainID: "xrpl", path: TestAccounts.xrpl.path, address: N.exchange, publicKey: TestAccounts.xrpl.publicKey, accountXPub: nil
        )
        let entries = try await XRPLActivitySource(reader: N.reader(try N.fake())).history(chain: .xrpl, account: exchange, usage: nil)
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.id.hasPrefix("xrpl:") && $0.hash.count == 64 && $0.asset == .native(.xrpl) })
        #expect(entries.contains { $0.direction == .received })
    }

    @Test("Atividade: recebimento de endereco parecido com um destino ja pago fica suspeito; o envio nunca")
    func activityLookalike() {
        let lookalike = "rJb5KsQ9vWmT2cNpLz8dXrYh4gFkEuQTcy"
        func item(_ id: String, _ direction: ActivityItem.Direction, _ counterparty: String) -> ActivityItem {
            ActivityItem(
                id: "xrpl:" + id, chainID: "xrpl", direction: direction, asset: .native(.xrpl), amount: 5_000_000,
                counterparty: counterparty, date: Date(), status: .confirmed, fee: nil, hash: id, explorerURL: nil
            )
        }
        let page = ActivityPage(chainID: "xrpl", items: [
            item("A1", .sent, N.plain), item("A2", .received, lookalike), item("A3", .received, N.exchange), item("A4", .sent, lookalike),
        ], suspicious: SuspiciousSummary())
        let entries = XRPLActivitySource.entries(page, owner: N.owner)
        #expect(entries.map(\.suspicious) == [false, true, false, false])
    }
}
