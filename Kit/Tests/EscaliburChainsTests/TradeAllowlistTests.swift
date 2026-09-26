import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// A allowlist compilada: enderecos com checksum EIP-55 igual ao das fontes, seletores
/// iguais aos do ABI verificado (calculados do keccak e conferidos contra os valores
/// vistos na calldata real e publicados no 4byte.directory).
@Suite("Troca: allowlist de routers")
struct TradeAllowlistTests {
    typealias T = EVMTestSupport

    @Test("Enderecos, com checksum das fontes (docs dos provedores, Sourcify, deployments da LI.FI)")
    func addresses() {
        #expect(TradeAllowlist.velora.checksummed == "0x6A000F20005980200259B80c5102003040001068")
        #expect(TradeAllowlist.kyber.checksummed == "0x6131B5fae19EA4f9D964eAc0408E4408b66337b5")
        #expect(TradeAllowlist.lifiDiamond.checksummed == "0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE")
        #expect(TradeAllowlist.lifiFeeForwarder.checksummed == "0xCE40449B773a3E6E5e769ADb4e567179d4828cbd")
        #expect(TradeAllowlist.de1Proxy.checksummed == "0x6352a56caadC4F1E25CD6c75970Fa768A3304e64")
        #expect(TradeAllowlist.lifiFacets[1]?.checksummed == "0x8C9dBA771220Ed09580b77F0765e7153fbDE7790")
        #expect(TradeAllowlist.lifiFacets[10]?.checksummed == "0x8dFDaeBB42655a4A4e2b89687dd117074AE8c665")
        #expect(TradeAllowlist.lifiFacets[8453]?.checksummed == "0x31a9b1835864706Af10103b31Ea2b79bdb995F5F")
        // Segunda leva: faceta da Sonic (deployments/sonic.json) e implementacoes da De¹
        // lidas no slot EIP-1967.
        #expect(TradeAllowlist.lifiFacets[146]?.checksummed == "0xf24c9914D3a89F16aD9C87fa549FF24359a31715")
        #expect(TradeAllowlist.de1Implementations[59144]?.checksummed == "0x1aA298Ae7c53D8DAFA200ED49608649BFA76a446")
        #expect(TradeAllowlist.de1Implementations[130]?.checksummed == "0x170100a288dc3d7e83fea20441F98166B15b6dF0")
        #expect(TradeAllowlist.de1Implementations[146] == nil)
    }

    @Test("Seletores aceitos por router")
    func selectors() {
        func hex(_ function: ABIFunction) -> String { Hex.encode(function.selector) }
        #expect(hex(VeloraCalldata.swapExactAmountIn) == "e3ead59e")
        #expect(hex(KyberCalldata.swap) == "e21fd0e9")
        #expect(LiFiCalldata.functions.map(hex) == ["4666fc80", "733214a3", "af7060fd", "5fd9ae2e", "2c57e884", "736eac0b"])
        #expect(hex(LiFiCalldata.forwardERC20Fees) == "332d746b")
        #expect(hex(LiFiCalldata.forwardNativeFees) == "0e8ae67f")
        #expect(hex(De1Calldata.swap) == "90411a32")
        #expect(hex(De1Calldata.simpleSwap) == "0a9704d5")
        #expect(hex(TradeRouterPin.facetAddressFunction) == "cdffacc6")
        // O swapTokensGeneric antigo nao e aceito.
        let generic = try! ABIFunction("swapTokensGeneric(bytes32,string,string,address,uint256,(address,address,address,address,uint256,bytes,bool)[])")
        #expect(Hex.encode(generic.selector) == "4630a0d8")
        #expect(!TradeAllowlist.router(for: .lifi, on: .base)!.selectors.contains(generic.selector))
    }

    /// Quem atende cada rede, conferido ao vivo em 25/09/2026 (as 7 da v1) e 26/09/2026
    /// (a segunda leva). X Layer e Celo nao tem troca.
    static let coverageTable: [String: Set<TradeProvider>] = [
        "ethereum": [.velora, .kyberSwap, .lifi, .de1], "arbitrum": [.velora, .kyberSwap, .lifi, .de1],
        "base": [.velora, .kyberSwap, .lifi, .de1], "optimism": [.velora, .kyberSwap, .lifi, .de1],
        "polygon": [.velora, .kyberSwap, .lifi, .de1], "bnb": [.velora, .kyberSwap, .lifi, .de1],
        "avalanche": [.velora, .kyberSwap, .lifi],
        "plasma": [.kyberSwap], "linea": [.kyberSwap, .de1], "unichain": [.velora, .kyberSwap, .de1],
        "sonic": [.kyberSwap, .lifi], "xlayer": [], "celo": [],
    ]

    @Test("Cobertura: cada provedor so nas redes em que o router foi conferido; nada fora da EVM")
    func coverage() {
        #expect(Set(Self.coverageTable.keys) == Set(Chain.evmChains.map(\.id)))
        for chain in Chain.evmChains {
            let expected = Self.coverageTable[chain.id] ?? []
            for provider in TradeProvider.allCases {
                #expect((TradeAllowlist.router(for: provider, on: chain) != nil) == expected.contains(provider), "\(chain.id) \(provider)")
            }
        }
        #expect(TradeAllowlist.routers(on: .solana).isEmpty)
        // Spender = router nos quatro; a lista de revogacao inclui o VaultRelayer da CoW.
        for router in TradeAllowlist.routers(on: .base) { #expect(router.spender == router.address) }
        #expect(TradeAllowlist.spenders(on: .base).contains(CoWProtocol.vaultRelayer))
        #expect(!TradeAllowlist.spenders(on: .optimism).contains(CoWProtocol.vaultRelayer))
        // Pins: imutavel, faceta, implementacao.
        #expect(TradeAllowlist.router(for: .velora, on: .base)?.pin == .immutable)
        #expect(TradeAllowlist.router(for: .de1, on: .base)?.pin == .eip1967(implementation: T.address("0x201263cea08e8f1d6e2fdd1fd2ca44bf6145e2af")))
        #expect(TradeAllowlist.router(for: .lifi, on: .ethereum)?.facetQueries.count == 6)
        #expect(TradeAllowlist.router(for: .lifi, on: .sonic)?.pin == .diamondFacet(T.address("0xf24c9914D3a89F16aD9C87fa549FF24359a31715")))
        #expect(TradeAllowlist.router(for: .kyberSwap, on: .plasma)?.address == TradeAllowlist.kyber)
        #expect(TradeAllowlist.router(for: .velora, on: .unichain)?.pin == .immutable)
        // CoW na Plasma e na Linea: o VaultRelayer entra na lista de revogacao.
        #expect(TradeAllowlist.spenders(on: .plasma) == [TradeAllowlist.kyber, CoWProtocol.vaultRelayer])
        #expect(TradeAllowlist.spenders(on: .linea).contains(CoWProtocol.vaultRelayer))
        #expect(TradeAllowlist.spenders(on: .xlayer).isEmpty)
    }

    @Test("Taxa da Escalibur: zero em todos os provedores e redes")
    func feeIsZero() {
        for chain in Chain.evmChains {
            for provider in TradeProvider.allCases {
                #expect(TradeFeeSchedule.escaliburFee(provider: provider, chain: chain) == .none)
            }
        }
        #expect(TradeFeeSchedule.providerFeeCeilingBps(.lifi) == 25)
        #expect(TradeFeeSchedule.providerFeeCeilingBps(.velora) == 0)
    }

    @Test("Texto: percentual, preco aproximado e numero decimal digitado")
    func text() {
        #expect(TradeText.percent(bps: 50) == "0,5%")
        #expect(TradeText.percent(bps: 1_500) == "15%")
        #expect(TradeText.percent(bps: 1) == "0,01%")
        #expect(TradeText.approximate(BigUInt(decimal: "2692431234")!, decimals: 6).text == "2.692,43")
        #expect(TradeText.approximate(BigUInt(371_234), decimals: 9).text == "0,0003712")
        #expect(TradeDecimal("3.000") == TradeDecimal(mantissa: 3_000, scale: 3))
        #expect(TradeDecimal(",5") == TradeDecimal(mantissa: 5, scale: 1))
        #expect(TradeDecimal("1,2,3") == nil)
        #expect(TradeDecimal("") == nil)
    }
}
