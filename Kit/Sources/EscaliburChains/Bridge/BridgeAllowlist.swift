import EscaliburCore
import Foundation

// A allowlist da ponte, compilada e rede por rede (docs/seguranca.md 4.12).
//
// Primeira leva: Ethereum, Arbitrum, Base e Optimism (CCTP V2 rapido, SpokePool do
// Across, ETH nativo e simulacao em dois RPCs). Segunda leva abaixo. Terceira (14/10/2026):
// a BNB, so pelo Across. O resto fica de fora ate fechar tudo:
// - BNB sem CCTP: o TokenMessengerV2 da Ethereum aceita o dominio 17, mas na BNB o USDC
//   nao e cunhado (`getLocalToken` zero para todas as origens, `burnLimitsPerMessage`
//   zero). Uma queima para la se perderia: a BNB nao tem `cctp` aqui, e o app ainda
//   confere `getLocalToken` no destino antes de assinar qualquer queima.
// - Celo: sem CCTP. Sonic, X Layer e Celo: sem SpokePool.
// - O SpokePool da Base, 0x09ae...bEC64, tem codigo com o mesmo endereco na X Layer e na
//   Celo, e la nao e SpokePool (`chainId()` reverte). Endereco vale so na rede listada.
//
// Conferencia em 11 e 12/10/2026, cada valor em duas leituras independentes (o agente
// de seguranca e a sessao principal), cada leitura em dois RPCs:
// - endereco nas fontes oficiais: developers.circle.com (contract-addresses,
//   supported-chains-and-domains, usdc-contract-addresses) e docs.across.to mais
//   across-protocol/contracts broadcast/deployed-addresses.json, que concordam;
// - `localDomain()` do MessageTransmitterV2 e `chainId()` do SpokePool lidos na cadeia;
// - a implementacao de cada proxy, no slot EIP-1967. Implementacao diferente da daqui
//   desliga a ponte ate a proxima versao do app (o dono do proxy trocou o codigo).

/// O que a ponte usa numa rede.
public struct BridgeChain: Sendable, Equatable {
    public let chain: Chain
    /// O CCTP V2 da Circle nesta rede; `nil` onde a Circle nao cunha USDC nativo (BNB).
    public let cctp: CCTP?
    /// O USDC que a ponte move nesta rede: o nativo da Circle onde ha CCTP; na BNB, o da
    /// Binance, que so anda pelo Across.
    public let usdc: EVMAddress
    /// O Across nesta rede; `nil` onde ele nao tem SpokePool (Sonic).
    public let across: Across?
    /// O USDT do emissor, so onde o Across entrega exatamente este contrato.
    public let usdt: EVMAddress?
    /// A moeda nativa da rede e o ETH: o Across move ETH nativo de ponta a ponta.
    public let nativeETH: Bool
    /// O ETH em token onde a moeda nativa nao e ETH e o Across entrega este contrato (na
    /// BNB, o da Binance). `nil` onde o ETH e nativo ou a ponte nao move ETH.
    public let ethToken: EVMAddress?
    /// Casas do USDC e do USDT nesta rede: 6 nos da Circle e da Tether, 18 nos da Binance.
    public let stableDecimals: Int
    /// O USDC desta rede e um proxy fora do CCTP (na BNB, o da Binance): a implementacao
    /// fixada, conferida como as da ponte. Trocada, a ponte para (revisao de 14/10/2026, B1).
    public let usdcImplementation: EVMAddress?
    /// O Across move o USDC desta rede. Na Plasma nao: la ele so leva USDT0, e o USDC
    /// chega pelo CCTP (`available-routes`, 14/10/2026).
    public let acrossUSDC: Bool
    /// O WBTC que o Across entrega nesta rede, so onde e o mesmo contrato da lista curada.
    public let wbtc: EVMAddress?

    /// A Legacy Mesh da Tether nesta rede (o UsdtOFT), so na Ethereum e na Arbitrum.
    public var mesh: USDT0Mesh.Source? { USDT0Mesh.source(chain) }

    public struct CCTP: Sendable, Equatable {
        /// O dominio do CCTP. Nao e o chainId: a Base e 6.
        public let domain: UInt32
        public let messengerImplementation: EVMAddress
        public let transmitterImplementation: EVMAddress
    }

    public struct Across: Sendable, Equatable {
        public let spokePool: EVMAddress
        public let implementation: EVMAddress
        /// O WETH que o SpokePool embrulha quando entra ETH (`wrappedNativeToken()`).
        public let wrappedNative: EVMAddress
    }

    /// Rede com CCTP: USDC e USDT de 6 casas, ETH nativo ou nenhum.
    public init(
        chain: Chain, cctpDomain: UInt32, usdc: EVMAddress, messengerImplementation: EVMAddress, transmitterImplementation: EVMAddress,
        across: Across?, usdt: EVMAddress?, nativeETH: Bool, acrossUSDC: Bool = true, wbtc: EVMAddress? = nil
    ) {
        self.init(chain: chain, cctp: CCTP(domain: cctpDomain, messengerImplementation: messengerImplementation,
                                           transmitterImplementation: transmitterImplementation),
                  usdc: usdc, across: across, usdt: usdt, nativeETH: nativeETH, ethToken: nil, stableDecimals: 6, acrossUSDC: acrossUSDC,
                  wbtc: wbtc)
    }

    public init(
        chain: Chain, cctp: CCTP?, usdc: EVMAddress, across: Across?, usdt: EVMAddress?, nativeETH: Bool, ethToken: EVMAddress?,
        stableDecimals: Int, usdcImplementation: EVMAddress? = nil, acrossUSDC: Bool = true, wbtc: EVMAddress? = nil
    ) {
        self.wbtc = wbtc
        self.usdcImplementation = usdcImplementation
        self.acrossUSDC = acrossUSDC
        self.chain = chain
        self.cctp = cctp
        self.usdc = usdc
        self.across = across
        self.usdt = usdt
        self.nativeETH = nativeETH
        self.ethToken = ethToken
        self.stableDecimals = stableDecimals
    }
}

public enum BridgeAllowlist {
    static func address(_ hex: String) -> EVMAddress {
        EVMAddress(uncheckedBytes: [UInt8](hex: hex)!)
    }

    // CCTP V2: o mesmo endereco nas quatro redes (CREATE2 da Circle), conferido em cada uma.
    public static let tokenMessenger = address("28b5a0e9C621a5BadaA536219b3a228C8168cf5d")
    public static let messageTransmitter = address("81D40F21F12A8F0E3252Bccb954D722d4c464B64")
    public static let tokenMinter = address("fd78EE919681417d192449715b2594ab58f5D002")
    static let messengerImplementation = address("555e272506c06e7e559d57418563742afe363ec8")

    /// O teto por queima que o TokenMinterV2 impoe ao USDC, lido nas quatro redes:
    /// 10.000.000 USDC. Valor maior vira mais de uma queima.
    public static let burnLimitPerMessage = BigUInt(10_000_000_000_000)

    public static let ethereum = BridgeChain(
        chain: .ethereum, cctpDomain: 0,
        usdc: address("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("a30c41865729c248067704d4db9f38385cbe1186"),
        across: .init(spokePool: address("5c7BCd6E7De5423a257D81B442095A1a6ced35C5"), implementation: address("456ac26e5ec083ee9889eba0d1a0a582502b8e84"),
                      wrappedNative: address("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")),
        usdt: address("dAC17F958D2ee523a2206206994597C13D831ec7"), nativeETH: true,
        wbtc: address("2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599")
    )

    public static let arbitrum = BridgeChain(
        chain: .arbitrum, cctpDomain: 3,
        usdc: address("af88d065e77c8cC2239327C5EDb3A432268e5831"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("7b93db2bc72faf642cec0adcac4f91718831a1f4"),
        across: .init(spokePool: address("e35e9842fceaCA96570B734083f4a58e8F7C5f2A"), implementation: address("cfcda84333431bcc9155f2368b8362f0d1dff8c9"),
                      wrappedNative: address("82aF49447D8a07e3bd95BD0d56f35241523fBab1")),
        // USDT0, o USDT da Tether na Arbitrum, e o que o Across entrega aqui.
        usdt: address("Fd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9"), nativeETH: true,
        wbtc: address("2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f")
    )

    public static let base = BridgeChain(
        chain: .base, cctpDomain: 6,
        usdc: address("833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("7db629f6acc20be49a0a7565c21cc178e9ac21e3"),
        across: .init(spokePool: address("09aea4b2242abC8bb4BB78D537A67a245A7bEC64"), implementation: address("f23c6c04a2b88e8651fe99bbdccbb5c9d306e6b0"),
                      wrappedNative: address("4200000000000000000000000000000000000006")),
        // O USDT do Across na Base (0xfde4...) e de ponte, nao do emissor.
        usdt: nil, nativeETH: true
    )

    public static let optimism = BridgeChain(
        chain: .optimism, cctpDomain: 2,
        usdc: address("0b2C639c533813f4Aa9D7837CAf62653d097Ff85"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("1f33335414afb7305367452d00a0d024b0184ea8"),
        across: .init(spokePool: address("6f26Bf09B1C792e3228e5467807a900A503c0281"), implementation: address("60674c53a4cc4ed350659c95fb8020b5ac61ca1d"),
                      wrappedNative: address("4200000000000000000000000000000000000006")),
        // O Across entrega o USDT de ponte (0x94b0...), nao o USDT0 da lista do app.
        usdt: nil, nativeETH: true,
        wbtc: address("68f180fcCe6836688e9084f035309E29Bf0A2095")
    )

    // Segunda leva, 14/10/2026: lida do mesmo jeito (implementacao no slot EIP-1967,
    // `localDomain()` e `chainId()` em dois RPCs; dominio e implementacao do
    // TokenMessengerV2 batem com a leitura independente do agente de seguranca de
    // 11/10). Cada uma tem `eth_simulateV1` em duas fontes. O que fica de fora em cada:
    // - Polygon: so USDC. O ETH que o Across entrega la e WETH de ponte, e o USDT da
    //   lista ainda nao tem a conferencia de emissor registrada.
    // - Linea: USDC e ETH. O USDT da Linea e de ponte (TokenRegistry).
    // - Unichain: USDC, ETH e USDT0.
    // - Sonic: so USDC; o Across nao tem SpokePool la.
    // - Plasma: USDC e USDT0; a moeda nativa e o XPL. O USDC so pelo CCTP: o Across de la
    //   nao leva USDC, e por isso nao ha USDC entre a Plasma e a BNB.
    //
    // WBTC (17/10/2026, pedido do dono de liberar toda moeda que der): pelo Across, entre
    // Ethereum, Arbitrum, OP e Polygon, as redes em que o Across entrega o mesmo contrato da
    // lista curada (`available-routes` ao vivo). Em dois RPCs de cada uma: codigo igual e
    // `decimals()` 8. Na Arbitrum e o token padrao da ponte da Arbitrum (proxy de beacon
    // da propria Arbitrum); na Polygon, o da ponte PoS. A Linea fica de fora: o WBTC que o
    // Across entrega la nao esta na lista.
    public static let polygon = BridgeChain(
        chain: .polygon, cctpDomain: 7,
        usdc: address("3c499c542cEF5E3811e1192ce70d8cC03d5c3359"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("d40518c1a3139e8f1f73f83e5de74e05c88f5ad3"),
        across: .init(spokePool: address("9295ee1d8C5b022Be115A2AD3c30C72E34e7F096"), implementation: address("304bed95daecd3e680073eab385193da711d59d4"),
                      wrappedNative: address("0d500b1d8e8ef31e21c99d1db9a6444d3adf1270")),
        usdt: nil, nativeETH: false,
        wbtc: address("1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6")
    )

    public static let linea = BridgeChain(
        chain: .linea, cctpDomain: 11,
        usdc: address("176211869cA2b568f2A7D4EE941E073a821EE1ff"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("cec4e8c3bd65cf40821cb2c63deb0aabbcd9ef1b"),
        across: .init(spokePool: address("7E63A5f1a8F0B4d0934B2f2327DAED3F6bb2ee75"), implementation: address("263c0e973fd0ca9de57bb22a91c57fc367a81915"),
                      wrappedNative: address("e5d7c2a44ffddf6b295a15c148167daaaf5cf34f")),
        usdt: nil, nativeETH: true
    )

    public static let unichain = BridgeChain(
        chain: .unichain, cctpDomain: 10,
        usdc: address("078D782b760474a361dDA0AF3839290b0EF57AD6"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("ca8b81cc584e1480f7855bf843ce17af511ecd03"),
        across: .init(spokePool: address("09aea4b2242abC8bb4BB78D537A67a245A7bEC64"), implementation: address("e619bd2ed532b87e353142b73ab8e70cb764ff64"),
                      wrappedNative: address("4200000000000000000000000000000000000006")),
        usdt: address("9151434b16b9763660705744891fA906F660EcC5"), nativeETH: true
    )

    public static let sonic = BridgeChain(
        chain: .sonic, cctpDomain: 13,
        usdc: address("29219dd400f2Bf60E5a23d13Be72B486D4038894"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("824ddd600433ce8b17ad5dd6333c883ac10a3ece"),
        across: nil, usdt: nil, nativeETH: false
    )

    public static let plasma = BridgeChain(
        chain: .plasma, cctpDomain: 33,
        usdc: address("2d661C89D812261039AF9764eceaAee884f5F67F"),
        // A Plasma tem outra implementacao do TokenMessengerV2 (lida em dois RPCs, igual a
        // do agente de seguranca).
        messengerImplementation: address("1ccafdffbc1b7b5c499c97322f961b7d929a41b4"),
        transmitterImplementation: address("d683965f427af258f5eec40f950a95a62edc8ca6"),
        across: .init(spokePool: address("50039fAEfebef707cFD94D6d462fE6D10B39207a"), implementation: address("af10c33de0aee6df661b9bfb25e829871ab87a41"),
                      wrappedNative: address("6100e367285b01f48d07953803a2d8dca5d19873")),
        usdt: address("B8CE59FC3717ada4C02eaDF9682A9e934F625ebb"), nativeETH: false, acrossUSDC: false
    )

    /// BNB Chain, so pelo Across. O USDC, o USDT e o ETH daqui sao os da Binance, com 18
    /// casas, e sao os contratos que o Across entrega (`available-routes`, 14/10/2026).
    /// Conferido em 14/10/2026: endereco do SpokePool em across-protocol/contracts
    /// (broadcast/deployed-addresses.json) e na API do Across; na cadeia, em dois RPCs
    /// (bsc-dataseed.bnbchain.org e bsc-rpc.publicnode.com), `chainId()` 56, a
    /// implementacao no slot EIP-1967, `wrappedNativeToken()` (o WBNB) e `decimals()` 18
    /// nos tres tokens.
    public static let bnb = BridgeChain(
        chain: .bnb, cctp: nil,
        usdc: address("8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d"),
        across: .init(spokePool: address("4e8E101924eDE233C13e2D8622DC8aED2872d505"), implementation: address("c7b7029373f504949553106c9eb2dafdd48ef086"),
                      wrappedNative: address("bb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c")),
        usdt: address("55d398326f99059fF775485246999027B3197955"), nativeETH: false,
        ethToken: address("2170Ed0880ac9A755fd29B2688956BD959F933F8"), stableDecimals: 18,
        // O USDC da Binance e proxy EIP-1967 com admin numa chave so; o USDT e o ETH de la nao
        // sao proxy. Implementacao lida em dois RPCs em 14/10/2026.
        usdcImplementation: address("ba5fe23f8a3a24bed3236f05f2fcf35fd0bf0b5c")
    )

    public static let chains: [BridgeChain] = [ethereum, arbitrum, base, optimism, polygon, linea, unichain, sonic, plasma, bnb]

    /// A Tron, so como destino do USDT pela Legacy Mesh da Tether (`USDT0Mesh`). Nao e EVM e
    /// nao entra em `chains` (as redes de origem): sem CCTP nem Across; o `usdc` fica no
    /// endereco zero e nunca e usado (`BridgeAsset.available` so libera o USDT pela Mesh), e o
    /// `usdt` sao os 20 bytes do USDT da Tron, TR7NH...Lj6t.
    public static let tron = BridgeChain(
        chain: .tron, cctp: nil, usdc: .zero, across: nil, usdt: EVMAddress(uncheckedBytes: USDT0Mesh.tronUSDT.account20),
        nativeETH: false, ethToken: nil, stableDecimals: 6, acrossUSDC: false
    )

    /// Os destinos: as redes de origem e a Tron.
    public static let destinations: [BridgeChain] = chains + [tron]

    public static func chain(_ chain: Chain) -> BridgeChain? {
        destinations.first { $0.chain.id == chain.id }
    }

    public static func chain(domain: UInt32) -> BridgeChain? {
        chains.first { $0.cctp?.domain == domain }
    }
}
