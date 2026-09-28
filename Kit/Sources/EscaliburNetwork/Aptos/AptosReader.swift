import EscaliburChains
import EscaliburCore
import Foundation

/// Leitura de estado, simulacao, transmissao e acompanhamento da Aptos, pela API REST de
/// fullnode de tres operadores independentes e sem chave (`Endpoints.aptos`): PublicNode,
/// Sentio e Aptos Labs.
///
/// O que decide o dinheiro vem de dois provedores concordando (docs/seguranca.md §5.5): o
/// `chain_id` (tem de ser o 1 compilado, nos dois), o numero de sequencia, a chave de
/// autenticacao e o saldo do dono, se o destino ja tem loja de APT, e o preco do gas. As
/// leituras de conta sao feitas nos dois na mesma versao do ledger (a menor das duas que
/// eles informam), entao dois nos honestos respondem igual; diferenca e provedor trocando
/// dado. O preco do gas nao tem versao: diferenca rele uma vez, 1,5 s depois, e a segunda
/// vira `providersDisagree`. A simulacao, para o gas e para a transacao exata, roda em dois
/// provedores, e as duas tem de dar certo.
///
/// Uma fonte so, com o motivo:
/// - o saldo da tela (`displayBalance`): exibicao; o plano rele em dois;
/// - o historico, pelo indexador GraphQL da Aptos Labs, o unico sem chave com as
///   transferencias recebidas (a API do fullnode so lista o que a conta enviou).
///   Informativo: nada dali entra num plano.
///
/// O endereco vai no corpo do POST das views, nunca no caminho. So o acompanhamento por
/// hash e o indice do ledger usam GET.
public actor AptosReader {
    public static let shared = AptosReader()

    let transport: ReaderTransport
    let pool: ProviderPool
    let providers: [Provider]
    let indexer: URL?

    public init(
        transport: ReaderTransport = HTTPClient.shared,
        providers: [ProviderPool.Provider] = Endpoints.aptos,
        indexer: URL? = Endpoints.aptosIndexer,
        pacing: TimeInterval = 0.25
    ) {
        // Os nos publicos limitam por IP; a Aptos Labs publica 40.000 unidades de computo a
        // cada 5 minutos. Um quarto de segundo entre chamadas ao mesmo host, e o 429 repete
        // uma vez.
        let hosts = (providers.map(\.baseURL) + [indexer].compactMap { $0 }).compactMap(\.host)
        self.transport = PacedTransport(base: transport, intervals: Dictionary(hosts.map { ($0, pacing) }, uniquingKeysWith: { a, _ in a }))
        self.pool = ProviderPool(providers)
        self.providers = providers
        self.indexer = indexer
    }

    /// O cabecalho da transacao em BCS, para simular e transmitir os mesmos bytes.
    static let bcsContentType = "application/x.aptos.signed_transaction+bcs"

    // MARK: Estado para o plano

    /// Sequencia, chave de autenticacao e saldo do dono, e se o destino ja tem loja de APT,
    /// lidos em dois provedores na mesma versao do ledger, mais o preco do gas nos dois.
    public func accountState(owner: AptosAddress, destination: AptosAddress) async throws -> AptosAccountState {
        try await agreedTwice {
            let (reading, ledger) = try await self.pinned(field: "account") { provider, version in
                try await self.accountReading(owner: owner, destination: destination, at: provider, version: version)
            }
            let price = try await self.agreedGasPrice()
            return AptosAccountState(
                sequenceNumber: reading.sequenceNumber, authenticationKey: reading.authenticationKey, balance: reading.balance,
                gasUnitPrice: price, chainID: ledger.chainID, ledgerVersion: ledger.version,
                ledgerTimestamp: ledger.timestampMicros / 1_000_000, destinationExists: reading.destinationExists
            )
        }
    }

    /// Se o destino ja tem loja primaria de APT, nos dois provedores e na mesma versao. Para
    /// a tela do destino; o plano le de novo em `accountState`.
    public func destinationExists(_ destination: AptosAddress) async throws -> Bool {
        try await pinned(field: "destination") { provider, version in
            try await self.storeExists(destination, at: provider, version: version)
        }.value
    }

    struct AccountReading: Sendable, Equatable {
        let sequenceNumber: UInt64
        let authenticationKey: [UInt8]
        let balance: UInt64
        let destinationExists: Bool
    }

    private func accountReading(owner: AptosAddress, destination: AptosAddress, at provider: Provider, version: UInt64) async throws -> AccountReading {
        let sequence = try Self.parseU64View(try await view(provider, version, "0x1::account::get_sequence_number", [], [owner.hex]), "get_sequence_number")
        let key = try Self.parseBytesView(try await view(provider, version, "0x1::account::get_authentication_key", [], [owner.hex]), "get_authentication_key")
        let balance = try Self.parseU64View(
            try await view(provider, version, "0x1::coin::balance", ["0x1::aptos_coin::AptosCoin"], [owner.hex]), "coin::balance"
        )
        let exists = try await storeExists(destination, at: provider, version: version)
        return AccountReading(sequenceNumber: sequence, authenticationKey: key, balance: balance, destinationExists: exists)
    }

    private func storeExists(_ address: AptosAddress, at provider: Provider, version: UInt64) async throws -> Bool {
        try Self.parseBoolView(
            try await view(provider, version, "0x1::primary_fungible_store::primary_store_exists", ["0x1::fungible_asset::Metadata"],
                           [address.hex, AptosAddress.aptMetadata.hex]),
            "primary_store_exists"
        )
    }

    /// `gas_estimate` em dois provedores, iguais.
    private func agreedGasPrice() async throws -> UInt64 {
        let transport = self.transport
        let prices = try await Quorum.collect(await pool.available(), pool: pool, count: 2) { provider in
            try Self.parseGasPrice(StrictJSON.parse(try await transport.send(.get(provider.baseURL.adding(path: "estimate_gas_price")))))
        }.map(\.value)
        guard prices[0] == prices[1] else { throw ReaderError.providersDisagree(field: "gas_estimate") }
        return prices[0]
    }

    // MARK: Simulacao

    /// A transacao simulada em dois provedores, com a assinatura zerada (a rede so simula
    /// assim) e a chave publica do dono.
    public func simulate(_ raw: AptosRawTransaction, publicKey: [UInt8]) async throws -> [AptosSimulation] {
        let body = Data(AptosSignedTransaction.simulationBytes(raw, publicKey: publicKey))
        let transport = self.transport
        return try await Quorum.collect(await pool.available(), pool: pool, count: 2) { provider in
            try await self.ensureMainnet(provider)
            let request = ReaderRequest(
                method: .post, url: provider.baseURL.adding(path: "transactions/simulate"), body: body,
                headers: ["Content-Type": Self.bcsContentType]
            )
            return try Self.parseSimulation(StrictJSON.parse(try await transport.send(request)))
        }.map(\.value)
    }

    /// O gas usado para o maximo: a simulacao em dois provedores, as duas com sucesso, e a
    /// maior das duas leituras.
    public func estimateGasUsed(_ raw: AptosRawTransaction, publicKey: [UInt8]) async throws -> UInt64 {
        let results = try await simulate(raw, publicKey: publicKey)
        guard results.allSatisfy(\.success) else { throw ReaderError.executionReverted }
        let expected = AptosSignedTransaction.hash(of: AptosSignedTransaction.simulationBytes(raw, publicKey: publicKey))
        guard results.allSatisfy({ $0.hash.lowercased() == expected }) else { throw ReaderError.responseMismatch(field: "simulate.hash") }
        return results.map(\.gasUsed).max() ?? 0
    }

    // MARK: Transmissao e acompanhamento

    /// Os mesmos bytes assinados para ate dois provedores, um depois do outro. So sai
    /// transacao que `AptosSignedTransaction.parse` aceita. O id devolvido e o hash
    /// calculado aqui; o que o provedor responde tem de ser igual.
    ///
    /// Recusa com 4xx conta como recusa daquele provedor; o `HTTPClient` nao devolve o
    /// corpo, entao o motivo exato (sequencia velha, saldo) nao chega aqui.
    public func broadcast(_ signed: SignedTransaction) async throws -> BroadcastReceipt {
        let parsed: AptosSignedTransaction
        do { parsed = try AptosSignedTransaction.parse(signed) } catch { throw ReaderError.broadcastMismatch }
        let id = signed.id.lowercased()
        let body = Data(parsed.bytes)
        var tally = BroadcastTally()
        for provider in (await pool.available()).prefix(2) {
            do {
                try await ensureMainnet(provider)
                let request = ReaderRequest(
                    method: .post, url: provider.baseURL.adding(path: "transactions"), body: body,
                    headers: ["Content-Type": Self.bcsContentType], timeout: 30
                )
                let answer: StrictJSON
                do {
                    answer = try StrictJSON.parse(try await transport.send(request))
                } catch HTTPClient.Failure.status(let code) where (400..<500).contains(code) && code != 429 {
                    throw ReaderError.broadcastRejected(.other, code: "http-\(code)")
                }
                guard try answer.field("hash", "transactions").string("transactions.hash").lowercased() == id else {
                    throw ReaderError.broadcastMismatch
                }
                await pool.reportSuccess(provider)
                tally.add(.success(id), provider: provider)
            } catch {
                await Quorum.record(error, provider, pool)
                tally.add(.failure(error), provider: provider)
            }
        }
        return try tally.receipt(chainID: Chain.aptos.id, id: id)
    }

    enum Lookup: Sendable, Equatable {
        case notFound
        case pending
        case committed(success: Bool, version: UInt64)
    }

    /// A transacao pelo hash, em dois provedores. Final so com as duas concordando no
    /// resultado. Nenhuma das duas conhecendo, e a hora do ledger nos dois ja depois de
    /// `expiresAt` (a validade da transacao, em segundos Unix): vencida, a rede nao executa
    /// mais.
    public func status(of hash: String, expiresAt: UInt64? = nil) async throws -> TransactionStatus {
        guard hash.hasPrefix("0x"), let bytes = Hex.decode(hash), bytes.count == 32 else { throw ReaderError.invalidInput("hash") }
        let id = Hex.encode(bytes, prefix: true)
        let transport = self.transport
        let readings = try await Quorum.collect(await pool.available(), pool: pool, count: 2) { provider in
            try await self.ensureMainnet(provider)
            do {
                let data = try await transport.send(.get(provider.baseURL.adding(path: "transactions/by_hash/" + id)))
                return try Self.parseLookup(StrictJSON.parse(data), hash: id)
            } catch HTTPClient.Failure.status(404) {
                return Lookup.notFound
            }
        }.map(\.value)
        switch (readings[0], readings[1]) {
        case (.committed(let a, let versionA), .committed(let b, let versionB)) where a == b:
            return a ? .confirmed(block: min(versionA, versionB), confirmations: nil) : .failed(reason: "execution")
        case (.notFound, .notFound):
            if let expiresAt {
                let ledgers = try await Quorum.collect(await pool.available(), pool: pool, count: 2) { provider in
                    try await self.ledger(provider)
                }.map(\.value)
                if ledgers.allSatisfy({ $0.timestampMicros / 1_000_000 > expiresAt }) { return .failed(reason: "expired") }
            }
            return .notFound
        default:
            return .pending
        }
    }

    // MARK: Saldo da tela

    /// O saldo para a tela: `coin::balance<AptosCoin>` (moeda e loja primaria juntas), num
    /// provedor. Na Aptos qualquer endereco recebe, sem minimo: a conta sempre "existe"
    /// para a tela de receber.
    public func displayBalance(owner text: String) async throws -> ChainBalance {
        guard case .success(let owner) = AptosAddress.parse(text) else { throw ReaderError.invalidInput("endereco") }
        let octas = try await Quorum.first(await pool.available(), pool: pool) { provider in
            try await self.ensureMainnet(provider)
            return try Self.parseU64View(
                try await self.view(provider, nil, "0x1::coin::balance", ["0x1::aptos_coin::AptosCoin"], [owner.hex]), "coin::balance"
            )
        }
        return ChainBalance(
            chainID: Chain.aptos.id, holdings: [Holding(asset: .native(.aptos), amount: BigUInt(octas))],
            accountExists: true, unknownTokenCount: 0, fetchedAt: .now
        )
    }

    // MARK: Historico

    /// A consulta do historico no indexador: as ultimas transacoes que tocam a conta, com
    /// os movimentos de APT de cada uma (da conta e da contraparte). O mesmo texto que o
    /// `gravar.py` dos testes usa.
    static let historyQuery = #"query Historico($owner: String!, $limit: Int!) { account_transactions(where: {account_address: {_eq: $owner}}, order_by: {transaction_version: desc}, limit: $limit) { transaction_version user_transaction { sender entry_function_id_str } fungible_asset_activities(where: {asset_type: {_in: ["0x1::aptos_coin::AptosCoin", "0x000000000000000000000000000000000000000000000000000000000000000a"]}}) { owner_address type amount is_gas_fee is_transaction_success transaction_timestamp } } }"#

    /// As ultimas transacoes da conta pelo indexador GraphQL da Aptos Labs.
    public func history(owner: AptosAddress) async throws -> ActivityPage {
        guard let indexer else { throw ReaderError.unsupported("historico sem indexador") }
        let body: StrictJSON = .object([
            "query": .string(Self.historyQuery),
            "variables": .object(["owner": .string(owner.hex), "limit": .int(ActivityRules.pageSize)]),
        ])
        let json = try StrictJSON.parse(try await transport.send(ReaderRequest(method: .post, url: indexer, body: body.serialized, timeout: 30)))
        return try Self.parseHistory(json, owner: owner)
    }

    // MARK: Transporte

    struct Ledger: Sendable, Equatable {
        let chainID: UInt8
        let version: UInt64
        let timestampMicros: UInt64
    }

    /// O indice do no (`GET /v1`): rede, versao e hora do ledger. Outra rede e recusa.
    func ledger(_ provider: Provider) async throws -> Ledger {
        let ledger = try Self.parseLedger(StrictJSON.parse(try await transport.send(.get(provider.baseURL))))
        guard ledger.chainID == AptosPlanner.mainnetChainID else { throw ReaderError.wrongNetwork }
        return ledger
    }

    /// Antes de simular, transmitir ou acompanhar: o no e da rede principal.
    private func ensureMainnet(_ provider: Provider) async throws {
        _ = try await ledger(provider)
    }

    /// Uma view (`POST /v1/view`), numa versao fixa do ledger quando `version` vem.
    private func view(_ provider: Provider, _ version: UInt64?, _ function: String, _ types: [String], _ arguments: [String]) async throws -> StrictJSON {
        var url = provider.baseURL.adding(path: "view")
        if let version { url = url.adding(query: [("ledger_version", String(version))]) }
        let body: StrictJSON = .object([
            "function": .string(function),
            "type_arguments": .array(types.map(StrictJSON.string)),
            "arguments": .array(arguments.map(StrictJSON.string)),
        ])
        return try StrictJSON.parse(try await transport.send(.post(url, body)))
    }

    /// A mesma leitura em dois provedores, na menor versao do ledger que os dois informam.
    /// Valores diferentes na mesma versao sao um provedor trocando dado.
    private func pinned<T: Sendable & Equatable>(
        field: String, _ read: @escaping @Sendable (Provider, UInt64) async throws -> T
    ) async throws -> (value: T, ledger: Ledger) {
        let ledgers = try await Quorum.collect(await pool.available(), pool: pool, count: 2) { provider in
            try await self.ledger(provider)
        }
        let first = ledgers[0], second = ledgers[1]
        let base = first.value.version <= second.value.version ? first.value : second.value
        async let a = read(first.provider, base.version)
        async let b = read(second.provider, base.version)
        let (x, y) = try await (a, b)
        guard x == y else { throw ReaderError.providersDisagree(field: field) }
        return (x, base)
    }

    /// Diferenca na primeira vez rele uma vez (o preco do gas muda entre leituras).
    private func agreedTwice<T: Sendable>(_ read: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await read()
        } catch ReaderError.providersDisagree {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return try await read()
        }
    }

    // MARK: Parse

    static func parseLedger(_ json: StrictJSON) throws -> Ledger {
        let path = "index"
        guard let chain = UInt8(exactly: try json.field("chain_id", path).uint64(path + ".chain_id")) else {
            throw ReaderError.malformed(field: path + ".chain_id")
        }
        let version = try json.field("ledger_version", path).decimalString(path + ".ledger_version")
        let timestamp = try json.field("ledger_timestamp", path).decimalString(path + ".ledger_timestamp")
        guard let v = version.uint64, let t = timestamp.uint64 else { throw ReaderError.malformed(field: path) }
        return Ledger(chainID: chain, version: v, timestampMicros: t)
    }

    static func single(_ json: StrictJSON, _ path: String) throws -> StrictJSON {
        let values = try json.array(path)
        guard values.count == 1 else { throw ReaderError.malformed(field: path) }
        return values[0]
    }

    /// `["123"]`: u64 em texto decimal.
    static func parseU64View(_ json: StrictJSON, _ path: String) throws -> UInt64 {
        guard let value = try single(json, path).decimalString(path).uint64 else { throw ReaderError.malformed(field: path) }
        return value
    }

    /// `["0x..."]`: 32 bytes em hex.
    static func parseBytesView(_ json: StrictJSON, _ path: String) throws -> [UInt8] {
        let text = try single(json, path).string(path)
        guard text.hasPrefix("0x"), let bytes = Hex.decode(text), bytes.count == 32 else { throw ReaderError.malformed(field: path) }
        return bytes
    }

    static func parseBoolView(_ json: StrictJSON, _ path: String) throws -> Bool {
        try single(json, path).bool(path)
    }

    static func parseGasPrice(_ json: StrictJSON) throws -> UInt64 {
        try json.field("gas_estimate", "estimate_gas_price").uint64("estimate_gas_price.gas_estimate")
    }

    /// Endereco que o no escreve: "0x" e ate 64 digitos (o no corta zeros a esquerda so nos
    /// especiais, mas a leitura aceita qualquer comprimento e completa com zeros).
    static func address(_ json: StrictJSON, _ path: String) throws -> AptosAddress {
        let text = try json.string(path)
        let digits = text.hasPrefix("0x") ? String(text.dropFirst(2)) : ""
        guard (1...64).contains(digits.count), let bytes = Hex.decode(String(repeating: "0", count: 64 - digits.count) + digits),
              let address = AptosAddress(bytes: bytes)
        else { throw ReaderError.malformed(field: path) }
        return address
    }

    /// A resposta de `/transactions/simulate`: um `UserTransaction` com sucesso, gas usado,
    /// hash e eventos. Os eventos que importam viram casos; o resto fica pelo tipo.
    static func parseSimulation(_ json: StrictJSON) throws -> AptosSimulation {
        let path = "simulate"
        let tx = try single(json, path)
        let success = try tx.field("success", path).bool(path + ".success")
        guard let gasUsed = try tx.field("gas_used", path).decimalString(path + ".gas_used").uint64 else {
            throw ReaderError.malformed(field: path + ".gas_used")
        }
        let hash = try tx.field("hash", path).string(path + ".hash")
        var events: [AptosSimulation.Event] = []
        for (index, event) in try tx.field("events", path).array(path + ".events").enumerated() {
            let eventPath = path + ".events[\(index)]"
            let type = try event.field("type", eventPath).string(eventPath + ".type")
            let data = try event.field("data", eventPath)
            switch type {
            case "0x1::fungible_asset::Withdraw", "0x1::fungible_asset::Deposit":
                let store = try address(try data.field("store", eventPath), eventPath + ".store")
                guard let amount = try data.field("amount", eventPath).decimalString(eventPath + ".amount").uint64 else {
                    throw ReaderError.malformed(field: eventPath + ".amount")
                }
                events.append(type.hasSuffix("Withdraw") ? .withdraw(store: store, amount: amount) : .deposit(store: store, amount: amount))
            case "0x1::transaction_fee::FeeStatement":
                guard let units = try data.field("total_charge_gas_units", eventPath).decimalString(eventPath + ".total").uint64 else {
                    throw ReaderError.malformed(field: eventPath + ".total_charge_gas_units")
                }
                events.append(.fee(totalGasUnits: units))
            default:
                events.append(.other(ReaderError.sanitized(type)))
            }
        }
        return AptosSimulation(success: success, gasUsed: gasUsed, hash: hash, events: events)
    }

    /// `/transactions/by_hash/{h}`: pendente, ou executada com sucesso ou falha e a versao.
    static func parseLookup(_ json: StrictJSON, hash: String) throws -> Lookup {
        let path = "by_hash"
        guard try json.field("hash", path).string(path + ".hash").lowercased() == hash else {
            throw ReaderError.responseMismatch(field: path + ".hash")
        }
        switch try json.field("type", path).string(path + ".type") {
        case "pending_transaction":
            return .pending
        case "user_transaction":
            let success = try json.field("success", path).bool(path + ".success")
            guard let version = try json.field("version", path).decimalString(path + ".version").uint64 else {
                throw ReaderError.malformed(field: path + ".version")
            }
            return .committed(success: success, version: version)
        default:
            throw ReaderError.malformed(field: path + ".type")
        }
    }

    /// "2026-09-28T04:44:00" ou com fracao de segundo, em UTC, como o indexador escreve.
    static func indexerDate(_ text: String) -> Date? {
        let parts = text.split(separator: "T")
        guard parts.count == 2 else { return nil }
        let day = parts[0].split(separator: "-").compactMap { Int($0) }
        let clock = parts[1].split(separator: ".")[0].split(separator: ":").compactMap { Int($0) }
        guard day.count == 3, clock.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: day[0], month: day[1], day: day[2], hour: clock[0], minute: clock[1], second: clock[2]))
    }

    static let withdrawTypes: Set<String> = ["0x1::fungible_asset::Withdraw", "0x1::coin::WithdrawEvent", "0x1::coin::CoinWithdraw"]
    static let depositTypes: Set<String> = ["0x1::fungible_asset::Deposit", "0x1::coin::DepositEvent", "0x1::coin::CoinDeposit"]

    /// O historico do indexador. Cada transacao vira no maximo um item: o que saiu da
    /// conta (envio, com a contraparte que recebeu), o que entrou (recebimento, com quem
    /// enviou) ou uma acao da conta sem movimento de APT (so a taxa). O id e a versao do
    /// ledger: o indexador nao devolve o hash, e o explorador abre pelos dois.
    static func parseHistory(_ json: StrictJSON, owner: AptosAddress) throws -> ActivityPage {
        if json.optionalField("errors") != nil { throw ReaderError.providerError(code: "graphql") }
        let native = Asset.native(.aptos)
        var items: [ActivityItem] = []
        var suspicious = SuspiciousSummary()
        let list = try json.field("data", "graphql").field("account_transactions", "graphql.data").array("account_transactions")
        for (offset, entry) in list.enumerated() {
            let path = "account_transactions[\(offset)]"
            let version = try entry.field("transaction_version", path).uint64(path + ".transaction_version")
            let user = entry.optionalField("user_transaction")
            let sender = try user.map { try address(try $0.field("sender", path), path + ".sender") }
            var withdrawn = BigUInt(), deposited = BigUInt(), fee = BigUInt()
            var success = true
            var zeroDeposit = false
            var date: Date?
            var receivers: [AptosAddress] = [], payers: [AptosAddress] = []
            for (index, activity) in try entry.field("fungible_asset_activities", path).array(path + ".activities").enumerated() {
                let activityPath = path + ".activities[\(index)]"
                let who = try address(try activity.field("owner_address", activityPath), activityPath + ".owner_address")
                let type = try activity.field("type", activityPath).string(activityPath + ".type")
                let amount = try activity.field("amount", activityPath).integer(activityPath + ".amount")
                let gas = try activity.field("is_gas_fee", activityPath).bool(activityPath + ".is_gas_fee")
                let ok = try activity.field("is_transaction_success", activityPath).bool(activityPath + ".is_transaction_success")
                success = success && ok
                let stamp = try activity.field("transaction_timestamp", activityPath).string(activityPath + ".transaction_timestamp")
                if date == nil { date = indexerDate(stamp) }
                if who == owner {
                    if gas {
                        fee = fee + amount
                    } else if withdrawTypes.contains(type) {
                        withdrawn = withdrawn + amount
                    } else if depositTypes.contains(type) {
                        deposited = deposited + amount
                        zeroDeposit = zeroDeposit || amount.isZero
                    }
                } else if !gas {
                    if depositTypes.contains(type), !receivers.contains(who) { receivers.append(who) }
                    if withdrawTypes.contains(type), !payers.contains(who) { payers.append(who) }
                }
            }
            guard let date else { continue }
            let status: ActivityItem.Status = success ? .confirmed : .failed
            let explorer = Chain.aptos.explorerURL(tx: String(version))
            let ownerSent = sender == owner
            let direction: ActivityItem.Direction
            let amount: BigUInt
            let counterparty: String?
            if !withdrawn.isZero, deposited.isZero {
                direction = .sent; amount = withdrawn
                counterparty = receivers.count == 1 ? receivers[0].hex : nil
            } else if !deposited.isZero, withdrawn.isZero {
                direction = .received; amount = deposited
                counterparty = (sender.flatMap { $0 == owner ? nil : $0 } ?? (payers.count == 1 ? payers[0] : nil))?.hex
                if let suspicion = ActivityRules.judgeIncoming(asset: native, amount: amount) {
                    ActivityRules.count(suspicion, in: &suspicious)
                    continue
                }
            } else if !withdrawn.isZero || ownerSent {
                direction = .other; amount = withdrawn; counterparty = nil
            } else {
                // Transacao de outro que toca a conta sem mover APT para ela: deposito de
                // valor zero (o que planta endereco sosia) ou de outro ativo, fora da lista.
                ActivityRules.count(zeroDeposit ? .zeroValue : .unknownAsset, in: &suspicious)
                continue
            }
            items.append(ActivityItem(
                id: "aptos:\(version)", chainID: Chain.aptos.id, direction: direction, asset: native, amount: amount,
                counterparty: counterparty, date: date, status: status,
                fee: ownerSent && !fee.isZero ? fee : nil, hash: String(version), explorerURL: explorer
            ))
        }
        return ActivityRules.page(chainID: Chain.aptos.id, items: items, suspicious: suspicious)
    }
}
