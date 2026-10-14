import EscaliburCore
import Foundation

// A allowlist da ponte, compilada e rede por rede (docs/seguranca.md 4.12).
//
// Primeira leva: Ethereum, Arbitrum, Base e Optimism (CCTP V2 rapido, SpokePool do
// Across, ETH nativo e simulacao em dois RPCs). Segunda leva abaixo. O resto fica de
// fora ate fechar tudo:
// - BNB: o TokenMessengerV2 da Ethereum aceita o dominio 17, mas na BNB o USDC nao e
//   cunhado (`getLocalToken` zero para todas as origens, `burnLimitsPerMessage` zero).
//   Uma queima para la se perderia; o app confere `getLocalToken` no destino antes de
//   assinar qualquer queima, mesmo nas redes desta lista.
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
    /// O dominio do CCTP. Nao e o chainId: a Base e 6.
    public let cctpDomain: UInt32
    /// O USDC nativo da Circle nesta rede.
    public let usdc: EVMAddress
    public let messengerImplementation: EVMAddress
    public let transmitterImplementation: EVMAddress
    /// O Across nesta rede; `nil` onde ele nao tem SpokePool (Sonic).
    public let across: Across?
    /// O USDT do emissor, so onde o Across entrega exatamente este contrato.
    public let usdt: EVMAddress?
    /// A moeda nativa da rede e o ETH: o Across move ETH nativo de ponta a ponta.
    public let nativeETH: Bool

    public struct Across: Sendable, Equatable {
        public let spokePool: EVMAddress
        public let implementation: EVMAddress
        /// O WETH que o SpokePool embrulha quando entra ETH (`wrappedNativeToken()`).
        public let wrappedNative: EVMAddress
    }

    public init(
        chain: Chain, cctpDomain: UInt32, usdc: EVMAddress, messengerImplementation: EVMAddress, transmitterImplementation: EVMAddress,
        across: Across?, usdt: EVMAddress?, nativeETH: Bool
    ) {
        self.chain = chain
        self.cctpDomain = cctpDomain
        self.usdc = usdc
        self.messengerImplementation = messengerImplementation
        self.transmitterImplementation = transmitterImplementation
        self.across = across
        self.usdt = usdt
        self.nativeETH = nativeETH
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
        usdt: address("dAC17F958D2ee523a2206206994597C13D831ec7"), nativeETH: true
    )

    public static let arbitrum = BridgeChain(
        chain: .arbitrum, cctpDomain: 3,
        usdc: address("af88d065e77c8cC2239327C5EDb3A432268e5831"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("7b93db2bc72faf642cec0adcac4f91718831a1f4"),
        across: .init(spokePool: address("e35e9842fceaCA96570B734083f4a58e8F7C5f2A"), implementation: address("cfcda84333431bcc9155f2368b8362f0d1dff8c9"),
                      wrappedNative: address("82aF49447D8a07e3bd95BD0d56f35241523fBab1")),
        // USDT0, o USDT da Tether na Arbitrum, e o que o Across entrega aqui.
        usdt: address("Fd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9"), nativeETH: true
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
        usdt: nil, nativeETH: true
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
    // - Plasma: USDC e USDT0; a moeda nativa e o XPL.
    public static let polygon = BridgeChain(
        chain: .polygon, cctpDomain: 7,
        usdc: address("3c499c542cEF5E3811e1192ce70d8cC03d5c3359"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("d40518c1a3139e8f1f73f83e5de74e05c88f5ad3"),
        across: .init(spokePool: address("9295ee1d8C5b022Be115A2AD3c30C72E34e7F096"), implementation: address("304bed95daecd3e680073eab385193da711d59d4"),
                      wrappedNative: address("0d500b1d8e8ef31e21c99d1db9a6444d3adf1270")),
        usdt: nil, nativeETH: false
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
        usdt: address("B8CE59FC3717ada4C02eaDF9682A9e934F625ebb"), nativeETH: false
    )

    public static let chains: [BridgeChain] = [ethereum, arbitrum, base, optimism, polygon, linea, unichain, sonic, plasma]

    public static func chain(_ chain: Chain) -> BridgeChain? {
        chains.first { $0.chain.id == chain.id }
    }

    public static func chain(domain: UInt32) -> BridgeChain? {
        chains.first { $0.cctpDomain == domain }
    }
}
