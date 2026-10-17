import EscaliburCore
import Foundation

// PancakeSwap direta (pedido do dono, 17/10/2026: "a mais importante de todos").
//
// Como a Uniswap direta, sem API: a cotacao e lida na cadeia e a calldata do SmartRouter e
// montada aqui (`PancakeCalldata`). A v3 e uma copia da v3 da Uniswap (QuoterV2 com a mesma
// interface); a v2, onde moram os memecoins da BNB Chain, e cotada pelas reservas do par,
// com a taxa de 0,25%. O SmartRouter puxa o token pelo approve exato de sempre, sem Permit2.
//
// Fonte dos enderecos: developer.pancakeswap.finance/contracts/v3/addresses (SmartRouter por
// rede) e github.com/pancakeswap/pancake-v3-contracts/deployments (QuoterV2, fabrica e
// deployer), conferidos em 17/10/2026 em dois RPCs de cada rede: codigo igual nos dois (o
// SmartRouter com 24.316 bytes nas 5), sem proxy (slot EIP-1967 zerado), `factory()`,
// `deployer()`, `factoryV2()` e `WETH9()` do SmartRouter batendo com os daqui, e
// `deployer()` do QuoterV2 tambem. O SmartRouter e verificado no Sourcify ("SmartRouter",
// match exato, BNB). O endereco de pool da v3 calculado pelo deployer com o hash abaixo bateu
// com `getPool` da fabrica nas 5 (0,01%, 0,05% e 0,25%), e o do par da v2 com `getPair` na BNB.

public struct PancakeDeployment: Sendable, Equatable {
    public let chainID: UInt64
    /// SmartRouter: o `to` da troca e o spender do approve exato.
    public let router: EVMAddress
    public let wrappedNative: EVMAddress
    /// A fabrica da v2 com o hash de codigo do par; so na BNB, onde a v2 tem a liquidez.
    public let v2Factory: EVMAddress?
    /// Stablecoins da lista que servem de ponte.
    public let stables: [EVMAddress]

    static func address(_ hex: String) -> EVMAddress { TradeAllowlist.address(hex) }

    /// O mesmo nas 5 redes.
    static let v3Quoter = address("b048bbc1ee6b733fffcfb9e9cef7375518e25997")
    static let v3Deployer = address("41ff9aa7e16b8b1a8a8dc4f0efacd93d02d071c9")
    static let v3PoolInitCodeHash = [UInt8](hex: "6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2")!
    static let v2PairInitCodeHash = [UInt8](hex: "00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5")!

    public static let all: [UInt64: PancakeDeployment] = [
        56: .init(chainID: 56, router: address("13f4ea83d0bd40e75c8222255bc855a974568dd4"),
                  wrappedNative: address("bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c"),
                  v2Factory: address("ca143ce32fe78f1f7019d7d551a6402fc5350c73"),
                  stables: [address("55d398326f99059ff775485246999027b3197955"), address("8ac76a51cc950d9822d68b83fe1ad97b32cd580d")]),
        1: .init(chainID: 1, router: address("13f4ea83d0bd40e75c8222255bc855a974568dd4"),
                 wrappedNative: address("c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"), v2Factory: nil,
                 stables: [address("a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"), address("dac17f958d2ee523a2206206994597c13d831ec7")]),
        8453: .init(chainID: 8453, router: address("678aa4bf4e210cf2166753e054d5b7c31cc7fa86"),
                    wrappedNative: address("4200000000000000000000000000000000000006"), v2Factory: nil,
                    stables: [address("833589fcd6edb6e08f4c7c32d4f71b54bda02913")]),
        42161: .init(chainID: 42161, router: address("32226588378236fd0c7c4053999f88ac0e5cac77"),
                     wrappedNative: address("82af49447d8a07e3bd95bd0d56f35241523fbab1"), v2Factory: nil,
                     stables: [address("af88d065e77c8cc2239327c5edb3a432268e5831"), address("fd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9")]),
        59144: .init(chainID: 59144, router: address("678aa4bf4e210cf2166753e054d5b7c31cc7fa86"),
                     wrappedNative: address("e5d7c2a44ffddf6b295a15c148167daaaf5cf34f"), v2Factory: nil,
                     stables: [address("176211869ca2b568f2a7d4ee941e073a821ee1ff")]),
    ]

    public static func on(_ chain: Chain) -> PancakeDeployment? {
        guard chain.family == .evm, let id = chain.evmChainID else { return nil }
        return all[id]
    }

    var bases: [EVMAddress] { [wrappedNative] + stables }
}

/// As faixas de taxa da v3 da PancakeSwap, em milionesimos.
public enum PancakeV3Fee {
    public static let all: [UInt32] = [100, 500, 2_500, 10_000]
}

/// Um caminho de uma ou duas etapas.
public enum PancakeRoute: Sendable, Hashable {
    case v3(tokens: [EVMAddress], fees: [UInt32])
    /// v2: os tokens do caminho, todos pares de 0,25%.
    case v2(tokens: [EVMAddress])

    public var hops: Int {
        switch self {
        case .v3(_, let fees): return fees.count
        case .v2(let tokens): return tokens.count - 1
        }
    }
}

public enum PancakePool: Sendable, Hashable {
    case v3(a: EVMAddress, b: EVMAddress, fee: UInt32)
    case v2(a: EVMAddress, b: EVMAddress)

    static func v3(_ a: EVMAddress, _ b: EVMAddress, _ fee: UInt32) -> PancakePool {
        let (x, y) = UniswapPool.sorted(a, b)
        return .v3(a: x, b: y, fee: fee)
    }

    static func v2(_ a: EVMAddress, _ b: EVMAddress) -> PancakePool {
        let (x, y) = UniswapPool.sorted(a, b)
        return .v2(a: x, b: y)
    }
}

/// O que a leitura de liquidez achou num pool: a liquidez da v3, ou as reservas da v2 na
/// ordem dos tokens (o menor endereco primeiro).
public enum PancakeDepth: Sendable, Equatable {
    case v3(BigUInt)
    case v2(reserve0: BigUInt, reserve1: BigUInt)
}

/// A busca de rota: pools candidatos, um `aggregate3` de liquidez (v3) e reservas (v2), e um
/// de cotacao da v3. A v2 sai da conta das reservas, sem cotacao na cadeia.
public struct PancakeSearch: Sendable {
    public let intent: TradeIntent
    public let deployment: PancakeDeployment

    static let tiersPerLeg = 2
    static let routerOverheadGas: UInt64 = 60_000
    /// Gas de uma etapa da v2 no SmartRouter, so para comparar.
    static let v2HopGas: UInt64 = 90_000
    static let getReservesFunction = try! ABIFunction("getReserves()")  // 0902f1ac

    public init?(intent: TradeIntent) {
        guard let deployment = PancakeDeployment.on(intent.chain) else { return nil }
        self.intent = intent
        self.deployment = deployment
    }

    var tokenIn: EVMAddress { intent.sell.contract ?? deployment.wrappedNative }
    var tokenOut: EVMAddress { intent.buy.contract ?? deployment.wrappedNative }
    /// Nativo por embrulhado nao e troca.
    var usable: Bool { tokenIn != tokenOut }

    var pairs: [(EVMAddress, EVMAddress)] {
        guard usable else { return [] }
        var out = [(tokenIn, tokenOut)]
        for base in deployment.bases where base != tokenIn && base != tokenOut {
            out += [(tokenIn, base), (base, tokenOut)]
        }
        return out
    }

    public var pools: [PancakePool] {
        var out = [PancakePool]()
        var seen = Set<PancakePool>()
        for (a, b) in pairs {
            for fee in PancakeV3Fee.all where seen.insert(.v3(a, b, fee)).inserted { out.append(.v3(a, b, fee)) }
            if deployment.v2Factory != nil, seen.insert(.v2(a, b)).inserted { out.append(.v2(a, b)) }
        }
        return out
    }

    static func v3PoolAddress(_ a: EVMAddress, _ b: EVMAddress, _ fee: UInt32) -> EVMAddress {
        let (token0, token1) = UniswapPool.sorted(a, b)
        let salt = Hash.keccak256((try? ABI.encode([.address(token0), .address(token1), .uint(BigUInt(fee))],
                                                    types: [.address, .address, .uint(24)])) ?? [])
        let digest = Hash.keccak256([0xff] + PancakeDeployment.v3Deployer.bytes + salt + PancakeDeployment.v3PoolInitCodeHash)
        return EVMAddress(uncheckedBytes: Array(digest.suffix(20)))
    }

    static func v2PairAddress(factory: EVMAddress, _ a: EVMAddress, _ b: EVMAddress) -> EVMAddress {
        let (token0, token1) = UniswapPool.sorted(a, b)
        let salt = Hash.keccak256(token0.bytes + token1.bytes)
        let digest = Hash.keccak256([0xff] + factory.bytes + salt + PancakeDeployment.v2PairInitCodeHash)
        return EVMAddress(uncheckedBytes: Array(digest.suffix(20)))
    }

    public func depthCalls() throws -> [Multicall3.Call] {
        try pools.map { pool in
            switch pool {
            case .v3(let a, let b, let fee):
                return Multicall3.Call(target: Self.v3PoolAddress(a, b, fee), data: try UniswapSearch.liquidityFunction.encodeCall([]))
            case .v2(let a, let b):
                guard let factory = deployment.v2Factory else { throw TradeRefusal.malformed("v2") }
                return Multicall3.Call(target: Self.v2PairAddress(factory: factory, a, b), data: try Self.getReservesFunction.encodeCall([]))
            }
        }
    }

    public func depths(_ returnData: [UInt8]) throws -> [PancakePool: PancakeDepth] {
        let results = try Multicall3.decodeAggregate3(returnData, expected: pools.count)
        var out = [PancakePool: PancakeDepth]()
        for (pool, data) in zip(pools, results) {
            guard let data else { continue }
            switch pool {
            case .v3:
                guard data.count == 32 else { continue }
                let liquidity = BigUInt(bigEndian: data)
                if !liquidity.isZero { out[pool] = .v3(liquidity) }
            case .v2:
                guard data.count == 96 else { continue }
                let r0 = BigUInt(bigEndian: Array(data[0..<32])), r1 = BigUInt(bigEndian: Array(data[32..<64]))
                if !r0.isZero, !r1.isZero { out[pool] = .v2(reserve0: r0, reserve1: r1) }
            }
        }
        return out
    }

    /// As rotas: v3 direta em cada faixa com liquidez e, por ponte, as duas faixas mais fundas
    /// de cada perna; v2 direta e por ponte quando os pares tem reservas.
    public func routes(_ depth: [PancakePool: PancakeDepth]) -> [PancakeRoute] {
        guard usable else { return [] }
        var out = [PancakeRoute]()
        for fee in PancakeV3Fee.all where depth[.v3(tokenIn, tokenOut, fee)] != nil {
            out.append(.v3(tokens: [tokenIn, tokenOut], fees: [fee]))
        }
        for base in deployment.bases where base != tokenIn && base != tokenOut {
            let first = deepest(depth) { .v3(tokenIn, base, $0) }
            let second = deepest(depth) { .v3(base, tokenOut, $0) }
            for a in first { for b in second { out.append(.v3(tokens: [tokenIn, base, tokenOut], fees: [a, b])) } }
        }
        if deployment.v2Factory != nil {
            if depth[.v2(tokenIn, tokenOut)] != nil { out.append(.v2(tokens: [tokenIn, tokenOut])) }
            for base in deployment.bases where base != tokenIn && base != tokenOut
                && depth[.v2(tokenIn, base)] != nil && depth[.v2(base, tokenOut)] != nil {
                out.append(.v2(tokens: [tokenIn, base, tokenOut]))
            }
        }
        return out
    }

    private func deepest(_ depth: [PancakePool: PancakeDepth], _ pool: (UInt32) -> PancakePool) -> [UInt32] {
        let found = PancakeV3Fee.all.compactMap { fee -> (UInt32, BigUInt)? in
            if case .v3(let liquidity)? = depth[pool(fee)] { return (fee, liquidity) }
            return nil
        }
        return Array(found.sorted { $0.1 > $1.1 }.prefix(Self.tiersPerLeg).map(\.0))
    }

    /// Cotacao da v3 no QuoterV2 (a mesma interface da Uniswap); a v2 nao entra aqui.
    public func quoteCalls(_ routes: [PancakeRoute]) throws -> [Multicall3.Call] {
        let amount = intent.amountIn
        return try routes.compactMap { route in
            guard case .v3(let tokens, let fees) = route else { return nil }
            if fees.count == 1 {
                return Multicall3.Call(target: PancakeDeployment.v3Quoter, data: try UniswapSearch.v3QuoteSingle.encodeCall([
                    .tuple([.address(tokens[0]), .address(tokens[1]), .uint(amount), .uint(BigUInt(fees[0])), .uint(0)]),
                ]))
            }
            return Multicall3.Call(target: PancakeDeployment.v3Quoter, data: try UniswapSearch.v3QuotePath.encodeCall([
                .bytes(UniswapCalldata.v3Path(tokens: tokens, fees: fees)), .uint(amount),
            ]))
        }
    }

    /// O que a v2 entrega pelas reservas: a conta do par com 0,25% de taxa, etapa a etapa,
    /// arredondada para baixo como o contrato. Token com taxa na transferencia entrega menos:
    /// o minimo sai alto, a simulacao recusa, e a PancakeSwap fica de fora dessa troca.
    static func v2AmountOut(_ amountIn: BigUInt, tokens: [EVMAddress], depth: [PancakePool: PancakeDepth]) -> BigUInt? {
        var amount = amountIn
        for (from, to) in zip(tokens, tokens.dropFirst()) {
            guard case .v2(let r0, let r1)? = depth[.v2(from, to)] else { return nil }
            let fromIsToken0 = from.bytes.lexicographicallyPrecedes(to.bytes)
            let (reserveIn, reserveOut) = fromIsToken0 ? (r0, r1) : (r1, r0)
            let withFee = amount * BigUInt(9_975)
            amount = withFee * reserveOut / (reserveIn * BigUInt(10_000) + withFee)
            if amount.isZero { return nil }
        }
        return amount
    }

    /// A melhor rota: a que mais entrega; empate, a de menos etapas.
    public func best(_ routes: [PancakeRoute], depth: [PancakePool: PancakeDepth], quotes returnData: [UInt8]?)
        throws -> (route: PancakeRoute, amountOut: BigUInt, gas: UInt64)? {
        let v3Routes = routes.filter { if case .v3 = $0 { return true }; return false }
        let results = try returnData.map { try Multicall3.decodeAggregate3($0, expected: v3Routes.count) } ?? []
        var v3Answers = [PancakeRoute: [UInt8]?]()
        for (route, data) in zip(v3Routes, results) { v3Answers[route] = data }

        var best: (route: PancakeRoute, amountOut: BigUInt, gas: UInt64)?
        for route in routes {
            let amountOut: BigUInt
            let gas: UInt64
            switch route {
            case .v3:
                guard let data = v3Answers[route] ?? nil, data.count >= 128 else { continue }
                amountOut = BigUInt(bigEndian: Array(data[0..<32]))
                gas = min(BigUInt(bigEndian: Array(data[96..<128])).uint64 ?? 1_000_000, 1_000_000) + Self.routerOverheadGas
            case .v2(let tokens):
                guard let out = Self.v2AmountOut(intent.amountIn, tokens: tokens, depth: depth) else { continue }
                amountOut = out
                gas = Self.v2HopGas * UInt64(route.hops) + Self.routerOverheadGas
            }
            guard !amountOut.isZero else { continue }
            if let current = best {
                if amountOut > current.amountOut || (amountOut == current.amountOut && route.hops < current.route.hops) {
                    best = (route, amountOut, gas)
                }
            } else {
                best = (route, amountOut, gas)
            }
        }
        return best
    }
}
