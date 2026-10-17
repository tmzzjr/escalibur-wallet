import EscaliburCore
import Foundation

// ShibaSwap direta (pedido do dono, 17/10/2026).
//
// Um fork da v2 da Uniswap (o da SushiSwap), so na Ethereum, onde mora o par SHIB/WETH dela.
// Como a v2 da PancakeSwap: sem API, a cotacao sai das reservas dos pares lidas na cadeia,
// com a taxa de 0,3%, e a calldata do router e montada aqui (`ShibaSwapCalldata`). O router
// puxa o token pelo approve exato de sempre.
//
// Fonte: o codigo verificado do router no Sourcify (Ethereum 0x03f7...b329,
// "UniswapV2Router02", match exato no codigo de criacao e no de execucao, solc 0.6.12):
// UniswapV2Router02.sol e libraries/UniswapV2Library.sol, de onde vem o hash do par e a
// taxa (997/1000). Conferido em 17/10/2026 em dois RPCs da Ethereum: codigo do router igual
// nos dois (18.469 bytes), sem proxy (slot EIP-1967 zerado), `factory()` e `WETH()` do router
// batendo com os daqui, os pares SHIB/WETH, USDC/WETH e USDT/WETH de `getPair` iguais aos
// calculados pelo hash, e `getAmountsOut` de 1 ETH em SHIB igual, ao wei, a conta das
// reservas com 0,3%.

public struct ShibaSwapDeployment: Sendable, Equatable {
    public let chainID: UInt64
    /// UniswapV2Router02: o `to` da troca e o spender do approve exato.
    public let router: EVMAddress
    public let factory: EVMAddress
    public let wrappedNative: EVMAddress
    /// Stablecoins da lista que servem de ponte.
    public let stables: [EVMAddress]

    static func address(_ hex: String) -> EVMAddress { TradeAllowlist.address(hex) }

    static let pairInitCodeHash = [UInt8](hex: "65d1a3b1e46c6e4f1be1ad5f99ef14dc488ae0549dc97db9b30afe2241ce1c7a")!

    public static let all: [UInt64: ShibaSwapDeployment] = [
        1: .init(chainID: 1, router: address("03f7724180aa6b939894b5ca4314783b0b36b329"),
                 factory: address("115934131916c8b277dd010ee02de363c09d037c"),
                 wrappedNative: address("c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"),
                 stables: [address("a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"), address("dac17f958d2ee523a2206206994597c13d831ec7")]),
    ]

    public static func on(_ chain: Chain) -> ShibaSwapDeployment? {
        guard chain.family == .evm, let id = chain.evmChainID else { return nil }
        return all[id]
    }

    var bases: [EVMAddress] { [wrappedNative] + stables }
}

/// Um par da v2, com os tokens na ordem do contrato (o menor endereco primeiro).
public struct ShibaSwapPair: Sendable, Hashable {
    public let token0: EVMAddress
    public let token1: EVMAddress

    public init(_ a: EVMAddress, _ b: EVMAddress) {
        (token0, token1) = UniswapPool.sorted(a, b)
    }
}

/// A busca de rota: os pares candidatos (direto e por uma ponte), as reservas num
/// `aggregate3` e a conta do par etapa a etapa. Nada e cotado fora da cadeia.
public struct ShibaSwapSearch: Sendable {
    public let intent: TradeIntent
    public let deployment: ShibaSwapDeployment

    static let routerOverheadGas: UInt64 = 50_000
    /// Gas de uma etapa no router, so para comparar.
    static let hopGas: UInt64 = 90_000
    static let getReservesFunction = try! ABIFunction("getReserves()")  // 0902f1ac

    public init?(intent: TradeIntent) {
        guard let deployment = ShibaSwapDeployment.on(intent.chain) else { return nil }
        self.intent = intent
        self.deployment = deployment
    }

    var tokenIn: EVMAddress { intent.sell.contract ?? deployment.wrappedNative }
    var tokenOut: EVMAddress { intent.buy.contract ?? deployment.wrappedNative }
    /// Nativo por embrulhado nao e troca.
    var usable: Bool { tokenIn != tokenOut }

    public var pairs: [ShibaSwapPair] {
        guard usable else { return [] }
        var out = [ShibaSwapPair(tokenIn, tokenOut)]
        for base in deployment.bases where base != tokenIn && base != tokenOut {
            for pair in [ShibaSwapPair(tokenIn, base), ShibaSwapPair(base, tokenOut)] where !out.contains(pair) { out.append(pair) }
        }
        return out
    }

    static func pairAddress(factory: EVMAddress, _ pair: ShibaSwapPair) -> EVMAddress {
        let salt = Hash.keccak256(pair.token0.bytes + pair.token1.bytes)
        let digest = Hash.keccak256([0xff] + factory.bytes + salt + ShibaSwapDeployment.pairInitCodeHash)
        return EVMAddress(uncheckedBytes: Array(digest.suffix(20)))
    }

    public func reserveCalls() throws -> [Multicall3.Call] {
        try pairs.map {
            Multicall3.Call(target: Self.pairAddress(factory: deployment.factory, $0), data: try Self.getReservesFunction.encodeCall([]))
        }
    }

    /// As reservas de cada par que existe e tem as duas pontas, na ordem do contrato. Par que
    /// nao existe volta sem dados (endereco sem codigo) e fica de fora.
    public func reserves(_ returnData: [UInt8]) throws -> [ShibaSwapPair: (BigUInt, BigUInt)] {
        let results = try Multicall3.decodeAggregate3(returnData, expected: pairs.count)
        var out = [ShibaSwapPair: (BigUInt, BigUInt)]()
        for (pair, data) in zip(pairs, results) {
            guard let data, data.count == 96 else { continue }
            let r0 = BigUInt(bigEndian: Array(data[0..<32])), r1 = BigUInt(bigEndian: Array(data[32..<64]))
            if !r0.isZero, !r1.isZero { out[pair] = (r0, r1) }
        }
        return out
    }

    /// Os caminhos com reservas: o direto e, por cada ponte, o de duas etapas.
    public func routes(_ reserves: [ShibaSwapPair: (BigUInt, BigUInt)]) -> [[EVMAddress]] {
        guard usable else { return [] }
        var out = [[EVMAddress]]()
        if reserves[ShibaSwapPair(tokenIn, tokenOut)] != nil { out.append([tokenIn, tokenOut]) }
        for base in deployment.bases where base != tokenIn && base != tokenOut
            && reserves[ShibaSwapPair(tokenIn, base)] != nil && reserves[ShibaSwapPair(base, tokenOut)] != nil {
            out.append([tokenIn, base, tokenOut])
        }
        return out
    }

    /// O que o caminho entrega: a conta do par com 0,3% de taxa, etapa a etapa, arredondada
    /// para baixo como o contrato (`UniswapV2Library.getAmountOut`). Token com taxa na
    /// transferencia entrega menos: o minimo sai alto, a simulacao recusa, e a ShibaSwap fica
    /// de fora dessa troca.
    static func amountOut(_ amountIn: BigUInt, path: [EVMAddress], reserves: [ShibaSwapPair: (BigUInt, BigUInt)]) -> BigUInt? {
        var amount = amountIn
        for (from, to) in zip(path, path.dropFirst()) {
            let pair = ShibaSwapPair(from, to)
            guard let (r0, r1) = reserves[pair] else { return nil }
            let (reserveIn, reserveOut) = from == pair.token0 ? (r0, r1) : (r1, r0)
            let withFee = amount * BigUInt(997)
            amount = withFee * reserveOut / (reserveIn * BigUInt(1_000) + withFee)
            if amount.isZero { return nil }
        }
        return amount
    }

    /// O melhor caminho: o que mais entrega; empate, o de menos etapas.
    public func best(_ routes: [[EVMAddress]], reserves: [ShibaSwapPair: (BigUInt, BigUInt)])
        -> (path: [EVMAddress], amountOut: BigUInt, gas: UInt64)? {
        var best: (path: [EVMAddress], amountOut: BigUInt, gas: UInt64)?
        for path in routes {
            guard let out = Self.amountOut(intent.amountIn, path: path, reserves: reserves) else { continue }
            let gas = Self.hopGas * UInt64(path.count - 1) + Self.routerOverheadGas
            if let current = best, out < current.amountOut || (out == current.amountOut && path.count >= current.path.count) { continue }
            best = (path, out, gas)
        }
        return best
    }
}
