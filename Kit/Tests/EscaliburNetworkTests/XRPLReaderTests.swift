import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Leitor do XRP Ledger contra respostas gravadas (Fixtures/leitores/xrpl), sem rede.
/// Gravadas em 25/09/2026 no xrplcluster.com (rippled) e em s1/s2.ripple.com (Clio).
@Suite("Leitor XRP Ledger com respostas gravadas")
struct XRPLReaderTests {
    static let owner = "rEb8TK3gBgk5auZkwc6sHnwrGVJH8DuaLh"
    static let exchange = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
    static let unfunded = "rrrrrrrrrrrrrrrrrrrrrhoLvTp"
    static let ledger: UInt32 = {
        let json = try! ReaderFixtures.json("xrpl", "ledger-validated")
        return try! json.field("result", "$").field("ledger_index", "$").uint32("$")
    }()

    /// Responde por metodo e por conta; `perHost` troca a resposta de um host.
    static func transport(accounts: [String: String] = [:], perHost: [String: [String: Data]] = [:]) throws -> FixtureTransport {
        let common: [String: Data] = [
            "server_info": try ReaderFixtures.data("xrpl", "server_info"),
            "fee": try ReaderFixtures.data("xrpl", "fee"),
            "ledger": try ReaderFixtures.data("xrpl", "ledger-validated"),
            "deposit_authorized": try ReaderFixtures.data("xrpl", "deposit_authorized"),
            "tx": try ReaderFixtures.data("xrpl", "tx-validado"),
            "account_tx": try ReaderFixtures.data("xrpl", "account_tx-exchange"),
        ]
        var loaded: [String: Data] = [:]
        for (account, fixture) in accounts { loaded[account] = try ReaderFixtures.data("xrpl", fixture) }
        let byAccount = loaded
        return FixtureTransport([{ request, body in
            guard let method = FixtureTransport.method(body) else { return nil }
            if let host = request.url.host, let special = perHost[host]?[method] { return special }
            if method == "account_info" {
                let params = FixtureTransport.params(body).first
                guard let account = try? params?.field("account", "p").string("p") else { return nil }
                return byAccount[account]
            }
            return common[method]
        }])
    }

    static func reader(_ transport: FixtureTransport) -> XRPLReader {
        XRPLReader(transport: transport, providers: testProviders("rippled", "clio"))
    }

    @Test("server_info e fee gravados: ledger validado, reservas em drops, taxa do ledger aberto")
    func ledgerState() async throws {
        let state = try await Self.reader(try Self.transport()).ledgerState()
        #expect(state.reserveBase == BigUInt(1_000_000))
        #expect(state.reserveIncrement == BigUInt(200_000))
        #expect(state.openLedgerFee == BigUInt(10))
        #expect(state.validatedLedgerIndex > 107_000_000)
    }

    @Test("server_info de outra rede e recusado; reserva absurda tambem")
    func ledgerSanity() throws {
        let info = try ReaderFixtures.json("xrpl", "server_info").field("result", "$")
        let fee = try ReaderFixtures.json("xrpl", "fee").field("result", "$")
        func mutate(_ change: (inout [String: StrictJSON]) -> Void) throws -> StrictJSON {
            var root = try info.object("r")
            var inner = try root["info"]!.object("i")
            change(&inner)
            root["info"] = .object(inner)
            return .object(root)
        }
        let testnet = try mutate { $0["network_id"] = .int(1) }
        #expect(throws: ReaderError.wrongNetwork) { _ = try XRPLReader.parseLedgerState(serverInfo: testnet, fee: fee) }
        let hugeReserve = try mutate {
            var validated = try! $0["validated_ledger"]!.object("v")
            validated["reserve_base_xrp"] = .number("1000")
            $0["validated_ledger"] = .object(validated)
        }
        #expect(throws: ReaderError.implausibleValue(field: "server_info.info.validated_ledger.reserve_base_xrp")) {
            _ = try XRPLReader.parseLedgerState(serverInfo: hugeReserve, fee: fee)
        }
        let syncing = try mutate { $0["server_state"] = .string("syncing") }
        #expect(throws: ReaderError.self) { _ = try XRPLReader.parseLedgerState(serverInfo: syncing, fee: fee) }
    }

    @Test("Conta do dono em dois servidores (rippled e Clio), no mesmo ledger, ate o plano")
    func accountState() async throws {
        let transport = try Self.transport(accounts: [Self.owner: "account_info-dono-rippled", Self.exchange: "account_info-destino-tag"])
        let reader = Self.reader(transport)
        let account = try await reader.accountState(address: Self.owner)
        #expect(account.sequenceReadings == [568_912, 568_912])
        #expect(account.balance == BigUInt(99_999_000))
        #expect(account.ownerCount == 0)
        #expect(account.flags == 131_072)
        // As duas leituras de account_info pediram o mesmo ledger, por numero.
        let ledgers = transport.requests.compactMap { request -> String? in
            let body = request.body.flatMap { try? StrictJSON.parse($0) }
            guard FixtureTransport.method(body) == "account_info" else { return nil }
            return (try? FixtureTransport.params(body).first?.field("ledger_index", "p")).map { StrictJSON.serialize($0) }
        }
        #expect(ledgers == [String(Self.ledger), String(Self.ledger)])
        #expect(transport.requests.allSatisfy { $0.method == .post && !$0.url.absoluteString.contains(Self.owner) })

        let ledger = try await reader.ledgerState()
        let destination = try await reader.destinationState(address: Self.exchange, source: Self.owner)
        let signer = try XRPLSigner(path: DerivationPath("m/44'/144'/0'/0/0")!, publicKey: XRPLReaderLiveTests.ownerKey)
        let plan = try XRPLPlanner.planSend(
            XRPLSendIntent(destination: Self.exchange, destinationTag: 7, drops: 1_000, acknowledgesDisallowXRP: true),
            signer: signer, account: account, ledger: ledger, destination: destination, walletID: UUID()
        )
        #expect(plan.transactions.count == 1)
    }

    @Test("Sequence diferente nos dois servidores vai ao plano, que recusa")
    func sequenceMismatch() async throws {
        var data = try ReaderFixtures.json("xrpl", "account_info-dono-rippled")
        guard case .object(var root) = data, case .object(var result)? = root["result"], case .object(var fields)? = result["account_data"] else { return }
        fields["Sequence"] = .int(568_913)
        result["account_data"] = .object(fields)
        root["result"] = .object(result)
        data = .object(root)
        let transport = try Self.transport(accounts: [Self.owner: "account_info-dono-rippled"], perHost: ["clio.test": ["account_info": data.serialized]])
        let account = try await Self.reader(transport).accountState(address: Self.owner)
        #expect(Set(account.sequenceReadings) == [568_912, 568_913])
        let signer = try XRPLSigner(path: DerivationPath("m/44'/144'/0'/0/0")!, publicKey: XRPLReaderLiveTests.ownerKey)
        let ledger = try await Self.reader(transport).ledgerState()
        let destination = XRPLDestinationState(address: Self.exchange, readings: [.found(flags: 0), .found(flags: 0)])
        #expect(throws: XRPLPlanError.sequenceMismatch(account.sequenceReadings)) {
            _ = try XRPLPlanner.planSend(XRPLSendIntent(destination: Self.exchange, destinationTag: 1, drops: 1), signer: signer, account: account, ledger: ledger, destination: destination, walletID: UUID())
        }
    }

    @Test("Resposta de outra conta e recusada")
    func accountMismatch() async throws {
        let transport = try Self.transport(accounts: [Self.owner: "account_info-destino-tag"])
        await #expect(throws: ReaderError.self) { _ = try await Self.reader(transport).accountState(address: Self.owner) }
    }

    @Test("Destino inexistente: `actNotFound` do rippled (com ledger) e do Clio (sem ledger)")
    func unfundedDestination() async throws {
        let clio = try ReaderFixtures.data("xrpl", "account_info-inexistente-clio")
        let transport = try Self.transport(accounts: [Self.unfunded: "account_info-inexistente-rippled"], perHost: ["clio.test": ["account_info": clio]])
        let destination = try await Self.reader(transport).destinationState(address: Self.unfunded, source: Self.owner)
        #expect(destination.readings == [.notFound, .notFound])
        #expect(destination.depositPreauthorized == false)
    }

    @Test("Destino com DepositAuth: deposit_authorized perguntado a dois servidores")
    func depositAuth() async throws {
        var data = try ReaderFixtures.json("xrpl", "account_info-destino-tag")
        guard case .object(var root) = data, case .object(var result)? = root["result"], case .object(var account)? = result["account_data"] else { return }
        account["Flags"] = .int(XRPLAccountFlags.depositAuth)
        result["account_data"] = .object(account)
        root["result"] = .object(result)
        data = .object(root)
        let transport = try Self.transport(perHost: ["rippled.test": ["account_info": data.serialized], "clio.test": ["account_info": data.serialized]])
        let destination = try await Self.reader(transport).destinationState(address: Self.exchange, source: Self.owner)
        #expect(destination.depositPreauthorized)
        let asked = transport.requests.filter { FixtureTransport.method($0.body.flatMap { try? StrictJSON.parse($0) }) == "deposit_authorized" }
        #expect(asked.count == 2)
    }

    @Test("submit: aceito, recusado pelo motor, hash trocado")
    func submit() throws {
        let id = String(repeating: "AB", count: 32)
        func result(_ engine: String, hash: String = id) -> StrictJSON {
            .object(["engine_result": .string(engine), "tx_json": .object(["hash": .string(hash)])])
        }
        #expect(try XRPLReader.parseSubmit(result("tesSUCCESS"), expectedID: id) == "tesSUCCESS")
        #expect(try XRPLReader.parseSubmit(result("terQUEUED"), expectedID: id) == "terQUEUED")
        #expect(throws: ReaderError.broadcastRejected(.nonceTooLow, code: "tefPAST_SEQ")) { _ = try XRPLReader.parseSubmit(result("tefPAST_SEQ"), expectedID: id) }
        #expect(throws: ReaderError.broadcastRejected(.expired, code: "tefMAX_LEDGER")) { _ = try XRPLReader.parseSubmit(result("tefMAX_LEDGER"), expectedID: id) }
        #expect(throws: ReaderError.broadcastRejected(.underpriced, code: "telINSUF_FEE_P")) { _ = try XRPLReader.parseSubmit(result("telINSUF_FEE_P"), expectedID: id) }
        #expect(throws: ReaderError.broadcastMismatch) { _ = try XRPLReader.parseSubmit(result("tesSUCCESS", hash: String(repeating: "CD", count: 32)), expectedID: id) }
        let recorded = try ReaderFixtures.json("xrpl", "submit-invalido").field("result", "$")
        #expect(throws: ReaderError.providerError(code: "invalidTransaction")) { _ = try XRPLReader.checked(recorded, "submit") }
    }

    @Test("Transmissao confere o id local antes de mandar")
    func broadcastIntegrity() async throws {
        let blob: [UInt8] = [0x12, 0x00, 0x00]
        let id = Hex.encode(Hash.sha512Half([0x54, 0x58, 0x4E, 0x00] + blob)).uppercased()
        let accepted = Data("{\"result\":{\"engine_result\":\"tesSUCCESS\",\"tx_json\":{\"hash\":\"\(id)\"},\"status\":\"success\"}}".utf8)
        let transport = FixtureTransport([{ _, body in FixtureTransport.method(body) == "submit" ? accepted : nil }])
        let reader = Self.reader(transport)
        let signed = SignedTransaction(chainID: "xrpl", raw: blob, encoded: Hex.encode(blob).uppercased(), id: id)
        let receipt = try await reader.broadcast(signed)
        #expect(receipt.provisionalResult == "tesSUCCESS")
        #expect(receipt.acceptedBy == ["rippled"])
        let wrong = SignedTransaction(chainID: "xrpl", raw: blob, encoded: Hex.encode(blob), id: String(repeating: "00", count: 32))
        await #expect(throws: ReaderError.broadcastMismatch) { _ = try await reader.broadcast(wrong) }
    }

    @Test("tx gravado: validado nos dois servidores; nao achado; vencido")
    func txStatus() async throws {
        let confirmed = try await Self.reader(try Self.transport()).status(of: "AA422A0AF62C58042BE3A243954CC1BD2560E2345F475E577F8E21F4D455BEA5")
        #expect(confirmed == .confirmed(block: 106_836_736, confirmations: nil))
        let missing = try ReaderFixtures.json("xrpl", "tx-nao-achado").field("result", "$")
        #expect(try XRPLReader.parseTxStatus(missing) == .notFound)
        guard case .object(var fields) = missing else { return }
        fields["searched_all"] = .bool(true)
        #expect(try XRPLReader.parseTxStatus(.object(fields)) == .failed(reason: "expired"))
        let notFound = try Self.transport(perHost: ["clio.test": ["tx": try ReaderFixtures.data("xrpl", "tx-nao-achado")]])
        #expect(try await Self.reader(notFound).status(of: "AA422A0AF62C58042BE3A243954CC1BD2560E2345F475E577F8E21F4D455BEA5") == .pending)
    }

    @Test("account_tx gravado: 1 drop de golpe escondido, 1 XRP recebido aparece")
    func history() throws {
        let result = try ReaderFixtures.json("xrpl", "account_tx-exchange").field("result", "$")
        let page = try XRPLReader.parseHistory(result, owner: Self.exchange)
        #expect(page.items.count == 1)
        let item = try #require(page.items.first)
        #expect(item.direction == .received)
        #expect(item.amount == BigUInt(1_000_000))
        #expect(item.counterparty == "r4mRnUYGbq3mYVrT1XFU1ohEZt6s82S1fx")
        #expect(item.fee == nil)
        #expect(item.isPartialPayment == false)
        #expect(page.suspicious.dust == 8)
        #expect(item.explorerURL?.host == "xrpscan.com")
    }

    /// Pagamento parcial montado a partir de um item gravado: `DeliverMax` de 1.000 XRP e
    /// `delivered_amount` de 5 XRP, com tfPartialPayment. A tela mostra 5 e marca.
    @Test("Pagamento parcial: valor sempre pelo delivered_amount, e marcado")
    func partialPayment() throws {
        let result = try ReaderFixtures.json("xrpl", "account_tx-exchange").field("result", "$")
        var root = try result.object("r")
        var entries = try root["transactions"]!.array("t")
        var entry = try entries[5].object("e")
        var tx = try entry["tx_json"]!.object("tx")
        var meta = try entry["meta"]!.object("m")
        tx["DeliverMax"] = .string("1000000000")
        tx["Flags"] = .int(XRPLTransactionFlags.partialPayment)
        meta["delivered_amount"] = .string("5000000")
        entry["tx_json"] = .object(tx)
        entry["meta"] = .object(meta)
        entries = [.object(entry)]
        root["transactions"] = .array(entries)
        let page = try XRPLReader.parseHistory(.object(root), owner: Self.exchange)
        let item = try #require(page.items.first)
        #expect(item.amount == BigUInt(5_000_000))
        #expect(item.isPartialPayment)
    }
}
