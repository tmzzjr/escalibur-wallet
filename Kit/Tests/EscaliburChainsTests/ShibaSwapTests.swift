import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// A ShibaSwap direta: a calldata do router montada pelo app, a volta pelo decodificador
/// (com o que um router adulterado tentaria) e a conta da v2 pelas reservas.
@Suite("Troca: ShibaSwap direta")
struct ShibaSwapTests {
    typealias S = TradeTestSupport
    typealias T = EVMTestSupport

    static let deployment = ShibaSwapDeployment.on(.ethereum)!
    static let weth = T.address("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
    static let shib = EVMToken(chain: .ethereum, contract: T.address("0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE"), symbol: "SHIB", decimals: 18)
    static let usdc = EVMToken(chain: .ethereum, contract: T.address("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"), symbol: "USDC", decimals: 6)
    static let deadline = UInt64(S.recordedAt.timeIntervalSince1970) + 600

    static func intent(_ sell: TradeAsset, _ buy: TradeAsset) throws -> TradeIntent {
        try TradeIntent(owner: S.owner, sell: sell, buy: buy, amountIn: BigUInt(decimal: "10000000000000000")!, slippageBps: 50)
    }

    static func proposal(_ intent: TradeIntent, _ path: [EVMAddress], deadline: UInt64 = deadline) throws -> TradeProposal {
        let built = try ShibaSwapCalldata.encode(path: path, intent: intent, minimumOut: 1_000_000, deadline: deadline)
        return TradeProposal(provider: .shibaswap, chainID: 1, from: intent.owner, to: deployment.router, value: built.value, data: built.data,
                             expectedOut: 1_005_000, spender: deployment.router, gasEstimate: 140_000, routeSources: nil, reportedPriceImpactBps: nil)
    }

    static func validate(_ proposal: TradeProposal, _ intent: TradeIntent) throws -> ValidatedTradeQuote {
        try TradeValidator.validate(proposal, intent: intent, now: S.recordedAt)
    }

    @Test("As tres formas voltam pelo decodificador: ETH por token, token por ETH e token por token com ponte")
    func shapes() throws {
        let ethToShib = try Self.intent(.native(.ethereum), .token(Self.shib))
        let shibToEth = try Self.intent(.token(Self.shib), .native(.ethereum))
        let shibToUSDC = try Self.intent(.token(Self.shib), .token(Self.usdc))
        let cases: [(TradeIntent, [EVMAddress], sell: EVMAddress, buy: EVMAddress, selector: String)] = [
            (ethToShib, [Self.weth, Self.shib.contract], .zero, Self.shib.contract, "b6f9de95"),
            (shibToEth, [Self.shib.contract, Self.weth], Self.shib.contract, .zero, "791ac947"),
            (shibToUSDC, [Self.shib.contract, Self.weth, Self.usdc.contract], Self.shib.contract, Self.usdc.contract, "5c11d795"),
        ]
        for (intent, path, sell, buy, selector) in cases {
            let quote = try Self.validate(try Self.proposal(intent, path), intent)
            #expect(quote.provider == .shibaswap)
            #expect(quote.decoded.sellToken == sell && quote.decoded.buyToken == buy, "\(path)")
            #expect(quote.value == (intent.sell.isNative ? intent.amountIn : 0))
            #expect(quote.decoded.amountIn == intent.amountIn)
            #expect(quote.guaranteedOut == 1_000_000 && quote.decoded.recipient == S.owner)
            #expect(quote.decoded.deadline == Self.deadline)
            #expect(quote.spender == Self.deployment.router && !quote.router.viaPermit2)
            #expect(Hex.encode(Array(quote.data.prefix(4))) == selector)
        }
    }

    @Test("Calldata adulterada e recusada: destino, ponte fora da lista, caminho sem WETH, ETH a mais, prazo, minimo zero")
    func hostile() throws {
        let ethToShib = try Self.intent(.native(.ethereum), .token(Self.shib))
        let shibToEth = try Self.intent(.token(Self.shib), .native(.ethereum))
        let shibToUSDC = try Self.intent(.token(Self.shib), .token(Self.usdc))
        let f = ShibaSwapCalldata.self
        func raw(_ function: ABIFunction, _ values: [ABIValue], value: BigUInt = 0, base: TradeProposal) throws -> TradeProposal {
            S.with(base, value: value, data: try function.encodeCall(values))
        }
        let path = ABIValue.array([.address(Self.shib.contract), .address(Self.weth)])
        let tokens = try Self.proposal(shibToEth, [Self.shib.contract, Self.weth])

        // Destino trocado.
        let stranger = try raw(f.swapTokensForETH, [.uint(shibToEth.amountIn), .uint(1_000_000), path, .address(S.stranger), .uint(BigUInt(Self.deadline))],
                               base: tokens)
        #expect(throws: TradeRefusal.recipientMismatch(S.stranger)) { try Self.validate(stranger, shibToEth) }

        // Ponte fora da lista.
        let bridged = try Self.proposal(shibToUSDC, [Self.shib.contract, S.stranger, Self.usdc.contract])
        #expect(throws: TradeRefusal.malformed("ponte " + S.stranger.checksummed)) { try Self.validate(bridged, shibToUSDC) }

        // Vendendo ETH por um caminho que nao comeca no WETH; e saindo ETH por um que nao termina nele.
        let noWETH = try Self.proposal(ethToShib, [Self.usdc.contract, Self.shib.contract])
        #expect(throws: TradeRefusal.malformed("path")) { try Self.validate(noWETH, ethToShib) }
        let toUSDC = try raw(f.swapTokensForETH, [.uint(shibToEth.amountIn), .uint(1_000_000),
                                                  .array([.address(Self.shib.contract), .address(Self.usdc.contract)]),
                                                  .address(S.owner), .uint(BigUInt(Self.deadline))], base: tokens)
        #expect(throws: TradeRefusal.malformed("path")) { try Self.validate(toUSDC, shibToEth) }

        // ETH junto numa venda de token: o valor nao bate.
        #expect(throws: TradeRefusal.valueMismatch(expected: 0, found: 5)) { try Self.validate(S.with(tokens, value: 5), shibToEth) }

        // Prazo de duas horas.
        let late = try Self.proposal(shibToEth, [Self.shib.contract, Self.weth], deadline: Self.deadline + 7_200)
        #expect(throws: TradeRefusal.deadlineTooFar(seconds: 7_800)) { try Self.validate(late, shibToEth) }

        // Minimo zero.
        let zero = try raw(f.swapTokensForETH, [.uint(shibToEth.amountIn), .uint(0), path, .address(S.owner), .uint(BigUInt(Self.deadline))],
                           base: tokens)
        #expect(throws: TradeRefusal.zeroMinimumOut) { try Self.validate(zero, shibToEth) }

        // O caminho com tres etapas passa do limite.
        let long = try Self.proposal(shibToUSDC, [Self.shib.contract, Self.weth, T.address("0xdAC17F958D2ee523a2206206994597C13D831ec7"),
                                                  Self.usdc.contract])
        #expect(throws: TradeRefusal.malformed("path")) { try Self.validate(long, shibToUSDC) }

        // Fora da Ethereum nao ha ShibaSwap.
        #expect(ShibaSwapDeployment.on(.base) == nil && TradeAllowlist.router(for: .shibaswap, on: .base) == nil)
    }

    @Test("A conta do par: 0,3% de taxa, arredondada para baixo, igual ao getAmountsOut do router; e os enderecos dos pares")
    func math() throws {
        // As reservas do par SHIB/WETH e o getAmountsOut de 1 ETH, lidos em 17/10/2026 em dois RPCs.
        let pair = ShibaSwapPair(Self.weth, Self.shib.contract)
        #expect(pair.token0 == Self.shib.contract)
        let reserves = [pair: (BigUInt(decimal: "275094560010417664372311716692")!, BigUInt(decimal: "566712843818778590188")!)]
        let oneETH = BigUInt(decimal: "1000000000000000000")!
        #expect(ShibaSwapSearch.amountOut(oneETH, path: [Self.weth, Self.shib.contract], reserves: reserves)
                == BigUInt(decimal: "483115238033352185306229826")!)
        #expect(ShibaSwapSearch.amountOut(oneETH, path: [Self.weth, Self.usdc.contract], reserves: reserves) == nil)

        // CREATE2 com o hash do par, igual ao `getPair` da fabrica nos dois RPCs.
        let factory = Self.deployment.factory
        #expect(ShibaSwapSearch.pairAddress(factory: factory, pair) == T.address("0xCF6dAAB95c476106ECa715D48DE4b13287ffDEAa"))
        #expect(ShibaSwapSearch.pairAddress(factory: factory, ShibaSwapPair(Self.usdc.contract, Self.weth))
                == T.address("0x20E95253e54490D8d30ea41574b24F741ee70201"))
        #expect(ShibaSwapSearch.pairAddress(factory: factory, ShibaSwapPair(T.address("0xdAC17F958D2ee523a2206206994597C13D831ec7"), Self.weth))
                == T.address("0x703b120F15Ab77B986a24c6f9262364d02f9432f"))
    }

    @Test("A busca: pares direto e por ponte sem repetir, caminhos so com reservas, fica o que mais entrega")
    func search() throws {
        let intent = try TradeIntent(owner: S.owner, sell: .token(Self.shib), buy: .token(Self.usdc),
                                     amountIn: BigUInt(decimal: "1000000000000000000000000")!, slippageBps: 50)
        let search = try #require(ShibaSwapSearch(intent: intent))
        #expect(search.pairs.count == Set(search.pairs).count)
        #expect(search.pairs.first == ShibaSwapPair(Self.shib.contract, Self.usdc.contract))
        let shibWETH = ShibaSwapPair(Self.shib.contract, Self.weth), wethUSDC = ShibaSwapPair(Self.weth, Self.usdc.contract)
        #expect(search.pairs.contains(shibWETH) && search.pairs.contains(wethUSDC))
        // Sem o par direto: so a ponte pelo WETH tem as duas pernas.
        let reserves = [shibWETH: (BigUInt(decimal: "275094560010417664372311716692")!, BigUInt(decimal: "566712843818778590188")!),
                        wethUSDC: (BigUInt(decimal: "12222853317")!, BigUInt(decimal: "5075992031684670118")!)]
        let routes = search.routes(reserves)
        #expect(routes == [[Self.shib.contract, Self.weth, Self.usdc.contract]])
        let best = try #require(search.best(routes, reserves: reserves))
        #expect(best.path == routes[0] && !best.amountOut.isZero && best.gas == 230_000)
        // Nativo por embrulhado nao e troca.
        let wrap = try TradeIntent(owner: S.owner, sell: .native(.ethereum), buy: .token(EVMToken(chain: .ethereum, contract: Self.weth, symbol: "WETH", decimals: 18)),
                                   amountIn: 1, slippageBps: 50)
        #expect(ShibaSwapSearch(intent: wrap)?.pairs.isEmpty == true)
    }
}
