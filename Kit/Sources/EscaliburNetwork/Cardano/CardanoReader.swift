import EscaliburChains
import EscaliburCore
import Foundation

/// Leitura de estado, transmissao, acompanhamento e historico da Cardano, em duas fontes
/// independentes e sem chave (`Endpoints.cardanoKoios`, `cardanoYoroi`, `cardanoYoroiZero`):
/// a Koios, API comunitaria, e o backend da Yoroi, da Emurgo. Nenhuma outra fonte sem
/// chave foi achada em 27/09/2026 (Blockfrost, Maestro, Cardanoscan, NOWNodes e GetBlock
/// pedem chave).
///
/// O que decide o dinheiro vem das duas, concordando (docs/seguranca.md §5.5):
/// - as moedas do endereco do dono: entra no envio so a moeda que as duas listam, com o
///   mesmo valor, os mesmos tokens (ou nenhum) e o mesmo script de referencia (ou nenhum).
///   Mesma moeda com valor diferente e `providersDisagree`. Moeda que so uma lista (recem
///   chegada, ou ja gasta para a outra) fica de fora, depois de reler uma vez, 1,5 s
///   depois. Na Cardano as entradas precisam fechar exatamente com saidas e taxa: moeda
///   com valor errado faria a rede recusar, nunca pagar a mais;
/// - os parametros de taxa e de minimo por saida: iguais nas duas;
/// - a ponta da cadeia: as duas a ate 120 slots uma da outra; vale a menor.
///
/// Uma fonte so, com o motivo: o saldo da tela (exibicao; o plano rele nas duas) e o
/// historico (informativo, da Koios, que tem a transacao inteira).
///
/// A rede principal e conferida uma vez na Koios (`/genesis`, network magic 764824073);
/// na Yoroi, pela ponta, que o planejador compara com o relogio pela contagem de slots da
/// rede principal, e pelos enderecos das moedas, que tem de ser o perguntado.
public actor CardanoReader {
    public static let shared = CardanoReader()

    /// Network magic da rede principal (genese Shelley).
    static let mainnetMagic = "764824073"
    /// Mais moedas que isso e a leitura recusa: a comparacao precisa da lista inteira, e a
    /// Koios pagina em 1.000.
    static let maxUTXOs = 500
    static let tipTolerance: UInt64 = 120

    let transport: ReaderTransport
    let koios: URL
    let yoroi: URL
    let yoroiZero: URL
    private var mainnetVerified = false

    public init(
        transport: ReaderTransport = HTTPClient.shared,
        koios: URL = Endpoints.cardanoKoios, yoroi: URL = Endpoints.cardanoYoroi, yoroiZero: URL = Endpoints.cardanoYoroiZero,
        pacing: TimeInterval = 0.25
    ) {
        // A camada publica da Koios limita por IP (5.000 por dia); a da Yoroi nao publica
        // numero. Um quarto de segundo entre chamadas ao mesmo host, e o 429 repete uma vez.
        let hosts = [koios, yoroi, yoroiZero].compactMap(\.host)
        self.transport = PacedTransport(base: transport, intervals: Dictionary(hosts.map { ($0, pacing) }, uniquingKeysWith: { a, _ in a }))
        self.koios = koios
        self.yoroi = yoroi
        self.yoroiZero = yoroiZero
    }

    // MARK: Estado para o plano

    /// Moedas, parametros e ponta, nas duas fontes.
    public func spendState(owner: String) async throws -> CardanoSpendState {
        let address = try Self.ownerAddress(owner)
        do {
            return try await readSpendState(address, requireSameSet: true)
        } catch ReaderError.providersDisagree(field: "utxos") {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return try await readSpendState(address, requireSameSet: false)
        }
    }

    private func readSpendState(_ owner: String, requireSameSet: Bool) async throws -> CardanoSpendState {
        async let koiosReading = koiosState(owner)
        async let yoroiReading = yoroiState(owner)
        return try Self.merge(try await koiosReading, try await yoroiReading, requireSameSet: requireSameSet)
    }

    struct Reading: Equatable, Sendable {
        let utxos: [CardanoUTXO]
        let parameters: CardanoProtocolParameters
        let tipSlot: UInt64
    }

    static func merge(_ a: Reading, _ b: Reading, requireSameSet: Bool) throws -> CardanoSpendState {
        guard a.parameters == b.parameters else { throw ReaderError.providersDisagree(field: "parameters") }
        let (low, high) = (min(a.tipSlot, b.tipSlot), max(a.tipSlot, b.tipSlot))
        guard high - low <= tipTolerance else { throw ReaderError.providersDisagree(field: "tip") }
        let other = Dictionary(b.utxos.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        var agreed: [CardanoUTXO] = []
        for utxo in a.utxos {
            guard let twin = other[key(utxo)] else { continue }
            guard twin == utxo else { throw ReaderError.providersDisagree(field: "utxo") }
            agreed.append(utxo)
        }
        if requireSameSet, agreed.count != a.utxos.count || agreed.count != b.utxos.count {
            throw ReaderError.providersDisagree(field: "utxos")
        }
        return CardanoSpendState(utxos: agreed, parameters: a.parameters, tipSlot: low)
    }

    static func key(_ utxo: CardanoUTXO) -> String { "\(utxo.transactionID):\(utxo.index)" }

    private func koiosState(_ owner: String) async throws -> Reading {
        try await ensureMainnet()
        async let utxos = transport.send(Self.koiosUTXORequest(koios, owner))
        async let tip = transport.send(.get(koios.adding(path: "tip")))
        async let parameters = transport.send(.get(koios.adding(path: "cli_protocol_params")))
        return Reading(
            utxos: try Self.parseKoiosUTXOs(try await utxos, owner: owner),
            parameters: try Self.parseKoiosParameters(try await parameters),
            tipSlot: try Self.parseKoiosTip(try await tip)
        )
    }

    private func yoroiState(_ owner: String) async throws -> Reading {
        async let utxos = transport.send(Self.yoroiUTXORequest(yoroi, owner))
        async let tip = transport.send(.get(yoroi.adding(path: "v2/bestblock")))
        async let parameters = transport.send(.get(yoroiZero.adding(path: "protocolparameters")))
        return Reading(
            utxos: try Self.parseYoroiUTXOs(try await utxos, owner: owner),
            parameters: try Self.parseYoroiParameters(try await parameters),
            tipSlot: try Self.parseYoroiTip(try await tip)
        )
    }

    /// Uma vez: a Koios esta na rede principal.
    private func ensureMainnet() async throws {
        guard !mainnetVerified else { return }
        let genesis = try StrictJSON.parse(try await transport.send(.get(koios.adding(path: "genesis"))))
        guard let first = try genesis.array("genesis").first,
              try first.field("networkmagic", "genesis.networkmagic").string("genesis.networkmagic") == Self.mainnetMagic
        else { throw ReaderError.wrongNetwork }
        mainnetVerified = true
    }

    // MARK: Saldo da tela

    /// ADA total do endereco (inclusive o que esta junto de tokens) e quantos tokens
    /// diferentes chegaram, escondidos por padrao. Koios, e a Yoroi se ela falhar.
    public func displayBalance(owner text: String) async throws -> ChainBalance {
        let owner = try Self.ownerAddress(text)
        let (utxos, tokens) = try await displayReading(owner)
        let total = utxos.reduce(BigUInt(0)) { $0 + BigUInt($1.lovelace) }
        return ChainBalance(
            chainID: Chain.cardano.id, holdings: [Holding(asset: .native(.cardano), amount: total)],
            accountExists: true, unknownTokenCount: tokens, fetchedAt: .now
        )
    }

    private func displayReading(_ owner: String) async throws -> ([CardanoUTXO], Int) {
        do {
            let data = try await transport.send(Self.koiosUTXORequest(koios, owner))
            return (try Self.parseKoiosUTXOs(data, owner: owner), try Self.tokenKinds(koios: data))
        } catch {
            let data = try await transport.send(Self.yoroiUTXORequest(yoroi, owner))
            return (try Self.parseYoroiUTXOs(data, owner: owner), try Self.tokenKinds(yoroi: data))
        }
    }

    // MARK: Transmissao e acompanhamento

    /// Os mesmos bytes para as duas fontes. Aceita se uma aceitou; o id e o calculado aqui
    /// (hash do corpo), e o que a fonte devolver tem de ser ele.
    public func broadcast(_ signed: SignedTransaction) async throws -> BroadcastReceipt {
        guard signed.chainID == Chain.cardano.id, let parsed = try? CardanoSignedTransaction.parse(signed.raw),
              Hex.encode(parsed.body.hash) == signed.id
        else { throw ReaderError.broadcastMismatch }
        let id = signed.id
        let raw = Data(signed.raw)
        let koiosRequest = ReaderRequest(method: .post, url: koios.adding(path: "submittx"), body: raw, headers: ["Content-Type": "application/cbor"], timeout: 30)
        let yoroiRequest = ReaderRequest(
            method: .post, url: yoroi.adding(path: "txs/signed"),
            body: StrictJSON.object(["signedTx": .string(raw.base64EncodedString())]).serialized, timeout: 30
        )
        async let koiosAnswer = submit(koiosRequest, id: id)
        async let yoroiAnswer = submit(yoroiRequest, id: id)
        var tally = BroadcastTally()
        tally.add(await koiosAnswer, provider: ProviderPool.Provider(name: "koios", baseURL: koios))
        tally.add(await yoroiAnswer, provider: ProviderPool.Provider(name: "yoroi", baseURL: yoroi))
        return try tally.receipt(chainID: Chain.cardano.id, id: id)
    }

    private func submit(_ request: ReaderRequest, id: String) async -> Result<String, Error> {
        do {
            let data = try await transport.send(request)
            guard Self.submissionMatches(data, id: id) else { return .failure(ReaderError.broadcastMismatch) }
            return .success(id)
        } catch HTTPClient.Failure.status(let code) where (400..<500).contains(code) && code != 429 {
            // O no recusou (entrada gasta, taxa, validade). O corpo com o motivo nao chega
            // aqui, e nem deveria: pode trazer endereco e valor.
            return .failure(ReaderError.broadcastRejected(.other, code: String(code)))
        } catch {
            return .failure(error)
        }
    }

    /// A transacao pelo id, nas duas fontes. Confirmada com as duas vendo ela num bloco.
    /// Nenhuma vendo, e a ponta das duas ja depois de `validUntilSlot`: vencida, a rede
    /// nao aceita mais.
    public func status(of id: String, validUntilSlot: UInt64? = nil) async throws -> TransactionStatus {
        guard id.count == 64, Hex.decode(id) != nil else { throw ReaderError.invalidInput("id") }
        async let koiosDepth = transport.send(Self.koiosStatusRequest(koios, id))
        async let yoroiDepth = transport.send(Self.yoroiStatusRequest(yoroi, id))
        let a = try Self.parseKoiosStatus(try await koiosDepth, id: id)
        let b = try Self.parseYoroiStatus(try await yoroiDepth, id: id)
        switch (a, b) {
        case (.some(let x), .some(let y)) where x > 0 && y > 0:
            return .confirmed(block: nil, confirmations: min(x, y))
        case (.some, _), (_, .some):
            return .pending
        case (.none, .none):
            if let validUntilSlot, try await currentTip() > validUntilSlot { return .failed(reason: "expired") }
            return .notFound
        }
    }

    /// A ponta nas duas fontes; vale a menor.
    public func currentTip() async throws -> UInt64 {
        async let a = transport.send(.get(koios.adding(path: "tip")))
        async let b = transport.send(.get(yoroi.adding(path: "v2/bestblock")))
        return min(try Self.parseKoiosTip(try await a), try Self.parseYoroiTip(try await b))
    }

    // MARK: Historico

    /// As ultimas transacoes do endereco, pela Koios, com a variacao de ADA do dono em
    /// cada uma. Informativo.
    public func history(owner text: String, limit: Int = 25) async throws -> ActivityPage {
        let owner = try Self.ownerAddress(text)
        let listURL = koios.adding(path: "address_txs").adding(query: [("limit", String(limit)), ("order", "block_height.desc")])
        let list = try StrictJSON.parse(try await transport.send(.post(listURL, .object(["_addresses": .array([.string(owner)])]))))
        let hashes = try list.array("address_txs").map { try $0.field("tx_hash", "tx_hash").string("tx_hash") }
        guard !hashes.isEmpty else { return ActivityPage(chainID: Chain.cardano.id, items: [], suspicious: SuspiciousSummary()) }
        let details = try await transport.send(.post(koios.adding(path: "tx_info"), .object([
            "_tx_hashes": .array(hashes.map { .string($0) }), "_inputs": .bool(true),
        ])))
        return try Self.parseHistory(details, owner: owner, complete: hashes.count < limit)
    }

    // MARK: Pedidos

    static func koiosUTXORequest(_ base: URL, _ owner: String) -> ReaderRequest {
        .post(base.adding(path: "address_utxos"), .object(["_addresses": .array([.string(owner)]), "_extended": .bool(true)]))
    }

    static func yoroiUTXORequest(_ base: URL, _ owner: String) -> ReaderRequest {
        .post(base.adding(path: "txs/utxoForAddresses"), .object(["addresses": .array([.string(owner)])]))
    }

    static func koiosStatusRequest(_ base: URL, _ id: String) -> ReaderRequest {
        .post(base.adding(path: "tx_status"), .object(["_tx_hashes": .array([.string(id)])]))
    }

    static func yoroiStatusRequest(_ base: URL, _ id: String) -> ReaderRequest {
        .post(base.adding(path: "tx/status"), .object(["txHashes": .array([.string(id)])]))
    }

    // MARK: Leitura das respostas

    /// O endereco do dono, na forma canonica. Nunca vai em URL.
    static func ownerAddress(_ text: String) throws -> String {
        guard case .success(let address) = CardanoAddress.parse(text), address.type == 0 else {
            throw ReaderError.invalidInput("endereco")
        }
        return address.bech32
    }

    static func parseKoiosUTXOs(_ data: Data, owner: String) throws -> [CardanoUTXO] {
        let rows = try StrictJSON.parse(data).array("address_utxos")
        guard rows.count <= maxUTXOs else { throw ReaderError.unsupported("muitas moedas") }
        var out: [CardanoUTXO] = []
        for row in rows {
            if let spent = row.optionalField("is_spent"), try spent.bool("is_spent") { continue }
            guard try row.field("address", "address").string("address") == owner else { throw ReaderError.responseMismatch(field: "address") }
            out.append(CardanoUTXO(
                transactionID: try hash(row.field("tx_hash", "tx_hash")),
                index: try row.field("tx_index", "tx_index").uint32("tx_index"),
                lovelace: try lovelace(row.field("value", "value")),
                hasTokens: !(try row.field("asset_list", "asset_list").array("asset_list")).isEmpty,
                hasReferenceScript: row.optionalField("reference_script") != nil
            ))
        }
        return out.sorted { key($0) < key($1) }
    }

    static func parseYoroiUTXOs(_ data: Data, owner: String) throws -> [CardanoUTXO] {
        let rows = try StrictJSON.parse(data).array("utxoForAddresses")
        guard rows.count <= maxUTXOs else { throw ReaderError.unsupported("muitas moedas") }
        return try rows.map { row in
            guard try row.field("receiver", "receiver").string("receiver") == owner else { throw ReaderError.responseMismatch(field: "receiver") }
            return CardanoUTXO(
                transactionID: try hash(row.field("tx_hash", "tx_hash")),
                index: try row.field("tx_index", "tx_index").uint32("tx_index"),
                lovelace: try lovelace(row.field("amount", "amount")),
                hasTokens: !(try row.field("assets", "assets").array("assets")).isEmpty,
                hasReferenceScript: row.optionalField("script_ref") != nil
            )
        }.sorted { key($0) < key($1) }
    }

    static func tokenKinds(koios data: Data) throws -> Int {
        var kinds = Set<String>()
        for row in try StrictJSON.parse(data).array("address_utxos") {
            for asset in try row.field("asset_list", "asset_list").array("asset_list") {
                let policy = try asset.field("policy_id", "policy_id").string("policy_id")
                let name = try asset.field("asset_name", "asset_name").string("asset_name")
                kinds.insert(policy + name)
            }
        }
        return kinds.count
    }

    static func tokenKinds(yoroi data: Data) throws -> Int {
        var kinds = Set<String>()
        for row in try StrictJSON.parse(data).array("utxoForAddresses") {
            for asset in try row.field("assets", "assets").array("assets") {
                kinds.insert(try asset.field("assetId", "assetId").string("assetId"))
            }
        }
        return kinds.count
    }

    static func parseKoiosParameters(_ data: Data) throws -> CardanoProtocolParameters {
        let json = try StrictJSON.parse(data)
        return CardanoProtocolParameters(
            minFeeA: try json.field("txFeePerByte", "txFeePerByte").uint64("txFeePerByte"),
            minFeeB: try json.field("txFeeFixed", "txFeeFixed").uint64("txFeeFixed"),
            coinsPerUTxOByte: try json.field("utxoCostPerByte", "utxoCostPerByte").uint64("utxoCostPerByte"),
            maxTxSize: try json.field("maxTxSize", "maxTxSize").uint64("maxTxSize")
        )
    }

    static func parseYoroiParameters(_ data: Data) throws -> CardanoProtocolParameters {
        let json = try StrictJSON.parse(data)
        let fee = try json.field("linearFee", "linearFee")
        return CardanoProtocolParameters(
            minFeeA: try decimal(fee.field("coefficient", "linearFee.coefficient"), "linearFee.coefficient"),
            minFeeB: try decimal(fee.field("constant", "linearFee.constant"), "linearFee.constant"),
            coinsPerUTxOByte: try decimal(json.field("coinsPerUtxoByte", "coinsPerUtxoByte"), "coinsPerUtxoByte"),
            maxTxSize: try decimal(json.field("maxTxSize", "maxTxSize"), "maxTxSize")
        )
    }

    static func parseKoiosTip(_ data: Data) throws -> UInt64 {
        guard let first = try StrictJSON.parse(data).array("tip").first else { throw ReaderError.malformed(field: "tip") }
        return try first.field("abs_slot", "tip.abs_slot").uint64("tip.abs_slot")
    }

    static func parseYoroiTip(_ data: Data) throws -> UInt64 {
        try StrictJSON.parse(data).field("globalSlot", "bestblock.globalSlot").uint64("bestblock.globalSlot")
    }

    /// Confirmacoes na Koios; nil quando ela nao conhece a transacao.
    static func parseKoiosStatus(_ data: Data, id: String) throws -> UInt64? {
        let rows = try StrictJSON.parse(data).array("tx_status")
        guard rows.count == 1, try rows[0].field("tx_hash", "tx_hash").string("tx_hash") == id else {
            throw ReaderError.responseMismatch(field: "tx_hash")
        }
        return try rows[0].optionalField("num_confirmations")?.uint64("num_confirmations")
    }

    /// Profundidade na Yoroi; nil quando ela nao conhece a transacao.
    static func parseYoroiStatus(_ data: Data, id: String) throws -> UInt64? {
        let depth = try StrictJSON.parse(data).field("depth", "depth").object("depth")
        guard depth.keys.allSatisfy({ $0 == id }) else { throw ReaderError.responseMismatch(field: "depth") }
        return try depth[id].map { try $0.uint64("depth") }
    }

    /// A resposta da transmissao: a Koios devolve o id em texto JSON, a Yoroi `[]` ou
    /// `{"txId": ...}`. Um id diferente do calculado aqui e recusa.
    static func submissionMatches(_ data: Data, id: String) -> Bool {
        guard !data.isEmpty, let json = try? StrictJSON.parse(data) else { return true }
        switch json {
        case .string(let text): return text.lowercased() == id
        case .object(let fields):
            guard let value = fields["txId"] else { return true }
            if case .string(let text) = value { return text.lowercased() == id }
            return false
        default: return true
        }
    }

    static func parseHistory(_ data: Data, owner: String, complete: Bool) throws -> ActivityPage {
        var items: [ActivityItem] = []
        for tx in try StrictJSON.parse(data).array("tx_info") {
            let hash = try hash(tx.field("tx_hash", "tx_hash"))
            var spent: UInt64 = 0
            var received: UInt64 = 0
            var firstForeignInput: String?
            var firstForeignOutput: String?
            for input in try tx.field("inputs", "inputs").array("inputs") {
                let address = try input.field("payment_addr", "payment_addr").field("bech32", "payment_addr.bech32").string("payment_addr.bech32")
                let value = try lovelace(input.field("value", "value"))
                if address == owner { spent += value } else if firstForeignInput == nil { firstForeignInput = address }
            }
            for output in try tx.field("outputs", "outputs").array("outputs") {
                let address = try output.field("payment_addr", "payment_addr").field("bech32", "payment_addr.bech32").string("payment_addr.bech32")
                let value = try lovelace(output.field("value", "value"))
                if address == owner { received += value } else if firstForeignOutput == nil { firstForeignOutput = address }
            }
            let fee = try lovelace(tx.field("fee", "fee"))
            let time = try tx.field("tx_timestamp", "tx_timestamp").uint64("tx_timestamp")
            let direction: ActivityItem.Direction
            let amount: UInt64
            let counterparty: String?
            if spent > received {
                // Saiu: o que foi para fora, sem a taxa.
                let net = spent - received
                direction = firstForeignOutput == nil ? .other : .sent
                amount = net > fee ? net - fee : 0
                counterparty = firstForeignOutput
            } else {
                direction = received == 0 ? .other : .received
                amount = received - spent
                counterparty = firstForeignInput
            }
            guard !(direction == .received && amount == 0) else { continue }
            items.append(ActivityItem(
                id: hash, chainID: Chain.cardano.id, direction: direction, asset: .native(.cardano), amount: BigUInt(amount),
                counterparty: counterparty, date: Date(timeIntervalSince1970: TimeInterval(time)), status: .confirmed,
                fee: spent == 0 ? nil : BigUInt(fee), hash: hash, explorerURL: Chain.cardano.explorerURL(tx: hash)
            ))
        }
        return ActivityPage(chainID: Chain.cardano.id, items: items, suspicious: SuspiciousSummary(), isComplete: complete)
    }

    static func hash(_ value: StrictJSON) throws -> String {
        let text = try value.string("tx_hash")
        guard text.count == 64, Hex.decode(text) != nil else { throw ReaderError.malformed(field: "tx_hash") }
        return text.lowercased()
    }

    /// Lovelace em texto decimal (as duas fontes mandam assim), cabendo em 64 bits.
    static func lovelace(_ value: StrictJSON) throws -> UInt64 {
        guard let amount = try value.decimalString("lovelace").uint64 else { throw ReaderError.implausibleValue(field: "lovelace") }
        return amount
    }

    static func decimal(_ value: StrictJSON, _ path: String) throws -> UInt64 {
        guard let amount = try value.decimalString(path).uint64 else { throw ReaderError.implausibleValue(field: path) }
        return amount
    }
}
