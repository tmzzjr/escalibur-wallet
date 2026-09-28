import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// O que os quatro leitores compartilham: JSON estrito, consenso entre provedores e as
/// regras do historico.
@Suite("Suporte dos leitores")
struct ReaderSupportTests {
    // MARK: JSON estrito

    @Test("Numero grande mantem todos os digitos")
    func bigNumbers() throws {
        let json = try StrictJSON.parse(Data(#"{"balance": 2101293387317688123, "wei": "439595913402087593105057"}"#.utf8))
        #expect(try json.field("balance", "$").unsigned("balance") == BigUInt(decimal: "2101293387317688123")!)
        #expect(try json.field("wei", "$").decimalString("wei") == BigUInt(decimal: "439595913402087593105057")!)
        // Double perderia o ultimo digito: 2101293387317688123 vira ...8000.
        #expect(Double("2101293387317688123").map { UInt64($0) } != 2_101_293_387_317_688_123)
    }

    @Test("Campo faltando, tipo errado, negativo e fracao sao erro, nunca zero")
    func strictAccess() throws {
        let json = try StrictJSON.parse(Data(#"{"a": 1, "b": "2", "c": -3, "d": 1.5, "e": null}"#.utf8))
        #expect(throws: ReaderError.malformed(field: "$.x")) { _ = try json.field("x", "$") }
        #expect(throws: ReaderError.malformed(field: "b")) { _ = try json.field("b", "$").unsigned("b") }
        #expect(throws: ReaderError.malformed(field: "c")) { _ = try json.field("c", "$").unsigned("c") }
        #expect(throws: ReaderError.malformed(field: "d")) { _ = try json.field("d", "$").uint64("d") }
        #expect(try json.field("c", "$").int64("c") == -3)
        #expect(json.optionalField("e") == nil)
        #expect(throws: ReaderError.malformed(field: "q")) { _ = try StrictJSON.string("0x").quantity("q") }
        #expect(throws: ReaderError.malformed(field: "q")) { _ = try StrictJSON.string("12").quantity("q") }
        #expect(try StrictJSON.number("0.2").scaledDecimal("r", scale: 6) == BigUInt(200_000))
        #expect(throws: ReaderError.malformed(field: "r")) { _ = try StrictJSON.number("0.0000001").scaledDecimal("r", scale: 6) }
    }

    @Test("Chave duplicada, lixo depois do valor e escape invalido sao recusados")
    func strictGrammar() {
        for text in [#"{"a":1,"a":2}"#, #"{"a":1} x"#, #""\q""#, "[1,]", "{\"a\":\u{01}}", "01", "\"\u{0A}\""] {
            #expect(throws: ReaderError.self, "\(text)") { _ = try StrictJSON.parse(Data(text.utf8)) }
        }
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        #expect(throws: ReaderError.self) { _ = try StrictJSON.parse(Data(deep.utf8)) }
    }

    @Test("Serializacao com chaves em ordem e escape")
    func serialization() {
        let value = StrictJSON.object(["b": .int(2), "a": .array([.string("x\"y\n"), .bool(true), .null])])
        #expect(String(decoding: value.serialized, as: UTF8.self) == #"{"a":["x\"y\n",true,null],"b":2}"#)
    }

    // MARK: Consenso

    struct Boom: Error {}

    @Test("agree: dois iguais bastam; divergencia pergunta ao terceiro; sem par, erro")
    func agree() async throws {
        let providers = testProviders("a", "b", "c")
        let pool = ProviderPool(providers)
        let first = try await Quorum.agree(providers, pool: pool, field: "x") { $0.name == "b" ? 2 : 1 }
        #expect(first == 1)
        await #expect(throws: ReaderError.providersDisagree(field: "x")) {
            _ = try await Quorum.agree(providers, pool: pool, field: "x") { provider -> Int in
                ["a": 1, "b": 2, "c": 3][provider.name]!
            }
        }
        await #expect(throws: ReaderError.notEnoughProviders(needed: 2, got: 1)) {
            _ = try await Quorum.agree(providers, pool: pool, field: "x") { provider -> Int in
                guard provider.name == "a" else { throw ReaderError.providerError(code: "x") }
                return 1
            }
        }
    }

    @Test("collect: provedor que falha e trocado pelo proximo")
    func collect() async throws {
        let providers = testProviders("a", "b", "c")
        let answers = try await Quorum.collect(providers, pool: ProviderPool(providers), count: 2) { provider -> String in
            if provider.name == "a" { throw HTTPClient.Failure.timeout }
            return provider.name
        }
        #expect(answers.map(\.value) == ["b", "c"])
    }

    @Test("Falha de transporte conta contra o provedor; erro do protocolo nao")
    func circuitBreaker() async throws {
        let providers = testProviders("a", "b")
        let pool = ProviderPool(providers)
        for _ in 0..<3 {
            _ = try? await Quorum.first(providers, pool: pool) { provider -> Int in
                if provider.name == "a" { throw HTTPClient.Failure.timeout }
                return 1
            }
        }
        #expect(await pool.available().map(\.name) == ["b"])
        let other = ProviderPool(providers)
        for _ in 0..<3 {
            _ = try? await Quorum.first(providers, pool: other) { provider -> Int in
                if provider.name == "a" { throw ReaderError.providerError(code: "actNotFound") }
                return 1
            }
        }
        #expect(await other.available().map(\.name) == ["a", "b"])
    }

    @Test("Transmissao: 'ja conhecida' conta como aceita; recusa geral traz o motivo")
    func tally() throws {
        let providers = testProviders("a", "b")
        var tally = BroadcastTally()
        tally.add(.failure(ReaderError.broadcastRejected(.alreadyKnown, code: "-32000")), provider: providers[0])
        tally.add(.failure(HTTPClient.Failure.timeout), provider: providers[1])
        #expect(try tally.receipt(chainID: "ethereum", id: "0x1").acceptedBy == ["a"])
        var rejected = BroadcastTally()
        rejected.add(.failure(ReaderError.broadcastRejected(.insufficientFunds, code: "-32000")), provider: providers[0])
        #expect(throws: ReaderError.broadcastRejected(.insufficientFunds, code: "-32000")) { _ = try rejected.receipt(chainID: "ethereum", id: "0x1") }
    }

    @Test("Mensagens de erro de no EVM classificadas sem guardar o texto")
    func evmRejections() {
        #expect(BroadcastRejection.evm(message: "already known") == .alreadyKnown)
        #expect(BroadcastRejection.evm(message: "nonce too low: next nonce 7, tx nonce 6") == .nonceTooLow)
        #expect(BroadcastRejection.evm(message: "insufficient funds for gas * price + value: address 0xabc have 1 want 2") == .insufficientFunds)
        #expect(BroadcastRejection.evm(message: "replacement transaction underpriced") == .underpriced)
        #expect(BroadcastRejection.evm(message: "max fee per gas less than block base fee") == .underpriced)
        #expect(BroadcastRejection.evm(message: "invalid chain id for signer") == .wrongNetwork)
        #expect(BroadcastRejection.evm(message: "algo novo") == .other)
    }

    @Test("Codigo de erro de provedor saneado: nada de endereco, link ou texto livre")
    func sanitizedCodes() {
        #expect(ReaderError.sanitized("tefPAST_SEQ") == "tefPAST_SEQ")
        #expect(ReaderError.sanitized("-32000") == "-32000")
        #expect(ReaderError.sanitized("veja https://golpe.example/0xABC") == "vejahttpsgolpeexample0xABC")
        #expect(ReaderError.sanitized(String(repeating: "a", count: 100)).count == 40)
        #expect(ReaderError.sanitized("!!!") == "error")
    }

    @Test("Cota de RPC gratuito e falha do provedor, nao resposta")
    func rateLimitMessages() {
        #expect(EVMReader.isRateLimit(code: "-32001", message: "You've reached the usage limit for your current plan."))
        #expect(EVMReader.isRateLimit(code: "35", message: "ranges over 10000 blocks are not supported on free plan"))
        #expect(EVMReader.isRateLimit(code: "-32005", message: "limit exceeded"))
        #expect(!EVMReader.isRateLimit(code: "-32000", message: "exceeds block gas limit"))
        #expect(!EVMReader.isRateLimit(code: "-32000", message: "nonce too low"))
    }

    @Test("Espacamento por host: requisicoes seguidas ao mesmo host esperam a vez")
    func pacing() async throws {
        let transport = FixtureTransport([{ _, _ in Data("{}".utf8) }])
        let paced = PacedTransport(base: transport, intervals: ["paced.test": 0.15])
        let started = Date()
        for _ in 0..<3 { _ = try await paced.send(.get(URL(string: "https://paced.test/x")!)) }
        #expect(Date().timeIntervalSince(started) >= 0.29)
        // Host sem espacamento: nenhuma reserva de horario, logo nenhuma espera. Conferido
        // pelo estado do espacador e nao pelo relogio, que no runner do CI carregado
        // passava de qualquer teto.
        for _ in 0..<3 { _ = try await paced.send(.get(URL(string: "https://free.test/x")!)) }
        #expect(await HostPacer.shared.reservedSlot(host: "free.test") == nil)
        #expect(await HostPacer.shared.reservedSlot(host: "paced.test") != nil)
    }

    @Test("429 espera e tenta de novo uma vez")
    func retryOn429() async throws {
        final class Flaky: ReaderTransport, @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            func send(_ request: ReaderRequest) async throws -> Data {
                let count = lock.withLock { calls += 1; return calls }
                if count == 1 { throw HTTPClient.Failure.status(429) }
                return Data("ok".utf8)
            }
        }
        let flaky = Flaky()
        let data = try await PacedTransport(base: flaky, intervals: [:], retryDelay: 0.01).send(.get(URL(string: "https://retry.test/x")!))
        #expect(data == Data("ok".utf8))
        #expect(flaky.calls == 2)
    }

    // MARK: Historico

    @Test("Limite de po: 0,01 em stablecoin, 0,0001 no resto")
    func dust() {
        let usdt = TokenRegistry.find(chainID: "tron", contract: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t")!
        #expect(ActivityRules.dustLimit(for: usdt) == BigUInt(10_000))
        #expect(ActivityRules.dustLimit(for: .native(.ethereum)) == BigUInt(100_000_000_000_000))
        #expect(ActivityRules.dustLimit(for: .native(.xrpl)) == BigUInt(100))
        #expect(ActivityRules.judgeIncoming(asset: nil, amount: 5) == .unknownAsset)
        #expect(ActivityRules.judgeIncoming(asset: usdt, amount: 0) == .zeroValue)
        #expect(ActivityRules.judgeIncoming(asset: usdt, amount: 9_999) == .dust)
        #expect(ActivityRules.judgeIncoming(asset: usdt, amount: 1_000_000, flaggedByProvider: true) == .flaggedByProvider)
        #expect(ActivityRules.judgeIncoming(asset: usdt, amount: 10_000) == nil)
    }

    @Test("Pagina: mais recente primeiro, sem repetir, no maximo 30")
    func page() {
        let items = (0..<40).map { index in
            ActivityItem(
                id: "x:\(index % 35)", chainID: "tron", direction: .received, asset: .native(.tron), amount: 1,
                counterparty: nil, date: Date(timeIntervalSince1970: TimeInterval(index)), status: .confirmed, fee: nil,
                hash: "\(index)", explorerURL: nil
            )
        }
        let page = ActivityRules.page(chainID: "tron", items: items, suspicious: SuspiciousSummary())
        #expect(page.items.count == 30)
        #expect(page.items.first?.date == Date(timeIntervalSince1970: 39))
        #expect(Set(page.items.map(\.id)).count == 30)
    }
}
