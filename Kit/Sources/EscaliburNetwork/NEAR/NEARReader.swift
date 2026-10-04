import EscaliburChains
import EscaliburCore
import Foundation

/// Leitura de estado, transmissao, acompanhamento e historico da NEAR, pelo JSON-RPC de
/// quatro operadores sem chave (`Endpoints.near`) e pela API de transacoes da FastNEAR.
///
/// O que decide o dinheiro vem de dois provedores concordando, no mesmo bloco
/// (docs/seguranca.md §5.5):
/// - o bloco de referencia: o final mais baixo de dois provedores, com o hash igual em
///   dois. O hash vai na transacao, e todo o resto e lido nele;
/// - a conta do dono (saldo, stake, armazenamento, contrato), a chave de acesso dele
///   (nonce e permissao), a conta de destino (existe ou nao, e se tem contrato), o preco
///   do gas e as regras do protocolo que entram na taxa e no saldo preso por
///   armazenamento, tudo igual nos dois;
/// - a rede (`chain_id` e genese), conferida uma vez por provedor contra a compilada, e o
///   `chain_id` de novo nas regras de cada leitura.
///
/// Uma fonte so, com o motivo: o saldo da tela (exibicao; o plano rele nos dois) e o
/// historico (informativo, da FastNEAR; o RPC nao lista transacoes por conta).
public actor NEARReader {
    public static let shared = NEARReader()

    let transport: ReaderTransport
    let providers: [ProviderPool.Provider]
    let pool: ProviderPool
    let historyURL: URL
    /// Quais tokens NEP-141 a conta tem (`api.fastnear.com`). Nil: so o NEAR.
    let tokensURL: URL?
    private var verifiedNetwork: Set<String> = []
    private var tracked: [String: Tracked] = [:]

    /// Uma transacao transmitida por este aparelho: quem assinou (o `tx` do RPC pede) e a
    /// altura final quando saiu, para saber quando "nao encontrada" vira "venceu".
    struct Tracked: Sendable {
        let signer: String
        let height: UInt64
    }

    public init(
        transport: ReaderTransport = HTTPClient.shared, providers: [ProviderPool.Provider] = Endpoints.near,
        history: URL = Endpoints.nearHistory, tokens: URL? = Endpoints.nearTokens, pacing: TimeInterval = 0.1
    ) {
        // Os nos publicos limitam por IP. Um decimo de segundo entre chamadas ao mesmo
        // host, e o 429 repete uma vez.
        let hosts = (providers.map(\.baseURL) + [history] + [tokens].compactMap { $0 }).compactMap(\.host)
        self.transport = PacedTransport(base: transport, intervals: Dictionary(hosts.map { ($0, pacing) }, uniquingKeysWith: { a, _ in a }))
        self.providers = providers
        self.pool = ProviderPool(providers)
        self.historyURL = history
        self.tokensURL = tokens
    }

    // MARK: Estado para o plano

    /// O que o plano precisa, no bloco de referencia e igual em dois provedores. `sender`
    /// nil: a conta do dono ainda nao existe. `accessKey` nil: a chave nao esta na conta.
    public struct Reading: Equatable, Sendable {
        public let checkpoint: NEARCheckpoint
        public let sender: NEARAccountState?
        public let accessKey: NEARAccessKeyState?
        public let destination: NEARAccountState?
        public let rules: NEARProtocolRules
    }

    struct Answer: Equatable, Sendable {
        let sender: NEARAccountState?
        let accessKey: NEARAccessKeyState?
        let destination: NEARAccountState?
        let rules: NEARProtocolRules
    }

    public func state(owner: NEARAccountID, publicKey: [UInt8], destination: NEARAccountID) async throws -> Reading {
        guard publicKey.count == 32 else { throw ReaderError.invalidInput("publicKey") }
        let checkpoint = try await checkpoint()
        let at = Base58.bitcoin.encode(checkpoint.hash)
        let key = "ed25519:" + Base58.bitcoin.encode(publicKey)
        let answer = try await Quorum.agree(await live(), pool: pool, field: "state") { provider in
            try await self.ensureNetwork(provider)
            async let sender = self.account(provider, owner.text, at: at)
            async let access = self.accessKey(provider, owner.text, key: key, at: at)
            async let target = self.account(provider, destination.text, at: at)
            async let rules = self.rules(provider, at: at)
            return Answer(sender: try await sender, accessKey: try await access, destination: try await target, rules: try await rules)
        }
        return Reading(checkpoint: checkpoint, sender: answer.sender, accessKey: answer.accessKey, destination: answer.destination, rules: answer.rules)
    }

    /// A conta de destino no bloco de referencia, igual em dois provedores. Para a tela do
    /// destino; o plano le de novo em `state`.
    public func destination(_ account: NEARAccountID) async throws -> NEARAccountState? {
        let checkpoint = try await checkpoint()
        let at = Base58.bitcoin.encode(checkpoint.hash)
        return try await Quorum.agree(await live(), pool: pool, field: "destination") { provider in
            try await self.ensureNetwork(provider)
            return OptionalAccount(value: try await self.account(provider, account.text, at: at))
        }.value
    }

    struct OptionalAccount: Equatable, Sendable { let value: NEARAccountState? }

    /// O final mais baixo de dois provedores, e o hash dele igual em dois.
    func checkpoint() async throws -> NEARCheckpoint {
        let providers = await live()
        let heads = try await Quorum.collect(providers, pool: pool, count: 2) { provider in
            try await self.ensureNetwork(provider)
            return try Self.header(try await self.call(provider, "block", .object(["finality": .string("final")]))).height
        }
        guard let height = heads.map(\.value).min() else { throw ReaderError.notEnoughProviders(needed: 2, got: 0) }
        let hash = try await Quorum.agree(providers, pool: pool, field: "checkpoint") { provider in
            try await self.ensureNetwork(provider)
            let header = try Self.header(try await self.call(provider, "block", .object(["block_id": .int(height)])))
            guard header.height == height else { throw ReaderError.responseMismatch(field: "block.height") }
            return header.hash
        }
        return NEARCheckpoint(height: height, hash: hash)
    }

    // MARK: Saldo da tela

    /// O saldo livre (fora do stake), num provedor (o primeiro que responde). So
    /// exibicao: o plano rele nos dois.
    public func displayBalance(owner text: String) async throws -> ChainBalance {
        guard case .success(let owner) = NEARAccountID.parse(text) else { throw ReaderError.invalidInput("account") }
        let state = try await Quorum.first(await live(), pool: pool) { provider in
            try await self.ensureNetwork(provider)
            return OptionalAccount(value: try await self.account(provider, owner.text, at: nil))
        }.value
        let unlisted = try? await otherTokens(owner.text)
        return ChainBalance(
            chainID: Chain.near.id, holdings: [Holding(asset: .native(.near), amount: state?.amount ?? 0)],
            accountExists: state != nil, unknownTokenCount: 0, fetchedAt: .now, unlisted: unlisted.map(UnlistedHolding.sorted)
        )
    }

    /// Os tokens NEP-141 com saldo pela FastNEAR; nome, simbolo e casas de cada um pelo
    /// `ft_metadata` do proprio contrato, num no da lista.
    func otherTokens(_ owner: String) async throws -> [UnlistedHolding] {
        guard let tokensURL else { throw ReaderError.unsupported("sem indexador de tokens") }
        let list = try StrictJSON.parse(try await transport.send(.get(tokensURL.adding(path: "v1/account/\(owner)/ft"), timeout: 20)))
        var out: [UnlistedHolding] = []
        for (contract, amount) in Self.ftBalances(list).prefix(20) {
            let metadata = try? await Quorum.first(await live(), pool: pool) { provider in
                let result = try await self.call(provider, "query", .object([
                    "request_type": .string("call_function"), "finality": .string("final"), "account_id": .string(contract),
                    "method_name": .string("ft_metadata"), "args_base64": .string("e30="),
                ]))
                return try Self.ftMetadata(result)
            }
            out.append(UnlistedHolding.make(
                chain: .near, kind: .token(contract: contract), symbol: metadata?.symbol ?? "", name: metadata?.name ?? "",
                decimals: metadata?.decimals ?? 0, amount: amount
            ))
        }
        return out
    }

    static func ftBalances(_ json: StrictJSON) -> [(contract: String, amount: BigUInt)] {
        ((try? json.field("tokens", "ft").array("tokens")) ?? []).compactMap { token in
            guard let contract = try? token.field("contract_id", "token").string("contract_id"),
                  case .success = NEARAccountID.parse(contract),
                  let amount = try? token.field("balance", "token").decimalString("balance"), !amount.isZero
            else { return nil }
            return (contract, amount)
        }
    }

    /// O retorno de `ft_metadata`: bytes de um JSON com `name`, `symbol` e `decimals`.
    static func ftMetadata(_ result: StrictJSON) throws -> (name: String, symbol: String, decimals: Int) {
        let bytes = try result.field("result", "query").array("result").map { try UInt8(exactly: $0.uint64("byte")) ?? { throw ReaderError.malformed(field: "byte") }() }
        let json = try StrictJSON.parse(Data(bytes))
        let decimals = try json.field("decimals", "ft_metadata").uint64("decimals")
        guard decimals <= 36 else { throw ReaderError.implausibleValue(field: "decimals") }
        return (
            (try? json.field("name", "ft_metadata").string("name")) ?? "",
            (try? json.field("symbol", "ft_metadata").string("symbol")) ?? "",
            Int(decimals)
        )
    }

    // MARK: Transmissao e acompanhamento

    /// Os mesmos bytes para dois provedores, com `send_tx` esperando a inclusao num bloco:
    /// o no confere assinatura, nonce e saldo antes de responder, e diz por que recusou.
    /// Aceita se um aceitou; o hash que o no devolve, quando devolve, tem de ser o
    /// calculado aqui.
    public func broadcast(_ signed: SignedTransaction) async throws -> BroadcastReceipt {
        guard let parsed = try? NEARSignedTransaction.parse(signed) else { throw ReaderError.broadcastMismatch }
        let id = signed.id
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
        let receipt = try tally.receipt(chainID: Chain.near.id, id: id)
        let height = (try? await Quorum.first(await live(), pool: pool) { provider in
            try Self.header(try await self.call(provider, "block", .object(["finality": .string("final")]))).height
        }) ?? 0
        track(id, signer: parsed.fields.signer.text, height: height)
        return receipt
    }

    /// Anota quem assinou e a altura da transmissao. So na memoria.
    func track(_ id: String, signer: String, height: UInt64) {
        tracked[id] = Tracked(signer: signer, height: height)
    }

    private func submit(_ provider: ProviderPool.Provider, _ encoded: String, id: String) async -> Result<String, Error> {
        do {
            let result = try await call(provider, "send_tx", .object([
                "signed_tx_base64": .string(encoded), "wait_until": .string("INCLUDED"),
            ]), timeout: 30)
            if let hash = try? result.field("transaction", "send_tx").field("hash", "send_tx.transaction").string("hash"), hash != id {
                return .failure(ReaderError.broadcastMismatch)
            }
            return .success(id)
        } catch RPCFailure.error(let cause, let data) {
            guard cause == "INVALID_TRANSACTION" else {
                return .failure(ReaderError.providerError(code: ReaderError.sanitized(cause)))
            }
            let reason = Self.rejection(data)
            return .failure(ReaderError.broadcastRejected(reason, code: ReaderError.sanitized(reason.rawValue)))
        } catch {
            return .failure(error)
        }
    }

    /// O resultado em dois provedores (`tx`, que pede quem assinou). Final so com os dois
    /// dizendo o mesmo num bloco final. Sem registro (o app foi reaberto), nao ha a quem
    /// perguntar, e fica `notFound`. Nao encontrada nos dois depois da validade: venceu.
    public func status(of id: String) async throws -> TransactionStatus {
        guard let digest = Base58.bitcoin.decode(id), digest.count == 32 else { throw ReaderError.invalidInput("id") }
        guard let entry = tracked[id] else { return .notFound }
        let readings = try await Quorum.collect(await live(), pool: pool, count: 2) { provider in
            try await self.transactionStatus(provider, id: id, signer: entry.signer)
        }.map(\.value)
        if let first = readings.first, let agreed = first, readings.allSatisfy({ $0 == agreed }) { return agreed }
        if readings.contains(where: { $0 != nil }) { return .pending }
        let height = try await Quorum.first(await live(), pool: pool) { provider in
            try Self.header(try await self.call(provider, "block", .object(["finality": .string("final")]))).height
        }
        if entry.height > 0, height > entry.height + NEARRules.validityBlocks { return .failed(reason: "expired") }
        return .notFound
    }

    /// `nil`: o no nao conhece a transacao. `.pending` enquanto nao e final.
    private nonisolated func transactionStatus(_ provider: ProviderPool.Provider, id: String, signer: String) async throws -> TransactionStatus? {
        do {
            let result = try await call(provider, "tx", .object([
                "tx_hash": .string(id), "sender_account_id": .string(signer), "wait_until": .string("NONE"),
            ]))
            return try Self.parseOutcome(result, id: id)
        } catch RPCFailure.error(let cause, _) where cause == "UNKNOWN_TRANSACTION" {
            return nil
        } catch RPCFailure.error(let cause, _) {
            throw ReaderError.providerError(code: ReaderError.sanitized(cause))
        }
    }

    // MARK: Historico

    /// As ultimas transacoes da conta pela FastNEAR: a lista (`/v0/account`) e os
    /// detalhes das 20 mais novas (`/v0/transactions`), com a conta so no corpo do POST.
    /// Informativo.
    public func history(owner text: String) async throws -> ActivityPage {
        guard case .success(let owner) = NEARAccountID.parse(text) else { throw ReaderError.invalidInput("account") }
        let list = try StrictJSON.parse(try await transport.send(ReaderRequest(
            method: .post, url: historyURL.adding(path: "v0/account"),
            body: StrictJSON.object(["account_id": .string(owner.text)]).serialized, timeout: 30
        )))
        let hashes = try Self.latestHashes(list, owner: owner, limit: Self.historyDetails)
        guard !hashes.isEmpty else { return ActivityRules.page(chainID: Chain.near.id, items: [], suspicious: SuspiciousSummary()) }
        let details = try await transport.send(ReaderRequest(
            method: .post, url: historyURL.adding(path: "v0/transactions"),
            body: StrictJSON.object(["tx_hashes": .array(hashes.map { .string($0) })]).serialized, timeout: 30
        ))
        return try Self.parseHistory(details, owner: owner, requested: Set(hashes))
    }

    /// A API da FastNEAR entrega no maximo 20 transacoes por consulta de detalhes.
    static let historyDetails = 20

    // MARK: JSON-RPC

    /// Erro do no: o nome da causa (`UNKNOWN_ACCOUNT`, `INVALID_TRANSACTION`) e o `data`,
    /// lido so para classificar a recusa. Nada disso sai daqui como texto.
    enum RPCFailure: Error { case error(cause: String, data: StrictJSON?) }

    nonisolated func call(_ provider: ProviderPool.Provider, _ method: String, _ params: StrictJSON, timeout: TimeInterval = 10) async throws -> StrictJSON {
        let body = StrictJSON.object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string(method), "params": params])
        let data = try await transport.send(ReaderRequest(method: .post, url: provider.baseURL, body: body.serialized, timeout: timeout))
        return try Self.result(data, method: method)
    }

    static func result(_ data: Data, method: String) throws -> StrictJSON {
        let json = try StrictJSON.parse(data)
        if let error = json.optionalField("error") {
            let cause = (try? error.field("cause", "error").field("name", "error.cause").string("error.cause.name"))
                ?? (try? error.field("name", "error").string("error.name")) ?? "error"
            throw RPCFailure.error(cause: cause, data: error.optionalField("data"))
        }
        return try json.field("result", method)
    }

    /// `chain_id` e genese do provedor contra os compilados, uma vez por provedor.
    private func ensureNetwork(_ provider: ProviderPool.Provider) async throws {
        guard !verifiedNetwork.contains(provider.name) else { return }
        let status = try await call(provider, "status", .array([]))
        guard try status.field("chain_id", "status").string("status.chain_id") == NEARRules.chainID,
              try status.field("genesis_hash", "status").string("status.genesis_hash") == NEARRules.genesisHash
        else { throw ReaderError.wrongNetwork }
        verifiedNetwork.insert(provider.name)
    }

    private func live() async -> [ProviderPool.Provider] {
        let available = await pool.available()
        return available.isEmpty ? providers : available
    }

    /// `view_account` no bloco pedido (ou no final). Conta que nao existe: nil.
    private nonisolated func account(_ provider: ProviderPool.Provider, _ account: String, at block: String?) async throws -> NEARAccountState? {
        var params: [String: StrictJSON] = ["request_type": .string("view_account"), "account_id": .string(account)]
        params[block == nil ? "finality" : "block_id"] = .string(block ?? "final")
        do {
            return try Self.parseAccount(try await call(provider, "query", .object(params)), at: block)
        } catch RPCFailure.error(let cause, _) where cause == "UNKNOWN_ACCOUNT" {
            return nil
        } catch RPCFailure.error(let cause, _) {
            throw ReaderError.providerError(code: ReaderError.sanitized(cause))
        }
    }

    /// `view_access_key` da chave do dono. Chave que nao esta na conta (ou conta que nao
    /// existe): nil.
    private nonisolated func accessKey(_ provider: ProviderPool.Provider, _ account: String, key: String, at block: String) async throws -> NEARAccessKeyState? {
        do {
            let result = try await call(provider, "query", .object([
                "request_type": .string("view_access_key"), "account_id": .string(account),
                "public_key": .string(key), "block_id": .string(block),
            ]))
            return try Self.parseAccessKey(result, at: block)
        } catch RPCFailure.error(let cause, _) where cause == "UNKNOWN_ACCESS_KEY" || cause == "UNKNOWN_ACCOUNT" {
            return nil
        } catch RPCFailure.error(let cause, _) {
            throw ReaderError.providerError(code: ReaderError.sanitized(cause))
        }
    }

    /// As regras do protocolo e o preco do gas no bloco.
    private nonisolated func rules(_ provider: ProviderPool.Provider, at block: String) async throws -> NEARProtocolRules {
        do {
            async let config = call(provider, "EXPERIMENTAL_protocol_config", .object(["block_id": .string(block)]))
            async let gas = call(provider, "gas_price", .array([.string(block)]))
            return try Self.parseRules(try await config, gasPrice: try await gas)
        } catch RPCFailure.error(let cause, _) {
            throw ReaderError.providerError(code: ReaderError.sanitized(cause))
        }
    }

    // MARK: Leitura das respostas

    struct Header: Equatable, Sendable {
        let height: UInt64
        let hash: [UInt8]
    }

    static func header(_ block: StrictJSON) throws -> Header {
        let header = try block.field("header", "block")
        let height = try header.field("height", "block.header").uint64("block.header.height")
        let hash = try base58Hash(try header.field("hash", "block.header"), "block.header.hash")
        return Header(height: height, hash: hash)
    }

    static func base58Hash(_ value: StrictJSON, _ path: String) throws -> [UInt8] {
        guard let bytes = Base58.bitcoin.decode(try value.string(path)), bytes.count == 32 else {
            throw ReaderError.malformed(field: path)
        }
        return bytes
    }

    /// A resposta tem de ser do bloco pedido.
    static func checkBlock(_ result: StrictJSON, _ block: String?, _ path: String) throws {
        guard let block else { return }
        guard try result.field("block_hash", path).string(path + ".block_hash") == block else {
            throw ReaderError.responseMismatch(field: path + ".block_hash")
        }
    }

    static func parseAccount(_ result: StrictJSON, at block: String?) throws -> NEARAccountState {
        let path = "view_account"
        try checkBlock(result, block, path)
        return NEARAccountState(
            amount: try result.field("amount", path).decimalString(path + ".amount"),
            locked: try result.field("locked", path).decimalString(path + ".locked"),
            storageUsage: try result.field("storage_usage", path).uint64(path + ".storage_usage"),
            codeHash: try base58Hash(try result.field("code_hash", path), path + ".code_hash"),
            globalContract: result.optionalField("global_contract_hash") != nil || result.optionalField("global_contract_account_id") != nil
        )
    }

    /// `permission`: o texto `"FullAccess"` ou um objeto `FunctionCall`. Chave que nao
    /// esta na conta nao vem como erro do RPC: vem como resultado com um campo `error`
    /// ("access key ... does not exist while viewing", visto em 28/09/2026), e vale nil.
    static func parseAccessKey(_ result: StrictJSON, at block: String) throws -> NEARAccessKeyState? {
        let path = "view_access_key"
        try checkBlock(result, block, path)
        if let error = result.optionalField("error") {
            guard try error.string(path + ".error").contains("does not exist") else { throw ReaderError.providerError(code: "view_access_key") }
            return nil
        }
        let permission = try result.field("permission", path)
        let full: Bool
        if case .string(let text) = permission {
            guard text == "FullAccess" else { throw ReaderError.malformed(field: path + ".permission") }
            full = true
        } else {
            guard permission.objectValue != nil else { throw ReaderError.malformed(field: path + ".permission") }
            full = false
        }
        return NEARAccessKeyState(nonce: try result.field("nonce", path).uint64(path + ".nonce"), fullAccess: full)
    }

    /// `EXPERIMENTAL_protocol_config` e `gas_price`. Os dois campos do protocolo 85
    /// (`min_gas_purchase_price`, `account_creation_charge`) faltando valem zero, como
    /// antes dele.
    static func parseRules(_ config: StrictJSON, gasPrice: StrictJSON) throws -> NEARProtocolRules {
        let path = "protocol_config"
        let runtime = try config.field("runtime_config", path)
        let costs = try runtime.field("transaction_costs", path + ".runtime_config")
        let actions = try costs.field("action_creation_config", path + ".transaction_costs")
        func fee(_ value: StrictJSON, _ name: String) throws -> NEARActionFee {
            NEARActionFee(
                sendNotSir: try value.field("send_not_sir", name).uint64(name + ".send_not_sir"),
                execution: try value.field("execution", name).uint64(name + ".execution")
            )
        }
        func optionalAmount(_ key: String) throws -> BigUInt {
            try runtime.optionalField(key)?.decimalString(path + "." + key) ?? 0
        }
        return NEARProtocolRules(
            chainID: try config.field("chain_id", path).string(path + ".chain_id"),
            gasPrice: try gasPrice.field("gas_price", "gas_price").decimalString("gas_price.gas_price"),
            minGasPurchasePrice: try optionalAmount("min_gas_purchase_price"),
            accountCreationCharge: try optionalAmount("account_creation_charge"),
            storageAmountPerByte: try runtime.field("storage_amount_per_byte", path).decimalString(path + ".storage_amount_per_byte"),
            actionReceipt: try fee(try costs.field("action_receipt_creation_config", path), "action_receipt_creation_config"),
            transfer: try fee(try actions.field("transfer_cost", path), "transfer_cost"),
            createAccount: try fee(try actions.field("create_account_cost", path), "create_account_cost"),
            addFullAccessKey: try fee(try actions.field("add_key_cost", path).field("full_access_cost", "add_key_cost"), "full_access_cost")
        )
    }

    /// O resultado de `tx`/`send_tx`: final so com `final_execution_status` FINAL. A
    /// transacao da resposta tem de ser a pedida.
    static func parseOutcome(_ result: StrictJSON, id: String) throws -> TransactionStatus {
        let path = "tx"
        if let transaction = result.optionalField("transaction"),
           try transaction.field("hash", path + ".transaction").string(path + ".transaction.hash") != id {
            throw ReaderError.responseMismatch(field: path + ".transaction.hash")
        }
        guard try result.field("final_execution_status", path).string(path + ".final_execution_status") == "FINAL" else {
            return .pending
        }
        let status = try result.field("status", path)
        if status.optionalField("Failure") != nil { return .failed(reason: "action") }
        guard status.optionalField("SuccessValue") != nil || status.optionalField("SuccessReceiptId") != nil else { return .pending }
        return .confirmed(block: nil, confirmations: nil)
    }

    /// Classifica a recusa do no pelo nome da variante de `InvalidTxError`. O `data` e
    /// lido aqui e descartado: pode trazer conta e valor.
    static func rejection(_ data: StrictJSON?) -> BroadcastRejection {
        let text = data.map { StrictJSON.serialize($0) } ?? ""
        if text.contains("InvalidSignature") { return .invalidSignature }
        if text.contains("InvalidNonce") { return .nonceTooLow }
        if text.contains("NonceTooLarge") { return .nonceTooHigh }
        if text.contains("NotEnoughBalance") || text.contains("LackBalanceForState") { return .insufficientFunds }
        if text.contains("Expired") { return .expired }
        if text.contains("InvalidChain") { return .wrongNetwork }
        return .other
    }

    /// As transacoes mais novas da lista (`account_txs`), sem repetir, com a conta
    /// conferida.
    static func latestHashes(_ list: StrictJSON, owner: NEARAccountID, limit: Int) throws -> [String] {
        let entries = try list.field("account_txs", "history").array("history.account_txs")
        var rows: [(height: UInt64, hash: String)] = []
        for entry in entries {
            guard try entry.field("account_id", "history.tx").string("history.account_id") == owner.text else {
                throw ReaderError.responseMismatch(field: "history.account_id")
            }
            let hash = try entry.field("transaction_hash", "history.tx").string("history.transaction_hash")
            guard Base58.bitcoin.decode(hash)?.count == 32 else { throw ReaderError.malformed(field: "history.transaction_hash") }
            rows.append((try entry.field("tx_block_height", "history.tx").uint64("history.tx_block_height"), hash))
        }
        var seen = Set<String>()
        return rows.sorted { $0.height > $1.height }.map(\.hash).filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
    }

    /// Cada transacao vira:
    /// - assinada pelo dono com uma so transferencia: envio, com a taxa de tudo que ela
    ///   queimou (a conversao e os recibos, sem os reembolsos);
    /// - outra coisa assinada pelo dono: "outra", sem valor;
    /// - recibo de transferencia para o dono, vindo de qualquer conta que nao a propria
    ///   rede (reembolso de gas e de deposito, `system`) nem o dono: recebimento, que passa
    ///   pelas regras de valor zero e po.
    static func parseHistory(_ data: Data, owner: NEARAccountID, requested: Set<String>) throws -> ActivityPage {
        let list = try StrictJSON.parse(data).field("transactions", "history").array("history.transactions")
        let asset = Asset.native(.near)
        var items: [ActivityItem] = []
        var suspicious = SuspiciousSummary()
        for entry in list {
            let path = "history.transaction"
            let transaction = try entry.field("transaction", path)
            let hash = try transaction.field("hash", path).string(path + ".hash")
            guard requested.contains(hash) else { throw ReaderError.responseMismatch(field: path + ".hash") }
            let signer = try transaction.field("signer_id", path).string(path + ".signer_id")
            let receiver = try transaction.field("receiver_id", path).string(path + ".receiver_id")
            let outcome = try entry.field("execution_outcome", path)
            let nanos = try outcome.field("block_timestamp", path + ".execution_outcome").uint64(path + ".block_timestamp")
            let date = Date(timeIntervalSince1970: TimeInterval(nanos / 1_000_000_000))
            let explorer = Chain.near.explorerURL(tx: hash)
            let receipts = try entry.field("receipts", path).array(path + ".receipts").map { try Receipt($0) }

            if signer == owner.text {
                let burnt = try outcome.field("outcome", path).field("tokens_burnt", path + ".outcome").decimalString(path + ".tokens_burnt")
                let fee = receipts.filter { $0.predecessor != "system" }.reduce(burnt) { $0 + $1.tokensBurnt }
                let actions = try transaction.field("actions", path).array(path + ".actions")
                let first = receipts.first { $0.predecessor == owner.text && $0.receiver == receiver }
                let status = first?.status ?? .pending
                if actions.count == 1, let deposit = try transferDeposit(actions[0]), receiver != owner.text {
                    items.append(ActivityItem(
                        id: "near:\(hash):out", chainID: Chain.near.id, direction: .sent, asset: asset, amount: deposit,
                        counterparty: receiver, date: date, status: status, fee: fee, hash: hash, explorerURL: explorer
                    ))
                } else {
                    items.append(ActivityItem(
                        id: "near:\(hash):out", chainID: Chain.near.id, direction: .other, asset: asset, amount: 0,
                        counterparty: receiver == owner.text ? nil : receiver, date: date, status: status, fee: fee, hash: hash,
                        explorerURL: explorer
                    ))
                }
            }
            for (index, receipt) in receipts.enumerated()
            where receipt.receiver == owner.text && receipt.predecessor != "system" && receipt.predecessor != owner.text {
                guard let amount = receipt.deposit else { continue }
                if receipt.status == .confirmed, let suspicion = ActivityRules.judgeIncoming(asset: asset, amount: amount) {
                    ActivityRules.count(suspicion, in: &suspicious)
                    continue
                }
                items.append(ActivityItem(
                    id: "near:\(hash):in\(index)", chainID: Chain.near.id, direction: .received, asset: asset, amount: amount,
                    counterparty: receipt.predecessor, date: date, status: receipt.status, fee: nil, hash: hash, explorerURL: explorer
                ))
            }
        }
        return ActivityRules.page(chainID: Chain.near.id, items: items, suspicious: suspicious)
    }

    /// O deposito de uma acao `Transfer`; nil para outra acao.
    static func transferDeposit(_ action: StrictJSON) throws -> BigUInt? {
        guard let transfer = action.optionalField("Transfer") else { return nil }
        return try transfer.field("deposit", "action.Transfer").decimalString("action.Transfer.deposit")
    }

    /// Um recibo do historico: quem mandou, quem recebeu, a soma das transferencias dele
    /// (nil sem transferencia), o que queimou e o resultado.
    struct Receipt {
        let predecessor: String
        let receiver: String
        let deposit: BigUInt?
        let tokensBurnt: BigUInt
        let status: ActivityItem.Status

        init(_ json: StrictJSON) throws {
            let path = "history.receipt"
            let body = try json.field("receipt", path)
            predecessor = try body.field("predecessor_id", path).string(path + ".predecessor_id")
            receiver = try body.field("receiver_id", path).string(path + ".receiver_id")
            var total: BigUInt?
            if let action = body.optionalField("receipt")?.optionalField("Action") {
                for item in try action.field("actions", path).array(path + ".actions") {
                    if let deposit = try NEARReader.transferDeposit(item) { total = (total ?? 0) + deposit }
                }
            }
            deposit = total
            let outcome = try json.field("execution_outcome", path).field("outcome", path + ".execution_outcome")
            tokensBurnt = try outcome.field("tokens_burnt", path).decimalString(path + ".tokens_burnt")
            let result = try outcome.field("status", path)
            if result.optionalField("Failure") != nil {
                status = .failed
            } else if result.optionalField("SuccessValue") != nil || result.optionalField("SuccessReceiptId") != nil {
                status = .confirmed
            } else {
                status = .pending
            }
        }
    }
}
