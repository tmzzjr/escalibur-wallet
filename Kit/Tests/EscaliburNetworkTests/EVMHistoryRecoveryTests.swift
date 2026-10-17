import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Responde pelas gravacoes da recuperacao (pares pedido e resposta, `Fixtures/leitores/
/// evm/alchemy-recuperacao-*`): cada pedido JSON-RPC, sozinho ou dentro de um lote, pelo
/// metodo e pelos parametros gravados. O que nao foi gravado volta como erro e fica em
/// `missed`, para o teste conferir que o leitor so pediu o que a rede respondeu.
final class RecordedRPC: Sendable {
    let transport: FixtureTransport
    private let state: State

    /// O que o transporte consulta: as respostas por pedido e o que faltou.
    private final class State: @unchecked Sendable {
        let answers: [String: StrictJSON]
        let failing: Set<String>
        let lock = NSLock()
        var misses: [String] = []

        init(answers: [String: StrictJSON], failing: Set<String>) {
            self.answers = answers
            self.failing = failing
        }

        func answer(_ call: StrictJSON) -> StrictJSON {
            let id = call.objectValue?["id"] ?? .number("1")
            guard let method = FixtureTransport.method(call), !failing.contains(method), let key = RecordedRPC.key(call),
                  var recorded = answers[key]?.objectValue
            else {
                lock.withLock { misses.append(RecordedRPC.key(call) ?? "?") }
                return .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number("-32000"), "message": .string("sem gravacao")])])
            }
            recorded["id"] = id
            return .object(recorded)
        }

        func respond(_ body: StrictJSON?) throws -> Data? {
            if case .array(let calls)? = body { return StrictJSON.array(calls.map(answer)).serialized }
            guard let body else { return nil }
            if let method = FixtureTransport.method(body), failing.contains(method) { throw HTTPClient.Failure.status(503) }
            let reply = answer(body)
            guard reply.objectValue?["error"] == nil else { throw HTTPClient.Failure.status(404) }
            return reply.serialized
        }
    }

    init(_ name: String, failing: Set<String> = []) throws {
        var answers: [String: StrictJSON] = [:]
        for pair in try ReaderFixtures.json("evm", name).array("pares") {
            let request = try pair.field("request", "par")
            let response = try pair.field("response", "par")
            if case .array(let calls) = request {
                var byID: [String: StrictJSON] = [:]
                for answer in try response.array("lote") { byID[StrictJSON.serialize(try answer.field("id", "lote"))] = answer }
                for call in calls {
                    if let key = Self.key(call), let answer = byID[StrictJSON.serialize(try call.field("id", "lote"))] { answers[key] = answer }
                }
            } else if let key = Self.key(request) {
                answers[key] = response
            }
        }
        let state = State(answers: answers, failing: failing)
        self.state = state
        transport = FixtureTransport([{ _, body in try state.respond(body) }])
    }

    var missed: [String] { state.lock.withLock { state.misses } }

    /// Quantas chamadas de cada metodo sairam, contando as de dentro dos lotes.
    func count(_ method: String, batched: Bool? = nil) -> Int {
        transport.requests.reduce(0) { total, request in
            let body = request.body.flatMap { try? StrictJSON.parse($0) }
            if case .array(let calls)? = body {
                guard batched != false else { return total }
                return total + calls.filter { FixtureTransport.method($0) == method }.count
            }
            guard batched != true else { return total }
            return total + (FixtureTransport.method(body) == method ? 1 : 0)
        }
    }

    static func key(_ call: StrictJSON) -> String? {
        guard let method = FixtureTransport.method(call) else { return nil }
        return method + "|" + StrictJSON.serialize(.array(FixtureTransport.params(call)))
    }
}

/// O historico da BNB Chain pela Alchemy com o que ela nao lista: as transacoes do dono
/// que falharam e o BNB que um contrato mandou para ele numa transacao dele. Gravado ao
/// vivo em 16/10/2026 pelo proprio leitor, em duas contas comuns da rede (LEIA-ME.txt).
@Suite("Historico da BNB Chain: falhas e BNB mandado por contrato, sem trace")
struct EVMHistoryRecoveryTests {
    static let provider = ProviderPool.Provider(name: "alchemy", baseURL: URL(string: "https://alchemy.test/v2/chave")!)
    /// Conta que vende USDT por BNB o dia inteiro, com transacoes que falham.
    static let seller = try! EVMAddress("0x3506415a8b48f50ebea46528451890e891b95572")
    /// Conta que troca token por BNB pelo roteador v2 da PancakeSwap.
    static let swapper = try! EVMAddress("0x7fa3a6202e6899bcee8a627f8786e5702ead1db3")
    static let router = "0x10ED43C718714eb63d5aA57B78B54704E256024E"
    /// `Withdrawal(address,uint256)` do WBNB.
    static let withdrawalTopic = "0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65"

    static func reader(_ recorded: RecordedRPC) -> EVMReader {
        EVMReader(transport: recorded.transport, rpc: [:], history: ["bnb": [provider]], privateRelays: [])
    }

    /// Os hashes que a Alchemy listou nos envios do dono, na gravacao.
    static func listedSends(_ name: String) throws -> Set<String> {
        var out = Set<String>()
        for pair in try ReaderFixtures.json("evm", name).array("pares") {
            let request = try pair.field("request", "par")
            guard FixtureTransport.method(request) == "alchemy_getAssetTransfers",
                  case .object(let query)? = FixtureTransport.params(request).first, query["fromAddress"] != nil,
                  case .array(let categories)? = query["category"], categories == [.string("external")]
            else { continue }
            for item in try pair.field("response", "par").field("result", "r").field("transfers", "t").array("t") {
                out.insert(try item.field("hash", "h").string("h").lowercased())
            }
        }
        return out
    }

    /// O `wad` do `Withdrawal` do WBNB em cada recibo gravado, pelo hash.
    static func withdrawals(_ name: String) throws -> [String: BigUInt] {
        var out: [String: BigUInt] = [:]
        for pair in try ReaderFixtures.json("evm", name).array("pares") {
            guard case .array(let calls) = try pair.field("request", "par"),
                  calls.allSatisfy({ FixtureTransport.method($0) == "eth_getTransactionReceipt" })
            else { continue }
            for answer in try pair.field("response", "par").array("lote") {
                let receipt = try answer.field("result", "r")
                for log in try receipt.field("logs", "l").array("l") {
                    guard let topics = try? log.field("topics", "t").array("t"), topics.first == .string(withdrawalTopic) else { continue }
                    out[try receipt.field("transactionHash", "h").string("h").lowercased()] = try log.field("data", "d").quantity("d")
                }
            }
        }
        return out
    }

    @Test("Falhas do dono: achadas pelo nonce bloco a bloco, com o status e a taxa do recibo, dentro do teto")
    func failedTransactions() async throws {
        let recorded = try RecordedRPC("alchemy-recuperacao-falhas-bnb")
        let reader = Self.reader(recorded)
        let page = try await reader.history(chain: .bnb, address: Self.seller)
        #expect(recorded.missed.isEmpty)

        // Quatro transacoes do dono que a Alchemy nao lista: todas falharam, com taxa.
        let listed = try Self.listedSends("alchemy-recuperacao-falhas-bnb")
        let failed = page.items.filter { $0.status == .failed }
        #expect(failed.count == 4)
        #expect(failed.allSatisfy { !listed.contains($0.hash.lowercased()) && $0.fee.map { !$0.isZero } == true })
        #expect(failed.allSatisfy { $0.direction == .other && $0.amount.isZero })
        #expect(page.items.filter { $0.status != .failed }.allSatisfy { listed.contains($0.hash.lowercased()) || $0.direction == .received })
        // Todas acharam: a diferenca do nonce fechou, a pagina e inteira.
        #expect(page.isComplete)
        #expect(page.items.allSatisfy { $0.chainID == "bnb" })
        #expect(recorded.transport.requests.allSatisfy { !$0.url.absoluteString.lowercased().contains(Self.seller.checksummed.lowercased()) })

        // Custo: dentro dos tetos por leitura.
        #expect(recorded.count("eth_getTransactionCount", batched: false) <= EVMReader.recoveryNonceProbes)
        #expect(recorded.count("eth_getBlockByNumber") == 4)
        #expect(recorded.count("eth_getBlockByNumber") <= EVMReader.recoveryBlocks)
        #expect(recorded.count("eth_getBalance") <= 2 * EVMReader.recoveryBalanceBlocks)
        #expect(recorded.count("trace_transaction") + recorded.count("debug_traceTransaction") == 0)

        // Segunda leitura na mesma sessao: as falhas ja achadas explicam o nonce, sem busca.
        let before = recorded.transport.requests.count
        let again = try await reader.history(chain: .bnb, address: Self.seller)
        let second = Array(recorded.transport.requests.dropFirst(before))
        #expect(again.items.filter { $0.status == .failed }.map(\.hash) == failed.map(\.hash))
        #expect(!second.contains { request in
            guard let body = request.body.flatMap({ try? StrictJSON.parse($0) }), case .object = body else { return false }
            return ["eth_blockNumber", "eth_getBlockByNumber", "eth_getTransactionCount"].contains(FixtureTransport.method(body) ?? "")
        })
    }

    @Test("BNB que volta da troca: saldo antes e depois do bloco, igual ao saque do WBNB no recibo, ao centavo")
    func internalFromSwap() async throws {
        let recorded = try RecordedRPC("alchemy-recuperacao-saldo-bnb")
        let reader = Self.reader(recorded)
        let page = try await reader.history(chain: .bnb, address: Self.swapper)
        #expect(recorded.missed.isEmpty)
        #expect(page.isComplete)

        // As tres trocas de token por BNB: o BNB que o roteador mandou e o `wad` do saque
        // do WBNB que ele fez para pagar, exato.
        let withdrawals = try Self.withdrawals("alchemy-recuperacao-saldo-bnb")
        #expect(withdrawals.count == 3)
        let listed = try Self.listedSends("alchemy-recuperacao-saldo-bnb")
        let recovered = page.items.filter { $0.direction == .received && listed.contains($0.hash.lowercased()) }
        #expect(recovered.count == 3)
        for item in recovered {
            #expect(item.asset.kind == .native && item.amount == withdrawals[item.hash.lowercased()], "\(item.hash)")
            #expect(item.counterparty == Self.router)
        }

        // So os envios com evento no recibo entram na conta: o envio de BNB para carteira
        // nao recebe nada de volta. Nove blocos, dois saldos cada, num lote.
        #expect(recorded.count("eth_getBalance", batched: true) == 18)
        #expect(recorded.count("eth_getBalance", batched: false) == 0)
        // Nenhuma falha nesta conta: o nonce bate com a lista, sem busca.
        #expect(recorded.count("eth_blockNumber") == 0)

        // Segunda leitura: o que o saldo deu ja esta na memoria da sessao.
        let before = recorded.transport.requests.count
        let again = try await reader.history(chain: .bnb, address: Self.swapper)
        #expect(recorded.transport.requests.count - before == 6)
        #expect(again.items == page.items)
    }

    @Test("Resposta que falta: a pagina fica como a Alchemy entregou, marcada parcial se ficou transacao do dono sem achar")
    func missingAnswers() async throws {
        let recorded = try RecordedRPC("alchemy-recuperacao-falhas-bnb", failing: ["eth_getBlockByNumber"])
        let page = try await Self.reader(recorded).history(chain: .bnb, address: Self.seller)
        #expect(!page.items.contains { $0.status == .failed })
        #expect(!page.isComplete)
        #expect(!page.items.isEmpty)

        // Sem o lote do nonce, nada se sabe: a pagina sai inteira, como antes.
        let silent = try RecordedRPC("alchemy-recuperacao-saldo-bnb", failing: ["eth_getCode"])
        let plain = try await Self.reader(silent).history(chain: .bnb, address: Self.swapper)
        #expect(plain.isComplete)
        #expect(!plain.items.contains { $0.direction == .received && $0.counterparty == Self.router })
    }
}
