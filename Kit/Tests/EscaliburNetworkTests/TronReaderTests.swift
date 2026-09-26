import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Leitor Tron contra respostas gravadas (Fixtures/leitores/tron), sem rede. Gravadas
/// em 25/09/2026 na PublicNode e na TronGrid.
@Suite("Leitor Tron com respostas gravadas")
struct TronReaderTests {
    static let owner = TronAddress(base58: "TNXoiAJ3dct8Fjg4M9fkLFh9S2v9TXc32G")!
    static let destination = "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
    static let shared = TronAddress(base58: "TNPeeaaFB7K9cmo4uQpcU32zGK8G1NYqeL")!
    static let unfunded = "TDJD7vKogBsFECgWtEmN4RMKx3vNzCkP6B"

    static func blockTime() throws -> Date {
        let json = try ReaderFixtures.json("tron", "getnowblock")
        let millis = try json.field("block_header", "$").field("raw_data", "$").field("timestamp", "$").uint64("$")
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }

    /// Responde pelo caminho `/wallet/...`; getaccount e getcontract pelo endereco pedido.
    static func transport(perHost: [String: [String: Data]] = [:]) throws -> FixtureTransport {
        let paths: [String: Data] = [
            "/wallet/getnowblock": try ReaderFixtures.data("tron", "getnowblock"),
            "/wallet/getaccountresource": try ReaderFixtures.data("tron", "getaccountresource-dono"),
            "/wallet/getchainparameters": try ReaderFixtures.data("tron", "getchainparameters"),
            "/walletsolidity/gettransactioninfobyid": try ReaderFixtures.data("tron", "gettransactioninfobyid-usdt"),
            "/wallet/gettransactioninfobyid": try ReaderFixtures.data("tron", "gettransactioninfobyid-usdt"),
        ]
        let accounts: [String: Data] = [
            owner.base58: try ReaderFixtures.data("tron", "getaccount-dono"),
            destination: try ReaderFixtures.data("tron", "getaccount-destino"),
            shared.base58: try ReaderFixtures.data("tron", "getaccount-controle-dividido"),
            unfunded: try ReaderFixtures.data("tron", "getaccount-inexistente"),
        ]
        let contracts: [String: Data] = [
            destination: try ReaderFixtures.data("tron", "getcontract-conta"),
            unfunded: try ReaderFixtures.data("tron", "getcontract-conta"),
            "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t": try ReaderFixtures.data("tron", "getcontract-usdt"),
        ]
        let balanceOf = try ReaderFixtures.data("tron", "balanceOf-dono")
        let transfer = try ReaderFixtures.data("tron", "transfer-estimativa")
        return FixtureTransport([{ request, body in
            let path = request.url.path
            if let host = request.url.host, let special = perHost[host]?[path] { return special }
            if let data = paths[path] { return data }
            switch path {
            case "/wallet/getaccount":
                return (try? body?.field("address", "b").string("b")).flatMap { accounts[$0] }
            case "/wallet/getcontract":
                return (try? body?.field("value", "b").string("b")).flatMap { contracts[$0] }
            case "/wallet/triggerconstantcontract":
                let selector = try? body?.field("function_selector", "b").string("b")
                return selector == "balanceOf(address)" ? balanceOf : transfer
            default:
                return nil
            }
        }])
    }

    static func reader(_ transport: FixtureTransport) -> TronReader {
        TronReader(transport: transport, providers: testProviders("publicnode", "trongrid"))
    }

    @Test("Estado do envio de USDT montado das respostas gravadas e aceito pelo planejador")
    func usdtState() async throws {
        let transport = try Self.transport()
        let state = try await Self.reader(transport).networkState(owner: Self.owner, intent: .usdt(to: Self.destination, amount: 1_000_000), now: try Self.blockTime())
        #expect(state.ownerControl.verdict == .soleOwner)
        #expect(state.parameters == TronChainParameters(energyPrice: 100, bandwidthPrice: 1_000, createAccountFee: 1_000_000, createAccountBandwidthFee: 100_000, memoFee: 1_000_000))
        #expect(state.usdtEnergyEstimate == 64_285)
        #expect(state.destinationActivated)
        #expect(state.destinationIsContract == false)
        #expect(state.destinationHoldsUSDT == true)
        #expect(!state.trxBalance.isZero)
        // Todo pedido e POST com o endereco no corpo.
        #expect(transport.requests.allSatisfy { $0.method == .post && !$0.url.absoluteString.contains(Self.owner.base58) })

        let owner = try TronOwner(path: DerivationPath("m/44'/195'/0'/0/0")!, publicKey: TronReaderLiveTests.ownerKey)
        let plan = try TronPlanner.planSendUSDT(walletID: UUID(), owner: owner, to: Self.destination, amount: 1_000_000, state: state, now: try Self.blockTime())
        #expect(plan.transactions.count == 1)
    }

    @Test("Bloco velho demais em relacao ao relogio e recusado")
    func staleBlock() throws {
        let json = try ReaderFixtures.json("tron", "getnowblock")
        let block = try TronReader.parseBlock(json, now: try Self.blockTime())
        #expect(block.refBlockBytes.count == 2)
        #expect(throws: ReaderError.implausibleValue(field: "getnowblock.block_header.raw_data.timestamp")) {
            _ = try TronReader.parseBlock(json, now: try Self.blockTime().addingTimeInterval(7_200))
        }
    }

    @Test("Parametros da rede: so os usados sao lidos, mesmo com parametro negativo na lista")
    func chainParameters() throws {
        let json = try ReaderFixtures.json("tron", "getchainparameters")
        let parameters = try TronReader.parseChainParameters(json)
        #expect(parameters.energyPrice == 100)
        guard case .object(var root) = json, case .array(var list)? = root["chainParameter"] else { return }
        list.removeAll { (try? $0.field("key", "k").string("k")) == "getEnergyFee" }
        root["chainParameter"] = .array(list)
        #expect(throws: ReaderError.malformed(field: "getchainparameters.getEnergyFee")) { _ = try TronReader.parseChainParameters(.object(root)) }
    }

    @Test("Recursos: restante do dia, campos ausentes do proto3 sao zero")
    func resources() throws {
        let resources = try TronReader.parseResources(try ReaderFixtures.json("tron", "getaccountresource-dono"))
        #expect(resources.freeBandwidth <= 600)
        #expect(try TronReader.parseResources(.object([:])) == TronAccountResources(freeBandwidth: 0, stakedBandwidth: 0, energy: 0))
        #expect(throws: ReaderError.self) { _ = try TronReader.parseResources(.object(["freeNetLimit": .string("600")])) }
    }

    @Test("Permissoes: conta com dono dividido e comprometida; um provedor ver basta")
    func permissions() async throws {
        let control = try await Self.reader(try Self.transport()).ownerControl(owner: Self.shared)
        #expect(control.isCompromised)
        let clean = try TronReader.parseOwnerAccount(try ReaderFixtures.data("tron", "getaccount-dono"), owner: Self.owner)
        let dirty = try TronReader.parseOwnerAccount(try ReaderFixtures.data("tron", "getaccount-controle-dividido"), owner: Self.shared)
        #expect(clean.control.verdict == .soleOwner)
        // Resposta de outra conta: troca de dado, erro.
        #expect(throws: ReaderError.responseMismatch(field: "getaccount.address")) {
            _ = try TronReader.parseOwnerAccount(try ReaderFixtures.data("tron", "getaccount-controle-dividido"), owner: Self.owner)
        }
        #expect(try TronReader.combine([clean, dirty]).control.isCompromised)
    }

    @Test("Conta inexistente: `{}` e nao ativada")
    func unfunded() async throws {
        let transport = try Self.transport()
        let unfunded = try #require(TronAddress(base58: Self.unfunded))
        let reading = try TronReader.parseOwnerAccount(try ReaderFixtures.data("tron", "getaccount-inexistente"), owner: unfunded)
        #expect(reading.control.verdict == .notActivated)
        #expect(reading.trx == 0)
        let state = try await Self.reader(transport).networkState(owner: Self.owner, intent: .trx(to: Self.unfunded, amount: 1_000_000), now: try Self.blockTime())
        #expect(state.destinationActivated == false)
        #expect(state.usdtEnergyEstimate == nil)
    }

    @Test("triggerconstantcontract: saldo, energy e revert")
    func constantCalls() throws {
        let (word, _) = try TronReader.parseConstantCall(try ReaderFixtures.json("tron", "balanceOf-dono"), field: "balanceOf")
        #expect(TRC20.decodeUint256(word) != nil)
        let (_, energy) = try TronReader.parseConstantCall(try ReaderFixtures.json("tron", "transfer-estimativa"), field: "transfer")
        #expect(energy == 64_285)
        #expect(throws: ReaderError.executionReverted) {
            _ = try TronReader.parseConstantCall(try ReaderFixtures.json("tron", "transfer-revert"), field: "transfer")
        }
    }

    @Test("broadcasthex: erro gravado vira recusa; sucesso exige o mesmo txid")
    func broadcastResponses() throws {
        let id = String(repeating: "ab", count: 32)
        #expect(throws: ReaderError.broadcastRejected(.other, code: "CONTRACT_VALIDATE_ERROR")) {
            _ = try TronReader.parseBroadcast(try ReaderFixtures.json("tron", "broadcasthex-erro"), expectedID: id)
        }
        #expect(try TronReader.parseBroadcast(.object(["result": .bool(true), "txid": .string(id)]), expectedID: id) == id)
        #expect(throws: ReaderError.broadcastMismatch) {
            _ = try TronReader.parseBroadcast(.object(["result": .bool(true), "txid": .string(String(repeating: "cd", count: 32))]), expectedID: id)
        }
        #expect(throws: ReaderError.broadcastRejected(.alreadyKnown, code: "DUP_TRANSACTION_ERROR")) {
            _ = try TronReader.parseBroadcast(.object(["result": .bool(false), "code": .string("DUP_TRANSACTION_ERROR")]), expectedID: id)
        }
    }

    /// A transacao assinada gravada (TronGrid: `raw_data_hex` + assinatura) montada como a
    /// `Transaction` protobuf que `broadcasthex` recebe: o txID e o SHA-256 do raw_data.
    @Test("Transmissao: raw_data extraido do protobuf da o txID; bytes trocados sao recusados")
    func broadcast() async throws {
        let recorded = try ReaderFixtures.json("tron", "transacao-assinada")
        let rawData = try #require(Hex.decode(try recorded.field("raw_data_hex", "$").string("$")))
        let signature = try #require(Hex.decode(try recorded.field("signature", "$").array("$")[0].string("$")))
        let txID = try recorded.field("txID", "$").string("$")
        func varint(_ value: Int) -> [UInt8] {
            var v = value, out: [UInt8] = []
            while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
            return out + [UInt8(v)]
        }
        let transaction = [0x0A] + varint(rawData.count) + rawData + [0x12] + varint(signature.count) + signature
        #expect(TronReader.rawData(ofTransaction: transaction) == rawData)
        #expect(Hex.encode(Hash.sha256(rawData)) == txID)

        let accepted = StrictJSON.object(["result": .bool(true), "txid": .string(txID)]).serialized
        let transport = FixtureTransport([{ request, _ in request.url.path == "/wallet/broadcasthex" ? accepted : nil }])
        let signed = SignedTransaction(chainID: "tron", raw: transaction, encoded: Hex.encode(transaction), id: txID)
        let receipt = try await Self.reader(transport).broadcast(signed)
        #expect(Set(receipt.acceptedBy) == ["publicnode", "trongrid"])
        let tampered = SignedTransaction(chainID: "tron", raw: transaction, encoded: Hex.encode(transaction), id: String(repeating: "00", count: 32))
        await #expect(throws: ReaderError.broadcastMismatch) { _ = try await Self.reader(transport).broadcast(tampered) }
    }

    @Test("gettransactioninfobyid: confirmado nos dois nos solidificados; vazio; falha")
    func status() async throws {
        let id = "6484590d488c8c312525f491137e5f95f5d3a9cd05235474a058c2fe29824982"
        #expect(try await Self.reader(try Self.transport()).status(of: id) == .confirmed(block: 85_577_993, confirmations: nil))
        #expect(try TronReader.parseTransactionInfo(try ReaderFixtures.json("tron", "gettransactioninfobyid-vazio"), id: id) == nil)
        let empty = try ReaderFixtures.data("tron", "gettransactioninfobyid-vazio")
        let halfway = try Self.transport(perHost: ["trongrid.test": ["/walletsolidity/gettransactioninfobyid": empty]])
        #expect(try await Self.reader(halfway).status(of: id) == .pending)
        // O bloco solidificado dos dois nos e o gravado; a expiracao conta da hora dele.
        let solid = try ReaderFixtures.data("tron", "getnowblock")
        let nowhere = try Self.transport(perHost: [
            "trongrid.test": ["/walletsolidity/gettransactioninfobyid": empty, "/wallet/gettransactioninfobyid": empty, "/walletsolidity/getnowblock": solid],
            "publicnode.test": ["/walletsolidity/gettransactioninfobyid": empty, "/wallet/gettransactioninfobyid": empty, "/walletsolidity/getnowblock": solid],
        ])
        let blockTime = try Self.blockTime()
        #expect(try await Self.reader(nowhere).solidifiedTime() == blockTime)
        #expect(try await Self.reader(nowhere).status(of: id, expiresAt: blockTime.addingTimeInterval(-300)) == .failed(reason: "expired"))
        #expect(try await Self.reader(nowhere).status(of: id, expiresAt: blockTime.addingTimeInterval(-60)) == .notFound)
        guard case .object(var info) = try ReaderFixtures.json("tron", "gettransactioninfobyid-usdt"), case .object(var receipt)? = info["receipt"] else { return }
        receipt["result"] = .string("OUT_OF_ENERGY")
        info["receipt"] = .object(receipt)
        #expect(try TronReader.parseTransactionInfo(.object(info), id: id) == .failed(reason: "OUT_OF_ENERGY"))
        #expect(throws: ReaderError.responseMismatch(field: "gettransactioninfobyid.id")) {
            _ = try TronReader.parseTransactionInfo(try ReaderFixtures.json("tron", "gettransactioninfobyid-usdt"), id: String(repeating: "0", count: 64))
        }
    }

    @Test("Historico da TronGrid gravado: USDT pelo contrato compilado, TRC-10 e po escondidos")
    func history() throws {
        let page = try TronReader.parseHistory(
            owner: Self.shared,
            transactions: ReaderFixtures.json("tron", "trongrid-transactions"),
            trc20: ReaderFixtures.json("tron", "trongrid-trc20")
        )
        let usdt = page.items.filter { $0.asset.symbol == "USDT" }
        #expect(usdt.count == 6)
        #expect(usdt.filter { $0.direction == .sent }.count == 2)
        #expect(usdt.filter { $0.direction == .received }.allSatisfy { $0.fee == nil })
        // 1 sun de TRX (po) e o TRC-10 recebido.
        #expect(page.suspicious.dust == 1)
        #expect(page.suspicious.unknownAsset == 1)
        #expect(page.items.allSatisfy { $0.explorerURL?.host == "tronscan.org" })
    }
}
