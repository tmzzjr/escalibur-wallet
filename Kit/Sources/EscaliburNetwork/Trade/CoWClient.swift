import EscaliburChains
import EscaliburCore
import Foundation

// A API da CoW (`api.cow.fi/{rede}/api/v1`), sem key. Formato conferido no openapi.yml do
// cowprotocol/services e ao vivo em 26/09/2026.
//
// - `PUT /app_data/{hash}` registra o documento do appData (idempotente).
// - `POST /orders` envia a ordem assinada; a resposta e o UID, que tem de ser o que a
//   carteira calculou (o UID carrega o digesto: UID diferente e ordem diferente).
// - `GET /orders/{uid}` consulta; os campos devolvidos sao conferidos contra a ordem
//   assinada antes de mostrar qualquer coisa.
// - `DELETE /orders` cancela fora da cadeia com `OrderCancellations` assinado. Nao e
//   garantido; o cancelamento garantido e `invalidateOrder` na cadeia (CoWPlanner).

public enum CoWClientError: Error, Equatable, Sendable {
    case unsupportedChain
    case malformedSignature
    case uidMismatch
    case orderMismatch
    case badResponse(String)
}

/// O estado de uma ordem, como a API conta e depois de conferido.
public struct CoWOrderStatus: Sendable, Equatable {
    public enum Status: String, Sendable {
        case open, fulfilled, cancelled, expired, presignaturePending, unknown
    }

    public let uid: [UInt8]
    public let status: Status
    public let invalidated: Bool
    public let owner: EVMAddress
    public let sellToken: EVMAddress
    public let buyToken: EVMAddress
    public let receiver: EVMAddress
    public let sellAmount: BigUInt
    public let buyAmount: BigUInt
    public let validTo: UInt32
    public let executedSellAmount: BigUInt
    public let executedBuyAmount: BigUInt

    /// A API devolveu a mesma ordem que foi assinada?
    public func matches(_ order: CoWOrder) -> Bool {
        sellToken == order.sellToken && buyToken == order.buyToken && receiver == order.receiver
            && sellAmount == order.sellAmount && buyAmount == order.buyAmount && validTo == order.validTo
    }

    /// Quanto ainda falta vender.
    public var remainingSellAmount: BigUInt {
        sellAmount.subtractingReportingUnderflow(executedSellAmount) ?? 0
    }
}

public struct CoWClient: Sendable {
    let client: HTTPClient
    let base: URL

    public init(client: HTTPClient = .shared, base: URL = Endpoints.trade["cow"]!.baseURL) {
        self.client = client
        self.base = base
    }

    func api(_ chain: Chain) throws -> URL {
        guard let network = CoWProtocol.apiNetwork(for: chain) else { throw CoWClientError.unsupportedChain }
        return base.appendingPathComponent(network).appendingPathComponent("api/v1")
    }

    static func hex(_ bytes: [UInt8]) -> String { Hex.encode(bytes, prefix: true) }

    // MARK: appData

    public func registerAppData(_ appData: CoWAppData, chain: Chain) async throws {
        let body = try JSONEncoder().encode(["fullAppData": appData.json])
        _ = try await client.send("PUT", try api(chain).appendingPathComponent("app_data/\(appData.hashHex)"), json: body)
    }

    // MARK: Envio

    struct Submission: Encodable {
        let sellToken, buyToken, receiver: String
        let sellAmount, buyAmount: String
        let validTo: UInt32
        let feeAmount: String
        let kind: String
        let partiallyFillable: Bool
        let sellTokenBalance, buyTokenBalance: String
        let signingScheme: String
        let signature: String
        let from: String
        let appData: String
        let appDataHash: String
    }

    /// Confere a assinatura (65 bytes, v 27/28, recupera o dono sobre o digesto local)
    /// antes de mandar: assinatura quebrada so seria recusada pela API depois.
    static func checkSignature(_ signature: SignedTransaction, digest: [UInt8], owner: EVMAddress) throws {
        let raw = signature.raw
        guard raw.count == 65, raw[64] == 27 || raw[64] == 28, signature.id == hex(digest),
              let key = try? Secp256k1.recover(digest: digest, compact: Array(raw.prefix(64)), recoveryID: raw[64] - 27, compressed: true),
              (try? EVMAddress(publicKey: key)) == owner
        else { throw CoWClientError.malformedSignature }
    }

    static func submissionBody(_ plan: CoWLimitOrderPlan, signature: SignedTransaction) throws -> Data {
        let order = plan.order
        try checkSignature(signature, digest: Array(plan.uid.prefix(32)), owner: plan.owner)
        let submission = Submission(
            sellToken: TradeWire.lower(order.sellToken), buyToken: TradeWire.lower(order.buyToken),
            receiver: TradeWire.lower(order.receiver), sellAmount: order.sellAmount.decimalString,
            buyAmount: order.buyAmount.decimalString, validTo: order.validTo, feeAmount: "0", kind: order.kind,
            partiallyFillable: order.partiallyFillable, sellTokenBalance: order.sellTokenBalance,
            buyTokenBalance: order.buyTokenBalance, signingScheme: "eip712", signature: hex(signature.raw),
            from: TradeWire.lower(plan.owner), appData: plan.appData.json, appDataHash: plan.appData.hashHex
        )
        return try JSONEncoder().encode(submission)
    }

    /// Envia a ordem assinada. So depois que o approve (e o embrulho) confirmaram: a CoW
    /// recusa ordem sem saldo e allowance. Devolve o UID, conferido.
    public func submit(_ plan: CoWLimitOrderPlan, signature: SignedTransaction) async throws -> [UInt8] {
        let body = try Self.submissionBody(plan, signature: signature)
        let data = try await client.post(try api(plan.order.chain).appendingPathComponent("orders"), json: body, timeout: 15)
        guard let text = try? JSONDecoder().decode(String.self, from: data), let uid = Hex.decode(String(text.dropFirst(2))) else {
            throw CoWClientError.badResponse("uid")
        }
        guard uid == plan.uid else { throw CoWClientError.uidMismatch }
        return uid
    }

    // MARK: Consulta

    struct OrderResponse: Decodable {
        let uid: String
        let owner: String
        let status: String
        let invalidated: Bool?
        let sellToken, buyToken, receiver: String
        let sellAmount, buyAmount: String
        let validTo: UInt32
        let executedSellAmount: String?
        let executedBuyAmount: String?
    }

    static func status(_ response: OrderResponse) throws -> CoWOrderStatus {
        func address(_ text: String, _ field: String) throws -> EVMAddress {
            guard text.hasPrefix("0x"), let bytes = Hex.decode(String(text.dropFirst(2))), let value = EVMAddress(bytes: bytes) else {
                throw CoWClientError.badResponse(field)
            }
            return value
        }
        func amount(_ text: String?, _ field: String) throws -> BigUInt {
            guard let value = BigUInt(decimal: text ?? "0") else { throw CoWClientError.badResponse(field) }
            return value
        }
        guard let uid = Hex.decode(String(response.uid.dropFirst(2))), uid.count == CoWProtocol.uidLength else {
            throw CoWClientError.badResponse("uid")
        }
        let owner = try address(response.owner, "owner")
        guard CoWProtocol.owner(ofUID: uid) == owner, CoWProtocol.validTo(ofUID: uid) == response.validTo else {
            throw CoWClientError.orderMismatch
        }
        return CoWOrderStatus(
            uid: uid, status: CoWOrderStatus.Status(rawValue: response.status) ?? .unknown,
            invalidated: response.invalidated ?? false, owner: owner,
            sellToken: try address(response.sellToken, "sellToken"), buyToken: try address(response.buyToken, "buyToken"),
            receiver: try address(response.receiver, "receiver"),
            sellAmount: try amount(response.sellAmount, "sellAmount"), buyAmount: try amount(response.buyAmount, "buyAmount"),
            validTo: response.validTo,
            executedSellAmount: try amount(response.executedSellAmount, "executedSellAmount"),
            executedBuyAmount: try amount(response.executedBuyAmount, "executedBuyAmount")
        )
    }

    /// `GET /orders/{uid}`. Com `expected`, recusa se a API devolver outra ordem.
    public func order(uid: [UInt8], chain: Chain, expected: CoWOrder? = nil) async throws -> CoWOrderStatus {
        let data = try await client.get(try api(chain).appendingPathComponent("orders/\(Self.hex(uid))"), timeout: 10)
        let response: OrderResponse
        do { response = try JSONDecoder().decode(OrderResponse.self, from: data) } catch { throw CoWClientError.badResponse("ordem") }
        let status = try Self.status(response)
        guard status.uid == uid else { throw CoWClientError.uidMismatch }
        if let expected, !status.matches(expected) { throw CoWClientError.orderMismatch }
        return status
    }

    /// Soma do que ainda falta vender nas ordens abertas do dono para um token: a regra
    /// de "uma ordem aberta por token vendido" (docs/seguranca.md 4.5).
    public func openSellTotal(owner: EVMAddress, sellToken: EVMAddress, chain: Chain) async throws -> BigUInt {
        try await openOrders(owner: owner, chain: chain)
            .filter { $0.sellToken == sellToken }
            .reduce(BigUInt()) { $0 + $1.remainingSellAmount }
    }

    /// As ordens abertas do dono (`GET /account/{dono}/orders`): so as do proprio dono,
    /// abertas, nao invalidadas na cadeia e ainda no prazo, cada uma com o UID conferido
    /// (dono e validTo gravados nele). A CoW e a unica fonte do livro de ordens.
    public func openOrders(owner: EVMAddress, chain: Chain, now: Date = .now) async throws -> [CoWOrderStatus] {
        let url = try TradeWire.url(try api(chain), "account/\(TradeWire.lower(owner))/orders", [("limit", "1000")])
        let data = try await client.get(url, timeout: 10)
        return try Self.openOrders(data, owner: owner, now: now)
    }

    static func openOrders(_ data: Data, owner: EVMAddress, now: Date) throws -> [CoWOrderStatus] {
        let responses: [OrderResponse]
        do { responses = try JSONDecoder().decode([OrderResponse].self, from: data) } catch { throw CoWClientError.badResponse("ordens") }
        let current = UInt32(clamping: Int64(now.timeIntervalSince1970))
        return try responses.map(Self.status).filter {
            $0.owner == owner && $0.status == .open && !$0.invalidated && $0.validTo > current && !$0.remainingSellAmount.isZero
        }
    }

    // MARK: Cancelamento fora da cadeia

    public func cancel(uids: [[UInt8]], chain: Chain, owner: EVMAddress, signature: SignedTransaction) async throws {
        let typed = try CoWPlanner.cancellationTypedData(chain: chain, uids: uids)
        try Self.checkSignature(signature, digest: try typed.signingDigest(), owner: owner)
        struct Body: Encodable {
            let orderUids: [String]
            let signature: String
            let signingScheme: String
        }
        let body = try JSONEncoder().encode(Body(orderUids: uids.map(Self.hex), signature: Self.hex(signature.raw), signingScheme: "eip712"))
        _ = try await client.send("DELETE", try api(chain).appendingPathComponent("orders"), json: body, timeout: 15)
    }
}
