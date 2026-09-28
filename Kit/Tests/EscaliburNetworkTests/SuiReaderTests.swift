import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Respostas da Sui gravadas em 27/09/2026 (Fixtures/leitores/sui, `gravar.py`): o
/// gRPC-Web do no da Sui Foundation, cru, e o GraphQL. Conta: Binance 1, rotulo publico de
/// exchange; chave publica tirada da assinatura de uma transacao dela na rede.
enum SuiRecorded {
    static let owner = address("0x935029ca5219502a47ac9b69f556ccf6e2198b5e7815cf50f68846f723739cbd")
    static let ownerKey = [UInt8](hex: "155d476da6f2f979141b56872dcf06cbbb956b471348ca1e0917ef6f313d3839")!
    /// OKX 1, o destino das simulacoes gravadas.
    static let destination = "0xab73ad38c63f83eda02182422b545395be1d3caeb54b5869159a9f70b678cd56"
    static let amount: UInt64 = 1_000_000_000

    static func address(_ text: String) -> SuiAddress {
        guard case .success(let address) = SuiAddress.parse(text) else { fatalError("endereco de teste invalido") }
        return address
    }

    struct Missing: Error { let name: String }

    static func data(_ name: String, _ ext: String = "bin") throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/leitores/sui") else {
            throw Missing(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func transaction(_ name: String) throws -> SuiTransactionData {
        try SuiTransactionData.decode([UInt8](try data(name + "-tx")))
    }

    /// O metodo gRPC do caminho ("GetEpoch") e a transacao do corpo, quando e simulacao.
    static func method(_ request: ReaderRequest) -> String { request.url.lastPathComponent }

    /// Um quadro gRPC-Web com a mensagem, sem trailers (como a NodeInfra responde).
    static func frame(_ message: [UInt8]) -> Data { Data([0] + UInt32(message.count).bigEndianByteArray + message) }

    /// Responde pelo metodo, com as gravacoes; simulacao so para a transacao gravada.
    /// `override` responde antes e pode lancar.
    final class Transport: ReaderTransport, @unchecked Sendable {
        typealias Override = @Sendable (_ host: String, _ method: String, _ body: Data) throws -> Data?
        private let lock = NSLock()
        private var log: [ReaderRequest] = []
        private let override: Override?
        private let recorded: [String: Data]
        private let simulations: [(tx: [UInt8], response: Data)]

        init(override: Override? = nil) throws {
            self.override = override
            recorded = [
                "GetServiceInfo": try SuiRecorded.data("GetServiceInfo"),
                "GetEpoch": try SuiRecorded.data("GetEpoch"),
                "GetBalance": try SuiRecorded.data("GetBalance-dono"),
                "ListBalances": try SuiRecorded.data("ListBalances-dono"),
                "ListOwnedObjects": try SuiRecorded.data("ListOwnedObjects-dono"),
                "BatchGetTransactions": try SuiRecorded.data("BatchGetTransactions-achada"),
                "ListTransactions": try SuiRecorded.data("ListTransactions-dono"),
                "graphql": try SuiRecorded.data("graphql-historico-dono", "json"),
            ]
            simulations = try ["SimulateTransaction-estimativa", "SimulateTransaction-envio"].map {
                ([UInt8](try SuiRecorded.data($0 + "-tx")), try SuiRecorded.data($0))
            }
        }

        var requests: [ReaderRequest] { lock.withLock { log } }

        func send(_ request: ReaderRequest) async throws -> Data {
            lock.withLock { log.append(request) }
            let body = request.body ?? Data()
            let method = request.url.path.hasSuffix("/graphql") ? "graphql" : SuiRecorded.method(request)
            if let override, let data = try override(request.url.host ?? "", method, body) { return data }
            if method == "SimulateTransaction" {
                let bytes = [UInt8](body)
                return simulations.first { entry in
                    bytes.count > entry.tx.count && Self.contains(bytes, entry.tx)
                }?.response ?? Data()
            }
            guard let data = recorded[method] else { throw HTTPClient.Failure.status(404) }
            return data
        }

        static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
            guard needle.count <= haystack.count else { return false }
            for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
                if Array(haystack[start..<(start + needle.count)]) == needle { return true }
            }
            return false
        }
    }

    static func providers() -> [ProviderPool.Provider] {
        ["suifoundation", "suiscan", "nodeinfra"].map { ProviderPool.Provider(name: $0, baseURL: URL(string: "https://\($0).test")!) }
    }

    static func reader(_ transport: Transport, graphQL: Bool = true) -> SuiReader {
        SuiReader(transport: transport, providers: providers(), graphQL: graphQL ? URL(string: "https://graphql.test/graphql") : nil, pacing: 0)
    }
}

@Suite("Leitor Sui com respostas gravadas")
struct SuiReaderTests {
    @Test("gRPC-Web: quadros, trailers com erro, sem dado e comprimido")
    func framing() throws {
        let message: [UInt8] = [0x08, 0x01]
        let trailerOK = Data([0x80, 0, 0, 0, 15]) + Data("grpc-status:0\r\n".utf8)
        #expect(try SuiGRPC.messages(SuiRecorded.frame(message) + trailerOK, method: "m") == [message])
        let trailerError = Data([0x80, 0, 0, 0, 15]) + Data("grpc-status:5\r\n".utf8)
        #expect(throws: ReaderError.providerError(code: "grpc-5")) { try SuiGRPC.messages(SuiRecorded.frame(message) + trailerError, method: "m") }
        #expect(throws: ReaderError.providerError(code: "grpc")) { try SuiGRPC.messages(Data(), method: "m") }
        #expect(throws: ReaderError.malformed(field: "m.frame")) { try SuiGRPC.messages(Data([1, 0, 0, 0, 1, 0]), method: "m") }
        #expect(throws: ReaderError.malformed(field: "m.frame")) { try SuiGRPC.messages(Data([0, 0, 0, 0, 9, 1]), method: "m") }
    }

    @Test("Estado da conta: moedas, preco e epoca de dois provedores; endereco so no corpo")
    func accountState() async throws {
        let transport = try SuiRecorded.Transport()
        let state = try await SuiRecorded.reader(transport).accountState(owner: SuiRecorded.owner)
        #expect(state.coins.count == 207)
        #expect(state.referenceGasPrice == 100)
        #expect(state.epoch == 1_264)
        #expect(state.coins.allSatisfy { $0.balance > 0 })
        #expect(state.addressBalance == 0)
        // Dois provedores diferentes responderam, e nenhum pedido levou o endereco na URL.
        let hosts = Set(transport.requests.compactMap(\.url.host))
        #expect(hosts.isSuperset(of: ["suifoundation.test", "suiscan.test"]))
        #expect(!transport.requests.contains { $0.url.absoluteString.contains(SuiRecorded.owner.hex.dropFirst(2)) })
        #expect(transport.requests.allSatisfy { $0.headers["Content-Type"] == "application/grpc-web+proto" })
    }

    @Test("Provedores divergindo numa moeda: le de novo e recusa")
    func coinsDisagree() async throws {
        let original = [UInt8](try SuiRecorded.data("ListOwnedObjects-dono"))
        // Muda a versao da primeira moeda no segundo provedor: o campo 3 logo depois do
        // id (campo 2, 66 caracteres) do primeiro objeto.
        let transport = try SuiRecorded.Transport { host, method, _ in
            guard host == "suiscan.test", method == "ListOwnedObjects" else { return nil }
            var changed = original
            if let id = (0..<(changed.count - 1)).first(where: { changed[$0] == 0x12 && changed[$0 + 1] == 66 }),
               changed[id + 68] == 0x18 {
                changed[id + 69] ^= 0x01
            }
            return Data(changed)
        }
        await #expect(throws: ReaderError.providersDisagree(field: "coins")) {
            try await SuiRecorded.reader(transport).accountState(owner: SuiRecorded.owner)
        }
    }

    @Test("No de outra rede e recusado antes de qualquer leitura")
    func wrongNetwork() async throws {
        let info = [UInt8](try SuiRecorded.data("GetServiceInfo"))
        let transport = try SuiRecorded.Transport { _, method, _ in
            guard method == "GetServiceInfo" else { return nil }
            // "mainnet" vira "testnet": mesmo tamanho, outra rede.
            let from = Array("mainnet".utf8)
            var changed = info
            if let start = (0...(info.count - from.count)).first(where: { Array(info[$0..<($0 + from.count)]) == from }) {
                changed.replaceSubrange(start..<(start + from.count), with: Array("testnet".utf8))
            }
            return Data(changed)
        }
        await #expect(throws: ReaderError.wrongNetwork) {
            try await SuiRecorded.reader(transport).accountState(owner: SuiRecorded.owner)
        }
    }

    @Test("Simulacao gravada: sucesso, gas e variacoes de saldo; digesto de outra transacao recusado")
    func simulation() async throws {
        let transport = try SuiRecorded.Transport()
        let reader = SuiRecorded.reader(transport)
        let send = try SuiRecorded.transaction("SimulateTransaction-envio")
        let results = try await reader.simulate(send)
        #expect(results.count == 2)
        let result = results[0]
        #expect(result.success)
        #expect(result.gas.computationCost == 100_000)
        #expect(result.balanceChanges.contains(SuiBalanceChange(
            address: SuiRecorded.address(SuiRecorded.destination), coinType: SuiPlanner.suiCoinType, negative: false, magnitude: 1_000_000_000
        )))
        #expect(try SuiPlanner.sendParameters(send)?.1 == SuiRecorded.amount)
        let estimate = try await reader.estimateGas(try SuiRecorded.transaction("SimulateTransaction-estimativa"))
        #expect(try SuiPlanner.budget(for: estimate, price: 100) == send.gas.budget)

        // A resposta gravada e da transacao de envio; pedida para outra, o digesto nao bate.
        let recorded = try SuiRecorded.data("SimulateTransaction-envio")
        let other = try SuiRecorded.Transport { _, method, _ in method == "SimulateTransaction" ? recorded : nil }
        await #expect(throws: ReaderError.responseMismatch(field: "simulate.digest")) {
            try await SuiRecorded.reader(other).simulate(try SuiRecorded.transaction("SimulateTransaction-estimativa"))
        }
    }

    @Test("Acompanhamento: achada nos dois, nao achada, e so num")
    func status() async throws {
        let digest = String(decoding: try SuiRecorded.data("digesto-achado", "txt"), as: UTF8.self)
        let found = try await SuiRecorded.reader(try SuiRecorded.Transport()).status(of: digest)
        guard case .confirmed(let checkpoint?, nil) = found else { Issue.record("esperava confirmada: \(found)"); return }
        #expect(checkpoint > 300_000_000)

        let missing = try SuiRecorded.data("BatchGetTransactions-nao-achada")
        let unknown = "Ea7JiCRKcxigeKMTwFx1y3SjVRg5nK3tJR68SovpBB8j"
        let none = try SuiRecorded.Transport { _, method, _ in method == "BatchGetTransactions" ? missing : nil }
        #expect(try await SuiRecorded.reader(none).status(of: unknown) == .notFound)
        // Validade ate a epoca 1.263, e a rede ja na 1.264: vencida.
        #expect(try await SuiRecorded.reader(none).status(of: unknown, validUntilEpoch: 1_263) == .failed(reason: "expired"))
        #expect(try await SuiRecorded.reader(none).status(of: unknown, validUntilEpoch: 1_265) == .notFound)

        let half = try SuiRecorded.Transport { host, method, _ in
            method == "BatchGetTransactions" && host == "suiscan.test" ? missing : nil
        }
        #expect(try await SuiRecorded.reader(half).status(of: digest) == .pending)
    }

    @Test("Saldo da tela: SUI de moedas e de endereco, outras moedas so na contagem")
    func displayBalance() async throws {
        let balance = try await SuiRecorded.reader(try SuiRecorded.Transport()).displayBalance(owner: SuiRecorded.owner.hex)
        #expect(balance.chainID == "sui")
        #expect(balance.holdings.count == 1)
        #expect(balance.holdings[0].asset == .native(.sui))
        #expect(balance.holdings[0].amount > BigUInt(1_000_000_000_000))
        #expect(balance.unknownTokenCount > 0)
        #expect(balance.accountExists)
    }

    @Test("Historico: GraphQL, e o gRPC quando o GraphQL falha")
    func history() async throws {
        let transport = try SuiRecorded.Transport()
        let page = try await SuiRecorded.reader(transport).history(owner: SuiRecorded.owner)
        #expect(page.chainID == "sui")
        #expect(page.isComplete)
        #expect(!page.items.isEmpty)
        #expect(page.items.allSatisfy { $0.asset == .native(.sui) && $0.explorerURL?.host == "suiscan.xyz" })
        #expect(page.items.contains { $0.direction == .sent && !$0.amount.isZero })
        // O endereco foi nas variaveis do corpo do GraphQL, nunca na URL.
        let graph = try #require(transport.requests.first { $0.url.host == "graphql.test" })
        #expect(String(decoding: graph.body ?? Data(), as: UTF8.self).contains(SuiRecorded.owner.hex))
        #expect(!graph.url.absoluteString.contains(SuiRecorded.owner.hex))

        let down = try SuiRecorded.Transport { host, _, _ in
            if host == "graphql.test" { throw HTTPClient.Failure.status(503) }
            return nil
        }
        let fallback = try await SuiRecorded.reader(down).history(owner: SuiRecorded.owner)
        #expect(!fallback.isComplete)
        #expect(!fallback.items.isEmpty)
    }

    @Test("Itens do historico: envio com taxa, recebimento, po e moeda fora da lista")
    func activityItems() {
        let owner = SuiRecorded.owner
        let other = SuiRecorded.address(SuiRecorded.destination)
        let gas = SuiGasCost(computationCost: 1_000_000, storageCost: 2_000_000, storageRebate: 1_000_000)
        func change(_ address: SuiAddress, _ negative: Bool, _ amount: UInt64, type: String = SuiPlanner.suiCoinType) -> SuiBalanceChange {
            SuiBalanceChange(address: address, coinType: type, negative: negative, magnitude: BigUInt(amount))
        }
        let entries = [
            SuiHistoryEntry(digest: "A91t5Yqb5mTQL6JCoGZjpTZGq9gBiRP3ZVPukt9Vprp3", sender: owner, success: true, date: .now, gas: gas,
                            changes: [change(owner, true, 5_002_000_000), change(other, false, 5_000_000_000)]),
            SuiHistoryEntry(digest: "HkPo6rYPyDY53x1MBszvSZVZyixVN7CHvCJGX381czAh", sender: other, success: true, date: .now, gas: nil,
                            changes: [change(owner, false, 7_000_000_000)]),
            SuiHistoryEntry(digest: "D4Ay9TdBJjXkGmrZSstZakpEWskEQHaWURP6xWPRXbAm", sender: other, success: true, date: .now, gas: nil,
                            changes: [change(owner, false, 10)]),
            SuiHistoryEntry(digest: "GNoQj54Ra8qGbzbvD25KXEYTsRDKTH5SSjLtHftGNwBM", sender: other, success: true, date: .now, gas: nil,
                            changes: [change(owner, false, 500, type: "0x" + String(repeating: "b", count: 64) + "::fake::USDC")]),
        ]
        let page = SuiReader.activityPage(entries, owner: owner, complete: true)
        #expect(page.items.count == 2)
        let sent = page.items.first { $0.direction == .sent }
        #expect(sent?.amount == 5_000_000_000)
        #expect(sent?.fee == 2_000_000)
        #expect(sent?.counterparty == other.hex)
        #expect(page.items.first { $0.direction == .received }?.amount == 7_000_000_000)
        #expect(page.suspicious.dust == 1)
        #expect(page.suspicious.unknownAsset == 1)
    }

    @Test("Transmissao: so a transacao assinada que confere; o digesto devolvido tem de ser o calculado")
    func broadcast() async throws {
        let vector = try #require(SuiReaderTests.trustVector)
        let digest = "HkPo6rYPyDY53x1MBszvSZVZyixVN7CHvCJGX381czAh"
        // ExecuteTransactionResponse { transaction { digest, effects { status { success } } } }.
        var status = SuiProtoWriter(); status.uint64(1, 1)
        var effects = SuiProtoWriter(); effects.message(4, status)
        var executed = SuiProtoWriter(); executed.string(1, digest); executed.message(4, effects)
        var response = SuiProtoWriter(); response.message(1, executed)
        let ok = SuiRecorded.frame(response.bytes)
        let transport = try SuiRecorded.Transport { _, method, _ in method == "ExecuteTransaction" ? ok : nil }
        let receipt = try await SuiRecorded.reader(transport).broadcast(vector)
        #expect(receipt.id == digest)
        #expect(receipt.acceptedBy == ["suifoundation", "suiscan"])
        #expect(receipt.provisionalResult == "success")
        // O corpo levou a transacao e a assinatura serializada (97 bytes).
        let sent = try #require(transport.requests.first { $0.url.lastPathComponent == "ExecuteTransaction" }?.body)
        #expect(SuiRecorded.Transport.contains([UInt8](sent), Array(vector.raw.suffix(97))))

        var wrong = SuiProtoWriter(); wrong.string(1, "D4Ay9TdBJjXkGmrZSstZakpEWskEQHaWURP6xWPRXbAm"); wrong.message(4, effects)
        var wrongResponse = SuiProtoWriter(); wrongResponse.message(1, wrong)
        let lie = SuiRecorded.frame(wrongResponse.bytes)
        let liar = try SuiRecorded.Transport { _, method, _ in method == "ExecuteTransaction" ? lie : nil }
        await #expect(throws: ReaderError.broadcastMismatch) { try await SuiRecorded.reader(liar).broadcast(vector) }

        var tampered = vector.raw
        tampered[20] ^= 1
        let forged = SignedTransaction(chainID: "sui", raw: tampered, encoded: vector.encoded, id: vector.id)
        await #expect(throws: ReaderError.broadcastMismatch) { try await SuiRecorded.reader(transport).broadcast(forged) }
    }

    /// O sign_direct_transfer do wallet-core (EscaliburChainsTests/SuiTransactionTests),
    /// no formato de `SignedTransaction` da carteira.
    static var trustVector: SignedTransaction? {
        let tx = "AAACAAgQJwAAAAAAAAAgJZ/4B0q0Jcu0ifI24Y4I8D8aeFa998eih3vWT3OLUBUCAgABAQAAAQEDAAAAAAEBANV1rX8Y6UhGKlz2mPVk7zlKdSpx/sYkk6+KBVwBLA1QAQbywsjB2JZN8QGdZhbpcFcZvrq9kx2idVy5SM635olk7AIAAAAAAAAgYEVuxmf1zRBGdoDr+VDtMpIFF12s2Ua7I2ru1XyGF8/Vda1/GOlIRipc9pj1ZO85SnUqcf7GJJOvigVcASwNUAEAAAAAAAAA0AcAAAAAAAAA"
        let sig = "APxPduNVvHj2CcRcHOtiP2aBR9qP3vO2Cb0g12PI64QofDB6ks33oqe/i/iCTLcop2rBrkczwrayZuJOdi7gvwNqfN7sFqdcD/Z4e8I1YQlGkDMCK7EOgmydRDqfH8C9jg=="
        guard let t = Data(base64Encoded: tx), let s = Data(base64Encoded: sig) else { return nil }
        return SignedTransaction(chainID: "sui", raw: [UInt8](t) + [UInt8](s), encoded: tx + "." + sig, id: "HkPo6rYPyDY53x1MBszvSZVZyixVN7CHvCJGX381czAh")
    }

    @Test("Tipos Move na forma longa e valores com sinal")
    func formats() {
        #expect(SuiReader.normalizedType("0x2::coin::Coin<0x2::sui::SUI>") == "0x0000000000000000000000000000000000000000000000000000000000000002::coin::Coin<0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI>")
        #expect(SuiReader.normalizedType(SuiPlanner.suiCoinType) == SuiPlanner.suiCoinType)
        #expect(SuiReader.normalizedType("sui::SUI") == nil)
        #expect(SuiReader.signedAmount("-2804976876")! == (true, BigUInt(2_804_976_876)))
        #expect(SuiReader.signedAmount("1000")! == (false, BigUInt(1_000)))
        #expect(SuiReader.signedAmount("1e3") == nil)
        #expect(SuiReader.signedAmount("-") == nil)
    }
}
