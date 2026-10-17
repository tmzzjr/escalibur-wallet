import EscaliburChains
import EscaliburCore
import Foundation

/// PancakeSwap direta: v3 nas 5 redes e v2 na BNB Chain, cotadas na cadeia pelos RPCs da
/// rede, com a calldata do SmartRouter montada aqui (`PancakeCalldata`). Sem API e sem chave.
///
/// Uma leitura de liquidez (v3) e reservas (v2) num `aggregate3`, e outra de cotacao da v3
/// no QuoterV2; a v2 sai da conta das reservas. Fica a rota que mais entrega. O minimo e o do
/// app, e a calldata volta pela validacao; o plano ainda simula em duas fontes.
public struct PancakeClient: TradeQuoteSource {
    public let provider = TradeProvider.pancakeswap
    let reader: TradeStateReader

    static let deadline: TimeInterval = 10 * 60

    public init(reader: TradeStateReader = TradeStateReader()) {
        self.reader = reader
    }

    public func propose(_ request: TradeQuoteRequest) async throws -> TradeProposal {
        let intent = request.intent
        guard let search = PancakeSearch(intent: intent), Multicall3.isDeployed(on: intent.chain),
              TradeAllowlist.router(for: .pancakeswap, on: intent.chain) != nil
        else { throw TradeProviderError.unsupported(.pancakeswap) }
        let chain = intent.chain

        let best: (route: PancakeRoute, amountOut: BigUInt, gas: UInt64)?
        do {
            let depthData = try await reader.call(chain: chain, to: Multicall3.address, data: try Multicall3.aggregate3(try search.depthCalls()))
            let depth = try search.depths(depthData)
            let routes = search.routes(depth)
            guard !routes.isEmpty else { throw TradeProviderError.noRoute(.pancakeswap) }
            let quoteCalls = try search.quoteCalls(routes)
            let quotes = quoteCalls.isEmpty ? nil
                : try await reader.call(chain: chain, to: Multicall3.address, data: try Multicall3.aggregate3(quoteCalls))
            best = try search.best(routes, depth: depth, quotes: quotes)
        } catch let error as TradeProviderError {
            throw error
        } catch {
            throw TradeProviderError.badResponse(.pancakeswap, String(describing: error))
        }
        guard let best else { throw TradeProviderError.noRoute(.pancakeswap) }

        let minimum = intent.minimumOut(forExpected: best.amountOut)
        let deadline = UInt64(Date().addingTimeInterval(Self.deadline).timeIntervalSince1970)
        let built: (data: [UInt8], value: BigUInt)
        do {
            built = try PancakeCalldata.encode(route: best.route, intent: intent, minimumOut: minimum, deadline: deadline,
                                               deployment: search.deployment)
        } catch {
            throw TradeProviderError.badResponse(.pancakeswap, "calldata: \(error)")
        }
        return TradeProposal(
            provider: .pancakeswap, chainID: chain.evmChainID, from: intent.owner, to: search.deployment.router,
            value: built.value, data: built.data, expectedOut: best.amountOut, spender: search.deployment.router,
            gasEstimate: best.gas,
            // Os pools da PancakeSwap tambem estao nas rotas dos agregadores: fora da divisao.
            routeSources: nil, reportedPriceImpactBps: nil
        )
    }
}
