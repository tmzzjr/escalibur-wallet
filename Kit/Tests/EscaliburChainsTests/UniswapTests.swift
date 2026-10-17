import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// A Uniswap direta: a calldata do Universal Router montada pelo app, a volta pelo
/// decodificador (com o que um router adulterado tentaria), a permissao exata do Permit2 na
/// guarda e no plano, e a busca de rota.
@Suite("Troca: Uniswap direta")
struct UniswapTests {
    typealias S = TradeTestSupport
    typealias T = EVMTestSupport

    static let base = UniswapDeployment.on(.base)!
    static let weth = T.address("0x4200000000000000000000000000000000000006")
    static let v4Tier = UniswapV4Tier(fee: 500, tickSpacing: 10)
    static let deadline = UInt64(S.recordedAt.timeIntervalSince1970) + 600

    static func proposal(_ intent: TradeIntent, _ route: UniswapRoute, minimum: BigUInt = 1_000_000, expected: BigUInt = 1_005_000,
                         deadline: UInt64 = deadline) throws -> TradeProposal {
        let built = try UniswapCalldata.encode(route: route, intent: intent, minimumOut: minimum, deadline: deadline, deployment: base)
        return TradeProposal(provider: .uniswap, chainID: 8453, from: intent.owner, to: base.router, value: built.value, data: built.data,
                             expectedOut: expected, spender: EIP712ValidatedMessage.permit2, gasEstimate: 150_000, routeSources: nil,
                             reportedPriceImpactBps: nil)
    }

    static func validate(_ proposal: TradeProposal, _ intent: TradeIntent) throws -> ValidatedTradeQuote {
        try TradeValidator.validate(proposal, intent: intent, now: S.recordedAt)
    }

    static func ethToUSDC() throws -> TradeIntent {
        try TradeIntent(owner: S.owner, sell: .native(.base), buy: .token(S.baseUSDC), amountIn: BigUInt(decimal: "10000000000000000")!, slippageBps: 50)
    }

    static func usdcToCbBTC() throws -> TradeIntent {
        let cbBTC = EVMToken(chain: .base, contract: T.address("0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf"), symbol: "cbBTC", decimals: 8)
        return try TradeIntent(owner: S.owner, sell: .token(S.baseUSDC), buy: .token(cbBTC), amountIn: 100_000_000, slippageBps: 50)
    }

    // MARK: Montagem e decodificacao

    @Test("As formas que o app monta voltam pelo decodificador com tokens, valor, minimo, dono e prazo")
    func shapes() throws {
        let usdcEth = try S.baseIntent()
        let ethUsdc = try Self.ethToUSDC()
        let usdcBtc = try Self.usdcToCbBTC()
        let cases: [(TradeIntent, UniswapRoute, sell: EVMAddress, buy: EVMAddress, value: BigUInt)] = [
            // v4 direto, token por nativo: o nativo e o endereco zero.
            (usdcEth, .v4(currencies: [S.baseUSDC.contract, .zero], tiers: [Self.v4Tier]), S.baseUSDC.contract, .zero, 0),
            // v4 em duas etapas, token por token com a moeda nativa de ponte.
            (usdcBtc, .v4(currencies: [S.baseUSDC.contract, .zero, usdcBtc.buy.contract!], tiers: [Self.v4Tier, Self.v4Tier]),
             S.baseUSDC.contract, usdcBtc.buy.contract!, 0),
            // v3 token por nativo: troca para o router e desembrulha para o dono.
            (usdcEth, .v3(tokens: [S.baseUSDC.contract, Self.weth], fees: [500]), S.baseUSDC.contract, .zero, 0),
            // v3 nativo por token: o router embrulha o msg.value.
            (ethUsdc, .v3(tokens: [Self.weth, S.baseUSDC.contract], fees: [500]), .zero, S.baseUSDC.contract, ethUsdc.amountIn),
            // v3 token por token pela ponte WETH.
            (usdcBtc, .v3(tokens: [S.baseUSDC.contract, Self.weth, usdcBtc.buy.contract!], fees: [500, 3_000]),
             S.baseUSDC.contract, usdcBtc.buy.contract!, 0),
        ]
        for (intent, route, sell, buy, value) in cases {
            let quote = try Self.validate(try Self.proposal(intent, route), intent)
            #expect(quote.provider == .uniswap)
            #expect(quote.value == value, "\(route)")
            #expect(quote.decoded.sellToken == sell && quote.decoded.buyToken == buy, "\(route)")
            #expect(quote.decoded.amountIn == intent.amountIn)
            #expect(quote.guaranteedOut == 1_000_000)
            #expect(quote.decoded.recipient == S.owner)
            #expect(quote.decoded.deadline == Self.deadline)
            #expect(quote.spender == EIP712ValidatedMessage.permit2 && quote.router.viaPermit2)
            #expect(Array(quote.data.prefix(4)) == [0x35, 0x93, 0x56, 0x4c])
        }
    }

    @Test("Calldata adulterada e recusada: destino, hook, ponte, comando a mais, minimo do TAKE_ALL, prazo")
    func hostile() throws {
        let intent = try Self.usdcToCbBTC()
        let router = try #require(TradeAllowlist.router(for: .uniswap, on: .base))
        let v3 = try Self.proposal(intent, .v3(tokens: [S.baseUSDC.contract, intent.buy.contract!], fees: [500]))

        // v3 para um estranho.
        let stranger = try S.mutate(v3.data, router: router) { arguments in
            var inputs = arguments[1].arrayValue!
            var values = try! ABI.decode(UniswapCalldata.v3SwapTypes, from: inputs[0].bytesValue!)
            values[0] = .address(S.stranger)
            inputs[0] = .bytes(try! ABI.encode(values, types: UniswapCalldata.v3SwapTypes))
            return [arguments[0], .array(inputs), arguments[2]]
        }
        #expect(throws: TradeRefusal.recipientMismatch(S.stranger)) { try Self.validate(S.with(v3, data: stranger), intent) }

        // Ponte que nao e o embrulhado nem stablecoin da lista.
        let bridged = try UniswapCalldata.encode(route: .v3(tokens: [S.baseUSDC.contract, S.stranger, intent.buy.contract!], fees: [500, 500]),
                                                 intent: intent, minimumOut: 1_000_000, deadline: Self.deadline, deployment: Self.base)
        #expect(throws: TradeRefusal.malformed("ponte " + S.stranger.checksummed)) { try Self.validate(S.with(v3, data: bridged.data), intent) }

        // Um comando a mais (SWEEP 0x04) depois da troca.
        let extra = try S.mutate(v3.data, router: router) { arguments in
            [.bytes(arguments[0].bytesValue! + [0x04]), .array(arguments[1].arrayValue! + [.bytes([UInt8](repeating: 0, count: 96))]), arguments[2]]
        }
        #expect(throws: TradeRefusal.malformed("commands 0x0004")) { try Self.validate(S.with(v3, data: extra), intent) }

        // Prazo de duas horas.
        let late = try Self.proposal(intent, .v3(tokens: [S.baseUSDC.contract, intent.buy.contract!], fees: [500]), deadline: Self.deadline + 7_200)
        #expect(throws: TradeRefusal.deadlineTooFar(seconds: 7_800)) { try Self.validate(late, intent) }

        // v4: pool com hook, e TAKE_ALL abaixo do minimo da troca.
        let v4 = try Self.proposal(intent, .v4(currencies: [S.baseUSDC.contract, intent.buy.contract!], tiers: [Self.v4Tier]))
        func v4Params(_ change: ([UInt8]) -> [[UInt8]]) throws -> [UInt8] {
            try S.mutate(v4.data, router: router) { arguments in
                var inputs = arguments[1].arrayValue!
                let values = try! ABI.decode(UniswapCalldata.v4SwapTypes, from: inputs[0].bytesValue!)
                let params = change(values[1].arrayValue![0].bytesValue!) + values[1].arrayValue!.dropFirst().map { $0.bytesValue! }
                inputs[0] = .bytes(try! ABI.encode([values[0], .array(params.map { .bytes($0) })], types: UniswapCalldata.v4SwapTypes))
                return [arguments[0], .array(inputs), arguments[2]]
            }
        }
        let hooked = try v4Params { swap in
            var fields = try! ABI.decode([UniswapCalldata.exactInSingleType], from: swap)[0].tupleValue!
            var key = fields[0].tupleValue!
            key[4] = .address(S.stranger)
            fields[0] = .tuple(key)
            return [try! ABI.encode([.tuple(fields)], types: [UniswapCalldata.exactInSingleType])]
        }
        #expect(throws: TradeRefusal.malformed("hooks")) { try Self.validate(S.with(v4, data: hooked), intent) }

        let takeLower = try S.mutate(v4.data, router: router) { arguments in
            var inputs = arguments[1].arrayValue!
            let values = try! ABI.decode(UniswapCalldata.v4SwapTypes, from: inputs[0].bytesValue!)
            var params = values[1].arrayValue!
            params[2] = .bytes(try! ABI.encode([.address(intent.buy.contract!), .uint(1)], types: UniswapCalldata.pairTypes))
            inputs[0] = .bytes(try! ABI.encode([values[0], .array(params)], types: UniswapCalldata.v4SwapTypes))
            return [arguments[0], .array(inputs), arguments[2]]
        }
        #expect(throws: TradeRefusal.malformed("TAKE_ALL")) { try Self.validate(S.with(v4, data: takeLower), intent) }

        // O router de outra rede.
        let arbitrum = try #require(UniswapDeployment.on(.arbitrum))
        #expect(throws: TradeRefusal.routerNotAllowed(arbitrum.router)) { try Self.validate(S.with(v4, to: arbitrum.router), intent) }
    }

    // MARK: Permit2 na guarda

    @Test("Guarda: Permit2.approve so passa exatamente como o plano declarou")
    func permit2Guard() throws {
        let grant = EVMPermit2Approval(token: S.baseUSDC.contract, spender: Self.base.router, amount: 100_000_000, expiration: 1_790_392_800)
        let data = try grant.calldata()
        #expect(Array(data.prefix(4)) == [0x87, 0x51, 0x7c, 0x45])
        let call = EVMCallProposal(transactionType: 2, to: EIP712ValidatedMessage.permit2, value: 0, data: data)
        #expect(throws: EVMCallRefusal.permit) { try EVMCallGuard.inspect(call, policy: EVMCallPolicy()) }
        let decoded = try EVMCallGuard.inspect(call, policy: EVMCallPolicy(permit2Approval: grant))
        #expect(decoded == .contractCall(contract: EIP712ValidatedMessage.permit2, function: "approve(address,address,uint160,uint48)",
                                         arguments: grant.arguments, value: 0))
        // Outro valor, outro prazo, outro spender, com valor nativo, ou a outro contrato: recusa.
        let others = [
            EVMPermit2Approval(token: grant.token, spender: grant.spender, amount: 100_000_001, expiration: grant.expiration),
            EVMPermit2Approval(token: grant.token, spender: grant.spender, amount: grant.amount, expiration: grant.expiration + 1),
            EVMPermit2Approval(token: grant.token, spender: S.stranger, amount: grant.amount, expiration: grant.expiration),
        ]
        for other in others {
            let proposal = EVMCallProposal(transactionType: 2, to: EIP712ValidatedMessage.permit2, value: 0, data: try other.calldata())
            #expect(throws: EVMCallRefusal.permit) { try EVMCallGuard.inspect(proposal, policy: EVMCallPolicy(permit2Approval: grant)) }
        }
        #expect(throws: EVMCallRefusal.permit) {
            try EVMCallGuard.inspect(EVMCallProposal(transactionType: 2, to: EIP712ValidatedMessage.permit2, value: 1, data: data),
                                     policy: EVMCallPolicy(permit2Approval: grant))
        }
        #expect(throws: EVMCallRefusal.permit) {
            try EVMCallGuard.inspect(EVMCallProposal(transactionType: 2, to: S.stranger, value: 0, data: data), policy: EVMCallPolicy(permit2Approval: grant))
        }
    }

    // MARK: Plano

    @Test("Plano: approve exato ao Permit2, permissao de 30 minutos ao router e troca, nesta ordem, assinados")
    func plan() throws {
        let account = try T.account(T.testKey)
        let quote = try TradeValidator.validate(S.proposal(.uniswap, "uniswap-base-usdc-eth"), intent: S.baseIntent(), now: S.recordedAt)
        let state = S.chainState(quote, allowance: 0, l1: BigUInt(20_000_000_000))
        let plan = try TradePlanner.planSwap(walletID: UUID(), account: account, quote: quote, state: state, now: S.recordedAt.addingTimeInterval(10))
        #expect(plan.transactions.count == 3 && plan.review.transactionCount == 3)
        let approve = plan.transactions[0] as! EVMTransaction
        let grant = plan.transactions[1] as! EVMTransaction
        let swap = plan.transactions[2] as! EVMTransaction
        #expect(approve.nonce == 7 && grant.nonce == 8 && swap.nonce == 9)
        #expect(approve.to == S.baseUSDC.contract && approve.data == ERC20.approve(spender: EIP712ValidatedMessage.permit2, amount: 100_000_000))
        let expected = EVMPermit2Approval(token: S.baseUSDC.contract, spender: Self.base.router, amount: 100_000_000,
                                          expiration: UInt64(S.recordedAt.timeIntervalSince1970) + 1_800)
        let expectedData = try expected.calldata()
        #expect(grant.to == EIP712ValidatedMessage.permit2 && grant.value == 0 && grant.data == expectedData)
        #expect(swap.to == Self.base.router && swap.data == quote.data)
        let line = { (label: String) in plan.review.lines.first { $0.label == label }?.value }
        #expect(line("Provedor") == "Uniswap")
        #expect(line("Permissão no Permit2") == "100\u{00A0}USDC para o contrato da Uniswap, por 30 minutos")
        #expect(line("Contrato autorizado no Permit2") == Self.base.router.checksummed)
        #expect(line("Etapas") == "3 transações: autorizar, liberar no Permit2 e trocar, nesta ordem")
        #expect(line("Prazo na cadeia")?.hasPrefix("Até ") == true)
        for transaction in [approve, grant, swap] {
            let signed = try transaction.assemble(with: [T.sign(transaction.signingDigest, key: T.testKey)])
            #expect(signed.raw.first == 0x02)
        }

        // Permissao do Permit2 que ja cobre e vale mais de 5 minutos: so approve e troca.
        let covered = TradePermit2Allowance(amount: 200_000_000, expiration: UInt64(S.recordedAt.timeIntervalSince1970) + 3_600)
        let coveredState = TradeChainState(
            network: state.network, sellToken: state.sellToken, routerHasCode: true, routerPin: nil,
            simulations: [S.simulation(quote, source: "a", allowance: 0, permit2: covered), S.simulation(quote, source: "b", allowance: 0, permit2: covered)],
            approveL1DataFee: state.approveL1DataFee, swapL1DataFee: state.swapL1DataFee, permit2: covered,
            permit2L1DataFee: state.permit2L1DataFee
        )
        let short = try TradePlanner.planSwap(walletID: UUID(), account: account, quote: quote, state: coveredState, now: S.recordedAt.addingTimeInterval(10))
        #expect(short.transactions.count == 2)

        // Vencendo em 2 minutos: pede outra.
        let expiring = TradePermit2Allowance(amount: 200_000_000, expiration: UInt64(S.recordedAt.timeIntervalSince1970) + 120)
        #expect(TradePlanner.permit2Approval(for: quote, current: expiring) == expected)

        // Simulacao sem a chamada do Permit2: o formato nao bate, nada e montado.
        let missing = TradeChainState(
            network: state.network, sellToken: state.sellToken, routerHasCode: true, routerPin: nil,
            simulations: [S.simulation(quote, source: "a", allowance: 0, permit2: covered), S.simulation(quote, source: "b", allowance: 0, permit2: covered)],
            approveL1DataFee: state.approveL1DataFee, swapL1DataFee: state.swapL1DataFee, permit2: nil,
            permit2L1DataFee: state.permit2L1DataFee
        )
        #expect(throws: TradeRefusal.simulationShape) {
            try TradePlanner.planSwap(walletID: UUID(), account: account, quote: quote, state: missing, now: S.recordedAt.addingTimeInterval(10))
        }
    }

    // MARK: Busca

    @Test("Busca: pools candidatos, endereco do pool da v3, id do pool da v4 e a melhor rota")
    func search() throws {
        let search = try #require(UniswapSearch(intent: S.baseIntent()))
        // USDC por ETH: as pontes (WETH e USDC na v3, nativo e USDC na v4) ja sao as pontas,
        // entao so o par direto, nas quatro faixas de cada versao.
        #expect(search.pools.count == 8)
        #expect(UniswapSearch.v3PoolAddress(factory: Self.base.v3Factory, Self.weth, S.baseUSDC.contract, 500)
                == T.address("0xd0b53D9277642d899DF5C87A3966A349A798F224"))
        #expect(Hex.encode(UniswapSearch.v4PoolID(.zero, S.baseUSDC.contract, Self.v4Tier))
                == "96d4b53a38337a5733179751781178a2613306063c511b78cd02684739288c0a")

        // So os pools com liquidez viram rota; nas pontes, as duas faixas mais fundas.
        let liquidity: [UniswapPool: BigUInt] = [
            .v3(S.baseUSDC.contract, Self.weth, 500): 10, .v3(S.baseUSDC.contract, Self.weth, 3_000): 5,
            .v4(S.baseUSDC.contract, .zero, Self.v4Tier): 7,
        ]
        let routes = search.routes(liquidity: liquidity)
        #expect(Set(routes) == [
            .v3(tokens: [S.baseUSDC.contract, Self.weth], fees: [500]), .v3(tokens: [S.baseUSDC.contract, Self.weth], fees: [3_000]),
            .v4(currencies: [S.baseUSDC.contract, .zero], tiers: [Self.v4Tier]),
        ])

        // Melhor: a que mais entrega; a cotacao que falhou nao conta.
        let answers: [[UInt8]?] = routes.map { route in
            switch route {
            case .v4: return S.word(900) + S.word(120_000)
            case .v3(_, let fees) where fees == [500]: return S.word(950) + S.word(0) + S.word(0) + S.word(110_000)
            default: return nil
            }
        }
        let encoded = try ABI.encode([.array(answers.map { .tuple([.bool($0 != nil), .bytes($0 ?? [])]) })], types: [.array(.tuple([.bool, .bytes]))])
        let best = try #require(try search.best(routes, returnData: encoded))
        #expect(best.route == .v3(tokens: [S.baseUSDC.contract, Self.weth], fees: [500]))
        #expect(best.amountOut == 950 && best.gas == 110_000 + UniswapSearch.routerOverheadGas)

        // Nativo por embrulhado nao e troca: sem pools.
        let wrap = try TradeIntent(owner: S.owner, sell: .native(.base),
                                   buy: .token(EVMToken(chain: .base, contract: Self.weth, symbol: "WETH", decimals: 18)),
                                   amountIn: 1_000, slippageBps: 50)
        #expect(try #require(UniswapSearch(intent: wrap)).pools.isEmpty)
        #expect(UniswapSearch(intent: try TradeIntent(owner: S.owner, sell: .native(.sonic),
                                                      buy: .token(EVMToken(chain: .sonic, contract: S.stranger, symbol: "X", decimals: 18)),
                                                      amountIn: 1, slippageBps: 50)) == nil)
    }
}
