import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// A leitura de saldo com a lista curada grande: quantas chamadas cada rede custa, o lote
/// do Multicall3 contra uma resposta gravada e as linhas de confianca do XRP Ledger. Sem
/// rede: respostas gravadas (Fixtures/leitores) e montadas aqui.
@Suite("Saldos: lote do Multicall3 e linhas do XRP Ledger")
struct BalanceBatchTests {
    static let owner = "0x28C6c06298d514Db089934071355E5743bf21d60"

    /// Resposta de `aggregate3`, na forma do contrato: `(bool success, bytes returnData)[]`.
    static func aggregate3Result(_ items: [(Bool, [UInt8])]) throws -> String {
        let encoded = try ABI.encode(
            [.array(items.map { .tuple([.bool($0.0), .bytes($0.1)]) })],
            types: [.array(.tuple([.bool, .bytes]))]
        )
        return Hex.encode(encoded, prefix: true)
    }

    static func word(_ value: UInt64) -> [UInt8] {
        BigUInt(value).bigEndianBytes(padTo: 32) ?? []
    }

    /// As chamadas de `aggregate3` que a requisicao leva, decodificadas da calldata.
    static func calls(_ body: StrictJSON?) throws -> [(target: EVMAddress, data: [UInt8])] {
        let params = FixtureTransport.params(body)
        guard case .object(let call)? = params.first, case .string(let data)? = call["data"], let bytes = Hex.decode(data) else {
            throw ReaderFixtures.FixtureMissing(name: "calldata")
        }
        let function = try ABIFunction("aggregate3((address,bool,bytes)[])")
        guard case .array(let items)? = try function.decodeCall(bytes).first else { throw ReaderFixtures.FixtureMissing(name: "aggregate3") }
        return items.compactMap { item in
            guard case .tuple(let fields) = item, case .address(let target) = fields[0], case .bytes(let data) = fields[2] else { return nil }
            return (target, data)
        }
    }

    // MARK: EVM

    @Test("Ethereum: a lista inteira em duas chamadas, e so o que tem saldo entra")
    func ethereumTwoCalls() async throws {
        let chain = Chain.ethereum
        let usdc = try #require(TokenRegistry.find(chainID: "ethereum", contract: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"))
        let link = try #require(TokenRegistry.find(chainID: "ethereum", contract: "0x514910771AF9Ca656af840dff83E8264EcF986CA"))
        let listed = TokenRegistry.assets(on: chain).filter { $0.kind != .native }
        #expect(listed.count > 50, "a Ethereum tem dezenas de tokens na lista")

        let transport = FixtureTransport([{ request, body in
            switch FixtureTransport.method(body) {
            case "eth_getBalance": return rpcResult("\"0xde0b6b3a7640000\"")
            case "eth_call":
                let calls = try Self.calls(body)
                let items: [(Bool, [UInt8])] = calls.map { call in
                    if call.target.checksummed == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" { return (true, Self.word(5_000_000)) }
                    // Um token que reverte nao derruba os outros.
                    if call.target.checksummed == "0x514910771AF9Ca656af840dff83E8264EcF986CA" { return (false, []) }
                    return (true, Self.word(0))
                }
                return rpcResult("\"" + (try Self.aggregate3Result(items)) + "\"")
            default: return nil
            }
        }])
        let service = BalanceService(client: .shared, transport: transport, evm: [chain.id: testProviders("rpc-a", "rpc-b")], xrpl: [])
        let balance = try await service.balance(chain: chain, addresses: [Self.owner])

        #expect(transport.requests.count == 2)
        let methods = transport.requests.compactMap { FixtureTransport.method($0.body.flatMap { try? StrictJSON.parse($0) }) }
        #expect(methods == ["eth_getBalance", "eth_call"])
        // A chamada vai ao Multicall3, com o balanceOf do dono para cada token da lista.
        let body = try StrictJSON.parse(try #require(transport.requests[1].body))
        let calls = try Self.calls(body)
        #expect(calls.count == listed.count)
        #expect(calls.allSatisfy { $0.data == ERC20.balanceOf(owner: try! EVMAddress(Self.owner)) })
        guard case .object(let call)? = FixtureTransport.params(body).first else { Issue.record("sem objeto de chamada"); return }
        #expect(call["to"] == .string(Multicall3.address.checksummed))

        #expect(balance.holdings.count == 2)
        #expect(balance.holdings[0].asset == .native(chain) && balance.holdings[0].amount == BigUInt(1_000_000_000_000_000_000))
        #expect(balance.holdings[1].asset == usdc && balance.holdings[1].amount == BigUInt(5_000_000))
        #expect(!balance.holdings.contains { $0.asset == link })
    }

    @Test("Toda rede EVM le os tokens da lista num lote so: duas chamadas por atualizacao")
    func everyChainFitsOneBatch() {
        for chain in Chain.evmChains {
            let tokens = TokenRegistry.assets(on: chain).filter { $0.kind != .native }.count
            #expect(Multicall3.isDeployed(on: chain), "\(chain.id): sem Multicall3 conferido")
            #expect(tokens <= Multicall3.maxCallsPerBatch, "\(chain.id): \(tokens) tokens passam de um lote")
        }
    }

    @Test("Lote que falha em todos os provedores: fica a moeda nativa, sem erro")
    func batchFailureKeepsNative() async throws {
        let transport = FixtureTransport([{ _, body in
            switch FixtureTransport.method(body) {
            case "eth_getBalance": return rpcResult("\"0x2a\"")
            case "eth_call": throw HTTPClient.Failure.status(503)
            default: return nil
            }
        }])
        let service = BalanceService(client: .shared, transport: transport, evm: ["base": testProviders("rpc-a", "rpc-b")], xrpl: [])
        let balance = try await service.balance(chain: .base, addresses: [Self.owner])
        #expect(balance.holdings == [Holding(asset: .native(.base), amount: BigUInt(42))])
        // Um eth_getBalance e o lote tentado nos dois provedores, nada por token.
        #expect(transport.requests.count == 3)
    }

    @Test("Limite de taxa no primeiro provedor: o lote vai ao segundo")
    func rateLimitFallsBack() async throws {
        let transport = FixtureTransport([{ request, body in
            switch FixtureTransport.method(body) {
            case "eth_getBalance": return rpcResult("\"0x0\"")
            case "eth_call":
                if request.url.host == "rpc-a.test" { return rpcError(code: -32005, message: "rate limit exceeded") }
                let items = try Self.calls(body).map { _ in (true, Self.word(7)) }
                return rpcResult("\"" + (try Self.aggregate3Result(items)) + "\"")
            default: return nil
            }
        }])
        let service = BalanceService(client: .shared, transport: transport, evm: ["arbitrum": testProviders("rpc-a", "rpc-b")], xrpl: [])
        let balance = try await service.balance(chain: .arbitrum, addresses: [Self.owner])
        let tokens = TokenRegistry.assets(on: .arbitrum).filter { $0.kind != .native }
        #expect(balance.holdings.count == 1 + tokens.count)
        #expect(balance.holdings.dropFirst().allSatisfy { $0.amount == BigUInt(7) })
    }

    @Test("Resposta com numero de resultados diferente do de chamadas e recusada inteira")
    func wrongCountRefused() async throws {
        let transport = FixtureTransport([{ _, body in
            switch FixtureTransport.method(body) {
            case "eth_getBalance": return rpcResult("\"0x0\"")
            case "eth_call": return rpcResult("\"" + (try Self.aggregate3Result([(true, Self.word(9))])) + "\"")
            default: return nil
            }
        }])
        let service = BalanceService(client: .shared, transport: transport, evm: ["optimism": testProviders("rpc-a")], xrpl: [])
        let balance = try await service.balance(chain: .optimism, addresses: [Self.owner])
        #expect(balance.holdings.count == 1)
    }

    @Test("Resposta real do Multicall3: a mesma calldata e os mesmos saldos do balanceOf direto")
    func recordedAggregate3() async throws {
        let fixture = try ReaderFixtures.json("evm", "multicall3-aggregate3-saldos")
        let tokens = [
            "0xdAC17F958D2ee523a2206206994597C13D831ec7", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            "0x514910771AF9Ca656af840dff83E8264EcF986CA", "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
            // Uma conta sem codigo (a chamada "da certo" sem retorno) e o proprio Multicall3,
            // que nao tem balanceOf e reverte.
            "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", "0xcA11bde05977b3631167028862bE2a173976CA11",
        ].map { try! EVMAddress($0) }
        let owner = try EVMAddress(Self.owner)
        let batches = Multicall3.balanceBatches(owner: owner, tokens: tokens)
        #expect(batches.count == 1)
        // A calldata gravada foi montada por outro codificador (js-sha3, fora do app).
        #expect(Hex.encode(try Multicall3.aggregate3(batches[0]), prefix: true) == (try fixture.field("request_data", "f").string("f")))

        let transport = FixtureTransport([{ _, body in
            guard FixtureTransport.method(body) == "eth_call" else { return nil }
            return rpcResult("\"" + (try fixture.field("result", "f").string("f")) + "\"")
        }])
        let pool = ProviderPool(testProviders("rpc-a"))
        let amounts = await BalanceService.tokenBalances(chain: .ethereum, owner: owner, tokens: tokens, pool: pool, transport: transport)
        let direct = try fixture.field("direct", "f")
        for (index, token) in tokens.prefix(4).enumerated() {
            let expected = try direct.field(token.checksummed, "direct").string("direct")
            #expect(amounts[index] == BigUInt(decimal: expected), "\(token.checksummed)")
        }
        #expect(amounts[4] == nil)
        #expect(amounts[5] == nil)
        #expect(transport.requests.count == 1)
    }

    // MARK: XRP Ledger

    @Test("XRP Ledger: account_info e account_lines, o RLUSD entra e a linha fora da lista conta como desconhecida")
    func xrplTrustLines() async throws {
        let transport = FixtureTransport([{ _, body in
            switch FixtureTransport.method(body) {
            case "account_info": return try ReaderFixtures.data("xrpl", "account_info-linhas")
            case "account_lines": return try ReaderFixtures.data("xrpl", "account_lines-linhas")
            default: return nil
            }
        }])
        let service = BalanceService(client: .shared, transport: transport, evm: [:], xrpl: testProviders("xrpl-a", "xrpl-b"))
        let balance = try await service.balance(chain: .xrpl, addresses: ["rLoD9U2ghXP2xUYbtML6G6v1p8LhM9mSnc"])
        let rlusd = try #require(TokenRegistry.assets(on: .xrpl).first { $0.symbol == "RLUSD" })
        #expect(balance.accountExists)
        #expect(balance.holdings.first == Holding(asset: .native(.xrpl), amount: BigUInt(4_179_816_000_005)))
        #expect(balance.holdings.contains(Holding(asset: rlusd, amount: BigUInt(9_696_979_559))))
        #expect(balance.holdings.count == 2)
        #expect(balance.unknownTokenCount == 1)  // SOLO, fora da lista
        #expect(transport.requests.count == 2)
    }

    @Test("XRP Ledger: conta inexistente nao pede as linhas")
    func xrplMissingAccount() async throws {
        let transport = FixtureTransport([{ _, body in
            FixtureTransport.method(body) == "account_info" ? try ReaderFixtures.data("xrpl", "account_info-inexistente-rippled") : nil
        }])
        let service = BalanceService(client: .shared, transport: transport, evm: [:], xrpl: testProviders("xrpl-a"))
        let balance = try await service.balance(chain: .xrpl, addresses: ["rrrrrrrrrrrrrrrrrrrrrhoLvTp"])
        #expect(!balance.accountExists)
        #expect(balance.holdings == [Holding(asset: .native(.xrpl), amount: BigUInt())])
        #expect(transport.requests.count == 1)
    }

    @Test("Linhas: saldo negativo (lado do emissor), zero e notacao cientifica")
    func trustLineParsing() throws {
        let usdc = try #require(TokenRegistry.assets(on: .xrpl).first { $0.symbol == "USDC" })
        let json = try StrictJSON.parse(Data("""
        {"lines":[
          {"account":"rGm7WCVp9gb4jZHWTEtGUr4dd74z2XuWhE","currency":"5553444300000000000000000000000000000000","balance":"1.5e1"},
          {"account":"rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De","currency":"524C555344000000000000000000000000000000","balance":"-3"},
          {"account":"rsoLo2S1kiGeCcn6hCUXVrCpGMWLrRrLZz","currency":"534F4C4F00000000000000000000000000000000","balance":"0"},
          {"account":"rGm7WCVp9gb4jZHWTEtGUr4dd74z2XuWhE","currency":"USD","balance":"2"}
        ]}
        """.utf8))
        let (holdings, unknown) = BalanceService.trustLineHoldings(json)
        #expect(holdings == [Holding(asset: usdc, amount: BigUInt(15_000_000))])
        // O "USD" do mesmo emissor nao e o USDC: codigo diferente, fica em "Outros
        // tokens", marcado, com as casas que a carteira usa no XRP Ledger.
        #expect(unknown.count == 1)
        #expect(unknown.first?.asset.symbol == "USD")
        #expect(unknown.first?.asset.origin == .discovered)
        #expect(unknown.first?.amount == BigUInt(2_000_000))
        // Linha de confianca so nasce pelo dono: nada de poeira "sem pedir" aqui.
        #expect(unknown.first?.reasons.contains(.dust) == false)
    }
}
