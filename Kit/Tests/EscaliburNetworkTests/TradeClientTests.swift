import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Os clientes de cotacao lendo as respostas reais gravadas (as mesmas fixtures dos
/// testes de EscaliburChains, lidas pelo caminho do fonte), e o meta-agregador com
/// provedores de mentira para os prazos e o circuit breaker.
enum TradeNetworkSupport {
    static let owner = try! EVMAddress("0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F")
    static let baseUSDC = EVMToken(chain: .base, contract: try! EVMAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"), symbol: "USDC", decimals: 6)
    static let arbUSDC = EVMToken(chain: .arbitrum, contract: try! EVMAddress("0xaf88d065e77c8cC2239327C5EDb3A432268e5831"), symbol: "USDC", decimals: 6)
    static let recordedAt = Date(timeIntervalSince1970: 1_790_391_000)

    static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("EscaliburChainsTests/Fixtures/trade/\(name).json")
        return try Data(contentsOf: url)
    }

    static func baseIntent() throws -> TradeIntent {
        try TradeIntent(owner: owner, sell: .token(baseUSDC), buy: .native(.base), amountIn: 100_000_000, slippageBps: 50)
    }

    static func arbIntent() throws -> TradeIntent {
        try TradeIntent(owner: owner, sell: .native(.arbitrum), buy: .token(arbUSDC), amountIn: BigUInt(decimal: "40000000000000000")!, slippageBps: 50)
    }
}

@Suite("Troca: clientes dos provedores")
struct TradeClientTests {
    typealias S = TradeNetworkSupport

    @Test("Cada cliente le a resposta gravada e a proposta passa na validacao")
    func parseFixtures() throws {
        let base = try S.baseIntent()
        let arb = try S.arbIntent()
        let cases: [(TradeProposal, TradeIntent)] = [
            (try VeloraClient.parse(S.fixture("velora-base-usdc-eth")), base),
            (try VeloraClient.parse(S.fixture("velora-arbitrum-eth-usdc")), arb),
            (try KyberSwapClient.parse(routes: S.fixture("kyber-base-usdc-eth-routes"), build: S.fixture("kyber-base-usdc-eth-build")), base),
            (try KyberSwapClient.parse(routes: S.fixture("kyber-arbitrum-eth-usdc-routes"), build: S.fixture("kyber-arbitrum-eth-usdc-build")), arb),
            (try LiFiClient.parse(S.fixture("lifi-base-usdc-eth")), base),
            (try LiFiClient.parse(S.fixture("lifi-arbitrum-eth-usdc")), arb),
            (try De1Client.parse(S.fixture("de1-base-usdc-eth")), base),
            (try De1Client.parse(S.fixture("de1-arbitrum-eth-usdc")), arb),
        ]
        for (proposal, intent) in cases {
            let quote = try TradeValidator.validate(proposal, intent: intent, now: S.recordedAt)
            #expect(quote.decoded.recipient == S.owner)
            #expect(quote.guaranteedOut > 0)
        }
        // Velora e Kyber dizem a rota (pools); LI.FI e De¹ nao.
        #expect(cases[0].0.routeSources?.isEmpty == false)
        #expect(cases[2].0.routeSources?.contains { $0.hasPrefix("0x") } == true)
        #expect(cases[4].0.routeSources == nil)
        #expect(cases[6].0.routeSources == nil)
        // Impacto pelos valores em dolar informados.
        #expect(cases[0].0.reportedPriceImpactBps != nil)
        #expect(cases[4].0.spender == TradeAllowlist.router(for: .lifi, on: .base)?.spender)
    }

    @Test("Kyber: o routeSummary volta no build byte a byte")
    func kyberRawSummary() throws {
        let routes = try S.fixture("kyber-base-usdc-eth-routes")
        let body = try KyberSwapClient.buildBody(routes: routes, intent: S.baseIntent())
        let summary = try RawJSON.value(routes, path: ["data", "routeSummary"])
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.hasPrefix(#"{"routeSummary":{"#))
        #expect(body.range(of: summary) != nil)
        #expect(text.hasSuffix(#","sender":"0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f","recipient":"0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f","slippageTolerance":50,"source":"escalibur"}"#))
        // O corpo e JSON valido e o routeSummary relido e o mesmo objeto.
        let parsed = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let original = try JSONSerialization.jsonObject(with: routes) as! [String: Any]
        #expect(NSDictionary(dictionary: parsed["routeSummary"] as! [String: Any]) == NSDictionary(dictionary: (original["data"] as! [String: Any])["routeSummary"] as! [String: Any]))
    }

    @Test("Recorte de JSON cru: chaves aninhadas, strings com chaves e aspas escapadas")
    func rawJSON() throws {
        let data = Data(#"{"a":1,"b":{"x":"}{\"","y":[1,{"z":2}],"k":{"q":true}},"c":null}"#.utf8)
        #expect(String(decoding: try RawJSON.value(data, path: ["b", "y"]), as: UTF8.self) == #"[1,{"z":2}]"#)
        #expect(String(decoding: try RawJSON.value(data, path: ["b", "x"]), as: UTF8.self) == #""}{\"""#)
        #expect(String(decoding: try RawJSON.value(data, path: ["b", "k"]), as: UTF8.self) == #"{"q":true}"#)
        #expect(String(decoding: try RawJSON.value(data, path: ["c"]), as: UTF8.self) == "null")
        #expect(throws: RawJSON.Failure.self) { try RawJSON.value(data, path: ["nada"]) }
    }

    @Test("Formatos: tolerancia da LI.FI e da De¹, impacto em dolar e em percentual")
    func wireFormats() {
        #expect(LiFiClient.fraction(TradeDecimal(mantissa: 50, scale: 4)) == "0.0050")
        #expect(LiFiClient.fraction(TradeDecimal(mantissa: 40, scale: 2)) == "0.40")
        #expect(LiFiClient.fraction(TradeDecimal(mantissa: 150, scale: 2)) == "1.50")
        #expect(TradeWire.impactBps(inUSD: "100.03", outUSD: "99.73") == 29)
        #expect(TradeWire.impactBps(inUSD: "99.99", outUSD: "100.02") == 0)
        #expect(TradeWire.percentText("0.02%") == 2)
        #expect(TradeWire.percentText("-0.01%") == 0)
        #expect(TradeWire.percentText("12.5%") == 1_250)
    }

    @Test("Resposta com quantia como numero JSON e recusada (sem Double no caminho do dinheiro)")
    func numbersRefused() {
        let bad = Data(#"{"code":200,"data":{"to":"0x6352a56caadC4F1E25CD6c75970Fa768A3304e64","data":"0x90411a32","value":0,"outAmount":"1"}}"#.utf8)
        #expect(throws: TradeProviderError.badResponse(.de1, "json")) { try De1Client.parse(bad) }
        let noRoute = Data(#"{"code":500,"error":"no route"}"#.utf8)
        #expect(throws: TradeProviderError.noRoute(.de1)) { try De1Client.parse(noRoute) }
    }
}

// MARK: Meta-agregador

/// Provedor de mentira: devolve uma proposta gravada depois de um atraso, ou falha.
@Suite("Troca: estado da ordem limite")
struct TradeStateCoWTests {
    @Test("Auditoria 2, B4: a allowance ao VaultRelayer tem de ser a mesma nas duas fontes")
    func agreedAllowance() throws {
        #expect(try TradeStateReader.agreedAllowance([100, 100]) == 100)
        #expect(try TradeStateReader.agreedAllowance([0, 0]) == 0)
        // Uma fonte dizendo "exata" e a outra mostrando sobra: nada e montado.
        #expect(throws: TradeStateError.sourcesDisagree("allowance")) { try TradeStateReader.agreedAllowance([100, 500]) }
        #expect(throws: TradeStateError.sourcesDisagree("allowance")) { try TradeStateReader.agreedAllowance([100]) }
        #expect(throws: TradeStateError.sourcesDisagree("allowance")) { try TradeStateReader.agreedAllowance([]) }
    }
}

struct StubSource: TradeQuoteSource {
    let provider: TradeProvider
    let delay: Duration
    let proposal: TradeProposal?

    func propose(_ request: TradeQuoteRequest) async throws -> TradeProposal {
        try await Task.sleep(for: delay)
        guard let proposal else { throw TradeProviderError.http(provider, .status(500)) }
        return proposal
    }
}

@Suite("Troca: meta-agregador")
struct TradeAggregatorTests {
    typealias S = TradeNetworkSupport

    static func proposals() throws -> [TradeProvider: TradeProposal] {
        [
            .velora: try VeloraClient.parse(S.fixture("velora-base-usdc-eth")),
            .kyberSwap: try KyberSwapClient.parse(routes: S.fixture("kyber-base-usdc-eth-routes"), build: S.fixture("kyber-base-usdc-eth-build")),
            .lifi: try LiFiClient.parse(S.fixture("lifi-base-usdc-eth")),
            .de1: try De1Client.parse(S.fixture("de1-base-usdc-eth")),
        ]
    }

    @Test("Todos respondem: ranking pelo garantido, na ordem")
    func allAnswer() async throws {
        let p = try Self.proposals()
        let aggregator = TradeAggregator(sources: TradeProvider.allCases.map { StubSource(provider: $0, delay: .milliseconds(10), proposal: p[$0]) })
        let set = await aggregator.quote(try S.baseIntent(), costs: .free)
        #expect(set.ranked.count == 4)
        #expect(set.failures.isEmpty && set.pending.isEmpty)
        let guaranteed = set.ranked.map(\.quote.guaranteedOut)
        #expect(guaranteed == guaranteed.sorted(by: >))
    }

    @Test("Prazo mole: a primeira parcial sai em ~prazo mole com o que chegou; a final espera o lento")
    func softDeadline() async throws {
        let p = try Self.proposals()
        let aggregator = TradeAggregator(sources: [
            StubSource(provider: .velora, delay: .milliseconds(20), proposal: p[.velora]),
            StubSource(provider: .kyberSwap, delay: .milliseconds(900), proposal: p[.kyberSwap]),
        ])
        let start = ContinuousClock.now
        var snapshots = [(Duration, TradeQuoteSet)]()
        for await set in aggregator.updates(try S.baseIntent(), costs: .free) {
            snapshots.append((ContinuousClock.now - start, set))
        }
        // Prazo mole de 1,5 s: a Kyber (0,9 s) chega antes, entao so ha a final, com as duas.
        #expect(snapshots.last?.1.isFinal == true)
        #expect(snapshots.last?.1.ranked.count == 2)

        let slow = TradeAggregator(sources: [
            StubSource(provider: .velora, delay: .milliseconds(20), proposal: p[.velora]),
            StubSource(provider: .kyberSwap, delay: .milliseconds(2_500), proposal: p[.kyberSwap]),
        ])
        let begin = ContinuousClock.now
        var parts = [(Duration, TradeQuoteSet)]()
        for await set in slow.updates(try S.baseIntent(), costs: .free) {
            parts.append((ContinuousClock.now - begin, set))
        }
        #expect(parts.count == 2)
        #expect(parts.first?.1.isFinal == false)
        #expect(parts.first?.1.ranked.map(\.quote.provider) == [.velora])
        #expect(parts.first?.1.pending == [.kyberSwap])
        #expect((parts.first?.0 ?? .zero) < .milliseconds(2_200))
        #expect(parts.last?.1.isFinal == true)
        #expect(parts.last?.1.ranked.count == 2)
    }

    @Test("Cada provedor de troca tem endereco em Endpoints.trade")
    func everyProviderHasEndpoint() {
        for provider in TradeProvider.allCases {
            #expect(Endpoints.trade[provider.rawValue] != nil, "\(provider)")
        }
    }

    @Test("Prazo duro: quem nao respondeu ate o duro fica de fora, marcado como prazo")
    func hardDeadline() async throws {
        let p = try Self.proposals()
        let aggregator = TradeAggregator(sources: [
            StubSource(provider: .velora, delay: .milliseconds(10), proposal: p[.velora]),
            StubSource(provider: .kyberSwap, delay: .seconds(5), proposal: p[.kyberSwap]),
        ])
        // Sem limite de relogio aqui: com a suite inteira rodando, os testes de Argon2
        // ocupam o pool cooperativo e atrasam qualquer temporizador. O corte e provado
        // pelo resultado: a proposta lenta existe e ficou de fora, marcada como prazo.
        let set = await aggregator.quote(try S.baseIntent(), costs: .free, softDeadline: .milliseconds(100), hardDeadline: .milliseconds(600))
        #expect(set.ranked.map(\.quote.provider) == [.velora])
        #expect(set.pending == [.kyberSwap])
        #expect(set.failures[.kyberSwap] == .timedOut(.kyberSwap))
        #expect(set.isFinal)

        let none = TradeAggregator(sources: [StubSource(provider: .velora, delay: .seconds(5), proposal: nil)])
        let empty = await none.quote(try S.baseIntent(), costs: .free, softDeadline: .milliseconds(100), hardDeadline: .milliseconds(500))
        #expect(empty.ranked.isEmpty)
        #expect(empty.pending == [.velora])
    }

    @Test("Calldata recusada conta como falha; tres falhas tiram o provedor por 60 s")
    func circuitBreaker() async throws {
        let p = try Self.proposals()
        // A Kyber "responde" com a calldata da Velora: router errado para o provedor.
        let hostile = p[.velora]!
        let lying = TradeProposal(provider: .kyberSwap, chainID: nil, from: nil, to: hostile.to, value: hostile.value, data: hostile.data,
                                  expectedOut: hostile.expectedOut, spender: nil, gasEstimate: nil, routeSources: nil, reportedPriceImpactBps: nil)
        let aggregator = TradeAggregator(sources: [
            StubSource(provider: .velora, delay: .milliseconds(5), proposal: p[.velora]),
            StubSource(provider: .kyberSwap, delay: .milliseconds(5), proposal: lying),
        ])
        for _ in 0..<3 {
            let set = await aggregator.quote(try S.baseIntent(), costs: .free, useCache: false)
            #expect(set.failures[.kyberSwap] == .refused(.kyberSwap, .routerNotAllowed(hostile.to)))
        }
        let benched = await aggregator.quote(try S.baseIntent(), costs: .free, useCache: false)
        #expect(benched.failures[.kyberSwap] == .benched(.kyberSwap))
        #expect(benched.ranked.map(\.quote.provider) == [.velora])
    }

    @Test("Provedor fora da rede nem e chamado (De¹ na Avalanche)")
    func unsupportedChain() async throws {
        let avaxUSDC = EVMToken(chain: .avalanche, contract: try EVMAddress("0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"), symbol: "USDC", decimals: 6)
        let intent = try TradeIntent(owner: S.owner, sell: .token(avaxUSDC), buy: .native(.avalanche), amountIn: 1_000_000, slippageBps: 50)
        let aggregator = TradeAggregator(sources: [StubSource(provider: .de1, delay: .milliseconds(1), proposal: nil)])
        let set = await aggregator.quote(intent, costs: .free)
        #expect(set.failures[.de1] == .unsupported(.de1))
    }
}

@Suite("Troca: CoW, corpo das requisicoes")
struct TradeCoWClientTests {
    typealias S = TradeNetworkSupport

    /// Chave de teste da EIP-155 (0x46...46), sem valor.
    static func sign(_ digest: [UInt8]) throws -> ProducedSignature {
        let key = SecureBytes(capacity: 32)
        key.replaceAll(with: [UInt8](repeating: 0x46, count: 32))
        defer { key.wipe() }
        let (compact, recoveryID) = try Secp256k1.signRecoverable(digest: digest, privateKey: key)
        return ProducedSignature(bytes: compact, recoveryID: recoveryID)
    }

    static func account() throws -> EVMAccount {
        let key = SecureBytes(capacity: 32)
        key.replaceAll(with: [UInt8](repeating: 0x46, count: 32))
        defer { key.wipe() }
        return try EVMAccount(path: DerivationPath("m/44'/60'/0'/0/0")!, publicKey: Secp256k1.publicKey(of: key))
    }

    @Test("Envio da ordem: corpo com a ordem local, assinatura r||s||v e appData cheio")
    func submissionBody() throws {
        let account = try Self.account()
        let intent = try CoWLimitOrderIntent(owner: account.address, sell: .token(S.baseUSDC), buy: .native(.base), sellAmount: 100_000_000,
                                             price: CoWLimitPrice("0.0004")!)
        let state = CoWChainState(
            network: EVMNetworkState(chain: .base, pendingNonces: [1, 1], baseFeePerGas: 5_000_000,
                                     priorityFees: EVMPriorityFees(slow: 1, normal: 1, fast: 1), gasEstimate: 46_000,
                                     l1DataFee: 1_000, nativeBalance: BigUInt(decimal: "1000000000000000000")!, destinationHasCode: true),
            sellToken: EVMTokenState(contractHasCode: true, balance: 100_000_000, allowance: 100_000_000)
        )
        let plan = try CoWPlanner.planLimitOrder(walletID: UUID(), account: account, intent: intent, state: state)
        #expect(plan.prerequisiteCount == 0)
        let message = plan.signingPlan.transactions[plan.orderSignatureIndex] as! EIP712ValidatedMessage
        let signed = try message.assemble(with: [Self.sign(message.digest)])
        let body = try CoWClient.submissionBody(plan, signature: signed)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["signingScheme"] as? String == "eip712")
        #expect(json["receiver"] as? String == "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f")
        #expect(json["buyAmount"] as? String == "40000000000000000")
        #expect(json["feeAmount"] as? String == "0")
        #expect(json["appData"] as? String == CoWAppData.limitOrder.json)
        #expect(json["appDataHash"] as? String == CoWAppData.limitOrder.hashHex)
        #expect((json["signature"] as? String)?.count == 132)
        // Assinatura de outro digesto e recusada antes de sair do aparelho.
        let wrong = try message.assemble(with: [Self.sign(message.digest)])
        let forged = SignedTransaction(chainID: wrong.chainID, raw: wrong.raw, encoded: wrong.encoded, id: "0x00")
        #expect(throws: CoWClientError.malformedSignature) { try CoWClient.submissionBody(plan, signature: forged) }
    }

    @Test("Consulta: ordem real da API lida, conferida contra o UID e contra a ordem esperada")
    func orderStatus() throws {
        let data = try S.fixture("cow-base-order-limit")
        let response = try JSONDecoder().decode(CoWClient.OrderResponse.self, from: data)
        let status = try CoWClient.status(response)
        #expect(status.status == .fulfilled)
        #expect(status.executedSellAmount == 48_645_716)
        #expect(status.remainingSellAmount == 0)
        #expect(CoWProtocol.owner(ofUID: status.uid) == status.owner)
    }

    @Test("Ordens abertas: so as do dono, abertas, nao invalidadas, no prazo e com saldo a vender")
    func openOrders() throws {
        // A ordem real gravada, com o estado trocado aqui para cada caso.
        let recorded = try JSONSerialization.jsonObject(with: try S.fixture("cow-base-order-limit")) as! [String: Any]
        let owner = try EVMAddress(recorded["owner"] as! String)
        let validTo = recorded["validTo"] as! Int
        func order(_ changes: [String: Any]) -> [String: Any] { recorded.merging(changes) { _, new in new } }
        let list: [[String: Any]] = [
            order(["status": "open", "executedSellAmount": "0"]),
            order(["status": "fulfilled"]),
            order(["status": "open", "invalidated": true, "executedSellAmount": "0"]),
            order(["status": "open", "executedSellAmount": recorded["sellAmount"] as! String]),
        ]
        let data = try JSONSerialization.data(withJSONObject: list)
        let before = Date(timeIntervalSince1970: TimeInterval(validTo - 60))
        let open = try CoWClient.openOrders(data, owner: owner, now: before)
        #expect(open.count == 1 && open.first?.status == .open && open.first?.remainingSellAmount == BigUInt(decimal: recorded["sellAmount"] as! String))
        // Vencida no relogio: fora.
        #expect(try CoWClient.openOrders(data, owner: owner, now: Date(timeIntervalSince1970: TimeInterval(validTo + 1))).isEmpty)
        // De outro dono: fora (o UID diz o dono, e a API nao escolhe por ele).
        #expect(try CoWClient.openOrders(data, owner: try EVMAddress("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"), now: before).isEmpty)
    }
}
