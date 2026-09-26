@testable import EscaliburChains
import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburEngines
@testable import EscaliburNetwork

/// Apoio dos testes dos motores EVM: respostas gravadas (Fixtures/evm, ver LEIA-ME.txt),
/// um transporte que responde por regra, as contas dos testes e servicos de mentira para
/// a troca.
enum EVMFixtures {
    static func data(_ name: String, folder: String = "Fixtures/evm") throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: folder) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func trade(_ name: String) throws -> Data {
        try data(name, folder: "Fixtures/evm/troca")
    }

    static func json(_ name: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data(name)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    /// Resposta JSON-RPC com `result`.
    static func result(_ literal: String) -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(literal)}".utf8)
    }
}

/// Um transporte sem rede: cada regra olha a requisicao e devolve os bytes gravados, ou
/// `nil` para a proxima regra. Guarda o que foi pedido, para o teste conferir quem
/// recebeu o que.
final class EVMFixtureTransport: ReaderTransport, @unchecked Sendable {
    struct Call {
        let host: String
        let method: String?
        let params: [Any]
        let request: ReaderRequest

        var firstObject: [String: Any]? { params.first as? [String: Any] }
    }

    typealias Rule = @Sendable (Call) throws -> Data?

    private let lock = NSLock()
    private var rules: [Rule]
    private var log: [Call] = []

    init(_ rules: [Rule] = []) {
        self.rules = rules
    }

    /// Regras novas entram na frente: o caso especial do teste antes da gravacao comum.
    func prepend(_ rule: @escaping Rule) {
        lock.withLock { rules.insert(rule, at: 0) }
    }

    var calls: [Call] { lock.withLock { log } }

    func calls(_ method: String) -> [Call] { calls.filter { $0.method == method } }

    func send(_ request: ReaderRequest) async throws -> Data {
        var method: String?
        var params: [Any] = []
        if let body = request.body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            method = object["method"] as? String
            params = object["params"] as? [Any] ?? []
        }
        let call = Call(host: request.url.host ?? "", method: method, params: params, request: request)
        let current = lock.withLock { () -> [Rule] in
            log.append(call)
            return rules
        }
        for rule in current {
            if let data = try rule(call) { return data }
        }
        throw HTTPClient.Failure.status(404)
    }
}

extension EVMFixtureTransport.Call: @unchecked Sendable {}

enum EVMTestAccounts {
    static let path = DerivationPath("m/44'/60'/0'/0/0")!

    /// "Binance 8", carteira quente de exchange com saldo nas sete redes. A chave publica
    /// foi recuperada da assinatura da transacao 0x16d93ffd...10cfc na Ethereum (a mesma
    /// dos testes do leitor EVM).
    static let binance8PublicKey = [UInt8](hex: "02607495e42d9fd036496ae938284f66fa67c12ab13a75213cbc33ec751164eb4b")!
    static let binance8 = try! EVMAddress("0xF977814e90dA44bFA03b6295A0616a897441aceC")
    /// "Binance 14": destino sem codigo.
    static let binance14 = try! EVMAddress("0x28C6c06298d514Db089934071355E5743bf21d60")
    /// Safe da GnosisDAO na Ethereum: proxy com codigo, aceita ETH.
    static let safe = try! EVMAddress("0x849D52316331967b6fF1198e5E32A0eB168D039d")
    /// Contrato de deposito da Beacon Chain: sem funcao de recebimento, ETH puro reverte.
    static let depositContract = try! EVMAddress("0x00000000219ab540356cBB839Cbe05303d7705Fa")

    static func binance8(on chain: Chain) -> DerivedAccount {
        DerivedAccount(chainID: chain.id, path: path, address: binance8.checksummed, publicKey: binance8PublicKey, accountXPub: nil)
    }

    /// A chave do exemplo da EIP-155 (0x46...46), sem valor. So nos testes sem rede: o
    /// endereco dela (0x9d8A...5A4F) tem delegacao EIP-7702 para um sweeper, e e o dono das
    /// cotacoes gravadas em Fixtures/evm/troca.
    static let testKey = "4646464646464646464646464646464646464646464646464646464646464646"

    static func privateKey() -> SecureBytes {
        let key = SecureBytes(capacity: 32)
        key.replaceAll(with: [UInt8](hex: testKey)!)
        return key
    }

    static func testAccount(on chain: Chain) throws -> DerivedAccount {
        let key = privateKey()
        defer { key.wipe() }
        let publicKey = try Secp256k1.publicKey(of: key)
        let address = try EVMAddress(publicKey: publicKey)
        return DerivedAccount(chainID: chain.id, path: path, address: address.checksummed, publicKey: publicKey, accountXPub: nil)
    }

    /// Assina cada transacao do plano com a chave de teste, como o assinador do app faria.
    static func sign(_ plan: SigningPlan) throws -> [SignedTransaction] {
        let key = privateKey()
        defer { key.wipe() }
        return try plan.transactions.map { transaction in
            let signatures = try transaction.signingRequests.map { request -> ProducedSignature in
                let (compact, recoveryID) = try Secp256k1.signRecoverable(digest: request.payload, privateKey: key)
                return ProducedSignature(bytes: compact, recoveryID: recoveryID)
            }
            return try transaction.assemble(with: signatures)
        }
    }
}

/// Os provedores de mentira: o host diz quem e quem.
func testProviders(_ names: String...) -> [ProviderPool.Provider] {
    names.map { ProviderPool.Provider(name: $0, baseURL: URL(string: "https://\($0).test")!) }
}

/// As respostas gravadas da Ethereum (Binance 8), por metodo e, onde importa, por
/// destino da chamada.
enum EVMEthereumFixtures {
    static let usdc = try! EVMAddress("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")
    static let transferSelector = "0xa9059cbb"
    static let balanceOfSelector = "0x70a08231"

    static func lower(_ address: EVMAddress) -> String { "0x" + Hex.encode(address.bytes) }

    static func transport() throws -> EVMFixtureTransport {
        let fixed: [String: Data] = [
            "eth_chainId": try EVMFixtures.data("eth_chainId-ethereum"),
            "eth_blockNumber": try EVMFixtures.data("eth_blockNumber-ethereum"),
            "eth_getTransactionCount": try EVMFixtures.data("eth_getTransactionCount-binance8"),
            "eth_feeHistory": try EVMFixtures.data("eth_feeHistory-ethereum"),
            "eth_getBalance": try EVMFixtures.data("eth_getBalance-binance8"),
            "eth_getTransactionReceipt": try EVMFixtures.data("eth_getTransactionReceipt-binance8"),
        ]
        let code: [String: Data] = [
            lower(EVMTestAccounts.binance14): try EVMFixtures.data("eth_getCode-binance14"),
            lower(EVMTestAccounts.safe): try EVMFixtures.data("eth_getCode-safe"),
            lower(usdc): try EVMFixtures.data("eth_getCode-usdc"),
        ]
        let estimates: [String: Data] = [
            lower(EVMTestAccounts.binance14): try EVMFixtures.data("eth_estimateGas-nativo"),
            lower(EVMTestAccounts.safe): try EVMFixtures.data("eth_estimateGas-safe"),
            lower(usdc): try EVMFixtures.data("eth_estimateGas-usdc"),
        ]
        let balanceOf = try EVMFixtures.data("balanceOf-usdc-binance8")
        let transfer = try EVMFixtures.data("eth_call-transfer-usdc")
        let nativeToSafe = try EVMFixtures.data("eth_call-nativo-safe")
        let nativeToDeposit = try EVMFixtures.data("eth_call-nativo-deposit-revert")
        return EVMFixtureTransport([{ call in
            guard let method = call.method else { return nil }
            if let data = fixed[method] { return data }
            switch method {
            case "eth_getCode":
                return code[(call.params.first as? String)?.lowercased() ?? ""] ?? EVMFixtures.result("\"0x\"")
            case "eth_estimateGas":
                return estimates[(call.firstObject?["to"] as? String)?.lowercased() ?? ""]
            case "eth_call":
                let to = (call.firstObject?["to"] as? String)?.lowercased() ?? ""
                let data = (call.firstObject?["data"] as? String)?.lowercased() ?? ""
                if data.hasPrefix(balanceOfSelector) { return balanceOf }
                if data.hasPrefix(transferSelector) { return transfer }
                if to == lower(EVMTestAccounts.safe) { return nativeToSafe }
                if to == lower(EVMTestAccounts.depositContract) { return nativeToDeposit }
                return nil
            case "eth_sendRawTransaction":
                // O no devolve o hash dos bytes que recebeu.
                guard let raw = call.params.first as? String, let bytes = Hex.decode(raw) else { return nil }
                return EVMFixtures.result("\"\(Hex.encode(Hash.keccak256(bytes), prefix: true))\"")
            default:
                return nil
            }
        }])
    }

    static func reader(_ transport: EVMFixtureTransport, providers: [ProviderPool.Provider] = testProviders("a", "b")) -> EVMReader {
        EVMReader(transport: transport, rpc: ["ethereum": providers], history: [:], privateRelays: testProviders("relay1", "relay2"))
    }
}
