import EscaliburChains
import EscaliburCore
import Foundation

// A leitura do estado publico que o plano de troca e a ordem limite precisam.
//
// Regras (docs/seguranca.md 4.3, 5.5):
// - todo RPC tem o `eth_chainId` conferido contra a constante compilada antes do
//   primeiro uso;
// - nonce pending de duas fontes (o plano exige que concordem, ou que a fila local do
//   app explique a diferenca);
// - baseFee e gorjetas: a mediana de duas fontes; saldo e allowance: o menor de duas
//   (o plano recusa se nao cobre, em vez de apostar no maior);
// - codigo do router e implementacao/faceta fixada: duas fontes concordando;
// - simulacao `eth_simulateV1` com `traceTransfers` em duas fontes distintas; cada uma
//   e conferida em EscaliburChains, e o gas vem dela;
// - OP e Base: taxa L1 pelo `getL1FeeUpperBound` do GasPriceOracle; Arbitrum: a parcela
//   L1 em gas pelo NodeInterface, que a simulacao nao conta.

public enum TradeStateError: Error, Equatable, Sendable {
    case wrongChainID(String)
    case notEnoughSources(String)
    case sourcesDisagree(String)
    case badResponse(String)
    case simulationUnavailable
}

public actor TradeStateReader {
    let client: HTTPClient
    private var verified = Set<String>()

    /// GasPriceOracle das redes OP Stack.
    static let gasPriceOracle = try! EVMAddress("0x420000000000000000000000000000000000000f")
    static let getL1FeeUpperBound = try! ABIFunction("getL1FeeUpperBound(uint256)")
    /// NodeInterface da Arbitrum (virtual, so por eth_call).
    static let nodeInterface = try! EVMAddress("0x00000000000000000000000000000000000000c8")
    static let gasEstimateL1Component = try! ABIFunction("gasEstimateL1Component(address,bool,bytes)")
    /// Bytes que uma transacao tipo 2 tem alem da calldata (nonce, taxas, gas, to, value,
    /// chainId, lista vazia), com folga. Entra no limite superior da taxa L1.
    static let transactionOverhead = 150

    public init(client: HTTPClient = .shared) {
        self.client = client
    }

    // MARK: RPC

    func rpc<T: Decodable & Sendable>(_ provider: ProviderPool.Provider, chain: Chain, _ method: String, _ params: [JSONValue], as type: T.Type) async throws -> T {
        let key = chain.id + "|" + provider.baseURL.absoluteString
        if !verified.contains(key) {
            let id = try await JSONRPC.call(provider.baseURL, method: "eth_chainId", params: [], as: String.self, client: client)
            guard let value = BigUInt(hex: id), value == BigUInt(chain.evmChainID ?? 0) else { throw TradeStateError.wrongChainID(provider.name) }
            verified.insert(key)
        }
        return try await JSONRPC.call(provider.baseURL, method: method, params: params, as: type, client: client)
    }

    /// Pergunta a varios provedores em paralelo e devolve as `count` primeiras respostas
    /// de fontes distintas.
    func collect<T: Sendable>(_ providers: [ProviderPool.Provider], count: Int, what: String,
                              _ operation: @escaping @Sendable (ProviderPool.Provider) async throws -> T) async throws -> [(String, T)] {
        var answers = [(String, T)]()
        var errors = [String]()
        await withTaskGroup(of: (String, Result<T, Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.name, .success(try await operation(provider))) } catch { return (provider.name, .failure(error)) }
                }
            }
            for await (name, result) in group {
                switch result {
                case .success(let value): answers.append((name, value))
                case .failure(let error): errors.append("\(name): \(error)")
                }
                if answers.count >= count { group.cancelAll(); break }
            }
        }
        // Nos publicos limitam taxa (429): mais tres tentativas, com pausa crescente, nos
        // que falharam. So leitura; nada aqui transmite.
        for pause in [500, 1_500, 3_000] where answers.count < count {
            try? await Task.sleep(for: .milliseconds(pause))
            for provider in providers where !answers.contains(where: { $0.0 == provider.name }) {
                if let value = try? await operation(provider) { answers.append((provider.name, value)) }
                if answers.count >= count { break }
            }
        }
        guard answers.count >= count else { throw TradeStateError.notEnoughSources(what + " (" + errors.joined(separator: "; ") + ")") }
        return answers
    }

    static func hex(_ text: String?) throws -> BigUInt {
        guard let text, let value = BigUInt(hex: text) else { throw TradeStateError.badResponse("hex") }
        return value
    }

    static func data(_ bytes: [UInt8]) -> JSONValue { .string(Hex.encode(bytes, prefix: true)) }
    static func address(_ address: EVMAddress) -> JSONValue { .string("0x" + Hex.encode(address.bytes)) }

    /// Os RPCs de leitura da rede e, depois, os de simulacao que nao estao na lista (mais
    /// fontes para quando os publicos devolvem 429).
    func readProviders(_ chain: Chain) -> [ProviderPool.Provider] {
        let base = Endpoints.evm[chain.id] ?? []
        let known = Set(base.map(\.baseURL))
        return base + (Endpoints.tradeSimulation[chain.id] ?? []).filter { !known.contains($0.baseURL) }
    }

    // MARK: Estado da rede

    /// Nonce, taxa e saldo nativo. `gasEstimate`, `l1DataFee` e `destinationHasCode` vem
    /// preenchidos com o que se passa; o plano deriva cada transacao a partir daqui.
    public func network(chain: Chain, owner: EVMAddress, localNextNonce: UInt64? = nil, gasEstimate: UInt64 = 21_000,
                        l1DataFee: BigUInt? = nil, destinationHasCode: Bool = true) async throws -> EVMNetworkState {
        let providers = readProviders(chain)
        let ownerValue = Self.address(owner)
        async let nonces = collect(providers, count: 2, what: "nonce") { provider in
            let text = try await self.rpc(provider, chain: chain, "eth_getTransactionCount", [ownerValue, .string("pending")], as: String.self)
            guard let value = try Self.hex(text).uint64 else { throw TradeStateError.badResponse("nonce") }
            return value
        }
        async let balances = collect(providers, count: 2, what: "saldo") { provider in
            try Self.hex(try await self.rpc(provider, chain: chain, "eth_getBalance", [ownerValue, .string("latest")], as: String.self))
        }
        async let histories = collect(providers, count: 2, what: "taxa") { provider in
            try await self.rpc(provider, chain: chain, "eth_feeHistory",
                               [.string("0xa"), .string("latest"), .array([.number(25), .number(50), .number(75)])], as: JSONValue.self)
        }
        let nonceValues = try await nonces.map(\.1)
        let balance = try await balances.map(\.1).min() ?? 0
        // Cada fonte da a sua baseFee e as suas gorjetas (mediana dos 10 blocos); o plano
        // leva a mediana das fontes (com duas, a media), nunca o numero de uma so
        // (auditoria 2, B1).
        var baseFees = [BigUInt]()
        var sourceTips: [[BigUInt]] = [[], [], []]
        for (_, history) in try await histories {
            guard let fees = history["baseFeePerGas"]?.arrayValue, let next = fees.last?.stringValue else {
                throw TradeStateError.badResponse("feeHistory")
            }
            baseFees.append(try Self.hex(next))
            var tips: [[BigUInt]] = [[], [], []]
            for block in history["reward"]?.arrayValue ?? [] {
                for column in 0..<3 {
                    if let text = block[column]?.stringValue, let value = BigUInt(hex: text) { tips[column].append(value) }
                }
            }
            for column in 0..<3 { sourceTips[column].append(Self.median(tips[column])) }
        }
        return EVMNetworkState(
            chain: chain, pendingNonces: nonceValues, localNextNonce: localNextNonce, baseFeePerGas: Self.median(baseFees),
            priorityFees: EVMPriorityFees(slow: Self.median(sourceTips[0]), normal: Self.median(sourceTips[1]), fast: Self.median(sourceTips[2])),
            gasEstimate: gasEstimate, l1DataFee: l1DataFee, nativeBalance: balance, destinationHasCode: destinationHasCode
        )
    }

    /// A mediana; com numero par de valores, a media dos dois do meio, para cima.
    static func median(_ values: [BigUInt]) -> BigUInt {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle] + 1) / 2
    }

    /// Codigo no endereco, em duas fontes concordando.
    public func hasCode(chain: Chain, _ address: EVMAddress) async throws -> Bool {
        let answers = try await collect(readProviders(chain), count: 2, what: "codigo") { provider in
            let code = try await self.rpc(provider, chain: chain, "eth_getCode", [Self.address(address), .string("latest")], as: String.self)
            return code.count > 2
        }
        guard Set(answers.map(\.1)).count == 1 else { throw TradeStateError.sourcesDisagree("codigo") }
        return answers[0].1
    }

    /// Saldo e allowance do token: o menor de duas fontes.
    public func token(chain: Chain, token: EVMAddress, owner: EVMAddress, spender: EVMAddress) async throws -> EVMTokenState {
        async let code = hasCode(chain: chain, token)
        let answers = try await collect(readProviders(chain), count: 2, what: "token") { provider in
            let call = { (data: [UInt8]) async throws -> BigUInt in
                let text = try await self.rpc(provider, chain: chain, "eth_call",
                                              [.object(["to": Self.address(token), "data": Self.data(data)]), .string("latest")], as: String.self)
                guard let bytes = Hex.decode(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text) else { throw TradeStateError.badResponse("eth_call") }
                return try ERC20.decodeUInt256(bytes)
            }
            let balance = try await call(ERC20.balanceOf(owner: owner))
            let allowance = try await call(ERC20.allowance(owner: owner, spender: spender))
            return [balance, allowance]
        }
        let balance = answers.map { $0.1[0] }.min() ?? 0
        let allowance = answers.map { $0.1[1] }.min() ?? 0
        return EVMTokenState(contractHasCode: try await code, balance: balance, allowance: allowance)
    }

    // MARK: Pin do router

    /// O que a cadeia diz para a consulta de pin, com duas fontes concordando.
    public func pin(chain: Chain, router: EVMAddress, query: TradePinQuery) async throws -> EVMAddress? {
        switch query {
        case .none:
            return nil
        case .storage(let slot):
            let answers = try await collect(readProviders(chain), count: 2, what: "pin") { provider in
                try await self.rpc(provider, chain: chain, "eth_getStorageAt",
                                   [Self.address(router), Self.data(slot), .string("latest")], as: String.self).lowercased()
            }
            return try Self.agreedAddress(answers.map(\.1))
        case .call(let data):
            let answers = try await collect(readProviders(chain), count: 2, what: "pin") { provider in
                try await self.rpc(provider, chain: chain, "eth_call",
                                   [.object(["to": Self.address(router), "data": Self.data(data)]), .string("latest")], as: String.self).lowercased()
            }
            return try Self.agreedAddress(answers.map(\.1))
        }
    }

    static func agreedAddress(_ words: [String]) throws -> EVMAddress {
        guard Set(words).count == 1, let word = words.first,
              let bytes = Hex.decode(word.hasPrefix("0x") ? String(word.dropFirst(2)) : word), bytes.count == 32,
              bytes.prefix(12).allSatisfy({ $0 == 0 }), let address = EVMAddress(bytes: Array(bytes.suffix(20)))
        else { throw TradeStateError.sourcesDisagree("pin") }
        return address
    }

    // MARK: Simulacao

    /// `eth_simulateV1` das chamadas pedidas, em duas fontes distintas.
    public func simulate(chain: Chain, calls: [TradeSimulationRequest.Call]) async throws -> [TradeSimulation] {
        try await simulate(chain: chain, calls: calls, stateOverrides: nil)
    }

    /// `stateOverrides` so existe para os testes ao vivo darem saldo a conta de teste; o
    /// app nunca passa (a simulacao tem de ver o estado real).
    func simulate(chain: Chain, calls: [TradeSimulationRequest.Call], stateOverrides: JSONValue?) async throws -> [TradeSimulation] {
        let providers = Endpoints.tradeSimulation[chain.id] ?? []
        guard providers.count >= 2 else { throw TradeStateError.simulationUnavailable }
        var block: [String: JSONValue] = ["calls": .array(calls.map { call in
            .object([
                "from": Self.address(call.from), "to": Self.address(call.to),
                "value": .string(call.value.hexString), "data": Self.data(call.data),
            ])
        })]
        if let stateOverrides { block["stateOverrides"] = stateOverrides }
        let payload: JSONValue = .object([
            "blockStateCalls": .array([.object(block)]),
            "traceTransfers": .bool(true),
            "validation": .bool(false),
        ])
        let answers = try await collect(providers, count: 2, what: "simulacao") { provider in
            let result = try await self.rpc(provider, chain: chain, "eth_simulateV1", [payload, .string("latest")], as: JSONValue.self)
            return try Self.parseSimulation(result, source: provider.name)
        }
        return answers.map(\.1)
    }

    static func parseSimulation(_ result: JSONValue, source: String) throws -> TradeSimulation {
        guard let block = result[0], let calls = block["calls"]?.arrayValue else { throw TradeStateError.badResponse("simulacao") }
        return TradeSimulation(source: source, calls: try calls.map { call in
            guard let status = call["status"]?.stringValue, let gas = call["gasUsed"]?.stringValue,
                  let gasUsed = BigUInt(hex: gas)?.uint64
            else { throw TradeStateError.badResponse("simulacao") }
            let logs = try (call["logs"]?.arrayValue ?? []).map { log -> TradeSimulatedLog in
                guard let address = log["address"]?.stringValue, let bytes = Hex.decode(String(address.dropFirst(2))),
                      let contract = EVMAddress(bytes: bytes), let data = log["data"]?.stringValue,
                      let raw = Hex.decode(String(data.dropFirst(2)))
                else { throw TradeStateError.badResponse("log") }
                let topics = (log["topics"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap { Hex.decode(String($0.dropFirst(2))) } }
                return TradeSimulatedLog(address: contract, topics: topics, data: raw)
            }
            return TradeSimulatedCall(success: status == "0x1", gasUsed: gasUsed, logs: logs, error: call["error"]?["message"]?.stringValue)
        })
    }

    // MARK: Parcelas L1

    /// OP e Base: `getL1FeeUpperBound(tamanho)`, o maior de duas fontes.
    public func l1DataFee(chain: Chain, calldataSize: Int) async throws -> BigUInt? {
        guard EVMFeeProfile.for(chain)?.chargesL1DataFee == true else { return nil }
        let data = try Self.getL1FeeUpperBound.encodeCall([.uint(BigUInt(calldataSize + Self.transactionOverhead))])
        let answers = try await collect(readProviders(chain), count: 2, what: "taxa L1") { provider in
            try Self.hex(try await self.rpc(provider, chain: chain, "eth_call",
                                            [.object(["to": Self.address(Self.gasPriceOracle), "data": Self.data(data)]), .string("latest")],
                                            as: String.self))
        }
        return answers.map(\.1).max()
    }

    /// Arbitrum: a parcela L1 em unidades de gas (NodeInterface.gasEstimateL1Component).
    public func arbitrumL1Gas(chain: Chain, to: EVMAddress, data: [UInt8]) async throws -> UInt64 {
        guard chain.evmChainID == 42161 else { return 0 }
        let call = try Self.gasEstimateL1Component.encodeCall([.address(to), .bool(false), .bytes(data)])
        let answers = try await collect(readProviders(chain), count: 1, what: "gas L1") { provider in
            let text = try await self.rpc(provider, chain: chain, "eth_call",
                                          [.object(["to": Self.address(Self.nodeInterface), "data": Self.data(call)]), .string("latest")],
                                          as: String.self)
            guard let bytes = Hex.decode(String(text.dropFirst(2))),
                  let values = try? ABI.decode([.uint(64), .uint256, .uint256], from: bytes),
                  let gas = values.first?.uintValue?.uint64
            else { throw TradeStateError.badResponse("NodeInterface") }
            return gas
        }
        return answers.map(\.1).max() ?? 0
    }

    // MARK: Troca

    /// Tudo o que `TradePlanner.planSwap` precisa para esta cotacao.
    public func read(for quote: ValidatedTradeQuote, localNextNonce: UInt64? = nil) async throws -> TradeChainState {
        let intent = quote.intent
        let chain = intent.chain
        async let network = network(chain: chain, owner: intent.owner, localNextNonce: localNextNonce)
        async let routerCode = hasCode(chain: chain, quote.to)
        async let pinned = pin(chain: chain, router: quote.to, query: quote.pinQuery)
        var tokenState: EVMTokenState?
        if let token = intent.sell.contract {
            tokenState = try await self.token(chain: chain, token: token, owner: intent.owner, spender: quote.spender)
        }
        let request = TradePlanner.simulationRequest(for: quote, currentAllowance: tokenState?.allowance)
        async let simulations = simulate(chain: chain, calls: request.calls)
        let approveData = ERC20.approve(spender: quote.spender, amount: intent.amountIn)
        async let approveL1 = l1DataFee(chain: chain, calldataSize: approveData.count)
        async let swapL1 = l1DataFee(chain: chain, calldataSize: quote.data.count)
        var approveL1Gas: UInt64 = 0
        if let token = intent.sell.contract, chain.evmChainID == 42161 {
            approveL1Gas = try await arbitrumL1Gas(chain: chain, to: token, data: approveData)
        }
        let swapL1Gas = try await arbitrumL1Gas(chain: chain, to: quote.to, data: quote.data)
        return TradeChainState(
            network: try await network, sellToken: tokenState, routerHasCode: try await routerCode, routerPin: try await pinned,
            simulations: try await simulations, approveL1DataFee: try await approveL1, swapL1DataFee: try await swapL1,
            approveL1Gas: approveL1Gas, swapL1Gas: swapL1Gas
        )
    }

    // MARK: Ordem limite

    /// O estado de `CoWPlanner.planLimitOrder`. `openOrdersSellTotal` vem do registro
    /// local e de `CoWClient.openOrders`.
    public func readCoW(intent: CoWLimitOrderIntent, openOrdersSellTotal: BigUInt = 0, localNextNonce: UInt64? = nil) async throws -> CoWChainState {
        let chain = intent.chain
        guard let sellToken = intent.orderSellToken else { throw TradeStateError.badResponse("rede sem CoW") }
        async let relayerCode = hasCode(chain: chain, CoWProtocol.vaultRelayer)
        let tokenState = try await token(chain: chain, token: sellToken.contract, owner: intent.owner, spender: CoWProtocol.vaultRelayer)
        let total = openOrdersSellTotal + intent.sellAmount
        let approveData = ERC20.approve(spender: CoWProtocol.vaultRelayer, amount: total)
        let wrapValue = intent.sell.isNative ? intent.sellAmount : 0

        // Gas: simulacao quando a rede tem (approve a partir da allowance atual, com
        // approve(0) antes no USDT, e o deposit); sem simulacao, eth_estimateGas.
        var calls = [TradeSimulationRequest.Call]()
        let current = tokenState.allowance ?? 0
        if current < total {
            if EVMPlanner.requiresZeroFirstApproval(sellToken), !current.isZero {
                calls.append(.init(from: intent.owner, to: sellToken.contract, value: 0, data: ERC20.approve(spender: CoWProtocol.vaultRelayer, amount: 0)))
            }
            calls.append(.init(from: intent.owner, to: sellToken.contract, value: 0, data: approveData))
        }
        let depositData = try TradeWire.depositCall()
        if intent.sell.isNative {
            calls.append(.init(from: intent.owner, to: sellToken.contract, value: wrapValue, data: depositData))
        }
        var approveGas: UInt64 = 60_000
        var wrapGas: UInt64?
        if !calls.isEmpty {
            let gas = try await gasUsed(chain: chain, calls: calls)
            let approveCount = calls.count - (intent.sell.isNative ? 1 : 0)
            if approveCount > 0 { approveGas = gas.prefix(approveCount).max() ?? approveGas }
            if intent.sell.isNative { wrapGas = gas.last }
        }
        let approveL1Gas = try await arbitrumL1Gas(chain: chain, to: sellToken.contract, data: approveData)
        let network = try await network(chain: chain, owner: intent.owner, localNextNonce: localNextNonce,
                                        gasEstimate: approveGas + approveL1Gas,
                                        l1DataFee: try await l1DataFee(chain: chain, calldataSize: approveData.count),
                                        destinationHasCode: try await relayerCode)
        var wrapL1: BigUInt?
        if intent.sell.isNative {
            wrapL1 = try await l1DataFee(chain: chain, calldataSize: depositData.count)
            wrapGas = (wrapGas ?? 0) + (try await arbitrumL1Gas(chain: chain, to: sellToken.contract, data: depositData))
        }
        return CoWChainState(network: network, sellToken: tokenState, wrapGasEstimate: wrapGas, wrapL1DataFee: wrapL1,
                             openOrdersSellTotal: openOrdersSellTotal)
    }

    /// O estado do cancelamento na cadeia de uma ordem da CoW: `invalidateOrder(uid)` no
    /// GPv2Settlement, com o gas medido da chamada exata e a taxa L1 dela.
    public func readCancellation(chain: Chain, owner: EVMAddress, uid: [UInt8], localNextNonce: UInt64? = nil) async throws -> EVMNetworkState {
        let data = try CoWProtocol.invalidateOrderCall(uid: uid)
        let gas = try await gasUsed(chain: chain, calls: [.init(from: owner, to: CoWProtocol.settlement, value: 0, data: data)]).first ?? 0
        let l1Gas = try await arbitrumL1Gas(chain: chain, to: CoWProtocol.settlement, data: data)
        return try await network(
            chain: chain, owner: owner, localNextNonce: localNextNonce, gasEstimate: gas + l1Gas,
            l1DataFee: try await l1DataFee(chain: chain, calldataSize: data.count), destinationHasCode: true
        )
    }

    /// Gas de cada chamada: pela simulacao (duas fontes, o menor) ou, sem ela, por
    /// `eth_estimateGas` chamada a chamada (duas fontes, o menor). Uma fonte que infla o
    /// gas nao sobe a taxa maxima; o plano soma 20% de folga (auditoria 2, B1).
    func gasUsed(chain: Chain, calls: [TradeSimulationRequest.Call]) async throws -> [UInt64] {
        if (Endpoints.tradeSimulation[chain.id] ?? []).count >= 2 {
            let simulations = try await simulate(chain: chain, calls: calls)
            var gas = [UInt64](repeating: .max, count: calls.count)
            for simulation in simulations {
                guard simulation.calls.count == calls.count, simulation.calls.allSatisfy(\.success) else {
                    throw TradeStateError.badResponse("simulacao reverteu")
                }
                for (index, call) in simulation.calls.enumerated() { gas[index] = min(gas[index], call.gasUsed) }
            }
            return gas
        }
        var out = [UInt64]()
        for call in calls {
            let answers = try await collect(readProviders(chain), count: 2, what: "estimateGas") { provider in
                try Self.hex(try await self.rpc(provider, chain: chain, "eth_estimateGas", [.object([
                    "from": Self.address(call.from), "to": Self.address(call.to),
                    "value": .string(call.value.hexString), "data": Self.data(call.data),
                ])], as: String.self))
            }
            guard let gas = answers.compactMap(\.1.uint64).min(), answers.count >= 2 else { throw TradeStateError.badResponse("estimateGas") }
            out.append(gas)
        }
        return out
    }
}

extension TradeWire {
    /// `deposit()` do token embrulhado.
    static func depositCall() throws -> [UInt8] {
        try ABIFunction("deposit()").selector
    }
}
