import EscaliburCore
import Foundation

// A allowlist de routers, compilada.
//
// Para cada rede e provedor: o `to` aceito, o spender que recebe o approve exato, as
// funcoes aceitas (seletores tirados do ABI verificado) e como conferir que o codigo
// atras do endereco ainda e o que foi auditado. A allowlist vive no binario: a config
// remota so pode desligar provedor, nunca acrescentar endereco (docs/blockchain.md 3.5).
//
// Conferencia feita em 25/09/2026, para cada endereco e cada uma das 7 redes:
// - `eth_getCode` nao vazio em dois RPCs;
// - codigo verificado no Sourcify (sourcify.dev/server/v2/contract/<chainId>/<endereco>):
//   AugustusV6 (solc 0.8.22), MetaAggregationRouterV2, GenericSwapFacetV3,
//   OpenOceanExchange (implementacao atras do proxy);
// - o endereco devolvido pela API ao vivo (`to` da transacao e `approvalAddress`/
//   `tokenTransferProxy`/`routerAddress`) bateu com o daqui.

/// Como conferir, antes de assinar, que o codigo atras do router e o que foi lido.
public enum TradeRouterPin: Sendable, Equatable {
    /// Contrato sem proxy: o codigo e imutavel. A Augustus V6.2 e um diamond, mas
    /// `swapExactAmountIn` esta no bytecode principal (Routers.sol), e funcao declarada
    /// tem precedencia sobre o fallback de facetas.
    case immutable
    /// Proxy EIP-1967: a implementacao no slot
    /// `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` tem de ser
    /// esta. Upgrade do dono do proxy desliga o provedor ate a proxima versao do app.
    case eip1967(implementation: EVMAddress)
    /// Diamond EIP-2535: `facetAddress(seletor)` tem de devolver esta faceta para cada
    /// seletor aceito.
    case diamondFacet(EVMAddress)

    /// `keccak256("eip1967.proxy.implementation") - 1`.
    public static let eip1967ImplementationSlot = [UInt8](hex: "360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc")!

    /// `facetAddress(bytes4)` do DiamondLoupe (EIP-2535).
    public static let facetAddressFunction = try! ABIFunction("facetAddress(bytes4)")  // cdffacc6

    /// O endereco que a leitura na cadeia tem de devolver; `nil` se nao ha o que ler.
    public var expected: EVMAddress? {
        switch self {
        case .immutable: return nil
        case .eip1967(let implementation): return implementation
        case .diamondFacet(let facet): return facet
        }
    }
}

/// Um router aceito numa rede.
public struct TradeRouter: Sendable, Equatable {
    public let provider: TradeProvider
    public let chainID: UInt64
    /// O `to` da transacao de troca.
    public let address: EVMAddress
    /// Quem recebe o `approve` exato do token vendido.
    public let spender: EVMAddress
    public let pin: TradeRouterPin
    /// As funcoes aceitas. Seletor fora desta lista e recusado antes de decodificar.
    public let functions: [ABIFunction]
    /// LI.FI: o contrato de taxa que pode aparecer dentro do `swapData`.
    public let feeForwarder: EVMAddress?

    public var selectors: Set<[UInt8]> { Set(functions.map(\.selector)) }

    /// A calldata de `facetAddress(seletor)` para cada seletor aceito (so diamond).
    public var facetQueries: [[UInt8]] {
        guard case .diamondFacet = pin else { return [] }
        return functions.compactMap { function in
            try? TradeRouterPin.facetAddressFunction.encodeCall([.fixedBytes(function.selector)])
        }
    }
}

public enum TradeAllowlist {
    static func address(_ hex: String) -> EVMAddress {
        EVMAddress(uncheckedBytes: [UInt8](hex: hex)!)
    }

    /// As 7 redes EVM da v1, pelo chainId compilado.
    static let evmChainIDs: [UInt64] = [1, 42161, 8453, 10, 137, 56, 43114]

    // MARK: Velora (ex-ParaSwap), Augustus V6.2

    /// Mesmo endereco nas 7 redes. Fonte: developers.velora.xyz, "Augustus v6.2 smart
    /// contracts"; Sourcify "AugustusV6" nas 7; `contractAddress` e `tokenTransferProxy`
    /// da API ao vivo. O spender e o proprio router (v6.2 nao tem TokenTransferProxy
    /// separado).
    static let velora = address("6a000f20005980200259b80c5102003040001068")

    // MARK: KyberSwap, MetaAggregationRouterV2

    /// Mesmo endereco nas 7 redes. Fonte: docs.kyberswap.com (Aggregator API, "router
    /// address"); Sourcify "MetaAggregationRouterV2" nas 7; `routerAddress` da API ao
    /// vivo. Sem proxy: `Ownable` so mexe em whitelist e resgate.
    static let kyber = address("6131b5fae19ea4f9d964eac0408e4408b66337b5")

    // MARK: LI.FI, LiFiDiamond

    /// Mesmo diamond nas 7 redes. Fonte: github.com/lifinance/contracts,
    /// deployments/<rede>.json (`LiFiDiamond`, `GenericSwapFacetV3`, `FeeForwarder`),
    /// conferido com `facetAddress(seletor)` na cadeia em 25/09/2026. O
    /// `swapTokensGeneric` antigo nao esta mais no diamond (facetAddress devolve zero),
    /// entao a v1 so aceita as seis funcoes da GenericSwapFacetV3.
    static let lifiDiamond = address("1231deb6f5749ef6ce6943a275a1d3e7486f4eae")
    /// FeeForwarder 2.0.0, mesmo endereco e mesmo codehash nas 7 redes (Sourcify na Base).
    static let lifiFeeForwarder = address("ce40449b773a3e6e5e769adb4e567179d4828cbd")
    static let lifiFacets: [UInt64: EVMAddress] = [
        1: address("8c9dba771220ed09580b77f0765e7153fbde7790"),
        10: address("8dfdaebb42655a4a4e2b89687dd117074ae8c665"),
        42161: address("31a9b1835864706af10103b31ea2b79bdb995f5f"),
        8453: address("31a9b1835864706af10103b31ea2b79bdb995f5f"),
        137: address("31a9b1835864706af10103b31ea2b79bdb995f5f"),
        56: address("31a9b1835864706af10103b31ea2b79bdb995f5f"),
        43114: address("31a9b1835864706af10103b31ea2b79bdb995f5f"),
    ]

    // MARK: De¹ (ex-OpenOcean), OpenOceanExchange

    /// Proxy transparente, mesmo endereco em todas as redes; a implementacao muda por
    /// rede e fica fixada aqui. So entram as redes em que a implementacao esta
    /// verificada: Sourcify em Ethereum, Arbitrum, Base, OP e BNB; Blockscout na Polygon.
    /// Avalanche fica de fora: a implementacao `0x6a27...f993` nao esta verificada em
    /// nenhum explorador que conferimos.
    static let de1Proxy = address("6352a56caadc4f1e25cd6c75970fa768a3304e64")
    static let de1Implementations: [UInt64: EVMAddress] = [
        1: address("e29b6b6e96befe1e9c6f948bcb5a3f71058bda9b"),
        42161: address("94e8da4a7707b2edd1688c1ab3b09fd0fb8267eb"),
        8453: address("201263cea08e8f1d6e2fdd1fd2ca44bf6145e2af"),
        10: address("dcbf4cb83d27c408b30dd7f39bfcabd7176b1ba3"),
        137: address("2691f337abeb0146f16441ca4f82f363275851d5"),
        56: address("86f2058ba5e1466260055d1f3dab38b15f98be09"),
    ]

    // MARK: Consulta

    /// O router de um provedor numa rede, ou `nil` se o provedor nao atende ali.
    public static func router(for provider: TradeProvider, on chain: Chain) -> TradeRouter? {
        guard chain.family == .evm, let chainID = chain.evmChainID, evmChainIDs.contains(chainID) else { return nil }
        switch provider {
        case .velora:
            return TradeRouter(provider: .velora, chainID: chainID, address: velora, spender: velora,
                               pin: .immutable, functions: VeloraCalldata.functions, feeForwarder: nil)
        case .kyberSwap:
            return TradeRouter(provider: .kyberSwap, chainID: chainID, address: kyber, spender: kyber,
                               pin: .immutable, functions: KyberCalldata.functions, feeForwarder: nil)
        case .lifi:
            guard let facet = lifiFacets[chainID] else { return nil }
            return TradeRouter(provider: .lifi, chainID: chainID, address: lifiDiamond, spender: lifiDiamond,
                               pin: .diamondFacet(facet), functions: LiFiCalldata.functions, feeForwarder: lifiFeeForwarder)
        case .de1:
            guard let implementation = de1Implementations[chainID] else { return nil }
            return TradeRouter(provider: .de1, chainID: chainID, address: de1Proxy, spender: de1Proxy,
                               pin: .eip1967(implementation: implementation), functions: De1Calldata.functions, feeForwarder: nil)
        }
    }

    /// Todos os routers aceitos numa rede.
    public static func routers(on chain: Chain) -> [TradeRouter] {
        TradeProvider.allCases.compactMap { router(for: $0, on: chain) }
    }

    /// Os spenders de troca de uma rede, para a tela de aprovacoes vigentes e revogacao
    /// (docs/seguranca.md 4.4), incluindo o VaultRelayer da CoW.
    public static func spenders(on chain: Chain) -> Set<EVMAddress> {
        var out = Set(routers(on: chain).map(\.spender))
        if CoWProtocol.supports(chain) { out.insert(CoWProtocol.vaultRelayer) }
        return out
    }
}
