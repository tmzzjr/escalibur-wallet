import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
@testable import EscaliburEngines

/// As respostas gravadas da TON (Fixtures/ton) e um transporte que responde com elas, sem
/// rede. Ver Fixtures/ton/LEIA-ME.txt para a origem de cada arquivo.
enum TONRecorded {
    /// Os testes ao vivo so rodam com ESCALIBUR_REDE=1.
    static let liveNetwork = ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"

    /// A carteira V4R2 das respostas gravadas; a chave e a de `get_public_key` do proprio
    /// contrato (ver EscaliburNetworkTests/TONReaderLiveTests.swift).
    static let ownerKey = Hex.decode("38b6bd15c9dc2c929269db0c8967e15cf2da2b96a937e4a7cc2938e1a1f30b2e") ?? []
    static let ownerPath = DerivationPath("m/44'/607'/0'")!
    static let wallet = try! TONWallet(publicKey: ownerKey, version: .v4r2)
    static let ownerJettonWallet = "0:16e07181d7abc5e87ef9a4a696dad8a4b2199f46165f7e21a0dd1935aa393948"
    static let ownerBalance = BigUInt(96_633_095_889_328)
    static let jettonBalance = BigUInt(169_460_663_914)
    static let estimatedFee = BigUInt(66_727)

    /// Uma carteira V4R2 que existe na rede. O transporte responde por ela com o
    /// `getAddressInformation` gravado do dono (a resposta nao traz o endereco).
    static let activeDestination = parse("0:12d12a693dbeff8e278fb409f2a1fc5896403f878f442a646e3613b85c13eca2")
    /// Um endereco sem contrato.
    static let uninitializedDestination = parse("0:1111111111111111111111111111111111111111111111111111111111111111")
    /// A conta do historico gravado (tonapi-events-envenenada).
    static let poisoned = parse("0:c44015434ad966c8dab4b5180f272d094855e0a7489a2dd05acf6a6c1ee47faa")

    static let usdt = TokenRegistry.find(chainID: "ton", contract: "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs")!
    static let ton = Asset.native(.ton)
    /// Hora fixa: a validade e o `query_id` da mensagem saem dela.
    static let now = Date(timeIntervalSince1970: 1_790_406_100)

    static func parse(_ text: String) -> TONAddress {
        guard case .success(let parsed) = TONAddress.parse(text) else { fatalError("endereco de teste invalido") }
        return parsed.address
    }

    struct Missing: Error { let name: String }

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/ton") else {
            throw Missing(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func account(address: String = wallet.address.friendly(bounceable: false), key: [UInt8] = ownerKey) -> DerivedAccount {
        DerivedAccount(chainID: "ton", path: ownerPath, address: address, publicKey: key, accountXPub: nil)
    }

    static func request(
        asset: Asset, to destination: String = activeDestination.friendly(bounceable: false), amount: BigUInt,
        comment: String? = nil, sendAll: Bool = false, known: [String] = []
    ) -> SendRequest {
        SendRequest(
            walletID: UUID(), chain: .ton, asset: asset, account: account(), destination: destination, tag: comment,
            amount: amount, sendAll: sendAll, feeLevel: .normal, utxoUsage: nil, knownAddresses: known
        )
    }

    static func provider(_ name: String) -> ProviderPool.Provider {
        ProviderPool.Provider(name: name, baseURL: URL(string: "https://\(name).test")!)
    }

    static func reader(_ transport: Transport) -> TONReader {
        TONReader(transport: transport, rpc: [provider("toncenter-v2")], api: [provider("tonapi"), provider("toncenter")])
    }

    static func engine(_ transport: Transport, deadlines: TONSendEngine.Deadlines = .init(), now: Date = now) -> TONSendEngine {
        TONSendEngine(reader: reader(transport), deadlines: deadlines, now: { now })
    }

    /// toncenter v2 pelo `method` (e pela conta, no `getAddressInformation`); tonapi e
    /// toncenter v3 pelo caminho. A tonapi responde as mesmas contas que a toncenter (o
    /// dono e o destino ativo com a gravacao do dono, o resto nao inicializado), com o
    /// campo `address` trocado pelo pedido. `override` responde antes das gravacoes e
    /// pode lancar.
    final class Transport: ReaderTransport, @unchecked Sendable {
        typealias Override = @Sendable (_ host: String, _ path: String, _ method: String?, _ params: [String: Any]) throws -> Data?

        private let lock = NSLock()
        private var log: [ReaderRequest] = []
        private let override: Override?
        private let active: Data
        private let uninitialized: Data
        private let rpc: [String: Data]
        private let tonapi: [String: Data]
        private let tonapiActive: String
        private let tonapiUninitialized: String
        private let messageTransactions: Data

        init(override: Override? = nil) throws {
            self.override = override
            active = try TONRecorded.data("getAddressInformation-dono")
            uninitialized = try TONRecorded.data("getAddressInformation-nao-inicializada")
            rpc = [
                "estimateFee": try TONRecorded.data("estimateFee"),
                "seqno": try TONRecorded.data("runGetMethod-seqno"),
                "get_wallet_address": try TONRecorded.data("runGetMethod-get_wallet_address"),
                "get_wallet_data": try TONRecorded.data("runGetMethod-get_wallet_data"),
            ]
            tonapi = [
                "/methods/seqno": try TONRecorded.data("tonapi-seqno"),
                "/transaction": try TONRecorded.data("tonapi-message-transaction"),
                "/events": try TONRecorded.data("tonapi-events-envenenada"),
                "\(TONRecorded.ownerJettonWallet)/methods/get_wallet_data": try TONRecorded.data("tonapi-get_wallet_data"),
            ]
            tonapiActive = String(decoding: try TONRecorded.data("tonapi-account-dono"), as: UTF8.self)
            tonapiUninitialized = String(decoding: try TONRecorded.data("tonapi-account-nao-inicializada"), as: UTF8.self)
            messageTransactions = try TONRecorded.data("toncenter-transactionsByMessage")
        }

        var requests: [ReaderRequest] { lock.withLock { log } }

        func send(_ request: ReaderRequest) async throws -> Data {
            lock.withLock { log.append(request) }
            let host = request.url.host ?? ""
            let path = request.url.path
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let params = body["params"] as? [String: Any] ?? [:]
            var method = body["method"] as? String
            if method == "runGetMethod" { method = params["method"] as? String }
            if let override, let data = try override(host, path, method, params) { return data }
            switch host {
            case "toncenter-v2.test":
                if method == "getAddressInformation" {
                    let address = params["address"] as? String
                    let known = [TONRecorded.wallet.address.raw, TONRecorded.activeDestination.raw]
                    return known.contains(address ?? "") ? active : uninitialized
                }
                if let method, let data = rpc[method] { return data }
            case "tonapi.test":
                if let data = tonapi.first(where: { path.hasSuffix($0.key) })?.value { return data }
                if let account = Self.tonapiAccount(path) {
                    let known = [TONRecorded.wallet.address.raw, TONRecorded.activeDestination.raw]
                    return Self.readdressed(known.contains(account) ? tonapiActive : tonapiUninitialized, to: account)
                }
            case "toncenter.test":
                if path.hasSuffix("/transactionsByMessage") { return messageTransactions }
            default:
                break
            }
            throw HTTPClient.Failure.status(404)
        }

        /// A conta de `/blockchain/accounts/{conta}`, sem nada depois.
        static func tonapiAccount(_ path: String) -> String? {
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "blockchain", parts[1] == "accounts" else { return nil }
            return String(parts[2])
        }

        /// A resposta gravada da tonapi com o campo `address` trocado.
        static func readdressed(_ json: String, to address: String) -> Data {
            guard let range = json.range(of: #""address":\s*"[^"]*""#, options: .regularExpression) else { return Data(json.utf8) }
            return Data(json.replacingCharacters(in: range, with: #""address":""# + address + #"""#).utf8)
        }
    }
}
