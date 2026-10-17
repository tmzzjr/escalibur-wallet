import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// A PancakeSwap direta: a calldata do SmartRouter montada pelo app, a volta pelo
/// decodificador (com o que um router adulterado tentaria) e a conta da v2 pelas reservas.
@Suite("Troca: PancakeSwap direta")
struct PancakeTests {
    typealias S = TradeTestSupport
    typealias T = EVMTestSupport

    static let bnb = PancakeDeployment.on(.bnb)!
    static let wbnb = T.address("0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c")
    static let usdt = EVMToken(chain: .bnb, contract: T.address("0x55d398326f99059fF775485246999027B3197955"), symbol: "USDT", decimals: 18)
    static let cake = EVMToken(chain: .bnb, contract: T.address("0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82"), symbol: "CAKE", decimals: 18)
    static let deadline = UInt64(S.recordedAt.timeIntervalSince1970) + 600

    static func proposal(_ intent: TradeIntent, _ route: PancakeRoute, deadline: UInt64 = deadline) throws -> TradeProposal {
        let built = try PancakeCalldata.encode(route: route, intent: intent, minimumOut: 1_000_000, deadline: deadline, deployment: bnb)
        return TradeProposal(provider: .pancakeswap, chainID: 56, from: intent.owner, to: bnb.router, value: built.value, data: built.data,
                             expectedOut: 1_005_000, spender: bnb.router, gasEstimate: 150_000, routeSources: nil, reportedPriceImpactBps: nil)
    }

    static func validate(_ proposal: TradeProposal, _ intent: TradeIntent) throws -> ValidatedTradeQuote {
        try TradeValidator.validate(proposal, intent: intent, now: S.recordedAt)
    }

    static func intent(_ sell: TradeAsset, _ buy: TradeAsset) throws -> TradeIntent {
        try TradeIntent(owner: S.owner, sell: sell, buy: buy, amountIn: BigUInt(decimal: "10000000000000000")!, slippageBps: 50)
    }

    @Test("As formas que o app monta voltam pelo decodificador: v3 direta e em duas etapas, v2, nativo dos dois lados")
    func shapes() throws {
        let bnbToUSDT = try Self.intent(.native(.bnb), .token(Self.usdt))
        let usdtToBNB = try Self.intent(.token(Self.usdt), .native(.bnb))
        let cakeToUSDT = try Self.intent(.token(Self.cake), .token(Self.usdt))
        let cases: [(TradeIntent, PancakeRoute, sell: EVMAddress, buy: EVMAddress)] = [
            (bnbToUSDT, .v3(tokens: [Self.wbnb, Self.usdt.contract], fees: [500]), .zero, Self.usdt.contract),
            (usdtToBNB, .v3(tokens: [Self.usdt.contract, Self.wbnb], fees: [100]), Self.usdt.contract, .zero),
            (cakeToUSDT, .v3(tokens: [Self.cake.contract, Self.wbnb, Self.usdt.contract], fees: [2_500, 500]), Self.cake.contract, Self.usdt.contract),
            (bnbToUSDT, .v2(tokens: [Self.wbnb, Self.usdt.contract]), .zero, Self.usdt.contract),
            (usdtToBNB, .v2(tokens: [Self.usdt.contract, Self.wbnb]), Self.usdt.contract, .zero),
            (cakeToUSDT, .v2(tokens: [Self.cake.contract, Self.wbnb, Self.usdt.contract]), Self.cake.contract, Self.usdt.contract),
        ]
        for (intent, route, sell, buy) in cases {
            let quote = try Self.validate(try Self.proposal(intent, route), intent)
            #expect(quote.provider == .pancakeswap)
            #expect(quote.decoded.sellToken == sell && quote.decoded.buyToken == buy, "\(route)")
            #expect(quote.value == (intent.sell.isNative ? intent.amountIn : 0))
            #expect(quote.guaranteedOut == 1_000_000 && quote.decoded.recipient == S.owner)
            #expect(quote.decoded.deadline == Self.deadline)
            #expect(quote.spender == Self.bnb.router && !quote.router.viaPermit2)
            #expect(Array(quote.data.prefix(4)) == [0x5a, 0xe4, 0x01, 0xdc])
        }
    }

    @Test("Calldata adulterada e recusada: destino, ponte fora da lista, chamada a mais, minimo do unwrap, prazo, v2 fora da BNB")
    func hostile() throws {
        let intent = try Self.intent(.token(Self.cake), .token(Self.usdt))
        let router = try #require(TradeAllowlist.router(for: .pancakeswap, on: .bnb))
        let v2 = try Self.proposal(intent, .v2(tokens: [Self.cake.contract, Self.usdt.contract]))

        // Destino trocado na v2.
        let stranger = try S.mutate(v2.data, router: router) { arguments in
            var calls = arguments[1].arrayValue!
            var values = try! PancakeCalldata.swapV2.decodeCall(calls[0].bytesValue!)
            values[3] = .address(S.stranger)
            calls[0] = .bytes(try! PancakeCalldata.swapV2.encodeCall(values))
            return [arguments[0], .array(calls)]
        }
        #expect(throws: TradeRefusal.recipientMismatch(S.stranger)) { try Self.validate(S.with(v2, data: stranger), intent) }

        // Ponte fora da lista.
        let bridged = try PancakeCalldata.encode(route: .v2(tokens: [Self.cake.contract, S.stranger, Self.usdt.contract]), intent: intent,
                                                 minimumOut: 1_000_000, deadline: Self.deadline, deployment: Self.bnb)
        #expect(throws: TradeRefusal.malformed("ponte " + S.stranger.checksummed)) { try Self.validate(S.with(v2, data: bridged.data), intent) }

        // Uma chamada a mais no multicall (um sweep qualquer).
        let extra = try S.mutate(v2.data, router: router) { arguments in
            [arguments[0], .array(arguments[1].arrayValue! + [.bytes([0xdf, 0x2a, 0xb5, 0xbb] + [UInt8](repeating: 0, count: 96))])]
        }
        #expect(throws: TradeRefusal.self) { try Self.validate(S.with(v2, data: extra), intent) }

        // Prazo de duas horas.
        let late = try Self.proposal(intent, .v2(tokens: [Self.cake.contract, Self.usdt.contract]), deadline: Self.deadline + 7_200)
        #expect(throws: TradeRefusal.deadlineTooFar(seconds: 7_800)) { try Self.validate(late, intent) }

        // Saindo BNB: o unwrap com minimo menor que o da troca, ou para outro.
        let toBNB = try Self.intent(.token(Self.usdt), .native(.bnb))
        let native = try Self.proposal(toBNB, .v3(tokens: [Self.usdt.contract, Self.wbnb], fees: [500]))
        for (minimum, to) in [(BigUInt(1), S.owner), (BigUInt(1_000_000), S.stranger)] {
            let changed = try S.mutate(native.data, router: router) { arguments in
                var calls = arguments[1].arrayValue!
                calls[1] = .bytes(try! PancakeCalldata.unwrapWETH9.encodeCall([.uint(minimum), .address(to)]))
                return [arguments[0], .array(calls)]
            }
            #expect(throws: TradeRefusal.self) { try Self.validate(S.with(native, data: changed), toBNB) }
        }

        // v2 fora da BNB: a Base nao tem a v2 na lista.
        let baseIntent = try S.baseIntent()
        let base = try #require(PancakeDeployment.on(.base))
        let onBase = try PancakeCalldata.encode(route: .v2(tokens: [S.baseUSDC.contract, base.wrappedNative]), intent: baseIntent,
                                                minimumOut: 1_000_000, deadline: Self.deadline, deployment: base)
        let proposal = TradeProposal(provider: .pancakeswap, chainID: 8453, from: S.owner, to: base.router, value: 0, data: onBase.data,
                                     expectedOut: 1_005_000, spender: base.router, gasEstimate: nil, routeSources: nil, reportedPriceImpactBps: nil)
        #expect(throws: TradeRefusal.malformed("v2")) { try Self.validate(proposal, baseIntent) }
    }

    @Test("A conta da v2: 0,25% de taxa, arredondada para baixo, como o par; e o endereco do par e do pool")
    func v2Math() throws {
        let a = Self.wbnb, b = Self.usdt.contract
        let (token0, _) = UniswapPool.sorted(a, b)
        let reserves: [PancakePool: PancakeDepth] = [
            .v2(a, b): token0 == a ? .v2(reserve0: 1_000, reserve1: 600_000) : .v2(reserve0: 600_000, reserve1: 1_000),
        ]
        // 10 WBNB por USDT: 10*9975*600000 / (1000*10000 + 10*9975) = 5925 (para baixo).
        #expect(PancakeSearch.v2AmountOut(10, tokens: [a, b], depth: reserves) == 5_925)
        #expect(PancakeSearch.v2AmountOut(10, tokens: [b, a], depth: reserves) == 0 || PancakeSearch.v2AmountOut(10, tokens: [b, a], depth: reserves) == nil)
        // Os enderecos que a cadeia confirmou (getPool e getPair, 17/10/2026).
        #expect(PancakeSearch.v2PairAddress(factory: Self.bnb.v2Factory!, a, b) == T.address("0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE"))
    }
}
