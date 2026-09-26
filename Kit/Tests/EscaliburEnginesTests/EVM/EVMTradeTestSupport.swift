@testable import EscaliburChains
import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburEngines
@testable import EscaliburNetwork

/// Apoio dos testes da troca EVM.
///
/// As cotacoes sao as respostas reais dos quatro provedores gravadas em
/// Fixtures/evm/troca (100 USDC -> ETH na Base, dono 0x9d8A...5A4F), lidas pelos clientes
/// reais e entregues ao `TradeAggregator` real, que valida e ranqueia. O estado da cadeia
/// e sintetico e dito aqui: nonce 7, baseFee 0,005 gwei, gorjeta 0,001 gwei, taxa L1 de
/// 20 gwei por transacao, e duas simulacoes honestas de fontes diferentes.
enum EVMTradeFixtures {
    static let amount = BigUInt(100_000_000)
    static let usdc = TokenRegistry.find(chainID: "base", contract: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")!
    static let usdcToken = EVMToken(chain: .base, contract: try! EVMAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"), symbol: "USDC", decimals: 6)
    static let l1Fee = BigUInt(20_000_000_000)

    static func proposals() throws -> [TradeProposal] {
        [
            try VeloraClient.parse(EVMFixtures.trade("velora-base-usdc-eth")),
            try KyberSwapClient.parse(routes: EVMFixtures.trade("kyber-base-usdc-eth-routes"), build: EVMFixtures.trade("kyber-base-usdc-eth-build")),
            try LiFiClient.parse(EVMFixtures.trade("lifi-base-usdc-eth")),
            try De1Client.parse(EVMFixtures.trade("de1-base-usdc-eth")),
        ]
    }

    static func intent(amount: BigUInt = amount) throws -> TradeIntent {
        let owner = try EVMAddress(EVMTestAccounts.testAccount(on: .base).address)
        return try TradeIntent(owner: owner, sell: .token(usdcToken), buy: .native(.base), amountIn: amount, slippageBps: 50)
    }

    static func request(amount: BigUInt = amount) throws -> TradeRequest {
        TradeRequest(walletID: UUID(), chain: .base, account: try EVMTestAccounts.testAccount(on: .base), sell: usdc,
                     buy: .native(.base), amountIn: amount, slippageBasisPoints: 50)
    }

    /// A mesma cotacao validada que o agregador produz, para o teste saber o esperado.
    static func validated(_ provider: TradeProvider) throws -> ValidatedTradeQuote {
        let proposal = try #require(try proposals().first { $0.provider == provider })
        return try TradeValidator.validate(proposal, intent: intent())
    }

    static func network(localNextNonce: UInt64? = nil, gas: UInt64 = 21_000, l1: BigUInt? = nil,
                        balance: BigUInt = BigUInt(decimal: "1000000000000000000")!) -> EVMNetworkState {
        EVMNetworkState(
            chain: .base, pendingNonces: [7, 7], localNextNonce: localNextNonce, baseFeePerGas: 5_000_000,
            priorityFees: EVMPriorityFees(slow: 1_000_000, normal: 1_000_000, fast: 2_000_000), gasEstimate: gas,
            l1DataFee: l1, nativeBalance: balance, destinationHasCode: true
        )
    }

    // MARK: Simulacao sintetica

    static let transferTopic = Hash.keccak256(Array("Transfer(address,address,uint256)".utf8))
    static let approvalTopic = Hash.keccak256(Array("Approval(address,address,uint256)".utf8))
    static let nativePseudoToken = EVMAddress(bytes: [UInt8](repeating: 0xEE, count: 20))!

    static func topic(_ address: EVMAddress) -> [UInt8] { [UInt8](repeating: 0, count: 12) + address.bytes }
    static func word(_ value: BigUInt) -> [UInt8] { value.bigEndianBytes(padTo: 32)! }

    /// O que um no honesto devolveria: o approve exato e a troca, com o vendido saindo do
    /// dono e o comprado entrando.
    static func simulation(_ quote: ValidatedTradeQuote, allowance: BigUInt?, source: String, success: Bool = true) -> TradeSimulation {
        let intent = quote.intent
        var calls = [TradeSimulatedCall]()
        for value in TradePlanner.approvals(for: quote, currentAllowance: allowance) {
            calls.append(TradeSimulatedCall(success: true, gasUsed: 46_000, logs: [
                TradeSimulatedLog(address: intent.sell.contract!, topics: [approvalTopic, topic(intent.owner), topic(quote.spender)], data: word(value)),
            ]))
        }
        let sell = intent.sell.contract ?? nativePseudoToken
        let buy = intent.buy.contract ?? nativePseudoToken
        calls.append(TradeSimulatedCall(success: success, gasUsed: 310_000, logs: [
            TradeSimulatedLog(address: sell, topics: [transferTopic, topic(intent.owner), topic(quote.to)], data: word(intent.amountIn)),
            TradeSimulatedLog(address: buy, topics: [transferTopic, topic(quote.to), topic(intent.owner)], data: word(quote.expectedOut)),
        ]))
        return TradeSimulation(source: source, calls: calls)
    }
}

/// Um provedor que devolve a proposta gravada para o valor gravado, e "sem rota" para
/// qualquer outro (as fracoes da divisao).
struct RecordedQuoteSource: TradeQuoteSource {
    let provider: TradeProvider
    let proposal: TradeProposal
    let amountIn: BigUInt
    let counter: EVMCallCounter

    func propose(_ request: TradeQuoteRequest) async throws -> TradeProposal {
        await counter.add(provider.rawValue)
        guard request.intent.amountIn == amountIn else { throw TradeProviderError.noRoute(provider) }
        return proposal
    }
}

actor EVMCallCounter {
    private(set) var counts: [String: Int] = [:]
    func add(_ key: String) { counts[key, default: 0] += 1 }
    func count(_ key: String) -> Int { counts[key] ?? 0 }
}

/// O estado da cadeia para a troca, sintetico e configuravel.
actor FakeTradeChain: EVMTradeChainReading {
    var tokenBalance: BigUInt
    var allowance: BigUInt
    var failingSimulationSource: String?
    private(set) var reads: [(provider: TradeProvider, localNextNonce: UInt64?)] = []

    init(tokenBalance: BigUInt = BigUInt(1_000_000_000), allowance: BigUInt = 0, failingSimulationSource: String? = nil) {
        self.tokenBalance = tokenBalance
        self.allowance = allowance
        self.failingSimulationSource = failingSimulationSource
    }

    func network(chain: Chain, owner: EVMAddress, localNextNonce: UInt64?, gasEstimate: UInt64, l1DataFee: BigUInt?,
                 destinationHasCode: Bool) async throws -> EVMNetworkState {
        EVMTradeFixtures.network(localNextNonce: localNextNonce, gas: gasEstimate, l1: l1DataFee)
    }

    func l1DataFee(chain: Chain, calldataSize: Int) async throws -> BigUInt? { EVMTradeFixtures.l1Fee }

    func token(chain: Chain, token: EVMAddress, owner: EVMAddress, spender: EVMAddress) async throws -> EVMTokenState {
        EVMTokenState(contractHasCode: true, balance: tokenBalance, allowance: allowance)
    }

    func read(for quote: ValidatedTradeQuote, localNextNonce: UInt64?) async throws -> TradeChainState {
        reads.append((quote.provider, localNextNonce))
        let simulations = ["publicnode", "drpc"].map {
            EVMTradeFixtures.simulation(quote, allowance: allowance, source: $0, success: $0 != failingSimulationSource)
        }
        return TradeChainState(
            network: EVMTradeFixtures.network(localNextNonce: localNextNonce),
            sellToken: EVMTokenState(contractHasCode: true, balance: tokenBalance, allowance: allowance),
            routerHasCode: true, routerPin: quote.router.pin.expected, simulations: simulations,
            approveL1DataFee: EVMTradeFixtures.l1Fee, swapL1DataFee: EVMTradeFixtures.l1Fee
        )
    }

    func readCoW(intent: CoWLimitOrderIntent, openOrdersSellTotal: BigUInt, localNextNonce: UInt64?) async throws -> CoWChainState {
        CoWChainState(
            network: EVMTradeFixtures.network(localNextNonce: localNextNonce, gas: 60_000, l1: EVMTradeFixtures.l1Fee),
            sellToken: EVMTokenState(contractHasCode: true, balance: tokenBalance, allowance: allowance),
            wrapGasEstimate: intent.sell.isNative ? 30_000 : nil, wrapL1DataFee: intent.sell.isNative ? EVMTradeFixtures.l1Fee : nil,
            openOrdersSellTotal: openOrdersSellTotal
        )
    }
}

/// A CoW sem rede. O envio e o cancelamento passam pelas conferencias reais do
/// `CoWClient` (assinatura recuperando o dono sobre o digesto local) antes de responder.
actor FakeCoW: EVMCoWService {
    var openTotal: BigUInt
    private(set) var registered: [CoWAppData] = []
    private(set) var submitted: [[UInt8]] = []
    private(set) var cancelled: [(uids: [[UInt8]], owner: EVMAddress)] = []

    init(openTotal: BigUInt = 0) {
        self.openTotal = openTotal
    }

    func registerAppData(_ appData: CoWAppData, chain: Chain) async throws {
        registered.append(appData)
    }

    func submit(_ plan: CoWLimitOrderPlan, signature: SignedTransaction) async throws -> [UInt8] {
        _ = try CoWClient.submissionBody(plan, signature: signature)
        submitted.append(plan.uid)
        return plan.uid
    }

    func openSellTotal(owner: EVMAddress, sellToken: EVMAddress, chain: Chain) async throws -> BigUInt { openTotal }

    func cancel(uids: [[UInt8]], chain: Chain, owner: EVMAddress, signature: SignedTransaction) async throws {
        let typed = try CoWPlanner.cancellationTypedData(chain: chain, uids: uids)
        try CoWClient.checkSignature(signature, digest: try typed.signingDigest(), owner: owner)
        cancelled.append((uids, owner))
    }
}

struct FakeOracle: EVMPriceOracle {
    let prices: [String: String]?
    /// Demora da resposta, para o caso da rede lenta entre o inicio do plano e a recotacao.
    var delay: Duration = .zero

    func usdPrices(_ ids: [String]) async throws -> [String: String] {
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let prices else { throw HTTPClient.Failure.offline }
        return prices
    }
}

enum EVMTradeHarness {
    /// A Base sem rede: chainId, transmissao que devolve o hash dos bytes recebidos e o
    /// recibo gravado (status 1) para acompanhar a autorizacao da ordem limite.
    static func baseTransport(receiptStatus: String = "0x1") throws -> EVMFixtureTransport {
        let chainID = try EVMFixtures.data("eth_chainId-base")
        let head = try EVMFixtures.data("eth_blockNumber-ethereum")
        let receipt = String(decoding: try EVMFixtures.data("eth_getTransactionReceipt-binance8"), as: UTF8.self)
            .replacingOccurrences(of: "\"status\":\"0x1\"", with: "\"status\":\"\(receiptStatus)\"")
        return EVMFixtureTransport([{ call in
            switch call.method {
            case "eth_chainId": return chainID
            case "eth_blockNumber": return head
            case "eth_getTransactionReceipt": return Data(receipt.utf8)
            case "eth_sendRawTransaction":
                guard let raw = call.params.first as? String, let bytes = Hex.decode(raw) else { return nil }
                return EVMFixtures.result("\"\(Hex.encode(Hash.keccak256(bytes), prefix: true))\"")
            default: return nil
            }
        }])
    }

    static func sources(_ counter: EVMCallCounter, proposals: [TradeProposal]? = nil) throws -> [any TradeQuoteSource] {
        try (proposals ?? EVMTradeFixtures.proposals()).map {
            RecordedQuoteSource(provider: $0.provider, proposal: $0, amountIn: EVMTradeFixtures.amount, counter: counter)
        }
    }

    static func engine(
        chain: Chain = .base, state: FakeTradeChain = FakeTradeChain(), cow: FakeCoW = FakeCoW(), prices: [String: String]? = nil,
        oracleDelay: Duration = .zero, sources: [any TradeQuoteSource], transport: EVMFixtureTransport
    ) -> EVMTradeEngine {
        let reader = EVMReader(transport: transport, rpc: [chain.id: testProviders("a", "b")], history: [:],
                               privateRelays: testProviders("relay1", "relay2"))
        let services = EVMTradeServices(
            aggregator: TradeAggregator(sources: sources), chainState: state, reader: reader, cow: cow, prices: FakeOracle(prices: prices, delay: oracleDelay),
            pendingOrders: EVMPendingLimitOrders(), confirmation: EVMConfirmationPolicy(interval: .milliseconds(1), attempts: 3)
        )
        return EVMTradeEngine(chain: chain, services: services)!
    }
}
