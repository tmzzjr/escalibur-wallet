import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Respostas da Polkadot Asset Hub gravadas em 28/09/2026 (Fixtures/leitores/polkadot,
/// `gravar.mjs`), todas no bloco finalizado 21.173.079, do RPC da Parity; o bloco
/// 21.172.670 com duas transferencias reais, o sidecar do mesmo bloco (reduzido a metodo,
/// hash e resultado de cada extrinsic) e o historico do indexador da Nova. Os provedores
/// de mentira respondem com o gravado, e cada teste troca so o que precisa.
enum PolkadotRecorded {
    static let owner = "1626DFYAYv5UGwSy6dz3yiGExMxxik68RqQbusnb4MCHEY6e"
    static let empty = "13nN6BGAoJwd7Nw1XxeBCx5YcBXuYnL94Mh7i3xBprqVSsFk"
    static let checkpointNumber: UInt64 = 21_173_079
    static let checkpointHash = "0xdbe81ae3b8fc1fdfad4a503d791799bc594c1fb76aadaf65038406b956ddc524"
    static let transferBlock: UInt64 = 21_172_670
    static let transferBlockHash = "0x5f95fcdd9ef0619b32fc083cb0b534fe4c35487a279985a0c66c3715a0202952"
    /// A transferencia real do dono no bloco 21.172.670, posicao 2 (Ed25519, era 9b17).
    static let signedHex = "45028400de01f487837eae7557b87b856c1750bc21effbf60042a79cd87cb54b0a11bb3e002cd8da9380ba775111b8bc48fa18acb3029954441276e7160708c18e4fd0819d18f900bdfc3857f1a892ea78a8fd33f77ef11f67adf81381b8cd8fa6c667cd0d9b1791070000000a03008b67634b395e5f8220231e7a837020a2fec7b93c580b539d2f8bc07f2e1eba8b36bea35f"
    static let signedID = "0x7b0c234cbbf38694fd430566f28f43f7e73a70188da7d214ac7d454992da3aa8"
    static let providers = testProviders("a", "b", "c")
    static let sidecar = URL(string: "https://sidecar.test")!
    static let history = URL(string: "https://historico.test")!

    static func data(_ name: String) throws -> Data { try ReaderFixtures.data("polkadot", name) }

    static func address(_ text: String) -> PolkadotAddress {
        guard case .success(let address) = PolkadotAddress.parse(text) else { fatalError("endereco do teste") }
        return address
    }

    static var signed: SignedTransaction {
        let raw = [UInt8](hex: signedHex)!
        return SignedTransaction(chainID: "polkadot", raw: raw, encoded: Hex.encode(raw, prefix: true), id: signedID)
    }

    /// `override` responde antes do gravado: host do provedor, metodo e parametros.
    static func transport(
        first: [FixtureTransport.Rule] = [], override: (@Sendable (String, String, [StrictJSON]) throws -> Data?)? = nil
    ) -> FixtureTransport {
        FixtureTransport(first + [
            { request, body in
                guard let host = request.url.host, host.hasSuffix(".test"), host != "sidecar.test", host != "historico.test",
                      let method = FixtureTransport.method(body) else { return nil }
                let params = FixtureTransport.params(body)
                if let custom = try override?(host, method, params) { return custom }
                switch method {
                case "chain_getFinalizedHead": return try data("finalizedHead")
                case "chain_getHeader": return try data("header")
                case "chain_getBlockHash":
                    guard case .number(let text)? = params.first, let number = UInt64(text) else { return nil }
                    switch number {
                    case 0: return try data("blockHash-genese")
                    case checkpointNumber: return try data("blockHash-referencia")
                    case transferBlock: return try data("blockHash-21172670")
                    default: return rpcResult("\"0x\(String(repeating: "0", count: 48))\(String(format: "%016llx", number))\"")
                    }
                case "state_getRuntimeVersion": return try data("runtimeVersion")
                case "state_getStorage":
                    guard case .string(let key)? = params.first else { return nil }
                    return key.hasSuffix(Hex.encode(address(owner).accountID)) ? try data("storage-dono") : try data("storage-vazia")
                case "state_call": return try data("query_info")
                case "chain_getBlock":
                    guard case .string(let hash)? = params.first else { return nil }
                    return hash == transferBlockHash ? try data("block-21172670") : rpcResult("{\"block\":{\"header\":{},\"extrinsics\":[]}}")
                case "author_submitExtrinsic":
                    guard case .string(let hex)? = params.first, let raw = [UInt8](hex: hex) else { return nil }
                    return rpcResult("\"\(PolkadotSignedExtrinsic.id(of: raw))\"")
                default: return nil
                }
            },
            { request, body in
                switch request.url.host {
                case "sidecar.test": return try data("sidecar-21172670")
                case "historico.test":
                    guard case .object(let fields)? = body, case .string(let query)? = fields["query"] else { return nil }
                    return query.contains("_metadata") ? try data("historico-metadados") : try data("historico-dono")
                default: return nil
                }
            },
        ])
    }

    static func reader(_ transport: FixtureTransport) -> PolkadotReader {
        PolkadotReader(transport: transport, providers: providers, sidecar: sidecar, history: history, pacing: 0)
    }
}

@Suite("Polkadot: leitor com respostas gravadas")
struct PolkadotReaderTests {
    @Test("Estado no bloco finalizado, em dois provedores concordando, com o endereco so no corpo")
    func accountState() async throws {
        let transport = PolkadotRecorded.transport()
        let reading = try await PolkadotRecorded.reader(transport).accountState(
            owner: PolkadotRecorded.address(PolkadotRecorded.owner), destination: PolkadotRecorded.address(PolkadotRecorded.empty)
        )
        #expect(reading.checkpoint.number == PolkadotRecorded.checkpointNumber)
        #expect(Hex.encode(reading.checkpoint.hash, prefix: true) == PolkadotRecorded.checkpointHash)
        #expect(reading.runtime == PolkadotRuntimeState(specName: "statemint", specVersion: 2_005_000, transactionVersion: 15, genesisHash: PolkadotRuntime.genesisHash))
        #expect(reading.sender.nonce == 485 && reading.sender.free == BigUInt(10_401_141_645) && reading.sender.reserved == BigUInt(200_410_000_000))
        #expect(reading.destination == .empty)
        #expect(transport.requests.allSatisfy { !$0.url.absoluteString.contains(PolkadotRecorded.owner) })
        // A chave de armazenamento do dono: prefixo de System.Account, BLAKE2b-128 e a conta.
        #expect(PolkadotReader.accountKey(PolkadotRecorded.address(PolkadotRecorded.owner)).hasPrefix("0x26aa394eea5630e07c48ae0c9558cef7b99d880ec681799c0cf30e8886371da9"))
    }

    @Test("Um provedor com outra conta: vale a dos dois que concordam; tres diferentes, recusa")
    func stateDisagreement() async throws {
        let changed = rpcResult("\"0xe6010000\(String(repeating: "0", count: 152))\"")
        let one = PolkadotRecorded.transport { host, method, params in
            host == "a.test" && method == "state_getStorage" ? changed : nil
        }
        let reading = try await PolkadotRecorded.reader(one).accountState(
            owner: PolkadotRecorded.address(PolkadotRecorded.owner), destination: PolkadotRecorded.address(PolkadotRecorded.empty)
        )
        #expect(reading.sender.nonce == 485)

        let all = PolkadotRecorded.transport { host, method, _ in
            guard method == "state_getStorage" else { return nil }
            let nonce = host == "a.test" ? "e6" : host == "b.test" ? "e7" : "e8"
            return rpcResult("\"0x\(nonce)010000\(String(repeating: "0", count: 152))\"")
        }
        await #expect(throws: ReaderError.providersDisagree(field: "state")) {
            _ = try await PolkadotRecorded.reader(all).accountState(
                owner: PolkadotRecorded.address(PolkadotRecorded.owner), destination: PolkadotRecorded.address(PolkadotRecorded.empty)
            )
        }
    }

    @Test("Provedor de outra rede (genese diferente) nao conta")
    func wrongGenesis() async throws {
        let kusama = rpcResult("\"0x48239ef607d7928874027a43a67689209727dfb3d3dc5e5b03a39bdc2eda771a\"")
        let transport = PolkadotRecorded.transport { _, method, params in
            guard method == "chain_getBlockHash", case .number("0")? = params.first else { return nil }
            return kusama
        }
        await #expect(throws: ReaderError.wrongNetwork) {
            _ = try await PolkadotRecorded.reader(transport).accountState(
                owner: PolkadotRecorded.address(PolkadotRecorded.owner), destination: PolkadotRecorded.address(PolkadotRecorded.empty)
            )
        }
    }

    @Test("Bloco de referencia: o finalizado mais baixo dos dois")
    func checkpointIsLowest() async throws {
        let transport = PolkadotRecorded.transport { host, method, _ in
            guard host == "b.test", method == "chain_getHeader" else { return nil }
            let header = String(decoding: try PolkadotRecorded.data("header"), as: UTF8.self).replacingOccurrences(of: "0x1431357", with: "0x1431359")
            return Data(header.utf8)
        }
        let checkpoint = try await PolkadotRecorded.reader(transport).checkpoint()
        #expect(checkpoint.number == PolkadotRecorded.checkpointNumber)
    }

    @Test("Taxa da transacao exata, igual em dois; diferente ou recusada pelo no, sem taxa")
    func fee() async throws {
        let checkpoint = PolkadotCheckpoint(number: PolkadotRecorded.checkpointNumber, hash: [UInt8](hex: PolkadotRecorded.checkpointHash)!)
        let raw = [UInt8](hex: PolkadotRecorded.signedHex)!
        #expect(try await PolkadotRecorded.reader(PolkadotRecorded.transport()).fee(for: raw, at: checkpoint) == BigUInt(8_808_355))

        let differing = PolkadotRecorded.transport { host, method, _ in
            guard method == "state_call" else { return nil }
            let fee = host == "a.test" ? "a3" : host == "b.test" ? "a4" : "a5"
            return rpcResult("\"0xe2bee45319d100\(fee)678600000000000000000000000000\"")
        }
        await #expect(throws: ReaderError.providersDisagree(field: "fee")) {
            _ = try await PolkadotRecorded.reader(differing).fee(for: raw, at: checkpoint)
        }
        let refused = PolkadotRecorded.transport { _, method, _ in
            method == "state_call" ? rpcError(code: -32000, message: "Client error: Execution failed") : nil
        }
        await #expect(throws: ReaderError.providerError(code: "-32000")) {
            _ = try await PolkadotRecorded.reader(refused).fee(for: raw, at: checkpoint)
        }
        #expect(throws: ReaderError.malformed(field: "query_info")) { try PolkadotReader.parsePartialFee([UInt8](hex: "e2bee45319d100a367860000000000000000000000000000")!) }
    }

    @Test("Transmissao: o hash do no tem de ser o calculado; a recusa e classificada")
    func broadcast() async throws {
        let receipt = try await PolkadotRecorded.reader(PolkadotRecorded.transport()).broadcast(PolkadotRecorded.signed)
        #expect(receipt.id == PolkadotRecorded.signedID && receipt.acceptedBy == ["a", "b"])

        let other = PolkadotRecorded.transport { _, method, _ in
            method == "author_submitExtrinsic" ? rpcResult("\"0x\(String(repeating: "ab", count: 32))\"") : nil
        }
        await #expect(throws: ReaderError.broadcastMismatch) { _ = try await PolkadotRecorded.reader(other).broadcast(PolkadotRecorded.signed) }

        let bad = PolkadotRecorded.transport { _, method, _ in
            guard method == "author_submitExtrinsic" else { return nil }
            return Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":1010,\"message\":\"Invalid Transaction\",\"data\":\"Transaction has a bad signature\"}}".utf8)
        }
        await #expect(throws: ReaderError.broadcastRejected(.invalidSignature, code: "1010")) {
            _ = try await PolkadotRecorded.reader(bad).broadcast(PolkadotRecorded.signed)
        }
        #expect(PolkadotReader.rejection(code: 1010, text: "Invalid Transaction Inability to pay some fees") == .insufficientFunds)
        #expect(PolkadotReader.rejection(code: 1010, text: "Invalid Transaction Transaction is outdated") == .nonceTooLow)
        #expect(PolkadotReader.rejection(code: 1010, text: "Invalid Transaction Transaction has an ancient birth block") == .expired)
        #expect(PolkadotReader.rejection(code: 1013, text: "Transaction Already Imported") == .alreadyKnown)

        // Bytes que nao sao do formato da carteira nem saem.
        var tampered = PolkadotRecorded.signed.raw
        tampered[tampered.count - 1] ^= 1
        let foreign = SignedTransaction(chainID: "polkadot", raw: tampered, encoded: Hex.encode(tampered, prefix: true), id: PolkadotRecorded.signedID)
        await #expect(throws: ReaderError.broadcastMismatch) { _ = try await PolkadotRecorded.reader(PolkadotRecorded.transport()).broadcast(foreign) }
    }

    @Test("Acompanhamento: acha a transacao nos blocos finalizados e le o resultado no sidecar")
    func statusConfirmed() async throws {
        let reader = PolkadotRecorded.reader(PolkadotRecorded.transport())
        _ = try await reader.broadcast(PolkadotRecorded.signed)
        // Era 9b17: periodo 4096, nascimento no bloco 21.172.601, 69 blocos antes da
        // transferencia; o acompanhamento percorre 40 blocos por consulta.
        #expect(PolkadotReader.birth(era: try PolkadotSignedExtrinsic.parse(PolkadotRecorded.signed).era, finalized: PolkadotRecorded.checkpointNumber) == 21_172_601)
        #expect(try await reader.status(of: PolkadotRecorded.signedID) == .pending)
        #expect(try await reader.status(of: PolkadotRecorded.signedID) == .confirmed(block: PolkadotRecorded.transferBlock, confirmations: nil))
        #expect(try await reader.status(of: "0x" + String(repeating: "cd", count: 32)) == .notFound)
    }

    @Test("Acompanhamento: fora da era sem aparecer, venceu; o sidecar diz falha, falhou")
    func statusExpiredAndFailed() async throws {
        let reader = PolkadotRecorded.reader(PolkadotRecorded.transport())
        let missing = "0x" + String(repeating: "cd", count: 32)
        await reader.track(missing, birth: PolkadotRecorded.checkpointNumber - 70, death: PolkadotRecorded.checkpointNumber - 40)
        #expect(try await reader.status(of: missing) == .failed(reason: "expired"))

        let recorded = String(decoding: try PolkadotRecorded.data("sidecar-21172670"), as: UTF8.self)
        let flipped = Data(recorded.replacingOccurrences(
            of: "\"hash\":\"\(PolkadotRecorded.signedID)\",\"success\":true", with: "\"hash\":\"\(PolkadotRecorded.signedID)\",\"success\":false"
        ).utf8)
        #expect(flipped != Data(recorded.utf8))
        let failing = PolkadotRecorded.transport(first: [{ request, _ in request.url.host == "sidecar.test" ? flipped : nil }])
        let reader2 = PolkadotRecorded.reader(failing)
        await reader2.track(PolkadotRecorded.signedID, birth: PolkadotRecorded.transferBlock - 1, death: PolkadotRecorded.transferBlock + 100)
        #expect(try await reader2.status(of: PolkadotRecorded.signedID) == .failed(reason: "dispatch"))
        #expect(throws: ReaderError.responseMismatch(field: "sidecar.hash")) {
            try PolkadotReader.parseSidecarSuccess(Data(recorded.utf8), index: 3, id: PolkadotRecorded.signedID)
        }
    }

    @Test("Historico do indexador da Nova: enviado com taxa, recebido sem, genese conferida")
    func history() async throws {
        let page = try await PolkadotRecorded.reader(PolkadotRecorded.transport()).history(owner: PolkadotRecorded.owner)
        #expect(page.items.count == 30 && page.chainID == "polkadot")
        let sent = try #require(page.items.first)
        #expect(sent.direction == .sent && sent.amount == BigUInt(401_141_645) && sent.fee == BigUInt(8_858_355))
        #expect(sent.counterparty == "149nNNvTDsJdvCBnEh83EG9j89GAk97a3ucoivz4RyqZGJJ3" && sent.status == .confirmed)
        #expect(sent.hash == PolkadotRecorded.signedID)
        #expect(sent.explorerURL?.absoluteString == "https://assethub-polkadot.subscan.io/extrinsic/\(PolkadotRecorded.signedID)")
        let received = page.items[1]
        #expect(received.direction == .received && received.fee == nil && received.amount == BigUInt(410_000_000))

        let kusama = Data("{\"data\":{\"_metadata\":{\"genesisHash\":\"0x48239ef607d7928874027a43a67689209727dfb3d3dc5e5b03a39bdc2eda771a\"}}}".utf8)
        let wrong = PolkadotRecorded.transport(first: [{ request, body in
            guard request.url.host == "historico.test", case .object(let fields)? = body, case .string(let query)? = fields["query"],
                  query.contains("_metadata") else { return nil }
            return kusama
        }])
        await #expect(throws: ReaderError.wrongNetwork) { _ = try await PolkadotRecorded.reader(wrong).history(owner: PolkadotRecorded.owner) }
    }

    @Test("Saldo da tela: livre mais reservado")
    func displayBalance() async throws {
        let balance = try await PolkadotRecorded.reader(PolkadotRecorded.transport()).displayBalance(owner: PolkadotRecorded.owner)
        #expect(balance.holdings == [Holding(asset: .native(.polkadot), amount: BigUInt(10_401_141_645) + BigUInt(200_410_000_000))])
        #expect(balance.accountExists)
    }
}
