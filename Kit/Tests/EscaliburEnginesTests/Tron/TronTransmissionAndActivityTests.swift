import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburEngines

/// Transmissao, acompanhamento e Atividade da Tron contra as respostas gravadas, sem rede.
@Suite("Motor Tron: transmissao, acompanhamento e Atividade")
struct TronTransmissionAndActivityTests {
    typealias R = TronRecorded

    /// A transacao assinada gravada (TronGrid: `raw_data_hex` e a assinatura), montada
    /// como a Transaction que `broadcasthex` recebe.
    static func recordedSigned() throws -> (signed: SignedTransaction, raw: TronRawTransaction) {
        let recorded = try R.object("transacao-assinada")
        let rawHex = try #require(recorded["raw_data_hex"] as? String)
        let signatureHex = try #require((recorded["signature"] as? [String])?.first)
        let id = try #require(recorded["txID"] as? String)
        let rawData = try #require(Hex.decode(rawHex))
        let signature = try #require(Hex.decode(signatureHex))
        let raw = try TronRawTransaction.decode(rawData)
        let bytes = TronProtobuf.signedTransaction(raw: raw, signatures: [signature])
        return (SignedTransaction(chainID: "tron", raw: bytes, encoded: Hex.encode(bytes), id: id), raw)
    }

    // MARK: Transmissao

    @Test("Transmissao: devolve o txID calculado dos bytes e guarda a expiracao gravada na transacao")
    func broadcast() async throws {
        let (signed, raw) = try Self.recordedSigned()
        let accepted = R.encode(["result": true, "txid": signed.id])
        let transport = try R.Transport { _, path, _ in path == "/wallet/broadcasthex" ? accepted : nil }
        let engine = try R.engine(transport)
        let id = try await engine.broadcast([signed], chain: .tron)
        #expect(id == Hex.encode(raw.txID))
        #expect(transport.paths(containing: "broadcasthex").count == 2)
        let deadline = await engine.deadlines.deadline(for: id)
        #expect(deadline == Date(timeIntervalSince1970: TimeInterval(raw.expiration) / 1000))
    }

    @Test("Transmissao de bytes que nao batem com o id, ou de outra rede: recusada sem sair nada")
    func broadcastRefusesForeignBytes() async throws {
        let (signed, _) = try Self.recordedSigned()
        let transport = try R.Transport()
        let engine = try R.engine(transport)
        let wrongID = SignedTransaction(chainID: "tron", raw: signed.raw, encoded: signed.encoded, id: String(repeating: "ab", count: 32))
        let wrongChain = SignedTransaction(chainID: "ton", raw: signed.raw, encoded: signed.encoded, id: signed.id)
        let truncated = SignedTransaction(chainID: "tron", raw: Array(signed.raw.dropLast()), encoded: Hex.encode(signed.raw.dropLast()), id: signed.id)
        for bad in [[wrongID], [wrongChain], [truncated], [signed, signed], []] {
            await #expect(throws: SendEngineError.message(TronEngineText.notOurTransaction)) { _ = try await engine.broadcast(bad, chain: .tron) }
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("Recusa dos dois provedores: nada saiu; falha de rede: conferir antes de repetir")
    func broadcastFailures() async throws {
        let (signed, _) = try Self.recordedSigned()
        let refused = R.encode(["result": false, "code": "SIGERROR", "message": "76616c6964617465207369676e6174757265206572726f72"])
        let rejecting = try R.Transport { _, path, _ in path == "/wallet/broadcasthex" ? refused : nil }
        await #expect(throws: SendEngineError.message(TronEngineText.rejected(.invalidSignature))) {
            _ = try await R.engine(rejecting).broadcast([signed], chain: .tron)
        }
        let offline = try R.Transport { _, path, _ in
            if path == "/wallet/broadcasthex" { throw HTTPClient.Failure.timeout }
            return nil
        }
        await #expect(throws: SendEngineError.message(TronEngineText.broadcastUnconfirmed)) {
            _ = try await R.engine(offline).broadcast([signed], chain: .tron)
        }
        let otherID = R.encode(["result": true, "txid": String(repeating: "cd", count: 32)])
        let lying = try R.Transport { _, path, _ in path == "/wallet/broadcasthex" ? otherID : nil }
        await #expect(throws: SendEngineError.message(TronEngineText.answerMismatch)) {
            _ = try await R.engine(lying).broadcast([signed], chain: .tron)
        }
    }

    // MARK: Acompanhamento

    @Test("Resultado final no no solidificado dos dois provedores: confirmado")
    func statusConfirmed() async throws {
        let engine = try R.engine(try R.Transport())
        let status = await engine.status("6484590d488c8c312525f491137e5f95f5d3a9cd05235474a058c2fe29824982", chain: .tron)
        #expect(status == .confirmed(detail: TronEngineText.confirmed))
    }

    /// A hora do ultimo bloco solidificado de cada provedor, trocada no meio do teste.
    final class SolidClock: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [String: Date] = [:]
        func set(_ host: String, _ date: Date) { lock.withLock { times[host] = date } }
        func block(_ host: String) -> Data? {
            guard let date = lock.withLock({ times[host] }) else { return nil }
            return R.encode(["blockID": String(repeating: "0", count: 64),
                             "block_header": ["raw_data": ["number": 1, "timestamp": Int64(date.timeIntervalSince1970 * 1000)]]])
        }
    }

    /// Resposta alterada no teste: `gettransactioninfobyid` volta `{}` nos dois nos, e o
    /// bloco solidificado de cada no e montado aqui.
    @Test("Regressao M4: vencida so quando o bloco solidificado dos dois provedores passou da expiracao, nunca pelo relogio do aparelho")
    func statusExpires() async throws {
        let empty = try R.data("gettransactioninfobyid-vazio")
        let (signed, raw) = try Self.recordedSigned()
        let expiration = Date(timeIntervalSince1970: TimeInterval(raw.expiration) / 1000)
        let accepted = R.encode(["result": true, "txid": signed.id])
        let solid = SolidClock()
        let transport = try R.Transport { host, path, _ in
            if path.hasSuffix("gettransactioninfobyid") { return empty }
            if path == "/walletsolidity/getnowblock" { return solid.block(host) }
            return path == "/wallet/broadcasthex" ? accepted : nil
        }
        let deadlines = TronSendEngine.Deadlines()
        let reader = TronReader(transport: transport, providers: R.providers)
        _ = try await TronSendEngine(reader: reader, deadlines: deadlines, now: { expiration }).broadcast([signed], chain: .tron)
        // O relogio do aparelho uma hora adiantado nao decide nada.
        let engine = TronSendEngine(reader: reader, deadlines: deadlines, now: { expiration.addingTimeInterval(3_600) })

        for host in ["publicnode.test", "trongrid.test"] { solid.set(host, expiration.addingTimeInterval(60)) }
        #expect(await engine.status(signed.id, chain: .tron) == .pending)
        // Um provedor adiantado sozinho nao faz vencer: vale a menor hora dos dois.
        solid.set("trongrid.test", expiration.addingTimeInterval(600))
        #expect(await engine.status(signed.id, chain: .tron) == .pending)
        solid.set("publicnode.test", expiration.addingTimeInterval(300))
        #expect(await engine.status(signed.id, chain: .tron) == .failed(reason: TronEngineText.failure("expired")))
        // Sem registro de expiracao (app reaberto), nunca vence: fica pendente.
        let forgotten = TronSendEngine(reader: reader, deadlines: TronSendEngine.Deadlines(), now: { expiration.addingTimeInterval(3_600) })
        #expect(await forgotten.status(signed.id, chain: .tron) == .pending)
    }

    @Test("Falha de leitura no acompanhamento: pendente, nunca falha inventada")
    func statusReadFailure() async throws {
        let transport = try R.Transport { _, _, _ in throw HTTPClient.Failure.offline }
        let engine = try R.engine(transport)
        #expect(await engine.status("6484590d488c8c312525f491137e5f95f5d3a9cd05235474a058c2fe29824982", chain: .tron) == .pending)
        #expect(await engine.status("nao-e-hash", chain: .tron) == .pending)
    }

    // MARK: Atividade

    static func poisonedHistory() async throws -> [ActivityEntry] {
        let source = TronActivitySource(reader: TronReader(transport: try R.Transport(), providers: R.providers))
        return try await source.history(chain: .tron, account: R.account(address: R.poisoned), usage: nil)
    }

    /// Os 7 transferFrom de valor zero que a conta nao assinou (Fixtures/tron/LEIA-ME.txt).
    static let forged: Set<String> = [
        "2ac7cce0c7fd", "1af7acabca53", "f69bad45b9e3", "6fa6109a4404", "efd5768f2f03", "05f41f821aaa", "82917b5e1aa1",
    ]

    @Test("Historico envenenado gravado: os envios falsos de 0 USDT saem marcados, os verdadeiros nao")
    func poisonedHistoryIsScreened() async throws {
        let entries = try await Self.poisonedHistory()
        let suspicious = entries.filter(\.suspicious)
        #expect(Set(suspicious.map { String($0.hash.prefix(12)) }) == Self.forged)
        #expect(suspicious.allSatisfy { $0.direction == .sent && $0.amount.isZero && $0.fee == nil && $0.asset?.symbol == "USDT" })

        // Os cinco envios de USDT e o de TRX que a conta assinou aparecem, com a taxa.
        let signed = entries.filter { $0.direction == .sent && !$0.amount.isZero }
        #expect(signed.count == 6)
        #expect(signed.allSatisfy { !$0.suspicious && $0.fee != nil })
        #expect(signed.contains { $0.counterparty == "TCsa4VaxBcoY2N7pFdkmC5r1AtieCRRgos" && $0.amount == BigUInt(400_000_000) })
        // O TRX de 1 a 9 sun de desconhecidos nem chega: o leitor ja tira o po abaixo do limite.
        #expect(!entries.contains { $0.direction == .received && $0.asset == R.trx && $0.amount < BigUInt(100) })
        // Limite conhecido: 0,0215 USDT de TAASGw3...6g1d2, sosia de TAAQ2PHS...6g1d2, fica
        // visivel. Casa 2 letras no comeco (depois do T) e 5 no fim, e `AddressPoisoning`
        // pede 3 no comeco.
        #expect(entries.contains { $0.counterparty == "TAASGw3rY8vdqWpM6p2gHc1YpQ4XY6g1d2" && !$0.suspicious })
    }

    static func item(
        _ direction: ActivityItem.Direction, asset: Asset = R.usdt, amount: BigUInt, from counterparty: String, fee: BigUInt? = nil
    ) -> ActivityItem {
        ActivityItem(
            id: "tron:\(UUID().uuidString)", chainID: "tron", direction: direction, asset: asset, amount: amount,
            counterparty: counterparty, date: Date(timeIntervalSince1970: 1_790_000_000), status: .confirmed, fee: fee,
            hash: String(repeating: "0", count: 64), explorerURL: nil
        )
    }

    /// Itens montados no teste para as regras que o historico gravado nao exercita.
    @Test("Regras: sosia de destino verdadeiro, po no limite, token fora da lista e dreno")
    func screeningRules() {
        let real = "TCsa4VaxBcoY2N7pFdkmC5r1AtieCRRgos"
        // Mesmas 4 letras depois do T e mesmas 5 no fim, meio trocado.
        let lookalike = "TCsa4" + String(repeating: "Z", count: 24) + "RRgos"
        let stranger = "TXV9JPfrcQhPL1DoFiM5vAMVeusfPjDqmH"
        let fakeToken = Asset(chainID: "tron", kind: .token(contract: "TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj"), symbol: "USDT", name: "Tether",
                              decimals: 6, coingeckoID: nil, isStablecoin: true)
        let items = [
            Self.item(.sent, amount: 400_000_000, from: real, fee: 12_453_000),
            Self.item(.received, amount: 5_000_000, from: lookalike),
            Self.item(.received, amount: 10_000, from: stranger),
            Self.item(.received, amount: 10_000, from: real),
            Self.item(.received, amount: 10_001, from: stranger),
            Self.item(.received, asset: fakeToken, amount: 5_000_000, from: stranger),
            Self.item(.sent, amount: 900_000_000, from: stranger),
            Self.item(.sent, amount: 0, from: stranger, fee: 345_000),
        ]
        let entries = TronActivityScreen.entries(items, owner: R.poisoned)
        #expect(entries.map(\.suspicious) == [false, true, true, false, false, true, false, false])
    }
}
