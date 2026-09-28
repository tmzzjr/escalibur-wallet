import EscaliburChains
import EscaliburCore
import Foundation

/// Leitura de estado, taxa, transmissao, acompanhamento e historico da Polkadot Asset
/// Hub, pelo JSON-RPC de quatro operadores sem chave (`Endpoints.polkadot`).
///
/// O que decide o dinheiro vem de dois provedores concordando, no mesmo bloco
/// (docs/seguranca.md §5.5):
/// - o bloco de referencia: o finalizado mais baixo de dois provedores, com o hash igual
///   em dois. A era da transacao nasce nele, e todo o resto e lido nele;
/// - o runtime desse bloco (nome, `spec_version`, `transaction_version`) e as contas do
///   dono e do destino (`System.Account`: nonce, livre, reservado, congelado), iguais;
/// - a taxa da transacao exata (`TransactionPaymentApi_query_info`), igual. A avaliacao
///   tambem prova que o no decodifica a transacao que a carteira monta: uma extensao nova
///   no runtime faz os dois recusarem, e o plano para;
/// - a genese, conferida uma vez por provedor contra a compilada.
///
/// Uma fonte so, com o motivo: o saldo da tela (exibicao; o plano rele nos dois), o
/// resultado da transacao no acompanhamento (o sidecar da Parity, depois de um no achar a
/// transacao num bloco finalizado) e o historico (informativo, do indexador da Nova).
public actor PolkadotReader {
    public static let shared = PolkadotReader()

    /// `twox128("System") ++ twox128("Account")`, o prefixo do mapa `System.Account`.
    /// Constante do Substrate (docs.substrate.io, "Storage keys"; o mesmo prefixo que o
    /// polkadot-js monta para `api.query.system.account`). A chave de cada conta e este
    /// prefixo, o BLAKE2b-128 da conta e a conta (`Blake2_128Concat`).
    static let systemAccountPrefix: [UInt8] = [UInt8](hex: "26aa394eea5630e07c48ae0c9558cef7b99d880ec681799c0cf30e8886371da9")!
    /// Quantos blocos o acompanhamento percorre por consulta, no maximo.
    static let scanBatch: UInt64 = 40

    let transport: ReaderTransport
    let providers: [ProviderPool.Provider]
    let pool: ProviderPool
    let sidecar: URL
    let historyURL: URL
    private var verifiedGenesis: Set<String> = []
    private var historyVerified = false
    private var scans: [String: Scan] = [:]

    /// Uma transacao transmitida por este aparelho, e ate onde o acompanhamento ja olhou.
    struct Scan: Sendable {
        let birth: UInt64
        let death: UInt64
        var next: UInt64
        var found: (block: UInt64, index: Int)?
    }

    public init(
        transport: ReaderTransport = HTTPClient.shared, providers: [ProviderPool.Provider] = Endpoints.polkadot,
        sidecar: URL = Endpoints.polkadotSidecar, history: URL = Endpoints.polkadotHistory, pacing: TimeInterval = 0.1
    ) {
        // Os nos publicos limitam por IP. Um decimo de segundo entre chamadas ao mesmo host,
        // e o 429 repete uma vez.
        let hosts = (providers.map(\.baseURL) + [sidecar, history]).compactMap(\.host)
        self.transport = PacedTransport(base: transport, intervals: Dictionary(hosts.map { ($0, pacing) }, uniquingKeysWith: { a, _ in a }))
        self.providers = providers
        self.pool = ProviderPool(providers)
        self.sidecar = sidecar
        self.historyURL = history
    }

    // MARK: Estado para o plano

    /// O que o plano precisa antes da taxa: bloco de referencia, runtime e as duas contas,
    /// em dois provedores concordando.
    public struct AccountReading: Equatable, Sendable {
        public let checkpoint: PolkadotCheckpoint
        public let runtime: PolkadotRuntimeState
        public let sender: PolkadotAccountInfo
        public let destination: PolkadotAccountInfo
    }

    struct StateAnswer: Equatable, Sendable {
        let runtime: PolkadotRuntimeState
        let sender: [UInt8]?
        let destination: [UInt8]?
    }

    public func accountState(owner: PolkadotAddress, destination: PolkadotAddress) async throws -> AccountReading {
        let checkpoint = try await checkpoint()
        let at = Hex.encode(checkpoint.hash, prefix: true)
        let senderKey = Self.accountKey(owner)
        let destinationKey = Self.accountKey(destination)
        let answer = try await Quorum.agree(await live(), pool: pool, field: "state") { provider in
            try await self.ensureGenesis(provider)
            async let version = self.call(provider, "state_getRuntimeVersion", [.string(at)])
            async let sender = self.call(provider, "state_getStorage", [.string(senderKey), .string(at)])
            async let target = self.call(provider, "state_getStorage", [.string(destinationKey), .string(at)])
            return StateAnswer(
                runtime: try Self.parseRuntime(try await version),
                sender: try Self.optionalHex(try await sender, "storage"),
                destination: try Self.optionalHex(try await target, "storage")
            )
        }
        return AccountReading(
            checkpoint: checkpoint, runtime: answer.runtime,
            sender: try Self.accountInfo(answer.sender), destination: try Self.accountInfo(answer.destination)
        )
    }

    /// A taxa da transacao exata no bloco de referencia, igual em dois provedores. Um no
    /// que nao decodifica a transacao responde com erro, e nao ha taxa.
    public func fee(for extrinsic: [UInt8], at checkpoint: PolkadotCheckpoint) async throws -> BigUInt {
        let argument = Hex.encode(extrinsic + UInt32(extrinsic.count).littleEndianByteArray, prefix: true)
        let at = Hex.encode(checkpoint.hash, prefix: true)
        return try await Quorum.agree(await live(), pool: pool, field: "fee") { provider in
            let result = try await self.call(provider, "state_call", [.string("TransactionPaymentApi_query_info"), .string(argument), .string(at)])
            return try Self.parsePartialFee(try result.hexData("query_info"))
        }
    }

    /// O finalizado mais baixo de dois provedores, e o hash dele igual em dois.
    func checkpoint() async throws -> PolkadotCheckpoint {
        let providers = await live()
        let heads = try await Quorum.collect(providers, pool: pool, count: 2) { provider in
            try await self.finalizedNumber(provider)
        }
        guard let number = heads.map(\.value).min() else { throw ReaderError.notEnoughProviders(needed: 2, got: 0) }
        let hash = try await Quorum.agree(providers, pool: pool, field: "checkpoint") { provider in
            try await self.blockHash(provider, number)
        }
        return PolkadotCheckpoint(number: number, hash: hash)
    }

    // MARK: Saldo da tela

    /// DOT livre mais reservado, num provedor (o primeiro que responde). So exibicao: o
    /// plano rele nos dois.
    public func displayBalance(owner text: String) async throws -> ChainBalance {
        guard case .success(let owner) = PolkadotAddress.parse(text) else { throw ReaderError.invalidInput("address") }
        let info = try await Quorum.first(await live(), pool: pool) { provider in
            try await self.ensureGenesis(provider)
            let raw = try Self.optionalHex(try await self.call(provider, "state_getStorage", [.string(Self.accountKey(owner))]), "storage")
            return try Self.accountInfo(raw)
        }
        return ChainBalance(
            chainID: Chain.polkadot.id, holdings: [Holding(asset: .native(.polkadot), amount: info.total)],
            accountExists: !info.total.isZero, unknownTokenCount: 0, fetchedAt: .now
        )
    }

    // MARK: Transmissao e acompanhamento

    /// Os mesmos bytes para dois provedores. Aceita se um aceitou; o hash que o no devolve
    /// tem de ser o calculado aqui. Depois, anota de onde o acompanhamento comeca a
    /// procurar: o bloco de nascimento da era, que e o finalizado de agora recuado ate a
    /// fase dela.
    public func broadcast(_ signed: SignedTransaction) async throws -> BroadcastReceipt {
        guard let parsed = try? PolkadotSignedExtrinsic.parse(signed) else { throw ReaderError.broadcastMismatch }
        let id = signed.id.lowercased()
        let targets = Array(await live().prefix(2))
        guard !targets.isEmpty else { throw ReaderError.notEnoughProviders(needed: 1, got: 0) }
        let results = await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
            for (index, provider) in targets.enumerated() {
                group.addTask { (index, await self.submit(provider, signed.encoded, id: id)) }
            }
            var collected: [(Int, Result<String, Error>)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        var tally = BroadcastTally()
        for (index, result) in results { tally.add(result, provider: targets[index]) }
        let receipt = try tally.receipt(chainID: Chain.polkadot.id, id: id)
        if let finalized = try? await Quorum.first(await live(), pool: pool, { try await self.finalizedNumber($0) }) {
            let birth = Self.birth(era: parsed.era, finalized: finalized)
            track(id, birth: birth, death: birth + parsed.era.period - 1)
        }
        return receipt
    }

    /// Anota de onde o acompanhamento procura uma transacao: do nascimento ao ultimo
    /// bloco da era. So na memoria.
    func track(_ id: String, birth: UInt64, death: UInt64) {
        scans[id.lowercased()] = Scan(birth: birth, death: death, next: birth, found: nil)
    }

    /// O nascimento da era: o maior bloco ate o finalizado com a fase dela. O bloco de
    /// referencia do plano era finalizado quando o plano nasceu, e o plano vive 60 s,
    /// muito menos que o periodo da era.
    static func birth(era: PolkadotEra, finalized: UInt64) -> UInt64 {
        let back = (finalized + era.period - era.phase % era.period) % era.period
        return finalized >= back ? finalized - back : 0
    }

    private func submit(_ provider: ProviderPool.Provider, _ encoded: String, id: String) async -> Result<String, Error> {
        do {
            let result = try await call(provider, "author_submitExtrinsic", [.string(encoded)], timeout: 30)
            guard try result.string("hash").lowercased() == id else { return .failure(ReaderError.broadcastMismatch) }
            return .success(id)
        } catch RPCFailure.error(let code, let text) {
            return .failure(ReaderError.broadcastRejected(Self.rejection(code: code, text: text), code: ReaderError.sanitized(String(code))))
        } catch {
            return .failure(error)
        }
    }

    /// A transacao nos blocos finalizados desde o nascimento da era. Achada, o resultado
    /// vem do sidecar, conferido pelo hash na mesma posicao. Nao achada com o finalizado ja
    /// alem da era: venceu, a rede nao aceita mais. Sem registro (o app foi reaberto), nao
    /// ha de onde procurar, e fica `notFound`.
    public func status(of id: String) async throws -> TransactionStatus {
        let key = id.lowercased()
        guard key.hasPrefix("0x"), key.count == 66, Hex.decode(key) != nil else { throw ReaderError.invalidInput("id") }
        guard var scan = scans[key] else { return .notFound }
        let providers = await live()
        let finalized = try await Quorum.first(providers, pool: pool) { try await self.finalizedNumber($0) }
        if scan.found == nil {
            let last = min(finalized, scan.death, scan.next + Self.scanBatch - 1)
            while scan.next <= last, scan.found == nil {
                let number = scan.next
                let ids = try await Quorum.first(providers, pool: pool) { provider in
                    let hash = try await self.blockHash(provider, number)
                    let block = try await self.call(provider, "chain_getBlock", [.string(Hex.encode(hash, prefix: true))])
                    return try Self.extrinsicIDs(block)
                }
                if let index = ids.firstIndex(of: key) { scan.found = (number, index) }
                scan.next += 1
            }
            scans[key] = scan
        }
        guard let found = scan.found else {
            return finalized > scan.death && scan.next > scan.death ? .failed(reason: "expired") : .pending
        }
        let url = sidecar.adding(path: "blocks/\(found.block)").adding(query: [("noFees", "true"), ("eventDocs", "false"), ("extrinsicDocs", "false")])
        let success = try Self.parseSidecarSuccess(try await transport.send(.get(url, timeout: 30)), index: found.index, id: key)
        return success ? .confirmed(block: found.block, confirmations: nil) : .failed(reason: "dispatch")
    }

    // MARK: Historico

    /// As ultimas transferencias de DOT da conta, pelo indexador da Nova. Informativo.
    public func history(owner text: String) async throws -> ActivityPage {
        guard case .success(let owner) = PolkadotAddress.parse(text) else { throw ReaderError.invalidInput("address") }
        if !historyVerified {
            let meta = try StrictJSON.parse(try await transport.send(.post(historyURL, .object([
                "query": .string("{ _metadata { genesisHash } }"),
            ]))))
            let genesis = try meta.field("data", "history").field("_metadata", "history.data").field("genesisHash", "history._metadata").hexData("genesisHash")
            guard genesis == PolkadotRuntime.genesisHash else { throw ReaderError.wrongNetwork }
            historyVerified = true
        }
        let query = """
        query($a: String!) { historyElements(filter: {address: {equalTo: $a}, transfer: {isNull: false}}, \
        orderBy: TIMESTAMP_DESC, first: \(ActivityRules.pageSize)) { nodes { id extrinsicHash timestamp transfer } } }
        """
        let data = try await transport.send(ReaderRequest(
            method: .post, url: historyURL,
            body: StrictJSON.object(["query": .string(query), "variables": .object(["a": .string(owner.ss58)])]).serialized, timeout: 30
        ))
        return try Self.parseHistory(data, owner: owner)
    }

    // MARK: JSON-RPC

    enum RPCFailure: Error { case error(code: Int64, text: String) }

    /// Uma chamada JSON-RPC. Erro do no volta como `RPCFailure` so para a transmissao
    /// classificar; nos outros usos vira `providerError` com o codigo, sem a mensagem.
    nonisolated func call(_ provider: ProviderPool.Provider, _ method: String, _ params: [StrictJSON], timeout: TimeInterval = 10) async throws -> StrictJSON {
        let body = StrictJSON.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string(method), "params": .array(params)])
        let data = try await transport.send(ReaderRequest(method: .post, url: provider.baseURL, body: body.serialized, timeout: timeout))
        return try Self.result(data, method: method)
    }

    static func result(_ data: Data, method: String) throws -> StrictJSON {
        let json = try StrictJSON.parse(data)
        if let error = json.optionalField("error") {
            let code = (try? error.field("code", "error").int64("error.code")) ?? 0
            let text = [error.optionalField("message"), error.optionalField("data")].compactMap { try? $0?.string("error") }.joined(separator: " ")
            if method == "author_submitExtrinsic" { throw RPCFailure.error(code: code, text: text) }
            throw ReaderError.providerError(code: ReaderError.sanitized(String(code)))
        }
        return try json.field("result", method)
    }

    private nonisolated func finalizedNumber(_ provider: ProviderPool.Provider) async throws -> UInt64 {
        let hash = try await call(provider, "chain_getFinalizedHead", []).hexData("finalizedHead")
        guard hash.count == 32 else { throw ReaderError.malformed(field: "finalizedHead") }
        let header = try await call(provider, "chain_getHeader", [.string(Hex.encode(hash, prefix: true))])
        return try Self.headerNumber(header)
    }

    private nonisolated func blockHash(_ provider: ProviderPool.Provider, _ number: UInt64) async throws -> [UInt8] {
        let result = try await call(provider, "chain_getBlockHash", [.int(number)])
        guard !result.isNull else { throw ReaderError.malformed(field: "blockHash") }
        let hash = try result.hexData("blockHash")
        guard hash.count == 32 else { throw ReaderError.malformed(field: "blockHash") }
        return hash
    }

    /// A genese do provedor tem de ser a compilada, uma vez por provedor.
    private func ensureGenesis(_ provider: ProviderPool.Provider) async throws {
        guard !verifiedGenesis.contains(provider.name) else { return }
        guard try await blockHash(provider, 0) == PolkadotRuntime.genesisHash else { throw ReaderError.wrongNetwork }
        verifiedGenesis.insert(provider.name)
    }

    private func live() async -> [ProviderPool.Provider] {
        let available = await pool.available()
        return available.isEmpty ? providers : available
    }

    // MARK: Leitura das respostas

    static func accountKey(_ address: PolkadotAddress) -> String {
        Hex.encode(systemAccountPrefix + Blake2b.hash(address.accountID, outputLength: 16) + address.accountID, prefix: true)
    }

    static func optionalHex(_ value: StrictJSON, _ path: String) throws -> [UInt8]? {
        value.isNull ? nil : try value.hexData(path)
    }

    /// Conta sem valor no armazenamento nao existe: tudo zero.
    static func accountInfo(_ raw: [UInt8]?) throws -> PolkadotAccountInfo {
        guard let raw else { return .empty }
        do {
            return try PolkadotAccountInfo.decode(raw)
        } catch {
            throw ReaderError.malformed(field: "System.Account")
        }
    }

    static func headerNumber(_ header: StrictJSON) throws -> UInt64 {
        let text = try header.field("number", "header").string("header.number")
        guard text.hasPrefix("0x"), text.count <= 18, let value = UInt64(text.dropFirst(2), radix: 16) else {
            throw ReaderError.malformed(field: "header.number")
        }
        return value
    }

    static func parseRuntime(_ value: StrictJSON) throws -> PolkadotRuntimeState {
        PolkadotRuntimeState(
            specName: try value.field("specName", "runtime").string("runtime.specName"),
            specVersion: try value.field("specVersion", "runtime").uint32("runtime.specVersion"),
            transactionVersion: try value.field("transactionVersion", "runtime").uint32("runtime.transactionVersion"),
            genesisHash: PolkadotRuntime.genesisHash
        )
    }

    /// `RuntimeDispatchInfo { weight: { ref_time: Compact<u64>, proof_size: Compact<u64> },
    /// class: DispatchClass, partial_fee: u128 }`, nada sobrando.
    static func parsePartialFee(_ bytes: [UInt8]) throws -> BigUInt {
        var reader = PolkadotSCALE.Reader(bytes)
        do {
            _ = try reader.compact()
            _ = try reader.compact()
            guard try reader.byte() <= 2 else { throw ReaderError.malformed(field: "query_info.class") }
            let fee = try reader.unsigned(width: 16)
            try reader.requireEnd()
            return fee
        } catch let error as ReaderError {
            throw error
        } catch {
            throw ReaderError.malformed(field: "query_info")
        }
    }

    /// Os ids (BLAKE2b-256 da extrinsic inteira) de um bloco, na ordem.
    static func extrinsicIDs(_ block: StrictJSON) throws -> [String] {
        let list = try block.field("block", "chain_getBlock").field("extrinsics", "block").array("block.extrinsics")
        return try list.map { PolkadotSignedExtrinsic.id(of: try $0.hexData("extrinsic")) }
    }

    /// O resultado da extrinsic na posicao achada, com o hash conferido.
    static func parseSidecarSuccess(_ data: Data, index: Int, id: String) throws -> Bool {
        let extrinsics = try StrictJSON.parse(data).field("extrinsics", "sidecar").array("sidecar.extrinsics")
        guard extrinsics.indices.contains(index) else { throw ReaderError.responseMismatch(field: "sidecar.extrinsics") }
        let item = extrinsics[index]
        guard try item.field("hash", "sidecar.extrinsic").string("sidecar.hash").lowercased() == id else {
            throw ReaderError.responseMismatch(field: "sidecar.hash")
        }
        return try item.field("success", "sidecar.extrinsic").bool("sidecar.success")
    }

    /// Classifica a recusa do no. O texto e lido aqui e descartado: pode trazer endereco e
    /// valor. Codigos do `sc_rpc_api::author` (1010 invalida, 1011 desconhecida, 1012
    /// banida, 1013 ja importada, 1014 prioridade baixa).
    static func rejection(code: Int64, text: String) -> BroadcastRejection {
        let lower = text.lowercased()
        switch code {
        case 1013: return .alreadyKnown
        case 1014: return .nonceTooLow
        default: break
        }
        if lower.contains("bad signature") || lower.contains("badproof") { return .invalidSignature }
        if lower.contains("inability to pay") || lower.contains("payment") { return .insufficientFunds }
        if lower.contains("outdated") || lower.contains("stale") { return .nonceTooLow }
        if lower.contains("future") { return .nonceTooHigh }
        if lower.contains("ancient") || lower.contains("birth block") { return .expired }
        return .other
    }

    /// Os nos do historico, do mais novo para o mais velho. Enviado: a taxa e do dono.
    /// Recebido de valor zero ou po fica de fora e conta como suspeito.
    static func parseHistory(_ data: Data, owner: PolkadotAddress) throws -> ActivityPage {
        let nodes = try StrictJSON.parse(data).field("data", "history").field("historyElements", "history.data")
            .field("nodes", "history.historyElements").array("history.nodes")
        var items: [ActivityItem] = []
        var suspicious = SuspiciousSummary()
        let asset = Asset.native(.polkadot)
        for node in nodes {
            guard let transfer = node.optionalField("transfer") else { continue }
            let hash = try node.field("extrinsicHash", "history.node").string("history.extrinsicHash").lowercased()
            guard hash.hasPrefix("0x"), hash.count == 66, Hex.decode(hash) != nil else { throw ReaderError.malformed(field: "history.extrinsicHash") }
            let from = try transfer.field("from", "transfer").string("transfer.from")
            let to = try transfer.field("to", "transfer").string("transfer.to")
            let amount = try transfer.field("amount", "transfer").decimalString("transfer.amount")
            let success = try transfer.field("success", "transfer").bool("transfer.success")
            let seconds = try node.field("timestamp", "history.node").decimalString("history.timestamp")
            guard let time = seconds.uint64 else { throw ReaderError.malformed(field: "history.timestamp") }
            let sent = PolkadotAddress.parse(from).map { $0 == owner }
            let received = PolkadotAddress.parse(to).map { $0 == owner }
            let direction: ActivityItem.Direction
            let counterparty: String
            switch (sent, received) {
            case (.success(true), .success(true)): direction = .other; counterparty = to
            case (.success(true), _): direction = .sent; counterparty = to
            case (_, .success(true)): direction = .received; counterparty = from
            default: throw ReaderError.responseMismatch(field: "history.address")
            }
            if direction == .received, success, let suspicion = ActivityRules.judgeIncoming(asset: asset, amount: amount) {
                ActivityRules.count(suspicion, in: &suspicious)
                continue
            }
            let fee = direction == .received ? nil : try transfer.field("fee", "transfer").decimalString("transfer.fee")
            items.append(ActivityItem(
                id: try node.field("id", "history.node").string("history.id"), chainID: Chain.polkadot.id,
                direction: direction, asset: asset, amount: amount, counterparty: counterparty,
                date: Date(timeIntervalSince1970: TimeInterval(time)), status: success ? .confirmed : .failed,
                fee: fee, hash: hash, explorerURL: Chain.polkadot.explorerURL(tx: hash)
            ))
        }
        return ActivityRules.page(chainID: Chain.polkadot.id, items: items, suspicious: suspicious)
    }
}
