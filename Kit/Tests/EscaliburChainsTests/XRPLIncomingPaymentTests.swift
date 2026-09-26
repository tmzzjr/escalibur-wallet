import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// Leitura de recebimento: o valor entregue vem de `meta.delivered_amount`, nunca do
/// `Amount`/`DeliverMax`.
///
/// Fontes: XRPLF/xrpl.js, packages/xrpl/test/fixtures/rippled/partialPaymentXRP.json,
/// partialPaymentIOU.json, streams/partialPaymentTransaction.json e tx/payment.json,
/// commit 5c41405. Sao as respostas que o proprio xrpl.js usa para testar o aviso de
/// pagamento parcial.
@Suite("XRPL recebimento")
struct XRPLIncomingPaymentTests {
    static func response(_ name: String, validated: Bool? = true) throws -> [String: Any] {
        let entry = try XRPLFixtures.json("receipts")[name] as! [String: Any]
        var response = entry["response"] as! [String: Any]
        // As fixtures do xrpl.js omitem `validated` em parte das respostas; a leitura
        // exige, entao o teste diz explicitamente.
        if let validated { response["validated"] = validated }
        return response
    }

    @Test("Pagamento parcial de XRP (API v2): vale o delivered_amount, nao o DeliverMax")
    func partialXRP() throws {
        let response = try Self.response("partial_xrp_v2")
        let tx = response["tx_json"] as! [String: Any]
        #expect(tx["DeliverMax"] as? String == "2000000")
        guard case .delivered(let delivery) = XRPLIncomingPayment.read(object: response) else {
            Issue.record("deveria ler")
            return
        }
        #expect(delivery.delivered == .xrp(drops: 1_000_000))
        #expect(delivery.isPartialPayment)
        #expect(delivery.sender == "rGFuMiw48HdbnrUbkRYuitXTmfrDBNTCnX")
        #expect(delivery.destination == "rNNuQMuExCiEjeZ4h9JJnj5PSWypdMXDj4")
        #expect(delivery.hash == "A0A074D10355223CBE2520A42F93A52E3CC8B4D692570EB4841084F9BBB39F7A")
    }

    @Test("Pagamento parcial de token (API v2): 9,98 USD entregues de um teto de 10")
    func partialIOU() throws {
        guard case .delivered(let delivery) = XRPLIncomingPayment.read(object: try Self.response("partial_iou_v2")) else {
            Issue.record("deveria ler")
            return
        }
        let expected = try XRPLIssuedAmount(
            value: XRPLDecimal("9.980039920159681"), currency: XRPLCurrency(code: "USD"), issuer: "rvYAfWj5gh67oV6fW32ZzP3Aw4Eubs59B"
        )
        #expect(delivery.delivered == .issued(expected))
        #expect(delivery.isPartialPayment)
    }

    @Test("O golpe classico (stream, API v1): Amount de 1 bilhao de XRP, 4456 drops entregues")
    func scamStream() throws {
        let response = try Self.response("partial_stream_v1", validated: nil)
        let tx = response["transaction"] as! [String: Any]
        #expect(tx["Amount"] as? String == "1000000000000000")
        let data = try JSONSerialization.data(withJSONObject: response)
        guard case .delivered(let delivery) = XRPLIncomingPayment.read(json: data) else {
            Issue.record("deveria ler")
            return
        }
        #expect(delivery.delivered == .xrp(drops: 4456))
        #expect(delivery.isPartialPayment)
        #expect(delivery.ledgerIndex == 66_093_882)
    }

    @Test("Sem delivered_amount, sem validacao, falha ou outro tipo: nada vira recebido")
    func refusals() throws {
        // O tx/payment.json do xrpl.js nao traz delivered_amount: a leitura nao cai
        // para o DeliverMax.
        #expect(XRPLIncomingPayment.read(object: try Self.response("payment_without_delivered_v2")) == .deliveredAmountUnavailable)
        #expect(XRPLIncomingPayment.read(object: try Self.response("partial_xrp_v2", validated: false)) == .notValidated)
        #expect(XRPLIncomingPayment.read(object: try Self.response("partial_xrp_v2", validated: nil)) == .notValidated)

        var failed = try Self.response("partial_xrp_v2")
        var meta = failed["meta"] as! [String: Any]
        meta["TransactionResult"] = "tecPATH_PARTIAL"
        failed["meta"] = meta
        #expect(XRPLIncomingPayment.read(object: failed) == .failed(result: "tecPATH_PARTIAL"))

        var old = try Self.response("partial_xrp_v2")
        meta = old["meta"] as! [String: Any]
        meta["delivered_amount"] = "unavailable"
        old["meta"] = meta
        #expect(XRPLIncomingPayment.read(object: old) == .deliveredAmountUnavailable)

        var offer = try Self.response("partial_xrp_v2")
        var tx = offer["tx_json"] as! [String: Any]
        tx["TransactionType"] = "OfferCreate"
        offer["tx_json"] = tx
        #expect(XRPLIncomingPayment.read(object: offer) == .notAPayment)

        var mpt = try Self.response("partial_xrp_v2")
        meta = mpt["meta"] as! [String: Any]
        meta["delivered_amount"] = ["mpt_issuance_id": "00002403C84A0A28E0190E208E982C352BBD5006600555CF", "value": "10"]
        mpt["meta"] = meta
        #expect(XRPLIncomingPayment.read(object: mpt) == .unsupported)

        #expect(XRPLIncomingPayment.read(json: Data("nao e json".utf8)) == .unsupported)
    }

    @Test("Pagamento comum com tag: nao marcado como parcial; resposta embrulhada em result")
    func plainPayment() throws {
        var response = try Self.response("partial_xrp_v2")
        var tx = response["tx_json"] as! [String: Any]
        tx["Flags"] = 0
        tx["DestinationTag"] = 4_294_967_295
        response["tx_json"] = tx
        guard case .delivered(let delivery) = XRPLIncomingPayment.read(object: ["result": response]) else {
            Issue.record("deveria ler")
            return
        }
        #expect(!delivery.isPartialPayment)
        #expect(delivery.destinationTag == UInt32.max)

        tx["DestinationTag"] = 4_294_967_296
        response["tx_json"] = tx
        #expect(XRPLIncomingPayment.read(object: response) == .unsupported)
    }
}
