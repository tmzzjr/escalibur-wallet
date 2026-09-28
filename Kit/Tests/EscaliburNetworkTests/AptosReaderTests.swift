import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Respostas da Aptos gravadas em 28/09/2026 (Fixtures/leitores/aptos, `gravar.py`): a API
/// REST da PublicNode e da Sentio e o indexador GraphQL da Aptos Labs. Conta 0x966e...6c41
/// (chave publica tirada da assinatura de uma transacao dela na rede); destinos: um com APT
/// e um que nunca recebeu.
enum AptosRecorded {
    struct Recording: Decodable {
        let dono: String, chave: String, existente: String, nova: String
        let valor: UInt64, versao: UInt64, hora: UInt64, preco: UInt64, sequencia: UInt64, saldo: UInt64
        let transacao: String
    }

    struct Missing: Error { let name: String }

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/leitores/aptos") else {
            throw Missing(name: name)
        }
        return try Data(contentsOf: url)
    }

    static let recording = try! JSONDecoder().decode(Recording.self, from: data("gravacao.json"))
    static let owner = address(recording.dono)
    static let ownerKey = [UInt8](hex: recording.chave)!

    static func address(_ text: String) -> AptosAddress {
        guard case .success(let address) = AptosAddress.parse(text) else { fatalError("endereco de teste invalido") }
        return address
    }

    /// Os bytes simulados (com a assinatura zerada) de uma gravacao, e a transacao dentro.
    static func simulated(_ name: String) throws -> (bytes: [UInt8], raw: AptosRawTransaction) {
        let text = String(decoding: try data("simulacao-\(name).bcs.hex"), as: UTF8.self)
        let bytes = try #require([UInt8](hex: text))
        return (bytes, try AptosRawTransaction.decode(Array(bytes.dropLast(99))))
    }

    /// Responde pelo caminho e pelo corpo, com as gravacoes de cada provedor; o terceiro
    /// provedor (reserva) responde como a Sentio. `override` responde antes e pode lancar.
    final class Transport: ReaderTransport, @unchecked Sendable {
        typealias Override = @Sendable (_ provider: String, _ path: String, _ body: Data) throws -> Data?
        private let lock = NSLock()
        private var log: [ReaderRequest] = []
        private let override: Override?
        private let simulations: [(bytes: [UInt8], name: String)]

        init(override: Override? = nil) throws {
            self.override = override
            simulations = try ["estimativa-existente", "envio-existente", "estimativa-nova", "envio-nova"].map {
                (try AptosRecorded.simulated($0).bytes, $0)
            }
        }

        var requests: [ReaderRequest] { lock.withLock { log } }

        func send(_ request: ReaderRequest) async throws -> Data {
            lock.withLock { log.append(request) }
            let host = request.url.host ?? ""
            let provider = host.hasPrefix("publicnode") ? "publicnode" : "sentio"
            let path = request.url.path
            let body = request.body ?? Data()
            if let override, let data = try override(host.components(separatedBy: ".")[0], path, body) { return data }
            if path.hasSuffix("/graphql") { return try AptosRecorded.data("graphql-historico-dono.json") }
            if path.hasSuffix("/v1") { return try AptosRecorded.data("indice-\(provider).json") }
            if path.hasSuffix("/estimate_gas_price") { return try AptosRecorded.data("preco-gas.json") }
            if path.hasSuffix("/view") { return try AptosRecorded.data("view-\(try Self.viewName(body)).json") }
            if path.hasSuffix("/transactions/simulate") {
                guard let entry = simulations.first(where: { $0.bytes == [UInt8](body) }) else { throw HTTPClient.Failure.status(400) }
                return try AptosRecorded.data("simulacao-\(entry.name)-\(provider).json")
            }
            if path.contains("/transactions/by_hash/"), path.hasSuffix(AptosRecorded.recording.transacao) {
                return try AptosRecorded.data("transacao-\(provider).json")
            }
            throw HTTPClient.Failure.status(404)
        }

        /// A gravacao de cada view, pela funcao e pelo primeiro argumento.
        static func viewName(_ body: Data) throws -> String {
            let json = try StrictJSON.parse(body)
            let function = try json.field("function", "view").string("function")
            let first = try json.field("arguments", "view").array("arguments")[0].string("arguments")
            switch function {
            case "0x1::account::get_sequence_number": return "sequencia-dono"
            case "0x1::account::get_authentication_key": return "chave-dono"
            case "0x1::coin::balance": return "saldo-dono"
            case "0x1::primary_fungible_store::primary_store_exists":
                return first == AptosRecorded.recording.existente ? "loja-existente" : "loja-nova"
            default: throw HTTPClient.Failure.status(400)
            }
        }
    }

    static func providers() -> [ProviderPool.Provider] {
        ["publicnode", "sentio", "aptoslabs"].map { ProviderPool.Provider(name: $0, baseURL: URL(string: "https://\($0).test/v1")!) }
    }

    static func reader(_ transport: Transport, indexer: Bool = true) -> AptosReader {
        AptosReader(transport: transport, providers: providers(), indexer: indexer ? URL(string: "https://indexer.test/v1/graphql") : nil, pacing: 0)
    }

    /// Uma transferencia da rede principal assinada aqui com a chave do vetor do wallet-core.
    static func signed(sequence: UInt64 = 3) throws -> SignedTransaction {
        let seed = SecureBytes(capacity: 32)
        defer { seed.wipe() }
        seed.replaceAll(with: [UInt8](hex: "5d996aa76b3212142792d9130796cd2e11e3c445a93118c08414df4f66bc60ec")!)
        let key = try Ed25519.publicKey(of: seed)
        let raw = AptosRawTransaction(
            sender: try AptosAddress(ed25519PublicKey: key), sequenceNumber: sequence, recipient: address(recording.existente),
            amount: 1_000, maxGasAmount: 200, gasUnitPrice: 100, expirationTimestampSecs: recording.hora + 120, chainID: 1
        )
        let signature = try Ed25519.sign(raw.signingMessage, seed: seed)
        let bytes = raw.bcs() + [0, 32] + key + [64] + signature
        return SignedTransaction(chainID: "aptos", raw: bytes, encoded: Hex.encode(bytes), id: AptosSignedTransaction.hash(of: bytes))
    }
}

@Suite("Leitor Aptos com respostas gravadas")
struct AptosReaderTests {
    typealias R = AptosRecorded

    @Test("Estado da conta: dois provedores na mesma versao do ledger, a menor das duas")
    func accountState() async throws {
        let transport = try R.Transport()
        let reader = R.reader(transport)
        let state = try await reader.accountState(owner: R.owner, destination: R.address(R.recording.existente))
        #expect(state.sequenceNumber == R.recording.sequencia && state.balance == R.recording.saldo)
        #expect(state.authenticationKey == R.owner.bytes && state.gasUnitPrice == R.recording.preco && state.chainID == 1)
        #expect(state.ledgerVersion == R.recording.versao && state.ledgerTimestamp == R.recording.hora)
        #expect(state.destinationExists)
        let views = transport.requests.filter { $0.url.path.hasSuffix("/view") }
        #expect(views.count == 8)
        #expect(views.allSatisfy { $0.url.query == "ledger_version=\(R.recording.versao)" && $0.method == .post })
        // O endereco vai no corpo, nunca no caminho.
        #expect(!transport.requests.contains { $0.url.absoluteString.contains(String(R.recording.dono.dropFirst(2))) })

        let fresh = try await reader.accountState(owner: R.owner, destination: R.address(R.recording.nova))
        #expect(!fresh.destinationExists)
        #expect(try await reader.destinationExists(R.address(R.recording.nova)) == false)
    }

    @Test("Provedor que diverge no saldo, ou em outra rede, e recusado")
    func disagreementAndWrongNetwork() async throws {
        let lying = try R.Transport { provider, path, body in
            guard provider == "sentio", path.hasSuffix("/view"), try R.Transport.viewName(body) == "saldo-dono" else { return nil }
            return Data(#"["3376623592"]"#.utf8)
        }
        await #expect(throws: ReaderError.providersDisagree(field: "account")) {
            _ = try await R.reader(lying).accountState(owner: R.owner, destination: R.address(R.recording.existente))
        }
        let devnet = try R.Transport { provider, path, _ in
            guard provider == "publicnode", path.hasSuffix("/v1") else { return nil }
            return Data(#"{"chain_id":33,"ledger_version":"7391711772","ledger_timestamp":"1790570883000000"}"#.utf8)
        }
        // O no de outra rede cai, e o reserva (a Aptos Labs) entra no lugar dele.
        let state = try await R.reader(devnet).accountState(owner: R.owner, destination: R.address(R.recording.existente))
        #expect(state.chainID == 1)
        let bothWrong = try R.Transport { _, path, _ in
            path.hasSuffix("/v1") ? Data(#"{"chain_id":2,"ledger_version":"1","ledger_timestamp":"1"}"#.utf8) : nil
        }
        await #expect(throws: ReaderError.wrongNetwork) {
            _ = try await R.reader(bothWrong).accountState(owner: R.owner, destination: R.address(R.recording.existente))
        }
    }

    @Test("Simulacao gravada: gas usado, hash dos bytes e eventos de loja")
    func simulation() async throws {
        let reader = R.reader(try R.Transport())
        for (name, expected) in [("estimativa-existente", 63), ("estimativa-nova", 5_415)] as [(String, UInt64)] {
            let raw = try R.simulated(name).raw
            #expect(try await reader.estimateGasUsed(raw, publicKey: R.ownerKey) == expected)
        }
        let raw = try R.simulated("envio-existente").raw
        let results = try await reader.simulate(raw, publicKey: R.ownerKey)
        #expect(results.count == 2 && results.allSatisfy(\.success))
        #expect(results[0].events == [
            .withdraw(store: R.owner.primaryAPTStore, amount: R.recording.valor),
            .deposit(store: R.address(R.recording.existente).primaryAPTStore, amount: R.recording.valor),
            .fee(totalGasUnits: 63),
        ])
        #expect(results[0].hash == AptosSignedTransaction.hash(of: AptosSignedTransaction.simulationBytes(raw, publicKey: R.ownerKey)))
    }

    @Test("Acompanhamento: confirmada nos dois, pendente, nao achada e vencida")
    func status() async throws {
        let reader = R.reader(try R.Transport())
        #expect(try await reader.status(of: R.recording.transacao) == .confirmed(block: 7_391_617_458, confirmations: nil))
        let unknown = "0x" + String(repeating: "ab", count: 32)
        #expect(try await reader.status(of: unknown) == .notFound)
        #expect(try await reader.status(of: unknown, expiresAt: R.recording.hora + 60) == .notFound)
        #expect(try await reader.status(of: unknown, expiresAt: R.recording.hora - 60) == .failed(reason: "expired"))

        let pending = try R.Transport { _, path, _ in
            path.contains("/by_hash/") ? Data(#"{"type":"pending_transaction","hash":"\#(unknown)"}"#.utf8) : nil
        }
        #expect(try await R.reader(pending).status(of: unknown) == .pending)
        let swapped = try R.Transport { provider, path, _ in
            provider == "sentio" && path.contains("/by_hash/") ? Data(#"{"type":"pending_transaction","hash":"0x01"}"#.utf8) : nil
        }
        // A Sentio responde outro hash: cai, e a Aptos Labs (reserva, gravacao da Sentio) responde.
        #expect(try await R.reader(swapped).status(of: R.recording.transacao) == .confirmed(block: 7_391_617_458, confirmations: nil))
        await #expect(throws: ReaderError.invalidInput("hash")) { _ = try await reader.status(of: "0x1234") }
    }

    @Test("Transmissao: os mesmos bytes em BCS para dois provedores, hash conferido")
    func broadcast() async throws {
        let signed = try R.signed()
        let accepting = try R.Transport { _, path, body in
            guard path.hasSuffix("/transactions") else { return nil }
            #expect([UInt8](body) == signed.raw)
            return Data(#"{"hash":"\#(signed.id)"}"#.utf8)
        }
        let receipt = try await R.reader(accepting).broadcast(signed)
        #expect(receipt.id == signed.id && receipt.acceptedBy == ["publicnode", "sentio"])
        #expect(accepting.requests.filter { $0.url.path.hasSuffix("/transactions") }.allSatisfy {
            $0.headers["Content-Type"] == "application/x.aptos.signed_transaction+bcs"
        })

        let rejecting = try R.Transport { _, path, _ in
            if path.hasSuffix("/transactions") { throw HTTPClient.Failure.status(400) }
            return nil
        }
        await #expect(throws: ReaderError.broadcastRejected(.other, code: "http-400")) { _ = try await R.reader(rejecting).broadcast(signed) }

        let otherHash = try R.Transport { _, path, _ in
            path.hasSuffix("/transactions") ? Data(#"{"hash":"0x\#(String(repeating: "0", count: 64))"}"#.utf8) : nil
        }
        await #expect(throws: ReaderError.broadcastMismatch) { _ = try await R.reader(otherHash).broadcast(signed) }

        var tampered = signed.raw
        tampered[40] ^= 1
        let bad = SignedTransaction(chainID: "aptos", raw: tampered, encoded: Hex.encode(tampered), id: signed.id)
        let silent = try R.Transport()
        await #expect(throws: ReaderError.broadcastMismatch) { _ = try await R.reader(silent).broadcast(bad) }
        #expect(silent.requests.isEmpty)
    }

    @Test("Saldo da tela e historico do indexador")
    func balanceAndHistory() async throws {
        let transport = try R.Transport()
        let reader = R.reader(transport)
        let balance = try await reader.displayBalance(owner: R.recording.dono)
        #expect(balance.holdings == [Holding(asset: .native(.aptos), amount: BigUInt(R.recording.saldo))] && balance.accountExists)

        let page = try await reader.history(owner: R.owner)
        #expect(page.items.count == 30 && page.items.allSatisfy { $0.direction == .sent && $0.status == .confirmed })
        let first = try #require(page.items.first)
        #expect(first.fee == BigUInt(541_500) && first.counterparty?.count == 66 && first.explorerURL?.absoluteString.contains(first.hash) == true)
        #expect(UInt64(first.hash) != nil && first.id == "aptos:\(first.hash)")
        let query = String(decoding: try R.data("historico.graphql"), as: UTF8.self)
        #expect(AptosReader.historyQuery == query.trimmingCharacters(in: .whitespacesAndNewlines))
        let request = try #require(transport.requests.first { $0.url.path.hasSuffix("/graphql") })
        #expect(try StrictJSON.parse(request.body ?? Data()).field("variables", "").field("owner", "").string("") == R.recording.dono)
    }

    /// Movimentos que a conta gravada nao tem, montados no formato do indexador.
    @Test("Historico: recebimento, po, valor zero, falha e token de fora")
    func historyShapes() throws {
        let owner = R.recording.dono
        let other = "0x" + String(repeating: "3", count: 64)
        func activity(_ who: String, _ type: String, _ amount: UInt64, gas: Bool = false, ok: Bool = true) -> String {
            #"{"owner_address":"\#(who)","type":"\#(type)","amount":\#(amount),"is_gas_fee":\#(gas),"is_transaction_success":\#(ok),"transaction_timestamp":"2026-09-28T04:44:00.123456"}"#
        }
        func tx(_ version: Int, sender: String, _ activities: [String]) -> String {
            #"{"transaction_version":\#(version),"user_transaction":{"sender":"\#(sender)","entry_function_id_str":"0x1::aptos_account::transfer"},"fungible_asset_activities":[\#(activities.joined(separator: ","))]}"#
        }
        let withdraw = "0x1::fungible_asset::Withdraw", deposit = "0x1::fungible_asset::Deposit", gas = "0x1::aptos_coin::GasFeeEvent"
        let entries = [
            tx(5, sender: other, [activity(other, gas, 6_300, gas: true), activity(other, withdraw, 250_000_000), activity(owner, deposit, 250_000_000)]),
            tx(4, sender: other, [activity(other, gas, 6_300, gas: true), activity(other, withdraw, 1), activity(owner, deposit, 1)]),
            tx(3, sender: other, [activity(other, gas, 6_300, gas: true), activity(other, withdraw, 0), activity(owner, deposit, 0)]),
            tx(2, sender: owner, [activity(owner, gas, 6_300, gas: true, ok: false)]),
            tx(1, sender: other, [activity(other, gas, 6_300, gas: true)]),
        ]
        let json = try StrictJSON.parse(Data(#"{"data":{"account_transactions":[\#(entries.joined(separator: ","))]}}"#.utf8))
        let page = try AptosReader.parseHistory(json, owner: R.owner)
        #expect(page.items.count == 2)
        let received = try #require(page.items.first { $0.id == "aptos:5" })
        #expect(received.direction == .received && received.amount == BigUInt(250_000_000) && received.counterparty == other && received.fee == nil)
        let failed = try #require(page.items.first { $0.id == "aptos:2" })
        #expect(failed.direction == .other && failed.status == .failed && failed.fee == BigUInt(6_300))
        #expect(page.suspicious.dust == 1 && page.suspicious.zeroValue == 1 && page.suspicious.unknownAsset == 1)
        #expect(failed.date == Date(timeIntervalSince1970: 1_790_570_640))
        #expect(throws: ReaderError.providerError(code: "graphql")) {
            try AptosReader.parseHistory(try StrictJSON.parse(Data(#"{"errors":[{"message":"x"}]}"#.utf8)), owner: R.owner)
        }
    }
}
