import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// As respostas gravadas da Aptos, as mesmas dos testes do leitor
/// (EscaliburNetworkTests/Fixtures/leitores/aptos, `gravar.py`), lidas do repositorio. O
/// relogio do motor fica na hora do ledger gravado: as transacoes que ele monta sao, byte a
/// byte, as que foram simuladas na gravacao.
enum AptosRecorded {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("EscaliburNetworkTests/Fixtures/leitores/aptos")

    struct Recording: Decodable {
        let dono: String, chave: String, existente: String, nova: String
        let valor: UInt64, versao: UInt64, hora: UInt64, preco: UInt64, sequencia: UInt64, saldo: UInt64
        let transacao: String
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(name)) }
    static let recording = try! JSONDecoder().decode(Recording.self, from: data("gravacao.json"))
    static let ownerKey = [UInt8](hex: recording.chave)!
    static let now = Date(timeIntervalSince1970: TimeInterval(recording.hora))

    static func account(address: String = recording.dono, key: [UInt8] = ownerKey) -> DerivedAccount {
        DerivedAccount(chainID: "aptos", path: DerivationPath("m/44'/637'/0'/0'/0'")!, address: address, publicKey: key, accountXPub: nil)
    }

    static func request(amount: BigUInt = BigUInt(recording.valor), to destination: String = recording.existente, sendAll: Bool = false,
                        asset: Asset = .native(.aptos), account: DerivedAccount = account(), known: [String] = []) -> SendRequest {
        SendRequest(
            walletID: UUID(), chain: .aptos, asset: asset, account: account, destination: destination, tag: nil,
            amount: amount, sendAll: sendAll, feeLevel: .normal, utxoUsage: nil, knownAddresses: known
        )
    }

    /// Responde pelo caminho e pelo corpo; simulacao so para os bytes gravados (400 para
    /// qualquer outro). O terceiro provedor responde como a Sentio.
    final class Transport: ReaderTransport, @unchecked Sendable {
        typealias Override = @Sendable (_ provider: String, _ path: String, _ body: Data) throws -> Data?
        private let override: Override?
        private let simulations: [(bytes: [UInt8], name: String)]
        private let lock = NSLock()
        private var log: [String] = []

        init(override: Override? = nil) throws {
            self.override = override
            simulations = try ["estimativa-existente", "envio-existente", "estimativa-nova", "envio-nova"].map { name in
                let text = String(decoding: try AptosRecorded.data("simulacao-\(name).bcs.hex"), as: UTF8.self)
                return ([UInt8](hex: text)!, name)
            }
        }

        var paths: [String] { lock.withLock { log } }

        func send(_ request: ReaderRequest) async throws -> Data {
            let host = request.url.host ?? ""
            let provider = host.hasPrefix("publicnode") ? "publicnode" : "sentio"
            let path = request.url.path
            let body = request.body ?? Data()
            lock.withLock { log.append(path) }
            if let override, let data = try override(host.components(separatedBy: ".")[0], path, body) { return data }
            if path.hasSuffix("/graphql") { return try AptosRecorded.data("graphql-historico-dono.json") }
            if path.hasSuffix("/v1") { return try AptosRecorded.data("indice-\(provider).json") }
            if path.hasSuffix("/estimate_gas_price") { return try AptosRecorded.data("preco-gas.json") }
            if path.hasSuffix("/view") { return try AptosRecorded.data("view-\(try Self.viewName(body)).json") }
            if path.hasSuffix("/transactions/simulate") {
                guard let entry = simulations.first(where: { $0.bytes == [UInt8](body) }) else { throw HTTPClient.Failure.status(400) }
                return try AptosRecorded.data("simulacao-\(entry.name)-\(provider).json")
            }
            if path.contains("/transactions/by_hash/"), path.hasSuffix(AptosRecorded.recording.transacao) {
                return try AptosRecorded.data("transacao-\(provider).json")
            }
            throw HTTPClient.Failure.status(404)
        }

        static func viewName(_ body: Data) throws -> String {
            let text = String(decoding: body, as: UTF8.self)
            if text.contains("get_sequence_number") { return "sequencia-dono" }
            if text.contains("get_authentication_key") { return "chave-dono" }
            if text.contains("0x1::coin::balance") { return "saldo-dono" }
            if text.contains("primary_store_exists") {
                return text.contains(AptosRecorded.recording.existente) ? "loja-existente" : "loja-nova"
            }
            throw HTTPClient.Failure.status(400)
        }
    }

    static func engine(_ transport: Transport, deadlines: AptosSendEngine.Deadlines = .init(), now: Date = now) -> AptosSendEngine {
        let providers = ["publicnode", "sentio", "aptoslabs"].map { ProviderPool.Provider(name: $0, baseURL: URL(string: "https://\($0).test/v1")!) }
        let reader = AptosReader(transport: transport, providers: providers, indexer: URL(string: "https://indexer.test/v1/graphql"), pacing: 0)
        return AptosSendEngine(reader: reader, deadlines: deadlines, now: { now })
    }

    /// Uma transferencia da rede principal assinada aqui com a chave do vetor do wallet-core.
    static func signed() throws -> SignedTransaction {
        let seed = SecureBytes(capacity: 32)
        defer { seed.wipe() }
        seed.replaceAll(with: [UInt8](hex: "5d996aa76b3212142792d9130796cd2e11e3c445a93118c08414df4f66bc60ec")!)
        let key = try Ed25519.publicKey(of: seed)
        guard case .success(let recipient) = AptosAddress.parse(recording.existente) else { throw SendEngineError.message("destino") }
        let raw = AptosRawTransaction(
            sender: try AptosAddress(ed25519PublicKey: key), sequenceNumber: 3, recipient: recipient, amount: 1_000,
            maxGasAmount: 200, gasUnitPrice: 100, expirationTimestampSecs: recording.hora + 120, chainID: 1
        )
        let bytes = raw.bcs() + [0, 32] + key + [64] + (try Ed25519.sign(raw.signingMessage, seed: seed))
        return SignedTransaction(chainID: "aptos", raw: bytes, encoded: Hex.encode(bytes), id: AptosSignedTransaction.hash(of: bytes))
    }
}

@Suite("Motor de envio Aptos com respostas gravadas")
struct AptosSendEngineTests {
    typealias R = AptosRecorded

    @Test("Destino: conta com APT, conta nova (o envio cria), sistema e outra rede")
    func destination() async throws {
        let engine = R.engine(try R.Transport())
        let existing = try await engine.destination(R.recording.existente, chain: .aptos)
        #expect(existing.exists && existing.note == nil && !existing.requiresTag)
        let fresh = try await engine.destination(R.recording.nova, chain: .aptos)
        #expect(!fresh.exists && fresh.note == AptosEngineText.newAccountNote)
        await #expect(throws: SendEngineError.message(AptosEngineText.systemAddress)) { _ = try await engine.destination("0x1", chain: .aptos) }
        await #expect(throws: SendEngineError.message(AptosEngineText.address(.otherNetwork(.ethereum)))) {
            _ = try await engine.destination("0x52908400098527886E0F7030069857D2E4169EE7", chain: .aptos)
        }
        await #expect(throws: SendEngineError.unsupported(.sui)) { _ = try await engine.destination(R.recording.existente, chain: .sui) }
    }

    @Test("Maximo: saldo menos a taxa maxima do gas simulado nos dois provedores")
    func spendable() async throws {
        let engine = R.engine(try R.Transport())
        let existing = try await engine.spendable(R.request(sendAll: true))
        #expect(existing.amount == BigUInt(R.recording.saldo - 200 * R.recording.preco))
        #expect(existing.feeNote == "Taxa máxima da rede: 0,0002 APT. A rede cobra só o gas usado.")
        let fresh = try await engine.spendable(R.request(to: R.recording.nova, sendAll: true))
        #expect(fresh.amount == BigUInt(R.recording.saldo - 6_498 * R.recording.preco))
        #expect(fresh.feeNote?.hasSuffix("Este envio também cria a conta de destino.") == true)
    }

    @Test("Plano para conta com APT: os bytes gravados, simulados de novo e conferidos")
    func planExisting() async throws {
        let transport = try R.Transport()
        let request = R.request()
        let plan = try await R.engine(transport).plan(request)
        let transfer = try #require(plan.transactions.first as? AptosTransfer)
        let recorded = String(decoding: try R.data("simulacao-envio-existente.bcs.hex"), as: UTF8.self)
        #expect(Hex.encode(AptosSignedTransaction.simulationBytes(transfer.raw, publicKey: R.ownerKey)) == recorded)
        #expect(plan.review.recipient == R.recording.existente && plan.review.warnings.contains(.firstSendToAddress))
        try PlanIntentCheck.send(plan.review, asset: .native(.aptos), amount: BigUInt(R.recording.valor), ceiling: 0, chain: .aptos)
        // Duas simulacoes da estimativa e duas da transacao exata.
        #expect(transport.paths.filter { $0.hasSuffix("/simulate") }.count == 4)
    }

    @Test("Plano para conta nova: a revisao diz que o envio cria a conta")
    func planFresh() async throws {
        let plan = try await R.engine(try R.Transport()).plan(R.request(to: R.recording.nova, known: [R.recording.nova]))
        let transfer = try #require(plan.transactions.first as? AptosTransfer)
        #expect(transfer.raw.maxGasAmount == 6_498)
        #expect(plan.review.lines.contains { $0.label == "Conta de destino" })
        #expect(!plan.review.warnings.contains(.firstSendToAddress))
    }

    @Test("Recusas: simulacao que move outra coisa, simulacao que falha, ativo, conta e relogio")
    func refusals() async throws {
        // A Sentio devolve, para o envio, a simulacao do envio para a conta nova.
        let swapped = try R.Transport { provider, path, body in
            guard provider == "sentio", path.hasSuffix("/simulate"),
                  Hex.encode([UInt8](body)) == String(decoding: try R.data("simulacao-envio-existente.bcs.hex"), as: UTF8.self)
            else { return nil }
            return try R.data("simulacao-envio-nova-sentio.json")
        }
        await #expect(throws: SendEngineError.message("A simulação da rede não moveu exatamente o valor revisado. Nada foi assinado.")) {
            _ = try await R.engine(swapped).plan(R.request())
        }
        let failing = try R.Transport { _, path, _ in
            path.hasSuffix("/simulate") ? Data(#"[{"success":false,"gas_used":"0","hash":"0x00","events":[]}]"#.utf8) : nil
        }
        await #expect(throws: SendEngineError.message(AptosEngineText.simulationFailed)) { _ = try await R.engine(failing).plan(R.request()) }

        let engine = R.engine(try R.Transport())
        await #expect(throws: SendEngineError.message(AptosEngineText.unsupportedAsset)) {
            _ = try await engine.plan(R.request(asset: .native(.sui)))
        }
        await #expect(throws: SendEngineError.message(AptosEngineText.keyMismatch)) {
            _ = try await engine.plan(R.request(account: R.account(address: R.recording.existente)))
        }
        await #expect(throws: SendEngineError.message(AptosEngineText.planner(.clockSkew))) {
            _ = try await R.engine(try R.Transport(), now: R.now.addingTimeInterval(600)).plan(R.request())
        }
        await #expect(throws: SendEngineError.message(AptosEngineText.planner(.destinationIsSelf))) {
            _ = try await engine.plan(R.request(to: R.recording.dono))
        }
    }

    @Test("Transmissao, prazo e acompanhamento")
    func broadcastAndStatus() async throws {
        let signed = try R.signed()
        let transport = try R.Transport { _, path, _ in
            path.hasSuffix("/transactions") ? Data(#"{"hash":"\#(signed.id)"}"#.utf8) : nil
        }
        let deadlines = AptosSendEngine.Deadlines()
        let engine = R.engine(transport, deadlines: deadlines)
        #expect(try await engine.broadcast([signed], chain: .aptos) == signed.id)
        #expect(await deadlines.expiresAt(signed.id) == R.recording.hora + 120)

        var tampered = signed.raw
        tampered[45] ^= 1
        let bad = SignedTransaction(chainID: "aptos", raw: tampered, encoded: Hex.encode(tampered), id: signed.id)
        await #expect(throws: SendEngineError.message(AptosEngineText.notOurTransaction)) { _ = try await engine.broadcast([bad], chain: .aptos) }

        #expect(await engine.status(R.recording.transacao, chain: .aptos) == .confirmed(detail: "Incluída na versão 7.391.617.458 do ledger, que já é final."))
        // Nao achada nos dois e com o prazo ja passado na hora do ledger: venceu.
        let old = "0x" + String(repeating: "cd", count: 32)
        await deadlines.record(old, expiresAt: R.recording.hora - 60)
        #expect(await engine.status(old, chain: .aptos) == .failed(reason: AptosEngineText.failure("expired")))
        #expect(await engine.status("0x" + String(repeating: "ef", count: 32), chain: .aptos) == .pending)
    }

    @Test("Atividade: envios da conta gravada, e o registro dos motores")
    func activityAndRegistry() async throws {
        let transport = try R.Transport()
        let providers = ["publicnode", "sentio", "aptoslabs"].map { ProviderPool.Provider(name: $0, baseURL: URL(string: "https://\($0).test/v1")!) }
        let reader = AptosReader(transport: transport, providers: providers, indexer: URL(string: "https://indexer.test/v1/graphql"), pacing: 0)
        let entries = try await AptosActivitySource(reader: reader).history(chain: .aptos, account: R.account(), usage: nil)
        #expect(entries.count == 30 && entries.allSatisfy { $0.direction == .sent && !$0.suspicious && $0.chainID == "aptos" })

        #expect(SendEngines.engine(for: .aptos) is AptosSendEngine)
        #expect(ActivitySources.source(for: .aptos) is AptosActivitySource)
        #expect(TradeEngines.engine(for: .aptos) == nil)
    }

    @Test("Recebimento de endereco sosia de um destino ja pago e marcado")
    func lookalikeReceipt() {
        guard case .success(let owner) = AptosAddress.parse(R.recording.dono) else { return }
        let paid = R.recording.existente
        let lookalike = String(paid.prefix(6)) + String(repeating: "0", count: 56) + String(paid.suffix(4))
        let date = Date(timeIntervalSince1970: 1_790_570_000)
        let items = [
            ActivityItem(id: "aptos:2", chainID: "aptos", direction: .sent, asset: .native(.aptos), amount: 5_000_000, counterparty: paid,
                         date: date, status: .confirmed, fee: 6_300, hash: "2", explorerURL: nil),
            ActivityItem(id: "aptos:1", chainID: "aptos", direction: .received, asset: .native(.aptos), amount: 20_000, counterparty: lookalike,
                         date: date, status: .confirmed, fee: nil, hash: "1", explorerURL: nil),
        ]
        let entries = AptosActivitySource.entries(items, owner: owner)
        #expect(entries.map(\.suspicious) == [false, true])
    }
}
