@testable import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburEngines
@testable import EscaliburNetwork

/// Moeda custom no envio: o mesmo motor, a mesma conferencia de plano, e o que muda. Na
/// EVM, as casas salvas sao relidas na rede em dois provedores antes de montar, o proprio
/// contrato vira destino bloqueado e a revisao leva o aviso de nao verificado. Tron, TON e
/// XRP Ledger recusam com o motivo, sem ler a rede. As respostas sao as gravadas da
/// Ethereum (Fixtures/evm), com o contrato da moeda custom respondendo como um ERC-20.
@Suite("Moeda custom: envio")
struct EVMCustomTokenTests {
    typealias A = EVMTestAccounts
    typealias F = EVMEthereumFixtures

    /// Um contrato que nao esta na lista (o mesmo "USDC falso" do teste de recusa).
    static let contract = try! EVMAddress("0x58bDC4310db1b19854Ca9066deEd7E3dF4F2Ec9B")
    static let decimalsSelector = "0x313ce567"

    static func custom(decimals: Int = 6) -> Asset {
        CustomToken.asset(chain: .ethereum, kind: .token(contract: contract.checksummed), symbol: "USDC", name: "USD Coin", decimals: decimals)
    }

    /// As respostas da Ethereum, e o contrato custom com codigo, estimativa e 6 casas.
    static func transport() throws -> EVMFixtureTransport {
        let transport = try F.transport()
        let code = try EVMFixtures.data("eth_getCode-usdc")
        let estimate = try EVMFixtures.data("eth_estimateGas-usdc")
        let target = F.lower(contract)
        transport.prepend { call in
            switch call.method {
            case "eth_getCode": return (call.params.first as? String)?.lowercased() == target ? code : nil
            case "eth_estimateGas": return (call.firstObject?["to"] as? String)?.lowercased() == target ? estimate : nil
            case "eth_call":
                guard (call.firstObject?["data"] as? String)?.lowercased() == decimalsSelector else { return nil }
                return EVMFixtures.result("\"0x" + String(repeating: "0", count: 63) + "6\"")
            default: return nil
            }
        }
        return transport
    }

    static func request(_ asset: Asset, amount: BigUInt = 1_000_000, to destination: EVMAddress = A.binance14) -> SendRequest {
        SendRequest(
            walletID: UUID(), chain: .ethereum, asset: asset, account: A.binance8(on: .ethereum), destination: destination.checksummed,
            tag: nil, amount: amount, sendAll: false, feeLevel: .normal, utxoUsage: nil
        )
    }

    @Test("Plano de moeda custom: transfer no contrato salvo, aviso de nao verificado, mesma conferencia do app")
    func plan() async throws {
        let transport = try Self.transport()
        let engine = EVMSendEngine(chain: .ethereum, reader: F.reader(transport))!
        let asset = Self.custom()
        let plan = try await engine.plan(Self.request(asset))
        let transaction = try #require(plan.transactions.first as? EVMTransaction)
        #expect(transaction.to == Self.contract && transaction.value.isZero)
        #expect(Array(transaction.data.prefix(4)) == [0xa9, 0x05, 0x9c, 0xbb])
        #expect(plan.review.warnings.contains(.unverifiedToken(symbol: "USDC")))
        // A conferencia que o app faz antes da revisao e antes do PIN.
        try PlanIntentCheck.send(plan.review, asset: asset, amount: 1_000_000, ceiling: 1_000_000, chain: .ethereum)
        #expect(throws: PlanIntentCheck.Mismatch.wrongAsset) {
            try PlanIntentCheck.send(plan.review, asset: EVMSendEngineTests.usdcAsset, amount: 1_000_000, ceiling: 1_000_000, chain: .ethereum)
        }
        // As casas foram relidas em dois provedores, e o transfer simulado.
        let decimals = transport.calls("eth_call").filter { ($0.firstObject?["data"] as? String)?.lowercased() == Self.decimalsSelector }
        #expect(Set(decimals.map(\.host)).count == 2)
    }

    @Test("Casas salvas diferentes das da rede: recusado antes de montar")
    func decimalsChanged() async throws {
        let engine = EVMSendEngine(chain: .ethereum, reader: F.reader(try Self.transport()))!
        await #expect(throws: SendEngineError.message(
            "As casas decimais deste token na rede não são mais as que foram salvas. Remova a moeda e adicione de novo antes de enviar."
        )) {
            _ = try await engine.plan(Self.request(Self.custom(decimals: 18)))
        }
    }

    @Test("O contrato da propria moeda custom nunca e destino")
    func ownContractBlocked() async throws {
        let engine = EVMSendEngine(chain: .ethereum, reader: F.reader(try Self.transport()))!
        await #expect(throws: SendEngineError.self) {
            _ = try await engine.plan(Self.request(Self.custom(), to: Self.contract))
        }
    }

    @Test("Ler a moeda: codigo no contrato, casas em dois provedores e nome e simbolo")
    func facts() async throws {
        let transport = try Self.transport()
        let symbol = "0x" + "0000000000000000000000000000000000000000000000000000000000000020"
            + "0000000000000000000000000000000000000000000000000000000000000003" + "4142430000000000000000000000000000000000000000000000000000000000"
        transport.prepend { call in
            guard call.method == "eth_call", let data = (call.firstObject?["data"] as? String)?.lowercased() else { return nil }
            if data == "0x95d89b41" || data == "0x06fdde03" { return EVMFixtures.result("\"\(symbol)\"") }
            return nil
        }
        let read = try await F.reader(transport).tokenFacts(chain: .ethereum, contract: Self.contract)
        #expect(read.decimals == 6 && read.symbol == "ABC" && read.name == "ABC" && read.sources.count == 2)
        // Conta comum, sem codigo: nao e token.
        await #expect(throws: ReaderError.self) { _ = try await F.reader(transport).tokenFacts(chain: .ethereum, contract: A.binance14) }
    }

    @Test("Moeda nao custom fora da lista continua recusada; a lista nunca vira custom")
    func onlyCustom() throws {
        let fake = Asset(chainID: "ethereum", kind: .token(contract: Self.contract.checksummed), symbol: "USDC", name: "USD Coin", decimals: 6,
                         coingeckoID: nil, isStablecoin: true, origin: .discovered)
        #expect(throws: EVMEngineFailure.assetNotListed) { _ = try EVMEngineSupport.resolve(fake, on: .ethereum, allowCustom: true) }
        // A troca nao aceita moeda custom.
        #expect(throws: EVMEngineFailure.assetNotListed) { _ = try EVMEngineSupport.resolve(Self.custom(), on: .ethereum) }
        // Contrato da lista marcado como custom: vale a lista, com simbolo e casas dela.
        let listed = Asset(chainID: "ethereum", kind: .token(contract: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"), symbol: "FAKE", name: "x",
                           decimals: 6, coingeckoID: nil, isStablecoin: false, origin: .custom)
        guard case .token(let token) = try EVMEngineSupport.resolve(listed, on: .ethereum, allowCustom: true) else { Issue.record("nativo"); return }
        #expect(token.symbol == "USDC")
    }

    @Test("Tron, TON e XRP Ledger: moeda custom recusada com o motivo, sem ler a rede")
    func otherFamilies() async throws {
        let tron = Asset(chainID: "tron", kind: .token(contract: "TQGaH1PigTUJsSbCootv52Hi92Gx2Hbmw8"), symbol: "KYC", name: "KYC", decimals: 6,
                         coingeckoID: nil, isStablecoin: false, origin: .custom)
        #expect(throws: SendEngineError.unavailable(CustomToken.sendUnavailableReason(.tron)!)) { _ = try TronSendEngine.coin(tron) }
        let ton = Asset(chainID: "ton", kind: .token(contract: "EQAvlWFDxGF2lXm67y4yzC17wYKD9A0guwPkMs1gOsM__NOT"), symbol: "NOT", name: "Notcoin",
                        decimals: 9, coingeckoID: nil, isStablecoin: false, origin: .custom)
        #expect(throws: SendEngineError.unavailable(CustomToken.sendUnavailableReason(.ton)!)) { _ = try TONSendEngine.coin(ton) }
        let solo = Asset(chainID: "xrpl", kind: .issued(code: "534F4C4F00000000000000000000000000000000", issuer: "rsoLo2S1kiGeCcn6hCUXVrCpGMWLrRrLZz"),
                         symbol: "SOLO", name: "SOLO", decimals: 6, coingeckoID: nil, isStablecoin: false, origin: .custom)
        let request = SendRequest(
            walletID: UUID(), chain: .xrpl, asset: solo,
            account: DerivedAccount(chainID: "xrpl", path: DefaultPaths.path(for: .xrpl), address: "rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3", publicKey: [], accountXPub: nil),
            destination: "rsoLo2S1kiGeCcn6hCUXVrCpGMWLrRrLZz", tag: nil, amount: 1, sendAll: false, feeLevel: .normal, utxoUsage: nil
        )
        await #expect(throws: SendEngineError.unavailable(CustomToken.sendUnavailableReason(.xrpl)!)) {
            _ = try await XRPLSendEngine().plan(request)
        }
    }
}
