import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Leitor TON contra respostas gravadas (Fixtures/leitores/ton), sem rede. Gravadas em
/// 25/09/2026 na toncenter (API v2 e v3) e na tonapi.
@Suite("Leitor TON com respostas gravadas")
struct TONReaderTests {
    static let wallet = try! TONWallet(publicKey: TONReaderLiveTests.recordedOwnerKey, version: .v4r2)
    static let destination = "0:12d12a693dbeff8e278fb409f2a1fc5896403f878f442a646e3613b85c13eca2"  // V4R2 ativa
    static let uninitialized = "0:1111111111111111111111111111111111111111111111111111111111111111"
    /// A carteira jetton de USDT do dono das gravacoes.
    static let ownerJettonWallet = "0:16e07181d7abc5e87ef9a4a696dad8a4b2199f46165f7e21a0dd1935aa393948"

    /// toncenter v2 por `method` (e conta, no getAddressInformation); tonapi e toncenter v3
    /// pelo caminho. Na tonapi, a conta do dono e a gravada, e as outras dao 404 (conta
    /// que nunca existiu), como a toncenter as da por nao inicializadas. `overrides` troca
    /// por chave "host path|method".
    static func transport(overrides: [String: Data] = [:], before: [FixtureTransport.Rule] = []) throws -> FixtureTransport {
        let owner = try ReaderFixtures.data("ton", "getAddressInformation-dono")
        let uninit = try ReaderFixtures.data("ton", "getAddressInformation-nao-inicializada")
        let rpc: [String: Data] = [
            "estimateFee": try ReaderFixtures.data("ton", "estimateFee"),
            "seqno": try ReaderFixtures.data("ton", "runGetMethod-seqno"),
            "get_wallet_address": try ReaderFixtures.data("ton", "runGetMethod-get_wallet_address"),
            "get_wallet_data": try ReaderFixtures.data("ton", "runGetMethod-get_wallet_data"),
        ]
        let tonapiSeqno = try ReaderFixtures.data("ton", "tonapi-seqno")
        let tonapiOwner = try ReaderFixtures.data("ton", "tonapi-account-dono")
        let tonapiJetton = try ReaderFixtures.data("ton", "tonapi-get_wallet_data")
        let tonapiMessage = try ReaderFixtures.data("ton", "tonapi-message-transaction")
        let toncenterMessage = try ReaderFixtures.data("ton", "toncenter-transactionsByMessage")
        let events = try ReaderFixtures.data("ton", "tonapi-events")
        let ownerRaw = wallet.address.raw
        return FixtureTransport(before + [{ request, body in
            let host = request.url.host ?? ""
            let path = request.url.path
            let method = FixtureTransport.method(body)
            let key = host + " " + path + "|" + (method.flatMap { m in
                m == "runGetMethod" ? (try? body?.field("params", "p").field("method", "p").string("p")) : m
            } ?? "")
            if let special = overrides[key] { return special }
            if host == "toncenter-v2.test", let method {
                switch method {
                case "getAddressInformation":
                    let address = try? body?.field("params", "p").field("address", "p").string("p")
                    return address == ownerRaw ? owner : uninit
                case "runGetMethod":
                    return (try? body?.field("params", "p").field("method", "p").string("p")).flatMap { rpc[$0] }
                case "sendBocReturnHash":
                    return nil
                default:
                    return rpc[method]
                }
            }
            if host == "tonapi.test" {
                if path == "/blockchain/accounts/" + ownerRaw { return tonapiOwner }
                if path == "/blockchain/accounts/" + Self.ownerJettonWallet + "/methods/get_wallet_data" { return tonapiJetton }
                if path.hasSuffix("/methods/seqno") { return tonapiSeqno }
                if path.hasSuffix("/transaction") { return tonapiMessage }
                if path.hasSuffix("/events") { return events }
            }
            if host == "toncenter.test", path.hasSuffix("/transactionsByMessage") { return toncenterMessage }
            return nil
        }])
    }

    static func reader(_ transport: FixtureTransport) -> TONReader {
        TONReader(transport: transport, rpc: testProviders("toncenter-v2"), api: testProviders("tonapi", "toncenter"))
    }

    @Test("Conta V4R2 ativa: status, saldo e hash do codigo calculado do BOC")
    func accountInformation() throws {
        let active = try TONReader.parseAddressInformation(try ReaderFixtures.json("ton", "getAddressInformation-dono").field("result", "$"))
        #expect(active.status == .active)
        #expect(active.balance == BigUInt(96_633_095_889_328))
        #expect(active.codeHash == TONWalletVersion.v4r2.codeHash)
        let uninit = try TONReader.parseAddressInformation(try ReaderFixtures.json("ton", "getAddressInformation-nao-inicializada").field("result", "$"))
        #expect(uninit.status == .uninitialized)
        #expect(uninit.codeHash == nil)
        let tonapi = try TONReader.parseTonapiAccount(try ReaderFixtures.json("ton", "tonapi-account-dono"), address: Self.wallet.address)
        #expect(tonapi.status == .active)
        #expect(tonapi.codeHash == TONWalletVersion.v4r2.codeHash)
        // Resposta de outra conta na tonapi: recusada.
        #expect(throws: ReaderError.responseMismatch(field: "blockchain/accounts.address")) {
            _ = try TONReader.parseTonapiAccount(try ReaderFixtures.json("ton", "tonapi-account-dono"), address: TONJetton.usdtMaster)
        }
    }

    @Test("seqno nas duas APIs; taxa somada das fases da origem")
    func seqnoAndFee() throws {
        #expect(try TONReader.parseSeqno(toncenter: try ReaderFixtures.json("ton", "runGetMethod-seqno").field("result", "$")) == 63_846)
        #expect(try TONReader.parseSeqno(tonapi: try ReaderFixtures.json("ton", "tonapi-seqno")) == 63_846)
        #expect(try TONReader.parseEstimateFee(try ReaderFixtures.json("ton", "estimateFee").field("result", "$")) == BigUInt(66_727))
    }

    @Test("Estado do envio de TON montado das respostas gravadas e aceito pelo planejador")
    func chainState() async throws {
        let transport = try Self.transport()
        let state = try await Self.reader(transport).chainState(wallet: Self.wallet, intent: .ton(to: Self.destination, amount: 1_000_000, comment: nil))
        #expect(state.accountStatus == .active)
        #expect(state.seqno == 63_846)
        #expect(state.estimatedFee == BigUInt(66_727))
        #expect(state.codeHash == TONWalletVersion.v4r2.codeHash)
        #expect(state.destinationStatus == .uninitialized)
        // O corpo emulado tem a assinatura zerada e pede ignore_chksig.
        let estimate = transport.requests.first { FixtureTransport.method($0.body.flatMap { try? StrictJSON.parse($0) }) == "estimateFee" }
        let params = try #require(estimate?.body.flatMap { try? StrictJSON.parse($0) }).field("params", "p")
        #expect(try params.field("ignore_chksig", "p").bool("p"))
        let plan = try TONPlanner.planSendTON(
            walletID: UUID(), wallet: Self.wallet, path: DerivationPath("m/44'/607'/0'")!, to: Self.destination, amount: 1_000_000, state: state
        )
        #expect(plan.transactions.count == 1)
    }

    @Test("seqno diferente entre toncenter e tonapi: erro de consenso")
    func seqnoDisagreement() async throws {
        let other = Data("{\"success\":true,\"exit_code\":0,\"stack\":[{\"type\":\"num\",\"num\":\"0xf967\"}]}".utf8)
        let transport = try Self.transport(overrides: ["tonapi.test /blockchain/accounts/\(Self.wallet.address.raw)/methods/seqno|": other])
        await #expect(throws: ReaderError.providersDisagree(field: "seqno")) {
            _ = try await Self.reader(transport).chainState(wallet: Self.wallet, intent: .ton(to: Self.destination, amount: 1, comment: nil))
        }
    }

    // MARK: Duas fontes (auditoria 2, B3)

    /// O codigo da carteira jetton de USDT como as duas APIs mandam: a celula de
    /// biblioteca, em BOC (a toncenter com CRC, a tonapi sem).
    static let jettonCodeHex = "b5ee9c72010101010023000842028f452d7a4dfd74066b682365177259ed05734435be76b5fd4bd5d8af2b7c3d68"
    static let jettonCodeWithCRC = "b5ee9c72410101010023000842028f452d7a4dfd74066b682365177259ed05734435be76b5fd4bd5d8af2b7c3d68206bbf76"

    /// A carteira jetton do dono como conta ativa, na forma de cada API.
    static func jettonAccount(toncenter: Bool) throws -> Data {
        if toncenter {
            let code = Data(try #require(Hex.decode(jettonCodeWithCRC))).base64EncodedString()
            return Data(#"{"ok":true,"result":{"@type":"raw.fullAccountState","balance":"5000000","code":"\#(code)","data":"","frozen_hash":"","state":"active"}}"#.utf8)
        }
        return Data(#"{"address":"\#(ownerJettonWallet)","balance":5000000,"status":"active","code":"\#(jettonCodeHex)"}"#.utf8)
    }

    /// Uma regra que responde por uma conta so, antes das gravacoes.
    static func rule(host: String, account: String, _ data: @escaping @Sendable () throws -> Data) -> FixtureTransport.Rule {
        { request, body in
            guard request.url.host == host else { return nil }
            if host == "tonapi.test" { return request.url.path == "/blockchain/accounts/" + account ? try data() : nil }
            guard FixtureTransport.method(body) == "getAddressInformation",
                  (try? body?.field("params", "p").field("address", "p").string("p")) == account
            else { return nil }
            return try data()
        }
    }

    @Test("Conta em duas fontes: status e codigo iguais; o saldo e o menor")
    func accountMerge() throws {
        let v4 = TONWalletVersion.v4r2.codeHash
        let a = TONReader.AccountReading(status: .active, balance: 10, codeHash: v4)
        let b = TONReader.AccountReading(status: .active, balance: 7, codeHash: v4)
        #expect(try TONReader.mergeAccounts(a, b) == TONReader.AccountReading(status: .active, balance: 7, codeHash: v4))
        #expect(try TONReader.mergeAccounts(b, a).balance == 7)
        #expect(throws: ReaderError.providersDisagree(field: "account.status")) {
            try TONReader.mergeAccounts(a, TONReader.AccountReading(status: .uninitialized, balance: 10, codeHash: nil))
        }
        #expect(throws: ReaderError.providersDisagree(field: "account.code")) {
            try TONReader.mergeAccounts(a, TONReader.AccountReading(status: .active, balance: 10, codeHash: TONWalletVersion.v5r1.codeHash))
        }
        // A conta nao inicializada da tonapi e a da toncenter: a mesma leitura.
        let tonapi = try TONReader.parseTonapiAccount(
            try ReaderFixtures.json("ton", "tonapi-account-nao-inicializada"), address: try #require(Self.parsed(Self.uninitialized))
        )
        let center = try TONReader.parseAddressInformation(try ReaderFixtures.json("ton", "getAddressInformation-nao-inicializada").field("result", "$"))
        #expect(try TONReader.mergeAccounts(center, tonapi) == center)
    }

    static func parsed(_ text: String) -> TONAddress? {
        guard case .success(let parsed) = TONAddress.parse(text) else { return nil }
        return parsed.address
    }

    @Test("Destino que uma fonte diz carteira de USDT e a outra nao: nada e montado; as duas dizendo, o planejador recusa")
    func destinationFromBothSources() async throws {
        // A toncenter (pela gravacao) diz nao inicializada; a tonapi, a carteira jetton ativa.
        let hidden = try Self.transport(before: [Self.rule(host: "tonapi.test", account: Self.ownerJettonWallet) { try Self.jettonAccount(toncenter: false) }])
        await #expect(throws: ReaderError.providersDisagree(field: "account.status")) {
            _ = try await Self.reader(hidden).chainState(wallet: Self.wallet, intent: .ton(to: Self.ownerJettonWallet, amount: 1, comment: nil))
        }
        // As duas dizendo a verdade: o destino chega com o codigo da carteira de USDT.
        let honest = try Self.transport(before: [
            Self.rule(host: "tonapi.test", account: Self.ownerJettonWallet) { try Self.jettonAccount(toncenter: false) },
            Self.rule(host: "toncenter-v2.test", account: Self.ownerJettonWallet) { try Self.jettonAccount(toncenter: true) },
        ])
        let reader = Self.reader(honest)
        let state = try await reader.chainState(wallet: Self.wallet, intent: .ton(to: Self.ownerJettonWallet, amount: 1, comment: nil))
        #expect(state.destinationStatus == .active)
        #expect(TONJetton.isUSDTJettonWallet(codeHash: state.destinationCodeHash))
        #expect(throws: TONPlanError.destinationIsTokenContract) {
            try TONPlanner.planSendTON(walletID: UUID(), wallet: Self.wallet, path: DerivationPath("m/44'/607'/0'")!,
                                       to: Self.ownerJettonWallet, amount: 1, state: state)
        }
        let screen = try await reader.destinationState(try #require(Self.parsed(Self.ownerJettonWallet)))
        #expect(TONJetton.isUSDTJettonWallet(codeHash: screen.codeHash))
    }

    @Test("Uma fonte fora do ar: a outra sozinha nao decide conta do dono nem do destino")
    func noSingleSourceFallback() async throws {
        let tonapiDown: FixtureTransport.Rule = { request, _ in
            guard request.url.host == "tonapi.test", request.url.path.hasPrefix("/blockchain/accounts/"),
                  !request.url.path.contains("/methods/")
            else { return nil }
            throw HTTPClient.Failure.status(503)
        }
        await #expect(throws: HTTPClient.Failure.self) {
            _ = try await Self.reader(try Self.transport(before: [tonapiDown])).chainState(
                wallet: Self.wallet, intent: .ton(to: Self.destination, amount: 1, comment: nil)
            )
        }
        await #expect(throws: HTTPClient.Failure.self) {
            _ = try await Self.reader(try Self.transport(before: [tonapiDown])).destinationState(try #require(Self.parsed(Self.destination)))
        }
        let toncenterDown: FixtureTransport.Rule = { request, body in
            guard request.url.host == "toncenter-v2.test", FixtureTransport.method(body) == "getAddressInformation" else { return nil }
            throw HTTPClient.Failure.status(503)
        }
        await #expect(throws: HTTPClient.Failure.self) {
            _ = try await Self.reader(try Self.transport(before: [toncenterDown])).chainState(
                wallet: Self.wallet, intent: .ton(to: Self.destination, amount: 1, comment: nil)
            )
        }
    }

    @Test("Saldo de USDT em duas fontes: o menor; dono ou mestre trocado recusa; so uma respondendo, discordam")
    func jettonFromBothSources() async throws {
        let owner = Self.wallet.address
        let full = TONReader.JettonWalletData(balance: 100, owner: owner, master: TONJetton.usdtMaster)
        let lower = TONReader.JettonWalletData(balance: 60, owner: owner, master: TONJetton.usdtMaster)
        #expect(try TONReader.mergeJettonData(full, lower, owner: owner) == 60)
        #expect(try TONReader.mergeJettonData(nil, nil, owner: owner) == nil)
        #expect(throws: ReaderError.providersDisagree(field: "get_wallet_data")) { try TONReader.mergeJettonData(full, nil, owner: owner) }
        #expect(throws: ReaderError.providersDisagree(field: "get_wallet_data")) { try TONReader.mergeJettonData(nil, full, owner: owner) }
        let stranger = TONReader.JettonWalletData(balance: 100, owner: TONJetton.usdtMaster, master: TONJetton.usdtMaster)
        #expect(throws: ReaderError.responseMismatch(field: "get_wallet_data")) { try TONReader.mergeJettonData(full, stranger, owner: owner) }
        let otherMaster = TONReader.JettonWalletData(balance: 100, owner: owner, master: owner)
        #expect(throws: ReaderError.responseMismatch(field: "get_wallet_data")) { try TONReader.mergeJettonData(otherMaster, full, owner: owner) }

        // A resposta da tonapi: a mesma pilha; get-method que falha e `nil`.
        let parsed = try #require(try TONReader.parseJettonWalletData(tonapi: ReaderFixtures.json("ton", "tonapi-get_wallet_data")))
        #expect(parsed.balance == BigUInt(169_460_663_914) && parsed.owner == owner && parsed.master == TONJetton.usdtMaster)
        let failed = try StrictJSON.parse(Data(#"{"success":false,"exit_code":11,"stack":[{"type":"num","num":"0x17b02"}]}"#.utf8))
        #expect(try TONReader.parseJettonWalletData(tonapi: failed) == nil)

        // Pela rede gravada: a tonapi com saldo menor vale o menor.
        let path = "/blockchain/accounts/" + Self.ownerJettonWallet + "/methods/get_wallet_data"
        let recorded = String(decoding: try ReaderFixtures.data("ton", "tonapi-get_wallet_data"), as: UTF8.self)
        let smaller = Data(recorded.replacingOccurrences(of: "0x2774a4866a", with: "0x3b9aca00").utf8)
        let lowerTransport = try Self.transport(overrides: ["tonapi.test \(path)|": smaller])
        #expect(try await Self.reader(lowerTransport).jettonState(owner: owner).balance == BigUInt(1_000_000_000))
        // A tonapi sem a carteira jetton (404) e a toncenter com ela: discordam.
        let missing: FixtureTransport.Rule = { request, _ in
            guard request.url.host == "tonapi.test", request.url.path == path else { return nil }
            throw HTTPClient.Failure.status(404)
        }
        await #expect(throws: ReaderError.providersDisagree(field: "get_wallet_data")) {
            _ = try await Self.reader(try Self.transport(before: [missing])).jettonState(owner: owner)
        }
    }

    @Test("Taxa estimada acima do teto do planejador e recusada")
    func feeCeiling() async throws {
        let huge = Data("{\"ok\":true,\"result\":{\"source_fees\":{\"in_fwd_fee\":200000000,\"storage_fee\":0,\"gas_fee\":0,\"fwd_fee\":0}}}".utf8)
        let transport = try Self.transport(overrides: ["toncenter-v2.test |estimateFee": huge])
        await #expect(throws: ReaderError.implausibleValue(field: "estimateFee")) {
            _ = try await Self.reader(transport).chainState(wallet: Self.wallet, intent: .ton(to: Self.destination, amount: 1, comment: nil))
        }
    }

    @Test("Carteira jetton do USDT: a da rede tem de ser a calculada aqui; saldo com dono e mestre conferidos")
    func jettonState() async throws {
        let state = try await Self.reader(try Self.transport()).jettonState(owner: Self.wallet.address)
        #expect(state.ownerJettonWallet == "0:16e07181d7abc5e87ef9a4a696dad8a4b2199f46165f7e21a0dd1935aa393948")
        #expect(state.balance == BigUInt(169_460_663_914))
        #expect(try TONJetton.usdtWallet(owner: Self.wallet.address).raw == state.ownerJettonWallet)
        // O get_wallet_address gravado e da carteira do dono; para outra conta, a rede
        // "responderia" a carteira errada, e o leitor recusa.
        guard case .success(let other) = TONAddress.parse(Self.destination) else { return }
        await #expect(throws: ReaderError.responseMismatch(field: "get_wallet_address")) {
            _ = try await Self.reader(try Self.transport()).jettonState(owner: other.address)
        }
    }

    @Test("Corpo da emulacao igual ao que o TONTransfer assina, V4R2 e W5")
    func emulationBody() throws {
        for version in [TONWalletVersion.v4r2, .v5r1] {
            let wallet = try TONWallet(publicKey: TONReaderLiveTests.recordedOwnerKey, version: version)
            let message = TONOutgoingMessage(destination: TONJetton.usdtMaster, amount: 1, bounce: true, body: nil)
            let body = try TONReader.emulationBody(wallet: wallet, seqno: 7, validUntil: 1_790_000_000, messages: [message])
            #expect(body.bitCount > 512)
        }
    }

    @Test("Mensagem externa: confirmada nas duas APIs; vazia nas duas e vencida")
    func messageStatus() async throws {
        let hash = "732af3f9e362d8b32896464d6589f770a458a52a56eb45454a5f7cff92da407f"
        #expect(try await Self.reader(try Self.transport()).status(of: hash) == .confirmed(block: nil, confirmations: nil))
        let empty = try ReaderFixtures.data("ton", "toncenter-transactionsByMessage-vazio")
        let halfway = try Self.transport(overrides: ["toncenter.test /transactionsByMessage|": empty])
        #expect(try await Self.reader(halfway).status(of: hash) == .pending)
        #expect(try TONReader.parseToncenterTransactions(try ReaderFixtures.json("ton", "toncenter-transactionsByMessage")) == .confirmed(block: nil, confirmations: nil))
        #expect(try TONReader.parseToncenterTransactions(try ReaderFixtures.json("ton", "toncenter-transactionsByMessage-vazio")) == nil)
        guard case .object(var tx) = try ReaderFixtures.json("ton", "tonapi-message-transaction") else { return }
        tx["aborted"] = .bool(true)
        tx["success"] = .bool(false)
        #expect(try TONReader.parseTonapiTransaction(.object(tx)) == .failed(reason: "aborted"))
    }

    @Test("Transmissao: o id e o hash da mensagem calculado aqui; a toncenter tem de concordar")
    func broadcast() async throws {
        var builder = TONCellBuilder()
        try builder.storeUInt(0b10, bits: 2)
        let cell = builder.build()
        let boc = TONBOC.serialize(cell)
        let id = Hex.encode(cell.hash)
        let signed = SignedTransaction(chainID: "ton", raw: boc, encoded: Data(boc).base64EncodedString(), id: id)
        let good = Data("{\"ok\":true,\"result\":{\"hash\":\"\(Data(cell.hash).base64EncodedString())\"}}".utf8)
        let accepted = Data("{}".utf8)
        let transport = try Self.transport(overrides: ["toncenter-v2.test |sendBocReturnHash": good, "tonapi.test /blockchain/message|": accepted])
        let receipt = try await Self.reader(transport).broadcast(signed)
        #expect(Set(receipt.acceptedBy) == ["toncenter-v2", "tonapi"])
        #expect(receipt.id == id)
        let wrongID = SignedTransaction(chainID: "ton", raw: boc, encoded: signed.encoded, id: String(repeating: "00", count: 32))
        await #expect(throws: ReaderError.broadcastMismatch) { _ = try await Self.reader(transport).broadcast(wrongID) }
    }

    @Test("Eventos da tonapi: USDT pelo mestre compilado, 1 nanoton de golpe escondido")
    func history() throws {
        guard case .success(let parsed) = TONAddress.parse("0:c44015434ad966c8dab4b5180f272d094855e0a7489a2dd05acf6a6c1ee47faa") else { return }
        let page = try TONReader.parseEvents(try ReaderFixtures.json("ton", "tonapi-events"), owner: parsed.address)
        #expect(page.items.count == 3)
        #expect(page.items.allSatisfy { $0.asset.symbol == "USDT" && $0.direction == .received && $0.fee == nil })
        #expect(page.items.first?.amount == BigUInt(40_000_000_000))
        #expect(page.suspicious.flaggedByProvider == 5)
        #expect(page.items.allSatisfy { $0.explorerURL?.host == "tonviewer.com" })
    }
}
