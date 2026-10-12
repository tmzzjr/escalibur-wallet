import EscaliburCore
import Foundation

// A allowlist da ponte, compilada e rede por rede (docs/seguranca.md 4.12).
//
// V1: Ethereum, Arbitrum, Base e Optimism. As quatro tem CCTP V2 rapido, SpokePool do
// Across, ETH nativo e simulacao em dois RPCs. O resto fica de fora ate fechar tudo:
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
    public let spokePool: EVMAddress
    public let spokePoolImplementation: EVMAddress
    /// O WETH que o SpokePool embrulha quando entra ETH (`wrappedNativeToken()`).
    public let wrappedNative: EVMAddress
    /// O USDT do emissor, so onde o Across entrega exatamente este contrato.
    public let usdt: EVMAddress?
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
        spokePool: address("5c7BCd6E7De5423a257D81B442095A1a6ced35C5"),
        spokePoolImplementation: address("456ac26e5ec083ee9889eba0d1a0a582502b8e84"),
        wrappedNative: address("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
        usdt: address("dAC17F958D2ee523a2206206994597C13D831ec7")
    )

    public static let arbitrum = BridgeChain(
        chain: .arbitrum, cctpDomain: 3,
        usdc: address("af88d065e77c8cC2239327C5EDb3A432268e5831"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("7b93db2bc72faf642cec0adcac4f91718831a1f4"),
        spokePool: address("e35e9842fceaCA96570B734083f4a58e8F7C5f2A"),
        spokePoolImplementation: address("cfcda84333431bcc9155f2368b8362f0d1dff8c9"),
        wrappedNative: address("82aF49447D8a07e3bd95BD0d56f35241523fBab1"),
        // USDT0, o USDT da Tether na Arbitrum, e o que o Across entrega aqui.
        usdt: address("Fd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9")
    )

    public static let base = BridgeChain(
        chain: .base, cctpDomain: 6,
        usdc: address("833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("7db629f6acc20be49a0a7565c21cc178e9ac21e3"),
        spokePool: address("09aea4b2242abC8bb4BB78D537A67a245A7bEC64"),
        spokePoolImplementation: address("f23c6c04a2b88e8651fe99bbdccbb5c9d306e6b0"),
        wrappedNative: address("4200000000000000000000000000000000000006"),
        // O USDT do Across na Base (0xfde4...) e de ponte, nao do emissor.
        usdt: nil
    )

    public static let optimism = BridgeChain(
        chain: .optimism, cctpDomain: 2,
        usdc: address("0b2C639c533813f4Aa9D7837CAf62653d097Ff85"),
        messengerImplementation: messengerImplementation,
        transmitterImplementation: address("1f33335414afb7305367452d00a0d024b0184ea8"),
        spokePool: address("6f26Bf09B1C792e3228e5467807a900A503c0281"),
        spokePoolImplementation: address("60674c53a4cc4ed350659c95fb8020b5ac61ca1d"),
        wrappedNative: address("4200000000000000000000000000000000000006"),
        // O Across entrega o USDT de ponte (0x94b0...), nao o USDT0 da lista do app.
        usdt: nil
    )

    public static let chains: [BridgeChain] = [ethereum, arbitrum, base, optimism]

    public static func chain(_ chain: Chain) -> BridgeChain? {
        chains.first { $0.chain.id == chain.id }
    }

    public static func chain(domain: UInt32) -> BridgeChain? {
        chains.first { $0.cctpDomain == domain }
    }
}
