import EscaliburCore
import Foundation

// Uniswap: os contratos por rede e a busca de rota na cadeia.
//
// A Uniswap entra como provedor direto, sem API: a cotacao e lida nos contratos de
// cotacao da propria Uniswap (QuoterV2 da v3, V4Quoter da v4) pelos RPCs da rede, e a
// calldata do Universal Router e montada aqui (`UniswapCalldata`). A API oficial pede
// chave, e chave nao mora no app (pedido do dono, 17/10/2026).
//
// Fonte dos enderecos: github.com/Uniswap/sdks (sdk-core/src/addresses.ts e
// universal-router-sdk/src/utils/constants.ts, Universal Router 2.0), conferida em
// 17/10/2026 em cada uma das 9 redes:
// - codigo em dois RPCs da rede, igual nos dois, para router, Permit2, QuoterV2,
//   PoolManager, StateView, V4Quoter e o embrulhado da moeda nativa;
// - o Universal Router sem proxy (slot EIP-1967 zerado), com o mesmo tamanho de codigo
//   (19.499 bytes) nas 9, e `poolManager()` igual ao PoolManager da v4 daqui;
// - Sourcify: "UniversalRouter" (solc 0.8.26) na Ethereum, Base e BNB; "Permit2" na
//   Ethereum;
// - o endereco de pool da v3 calculado com o hash de codigo abaixo bateu com
//   `getPool` da fabrica nas 9 (WETH/USDC ou WBNB/USDT, taxas 0,05% e 0,3%).
// O QuoterV2 da Ethereum, Arbitrum, OP e Polygon e o 0x61fF...B21e: o SDK ainda lista
// o Quoter v1 nessas, de outra interface.

/// Os contratos da Uniswap numa rede.
public struct UniswapDeployment: Sendable, Equatable {
    public let chainID: UInt64
    /// Universal Router 2.0: o `to` da troca.
    public let router: EVMAddress
    /// O token embrulhado da moeda nativa, que a v3 usa no lugar dela.
    public let wrappedNative: EVMAddress
    public let v3Factory: EVMAddress
    public let v3Quoter: EVMAddress
    public let v4StateView: EVMAddress
    public let v4Quoter: EVMAddress
    /// As stablecoins da lista curada que servem de ponte numa rota de duas etapas.
    public let stables: [EVMAddress]

    static func address(_ hex: String) -> EVMAddress { TradeAllowlist.address(hex) }

    /// Fabrica 0x1F98...F984 e QuoterV2 0x61fF...B21e: Ethereum, Arbitrum, OP e Polygon.
    static let canonicalFactory = address("1f98431c8ad98523631ae4a59f267346ea31f984")
    static let canonicalQuoter = address("61ffe014ba17989e743c5f6cb21bf9697530b21e")
    static let opStackWETH = address("4200000000000000000000000000000000000006")

    public static let all: [UInt64: UniswapDeployment] = [
        1: .init(chainID: 1, router: address("66a9893cc07d91d95644aedd05d03f95e1dba8af"),
                 wrappedNative: address("c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"),
                 v3Factory: canonicalFactory, v3Quoter: canonicalQuoter,
                 v4StateView: address("7ffe42c4a5deea5b0fec41c94c136cf115597227"),
                 v4Quoter: address("52f0e24d1c21c8a0cb1e5a5dd6198556bd9e1203"),
                 stables: [address("a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"), address("dac17f958d2ee523a2206206994597c13d831ec7")]),
        10: .init(chainID: 10, router: address("851116d9223fabed8e56c0e6b8ad0c31d98b3507"),
                  wrappedNative: opStackWETH,
                  v3Factory: canonicalFactory, v3Quoter: canonicalQuoter,
                  v4StateView: address("c18a3169788f4f75a170290584eca6395c75ecdb"),
                  v4Quoter: address("1f3131a13296fb91c90870043742c3cdbff1a8d7"),
                  stables: [address("0b2c639c533813f4aa9d7837caf62653d097ff85"), address("01bff41798a0bcf287b996046ca68b395dbc1071")]),
        42161: .init(chainID: 42161, router: address("a51afafe0263b40edaef0df8781ea9aa03e381a3"),
                     wrappedNative: address("82af49447d8a07e3bd95bd0d56f35241523fbab1"),
                     v3Factory: canonicalFactory, v3Quoter: canonicalQuoter,
                     v4StateView: address("76fd297e2d437cd7f76d50f01afe6160f86e9990"),
                     v4Quoter: address("3972c00f7ed4885e145823eb7c655375d275a1c5"),
                     stables: [address("af88d065e77c8cc2239327c5edb3a432268e5831"), address("fd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9")]),
        137: .init(chainID: 137, router: address("1095692a6237d83c6a72f3f5efedb9a670c49223"),
                   wrappedNative: address("0d500b1d8e8ef31e21c99d1db9a6444d3adf1270"),
                   v3Factory: canonicalFactory, v3Quoter: canonicalQuoter,
                   v4StateView: address("5ea1bd7974c8a611cbab0bdcafcb1d9cc9b3ba5a"),
                   v4Quoter: address("b3d5c3dfc3a7aebff71895a7191796bffc2c81b9"),
                   stables: [address("3c499c542cef5e3811e1192ce70d8cc03d5c3359"), address("c2132d05d31c914a87c6611c10748aeb04b58e8f")]),
        56: .init(chainID: 56, router: address("1906c1d672b88cd1b9ac7593301ca990f94eae07"),
                  wrappedNative: address("bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c"),
                  v3Factory: address("db1d10011ad0ff90774d0c6bb92e5c5c8b4461f7"),
                  v3Quoter: address("78d78e420da98ad378d7799be8f4af69033eb077"),
                  v4StateView: address("d13dd3d6e93f276fafc9db9e6bb47c1180aee0c4"),
                  v4Quoter: address("9f75dd27d6664c475b90e105573e550ff69437b0"),
                  stables: [address("55d398326f99059ff775485246999027b3197955"), address("8ac76a51cc950d9822d68b83fe1ad97b32cd580d")]),
        43114: .init(chainID: 43114, router: address("94b75331ae8d42c1b61065089b7d48fe14aa73b7"),
                     wrappedNative: address("b31f66aa3c1e785363f0875a1b74e27b85fd66c7"),
                     v3Factory: address("740b1c1de25031c31ff4fc9a62f554a55cdc1bad"),
                     v3Quoter: address("be0f5544ec67e9b3b2d979aaa43f18fd87e6257f"),
                     v4StateView: address("c3c9e198c735a4b97e3e683f391ccbdd60b69286"),
                     v4Quoter: address("be40675bb704506a3c2ccfb762dcfd1e979845c2"),
                     stables: [address("b97ef9ef8734c71904d8002f8b6bc66dd9c48a6e"), address("9702230a8ea53601f5cd2dc00fdbc13d4df4a8c7")]),
        8453: .init(chainID: 8453, router: address("6ff5693b99212da76ad316178a184ab56d299b43"),
                    wrappedNative: opStackWETH,
                    v3Factory: address("33128a8fc17869897dce68ed026d694621f6fdfd"),
                    v3Quoter: address("3d4e44eb1374240ce5f1b871ab261cd16335b76a"),
                    v4StateView: address("a3c0c9b65bad0b08107aa264b0f3db444b867a71"),
                    v4Quoter: address("0d5e0f971ed27fbff6c2837bf31316121532048d"),
                    stables: [address("833589fcd6edb6e08f4c7c32d4f71b54bda02913")]),
        130: .init(chainID: 130, router: address("ef740bf23acae26f6492b10de645d6b98dc8eaf3"),
                   wrappedNative: opStackWETH,
                   v3Factory: address("1f98400000000000000000000000000000000003"),
                   v3Quoter: address("385a5cf5f83e99f7bb2852b6a19c3538b9fa7658"),
                   v4StateView: address("86e8631a016f9068c3f085faf484ee3f5fdee8f2"),
                   v4Quoter: address("333e3c607b141b18ff6de9f258db6e77fe7491e0"),
                   stables: [address("078d782b760474a361dda0af3839290b0ef57ad6"), address("9151434b16b9763660705744891fa906f660ecc5")]),
        59144: .init(chainID: 59144, router: address("661e93cca42afacb172121ef892830ca3b70f08d"),
                     wrappedNative: address("e5d7c2a44ffddf6b295a15c148167daaaf5cf34f"),
                     v3Factory: address("31fafd4889fa1269f7a13a66ee0fb458f27d72a9"),
                     v3Quoter: address("42be4d6527829fefa1493e1fb9f3676d2425c3c1"),
                     v4StateView: address("e861de206e460a8b936b05ad3816520b58ccdf9b"),
                     v4Quoter: address("2c125569c0bee20a66e33e5491c552b37ebd9934"),
                     stables: [address("176211869ca2b568f2a7d4ee941e073a821ee1ff")]),
    ]

    public static func on(_ chain: Chain) -> UniswapDeployment? {
        guard chain.family == .evm, let id = chain.evmChainID else { return nil }
        return all[id]
    }

    /// Pontes da v3: o embrulhado e as stablecoins.
    var v3Bases: [EVMAddress] { [wrappedNative] + stables }
    /// Pontes da v4: a moeda nativa (endereco zero, como a v4 a escreve) e as stablecoins.
    var v4Bases: [EVMAddress] { [.zero] + stables }

    /// Hash do codigo de criacao do pool da v3 (`POOL_INIT_CODE_HASH`), o mesmo nas 9.
    static let v3PoolInitCodeHash = [UInt8](hex: "e34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54")!
}

// MARK: Pools e rotas

/// As faixas de taxa da v3, em milionesimos.
public enum UniswapV3Fee {
    public static let all: [UInt32] = [100, 500, 3_000, 10_000]
}

/// Uma faixa de pool da v4 sem hook: taxa e espacamento de ticks, os pares padrao da
/// Uniswap. Pool com hook fica de fora: hook e codigo de terceiro rodando no meio da troca.
public struct UniswapV4Tier: Sendable, Hashable {
    public let fee: UInt32
    public let tickSpacing: Int32

    public static let all: [UniswapV4Tier] = [
        .init(fee: 100, tickSpacing: 1), .init(fee: 500, tickSpacing: 10),
        .init(fee: 3_000, tickSpacing: 60), .init(fee: 10_000, tickSpacing: 200),
    ]

    public init(fee: UInt32, tickSpacing: Int32) {
        self.fee = fee
        self.tickSpacing = tickSpacing
    }
}

/// Um caminho de uma ou duas etapas.
public enum UniswapRoute: Sendable, Hashable {
    /// v3: os tokens do caminho (o embrulhado no lugar do nativo) e a taxa de cada pool.
    case v3(tokens: [EVMAddress], fees: [UInt32])
    /// v4: as moedas do caminho (o endereco zero e o nativo) e a faixa de cada pool.
    case v4(currencies: [EVMAddress], tiers: [UniswapV4Tier])

    public var hops: Int {
        switch self {
        case .v3(_, let fees): return fees.count
        case .v4(_, let tiers): return tiers.count
        }
    }

    /// "v3" ou "v4", para a tela e para o ranking por gas.
    public var version: String {
        if case .v3 = self { return "v3" }
        return "v4"
    }
}

/// Um pool candidato, para a leitura de liquidez.
public enum UniswapPool: Sendable, Hashable {
    case v3(a: EVMAddress, b: EVMAddress, fee: UInt32)
    case v4(a: EVMAddress, b: EVMAddress, tier: UniswapV4Tier)

    static func sorted(_ a: EVMAddress, _ b: EVMAddress) -> (EVMAddress, EVMAddress) {
        a.bytes.lexicographicallyPrecedes(b.bytes) ? (a, b) : (b, a)
    }

    static func v3(_ a: EVMAddress, _ b: EVMAddress, _ fee: UInt32) -> UniswapPool {
        let (x, y) = sorted(a, b)
        return .v3(a: x, b: y, fee: fee)
    }

    static func v4(_ a: EVMAddress, _ b: EVMAddress, _ tier: UniswapV4Tier) -> UniswapPool {
        let (x, y) = sorted(a, b)
        return .v4(a: x, b: y, tier: tier)
    }
}

/// A busca de rota: pools candidatos, a leitura de liquidez de cada um num `aggregate3`
/// so, e as cotacoes das rotas cujos pools tem liquidez, noutro. Tudo puro; quem fala com
/// a rede e o `UniswapClient` de EscaliburNetwork.
public struct UniswapSearch: Sendable {
    public let intent: TradeIntent
    public let deployment: UniswapDeployment

    /// Duas etapas: no maximo as duas faixas de maior liquidez de cada perna.
    static let tiersPerLeg = 2
    /// Gas do router alem do que o quoter mede (comandos, transferencia da entrada e da
    /// saida). So para comparar com os outros provedores; o plano usa a simulacao.
    static let routerOverheadGas: UInt64 = 60_000

    public init?(intent: TradeIntent) {
        guard let deployment = UniswapDeployment.on(intent.chain) else { return nil }
        self.intent = intent
        self.deployment = deployment
    }

    var v3In: EVMAddress { intent.sell.contract ?? deployment.wrappedNative }
    var v3Out: EVMAddress { intent.buy.contract ?? deployment.wrappedNative }
    var v4In: EVMAddress { intent.sell.contract ?? .zero }
    var v4Out: EVMAddress { intent.buy.contract ?? .zero }

    /// Moeda nativa por embrulhado (ou o contrario) nao e troca: e embrulhar.
    var v3Usable: Bool { v3In != v3Out }
    var v4Usable: Bool {
        let pair = Set([v4In, v4Out])
        return !(pair.contains(.zero) && pair.contains(deployment.wrappedNative))
    }

    /// Os pares que as rotas podem usar: o direto e, por cada ponte, as duas pernas.
    var v3Pairs: [(EVMAddress, EVMAddress)] {
        guard v3Usable else { return [] }
        var pairs = [(v3In, v3Out)]
        for base in deployment.v3Bases where base != v3In && base != v3Out {
            pairs += [(v3In, base), (base, v3Out)]
        }
        return pairs
    }

    var v4Pairs: [(EVMAddress, EVMAddress)] {
        guard v4Usable else { return [] }
        var pairs = [(v4In, v4Out)]
        for base in deployment.v4Bases where base != v4In && base != v4Out {
            pairs += [(v4In, base), (base, v4Out)]
        }
        return pairs
    }

    /// Os pools candidatos, sem repeticao, na ordem.
    public var pools: [UniswapPool] {
        var out = [UniswapPool]()
        var seen = Set<UniswapPool>()
        for (a, b) in v3Pairs {
            for fee in UniswapV3Fee.all where seen.insert(.v3(a, b, fee)).inserted { out.append(.v3(a, b, fee)) }
        }
        for (a, b) in v4Pairs {
            for tier in UniswapV4Tier.all where seen.insert(.v4(a, b, tier)).inserted { out.append(.v4(a, b, tier)) }
        }
        return out
    }

    // MARK: Liquidez

    static let liquidityFunction = try! ABIFunction("liquidity()")  // 1a686502
    static let getLiquidityFunction = try! ABIFunction("getLiquidity(bytes32)")  // fa6793d5

    /// A leitura de liquidez de cada pool: `liquidity()` no endereco do pool da v3
    /// (calculado pela fabrica, sem perguntar), `getLiquidity(id)` no StateView da v4.
    public func liquidityCalls() throws -> [Multicall3.Call] {
        try pools.map { pool in
            switch pool {
            case .v3(let a, let b, let fee):
                return Multicall3.Call(target: Self.v3PoolAddress(factory: deployment.v3Factory, a, b, fee), data: try Self.liquidityFunction.encodeCall([]))
            case .v4(let a, let b, let tier):
                return Multicall3.Call(target: deployment.v4StateView,
                                       data: try Self.getLiquidityFunction.encodeCall([.fixedBytes(Self.v4PoolID(a, b, tier))]))
            }
        }
    }

    /// Endereco do pool da v3: CREATE2 da fabrica com `keccak(abi.encode(token0, token1, fee))`.
    static func v3PoolAddress(factory: EVMAddress, _ a: EVMAddress, _ b: EVMAddress, _ fee: UInt32) -> EVMAddress {
        let (token0, token1) = UniswapPool.sorted(a, b)
        let salt = Hash.keccak256((try? ABI.encode([.address(token0), .address(token1), .uint(BigUInt(fee))],
                                                    types: [.address, .address, .uint(24)])) ?? [])
        let digest = Hash.keccak256([0xff] + factory.bytes + salt + UniswapDeployment.v3PoolInitCodeHash)
        return EVMAddress(uncheckedBytes: Array(digest.suffix(20)))
    }

    /// O id do pool da v4: `keccak(abi.encode(PoolKey))`, sem hook.
    static func v4PoolID(_ a: EVMAddress, _ b: EVMAddress, _ tier: UniswapV4Tier) -> [UInt8] {
        Hash.keccak256((try? ABI.encode(UniswapCalldata.poolKey(a, b, tier).tupleValue ?? [], types: UniswapCalldata.poolKeyComponents)) ?? [])
    }

    /// A liquidez de cada pool, na ordem de `pools`; zero quando nao existe.
    public func liquidities(_ returnData: [UInt8]) throws -> [UniswapPool: BigUInt] {
        let results = try Multicall3.decodeAggregate3(returnData, expected: pools.count)
        var out = [UniswapPool: BigUInt]()
        for (pool, data) in zip(pools, results) {
            guard let data, data.count == 32 else { continue }
            let value = BigUInt(bigEndian: data)
            if !value.isZero { out[pool] = value }
        }
        return out
    }

    // MARK: Rotas e cotacao

    /// As rotas que valem cotar: o par direto em cada faixa com liquidez e, por ponte, as
    /// combinacoes das faixas de maior liquidez de cada perna.
    public func routes(liquidity: [UniswapPool: BigUInt]) -> [UniswapRoute] {
        var out = [UniswapRoute]()
        if v3Usable {
            for fee in UniswapV3Fee.all where liquidity[.v3(v3In, v3Out, fee)] != nil {
                out.append(.v3(tokens: [v3In, v3Out], fees: [fee]))
            }
            for base in deployment.v3Bases where base != v3In && base != v3Out {
                let first = best(UniswapV3Fee.all, liquidity) { .v3(v3In, base, $0) }
                let second = best(UniswapV3Fee.all, liquidity) { .v3(base, v3Out, $0) }
                for a in first { for b in second { out.append(.v3(tokens: [v3In, base, v3Out], fees: [a, b])) } }
            }
        }
        if v4Usable {
            for tier in UniswapV4Tier.all where liquidity[.v4(v4In, v4Out, tier)] != nil {
                out.append(.v4(currencies: [v4In, v4Out], tiers: [tier]))
            }
            for base in deployment.v4Bases where base != v4In && base != v4Out {
                let first = best(UniswapV4Tier.all, liquidity) { .v4(v4In, base, $0) }
                let second = best(UniswapV4Tier.all, liquidity) { .v4(base, v4Out, $0) }
                for a in first { for b in second { out.append(.v4(currencies: [v4In, base, v4Out], tiers: [a, b])) } }
            }
        }
        return out
    }

    private func best<T>(_ options: [T], _ liquidity: [UniswapPool: BigUInt], _ pool: (T) -> UniswapPool) -> [T] {
        let found = options.compactMap { option in liquidity[pool(option)].map { (option, $0) } }
        return Array(found.sorted { $0.1 > $1.1 }.prefix(Self.tiersPerLeg).map(\.0))
    }

    static let v3QuoteSingle = try! ABIFunction("quoteExactInputSingle((address,address,uint256,uint24,uint160))")  // c6a5026a
    static let v3QuotePath = try! ABIFunction("quoteExactInput(bytes,uint256)")  // cdca1753
    static let v4QuoteSingle = try! ABIFunction(
        "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))"
    )
    static let v4QuotePath = try! ABIFunction("quoteExactInput((address,(address,uint24,int24,address,bytes)[],uint128))")

    /// A cotacao de cada rota, no quoter da versao.
    public func quoteCalls(_ routes: [UniswapRoute]) throws -> [Multicall3.Call] {
        let amount = intent.amountIn
        return try routes.map { route in
            switch route {
            case .v3(let tokens, let fees) where fees.count == 1:
                return Multicall3.Call(target: deployment.v3Quoter, data: try Self.v3QuoteSingle.encodeCall([
                    .tuple([.address(tokens[0]), .address(tokens[1]), .uint(amount), .uint(BigUInt(fees[0])), .uint(0)]),
                ]))
            case .v3(let tokens, let fees):
                return Multicall3.Call(target: deployment.v3Quoter, data: try Self.v3QuotePath.encodeCall([
                    .bytes(UniswapCalldata.v3Path(tokens: tokens, fees: fees)), .uint(amount),
                ]))
            case .v4(let currencies, let tiers) where tiers.count == 1:
                let key = UniswapCalldata.poolKey(currencies[0], currencies[1], tiers[0])
                return Multicall3.Call(target: deployment.v4Quoter, data: try Self.v4QuoteSingle.encodeCall([
                    .tuple([key, .bool(UniswapCalldata.zeroForOne(currencies[0], currencies[1])), .uint(amount), .bytes([])]),
                ]))
            case .v4(let currencies, let tiers):
                return Multicall3.Call(target: deployment.v4Quoter, data: try Self.v4QuotePath.encodeCall([
                    .tuple([.address(currencies[0]), UniswapCalldata.pathKeys(currencies: currencies, tiers: tiers), .uint(amount)]),
                ]))
            }
        }
    }

    /// A melhor rota: a que mais entrega; empate, a de menos etapas. O gas e o que o quoter
    /// mediu mais o do router.
    public func best(_ routes: [UniswapRoute], returnData: [UInt8]) throws -> (route: UniswapRoute, amountOut: BigUInt, gas: UInt64)? {
        let results = try Multicall3.decodeAggregate3(returnData, expected: routes.count)
        var best: (route: UniswapRoute, amountOut: BigUInt, gas: UInt64)?
        for (route, data) in zip(routes, results) {
            guard let data, data.count >= 64 else { continue }
            let amountOut = BigUInt(bigEndian: Array(data[0..<32]))
            // O gas e a ultima palavra fixa: a 2a na v4, a 4a na v3 (as listas da cotacao por
            // caminho vem por referencia, entao a 4a palavra continua sendo o gas).
            let gasWord: [UInt8]
            if case .v3 = route {
                guard data.count >= 128 else { continue }
                gasWord = Array(data[96..<128])
            } else {
                gasWord = Array(data[32..<64])
            }
            guard !amountOut.isZero else { continue }
            let measured = min(BigUInt(bigEndian: gasWord).uint64 ?? 1_000_000, 1_000_000)
            let candidate = (route: route, amountOut: amountOut, gas: measured + Self.routerOverheadGas)
            if let current = best {
                if amountOut > current.amountOut || (amountOut == current.amountOut && route.hops < current.route.hops) { best = candidate }
            } else {
                best = candidate
            }
        }
        return best
    }
}
