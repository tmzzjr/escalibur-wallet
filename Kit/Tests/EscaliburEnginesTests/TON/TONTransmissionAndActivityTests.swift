import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburEngines

/// Transmissao, acompanhamento e Atividade da TON contra as respostas gravadas, sem rede.
@Suite("Motor TON: transmissao, acompanhamento e Atividade")
struct TONTransmissionAndActivityTests {
    typealias R = TONRecorded

    /// Uma celula montada no teste com o prefixo de mensagem externa. A transmissao so
    /// confere a forma e o hash; a assinatura e conferida pelo contrato da carteira.
    static func message(prefix: UInt64 = 0b10) throws -> (signed: SignedTransaction, hash: [UInt8]) {
        var builder = TONCellBuilder()
        try builder.storeUInt(prefix, bits: 2)
        try builder.storeUInt(0xE5C0_1A77, bits: 32)
        let cell = builder.build()
        let boc = TONBOC.serialize(cell)
        return (SignedTransaction(chainID: "ton", raw: boc, encoded: Data(boc).base64EncodedString(), id: Hex.encode(cell.hash)), cell.hash)
    }

    static func accepting(_ hash: [UInt8]) throws -> R.Transport {
        let answer = Data("{\"ok\":true,\"result\":{\"hash\":\"\(Data(hash).base64EncodedString())\"}}".utf8)
        return try R.Transport { _, path, method, _ in
            if method == "sendBocReturnHash" { return answer }
            return path.hasSuffix("/blockchain/message") ? Data("{}".utf8) : nil
        }
    }

    // MARK: Transmissao

    @Test("Transmissao: devolve o hash da mensagem calculado dos bytes, o mesmo que o acompanhamento procura")
    func broadcast() async throws {
        let (signed, hash) = try Self.message()
        let deadlines = TONSendEngine.Deadlines()
        let id = try await R.engine(try Self.accepting(hash), deadlines: deadlines).broadcast([signed], chain: .ton)
        #expect(id == Hex.encode(hash))
        #expect(await deadlines.deadline(for: id) == R.now.addingTimeInterval(TONPlanner.validitySeconds))
    }

    @Test("Transmissao do que nao e mensagem externa, ou com id trocado: recusada sem sair nada")
    func broadcastRefusesForeignBytes() async throws {
        let (signed, hash) = try Self.message()
        let (internalMessage, _) = try Self.message(prefix: 0b00)
        let transport = try Self.accepting(hash)
        let engine = R.engine(transport)
        let wrongID = SignedTransaction(chainID: "ton", raw: signed.raw, encoded: signed.encoded, id: String(repeating: "0", count: 64))
        let wrongEncoding = SignedTransaction(chainID: "ton", raw: signed.raw, encoded: Data(signed.raw.dropLast()).base64EncodedString(), id: signed.id)
        for bad in [[internalMessage], [wrongID], [wrongEncoding], [signed, signed], []] {
            await #expect(throws: SendEngineError.message(TONEngineText.notOurTransaction)) { _ = try await engine.broadcast(bad, chain: .ton) }
        }
        #expect(transport.requests.isEmpty)
    }

    /// Respostas montadas no teste: a toncenter devolve outro hash e a tonapi aceita;
    /// depois, as duas APIs falham com erro de rede.
    @Test("Hash trocado num provedor: vale a aceitacao do outro, com o id daqui; falha nas duas: conferir antes de repetir")
    func broadcastFailures() async throws {
        let (signed, hash) = try Self.message()
        let lying = try Self.accepting([UInt8](repeating: 7, count: 32))
        #expect(try await R.engine(lying).broadcast([signed], chain: .ton) == Hex.encode(hash))
        let offline = try R.Transport { _, _, _, _ in throw HTTPClient.Failure.timeout }
        await #expect(throws: SendEngineError.message(TONEngineText.broadcastUnconfirmed)) {
            _ = try await R.engine(offline).broadcast([signed], chain: .ton)
        }
    }

    // MARK: Acompanhamento

    @Test("Transacao achada nas duas APIs: confirmado")
    func statusConfirmed() async throws {
        let status = await R.engine(try R.Transport()).status("732af3f9e362d8b32896464d6589f770a458a52a56eb45454a5f7cff92da407f", chain: .ton)
        #expect(status == .confirmed(detail: TONEngineText.confirmed))
    }

    /// Respostas montadas no teste: a tonapi responde 404 e a toncenter, lista vazia.
    @Test("Nada nas duas APIs: pendente ate um minuto depois do prazo, entao vencida; sem prazo, nunca vence")
    func statusExpires() async throws {
        let (signed, hash) = try Self.message()
        let empty = try R.data("toncenter-transactionsByMessage-vazio")
        let answer = Data("{\"ok\":true,\"result\":{\"hash\":\"\(Data(hash).base64EncodedString())\"}}".utf8)
        let transport = try R.Transport { _, path, method, _ in
            if method == "sendBocReturnHash" { return answer }
            if path.hasSuffix("/blockchain/message") { return Data("{}".utf8) }
            if path.hasSuffix("/transaction") { throw HTTPClient.Failure.status(404) }
            return path.hasSuffix("/transactionsByMessage") ? empty : nil
        }
        let deadlines = TONSendEngine.Deadlines()
        let id = try await R.engine(transport, deadlines: deadlines).broadcast([signed], chain: .ton)
        let deadline = R.now.addingTimeInterval(TONPlanner.validitySeconds)
        #expect(await R.engine(transport, deadlines: deadlines, now: deadline.addingTimeInterval(30)).status(id, chain: .ton) == .pending)
        #expect(await R.engine(transport, deadlines: deadlines, now: deadline.addingTimeInterval(90)).status(id, chain: .ton)
            == .failed(reason: TONEngineText.failure("expired")))
        #expect(await R.engine(transport, now: deadline.addingTimeInterval(3_600)).status(id, chain: .ton) == .pending)
    }

    @Test("Falha de leitura no acompanhamento: pendente")
    func statusReadFailure() async throws {
        let transport = try R.Transport { _, _, _, _ in throw HTTPClient.Failure.offline }
        #expect(await R.engine(transport).status("732af3f9e362d8b32896464d6589f770a458a52a56eb45454a5f7cff92da407f", chain: .ton) == .pending)
    }

    // MARK: Atividade

    /// Os 0,0001 TON de enderecos desconhecidos que a tonapi nao marcou como golpe
    /// (Fixtures/ton/LEIA-ME.txt). Os que ela marcou o leitor ja tira.
    static let dustEvents: Set<String> = ["e62194f72e", "e29cde4782", "b2e26dd615", "cfc8b2289d", "9796520396"]

    @Test("Historico envenenado gravado: o po de 0,0001 TON de sosias sai marcado; USDT e envios, nao")
    func poisonedHistoryIsScreened() async throws {
        let source = TONActivitySource(reader: R.reader(try R.Transport()))
        let account = DerivedAccount(chainID: "ton", path: R.ownerPath, address: R.poisoned.friendly(bounceable: false), publicKey: R.ownerKey, accountXPub: nil)
        let entries = try await source.history(chain: .ton, account: account, usage: nil)
        let suspicious = entries.filter(\.suspicious)
        #expect(Set(suspicious.map { String($0.hash.prefix(10)) }) == Self.dustEvents)
        #expect(suspicious.allSatisfy { $0.direction == .received && $0.asset == R.ton && $0.amount == BigUInt(100_000) })
        let usdt = entries.filter { $0.asset == R.usdt }
        #expect(usdt.count == 15)
        #expect(usdt.allSatisfy { !$0.suspicious })
        #expect(usdt.filter { $0.direction == .sent }.count == 4)
    }

    static func received(_ amount: BigUInt, asset: Asset = R.ton, from sender: TONAddress) -> ActivityItem {
        ActivityItem(
            id: "ton:\(UUID().uuidString)", chainID: "ton", direction: .received, asset: asset, amount: amount,
            counterparty: sender.raw, date: Date(timeIntervalSince1970: 1_790_000_000), status: .confirmed, fee: nil,
            hash: String(repeating: "0", count: 64), explorerURL: nil
        )
    }

    /// Gera um sosia da grafia amigavel como o golpista gera: os mesmos primeiros bytes do
    /// hash (o comeco do texto) e um meio variado ate o CRC dar o mesmo fim.
    static func friendlyLookalike(of target: TONAddress) throws -> TONAddress {
        let wanted = String(target.friendly(bounceable: false).suffix(3))
        for counter in 0..<UInt32.max {
            var hash = target.hash
            hash[10] ^= 0xFF
            hash[20] = UInt8(truncatingIfNeeded: counter)
            hash[21] = UInt8(truncatingIfNeeded: counter >> 8)
            hash[22] = UInt8(truncatingIfNeeded: counter >> 16)
            let candidate = TONAddress(workchain: 0, hash: hash)
            if candidate.friendly(bounceable: false).hasSuffix(wanted) { return candidate }
        }
        throw TONRecorded.Missing(name: "sosia")
    }

    /// Itens montados no teste para as regras que o historico gravado nao exercita.
    @Test("Regras: sosia na grafia amigavel e na raw, po no limite, conhecido e token fora da lista")
    func screeningRules() throws {
        let real = R.activeDestination
        let friendly = try Self.friendlyLookalike(of: real)
        #expect(friendly.raw != real.raw)
        var rawHash = real.hash
        rawHash[16] ^= 0xFF
        let rawLookalike = TONAddress(workchain: 0, hash: rawHash)
        let stranger = R.uninitializedDestination
        let fakeJetton = Asset(chainID: "ton", kind: .token(contract: "EQAvlWFDxGF2lXm67y4yzC17wYKD9A0guwPkMs1gOsM__NOT"), symbol: "USDT",
                               name: "Tether", decimals: 6, coingeckoID: nil, isStablecoin: true)
        let sent = ActivityItem(
            id: "ton:envio", chainID: "ton", direction: .sent, asset: R.usdt, amount: 5_000_000, counterparty: real.raw,
            date: Date(timeIntervalSince1970: 1_790_000_000), status: .confirmed, fee: 5_000_000, hash: "envio", explorerURL: nil
        )
        let items = [
            sent,
            Self.received(20_000_000, from: friendly),
            Self.received(20_000_000, from: rawLookalike),
            Self.received(100_000, from: stranger),
            Self.received(100_000, from: real),
            Self.received(100_001, from: stranger),
            Self.received(5_000_000, asset: fakeJetton, from: stranger),
        ]
        let entries = TONActivityScreen.entries(items, owner: R.poisoned)
        #expect(entries.map(\.suspicious) == [false, true, true, true, false, false, true])
    }
}
