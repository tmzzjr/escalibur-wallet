import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Respostas da Koios e do backend da Yoroi gravadas em 27/09/2026
/// (Fixtures/leitores/cardano, `gravar.py`), no mesmo minuto: as duas fontes deram as
/// mesmas moedas, a mesma ponta e os mesmos parametros. Contas: um endereco com duas
/// moedas so de ADA e um com oito moedas que carregam tokens.
enum CardanoRecorded {
    static let owner = "addr1q8ph5dwx5hzrygtwfdpk2nxp2y4p0rr35tds049rz3dee4kr0g6udfwyxgskuj6rv4xvz5f2z7x8rgkmql22x9zmnntqar3scw"
    static let tokens = "addr1qxhss4frkp0hhhm3vku2mcj8lu47ezadcpfn8fw8njldx7fzh4dpaxkdtqwh5u7srvagl0sam4un2xfjrr7erw46ujuq4rs8u7"
    static let knownTx = "d8da3593663c88b2aa46dc27f7bcb8cef20bc86f7e456b43e467674fe6889c3a"
    static let tip: UInt64 = 198_997_677
    /// Transacao real 71fcd858... (bloco 13.997.301), para a transmissao.
    static let signedHex = "84a400818258201159b3b890643a4838754419d96797504748b596ab2636fbe179235ef9d0c8df000181825839010d93d40a3b055fb9c61c24aba4b8a11907084702d599565ac48e4226cc552eaa4d8ce0b0e674a2f32096094ef8c3b433b8ecd1ca9e7c98301a1191e7dc021a00028f04031a0bdc7cbda100818258202cfe7dc06bc2693c82924eba788fd107db77b7af8863e4b5b2e764c608ac51fe5840fe2fa453011406f3f0b812e9ff9c1901f4c02ec81748f84151acad220438ec65b89c1f415cec8c70857730da2712d9b8aea438cd76cc40b6a272558b72ff0004f5f6"
    static let signedID = "71fcd8583c44f5e94243f81bb9498d6479c311faf864e86ddd1653061619b6e5"

    static func data(_ name: String) throws -> Data { try ReaderFixtures.data("cardano", name) }

    static func firstAddress(_ body: StrictJSON?, _ key: String) -> String? {
        guard case .object(let fields)? = body, case .array(let list)? = fields[key], case .string(let text)? = list.first else { return nil }
        return text
    }

    /// As duas fontes respondendo com o gravado. `yoroiUTXOs` troca a resposta de moedas
    /// da Yoroi; `koiosMagic`, o network magic da genese.
    static func transport(
        yoroiUTXOs: (@Sendable (Data) throws -> Data)? = nil, yoroiParameters: (@Sendable (Data) throws -> Data)? = nil,
        koiosMagic: String? = nil, koiosUTXOsFail: Bool = false, submit: (@Sendable (ReaderRequest) throws -> Data)? = nil
    ) -> FixtureTransport {
        FixtureTransport([
            { request, body in
                guard request.url.host == "api.koios.rest" else { return nil }
                switch request.url.lastPathComponent {
                case "address_utxos":
                    if koiosUTXOsFail { throw HTTPClient.Failure.status(503) }
                    return try data(firstAddress(body, "_addresses") == owner ? "koios-address_utxos-dono" : "koios-address_utxos-tokens")
                case "tip": return try data("koios-tip")
                case "cli_protocol_params": return try data("koios-cli_protocol_params")
                case "genesis":
                    let genesis = try data("koios-genesis")
                    guard let koiosMagic else { return genesis }
                    return Data(String(decoding: genesis, as: UTF8.self).replacingOccurrences(of: "764824073", with: koiosMagic).utf8)
                case "tx_status":
                    return try data(firstAddress(body, "_tx_hashes") == knownTx ? "koios-tx_status" : "koios-tx_status-nenhuma")
                case "address_txs": return try data("koios-address_txs-dono")
                case "tx_info": return try data("koios-tx_info-dono")
                case "submittx": return try submit?(request) ?? Data("\"\(signedID)\"".utf8)
                default: return nil
                }
            },
            { request, body in
                switch (request.url.host, request.url.lastPathComponent) {
                case ("api.yoroiwallet.com", "utxoForAddresses"):
                    let recorded = try data(firstAddress(body, "addresses") == owner ? "yoroi-utxoForAddresses-dono" : "yoroi-utxoForAddresses-tokens")
                    return try yoroiUTXOs?(recorded) ?? recorded
                case ("api.yoroiwallet.com", "bestblock"): return try data("yoroi-bestblock")
                case ("api.yoroiwallet.com", "status"):
                    return try data(firstAddress(body, "txHashes") == knownTx ? "yoroi-tx_status" : "yoroi-tx_status-nenhuma")
                case ("api.yoroiwallet.com", "signed"): return try submit?(request) ?? Data("[]".utf8)
                case ("zero.yoroiwallet.com", "protocolparameters"):
                    let recorded = try data("yoroi-protocolparameters")
                    return try yoroiParameters?(recorded) ?? recorded
                default: return nil
                }
            },
        ])
    }

    static func reader(_ transport: FixtureTransport) -> CardanoReader {
        CardanoReader(transport: transport, pacing: 0)
    }

    static func replacing(_ data: Data, _ old: String, _ new: String) -> Data {
        Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: old, with: new).utf8)
    }
}

@Suite("Cardano: leitor, com respostas gravadas")
struct CardanoReaderTests {
    @Test("Estado do envio: moedas, parametros e ponta concordando nas duas fontes; endereco so no corpo")
    func spendState() async throws {
        let transport = CardanoRecorded.transport()
        let state = try await CardanoRecorded.reader(transport).spendState(owner: CardanoRecorded.owner)
        #expect(state.utxos.count == 2)
        #expect(Set(state.utxos.map(\.lovelace)) == [710_782_414, 562_456_215])
        #expect(state.utxos.allSatisfy { $0.isPlainADA })
        #expect(state.parameters == CardanoProtocolParameters(minFeeA: 44, minFeeB: 155_381, coinsPerUTxOByte: 4_310, maxTxSize: 16_384))
        #expect(state.tipSlot == CardanoRecorded.tip)
        #expect(transport.requests.allSatisfy { !$0.url.absoluteString.contains("addr1") })
        #expect(Set(transport.requests.compactMap(\.url.host)) == ["api.koios.rest", "api.yoroiwallet.com", "zero.yoroiwallet.com"])
    }

    @Test("A mesma moeda com valor diferente nas duas fontes e recusa")
    func valueDisagreement() async throws {
        let transport = CardanoRecorded.transport(yoroiUTXOs: { CardanoRecorded.replacing($0, "710782414", "710782415") })
        await #expect(throws: ReaderError.providersDisagree(field: "utxo")) {
            try await CardanoRecorded.reader(transport).spendState(owner: CardanoRecorded.owner)
        }
    }

    @Test("Parametros diferentes nas duas fontes e recusa")
    func parameterDisagreement() async throws {
        let transport = CardanoRecorded.transport(yoroiParameters: { CardanoRecorded.replacing($0, "\"coefficient\": \"44\"", "\"coefficient\": \"45\"") })
        await #expect(throws: ReaderError.providersDisagree(field: "parameters")) {
            try await CardanoRecorded.reader(transport).spendState(owner: CardanoRecorded.owner)
        }
    }

    @Test("Moeda que so uma fonte lista fica de fora, depois de reler uma vez")
    func intersection() async throws {
        let transport = CardanoRecorded.transport(yoroiUTXOs: { recorded in
            guard case .array(let rows) = try StrictJSON.parse(recorded) else { return recorded }
            return StrictJSON.array(Array(rows.prefix(1))).serialized
        })
        let state = try await CardanoRecorded.reader(transport).spendState(owner: CardanoRecorded.owner)
        #expect(state.utxos.count == 1)
        #expect(transport.requests.filter { $0.url.lastPathComponent == "utxoForAddresses" }.count == 2)
    }

    @Test("Resposta de outra conta, e Koios de outra rede, sao recusadas")
    func mismatches() async throws {
        let wrongOwner = CardanoRecorded.transport(yoroiUTXOs: { CardanoRecorded.replacing($0, CardanoRecorded.owner, CardanoRecorded.tokens) })
        await #expect(throws: ReaderError.responseMismatch(field: "receiver")) {
            try await CardanoRecorded.reader(wrongOwner).spendState(owner: CardanoRecorded.owner)
        }
        let preprod = CardanoRecorded.transport(koiosMagic: "1")
        await #expect(throws: ReaderError.wrongNetwork) {
            try await CardanoRecorded.reader(preprod).spendState(owner: CardanoRecorded.owner)
        }
        await #expect(throws: ReaderError.invalidInput("endereco")) {
            try await CardanoRecorded.reader(CardanoRecorded.transport()).spendState(owner: "0x52908400098527886E0F7030069857D2E4169EE7")
        }
    }

    @Test("Saldo da tela: ADA total, com o que esta junto de tokens, e quantos tokens; Yoroi se a Koios falha")
    func displayBalance() async throws {
        let balance = try await CardanoRecorded.reader(CardanoRecorded.transport()).displayBalance(owner: CardanoRecorded.tokens)
        #expect(balance.holdings == [Holding(asset: .native(.cardano), amount: 9_458_295)])
        #expect(balance.unknownTokenCount == 2)
        let fallback = try await CardanoRecorded.reader(CardanoRecorded.transport(koiosUTXOsFail: true)).displayBalance(owner: CardanoRecorded.tokens)
        #expect(fallback.holdings == balance.holdings)
        #expect(fallback.unknownTokenCount == 2)
    }

    @Test("Acompanhamento: confirmada nas duas, desconhecida, vencida")
    func status() async throws {
        let reader = CardanoRecorded.reader(CardanoRecorded.transport())
        #expect(try await reader.status(of: CardanoRecorded.knownTx) == .confirmed(block: nil, confirmations: 109))
        let unknown = String(repeating: "0", count: 64)
        #expect(try await reader.status(of: unknown) == .notFound)
        #expect(try await reader.status(of: unknown, validUntilSlot: CardanoRecorded.tip - 1) == .failed(reason: "expired"))
        #expect(try await reader.status(of: unknown, validUntilSlot: CardanoRecorded.tip + 900) == .notFound)
    }

    @Test("Transmissao: os mesmos bytes nas duas fontes, CBOR cru na Koios, id conferido")
    func broadcast() async throws {
        let raw = [UInt8](hex: CardanoRecorded.signedHex)!
        let signed = SignedTransaction(chainID: "cardano", raw: raw, encoded: CardanoRecorded.signedHex, id: CardanoRecorded.signedID)
        let transport = CardanoRecorded.transport()
        let receipt = try await CardanoRecorded.reader(transport).broadcast(signed)
        #expect(receipt.id == CardanoRecorded.signedID)
        #expect(Set(receipt.acceptedBy) == ["koios", "yoroi"])
        let koios = try #require(transport.requests.first { $0.url.lastPathComponent == "submittx" })
        #expect(koios.body == Data(raw))
        #expect(koios.headers["Content-Type"] == "application/cbor")
        let yoroi = try #require(transport.requests.first { $0.url.lastPathComponent == "signed" })
        #expect(yoroi.body == StrictJSON.object(["signedTx": .string(Data(raw).base64EncodedString())]).serialized)

        // As duas recusam: recusa com o codigo, sem texto do no.
        let refusing = CardanoRecorded.transport(submit: { _ in throw HTTPClient.Failure.status(400) })
        await #expect(throws: ReaderError.broadcastRejected(.other, code: "400")) {
            try await CardanoRecorded.reader(refusing).broadcast(signed)
        }
        // Id que nao e o hash do corpo: nada sai.
        let wrong = SignedTransaction(chainID: "cardano", raw: raw, encoded: "", id: CardanoRecorded.knownTx)
        await #expect(throws: ReaderError.broadcastMismatch) {
            try await CardanoRecorded.reader(CardanoRecorded.transport()).broadcast(wrong)
        }
    }

    @Test("Historico: a variacao de ADA do dono em cada transacao, a mais nova primeiro")
    func history() async throws {
        let page = try await CardanoRecorded.reader(CardanoRecorded.transport()).history(owner: CardanoRecorded.owner, limit: 5)
        #expect(page.items.count == 5)
        #expect(page.items.allSatisfy { $0.direction == .sent && $0.fee == 169_620 && $0.chainID == "cardano" })
        #expect(page.items.map(\.date) == page.items.map(\.date).sorted(by: >))
        let oldest = try #require(page.items.last)
        #expect(oldest.hash.hasPrefix("38bc5aaa3832"))
        // 2.467.463.317 entraram, 2.190.124.153 voltaram de troco, 169.620 de taxa.
        #expect(oldest.amount == 277_169_544)
        #expect(oldest.counterparty?.hasPrefix("addr1qxtrny8hx") == true)
        #expect(oldest.explorerURL?.absoluteString == "https://cardanoscan.io/transaction/\(oldest.hash)")
    }
}
