import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
@testable import EscaliburEngines

/// As respostas gravadas da Tron (Fixtures/tron) e um transporte que responde com elas,
/// sem rede. Ver Fixtures/tron/LEIA-ME.txt para a origem de cada arquivo.
enum TronRecorded {
    /// Os testes ao vivo so rodam com ESCALIBUR_REDE=1.
    static let liveNetwork = ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"

    /// Conta de exchange com TRX, USDT, stake e permissoes de dono unico. A chave publica
    /// foi recuperada da assinatura da transacao f5e12244...dbdcb (ver
    /// EscaliburNetworkTests/TronReaderLiveTests.swift).
    static let owner = "TNXoiAJ3dct8Fjg4M9fkLFh9S2v9TXc32G"
    static let ownerKey = Hex.decode("026a2745758b2ece1844db054201c56698b1942f390ac4e2ab44f3ec711dc8322a") ?? []
    static let ownerPath = DerivationPath("m/44'/195'/0'/0/0")!
    /// Conta ativada que ja tem USDT.
    static let destination = "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
    /// Conta que a rede nao conhece.
    static let unfunded = "TDJD7vKogBsFECgWtEmN4RMKx3vNzCkP6B"
    static let usdtContract = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
    /// A vitima do transferFrom de valor zero (trongrid-*-envenenada).
    static let poisoned = "TU7TrZe1T73WB5s8W2A5iFgj8VTirc7Bdj"

    static let usdt = TokenRegistry.find(chainID: "tron", contract: usdtContract)!
    static let trx = Asset.native(.tron)

    struct Missing: Error { let name: String }

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/tron") else {
            throw Missing(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func object(_ name: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: try data(name)) as? [String: Any] else { throw Missing(name: name) }
        return object
    }

    static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A hora do bloco gravado: o leitor recusa bloco a mais de uma hora do relogio.
    static func blockTime() throws -> Date {
        let block = try object("getnowblock")
        let header = block["block_header"] as? [String: Any]
        let raw = header?["raw_data"] as? [String: Any]
        guard let millis = (raw?["timestamp"] as? NSNumber)?.int64Value else { throw Missing(name: "getnowblock.timestamp") }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }

    static func account(address: String = owner, key: [UInt8] = ownerKey) -> DerivedAccount {
        DerivedAccount(chainID: "tron", path: ownerPath, address: address, publicKey: key, accountXPub: nil)
    }

    static func request(
        asset: Asset, to destination: String = destination, amount: BigUInt, memo: String? = nil, sendAll: Bool = false,
        known: [String] = [], walletID: UUID = UUID()
    ) -> SendRequest {
        SendRequest(
            walletID: walletID, chain: .tron, asset: asset, account: account(), destination: destination, tag: memo,
            amount: amount, sendAll: sendAll, feeLevel: .normal, utxoUsage: nil, knownAddresses: known
        )
    }

    /// Dois provedores de mentira com os nomes que o leitor reconhece: a PublicNode para as
    /// leituras de um provedor so e a TronGrid para o consenso e o historico.
    static let providers = ["publicnode", "trongrid"].map {
        ProviderPool.Provider(name: $0, baseURL: URL(string: "https://\($0).test")!)
    }

    static func engine(_ transport: Transport, now: Date? = nil) throws -> TronSendEngine {
        let clock = try now ?? blockTime()
        return TronSendEngine(reader: TronReader(transport: transport, providers: providers), deadlines: TronSendEngine.Deadlines(), now: { clock })
    }

    /// Responde pelo caminho `/wallet/...`, com `getaccount` e `getcontract` pelo endereco
    /// pedido e `triggerconstantcontract` pelo seletor. `override` responde antes das
    /// gravacoes (resposta alterada no teste) e pode lancar para simular falha de rede.
    final class Transport: ReaderTransport, @unchecked Sendable {
        typealias Override = @Sendable (_ host: String, _ path: String, _ body: [String: Any]) throws -> Data?

        private let lock = NSLock()
        private var log: [ReaderRequest] = []
        private let override: Override?
        private let paths: [String: Data]
        private let accounts: [String: Data]
        private let contracts: [String: Data]
        private let balanceOf: Data
        private let transfer: Data

        init(override: Override? = nil) throws {
            self.override = override
            paths = [
                "/wallet/getnowblock": try TronRecorded.data("getnowblock"),
                "/wallet/getaccountresource": try TronRecorded.data("getaccountresource-dono"),
                "/wallet/getchainparameters": try TronRecorded.data("getchainparameters"),
                "/walletsolidity/gettransactioninfobyid": try TronRecorded.data("gettransactioninfobyid-usdt"),
                "/wallet/gettransactioninfobyid": try TronRecorded.data("gettransactioninfobyid-usdt"),
                "/v1/accounts/\(TronRecorded.poisoned)/transactions": try TronRecorded.data("trongrid-transactions-envenenada"),
                "/v1/accounts/\(TronRecorded.poisoned)/transactions/trc20": try TronRecorded.data("trongrid-trc20-envenenada"),
            ]
            accounts = [
                TronRecorded.owner: try TronRecorded.data("getaccount-dono"),
                TronRecorded.destination: try TronRecorded.data("getaccount-destino"),
                TronRecorded.unfunded: try TronRecorded.data("getaccount-inexistente"),
            ]
            contracts = [
                TronRecorded.destination: try TronRecorded.data("getcontract-conta"),
                TronRecorded.unfunded: try TronRecorded.data("getcontract-conta"),
                TronRecorded.usdtContract: try TronRecorded.data("getcontract-usdt"),
            ]
            balanceOf = try TronRecorded.data("balanceOf-dono")
            transfer = try TronRecorded.data("transfer-estimativa")
        }

        var requests: [ReaderRequest] { lock.withLock { log } }

        func paths(containing text: String) -> [String] {
            requests.map(\.url.path).filter { $0.contains(text) }
        }

        func send(_ request: ReaderRequest) async throws -> Data {
            lock.withLock { log.append(request) }
            let path = request.url.path
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if let override, let data = try override(request.url.host ?? "", path, body) { return data }
            if let data = paths[path] { return data }
            switch path {
            case "/wallet/getaccount":
                if let address = body["address"] as? String, let data = accounts[address] { return data }
            case "/wallet/getcontract":
                if let address = body["value"] as? String, let data = contracts[address] { return data }
            case "/wallet/triggerconstantcontract":
                return body["function_selector"] as? String == "balanceOf(address)" ? balanceOf : transfer
            default:
                break
            }
            throw HTTPClient.Failure.status(404)
        }
    }

    /// O getaccount do dono com uma chave estranha somada a permissao de dono (threshold
    /// 2, as duas chaves com peso 1): o controle dividido do golpe da "seed com USDT".
    static func splitControlAccount() throws -> Data {
        var account = try object("getaccount-dono")
        account["owner_permission"] = [
            "permission_name": "owner", "threshold": 2,
            "keys": [["address": owner, "weight": 1], ["address": "TNPeeaaFB7K9cmo4uQpcU32zGK8G1NYqeL", "weight": 1]],
        ] as [String: Any]
        return encode(account)
    }

    /// Recursos de uma conta sem stake e com a cota gratis do dia gasta.
    static let noResources = Data("{}".utf8)
}
