import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Os clientes da ponte lendo respostas reais da Iris e do Across, gravadas em 12/10/2026,
/// e recusando as adulteradas.
@Suite("Ponte: clientes da Circle e do Across")
struct BridgeClientTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/bridge/\(name).json"))
    }

    static func edited(_ name: String, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: try fixture(name)) as! [String: Any]
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    static let ethUSDC = try! EVMAddress("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    static let baseUSDC = try! EVMAddress("0x833589fcd6edb6e08f4c7c32d4f71b54bda02913")
    /// O `timestamp` da cotacao gravada.
    static let quotedAt = Date(timeIntervalSince1970: 1_791_769_979)

    // MARK: Iris

    @Test("Taxas da Circle: bps exatos e encaminhamento na faixa alta")
    func irisFees() throws {
        let fees = try CircleIrisClient.fees(try Self.fixture("iris-fees-eth-base"))
        #expect(fees.fast?.protocolBps == TradeDecimal("1"))
        #expect(fees.standard?.protocolBps == TradeDecimal("0"))
        #expect(fees.fast?.forwardFee == BigUInt(decimal: "54386"))
        // 10.000 USDC na rapida: 1 bps = 1 USDC, mais a taxa de encaminhamento.
        let fast = try #require(fees.fast)
        #expect(CCTPFees.maxFee(amount: BigUInt(10_000_000_000), level: fast) == BigUInt(1_000_000 + 54386))
        // Bps com casa decimal arredonda para cima: 1,3 bps de 1 unidade e 1.
        let odd = CCTPFees.Level(protocolBps: TradeDecimal("1.3")!, forwardFee: 0)
        #expect(CCTPFees.maxFee(amount: 1, level: odd) == 1)
        #expect(CCTPFees.maxFee(amount: BigUInt(1_000_000), level: odd) == 130)
    }

    @Test("Taxa absurda ou sem encaminhamento e recusada")
    func irisFeesRefused() {
        let high = Data(#"[{"finalityThreshold":1000,"minimumFee":150,"forwardFee":{"low":1,"med":1,"high":1}}]"#.utf8)
        #expect(throws: CircleIrisError.badResponse("taxa alta")) { try CircleIrisClient.fees(high) }
        let noForward = Data(#"[{"finalityThreshold":2000,"minimumFee":0}]"#.utf8)
        #expect(throws: CircleIrisError.badResponse("taxas")) { try CircleIrisClient.fees(noForward) }
    }

    @Test("Mensagem atestada e encaminhada")
    func irisMessage() throws {
        let attested = try CircleIrisClient.attested(try Self.fixture("iris-message-forwarded"))
        #expect(attested.complete)
        #expect(attested.message?.amount == 21164)
        #expect(!attested.attestation.isEmpty)
        #expect(attested.forward == .complete(txHash: "0xdcc8f5874e0e6ad36f0a357baf92f8a2943031fc2c37e1a3e7ff277e87ea4cb3"))
    }

    @Test("Duas mensagens numa queima nao e transacao da carteira")
    func irisTwoMessages() throws {
        let data = try Self.edited("iris-message-forwarded") { object in
            let messages = object["messages"] as! [Any]
            object["messages"] = messages + messages
        }
        #expect(throws: CircleIrisError.badResponse("mensagens")) { try CircleIrisClient.attested(data) }
    }

    // MARK: Across

    static func acrossQuote(_ data: Data, now: Date = quotedAt) throws -> AcrossQuote {
        try AcrossClient.quote(data, inputToken: ethUSDC, outputToken: baseUSDC, originChainID: 1, destinationChainID: 8453,
                               amount: BigUInt(1_000_000_000), now: now)
    }

    @Test("Cotacao do Across: valor, prazos, relayer e limites")
    func acrossFees() throws {
        let quote = try Self.acrossQuote(try Self.fixture("across-fees-usdc-eth-base"))
        #expect(quote.outputAmount == BigUInt(999_896_537))
        #expect(quote.inputAmount - quote.outputAmount == BigUInt(103_463))
        #expect(quote.quoteTimestamp == 1_791_769_979)
        #expect(quote.fillDeadline == 1_791_777_179)
        #expect(quote.exclusivityDeadline == 1_791_770_139)
        #expect(quote.exclusiveRelayer != nil)
        #expect(quote.maxDeposit > quote.maxDepositInstant)
    }

    @Test("Cotacao do Across adulterada e recusada")
    func acrossRefused() throws {
        let name = "across-fees-usdc-eth-base"
        let otherToken = try Self.edited(name) { object in
            var token = object["outputToken"] as! [String: Any]
            token["address"] = "0x1111111111111111111111111111111111111111"
            object["outputToken"] = token
        }
        #expect(throws: AcrossClientError.mismatch("tokens")) { try Self.acrossQuote(otherToken) }
        let more = try Self.edited(name) { $0["outputAmount"] = "1000000001" }
        #expect(throws: AcrossClientError.badResponse("taxa")) { try Self.acrossQuote(more) }
        let farDeadline = try Self.edited(name) { $0["fillDeadline"] = String(1_791_769_979 + 3 * 86_400) }
        #expect(throws: AcrossClientError.mismatch("prazo de entrega")) { try Self.acrossQuote(farDeadline) }
        let lonelyRelayer = try Self.edited(name) { $0["exclusiveRelayer"] = "0x0000000000000000000000000000000000000000" }
        #expect(throws: AcrossClientError.mismatch("exclusividade")) { try Self.acrossQuote(lonelyRelayer) }
        // Cotacao velha: o relogio andou 15 minutos.
        #expect(throws: AcrossClientError.mismatch("horário da cotação")) {
            try Self.acrossQuote(try Self.fixture(name), now: Self.quotedAt.addingTimeInterval(900))
        }
    }

    @Test("Regressao R7-B1: valor de 1 MB nas respostas do Across e da Iris e recusado na hora")
    func hugeNumbersRefused() throws {
        // Os campos numericos que chegam como texto (Across) ou numero (Iris) passam pelo
        // `BigUInt(decimal:)`, que recusa mais de 78 digitos antes de converter.
        let digits = String(repeating: "9", count: 1_000_000)
        let name = "across-fees-usdc-eth-base"
        var answers: [Data] = [try Self.edited(name) { $0["outputAmount"] = digits }]
        for field in ["minDeposit", "maxDeposit", "maxDepositInstant"] {
            answers.append(try Self.edited(name) { object in
                var limits = object["limits"] as! [String: Any]
                limits[field] = digits
                object["limits"] = limits
            })
        }
        let fees = Data(#"[{"finalityThreshold":1000,"minimumFee":1,"forwardFee":{"low":1,"med":1,"high":\#(digits)}}]"#.utf8)
        let elapsed = try ContinuousClock().measure {
            for answer in answers {
                #expect(throws: AcrossClientError.badResponse("taxa")) { try Self.acrossQuote(answer) }
            }
            #expect(throws: CircleIrisError.badResponse("taxas")) { try CircleIrisClient.fees(fees) }
            _ = try Self.acrossQuote(try Self.fixture(name))
        }
        // O tempo inclui ler 5 MB de JSON; a conversao quadratica levaria minutos.
        #expect(elapsed < .seconds(2))
    }

    @Test("Andamento do deposito")
    func acrossStatus() throws {
        let status = try AcrossClient.status(try Self.fixture("across-status-filled"))
        #expect(status.state == .filled)
        #expect(status.fillTxHash == "0xc5cb5caff751741769e7a8c6e05d1b182ef523caf4211e270c713efa3e50c408")
        #expect(status.refundTxHash == nil)
    }
}
