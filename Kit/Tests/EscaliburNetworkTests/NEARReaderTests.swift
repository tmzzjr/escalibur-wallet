import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// As respostas gravadas da NEAR (Fixtures/leitores/near, `gravar.py`), todas no bloco
/// 217.581.805. O dono e a conta implicita 78cb7728...0a31, com a chave de acesso total
/// dela; o destino com nome e madturk.near, que existe.
enum NEARRecorded {
    static let owner = "78cb7728d7f6257f78d979791c7372917fba684620485ccf9fcf80d91b450a31"
    static let ownerKey = [UInt8](hex: owner)!
    static let destination = "madturk.near"
    static let missing = "conta-que-nao-existe-escalibur.near"
    static let checkpointHeight: UInt64 = 217_581_805
    static let checkpointHash = "B8bnYvsCzJmnrQdEMWuMAN1m6VRtVChFie1fTAxm2b8S"
    static let providers = testProviders("a", "b", "c")
    static let history = URL(string: "https://historico.test")!
    /// A transferencia real 8VhtMYxX... do dono (Fixtures/near/transferencias-reais.json
    /// nos testes de EscaliburChains), assinada e aceita pela rede.
    static let signedBase64 = "QAAAADc4Y2I3NzI4ZDdmNjI1N2Y3OGQ5Nzk3OTFjNzM3MjkxN2ZiYTY4NDYyMDQ4NWNjZjlmY2Y4MGQ5MWI0NTBhMzEAeMt3KNf2JX942Xl5HHNykX+6aEYgSFzPn8+A2RtFCjFHpMET2sUAABEAAABuZWFydG9rZW5ib3QubmVhcv+MjzpHTfKIzPxkr3M1btmnvc0VpJ1w8VOPSChDcBzVAQAAAAPEjm9CAID8eGceAAAAAAAAALeAIjc5vijpMHCDbGGHlPPUWuqO9gO0yDr0RcoT4OzHrIk6Vj/8pt4cXW0E8PZLbQETqufHGj+j/gkPbm+2Dgo="
    static let signedID = "8VhtMYxX6hRaD827eaQcptC7Nw623n8FXuf17CdokwTg"

    static func data(_ name: String) throws -> Data { try ReaderFixtures.data("near", name) }

    static func account(_ text: String) -> NEARAccountID {
        guard case .success(let account) = NEARAccountID.parse(text) else { fatalError("conta do teste") }
        return account
    }

    static var signed: SignedTransaction {
        let raw = [UInt8](Data(base64Encoded: signedBase64)!)
        return SignedTransaction(chainID: "near", raw: raw, encoded: signedBase64, id: signedID)
    }

    /// Os parametros de objeto de um corpo JSON-RPC da NEAR.
    static func params(_ body: StrictJSON?) -> [String: StrictJSON] {
        guard case .object(let fields)? = body, case .object(let params)? = fields["params"] else { return [:] }
        return params
    }

    static func string(_ params: [String: StrictJSON], _ key: String) -> String? {
        guard case .string(let text)? = params[key] else { return nil }
        return text
    }

    /// `override` responde antes do gravado: host do provedor, metodo e parametros.
    static func transport(
        override: (@Sendable (String, String, [String: StrictJSON]) throws -> Data?)? = nil
    ) -> FixtureTransport {
        FixtureTransport([
            { request, body in
                guard let host = request.url.host, host.hasSuffix(".test"), host != "historico.test",
                      let method = FixtureTransport.method(body) else { return nil }
                let params = params(body)
                if let custom = try override?(host, method, params) { return custom }
                switch method {
                case "status": return try data("status")
                case "block":
                    if params["finality"] != nil { return try data("block-referencia") }
                    guard case .number(let text)? = params["block_id"], UInt64(text) == checkpointHeight else { return nil }
                    return try data("block-referencia")
                case "query":
                    switch string(params, "request_type") {
                    case "view_account":
                        switch string(params, "account_id") {
                        case owner: return try data("view_account-dono")
                        case destination: return try data("view_account-destino")
                        default: return try data("view_account-inexistente")
                        }
                    case "view_access_key":
                        let key = "ed25519:" + Base58.bitcoin.encode(ownerKey)
                        return try data(string(params, "public_key") == key ? "view_access_key-dono" : "view_access_key-outra")
                    default: return nil
                    }
                case "EXPERIMENTAL_protocol_config": return try data("protocol_config")
                case "gas_price": return try data("gas_price")
                case "send_tx": return try data("send_tx-ja-incluida")
                case "tx": return try data(string(params, "tx_hash") == signedID ? "tx-final" : "tx-desconhecida")
                default: return nil
                }
            },
            { request, _ in
                guard request.url.host == "historico.test" else { return nil }
                return try data(request.url.path.hasSuffix("/v0/account") ? "historico-conta" : "historico-transacoes")
            },
        ])
    }

    static func reader(_ transport: FixtureTransport) -> NEARReader {
        NEARReader(transport: transport, providers: providers, history: history, pacing: 0)
    }

    /// A resposta gravada com um texto trocado.
    static func replacing(_ name: String, _ old: String, _ new: String) throws -> Data {
        Data(String(decoding: try data(name), as: UTF8.self).replacingOccurrences(of: old, with: new).utf8)
    }
}

@Suite("NEAR: leitor com respostas gravadas")
struct NEARReaderTests {
    typealias R = NEARRecorded

    @Test("Estado no bloco final, em dois provedores concordando, com a conta so no corpo")
    func state() async throws {
        let transport = R.transport()
        let reading = try await R.reader(transport).state(owner: R.account(R.owner), publicKey: R.ownerKey, destination: R.account(R.destination))
        #expect(reading.checkpoint.height == R.checkpointHeight)
        #expect(Base58.bitcoin.encode(reading.checkpoint.hash) == R.checkpointHash)
        #expect(reading.sender == NEARAccountState(amount: BigUInt(decimal: "53495151373309256233186715")!, storageUsage: 182))
        #expect(reading.accessKey == NEARAccessKeyState(nonce: 217_540_425_000_008, fullAccess: true))
        #expect(reading.destination?.amount == BigUInt(decimal: "2894142213923769499999991")! && reading.destination?.hasContract == false)
        let rules = reading.rules
        #expect(rules.chainID == "mainnet" && rules.gasPrice == BigUInt(100_000_000) && rules.minGasPurchasePrice == BigUInt(1_000_000_000))
        #expect(rules.accountCreationCharge == BigUInt(7) * BigUInt.power(of: 10, 21))
        #expect(rules.storageAmountPerByte == BigUInt.power(of: 10, 19))
        #expect(rules.actionReceipt == NEARActionFee(sendNotSir: 108_059_500_000, execution: 108_059_500_000))
        #expect(rules.transfer == NEARActionFee(sendNotSir: 115_123_062_500, execution: 115_123_062_500))
        #expect(rules.createAccount == NEARActionFee(sendNotSir: 500_000_000_000, execution: 7_200_000_000_000))
        #expect(rules.addFullAccessKey == NEARActionFee(sendNotSir: 101_765_125_000, execution: 101_765_125_000))
        #expect(transport.requests.allSatisfy { $0.method == .post && !$0.url.absoluteString.contains(R.owner) })
    }

    @Test("Conta de destino que nao existe e chave que nao esta na conta viram nil")
    func missingDestinationAndKey() async throws {
        let reader = R.reader(R.transport())
        let other = [UInt8](repeating: 7, count: 32)
        let reading = try await reader.state(owner: R.account(R.owner), publicKey: other, destination: R.account(R.missing))
        #expect(reading.destination == nil)
        #expect(reading.accessKey == nil)
        #expect(reading.sender != nil)
        #expect(try await reader.destination(R.account(R.missing)) == nil)
        #expect(try await reader.destination(R.account(R.destination))?.storageUsage == 182)
    }

    @Test("Um provedor com outro saldo: vale o dos dois que concordam; tres diferentes, recusa")
    func disagreement() async throws {
        let one = R.transport { host, method, params in
            guard host == "a.test", method == "query", R.string(params, "account_id") == R.owner,
                  R.string(params, "request_type") == "view_account" else { return nil }
            return try R.replacing("view_account-dono", "53495151373309256233186715", "63495151373309256233186715")
        }
        let reading = try await R.reader(one).state(owner: R.account(R.owner), publicKey: R.ownerKey, destination: R.account(R.destination))
        #expect(reading.sender?.amount == BigUInt(decimal: "53495151373309256233186715")!)

        let all = R.transport { host, method, params in
            guard method == "query", R.string(params, "request_type") == "view_access_key" else { return nil }
            let nonce = host == "a.test" ? "217540425000009" : host == "b.test" ? "217540425000010" : "217540425000011"
            return try R.replacing("view_access_key-dono", "217540425000008", nonce)
        }
        await #expect(throws: ReaderError.providersDisagree(field: "state")) {
            _ = try await R.reader(all).state(owner: R.account(R.owner), publicKey: R.ownerKey, destination: R.account(R.destination))
        }
    }

    @Test("Resposta de outro bloco e provedor de outra rede nao contam")
    func otherBlockAndNetwork() async throws {
        let stale = R.transport { host, method, params in
            guard host != "c.test", method == "query", R.string(params, "request_type") == "view_account" else { return nil }
            return try R.replacing(R.string(params, "account_id") == R.owner ? "view_account-dono" : "view_account-destino", R.checkpointHash, "11111111111111111111111111111112")
        }
        await #expect(throws: ReaderError.self) {
            _ = try await R.reader(stale).state(owner: R.account(R.owner), publicKey: R.ownerKey, destination: R.account(R.destination))
        }

        let testnet = R.transport { host, method, _ in
            host == "a.test" && method == "status" ? try R.replacing("status", "\"chain_id\":\"mainnet\"", "\"chain_id\":\"testnet\"") : nil
        }
        let transport = testnet
        let reading = try await R.reader(transport).state(owner: R.account(R.owner), publicKey: R.ownerKey, destination: R.account(R.destination))
        #expect(reading.checkpoint.height == R.checkpointHeight)
        #expect(!transport.requests.contains { $0.url.host == "a.test" && FixtureTransport.method(try? StrictJSON.parse($0.body ?? Data())) == "query" })

        let everyone = R.transport { _, method, _ in
            method == "status" ? try R.replacing("status", "EPnLgE7iEq9s7yTkos96M3cWymH5avBAPm3qx3NXqR8H", "FWJ9kR6KFWoyMoNjpLXXGHeuiy7T2ghHFnf9GnBqJhMA") : nil
        }
        await #expect(throws: ReaderError.wrongNetwork) {
            _ = try await R.reader(everyone).state(owner: R.account(R.owner), publicKey: R.ownerKey, destination: R.account(R.destination))
        }
    }

    @Test("O bloco de referencia e o final mais baixo de dois provedores")
    func lowestCheckpoint() async throws {
        let ahead = R.transport { host, method, params in
            guard host == "a.test", method == "block", params["finality"] != nil else { return nil }
            return try R.replacing("block-referencia", "\"height\":217581805", "\"height\":217581811")
        }
        let reading = try await R.reader(ahead).state(owner: R.account(R.owner), publicKey: R.ownerKey, destination: R.account(R.destination))
        #expect(reading.checkpoint.height == R.checkpointHeight)
    }

    @Test("Transmite os mesmos bytes a dois provedores; o hash da resposta e o calculado aqui")
    func broadcast() async throws {
        let transport = R.transport()
        let receipt = try await R.reader(transport).broadcast(R.signed)
        #expect(receipt.id == R.signedID && receipt.acceptedBy.count == 2)
        let sent = transport.requests.filter { FixtureTransport.method(try? StrictJSON.parse($0.body ?? Data())) == "send_tx" }
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { R.string(R.params(try? StrictJSON.parse($0.body ?? Data())), "signed_tx_base64") == R.signedBase64 })

        let invalid = R.transport { _, method, _ in method == "send_tx" ? try R.data("send_tx-assinatura-invalida") : nil }
        await #expect(throws: ReaderError.broadcastRejected(.invalidSignature, code: "invalidSignature")) {
            _ = try await R.reader(invalid).broadcast(R.signed)
        }

        // Bytes que nao sao uma transferencia valida da carteira nunca saem.
        var raw = R.signed.raw
        raw[raw.count - 1] ^= 1
        let tampered = SignedTransaction(chainID: "near", raw: raw, encoded: Data(raw).base64EncodedString(), id: R.signedID)
        await #expect(throws: ReaderError.broadcastMismatch) { _ = try await R.reader(R.transport()).broadcast(tampered) }
    }

    @Test("Acompanhamento: final nos dois, desconhecida sem registro, vencida depois da validade")
    func status() async throws {
        let reader = R.reader(R.transport())
        #expect(try await reader.status(of: R.signedID) == .notFound)
        _ = try await reader.broadcast(R.signed)
        #expect(try await reader.status(of: R.signedID) == .confirmed(block: nil, confirmations: nil))

        let unknown = "4Pe8YAruRSTPphJ6aiMQMLyfqCQzo8d5H7XLbeyMKsEj"
        await reader.track(unknown, signer: R.owner, height: R.checkpointHeight - NEARRules.validityBlocks - 10)
        #expect(try await reader.status(of: unknown) == .failed(reason: "expired"))
        await reader.track(unknown, signer: R.owner, height: R.checkpointHeight - 10)
        #expect(try await reader.status(of: unknown) == .notFound)

        let pending = R.reader(R.transport { host, method, _ in
            host == "a.test" && method == "tx" ? try R.replacing("tx-final", "\"final_execution_status\":\"FINAL\"", "\"final_execution_status\":\"INCLUDED\"") : nil
        })
        await pending.track(R.signedID, signer: R.owner, height: R.checkpointHeight)
        #expect(try await pending.status(of: R.signedID) == .pending)
    }

    @Test("Historico: envios com a taxa inteira, recebimentos por recibo, a conta so no corpo")
    func history() async throws {
        let transport = R.transport()
        let page = try await R.reader(transport).history(owner: R.owner)
        #expect(transport.requests.allSatisfy { $0.method == .post && !$0.url.absoluteString.contains(R.owner) })
        let sent = try #require(page.items.first { $0.hash == R.signedID })
        #expect(sent.direction == .sent && sent.counterparty == "neartokenbot.near" && sent.status == .confirmed)
        #expect(sent.amount == BigUInt(decimal: "143579727109398725627588")!)
        #expect(sent.fee == BigUInt(decimal: "44636512500000000000")!)
        // A conta nasceu de um envio de 35,4 NEAR de outra conta implicita.
        let first = try #require(page.items.first { $0.direction == .received && $0.amount == BigUInt(decimal: "35405989840000000000000000")! })
        #expect(first.counterparty == "e292f41cccbf8500ccc64e9a767333d73b0e7360abba6c9008f280f9b3995982" && first.fee == nil)
        // Saque de wNEAR: o contrato manda a transferencia para a conta.
        #expect(page.items.contains { $0.direction == .received && $0.counterparty == "wrap.near" })
        #expect(page.items.filter { $0.direction == .sent }.count == 4)
        #expect(page.items.filter { $0.direction == .other }.count == 4)
        #expect(page.items.allSatisfy { $0.explorerURL?.host == "nearblocks.io" && $0.chainID == "near" })
    }

    @Test("Saldo da tela: o livre, e conta que nao existe")
    func displayBalance() async throws {
        let reader = R.reader(R.transport())
        let balance = try await reader.displayBalance(owner: R.owner)
        #expect(balance.accountExists && balance.holdings.first?.amount == BigUInt(decimal: "53495151373309256233186715")!)
        let empty = try await reader.displayBalance(owner: "b8d5df25047841365008f30fb6b30dd820e9a84d869f05623d114e96831f2fbf")
        #expect(!empty.accountExists && empty.holdings.first?.amount == 0)
    }

    @Test("Leitura estrita: permissao de contrato, campo faltando, erro do no sem texto")
    func strictParsing() throws {
        let functionCall = try StrictJSON.parse(Data("""
        {"block_hash":"\(R.checkpointHash)","block_height":1,"nonce":5,"permission":{"FunctionCall":{"allowance":null,"method_names":[],"receiver_id":"x.near"}}}
        """.utf8))
        #expect(try NEARReader.parseAccessKey(functionCall, at: R.checkpointHash) == NEARAccessKeyState(nonce: 5, fullAccess: false))
        let noAmount = try StrictJSON.parse(Data("{\"block_hash\":\"\(R.checkpointHash)\",\"locked\":\"0\",\"code_hash\":\"11111111111111111111111111111111\",\"storage_usage\":1}".utf8))
        #expect(throws: ReaderError.malformed(field: "view_account.amount")) { try NEARReader.parseAccount(noAmount, at: R.checkpointHash) }
        #expect(NEARReader.rejection(try StrictJSON.parse(Data("{\"TxExecutionError\":{\"InvalidTxError\":{\"InvalidNonce\":{\"ak_nonce\":5,\"tx_nonce\":5}}}}".utf8))) == .nonceTooLow)
        #expect(NEARReader.rejection(try StrictJSON.parse(Data("{\"TxExecutionError\":{\"InvalidTxError\":{\"NotEnoughBalance\":{}}}}".utf8))) == .insufficientFunds)
        #expect(NEARReader.rejection(try StrictJSON.parse(Data("{\"TxExecutionError\":{\"InvalidTxError\":\"Expired\"}}".utf8))) == .expired)
        #expect(throws: NEARReader.RPCFailure.self) { try NEARReader.result(try R.data("view_account-inexistente"), method: "query") }
    }
}
