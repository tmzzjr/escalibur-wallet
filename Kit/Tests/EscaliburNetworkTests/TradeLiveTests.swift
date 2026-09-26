import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra os provedores e os nos reais. So com ESCALIBUR_REDE=1. Cota de verdade, valida,
/// le o estado, simula e monta o plano. **Nao assina e nao transmite nada.**
///
/// A conta e nova, de uma chave derivada de um texto fixo, sem saldo e sem historico.
/// Para a simulacao passar, o teste da saldo a ela so dentro do `eth_simulateV1`
/// (stateOverrides: ETH e o slot 9 do mapa de saldos do USDC FiatToken, conferido contra
/// `balanceOf` de um detentor real na Base e na Arbitrum). Todo o resto e estado real.
///
/// Nao usar a chave da EIP-155 (0x46...46) aqui: o endereco dela (0x9d8A...5A4F) tem, desde
/// algum momento, delegacao EIP-7702 para um sweeper (`eth_getCode` = 0xef0100 8a67...408a
/// na Base, Arbitrum e Ethereum), que repassa todo ETH recebido. A simulacao pega isso e
/// recusa o plano; o teste `sweeper` abaixo mostra.
@Suite("Troca ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct TradeLiveTests {
    typealias S = TradeNetworkSupport

    static let usdc: [String: EVMToken] = [
        "base": TradeNetworkSupport.baseUSDC,
        "arbitrum": TradeNetworkSupport.arbUSDC,
    ]

    static func account() throws -> EVMAccount {
        let key = SecureBytes(capacity: 32)
        key.replaceAll(with: Hash.keccak256(Array("escalibur: conta de teste da troca ao vivo".utf8)))
        defer { key.wipe() }
        return try EVMAccount(path: DerivationPath("m/44'/60'/0'/0/0")!, publicKey: Secp256k1.publicKey(of: key))
    }

    /// Preco de oraculo pelo MarketService, como texto decimal. Sem oraculo, sem checagem.
    static func market(_ intent: TradeIntent) async -> TradeMarketReference {
        guard let quotes = try? await MarketService().quotes(ids: ["usd-coin", "ethereum"], currency: "usd"),
              let usdc = quotes["usd-coin"]?.price, let eth = quotes["ethereum"]?.price
        else { return .none }
        return TradeMarketReference(amountIn: intent.amountIn, sell: intent.sell, buy: intent.buy,
                                    sellPriceUSD: String(format: "%.8f", usdc), buyPriceUSD: String(format: "%.8f", eth))
    }

    static func overrides(owner: EVMAddress, token: EVMToken, amount: BigUInt) -> JSONValue {
        // FiatToken v2.2: `balanceAndBlacklistStates` no slot 9.
        let key = Hash.keccak256([UInt8](repeating: 0, count: 12) + owner.bytes + (BigUInt(9).bigEndianBytes(padTo: 32) ?? []))
        return .object([
            "0x" + Hex.encode(owner.bytes): .object(["balance": .string(BigUInt(decimal: "10000000000000000000")!.hexString)]),
            "0x" + Hex.encode(token.contract.bytes): .object(["stateDiff": .object([
                Hex.encode(key, prefix: true): .string(Hex.encode(amount.bigEndianBytes(padTo: 32)!, prefix: true)),
            ])]),
        ])
    }

    @Test("100 USDC -> ETH na Base e na Arbitrum: todos os provedores cotam, validam, simulam e viram plano", arguments: ["base", "arbitrum"])
    func quoteValidatePlan(chainID: String) async throws {
        let chain = Chain.find(chainID)!
        let token = Self.usdc[chainID]!
        let account = try Self.account()
        let amount = BigUInt(100_000_000)
        let intent = try TradeIntent(owner: account.address, sell: .token(token), buy: .native(chain), amountIn: amount, slippageBps: 50)
        let reader = TradeStateReader()
        let network = try await reader.network(chain: chain, owner: account.address)
        #expect(network.pendingNonces.count >= 2)
        let gasPrice = network.baseFeePerGas + network.priorityFees.normal
        let l1 = try await reader.l1DataFee(chain: chain, calldataSize: 2_000) ?? 0
        let costs = TradeCostModel(gasPriceWei: gasPrice, l1FeePerTransactionWei: l1, nativeToBuy: .identity)
        let market = await Self.market(intent)

        let aggregator = TradeAggregator()
        let set = await aggregator.quote(intent, market: market, costs: costs, useCache: false)
        #expect(!set.ranked.isEmpty)
        // Guaranteed ranking: o primeiro tem o maior liquido do garantido.
        if let first = set.ranked.first { #expect(set.ranked.allSatisfy { $0.netOut <= first.netOut }) }

        // Estado real, com saldo so dentro da simulacao.
        let funded = EVMNetworkState(
            chain: chain, pendingNonces: network.pendingNonces, baseFeePerGas: network.baseFeePerGas,
            priorityFees: network.priorityFees, gasEstimate: 21_000, nativeBalance: BigUInt(decimal: "10000000000000000000")!,
            destinationHasCode: true
        )
        let approveL1 = try await reader.l1DataFee(chain: chain, calldataSize: 68)
        // Cada provedor e recotado na hora de planejar, como o app faz com a escolhida
        // (cotacao com RFQ envelhece em segundos). Quem nao respondeu na rodada tem mais
        // uma chance aqui; so entao conta como falha.
        for provider in TradeProvider.allCases {
            try await Task.sleep(for: .milliseconds(800))  // RPC publico limita taxa
            let quote: ValidatedTradeQuote
            do {
                quote = try await aggregator.requote(provider, intent: intent, market: market, gasPriceWei: gasPrice)
            } catch {
                Issue.record("\(chainID): \(provider.displayName) sem cotacao valida: rodada \(String(describing: set.failures[provider])), recotacao \(error)")
                continue
            }
            let real = try await reader.token(chain: chain, token: token.contract, owner: account.address, spender: quote.spender)
            let request = TradePlanner.simulationRequest(for: quote, currentAllowance: real.allowance)
            let simulations = try await reader.simulate(chain: chain, calls: request.calls,
                                                        stateOverrides: Self.overrides(owner: account.address, token: token, amount: amount))
            let state = TradeChainState(
                network: funded, sellToken: EVMTokenState(contractHasCode: real.contractHasCode, balance: amount, allowance: real.allowance),
                routerHasCode: try await reader.hasCode(chain: chain, quote.to),
                routerPin: try await reader.pin(chain: chain, router: quote.to, query: quote.pinQuery),
                simulations: simulations,
                approveL1DataFee: approveL1,
                swapL1DataFee: try await reader.l1DataFee(chain: chain, calldataSize: quote.data.count),
                approveL1Gas: try await reader.arbitrumL1Gas(chain: chain, to: token.contract, data: ERC20.approve(spender: quote.spender, amount: amount)),
                swapL1Gas: try await reader.arbitrumL1Gas(chain: chain, to: quote.to, data: quote.data)
            )
            do {
                let plan = try TradePlanner.planSwap(walletID: UUID(), account: account, quote: quote, state: state, riskConfirmed: true)
                #expect(plan.transactions.count == 2, "\(quote.provider)")
                #expect(plan.review.lines.contains { $0.label == "Taxa da Escalibur" && $0.value == "Sem taxa da Escalibur" })
                let swap = plan.transactions.last as! EVMTransaction
                #expect(swap.data == quote.data && swap.to == quote.to)
            } catch {
                let reverts = simulations.flatMap { $0.calls.compactMap(\.error) }
                Issue.record("\(chainID): plano da \(quote.provider.displayName) recusado: \(error) \(reverts)")
            }
        }

        // Divisao: com 100 USDC nao deve compensar; o caminho roda de verdade.
        let usd5 = BigUInt(decimal: "2000000000000000")!
        if let split = await aggregator.proposeSplit(set, market: market, costs: costs, minimumGainAbsolute: usd5, force: true) {
            #expect(split.decision.legs.reduce(BigUInt()) { $0 + $1.amountIn } == amount)
        }
    }

    @Test("Redes novas: cada provedor da allowlist cota a moeda nativa por stablecoin e a calldata passa na validacao",
          arguments: [Chain.plasma, .linea, .unichain, .sonic])
    func secondWaveProviders(chain: Chain) async throws {
        let account = try Self.account()
        let asset = try #require(TokenRegistry.assets(on: chain).first { $0.isStablecoin })
        guard case .token(let contract) = asset.kind else { return }
        let token = EVMToken(chain: chain, contract: try EVMAddress(contract), symbol: asset.symbol, decimals: UInt8(asset.decimals))
        // Uns US$ 10 da moeda nativa: 100 XPL, 0,004 ETH, 250 S.
        let amount: BigUInt = switch chain.id {
        case "plasma": BigUInt(decimal: "100000000000000000000")!
        case "sonic": BigUInt(decimal: "250000000000000000000")!
        default: BigUInt(decimal: "4000000000000000")!
        }
        let intent = try TradeIntent(owner: account.address, sell: .native(chain), buy: .token(token), amountIn: amount, slippageBps: 100)
        let network = try await TradeStateReader().network(chain: chain, owner: account.address)
        let gasPrice = network.baseFeePerGas + network.priorityFees.normal
        let aggregator = TradeAggregator()
        for router in TradeAllowlist.routers(on: chain) {
            try await Task.sleep(for: .milliseconds(800))
            do {
                let quote = try await aggregator.requote(router.provider, intent: intent, gasPriceWei: gasPrice)
                #expect(quote.to == router.address, "\(chain.id) \(router.provider)")
                Live.note("\(chain.id): \(router.provider.displayName) garante \(quote.guaranteedOut) \(asset.symbol)")
            } catch let TradeProviderError.refused(_, refusal) {
                // Cotacao que chegou e nao passou na validacao: o provedor nao devia estar na allowlist.
                Issue.record("\(chain.id): \(router.provider.displayName) recusado pela validacao: \(refusal)")
            } catch {
                // Sem resposta (limite de taxa, prazo): nao diz nada sobre a calldata.
                Live.note("\(chain.id): \(router.provider.displayName) sem resposta agora: \(error)")
            }
        }
    }

    @Test("Pins conferidos na cadeia: faceta da LI.FI e implementacao da De¹ nas redes compiladas")
    func pins() async throws {
        let reader = TradeStateReader()
        for chain in [Chain.ethereum, .base, .arbitrum, .optimism, .polygon, .bnb, .plasma, .linea, .unichain, .sonic] {
            for router in TradeAllowlist.routers(on: chain) {
                #expect(try await reader.hasCode(chain: chain, router.address), "\(chain.id) \(router.provider)")
                for query in router.facetQueries {
                    let found = try await reader.pin(chain: chain, router: router.address, query: .call(data: query))
                    #expect(found == router.pin.expected, "\(chain.id) faceta \(Hex.encode(query.prefix(8)))")
                }
                if case .eip1967 = router.pin {
                    let found = try await reader.pin(chain: chain, router: router.address, query: .storage(slot: TradeRouterPin.eip1967ImplementationSlot))
                    #expect(found == router.pin.expected, "\(chain.id) implementacao da De¹")
                }
            }
        }
    }

    @Test("CoW: appData aceito, ordem real consultada e conferida, ordem limite planejada sem enviar")
    func cow() async throws {
        let cow = CoWClient()
        try await cow.registerAppData(.limitOrder, chain: .base)
        // As duas redes da segunda leva que a CoW atende aceitam o mesmo appData.
        try await cow.registerAppData(.limitOrder, chain: .plasma)
        try await cow.registerAppData(.limitOrder, chain: .linea)

        let fixture = try JSONSerialization.jsonObject(with: S.fixture("cow-base-order-limit")) as! [String: Any]
        let uid = Hex.decode(String((fixture["uid"] as! String).dropFirst(2)))!
        let status = try await cow.order(uid: uid, chain: .base)
        #expect(status.status == .fulfilled)
        #expect(status.owner == (try EVMAddress(fixture["owner"] as! String)))
        _ = try await cow.openSellTotal(owner: status.owner, sellToken: status.sellToken, chain: .base)

        let account = try Self.account()
        let reader = TradeStateReader()
        let intent = try CoWLimitOrderIntent(owner: account.address, sell: .token(S.baseUSDC), buy: .native(.base),
                                             sellAmount: 100_000_000, price: CoWLimitPrice("0.001")!)
        let network = try await reader.network(chain: .base, owner: account.address, gasEstimate: 60_000,
                                               l1DataFee: try await reader.l1DataFee(chain: .base, calldataSize: 68),
                                               destinationHasCode: try await reader.hasCode(chain: .base, CoWProtocol.vaultRelayer))
        let funded = EVMNetworkState(chain: .base, pendingNonces: network.pendingNonces, baseFeePerGas: network.baseFeePerGas,
                                     priorityFees: network.priorityFees, gasEstimate: 60_000, l1DataFee: network.l1DataFee,
                                     nativeBalance: BigUInt(decimal: "1000000000000000000")!, destinationHasCode: network.destinationHasCode)
        let real = try await reader.token(chain: .base, token: S.baseUSDC.contract, owner: account.address, spender: CoWProtocol.vaultRelayer)
        let plan = try CoWPlanner.planLimitOrder(
            walletID: UUID(), account: account, intent: intent,
            state: CoWChainState(network: funded, sellToken: EVMTokenState(contractHasCode: real.contractHasCode, balance: 100_000_000, allowance: real.allowance))
        )
        #expect(plan.order.buyAmount == BigUInt(decimal: "100000000000000000")!)
        #expect(plan.uid.count == 56)
        #expect(plan.signingPlan.review.kind == .limitOrder)
    }

    @Test("Segunda camada: a conta da chave da EIP-155 tem sweeper 7702, e a simulacao recusa o plano")
    func sweeper() async throws {
        let account = try TradeCoWClientTests.account()  // 0x9d8A...5A4F
        let code = try await JSONRPC.call(Endpoints.evm["base"]![1].baseURL, method: "eth_getCode",
                                          params: [.string("0x" + Hex.encode(account.address.bytes)), .string("latest")], as: String.self)
        guard code.hasPrefix("0xef0100") else { return }  // delegacao removida: nada a mostrar
        let intent = try TradeIntent(owner: account.address, sell: .token(S.baseUSDC), buy: .native(.base), amountIn: 100_000_000, slippageBps: 50)
        let proposal = try await VeloraClient().propose(TradeQuoteRequest(intent: intent, gasPriceWei: 10_000_000))
        let quote = try TradeValidator.validate(proposal, intent: intent)
        let reader = TradeStateReader()
        let request = TradePlanner.simulationRequest(for: quote, currentAllowance: 0)
        let simulations = try await reader.simulate(chain: .base, calls: request.calls,
                                                    stateOverrides: Self.overrides(owner: account.address, token: S.baseUSDC, amount: 100_000_000))
        let network = try await reader.network(chain: .base, owner: account.address)
        let state = TradeChainState(
            network: EVMNetworkState(chain: .base, pendingNonces: network.pendingNonces, baseFeePerGas: network.baseFeePerGas,
                                     priorityFees: network.priorityFees, gasEstimate: 21_000,
                                     nativeBalance: BigUInt(decimal: "10000000000000000000")!, destinationHasCode: true),
            sellToken: EVMTokenState(contractHasCode: true, balance: 100_000_000, allowance: 0), routerHasCode: true, routerPin: nil,
            simulations: simulations, approveL1DataFee: 1_000_000_000, swapL1DataFee: 1_000_000_000
        )
        // O ETH chega ao dono e sai no mesmo passo, para o sweeper: a guarda da simulacao
        // ve um Transfer nativo saindo da conta e recusa.
        #expect(throws: TradeRefusal.simulationUnexpectedTransfer(token: try EVMAddress("0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"))) {
            try TradePlanner.planSwap(walletID: UUID(), account: account, quote: quote, state: state)
        }
    }
}
