import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// As respostas gravadas da Sui, as mesmas dos testes do leitor
/// (EscaliburNetworkTests/Fixtures/leitores/sui, `gravar.py`), lidas do repositorio.
enum SuiRecorded {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("EscaliburNetworkTests/Fixtures/leitores/sui")

    /// Binance 1 e a chave publica dela, lida de uma assinatura na rede.
    static let owner = "0x935029ca5219502a47ac9b69f556ccf6e2198b5e7815cf50f68846f723739cbd"
    static let ownerKey = [UInt8](hex: "155d476da6f2f979141b56872dcf06cbbb956b471348ca1e0917ef6f313d3839")!
    /// OKX 1.
    static let destination = "0xab73ad38c63f83eda02182422b545395be1d3caeb54b5869159a9f70b678cd56"

    static func data(_ name: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(name)) }

    static func account(address: String = owner, key: [UInt8] = ownerKey) -> DerivedAccount {
        DerivedAccount(chainID: "sui", path: DerivationPath("m/44'/784'/0'/0'/0'")!, address: address, publicKey: key, accountXPub: nil)
    }

    static func request(amount: BigUInt = 1_000_000_000, to destination: String = destination, sendAll: Bool = false,
                        asset: Asset = .native(.sui), account: DerivedAccount = account(), known: [String] = []) -> SendRequest {
        SendRequest(
            walletID: UUID(), chain: .sui, asset: asset, account: account, destination: destination, tag: nil,
            amount: amount, sendAll: sendAll, feeLevel: .normal, utxoUsage: nil, knownAddresses: known
        )
    }

    static func frame(_ message: [UInt8]) -> Data { Data([0] + UInt32(message.count).bigEndianByteArray + message) }

    /// Responde pelo metodo gRPC do caminho; simulacao so para as transacoes gravadas
    /// (corpo vazio, que o leitor le como erro, para qualquer outra).
    final class Transport: ReaderTransport, @unchecked Sendable {
        typealias Override = @Sendable (_ method: String) throws -> Data?
        private let override: Override?
        private let recorded: [String: Data]
        private let simulations: [([UInt8], Data)]
        private let lock = NSLock()
        private var log: [String] = []

        init(override: Override? = nil) throws {
            self.override = override
            recorded = [
                "GetServiceInfo": try SuiRecorded.data("GetServiceInfo.bin"),
                "GetEpoch": try SuiRecorded.data("GetEpoch.bin"),
                "GetBalance": try SuiRecorded.data("GetBalance-dono.bin"),
                "ListOwnedObjects": try SuiRecorded.data("ListOwnedObjects-dono.bin"),
                "BatchGetTransactions": try SuiRecorded.data("BatchGetTransactions-achada.bin"),
                "ListTransactions": try SuiRecorded.data("ListTransactions-dono.bin"),
                "graphql": try SuiRecorded.data("graphql-historico-dono.json"),
            ]
            simulations = try ["SimulateTransaction-estimativa", "SimulateTransaction-envio"].map {
                ([UInt8](try SuiRecorded.data($0 + "-tx.bin")), try SuiRecorded.data($0 + ".bin"))
            }
        }

        var methods: [String] { lock.withLock { log } }

        func send(_ request: ReaderRequest) async throws -> Data {
            let method = request.url.lastPathComponent
            lock.withLock { log.append(method) }
            if let override, let data = try override(method) { return data }
            if method == "SimulateTransaction" {
                let body = [UInt8](request.body ?? Data())
                return simulations.first { tx, _ in Self.contains(body, tx) }?.1 ?? Data()
            }
            guard let data = recorded[method] else { throw HTTPClient.Failure.status(404) }
            return data
        }

        static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
            guard !needle.isEmpty, needle.count <= haystack.count else { return false }
            for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
                if Array(haystack[start..<(start + needle.count)]) == needle { return true }
            }
            return false
        }
    }

    static func engine(_ transport: Transport, deadlines: SuiSendEngine.Deadlines = .init()) -> SuiSendEngine {
        let providers = ["suifoundation", "suiscan", "nodeinfra"].map { ProviderPool.Provider(name: $0, baseURL: URL(string: "https://\($0).test")!) }
        let reader = SuiReader(transport: transport, providers: providers, graphQL: URL(string: "https://graphql.test/graphql"), pacing: 0)
        return SuiSendEngine(reader: reader, deadlines: deadlines)
    }
}

@Suite("Motor de envio da Sui")
struct SuiSendEngineTests {
    /// Custo da simulacao gravada: 100.000 de computacao e 1.976.000 de armazenamento.
    static let budget: UInt64 = 2_491_200

    @Test("Plano com a rede gravada: a transacao montada e a mesma que o no simulou, e a simulacao confere")
    func planAgainstRecordedNetwork() async throws {
        let transport = try SuiRecorded.Transport()
        let request = SuiRecorded.request()
        let plan = try await SuiRecorded.engine(transport).plan(request)
        let transfer = try #require(plan.transactions.first as? SuiTransfer)
        #expect(transfer.data.gas.budget == Self.budget)
        #expect(transfer.data.gas.payment.count == 207)
        #expect(transfer.transactionBytes == [UInt8](try SuiRecorded.data("SimulateTransaction-envio-tx.bin")))
        #expect(plan.review.recipient == SuiRecorded.destination)
        #expect(plan.review.outgoing == PlanReview.Movement(assetID: "sui:native", amount: 1_000_000_000))
        #expect(plan.review.warnings.contains(.firstSendToAddress))
        try PlanIntentCheck.send(plan.review, asset: .native(.sui), amount: 1_000_000_000, ceiling: 1_000_000_000_000, chain: .sui)
        // Duas simulacoes de estimativa e duas da transacao exata.
        #expect(transport.methods.filter { $0 == "SimulateTransaction" }.count == 4)
    }

    @Test("Maximo: as moedas menos o orcamento, com a taxa maxima na nota")
    func spendable() async throws {
        let spendable = try await SuiRecorded.engine(try SuiRecorded.Transport()).spendable(SuiRecorded.request())
        #expect(spendable.feeNote == "Taxa máxima da rede: 0,0024912 SUI. O que não for usado volta para a conta.")
        #expect(spendable.reserveNote == nil)
        #expect(spendable.amount > BigUInt(1_000_000_000_000))
    }

    @Test("A simulacao da transacao exata falhando num provedor impede o plano")
    func finalSimulationRequired() async throws {
        // A estimativa (1 MIST) e a gravada; a transacao exata de 2 SUI nao: o no volta sem
        // dado, e sem as duas simulacoes nao ha plano.
        let transport = try SuiRecorded.Transport()
        await #expect(throws: SendEngineError.message(SuiEngineText.simulationUnavailable)) {
            try await SuiRecorded.engine(transport).plan(SuiRecorded.request(amount: 2_000_000_000))
        }
    }

    @Test("Recusas antes de ler a rede: ativo, chave, destino")
    func refusals() async throws {
        let engine = SuiRecorded.engine(try SuiRecorded.Transport())
        // Um token de outra rede, ou qualquer coisa que nao seja SUI nativo.
        let token = try #require(TokenRegistry.tokens.first)
        await #expect(throws: SendEngineError.message(SuiEngineText.unsupportedAsset)) { try await engine.plan(SuiRecorded.request(asset: token)) }
        let wrong = SuiRecorded.account(address: SuiRecorded.destination)
        await #expect(throws: SendEngineError.message(SuiEngineText.keyMismatch)) { try await engine.plan(SuiRecorded.request(account: wrong)) }
        await #expect(throws: SendEngineError.message(SuiEngineText.address(.otherNetwork(.ethereum)))) {
            try await engine.plan(SuiRecorded.request(to: "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"))
        }
        await #expect(throws: SendEngineError.message(SuiEngineText.systemAddress)) {
            _ = try await engine.destination("0x" + String(repeating: "0", count: 63) + "5", chain: .sui)
        }
        await #expect(throws: SendEngineError.message("O destino é a própria conta.")) {
            try await engine.plan(SuiRecorded.request(to: SuiRecorded.owner))
        }
        let info = try await engine.destination(SuiRecorded.destination, chain: .sui)
        #expect(info.exists && !info.requiresTag)
    }

    @Test("Transmissao e acompanhamento: id calculado, vencimento pela epoca")
    func broadcastAndStatus() async throws {
        let tx = "AAACAAgQJwAAAAAAAAAgJZ/4B0q0Jcu0ifI24Y4I8D8aeFa998eih3vWT3OLUBUCAgABAQAAAQEDAAAAAAEBANV1rX8Y6UhGKlz2mPVk7zlKdSpx/sYkk6+KBVwBLA1QAQbywsjB2JZN8QGdZhbpcFcZvrq9kx2idVy5SM635olk7AIAAAAAAAAgYEVuxmf1zRBGdoDr+VDtMpIFF12s2Ua7I2ru1XyGF8/Vda1/GOlIRipc9pj1ZO85SnUqcf7GJJOvigVcASwNUAEAAAAAAAAA0AcAAAAAAAAA"
        let sig = "APxPduNVvHj2CcRcHOtiP2aBR9qP3vO2Cb0g12PI64QofDB6ks33oqe/i/iCTLcop2rBrkczwrayZuJOdi7gvwNqfN7sFqdcD/Z4e8I1YQlGkDMCK7EOgmydRDqfH8C9jg=="
        let digest = "HkPo6rYPyDY53x1MBszvSZVZyixVN7CHvCJGX381czAh"
        let signed = SignedTransaction(
            chainID: "sui", raw: [UInt8](Data(base64Encoded: tx)!) + [UInt8](Data(base64Encoded: sig)!), encoded: tx + "." + sig, id: digest
        )
        // ExecuteTransactionResponse com o digesto nos efeitos e sucesso.
        var status = [UInt8]([0x08, 0x01])
        status = [0x22, UInt8(status.count)] + status
        let effects = status + [0x3A, UInt8(digest.utf8.count)] + Array(digest.utf8)
        let executed = [0x22, UInt8(effects.count)] + effects
        let response = SuiRecorded.frame([0x0A, UInt8(executed.count)] + executed)
        let missing = try SuiRecorded.data("BatchGetTransactions-nao-achada.bin")
        let transport = try SuiRecorded.Transport { method in
            switch method {
            case "ExecuteTransaction": return response
            case "BatchGetTransactions": return missing
            default: return nil
            }
        }
        let deadlines = SuiSendEngine.Deadlines()
        let engine = SuiRecorded.engine(transport, deadlines: deadlines)
        #expect(try await engine.broadcast([signed], chain: .sui) == digest)
        // Sem validade por epoca, "nao achada" fica pendente.
        #expect(await engine.status(digest, chain: .sui) == .pending)
        // Com validade ate a epoca 1.263 e a rede na 1.264: venceu.
        await deadlines.record(digest, validUntilEpoch: 1_263)
        #expect(await engine.status(digest, chain: .sui) == .failed(reason: SuiEngineText.failure("expired")))

        var forged = signed.raw
        forged[30] ^= 1
        await #expect(throws: SendEngineError.message(SuiEngineText.notOurTransaction)) {
            try await engine.broadcast([SignedTransaction(chainID: "sui", raw: forged, encoded: signed.encoded, id: digest)], chain: .sui)
        }
    }

    @Test("Confirmada: checkpoint nos dois provedores")
    func confirmed() async throws {
        let digest = String(decoding: try SuiRecorded.data("digesto-achado.txt"), as: UTF8.self)
        let status = await SuiRecorded.engine(try SuiRecorded.Transport()).status(digest, chain: .sui)
        guard case .confirmed(let detail?) = status else { Issue.record("esperava confirmada: \(status)"); return }
        #expect(detail.hasPrefix("Incluída no checkpoint "))
    }

    @Test("Atividade: historico gravado e recebimento de endereco sosia marcado")
    func activity() async throws {
        let entries = try await SuiActivitySource(reader: SuiReader(
            transport: try SuiRecorded.Transport(),
            providers: [ProviderPool.Provider(name: "suifoundation", baseURL: URL(string: "https://suifoundation.test")!)],
            graphQL: URL(string: "https://graphql.test/graphql"), pacing: 0
        )).history(chain: .sui, account: SuiRecorded.account(), usage: nil)
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.chainID == "sui" && !$0.suspicious })

        // Recebimento de um endereco com o mesmo comeco e fim de um destino ja pago.
        let paid = "0xbeb1c170" + String(repeating: "1", count: 48) + "22223333"
        let lookalike = "0xbeb1c170" + String(repeating: "9", count: 48) + "22223333"
        let items = [
            ActivityItem(id: "a", chainID: "sui", direction: .sent, asset: .native(.sui), amount: 5, counterparty: paid,
                         date: .now, status: .confirmed, fee: nil, hash: "a", explorerURL: nil),
            ActivityItem(id: "b", chainID: "sui", direction: .received, asset: .native(.sui), amount: 7, counterparty: lookalike,
                         date: .now, status: .confirmed, fee: nil, hash: "b", explorerURL: nil),
        ]
        guard case .success(let owner) = SuiAddress.parse(SuiRecorded.owner) else { return }
        let judged = SuiActivitySource.entries(items, owner: owner)
        #expect(judged.first { $0.id == "b" }?.suspicious == true)
        #expect(judged.first { $0.id == "a" }?.suspicious == false)
    }
}
