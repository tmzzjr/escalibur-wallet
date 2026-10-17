import EscaliburChains
import EscaliburCore
import Foundation

/// Uniswap direta: cota nos contratos da propria Uniswap, pelos RPCs da rede, e monta a
/// calldata do Universal Router aqui (`UniswapCalldata`). Sem API e sem chave.
///
/// Duas leituras, cada uma um `aggregate3` do Multicall3: a liquidez de cada pool
/// candidato (v3 e v4 sem hook, direto ou por uma ponte: o embrulhado, a moeda nativa ou
/// uma stablecoin da lista), e a cotacao das rotas cujos pools tem liquidez. Fica a rota
/// que mais entrega. O minimo e o do app, com a tolerancia do dono, e a calldata volta
/// pela validacao como a de qualquer provedor; o plano ainda simula em duas fontes.
public struct UniswapClient: TradeQuoteSource {
    public let provider = TradeProvider.uniswap
    let reader: TradeStateReader

    /// Prazo gravado na calldata: o router recusa depois disso.
    static let deadline: TimeInterval = 10 * 60

    public init(reader: TradeStateReader = TradeStateReader()) {
        self.reader = reader
    }

    public func propose(_ request: TradeQuoteRequest) async throws -> TradeProposal {
        let intent = request.intent
        guard let search = UniswapSearch(intent: intent), Multicall3.isDeployed(on: intent.chain),
              TradeAllowlist.router(for: .uniswap, on: intent.chain) != nil
        else { throw TradeProviderError.unsupported(.uniswap) }
        let chain = intent.chain

        let liquidity: [UniswapPool: BigUInt]
        let routes: [UniswapRoute]
        let best: (route: UniswapRoute, amountOut: BigUInt, gas: UInt64)?
        do {
            let pools = try await reader.call(chain: chain, to: Multicall3.address, data: try Multicall3.aggregate3(try search.liquidityCalls()))
            liquidity = try search.liquidities(pools)
            routes = search.routes(liquidity: liquidity)
            guard !routes.isEmpty else { throw TradeProviderError.noRoute(.uniswap) }
            let quotes = try await reader.call(chain: chain, to: Multicall3.address, data: try Multicall3.aggregate3(try search.quoteCalls(routes)))
            best = try search.best(routes, returnData: quotes)
        } catch let error as TradeProviderError {
            throw error
        } catch {
            throw TradeProviderError.badResponse(.uniswap, String(describing: error))
        }
        guard let best else { throw TradeProviderError.noRoute(.uniswap) }

        let minimum = intent.minimumOut(forExpected: best.amountOut)
        let deadline = UInt64(Date().addingTimeInterval(Self.deadline).timeIntervalSince1970)
        let built: (data: [UInt8], value: BigUInt)
        do {
            built = try UniswapCalldata.encode(route: best.route, intent: intent, minimumOut: minimum, deadline: deadline,
                                               deployment: search.deployment)
        } catch {
            throw TradeProviderError.badResponse(.uniswap, "calldata: \(error)")
        }
        return TradeProposal(
            provider: .uniswap, chainID: chain.evmChainID, from: intent.owner, to: search.deployment.router,
            value: built.value, data: built.data, expectedOut: best.amountOut, spender: EIP712ValidatedMessage.permit2,
            gasEstimate: best.gas,
            // A divisao entre provedores so usa rotas conhecidas e disjuntas; os pools da
            // Uniswap tambem aparecem nas rotas dos agregadores, entao a Uniswap fica fora.
            routeSources: nil, reportedPriceImpactBps: nil
        )
    }
}
