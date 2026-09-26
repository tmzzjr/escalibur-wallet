import EscaliburChains
import EscaliburCore
import Foundation

// Os tres formatos de API que as redes UTXO usam, atras de uma interface so.
//
// - Esplora (mempool.space, blockstream.info, mempool.emzy.de, litecoinspace.org):
//   a API completa, com transacao crua, historico por endereco e transmissao em texto.
// - Blockcypher (Dogecoin e segunda fonte do Litecoin): referencias por endereco,
//   transacao crua com `includeHex`, taxa em tres niveis por kB.
// - Blockchair (Dogecoin e terceira fonte do Litecoin): painel por endereco, transacao
//   crua, taxa sugerida unica. Sem chave de API o limite por IP e baixo e o bloqueio
//   temporario (HTTP 430) e comum: fica por ultimo na ordem.
//
// Cada metodo devolve dado bruto do provedor, ja com o formato conferido. Quem decide
// o que vale (txid contra os bytes, script contra a chave derivada) e o UTXOReader.

enum UTXOBackend: Equatable, Sendable {
    /// `blockstream` so muda a fonte de taxa (`/fee-estimates` em vez de `/v1/fees`).
    case esplora(blockstream: Bool)
    case blockcypher
    case blockchair

    static func of(_ provider: ProviderPool.Provider) -> UTXOBackend {
        switch provider.name {
        case "blockcypher": return .blockcypher
        case "blockchair": return .blockchair
        case "blockstream": return .esplora(blockstream: true)
        default: return .esplora(blockstream: false)
        }
    }
}

/// Uma moeda como o provedor anuncia: so a pista de onde procurar. O valor anunciado
/// serve para comparar com o conferido, nunca para gastar.
struct UTXOUnspentClaim: Sendable, Equatable {
    let outpoint: UTXOOutpoint
    let claimedValue: UInt64
    /// nil: na mempool.
    let height: UInt32?
}

/// Taxa de uma fonte. `levels` nil quando a fonte so da um numero (Blockchair).
struct UTXOFeeQuote: Sendable, Equatable {
    let source: String
    let fastest: UTXOFeeRate
    let levels: (slow: UTXOFeeRate, normal: UTXOFeeRate, fast: UTXOFeeRate)?

    static func == (a: UTXOFeeQuote, b: UTXOFeeQuote) -> Bool {
        a.source == b.source && a.fastest == b.fastest && a.levels?.slow == b.levels?.slow
            && a.levels?.normal == b.levels?.normal && a.levels?.fast == b.levels?.fast
    }
}

/// Uma pagina de historico de um endereco.
enum UTXOHistoryPage: Sendable {
    /// Esplora: a transacao inteira, com o `prevout` de cada entrada.
    case full([EsploraTransaction])
    /// Blockcypher e Blockchair: o efeito da transacao neste endereco.
    case deltas([UTXOAddressDelta])
}

struct UTXOAddressDelta: Sendable, Equatable {
    let txid: String
    let height: UInt32?
    let date: Date?
    let received: UInt64
    let spent: UInt64
}

// MARK: Esplora

struct EsploraStatus: Decodable, Sendable, Equatable {
    let confirmed: Bool
    let blockHeight: UInt32?
    let blockTime: UInt64?

    enum CodingKeys: String, CodingKey {
        case confirmed
        case blockHeight = "block_height"
        case blockTime = "block_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        confirmed = try c.decode(Bool.self, forKey: .confirmed)
        blockHeight = try c.decodeIfPresent(UInt32.self, forKey: .blockHeight)
        blockTime = try c.decodeIfPresent(UInt64.self, forKey: .blockTime)
        // Confirmada sem altura nao e confirmada.
        if confirmed, blockHeight == nil {
            throw DecodingError.keyNotFound(CodingKeys.blockHeight, .init(codingPath: c.codingPath, debugDescription: ""))
        }
    }
}

struct EsploraAddress: Decodable, Sendable {
    struct Stats: Decodable, Sendable {
        let txCount: UInt64
        enum CodingKeys: String, CodingKey { case txCount = "tx_count" }
    }

    let address: String
    let chainStats: Stats
    let mempoolStats: Stats

    enum CodingKeys: String, CodingKey {
        case address
        case chainStats = "chain_stats"
        case mempoolStats = "mempool_stats"
    }
}

struct EsploraUnspent: Decodable, Sendable {
    let txid: String
    let vout: UInt32
    let value: UInt64
    let status: EsploraStatus
}

struct EsploraTransaction: Decodable, Sendable {
    struct Output: Decodable, Sendable {
        let scriptpubkey: String
        let scriptpubkeyAddress: String?
        let value: UInt64
        enum CodingKeys: String, CodingKey {
            case scriptpubkey, value
            case scriptpubkeyAddress = "scriptpubkey_address"
        }
    }

    struct Input: Decodable, Sendable {
        let prevout: Output?
        let isCoinbase: Bool
        enum CodingKeys: String, CodingKey {
            case prevout
            case isCoinbase = "is_coinbase"
        }
    }

    let txid: String
    let vin: [Input]
    let vout: [Output]
    let fee: UInt64
    let status: EsploraStatus
}

struct EsploraMempoolFees: Decodable, Sendable {
    let fastestFee: Double
    let halfHourFee: Double
    let hourFee: Double
}

// MARK: Blockcypher

struct BlockcypherRef: Decodable, Sendable {
    let txHash: String
    let blockHeight: Int64
    let txInputN: Int64
    let txOutputN: Int64
    let value: UInt64
    let confirmed: String?
    let received: String?

    enum CodingKeys: String, CodingKey {
        case value, confirmed, received
        case txHash = "tx_hash"
        case blockHeight = "block_height"
        case txInputN = "tx_input_n"
        case txOutputN = "tx_output_n"
    }
}

struct BlockcypherAddress: Decodable, Sendable {
    let address: String
    let finalNTx: UInt64
    let txrefs: [BlockcypherRef]?
    let unconfirmedTxrefs: [BlockcypherRef]?

    enum CodingKeys: String, CodingKey {
        case address, txrefs
        case finalNTx = "final_n_tx"
        case unconfirmedTxrefs = "unconfirmed_txrefs"
    }
}

struct BlockcypherTransaction: Decodable, Sendable {
    let hash: String
    let blockHeight: Int64
    let confirmations: UInt64
    let hex: String?

    enum CodingKeys: String, CodingKey {
        case hash, confirmations, hex
        case blockHeight = "block_height"
    }
}

struct BlockcypherChain: Decodable, Sendable {
    let height: UInt32
    let highFeePerKb: UInt64
    let mediumFeePerKb: UInt64
    let lowFeePerKb: UInt64

    enum CodingKeys: String, CodingKey {
        case height
        case highFeePerKb = "high_fee_per_kb"
        case mediumFeePerKb = "medium_fee_per_kb"
        case lowFeePerKb = "low_fee_per_kb"
    }
}

struct BlockcypherPush: Decodable, Sendable {
    struct Tx: Decodable, Sendable { let hash: String }
    let tx: Tx
}

// MARK: Blockchair

struct BlockchairAddressDashboard: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        struct Summary: Decodable, Sendable {
            let transactionCount: UInt64
            enum CodingKeys: String, CodingKey { case transactionCount = "transaction_count" }
        }
        struct Transaction: Decodable, Sendable {
            let blockId: Int64
            let hash: String
            let time: String
            let balanceChange: Int64
            enum CodingKeys: String, CodingKey {
                case hash, time
                case blockId = "block_id"
                case balanceChange = "balance_change"
            }
        }
        struct Unspent: Decodable, Sendable {
            let blockId: Int64
            let transactionHash: String
            let index: UInt32
            let value: UInt64
            enum CodingKeys: String, CodingKey {
                case index, value
                case blockId = "block_id"
                case transactionHash = "transaction_hash"
            }
        }

        let address: Summary
        let transactions: [Transaction]
        let utxo: [Unspent]
    }

    let data: [String: Entry]
}

struct BlockchairRaw: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let rawTransaction: String
        enum CodingKeys: String, CodingKey { case rawTransaction = "raw_transaction" }
    }
    let data: [String: Entry]
}

struct BlockchairTransactionDashboard: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        struct Transaction: Decodable, Sendable {
            let blockId: Int64
            enum CodingKeys: String, CodingKey { case blockId = "block_id" }
        }
        let transaction: Transaction
    }

    /// `nil` quando o provedor responde `"data": []` (transacao desconhecida).
    let data: [String: Entry]?

    enum CodingKeys: String, CodingKey { case data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let empty = try? c.decode([Int].self, forKey: .data), empty.isEmpty {
            data = nil
        } else {
            data = try c.decode([String: Entry].self, forKey: .data)
        }
    }
}

struct BlockchairStats: Decodable, Sendable {
    struct Data: Decodable, Sendable {
        let bestBlockHeight: UInt32
        let suggestedTransactionFeePerByteSat: UInt64
        enum CodingKeys: String, CodingKey {
            case bestBlockHeight = "best_block_height"
            case suggestedTransactionFeePerByteSat = "suggested_transaction_fee_per_byte_sat"
        }
    }
    let data: Data
}

struct BlockchairPush: Decodable, Sendable {
    struct Data: Decodable, Sendable {
        let transactionHash: String
        enum CodingKeys: String, CodingKey { case transactionHash = "transaction_hash" }
    }
    let data: Data
}

// MARK: Cliente de um provedor

/// Um provedor UTXO, falando o dialeto dele.
struct UTXOProviderClient: Sendable {
    let provider: ProviderPool.Provider
    let transport: ChainReaderTransport

    var backend: UTXOBackend { UTXOBackend.of(provider) }

    private func url(_ path: String, _ query: [URLQueryItem] = []) throws -> URL {
        try ReaderURL.make(provider.baseURL, path, query: query)
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        try ReaderDecode.json(T.self, from: try await transport.fetch(try url(path, query)))
    }

    // MARK: Historico por endereco

    /// Quantas transacoes o endereco tem (confirmadas e na mempool). So o numero:
    /// e o que a varredura por gap limit precisa.
    func transactionCount(_ address: String) async throws -> UInt64 {
        switch backend {
        case .esplora:
            let info = try await get(EsploraAddress.self, "address/\(address)")
            guard info.address == address else { throw ChainReaderError.mismatchedResponse }
            return info.chainStats.txCount + info.mempoolStats.txCount
        case .blockcypher:
            let info = try await get(BlockcypherAddress.self, "addrs/\(address)", [URLQueryItem(name: "limit", value: "1")])
            guard info.address == address else { throw ChainReaderError.mismatchedResponse }
            return info.finalNTx
        case .blockchair:
            let entry = try await blockchairAddress(address, transactions: 1, unspent: 1)
            return entry.address.transactionCount
        }
    }

    private func blockchairAddress(_ address: String, transactions: Int, unspent: Int) async throws -> BlockchairAddressDashboard.Entry {
        let dashboard = try await get(
            BlockchairAddressDashboard.self, "dashboards/address/\(address)",
            [URLQueryItem(name: "limit", value: "\(transactions),\(unspent)"), URLQueryItem(name: "transaction_details", value: "true")]
        )
        guard dashboard.data.count == 1, let entry = dashboard.data[address] else { throw ChainReaderError.mismatchedResponse }
        return entry
    }

    // MARK: Moedas

    func unspent(_ address: String) async throws -> [UTXOUnspentClaim] {
        switch backend {
        case .esplora:
            let list = try await get([EsploraUnspent].self, "address/\(address)/utxo")
            return try list.map { item in
                UTXOUnspentClaim(
                    outpoint: UTXOOutpoint(txid: try ReaderDecode.txid(item.txid, field: "txid"), vout: item.vout),
                    claimedValue: item.value, height: item.status.confirmed ? item.status.blockHeight : nil
                )
            }
        case .blockcypher:
            let info = try await get(
                BlockcypherAddress.self, "addrs/\(address)",
                [URLQueryItem(name: "unspentOnly", value: "true"), URLQueryItem(name: "limit", value: "200")]
            )
            guard info.address == address else { throw ChainReaderError.mismatchedResponse }
            return try ((info.txrefs ?? []) + (info.unconfirmedTxrefs ?? [])).map { ref in
                guard ref.txOutputN >= 0, ref.txOutputN <= Int64(UInt32.max), ref.txInputN == -1 else {
                    throw ChainReaderError.malformedResponse(field: "txrefs.tx_output_n")
                }
                return UTXOUnspentClaim(
                    outpoint: UTXOOutpoint(txid: try ReaderDecode.txid(ref.txHash, field: "tx_hash"), vout: UInt32(ref.txOutputN)),
                    claimedValue: ref.value, height: try Self.height(ref.blockHeight)
                )
            }
        case .blockchair:
            let entry = try await blockchairAddress(address, transactions: 1, unspent: 500)
            return try entry.utxo.map { item in
                UTXOUnspentClaim(
                    outpoint: UTXOOutpoint(txid: try ReaderDecode.txid(item.transactionHash, field: "transaction_hash"), vout: item.index),
                    claimedValue: item.value, height: try Self.height(item.blockId)
                )
            }
        }
    }

    /// -1 e "na mempool" no Blockcypher e no Blockchair.
    static func height(_ value: Int64) throws -> UInt32? {
        if value == -1 { return nil }
        guard value >= 0, value < Int64(UTXORules.lockTimeThreshold) else { throw ChainReaderError.malformedResponse(field: "block_height") }
        return UInt32(value)
    }

    /// A transacao crua inteira. O txid dela e conferido por quem chama.
    func rawTransaction(_ txid: UTXOTxID) async throws -> [UInt8] {
        switch backend {
        case .esplora:
            let data = try await transport.fetch(try url("tx/\(txid.hex)/hex"))
            return try ReaderDecode.hexBytes(try ReaderDecode.text(data, field: "hex"), field: "hex")
        case .blockcypher:
            let tx = try await get(
                BlockcypherTransaction.self, "txs/\(txid.hex)",
                [URLQueryItem(name: "includeHex", value: "true"), URLQueryItem(name: "limit", value: "1")]
            )
            guard let hex = tx.hex else { throw ChainReaderError.malformedResponse(field: "hex") }
            return try ReaderDecode.hexBytes(hex, field: "hex")
        case .blockchair:
            let raw = try await get(BlockchairRaw.self, "raw/transaction/\(txid.hex)")
            guard raw.data.count == 1, let entry = raw.data[txid.hex] else { throw ChainReaderError.mismatchedResponse }
            return try ReaderDecode.hexBytes(entry.rawTransaction, field: "raw_transaction")
        }
    }

    // MARK: Rede

    func tipHeight() async throws -> UInt32 {
        let height: UInt64
        switch backend {
        case .esplora:
            let data = try await transport.fetch(try url("blocks/tip/height"))
            height = try ReaderDecode.unsigned(try ReaderDecode.text(data, field: "height"), field: "height")
        case .blockcypher:
            height = UInt64(try await get(BlockcypherChain.self, "").height)
        case .blockchair:
            height = UInt64(try await get(BlockchairStats.self, "stats").data.bestBlockHeight)
        }
        guard height > 0, height < UInt64(UTXORules.lockTimeThreshold) else { throw ChainReaderError.malformedResponse(field: "height") }
        return UInt32(height)
    }

    func fees() async throws -> UTXOFeeQuote {
        switch backend {
        case .esplora(blockstream: false):
            // `precise` da fracoes de sat/vB; alguns forks so tem `recommended`.
            let fees: EsploraMempoolFees
            if let precise = try? await get(EsploraMempoolFees.self, "v1/fees/precise") {
                fees = precise
            } else {
                fees = try await get(EsploraMempoolFees.self, "v1/fees/recommended")
            }
            let fast = try Self.rate(satPerVByte: fees.fastestFee)
            return UTXOFeeQuote(
                source: provider.name, fastest: fast,
                levels: (try Self.rate(satPerVByte: fees.hourFee), try Self.rate(satPerVByte: fees.halfHourFee), fast)
            )
        case .esplora(blockstream: true):
            // Alvo em blocos para sat/vB. 1 bloco (proximo), 3 (meia hora), 6 (uma hora),
            // os mesmos alvos do mempool.space.
            let targets = try await get([String: Double].self, "fee-estimates")
            func at(_ blocks: Int) throws -> UTXOFeeRate {
                guard let value = targets[String(blocks)] else { throw ChainReaderError.malformedResponse(field: String(blocks)) }
                return try Self.rate(satPerVByte: value)
            }
            let fast = try at(1)
            return UTXOFeeQuote(source: provider.name, fastest: fast, levels: (try at(6), try at(3), fast))
        case .blockcypher:
            // Por 1000 bytes, nao vbytes. No Dogecoin e o mesmo; no Litecoin segwit
            // superestima um pouco, o que so sobe o teto.
            let chain = try await get(BlockcypherChain.self, "")
            let fast = try Self.rate(satPerKvB: chain.highFeePerKb)
            return UTXOFeeQuote(
                source: provider.name, fastest: fast,
                levels: (try Self.rate(satPerKvB: chain.lowFeePerKb), try Self.rate(satPerKvB: chain.mediumFeePerKb), fast)
            )
        case .blockchair:
            let stats = try await get(BlockchairStats.self, "stats")
            let (perKvB, overflow) = stats.data.suggestedTransactionFeePerByteSat.multipliedReportingOverflow(by: 1000)
            guard !overflow else { throw ChainReaderError.malformedResponse(field: "suggested_transaction_fee_per_byte_sat") }
            return UTXOFeeQuote(source: provider.name, fastest: try Self.rate(satPerKvB: perKvB), levels: nil)
        }
    }

    /// sat/vB fracionario (JSON) para sat/kvB inteiro. Arredonda para cima: abaixo
    /// da estimativa a transacao demora mais que o nivel prometido. O desconto de um
    /// milionesimo tira o ruido do ponto flutuante (3,303 x 1000 = 3303,0000000000005
    /// nao vira 3304).
    static func rate(satPerVByte value: Double) throws -> UTXOFeeRate {
        guard value.isFinite, value > 0, value < 1_000_000 else { throw ChainReaderError.malformedResponse(field: "fee") }
        return UTXOFeeRate(satPerKvB: max(1, UInt64((value * 1000 - 0.000_001).rounded(.up))))
    }

    static func rate(satPerKvB value: UInt64) throws -> UTXOFeeRate {
        guard value > 0 else { throw ChainReaderError.malformedResponse(field: "fee") }
        return UTXOFeeRate(satPerKvB: value)
    }

    // MARK: Transmissao

    /// Transmite o hex e devolve o txid que o provedor anunciou.
    func broadcast(hex: String) async throws -> String {
        switch backend {
        case .esplora:
            let data = try await transport.send(try url("tx"), body: Data(hex.utf8), contentType: "text/plain", timeout: 15)
            return try ReaderDecode.text(data, field: "txid")
        case .blockcypher:
            let body = try JSONEncoder().encode(["tx": hex])
            let data = try await transport.send(try url("txs/push"), body: body, contentType: "application/json", timeout: 15)
            return try ReaderDecode.json(BlockcypherPush.self, from: data).tx.hash
        case .blockchair:
            let data = try await transport.send(
                try url("push/transaction"), body: ReaderURL.formBody([("data", hex)]),
                contentType: "application/x-www-form-urlencoded", timeout: 15
            )
            return try ReaderDecode.json(BlockchairPush.self, from: data).data.transactionHash
        }
    }

    /// Onde a transacao esta. `tip` conta as confirmacoes quando o provedor so da a altura.
    func status(_ txid: UTXOTxID, tip: UInt32?) async throws -> ChainTransactionStatus {
        func confirmed(_ height: UInt32) -> ChainTransactionStatus {
            let confirmations = tip.flatMap { $0 >= height ? $0 - height + 1 : nil }
            return .confirmed(height: height, confirmations: confirmations)
        }
        do {
            switch backend {
            case .esplora:
                let status = try await get(EsploraStatus.self, "tx/\(txid.hex)/status")
                guard status.confirmed, let height = status.blockHeight else { return .pending }
                return confirmed(height)
            case .blockcypher:
                let tx = try await get(BlockcypherTransaction.self, "txs/\(txid.hex)", [URLQueryItem(name: "limit", value: "1")])
                guard tx.hash == txid.hex else { throw ChainReaderError.mismatchedResponse }
                guard let height = try Self.height(tx.blockHeight) else { return .pending }
                return confirmed(height)
            case .blockchair:
                let dashboard = try await get(BlockchairTransactionDashboard.self, "dashboards/transaction/\(txid.hex)")
                guard let data = dashboard.data else { return .notFound }
                guard data.count == 1, let entry = data[txid.hex] else { throw ChainReaderError.mismatchedResponse }
                guard let height = try Self.height(entry.transaction.blockId) else { return .pending }
                return confirmed(height)
            }
        } catch HTTPClient.Failure.status(404) {
            return .notFound
        }
    }

    // MARK: Historico

    func history(_ address: String) async throws -> UTXOHistoryPage {
        switch backend {
        case .esplora:
            // Mempool e as ultimas confirmadas (25 no Esplora da Blockstream, 50 no
            // mempool.space): o bastante para as ~30 da tela.
            return .full(try await get([EsploraTransaction].self, "address/\(address)/txs"))
        case .blockcypher:
            let info = try await get(BlockcypherAddress.self, "addrs/\(address)", [URLQueryItem(name: "limit", value: "50")])
            guard info.address == address else { throw ChainReaderError.mismatchedResponse }
            var byTx: [String: (height: UInt32?, date: Date?, received: UInt64, spent: UInt64)] = [:]
            for ref in (info.unconfirmedTxrefs ?? []) + (info.txrefs ?? []) {
                _ = try ReaderDecode.txid(ref.txHash, field: "tx_hash")
                let isOutput = ref.txOutputN >= 0 && ref.txInputN == -1
                let isInput = ref.txInputN >= 0 && ref.txOutputN == -1
                guard isOutput || isInput else { throw ChainReaderError.malformedResponse(field: "txrefs") }
                let height = try Self.height(ref.blockHeight)
                var entry = byTx[ref.txHash] ?? (height, Self.isoDate(ref.confirmed ?? ref.received), 0, 0)
                if isOutput { entry.received &+= ref.value } else { entry.spent &+= ref.value }
                byTx[ref.txHash] = entry
            }
            return .deltas(byTx.map { UTXOAddressDelta(txid: $0.key, height: $0.value.height, date: $0.value.date, received: $0.value.received, spent: $0.value.spent) })
        case .blockchair:
            let entry = try await blockchairAddress(address, transactions: 50, unspent: 1)
            return .deltas(try entry.transactions.map { tx in
                _ = try ReaderDecode.txid(tx.hash, field: "hash")
                let change = tx.balanceChange
                return UTXOAddressDelta(
                    txid: tx.hash, height: try Self.height(tx.blockId), date: Self.blockchairDate(tx.time),
                    received: change > 0 ? UInt64(change) : 0, spent: change < 0 ? change.magnitude : 0
                )
            })
        }
    }

    static func isoDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// "2026-03-09 19:54:16", em UTC.
    static func blockchairDate(_ text: String) -> Date? {
        isoDate(text.replacingOccurrences(of: " ", with: "T") + "Z")
    }
}
