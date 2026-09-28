import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// As respostas gravadas da Cardano, as mesmas dos testes do leitor
/// (EscaliburNetworkTests/Fixtures/leitores/cardano, `gravar.py`), lidas do repositorio.
enum CardanoEngineRecorded {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("EscaliburNetworkTests/Fixtures/leitores/cardano")

    /// Endereco com duas moedas so de ADA; a chave de pagamento e a testemunha das
    /// transacoes dele na rede (cbcbac71..., 20c9cd5d..., 0dcb3739...).
    static let owner = "addr1q8ph5dwx5hzrygtwfdpk2nxp2y4p0rr35tds049rz3dee4kr0g6udfwyxgskuj6rv4xvz5f2z7x8rgkmql22x9zmnntqar3scw"
    static let ownerKey = [UInt8](hex: "23807a7cac8e98ac43b4f329dabb9e56a748dc27610604b5509f2da1bec894fd")!
    static let destination = "addr1q94zzrtl32tjp8j96auatnhxd2y35fnk6wuxqvqm9364vp9spdkjdsmyfhvfagjzh4uzp9zs6p5djw89jac2g0ujs2eqsuy7pu"
    static let tip: UInt64 = 198_997_677
    static let total: UInt64 = 710_782_414 + 562_456_215
    /// Transacao real 71fcd858... (bloco 13.997.301).
    static let signedHex = "84a400818258201159b3b890643a4838754419d96797504748b596ab2636fbe179235ef9d0c8df000181825839010d93d40a3b055fb9c61c24aba4b8a11907084702d599565ac48e4226cc552eaa4d8ce0b0e674a2f32096094ef8c3b433b8ecd1ca9e7c98301a1191e7dc021a00028f04031a0bdc7cbda100818258202cfe7dc06bc2693c82924eba788fd107db77b7af8863e4b5b2e764c608ac51fe5840fe2fa453011406f3f0b812e9ff9c1901f4c02ec81748f84151acad220438ec65b89c1f415cec8c70857730da2712d9b8aea438cd76cc40b6a272558b72ff0004f5f6"
    static let signedID = "71fcd8583c44f5e94243f81bb9498d6479c311faf864e86ddd1653061619b6e5"

    static func data(_ name: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(name + ".json")) }

    static func account(address: String = owner, key: [UInt8] = ownerKey) -> DerivedAccount {
        DerivedAccount(chainID: "cardano", path: DerivationPath("m/1852'/1815'/0'/0/0")!, address: address, publicKey: key, accountXPub: nil)
    }

    static func request(amount: BigUInt = 100_000_000, to destination: String = destination, sendAll: Bool = false,
                        asset: Asset = .native(.cardano), account: DerivedAccount = account(), known: [String] = []) -> SendRequest {
        SendRequest(
            walletID: UUID(), chain: .cardano, asset: asset, account: account, destination: destination, tag: nil,
            amount: amount, sendAll: sendAll, feeLevel: .normal, utxoUsage: nil, knownAddresses: known
        )
    }

    /// Responde pelo ultimo trecho do caminho; transmissao aceita nas duas fontes.
    struct Transport: ReaderTransport {
        func send(_ request: ReaderRequest) async throws -> Data {
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            switch (request.url.host ?? "", request.url.lastPathComponent) {
            case ("api.koios.rest", "address_utxos"): return try data("koios-address_utxos-dono")
            case ("api.koios.rest", "tip"): return try data("koios-tip")
            case ("api.koios.rest", "cli_protocol_params"): return try data("koios-cli_protocol_params")
            case ("api.koios.rest", "genesis"): return try data("koios-genesis")
            case ("api.koios.rest", "tx_status"):
                return try data(body.contains("d8da3593") ? "koios-tx_status" : "koios-tx_status-nenhuma")
            case ("api.koios.rest", "address_txs"): return try data("koios-address_txs-dono")
            case ("api.koios.rest", "tx_info"): return try data("koios-tx_info-dono")
            case ("api.koios.rest", "submittx"): return Data("\"\(signedID)\"".utf8)
            case ("api.yoroiwallet.com", "utxoForAddresses"): return try data("yoroi-utxoForAddresses-dono")
            case ("api.yoroiwallet.com", "bestblock"): return try data("yoroi-bestblock")
            case ("api.yoroiwallet.com", "status"):
                return try data(body.contains("d8da3593") ? "yoroi-tx_status" : "yoroi-tx_status-nenhuma")
            case ("api.yoroiwallet.com", "signed"): return Data("[]".utf8)
            case ("zero.yoroiwallet.com", "protocolparameters"): return try data("yoroi-protocolparameters")
            default: throw HTTPClient.Failure.status(404)
            }
        }
    }

    static func engine() -> CardanoSendEngine {
        let clock = Date(timeIntervalSince1970: TimeInterval(Int64(tip) + CardanoPlanner.shelleySlotOffset))
        return CardanoSendEngine(
            reader: CardanoReader(transport: Transport(), pacing: 0), deadlines: CardanoSendEngine.Deadlines(), now: { clock }
        )
    }
}

@Suite("Motor de envio da Cardano, com respostas gravadas")
struct CardanoSendEngineTests {
    @Test("Registrado para a Cardano: envio e Atividade, sem troca")
    func registry() {
        #expect(SendEngines.engine(for: .cardano) is CardanoSendEngine)
        #expect(ActivitySources.source(for: .cardano) is CardanoActivitySource)
        #expect(TradeEngines.engine(for: .cardano) == nil)
    }

    @Test("Plano: 100 ADA com troco, das moedas que as duas fontes listam")
    func plan() async throws {
        let request = CardanoEngineRecorded.request()
        let plan = try await CardanoEngineRecorded.engine().plan(request)
        #expect(plan.review.recipient == CardanoEngineRecorded.destination)
        #expect(plan.review.outgoing == PlanReview.Movement(assetID: Asset.native(.cardano).id, amount: 100_000_000))
        #expect(plan.review.warnings.contains(.firstSendToAddress))
        try PlanIntentCheck.send(plan.review, asset: .native(.cardano), amount: 100_000_000, ceiling: 0, chain: .cardano)
        let body = try #require(plan.transactions.first as? CardanoTransfer).body
        #expect(body.inputs.count == 1)
        #expect(Hex.encode(body.inputs[0].transactionID).hasPrefix("20c9cd5d"))
        #expect(body.ttl == CardanoEngineRecorded.tip + 900)
        #expect(body.outputs[1].lovelace == 710_782_414 - 100_000_000 - body.fee)
    }

    @Test("Maximo e enviar tudo: as duas moedas menos a taxa, sem passar do que o dono viu")
    func sendAll() async throws {
        let engine = CardanoEngineRecorded.engine()
        let spendable = try await engine.spendable(CardanoEngineRecorded.request())
        #expect(spendable.amount < BigUInt(CardanoEngineRecorded.total))
        #expect(spendable.amount > BigUInt(CardanoEngineRecorded.total - 300_000))
        #expect(spendable.feeNote == CardanoEngineText.feeNote)
        #expect(spendable.reserveNote == nil)

        let all = try await engine.plan(CardanoEngineRecorded.request(amount: spendable.amount, sendAll: true))
        #expect(all.review.outgoing?.amount == spendable.amount)
        try PlanIntentCheck.send(all.review, asset: .native(.cardano), amount: nil, ceiling: spendable.amount, chain: .cardano)
        #expect(try #require(all.transactions.first as? CardanoTransfer).body.outputs.count == 1)

        // O dono viu menos do que ha agora: sai o que ele viu, com troco.
        let less = try await engine.plan(CardanoEngineRecorded.request(amount: 700_000_000, sendAll: true))
        #expect(less.review.outgoing?.amount == 700_000_000)
    }

    @Test("Recusas antes de ler a rede: ativo, conta, destino")
    func refusals() async throws {
        let engine = CardanoEngineRecorded.engine()
        await #expect(throws: SendEngineError.message(CardanoEngineText.unsupportedAsset)) {
            try await engine.plan(CardanoEngineRecorded.request(asset: .native(.sui)))
        }
        await #expect(throws: SendEngineError.message(CardanoEngineText.address(.otherNetwork(.ethereum)))) {
            try await engine.plan(CardanoEngineRecorded.request(to: "0x52908400098527886E0F7030069857D2E4169EE7"))
        }
        await #expect(throws: SendEngineError.message(CardanoEngineText.keyMismatch)) {
            try await engine.plan(CardanoEngineRecorded.request(account: CardanoEngineRecorded.account(key: [UInt8](repeating: 7, count: 32))))
        }
        await #expect(throws: SendEngineError.unsupported(.sui)) { try await engine.destination(CardanoEngineRecorded.destination, chain: .sui) }
        let info = try await engine.destination(CardanoEngineRecorded.destination, chain: .cardano)
        #expect(info.exists && !info.requiresTag)
        // Mais do que o saldo.
        await #expect(throws: SendEngineError.message(CardanoEngineText.insufficient)) {
            try await engine.plan(CardanoEngineRecorded.request(amount: 2_000_000_000))
        }
    }

    @Test("Transmissao so da transacao conferida; acompanhamento nas duas fontes")
    func broadcastAndStatus() async throws {
        let engine = CardanoEngineRecorded.engine()
        let raw = [UInt8](hex: CardanoEngineRecorded.signedHex)!
        let signed = SignedTransaction(chainID: "cardano", raw: raw, encoded: CardanoEngineRecorded.signedHex, id: CardanoEngineRecorded.signedID)
        #expect(try await engine.broadcast([signed], chain: .cardano) == CardanoEngineRecorded.signedID)
        await #expect(throws: SendEngineError.message(CardanoEngineText.notOurTransaction)) {
            try await engine.broadcast([SignedTransaction(chainID: "cardano", raw: raw, encoded: "", id: String(repeating: "0", count: 64))], chain: .cardano)
        }
        // A transmitida acima vale ate o slot 198.999.229, depois da ponta gravada (198.997.677): sem
        // aparecer nas duas fontes, segue pendente (o vencimento esta no teste do leitor).
        #expect(await engine.status(CardanoEngineRecorded.signedID, chain: .cardano) == .pending)
        let confirmed = await engine.status("d8da3593663c88b2aa46dc27f7bcb8cef20bc86f7e456b43e467674fe6889c3a", chain: .cardano)
        #expect(confirmed == .confirmed(detail: CardanoEngineText.confirmed(109)))
    }

    @Test("Atividade: envios lidos da Koios, nenhum marcado como suspeito")
    func activity() async throws {
        let source = CardanoActivitySource(reader: CardanoReader(transport: CardanoEngineRecorded.Transport(), pacing: 0))
        let entries = try await source.history(chain: .cardano, account: CardanoEngineRecorded.account(), usage: nil)
        #expect(entries.count == 5)
        #expect(entries.allSatisfy { $0.direction == .sent && !$0.suspicious })
    }
}
