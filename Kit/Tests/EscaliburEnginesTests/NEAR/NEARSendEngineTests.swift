import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// As respostas gravadas da NEAR, as mesmas dos testes do leitor
/// (EscaliburNetworkTests/Fixtures/leitores/near, `gravar.py`), lidas do repositorio. O
/// dono e a conta implicita 78cb7728...0a31, com a chave dela.
enum NEAREngineRecorded {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("EscaliburNetworkTests/Fixtures/leitores/near")

    static let owner = "78cb7728d7f6257f78d979791c7372917fba684620485ccf9fcf80d91b450a31"
    static let ownerKey = [UInt8](hex: owner)!
    static let destination = "madturk.near"
    static let missing = "conta-que-nao-existe-escalibur.near"
    static let newImplicit = "b8d5df25047841365008f30fb6b30dd820e9a84d869f05623d114e96831f2fbf"
    static let balance = BigUInt(decimal: "53495151373309256233186715")!
    static let reserved = BigUInt(decimal: "249964470000000000000")!

    static func data(_ name: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(name + ".json")) }

    static func account(address: String = owner, key: [UInt8] = ownerKey) -> DerivedAccount {
        DerivedAccount(chainID: "near", path: DerivationPath("m/44'/397'/0'")!, address: address, publicKey: key, accountXPub: nil)
    }

    static func request(amount: BigUInt = NEARRules.oneNEAR, to destination: String = destination, sendAll: Bool = false,
                        asset: Asset = .native(.near), account: DerivedAccount = account(), known: [String] = []) -> SendRequest {
        SendRequest(
            walletID: UUID(), chain: .near, asset: asset, account: account, destination: destination, tag: nil,
            amount: amount, sendAll: sendAll, feeLevel: .normal, utxoUsage: nil, knownAddresses: known
        )
    }

    static var signed: SignedTransaction {
        get throws {
            let url = folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("EscaliburChainsTests/Fixtures/near/transferencias-reais.json")
            let list = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] ?? []
            let first = try #require(list.first)
            let encoded = try #require(first["signed_base64"] as? String)
            let raw = [UInt8](try #require(Data(base64Encoded: encoded)))
            return SignedTransaction(chainID: "near", raw: raw, encoded: encoded, id: try #require(first["hash"] as? String))
        }
    }

    /// JSON-RPC pelo metodo e pelos parametros; a FastNEAR pelo caminho. `sendError` faz
    /// o no recusar a transmissao; `functionCallKey`, a chave do dono so chamar contrato.
    struct Transport: ReaderTransport {
        var sendError = false
        var functionCallKey = false

        func send(_ request: ReaderRequest) async throws -> Data {
            if request.url.host == "historico.test" {
                return try data(request.url.path.hasSuffix("/v0/account") ? "historico-conta" : "historico-transacoes")
            }
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let params = body["params"] as? [String: Any] ?? [:]
            switch body["method"] as? String ?? "" {
            case "status": return try data("status")
            case "block": return try data("block-referencia")
            case "query":
                if params["request_type"] as? String == "view_access_key" {
                    guard params["public_key"] as? String == "ed25519:" + Base58.bitcoin.encode(ownerKey) else { return try data("view_access_key-outra") }
                    guard functionCallKey else { return try data("view_access_key-dono") }
                    let text = String(decoding: try data("view_access_key-dono"), as: UTF8.self)
                    return Data(text.replacingOccurrences(of: "\"FullAccess\"", with: "{\"FunctionCall\":{\"allowance\":null,\"method_names\":[],\"receiver_id\":\"x.near\"}}").utf8)
                }
                switch params["account_id"] as? String {
                case owner: return try data("view_account-dono")
                case destination: return try data("view_account-destino")
                default: return try data("view_account-inexistente")
                }
            case "EXPERIMENTAL_protocol_config": return try data("protocol_config")
            case "gas_price": return try data("gas_price")
            case "send_tx": return try data(sendError ? "send_tx-assinatura-invalida" : "send_tx-ja-incluida")
            case "tx": return try data(params["tx_hash"] as? String == "8VhtMYxX6hRaD827eaQcptC7Nw623n8FXuf17CdokwTg" ? "tx-final" : "tx-desconhecida")
            default: throw HTTPClient.Failure.status(404)
            }
        }
    }

    static func engine(_ transport: Transport = Transport()) -> NEARSendEngine {
        NEARSendEngine(reader: reader(transport))
    }

    static func reader(_ transport: Transport = Transport()) -> NEARReader {
        NEARReader(
            transport: transport, providers: ["a", "b", "c"].map { ProviderPool.Provider(name: $0, baseURL: URL(string: "https://\($0).test")!) },
            history: URL(string: "https://historico.test")!, pacing: 0
        )
    }
}

@Suite("NEAR: motor de envio com respostas gravadas")
struct NEARSendEngineTests {
    typealias R = NEAREngineRecorded

    @Test("Destino: conta com nome existente; inexistente para; implicita nova segue com a nota")
    func destination() async throws {
        let engine = R.engine()
        let named = try await engine.destination(R.destination, chain: .near)
        #expect(named.exists && !named.isContract && named.note == nil && !named.requiresTag)
        await #expect(throws: SendEngineError.message(NEAREngineText.namedMissing)) {
            _ = try await engine.destination(R.missing, chain: .near)
        }
        let fresh = try await engine.destination(R.newImplicit, chain: .near)
        #expect(!fresh.exists && fresh.activationMinimum == nil && fresh.note == NEAREngineText.newImplicit)
        await #expect(throws: SendEngineError.message(NEAREngineText.address(.otherNetwork(.ethereum)))) {
            _ = try await engine.destination("0x9858EfFD232B4033E47d90003D41EC34EcaEda94", chain: .near)
        }
        await #expect(throws: SendEngineError.unsupported(.polkadot)) { _ = try await engine.destination(R.destination, chain: .polkadot) }
    }

    @Test("Maximo: o saldo menos a reserva da taxa; a nota diz a taxa e a reserva")
    func spendable() async throws {
        let spendable = try await R.engine().spendable(R.request(sendAll: true))
        #expect(spendable.amount == R.balance - R.reserved)
        #expect(spendable.reserveNote == nil)
        #expect(spendable.feeNote?.contains("0,0000446365125 NEAR") == true)
    }

    @Test("Plano: destino e valor pedidos, avisos do motor e conferencia do app")
    func plan() async throws {
        let request = R.request(known: ["alice.near"])
        let plan = try await R.engine().plan(request)
        let transfer = try #require(plan.transactions.first as? NEARTransfer)
        #expect(transfer.fields.nonce == 217_540_425_000_009)
        #expect(Base58.bitcoin.encode(transfer.fields.blockHash) == "B8bnYvsCzJmnrQdEMWuMAN1m6VRtVChFie1fTAxm2b8S")
        #expect(transfer.fields.receiver.text == R.destination && transfer.fields.deposit == NEARRules.oneNEAR)
        #expect(plan.review.recipient == R.destination && plan.walletID == request.walletID)
        #expect(plan.review.warnings.contains(.firstSendToAddress))
        try PlanIntentCheck.send(plan.review, asset: .native(.near), amount: NEARRules.oneNEAR, ceiling: R.balance, chain: .near)

        // Enviar tudo: nunca mais do que o maximo de agora.
        let all = try await R.engine().plan(R.request(amount: R.balance, sendAll: true))
        #expect(all.review.outgoing?.amount == R.balance - R.reserved)
        try PlanIntentCheck.send(all.review, asset: .native(.near), amount: nil, ceiling: R.balance, chain: .near)
    }

    @Test("Recusas do motor: ativo, chave, conta com nome inexistente, chave so de contrato")
    func refusals() async throws {
        let engine = R.engine()
        await #expect(throws: SendEngineError.message(NEAREngineText.unsupportedAsset)) { _ = try await engine.plan(R.request(asset: .native(.ethereum))) }
        await #expect(throws: SendEngineError.message(NEAREngineText.keyMismatch)) {
            _ = try await engine.plan(R.request(account: R.account(address: R.newImplicit)))
        }
        await #expect(throws: SendEngineError.message(NEAREngineText.namedMissing)) { _ = try await engine.plan(R.request(to: R.missing)) }
        await #expect(throws: SendEngineError.message(NEAREngineText.keyNotOnAccount)) {
            _ = try await R.engine(R.Transport(functionCallKey: true)).plan(R.request())
        }
        // Outra chave na mesma conta: a leitura da chave de acesso nao acha a chave.
        let other = [UInt8](repeating: 3, count: 32)
        await #expect(throws: SendEngineError.message(NEAREngineText.keyMismatch)) {
            _ = try await engine.plan(R.request(account: R.account(address: R.owner, key: other)))
        }
        await #expect(throws: SendEngineError.message("O destino é a própria conta.")) { _ = try await engine.plan(R.request(to: R.owner)) }
    }

    @Test("Transmissao: so a transacao da carteira sai, o id e o calculado aqui; recusa com frase")
    func broadcast() async throws {
        let signed = try R.signed
        let engine = R.engine()
        #expect(try await engine.broadcast([signed], chain: .near) == signed.id)
        #expect(await engine.status(signed.id, chain: .near) == .confirmed(detail: NEAREngineText.confirmed))
        await #expect(throws: SendEngineError.message(NEAREngineText.rejected(.invalidSignature))) {
            _ = try await R.engine(R.Transport(sendError: true)).broadcast([signed], chain: .near)
        }
        var raw = signed.raw
        raw[10] ^= 1
        let tampered = SignedTransaction(chainID: "near", raw: raw, encoded: Data(raw).base64EncodedString(), id: signed.id)
        await #expect(throws: SendEngineError.message(NEAREngineText.notOurTransaction)) { _ = try await engine.broadcast([tampered], chain: .near) }
        #expect(await engine.status("11111111111111111111111111111111", chain: .near) == .pending)
    }

    @Test("Atividade: envios, recebimentos e a taxa, com a triagem de conta parecida")
    func activity() async throws {
        let entries = try await NEARActivitySource(reader: R.reader()).history(chain: .near, account: R.account(), usage: nil)
        #expect(entries.filter { $0.direction == .sent }.count == 4)
        #expect(entries.contains { $0.direction == .received && $0.counterparty == "wrap.near" && !$0.suspicious })
        #expect(entries.allSatisfy { $0.chainID == "near" && $0.asset == .native(.near) })
        let lookalike = ActivityItem(
            id: "near:x:in0", chainID: "near", direction: .received, asset: .native(.near), amount: NEARRules.oneNEAR,
            counterparty: "78cb" + String(repeating: "0", count: 56) + "0a31", date: .now, status: .confirmed, fee: nil, hash: "x", explorerURL: nil
        )
        #expect(NEARActivitySource.entries([lookalike], owner: R.owner).first?.suspicious == true)
    }

    @Test("Registro: envio e historico na NEAR, troca nao")
    func registry() {
        #expect(SendEngines.engine(for: .near) is NEARSendEngine)
        #expect(ActivitySources.source(for: .near) is NEARActivitySource)
        #expect(TradeEngines.engine(for: .near) == nil)
    }
}
