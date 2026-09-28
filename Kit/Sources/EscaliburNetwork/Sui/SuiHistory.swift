import EscaliburChains
import EscaliburCore
import Foundation

/// Uma transacao do historico, lida do GraphQL ou do gRPC, antes de virar item da tela.
struct SuiHistoryEntry: Equatable {
    let digest: String
    let sender: SuiAddress?
    let success: Bool
    let date: Date?
    let gas: SuiGasCost?
    let changes: [SuiBalanceChange]
}

extension SuiReader {
    /// As ultimas transacoes que mexeram na conta (`affectedAddress`), pelo GraphQL da
    /// Sui Foundation. Na falha dele, o `ListTransactions` de um no gRPC (so as ultimas
    /// duas semanas, e a pagina sai marcada como incompleta). Informativo: nada daqui
    /// entra num plano.
    public func history(owner: SuiAddress) async throws -> ActivityPage {
        do {
            guard let graphQL else { throw ReaderError.unsupported("historico sem indexador") }
            let data = try await transport.send(.post(graphQL, Self.historyQuery(owner)))
            return Self.activityPage(try Self.parseGraphQLHistory(StrictJSON.parse(data)), owner: owner, complete: true)
        } catch {
            let entries = try await Quorum.first(await pool.available(), pool: pool) { provider in
                try await self.ensureMainnet(provider)
                return try Self.parseListTransactions(
                    try await self.stream(provider, "sui.rpc.v2.LedgerService/ListTransactions", Self.listTransactionsRequest(owner))
                )
            }
            return Self.activityPage(entries, owner: owner, complete: false)
        }
    }

    // MARK: GraphQL

    static let graphQLDocument = """
    query($a: SuiAddress!, $n: Int!) { transactions(last: $n, filter: { affectedAddress: $a }) { nodes { \
    digest sender { address } effects { status timestamp gasEffects { gasSummary { computationCost storageCost storageRebate } } \
    balanceChanges(first: 20) { nodes { owner { address } coinType { repr } amount } } } } } }
    """

    static func historyQuery(_ owner: SuiAddress) -> StrictJSON {
        .object([
            "query": .string(graphQLDocument),
            "variables": .object(["a": .string(owner.hex), "n": .int(ActivityRules.pageSize)]),
        ])
    }

    static func parseGraphQLHistory(_ json: StrictJSON) throws -> [SuiHistoryEntry] {
        if let errors = json.optionalField("errors"), !(errors.arrayValue ?? []).isEmpty {
            throw ReaderError.providerError(code: "graphql")
        }
        let nodes = try json.field("data", "$").field("transactions", "data").field("nodes", "transactions").array("transactions.nodes")
        return try nodes.enumerated().map { index, node in
            let path = "transactions.nodes[\(index)]"
            let digest = try node.field("digest", path).string(path + ".digest")
            let sender = node.optionalField("sender").flatMap { try? $0.field("address", path).string(path) }.flatMap(address)
            let effects = try node.field("effects", path)
            let status = try effects.field("status", path + ".effects").string(path + ".effects.status")
            guard status == "SUCCESS" || status == "FAILURE" else { throw ReaderError.malformed(field: path + ".effects.status") }
            let date = try effects.optionalField("timestamp").map { value -> Date in
                guard let date = isoDate(try value.string(path + ".timestamp")) else { throw ReaderError.malformed(field: path + ".timestamp") }
                return date
            }
            var gas: SuiGasCost?
            if let summary = effects.optionalField("gasEffects")?.optionalField("gasSummary") {
                gas = SuiGasCost(
                    computationCost: try uint64(summary.field("computationCost", path), path + ".computationCost"),
                    storageCost: try uint64(summary.field("storageCost", path), path + ".storageCost"),
                    storageRebate: try uint64(summary.field("storageRebate", path), path + ".storageRebate")
                )
            }
            let changeNodes = try effects.optionalField("balanceChanges")?.field("nodes", path).array(path + ".balanceChanges") ?? []
            let changes = try changeNodes.compactMap { change -> SuiBalanceChange? in
                // Saldo de objeto (sem endereco de conta) nao e da conta de ninguem.
                guard let ownerText = change.optionalField("owner").flatMap({ try? $0.field("address", path).string(path) }),
                      let owner = address(ownerText)
                else { return nil }
                guard let type = normalizedType(try change.field("coinType", path).field("repr", path).string(path + ".repr")),
                      let (negative, magnitude) = signedAmount(try change.field("amount", path).string(path + ".amount"))
                else { throw ReaderError.malformed(field: path + ".balanceChanges") }
                return SuiBalanceChange(address: owner, coinType: type, negative: negative, magnitude: magnitude)
            }
            return SuiHistoryEntry(digest: digest, sender: sender, success: status == "SUCCESS", date: date, gas: gas, changes: changes)
        }
    }

    // MARK: gRPC

    static func listTransactionsRequest(_ owner: SuiAddress) -> SuiProtoWriter {
        var affected = SuiProtoWriter()
        affected.string(1, owner.hex)
        var literal = SuiProtoWriter()
        literal.message(3, affected)
        var term = SuiProtoWriter()
        term.message(1, literal)
        var filter = SuiProtoWriter()
        filter.message(1, term)
        var options = SuiProtoWriter()
        options.uint64(1, UInt64(ActivityRules.pageSize))
        options.uint64(4, 1)  // ORDERING_DESCENDING
        var w = SuiProtoWriter()
        w.message(1, .fieldMask(["digest", "transaction.sender", "effects.status", "effects.gas_used", "balance_changes", "timestamp"]))
        w.message(4, filter)
        w.message(5, options)
        return w
    }

    /// As respostas do `ListTransactions`: cada quadro pode trazer uma transacao, e o
    /// ultimo traz o `QueryEnd`.
    static func parseListTransactions(_ frames: [SuiProtoMessage]) throws -> [SuiHistoryEntry] {
        try frames.compactMap { frame -> SuiHistoryEntry? in
            guard let executed = try frame.message(1, "transaction") else { return nil }
            let digest = try executed.requiredString(1, "digest")
            let sender = try executed.message(2, "transaction")?.string(5, "sender").flatMap(address)
            let effects = try executed.requiredMessage(4, "effects")
            let success = try effects.requiredMessage(4, "status").bool(1, "success") ?? false
            let gas = try effects.message(6, "gas_used").map {
                SuiGasCost(
                    computationCost: try $0.uint64(1, "computation_cost") ?? 0,
                    storageCost: try $0.uint64(2, "storage_cost") ?? 0,
                    storageRebate: try $0.uint64(3, "storage_rebate") ?? 0
                )
            }
            let date = try executed.message(7, "timestamp").map { Date(timeIntervalSince1970: TimeInterval(try $0.uint64(1, "seconds") ?? 0)) }
            let changes = try executed.messages(8, "balance_changes").map { change -> SuiBalanceChange in
                guard let owner = address(try change.requiredString(1, "address")),
                      let type = normalizedType(try change.requiredString(2, "coin_type")),
                      let (negative, magnitude) = signedAmount(try change.requiredString(3, "amount"))
                else { throw ReaderError.malformed(field: change.path) }
                return SuiBalanceChange(address: owner, coinType: type, negative: negative, magnitude: magnitude)
            }
            return SuiHistoryEntry(digest: digest, sender: sender, success: success, date: date, gas: gas, changes: changes)
        }
    }

    // MARK: Itens da tela

    /// Do ponto de vista do dono. O dono enviou: o que foi para outras contas em SUI, com
    /// a taxa liquida; sem SUI para ninguem, "outra" operacao. Outro enviou: o SUI que
    /// entrou, julgado pelas regras de po e valor zero; moeda fora da lista entra so na
    /// contagem de suspeitos.
    static func activityPage(_ entries: [SuiHistoryEntry], owner: SuiAddress, complete: Bool) -> ActivityPage {
        let native = Asset.native(.sui)
        var items: [ActivityItem] = []
        var suspicious = SuspiciousSummary()
        for entry in entries {
            let date = entry.date ?? .now
            let status: ActivityItem.Status = entry.success ? .confirmed : .failed
            let explorer = Chain.sui.explorerURL(tx: entry.digest)
            let sui = entry.changes.filter { $0.coinType == SuiPlanner.suiCoinType }
            if entry.sender == owner {
                let paid = sui.filter { $0.address != owner && !$0.negative && !$0.magnitude.isZero }
                let fee = entry.gas.flatMap { gas -> BigUInt? in
                    let net = gas.net
                    return net.negative ? nil : BigUInt(net.magnitude)
                }
                if paid.isEmpty {
                    items.append(ActivityItem(
                        id: "sui:\(entry.digest)", chainID: "sui", direction: .other, asset: native, amount: 0,
                        counterparty: nil, date: date, status: status, fee: fee, hash: entry.digest, explorerURL: explorer
                    ))
                } else {
                    let total = paid.reduce(BigUInt()) { $0 + $1.magnitude }
                    let recipients = Set(paid.map(\.address))
                    items.append(ActivityItem(
                        id: "sui:\(entry.digest)", chainID: "sui", direction: .sent, asset: native, amount: total,
                        counterparty: recipients.count == 1 ? recipients.first?.hex : nil, date: date, status: status,
                        fee: fee, hash: entry.digest, explorerURL: explorer
                    ))
                }
                continue
            }
            let received = entry.changes.filter { $0.address == owner && !$0.negative && !$0.magnitude.isZero }
            // Moeda fora da lista curada (a carteira so conhece SUI na Sui): so a contagem.
            for change in received where change.coinType != SuiPlanner.suiCoinType {
                ActivityRules.count(.unknownAsset, in: &suspicious)
            }
            guard let incoming = received.first(where: { $0.coinType == SuiPlanner.suiCoinType }) else { continue }
            if let suspicion = ActivityRules.judgeIncoming(asset: native, amount: incoming.magnitude) {
                ActivityRules.count(suspicion, in: &suspicious)
                continue
            }
            items.append(ActivityItem(
                id: "sui:\(entry.digest)", chainID: "sui", direction: .received, asset: native, amount: incoming.magnitude,
                counterparty: entry.sender?.hex, date: date, status: status, fee: nil, hash: entry.digest, explorerURL: explorer
            ))
        }
        return ActivityRules.page(chainID: "sui", items: items, suspicious: suspicious, complete: complete)
    }

    // MARK: Formatos

    static func address(_ text: String) -> SuiAddress? {
        guard case .success(let address) = SuiAddress.parse(text) else { return nil }
        return address
    }

    static func uint64(_ value: StrictJSON, _ path: String) throws -> UInt64 {
        guard let number = try value.integer(path).uint64 else { throw ReaderError.malformed(field: path) }
        return number
    }

    /// "2026-09-27T23:20:26.898Z", com ou sem fracao de segundo.
    static func isoDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
