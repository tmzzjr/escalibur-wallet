import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Tokens da lista que o emissor pode trocar por cima (proxy): a implementacao de hoje,
/// lida em dois RPCs, tem de ser a fixada aqui. Se houver upgrade, o teste falha e o
/// token volta a revisao (revisao de seguranca de 15/10/2026, B2). Lidas em 15/10/2026.
/// So com ESCALIBUR_REDE=1.
@Suite("Proxies dos tokens da lista ao vivo", .enabled(if: Live.enabled))
struct TokenProxyPinLiveTests {
    /// `keccak256("eip1967.proxy.implementation") - 1`, `keccak256("eip1967.proxy.beacon") - 1`,
    /// o slot do proxy da Polygon (`keccak256("matic.network.proxy.implementation")`) e o
    /// do FiatTokenProxy da Coinbase (`keccak256("org.zeppelinos.proxy.implementation")`).
    static let implementation = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
    static let beacon = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50"
    static let polygon = "0xbaab7dbf64751104133af04abc7d9979f0fda3b059a322a8333f533d3f32bf7f"
    static let zeppelin = "0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3"

    enum Read { case slot(String), implementationCall }
    struct Pin { let label: String; let chain: String; let target: String; let read: Read; let expected: String }

    static let pins: [Pin] = [
        Pin(label: "DOGE da Binance", chain: "bnb", target: "0xbA2aE424d960c26247Dd6c32edC70B295c744C43", read: .slot(implementation),
            expected: "0xba5fe23f8a3a24bed3236f05f2fcf35fd0bf0b5c"),
        Pin(label: "AVAX da Binance", chain: "bnb", target: "0x1CE0c2827e2eF14D5C4f29a091d735A204794041", read: .slot(implementation),
            expected: "0xba5fe23f8a3a24bed3236f05f2fcf35fd0bf0b5c"),
        Pin(label: "SOL da Binance", chain: "bnb", target: "0x570A5D26f7765Ecb712C0924E4De545B89fD43dF", read: .slot(implementation),
            expected: "0xba5fe23f8a3a24bed3236f05f2fcf35fd0bf0b5c"),
        Pin(label: "NEAR da Binance", chain: "bnb", target: "0x1Fa4a73a3F0133f0025378af00236f3aBDEE5D63", read: .slot(implementation),
            expected: "0xba5fe23f8a3a24bed3236f05f2fcf35fd0bf0b5c"),
        Pin(label: "WBTC da Arbitrum (beacon)", chain: "arbitrum", target: "0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f", read: .slot(beacon),
            expected: "0xe72ba9418b5f2ce0a6a40501fe77c6839aa37333"),
        Pin(label: "WBTC da Arbitrum (implementacao do beacon)", chain: "arbitrum", target: "0xe72ba9418b5f2ce0a6a40501fe77c6839aa37333",
            read: .implementationCall, expected: "0x3f770ac673856f105b586bb393d122721265ad46"),
        Pin(label: "WBTC da Polygon", chain: "polygon", target: "0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6", read: .slot(polygon),
            expected: "0x7ffb3d637014488b63fb9858e279385685afc1e2"),
        Pin(label: "cbBTC da Arbitrum", chain: "arbitrum", target: "0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf", read: .slot(zeppelin),
            expected: "0x7458bfdc30034eb860b265e6068121d18fa5aa72"),
    ]

    @Test("A implementacao de cada proxy e a fixada, em dois RPCs")
    func implementationsArePinned() async throws {
        for pin in Self.pins {
            var answered = 0
            for provider in Endpoints.evm[pin.chain] ?? [] where answered < 2 {
                let result: StrictJSON
                do {
                    switch pin.read {
                    case .slot(let slot):
                        result = try await EVMReader.call(HTTPClient.shared, provider.baseURL, "eth_getStorageAt",
                                                          [.string(pin.target), .string(slot), .string("latest")])
                    case .implementationCall:
                        result = try await EVMReader.call(HTTPClient.shared, provider.baseURL, "eth_call",
                                                          [.object(["to": .string(pin.target), "data": .string("0x5c60da1b")]), .string("latest")])
                    }
                } catch {
                    continue
                }
                let word = try result.string("resultado")
                let address = "0x" + word.suffix(40).lowercased()
                #expect(address == pin.expected, "\(pin.label) em \(provider.name): \(address), esperado \(pin.expected)")
                answered += 1
            }
            #expect(answered == 2, "\(pin.label): so \(answered) RPC(s) responderam")
        }
    }
}
