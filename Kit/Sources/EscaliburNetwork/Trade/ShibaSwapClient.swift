import EscaliburChains
import EscaliburCore
import Foundation

/// ShibaSwap direta, na Ethereum: as reservas dos pares lidas pelos RPCs da rede num
/// `aggregate3`, a conta do par com 0,3% e a calldata do router montada aqui
/// (`ShibaSwapCalldata`). Sem API e sem chave.
///
/// Fica o caminho que mais entrega, direto ou por uma ponte. O minimo e o do app, e a
/// calldata volta pela validacao; o plano ainda simula em duas fontes.
public struct ShibaSwapClient: TradeQuoteSource {
    public let provider = TradeProvider.shibaswap
    let reader: TradeStateReader

    static let deadline: TimeInterval = 10 * 60

    public init(reader: TradeStateReader = TradeStateReader()) {
        self.reader = reader
    }

    public func propose(_ request: TradeQuoteRequest) async throws -> TradeProposal {
        let intent = request.intent
        guard let search = ShibaSwapSearch(intent: intent), Multicall3.isDeployed(on: intent.chain),
              TradeAllowlist.router(for: .shibaswap, on: intent.chain) != nil
        else { throw TradeProviderError.unsupported(.shibaswap) }
        let chain = intent.chain

        let best: (path: [EVMAddress], amountOut: BigUInt, gas: UInt64)?
        do {
            let data = try await reader.call(chain: chain, to: Multicall3.address, data: try Multicall3.aggregate3(try search.reserveCalls()))
            let reserves = try search.reserves(data)
            let routes = search.routes(reserves)
            guard !routes.isEmpty else { throw TradeProviderError.noRoute(.shibaswap) }
            best = search.best(routes, reserves: reserves)
        } catch let error as TradeProviderError {
            throw error
        } catch {
            throw TradeProviderError.badResponse(.shibaswap, String(describing: error))
        }
        guard let best else { throw TradeProviderError.noRoute(.shibaswap) }

        let minimum = intent.minimumOut(forExpected: best.amountOut)
        let deadline = UInt64(Date().addingTimeInterval(Self.deadline).timeIntervalSince1970)
        let built: (data: [UInt8], value: BigUInt)
        do {
            built = try ShibaSwapCalldata.encode(path: best.path, intent: intent, minimumOut: minimum, deadline: deadline)
        } catch {
            throw TradeProviderError.badResponse(.shibaswap, "calldata: \(error)")
        }
        return TradeProposal(
            provider: .shibaswap, chainID: chain.evmChainID, from: intent.owner, to: search.deployment.router,
            value: built.value, data: built.data, expectedOut: best.amountOut, spender: search.deployment.router,
            gasEstimate: best.gas,
            // Os pares da ShibaSwap tambem estao nas rotas dos agregadores: fora da divisao.
            routeSources: nil, reportedPriceImpactBps: nil
        )
    }
}
