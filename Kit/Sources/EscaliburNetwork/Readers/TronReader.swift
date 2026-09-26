import EscaliburChains
import EscaliburCore
import Foundation

/// O destino de um envio Tron como a rede o ve, antes de haver valor e origem.
public struct TronDestinationState: Sendable, Equatable {
    /// `getaccount` do destino nao veio vazio, em dois provedores.
    public let activated: Bool
    /// `getcontract` devolveu bytecode.
    public let isContract: Bool
    /// `getchainparameters`: a taxa de criacao de conta sai daqui. Sem validar: quem
    /// valida a faixa e o `TronPlanner`, no plano.
    public let parameters: TronChainParameters

    public init(activated: Bool, isContract: Bool, parameters: TronChainParameters) {
        self.activated = activated
        self.isContract = isContract
        self.parameters = parameters
    }
}

/// Leitura de estado, transmissao e historico da Tron, pela API HTTP do java-tron
/// (`/wallet/*`, POST com o endereco no corpo) na TronGrid e na PublicNode.
///
/// O JSON da Tron e o protobuf em JSON (proto3): campo numerico igual a zero **nao
/// aparece**. `balance` ausente numa conta que existe e saldo zero, `EnergyLimit`
/// ausente e zero de stake. Cada leitura que usa isso diz; campo de outro tipo continua
/// sendo erro.
public actor TronReader {
    public static let shared = TronReader()

    let transport: ReaderTransport
    let pool: ProviderPool
    let historyProviders: [Provider]

    /// A transferencia planejada, para a estimativa de energy e as leituras do destino.
    public enum Intent: Sendable, Equatable {
        /// `amount` em sun.
        case trx(to: String, amount: BigUInt)
        /// `amount` em unidades de 6 casas.
        case usdt(to: String, amount: BigUInt)

        var destination: String {
            switch self {
            case .trx(let to, _), .usdt(let to, _): return to
            }
        }
    }

    public init(transport: ReaderTransport = HTTPClient.shared, providers: [ProviderPool.Provider] = Endpoints.tron + Endpoints.tronContingency) {
        // TronGrid sem chave: acima de ~2 requisicoes por segundo por IP passa a devolver
        // 429 por varios segundos; a tronstack recusa rajada com 503 (conferido em
        // 25/09/2026).
        self.transport = PacedTransport(base: transport, intervals: [
            "api.trongrid.io": Self.trongridInterval, "api.tronstack.io": Self.trongridInterval,
        ])
        self.pool = ProviderPool(providers)
        // Historico: so a TronGrid tem a API v1 de indexacao (`/v1/accounts/...`).
        self.historyProviders = providers.filter { $0.name == "trongrid" }
    }

    static let trongridInterval: TimeInterval = 0.5

    /// Ordem para leituras de um provedor so: quem nao tem limite apertado primeiro. A
    /// TronGrid sem chave fica para o consenso (onde dois sao perguntados) e para o
    /// historico, que so ela tem.
    static func singleReadOrder(_ providers: [Provider]) -> [Provider] {
        providers.filter { $0.name == "publicnode" } + providers.filter { $0.name != "publicnode" && $0.name != "trongrid" }
            + providers.filter { $0.name == "trongrid" }
    }

    /// Bloco com mais de uma hora de diferenca do relogio: no parado. O TaPoS ainda
    /// valeria (65.536 blocos), mas saldo e recursos lidos no mesmo no estariam velhos.
    static let maxBlockSkew: Int64 = 3_600_000

    // MARK: Estado para o plano

    /// Tudo que `TronPlanner` precisa: bloco para o TaPoS, saldos, recursos, parametros,
    /// o destino (ativado? contrato? ja tem USDT?), a energy da transferencia e a
    /// checagem de permissoes do dono.
    ///
    /// Saldos (TRX e USDT) vem de dois provedores e fica o menor: a API da Tron nao le em
    /// bloco fixo, e conta movimentada muda a cada bloco de 3 s. A checagem de
    /// permissoes tambem vem de dois, e basta um ver chave estranha para a conta ser
    /// tratada como comprometida.
    public func networkState(owner: TronAddress, intent: Intent, now: Date = .now) async throws -> TronNetworkState {
        guard let destination = TronAddress(base58: intent.destination) else { throw ReaderError.invalidInput("destino") }
        let providers = await pool.available()
        let singles = Self.singleReadOrder(providers)
        async let blockReading = nowBlock(singles, now: now)
        async let ownerReading = ownerAccount(owner, providers: providers)
        async let resourceReading = accountResources(owner, providers: singles)
        async let parameterReading = chainParameters(singles)
        async let activatedReading = isActivated(destination, providers: providers)
        async let contractReading = isContract(destination, providers: singles)
        async let ownerUSDT = usdtBalance(of: owner, providers: providers, pair: true)

        var energy: UInt64?
        var holdsUSDT: Bool?
        if case .usdt(_, let amount) = intent {
            async let estimate = transferEnergy(from: owner, to: destination, amount: amount, providers: singles)
            async let destinationUSDT = usdtBalance(of: destination, providers: singles, pair: false)
            energy = try await estimate
            let received = try await destinationUSDT
            holdsUSDT = !received.isZero
        }
        let (control, trx) = try await ownerReading
        return TronNetworkState(
            block: try await blockReading, trxBalance: trx, usdtBalance: try await ownerUSDT, resources: try await resourceReading,
            parameters: try await parameterReading, destinationActivated: try await activatedReading,
            destinationIsContract: try await contractReading, usdtEnergyEstimate: energy, destinationHoldsUSDT: holdsUSDT,
            ownerControl: control
        )
    }

    /// So a checagem de permissoes, para a importacao (docs/blockchain.md §2.6: o golpe
    /// da "seed com USDT").
    public func ownerControl(owner: TronAddress) async throws -> TronAccountControl {
        try await ownerAccount(owner, providers: await pool.available()).control
    }

    /// O destino antes do valor, sem conta de origem: existe na rede (dois provedores
    /// concordando, a mesma leitura do plano)? e contrato? E os parametros da rede, de
    /// onde sai o custo de ativar a conta. So para a tela do destino: o plano le tudo
    /// de novo em `networkState`.
    public func destinationState(_ address: TronAddress) async throws -> TronDestinationState {
        let providers = await pool.available()
        let singles = Self.singleReadOrder(providers)
        async let activated = isActivated(address, providers: providers)
        async let contract = isContract(address, providers: singles)
        async let parameters = chainParameters(singles)
        return TronDestinationState(
            activated: try await activated, isContract: try await contract, parameters: try await parameters
        )
    }

    // MARK: Transmissao e acompanhamento

    /// `POST /wallet/broadcasthex` com o hex da Transaction assinada, nos dois provedores.
    public func broadcast(_ signed: SignedTransaction) async throws -> BroadcastReceipt {
        guard signed.chainID == Chain.tron.id, Hex.decode(signed.encoded) == signed.raw,
              let rawData = Self.rawData(ofTransaction: signed.raw),
              Hex.encode(Hash.sha256(rawData)) == signed.id.lowercased()
        else { throw ReaderError.broadcastMismatch }
        let transport = self.transport
        let id = signed.id.lowercased()
        let targets = Array(await pool.available().prefix(2))
        var tally = BroadcastTally()
        await withTaskGroup(of: (Provider, Result<String, Error>).self) { group in
            for provider in targets {
                group.addTask {
                    do {
                        let json = try await Self.post(transport, provider, "wallet/broadcasthex", ["transaction": .string(signed.encoded)])
                        return (provider, .success(try Self.parseBroadcast(json, expectedID: id)))
                    } catch {
                        return (provider, .failure(error))
                    }
                }
            }
            for await (provider, result) in group {
                tally.add(result, provider: provider)
                if case .failure(let error) = result { await Quorum.record(error, provider, pool) }
            }
        }
        return try tally.receipt(chainID: Chain.tron.id, id: id)
    }

    /// `gettransactioninfobyid` no no solidificado, em dois provedores: final so quando os
    /// dois tem o mesmo resultado no mesmo bloco. No no comum (ainda nao solidificado),
    /// pendente. Sem nada nos dois e com `expiresAt` passado ha mais de dois minutos,
    /// vencida.
    public func status(of txID: String, expiresAt: Date? = nil, now: Date = .now) async throws -> TransactionStatus {
        guard let bytes = Hex.decode(txID), bytes.count == 32 else { throw ReaderError.invalidInput("txid") }
        let id = Hex.encode(bytes)
        let transport = self.transport
        let providers = await pool.available()
        let solid = try await Quorum.collect(providers, pool: pool, count: 2) { provider in
            try Self.parseTransactionInfo(try await Self.post(transport, provider, "walletsolidity/gettransactioninfobyid", ["value": .string(id)]), id: id)
        }.map(\.value)
        if let first = solid[0], solid[1] == first { return first }
        if solid.contains(where: { $0 != nil }) { return .pending }
        let head = try await Quorum.first(Self.singleReadOrder(providers), pool: pool) { provider in
            try Self.parseTransactionInfo(try await Self.post(transport, provider, "wallet/gettransactioninfobyid", ["value": .string(id)]), id: id)
        }
        if head != nil { return .pending }
        if let expiresAt, now.timeIntervalSince(expiresAt) > 120 { return .failed(reason: "expired") }
        return .notFound
    }

    // MARK: Historico

    /// TronGrid v1: `/v1/accounts/{a}/transactions` e `/transactions/trc20`. O endereco vai
    /// no caminho do GET, porque a API de indexacao so tem essa forma (docs/seguranca.md
    /// §5.3; o relay proprio resolve).
    public func history(address: TronAddress) async throws -> ActivityPage {
        guard !historyProviders.isEmpty else { throw ReaderError.unsupported("historico sem indexador") }
        let transport = self.transport
        let historyPool = ProviderPool(historyProviders)
        return try await Quorum.first(historyProviders, pool: historyPool) { provider in
            let base = provider.baseURL.adding(path: "v1/accounts/" + address.base58)
            let native = try await transport.send(.get(base.adding(path: "transactions").adding(query: [("limit", "\(ActivityRules.pageSize)")]), timeout: 30))
            let tokens = try await transport.send(.get(base.adding(path: "transactions/trc20").adding(query: [("limit", "50")]), timeout: 30))
            return try Self.parseHistory(owner: address, transactions: StrictJSON.parse(native), trc20: StrictJSON.parse(tokens))
        }
    }

    // MARK: Leituras

    private func nowBlock(_ providers: [Provider], now: Date) async throws -> TronBlockReference {
        let transport = self.transport
        return try await Quorum.first(providers, pool: pool) { provider in
            try Self.parseBlock(try await Self.post(transport, provider, "wallet/getnowblock", [:]), now: now)
        }
    }

    /// `getaccount` do dono em dois provedores, pela checagem de permissoes de
    /// EscaliburChains, mais o saldo de TRX.
    private func ownerAccount(_ owner: TronAddress, providers: [Provider]) async throws -> (control: TronAccountControl, trx: BigUInt) {
        let transport = self.transport
        let readings = try await Quorum.collect(providers, pool: pool, count: 2) { provider in
            let data = try await transport.send(.post(provider.baseURL.adding(path: "wallet/getaccount"), .object([
                "address": .string(owner.base58), "visible": .bool(true),
            ])))
            return try Self.parseOwnerAccount(data, owner: owner)
        }.map(\.value)
        return try Self.combine(readings)
    }

    private func accountResources(_ owner: TronAddress, providers: [Provider]) async throws -> TronAccountResources {
        let transport = self.transport
        return try await Quorum.first(providers, pool: pool) { provider in
            try Self.parseResources(try await Self.post(transport, provider, "wallet/getaccountresource", [
                "address": .string(owner.base58), "visible": .bool(true),
            ]))
        }
    }

    private func chainParameters(_ providers: [Provider]) async throws -> TronChainParameters {
        let transport = self.transport
        return try await Quorum.first(providers, pool: pool) { provider in
            try Self.parseChainParameters(try await Self.post(transport, provider, "wallet/getchainparameters", [:]))
        }
    }

    /// O destino existe na rede? Dois provedores concordando.
    private func isActivated(_ address: TronAddress, providers: [Provider]) async throws -> Bool {
        let transport = self.transport
        return try await Quorum.agree(providers, pool: pool, field: "getaccount") { provider in
            let json = try await Self.post(transport, provider, "wallet/getaccount", ["address": .string(address.base58), "visible": .bool(true)])
            guard let text = json.optionalField("address") else {
                guard json.objectValue?.isEmpty == true else { throw ReaderError.malformed(field: "getaccount.address") }
                return false
            }
            guard TronAddress(try text.string("getaccount.address")) == address else { throw ReaderError.responseMismatch(field: "getaccount.address") }
            return true
        }
    }

    /// `getcontract`: `{}` para conta comum; contrato traz `contract_address` e `bytecode`.
    private func isContract(_ address: TronAddress, providers: [Provider]) async throws -> Bool {
        let transport = self.transport
        return try await Quorum.first(providers, pool: pool) { provider in
            let json = try await Self.post(transport, provider, "wallet/getcontract", ["value": .string(address.base58), "visible": .bool(true)])
            guard let contract = json.optionalField("contract_address") else {
                guard json.objectValue != nil else { throw ReaderError.malformed(field: "getcontract") }
                return false
            }
            guard TronAddress(try contract.string("getcontract.contract_address")) == address else {
                throw ReaderError.responseMismatch(field: "getcontract.contract_address")
            }
            return true
        }
    }

    /// `balanceOf` no contrato do USDT (compilado em `TRC20.usdt`). Com `pair`, dois
    /// provedores e o menor valor.
    private func usdtBalance(of owner: TronAddress, providers: [Provider], pair: Bool) async throws -> BigUInt {
        let transport = self.transport
        let body: [String: StrictJSON] = [
            "owner_address": .string(owner.base58), "contract_address": .string(TRC20.usdt.contract.base58),
            "function_selector": .string("balanceOf(address)"), "parameter": .string(Hex.encode(TRC20.addressWord(owner))),
            "visible": .bool(true),
        ]
        let read: @Sendable (Provider) async throws -> BigUInt = { provider in
            let json = try await Self.post(transport, provider, "wallet/triggerconstantcontract", body)
            let (word, _) = try Self.parseConstantCall(json, field: "balanceOf")
            guard let value = TRC20.decodeUint256(word) else { throw ReaderError.malformed(field: "balanceOf.constant_result") }
            return value
        }
        guard pair else { return try await Quorum.first(providers, pool: pool, read) }
        let values = try await Quorum.collect(providers, pool: pool, count: 2, read).map(\.value)
        return values.min() ?? 0
    }

    /// Energy de `transfer(destino, valor)` do USDT, simulada com o dono como remetente.
    /// Reverter (saldo curto, conta bloqueada pelo emissor) e erro: a transacao real
    /// falharia e queimaria a energy.
    private func transferEnergy(from owner: TronAddress, to destination: TronAddress, amount: BigUInt, providers: [Provider]) async throws -> UInt64 {
        guard let word = amount.bigEndianBytes(padTo: 32) else { throw ReaderError.invalidInput("valor") }
        let transport = self.transport
        let body: [String: StrictJSON] = [
            "owner_address": .string(owner.base58), "contract_address": .string(TRC20.usdt.contract.base58),
            "function_selector": .string("transfer(address,uint256)"),
            "parameter": .string(Hex.encode(TRC20.addressWord(destination) + word)), "visible": .bool(true),
        ]
        return try await Quorum.first(providers, pool: pool) { provider in
            let json = try await Self.post(transport, provider, "wallet/triggerconstantcontract", body)
            return try Self.parseConstantCall(json, field: "transfer").energy
        }
    }

    // MARK: HTTP

    static func post(_ transport: ReaderTransport, _ provider: Provider, _ path: String, _ body: [String: StrictJSON]) async throws -> StrictJSON {
        let json = try StrictJSON.parse(try await transport.send(.post(provider.baseURL.adding(path: path), .object(body))))
        // Erro de validacao do no: `{"Error": "..."}`. So o fato, nunca o texto.
        if json.optionalField("Error") != nil { throw ReaderError.providerError(code: "Error") }
        return json
    }

    // MARK: Parse

    static func parseBlock(_ json: StrictJSON, now: Date) throws -> TronBlockReference {
        let id = try json.field("blockID", "getnowblock").string("getnowblock.blockID")
        let raw = try json.field("block_header", "getnowblock").field("raw_data", "getnowblock.block_header")
        let path = "getnowblock.block_header.raw_data"
        let number = try raw.field("number", path).uint64(path + ".number")
        let timestamp = try raw.field("timestamp", path).int64(path + ".timestamp")
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        guard abs(timestamp - nowMillis) <= maxBlockSkew else { throw ReaderError.implausibleValue(field: path + ".timestamp") }
        do {
            return try TronBlockReference(number: number, idHex: id, timestamp: timestamp)
        } catch {
            throw ReaderError.malformed(field: "getnowblock.blockID")
        }
    }

    struct OwnerReading: Sendable {
        let control: TronAccountControl
        let trx: BigUInt
    }

    static func parseOwnerAccount(_ data: Data, owner: TronAddress) throws -> OwnerReading {
        let json = try StrictJSON.parse(data)
        let control: TronAccountControl
        do {
            control = try TronPermissions.check(getAccountJSON: data, derived: owner)
        } catch TronPermissions.Failure.addressMismatch {
            throw ReaderError.responseMismatch(field: "getaccount.address")
        } catch {
            throw ReaderError.malformed(field: "getaccount")
        }
        // proto3: `balance` ausente em conta existente e zero.
        let trx = try json.optionalField("balance")?.unsigned("getaccount.balance") ?? 0
        return OwnerReading(control: control, trx: trx)
    }

    /// Duas leituras do dono: basta uma ver a conta comprometida; dono unico nos dois,
    /// ou conta inexistente nos dois, para passar. Saldo, o menor.
    static func combine(_ readings: [OwnerReading]) throws -> (control: TronAccountControl, trx: BigUInt) {
        let trx = readings.map(\.trx).min() ?? 0
        if let compromised = readings.first(where: { $0.control.isCompromised }) { return (compromised.control, trx) }
        guard let first = readings.first, readings.allSatisfy({ $0.control.verdict == first.control.verdict }) else {
            throw ReaderError.providersDisagree(field: "getaccount")
        }
        return (first.control, trx)
    }

    /// Restante do dia: cota gratis, bandwidth e energy de stake. Campo ausente e zero
    /// (proto3); conta inexistente responde `{}`.
    static func parseResources(_ json: StrictJSON) throws -> TronAccountResources {
        guard json.objectValue != nil else { throw ReaderError.malformed(field: "getaccountresource") }
        func value(_ key: String) throws -> UInt64 {
            try json.optionalField(key)?.uint64("getaccountresource." + key) ?? 0
        }
        func remaining(_ limit: String, _ used: String) throws -> UInt64 {
            let (total, spent) = (try value(limit), try value(used))
            return total > spent ? total - spent : 0
        }
        return TronAccountResources(
            freeBandwidth: try remaining("freeNetLimit", "freeNetUsed"),
            stakedBandwidth: try remaining("NetLimit", "NetUsed"),
            energy: try remaining("EnergyLimit", "EnergyUsed")
        )
    }

    static func parseChainParameters(_ json: StrictJSON) throws -> TronChainParameters {
        var entries: [String: StrictJSON?] = [:]
        for (offset, entry) in try json.field("chainParameter", "getchainparameters").array("getchainparameters.chainParameter").enumerated() {
            let path = "getchainparameters.chainParameter[\(offset)]"
            let key = try entry.field("key", path).string(path + ".key")
            guard entries[key] == nil else { throw ReaderError.malformed(field: path + ".key") }
            entries[key] = entry.optionalField("value")
        }
        // So os parametros que a carteira usa sao lidos, e tem de estar na lista. Os
        // outros podem ser negativos (`getRemoveThePowerOfTheGr` e -1) e nao importam.
        // proto3: `value` zero nao aparece.
        func require(_ key: String) throws -> BigUInt {
            guard let entry = entries[key] else { throw ReaderError.malformed(field: "getchainparameters." + key) }
            return try entry?.unsigned("getchainparameters." + key) ?? 0
        }
        return TronChainParameters(
            energyPrice: try require("getEnergyFee"),
            bandwidthPrice: try require("getTransactionFee"),
            createAccountFee: try require("getCreateNewAccountFeeInSystemContract"),
            createAccountBandwidthFee: try require("getCreateAccountFee"),
            memoFee: try require("getMemoFee")
        )
    }

    /// `triggerconstantcontract`: o primeiro resultado (32 bytes) e a energy usada. Revert
    /// aparece como `transaction.ret[0].ret = FAILED` ou `result.message`, com
    /// `result.result` ainda `true`.
    static func parseConstantCall(_ json: StrictJSON, field: String) throws -> (word: [UInt8], energy: UInt64) {
        let result = try json.field("result", field)
        if let code = result.optionalField("code") {
            throw ReaderError.providerError(code: ReaderError.sanitized((try? code.string(field + ".result.code")) ?? "error"))
        }
        guard try result.field("result", field + ".result").bool(field + ".result.result") else {
            throw ReaderError.providerError(code: "constant-call")
        }
        if result.optionalField("message") != nil { throw ReaderError.executionReverted }
        if let rets = json.optionalField("transaction")?.optionalField("ret")?.arrayValue,
           rets.contains(where: { (try? $0.field("ret", field).string(field)) == "FAILED" }) {
            throw ReaderError.executionReverted
        }
        let outputs = try json.field("constant_result", field).array(field + ".constant_result")
        guard let first = outputs.first, let word = Hex.decode(try first.string(field + ".constant_result")) else {
            throw ReaderError.malformed(field: field + ".constant_result")
        }
        let energy = try json.field("energy_used", field).uint64(field + ".energy_used")
        return (word, energy)
    }

    static func parseBroadcast(_ json: StrictJSON, expectedID: String) throws -> String {
        if try json.optionalField("result")?.bool("broadcasthex.result") == true {
            guard let txid = json.optionalField("txid"), try txid.string("broadcasthex.txid").lowercased() == expectedID else {
                throw ReaderError.broadcastMismatch
            }
            return expectedID
        }
        let code = try json.optionalField("code")?.string("broadcasthex.code") ?? "error"
        let message = (try? json.optionalField("message")?.string("broadcasthex.message")) ?? nil
        throw ReaderError.broadcastRejected(rejection(code: code, message: message ?? ""), code: ReaderError.sanitized(code))
    }

    /// Codigos de `Return.response_code` (java-tron, api.proto). A mensagem so e lida
    /// para separar saldo insuficiente de outra falha de validacao, e as vezes vem em hex.
    static func rejection(code: String, message: String) -> BroadcastRejection {
        switch code {
        case "DUP_TRANSACTION_ERROR": return .alreadyKnown
        case "SIGERROR": return .invalidSignature
        case "BANDWITH_ERROR": return .insufficientFunds
        case "TAPOS_ERROR", "TRANSACTION_EXPIRATION_ERROR": return .expired
        default:
            let text = (Hex.decode(message).flatMap { String(bytes: $0, encoding: .utf8) } ?? message).lowercased()
            if text.contains("balance is not sufficient") || text.contains("insufficient") { return .insufficientFunds }
            return .other
        }
    }

    /// `{}` e "nao existe"; senao, o resultado final da transacao no bloco.
    static func parseTransactionInfo(_ json: StrictJSON, id: String) throws -> TransactionStatus? {
        guard let fields = json.objectValue else { throw ReaderError.malformed(field: "gettransactioninfobyid") }
        if fields.isEmpty { return nil }
        guard try json.field("id", "gettransactioninfobyid").string("gettransactioninfobyid.id").lowercased() == id else {
            throw ReaderError.responseMismatch(field: "gettransactioninfobyid.id")
        }
        let block = try json.field("blockNumber", "gettransactioninfobyid").uint64("gettransactioninfobyid.blockNumber")
        let receipt = try json.optionalField("receipt")?.optionalField("result")?.string("gettransactioninfobyid.receipt.result")
        let failed = try json.optionalField("result")?.string("gettransactioninfobyid.result") == "FAILED"
        // Transferencia de TRX nao tem `receipt.result`: se esta no bloco, deu certo.
        if failed || (receipt != nil && receipt != "SUCCESS") { return .failed(reason: receipt ?? "FAILED") }
        return .confirmed(block: block, confirmations: nil)
    }

    /// O campo 1 (`raw_data`) da `Transaction` em protobuf: tag 0x0a, tamanho varint e os
    /// bytes. O txID e o SHA-256 dele.
    static func rawData(ofTransaction bytes: [UInt8]) -> [UInt8]? {
        guard bytes.first == 0x0A else { return nil }
        var index = 1
        var length = 0
        var shift = 0
        while index < bytes.count, shift < 35 {
            let byte = bytes[index]
            length |= Int(byte & 0x7F) << shift
            index += 1
            if byte & 0x80 == 0 {
                guard bytes.count - index >= length else { return nil }
                return Array(bytes[index..<(index + length)])
            }
            shift += 7
        }
        return nil
    }

    static func parseHistory(owner: TronAddress, transactions: StrictJSON, trc20: StrictJSON) throws -> ActivityPage {
        let native = Asset.native(.tron)
        var items: [ActivityItem] = []
        var suspicious = SuspiciousSummary()
        var fees: [String: BigUInt] = [:]
        var sentByOwner: Set<String> = []
        let usdtContract = TRC20.usdt.contract

        for (offset, item) in try transactions.field("data", "transactions").array("transactions.data").enumerated() {
            let path = "transactions.data[\(offset)]"
            // Transacao interna (TRX mandado por contrato) tem outro formato; fica fora.
            guard let txText = item.optionalField("txID") else { continue }
            let hash = try txText.string(path + ".txID").lowercased()
            let date = Date(timeIntervalSince1970: TimeInterval(try item.field("block_timestamp", path).uint64(path + ".block_timestamp")) / 1000)
            let ret = try item.field("ret", path).array(path + ".ret").first
            let contractRet = try ret?.optionalField("contractRet")?.string(path + ".ret.contractRet")
            let status: ActivityItem.Status = contractRet == nil || contractRet == "SUCCESS" ? .confirmed : .failed
            let fee = try ret?.optionalField("fee")?.unsigned(path + ".ret.fee") ?? 0
            let contracts = try item.field("raw_data", path).field("contract", path + ".raw_data").array(path + ".raw_data.contract")
            guard let contract = contracts.first else { continue }
            let type = try contract.field("type", path + ".contract").string(path + ".contract.type")
            let value = try contract.field("parameter", path + ".contract").field("value", path + ".contract.parameter")
            guard let from = TronAddress(try value.field("owner_address", path + ".value").string(path + ".value.owner_address")) else {
                throw ReaderError.malformed(field: path + ".value.owner_address")
            }
            let explorer = Chain.tron.explorerURL(tx: hash)
            if from == owner {
                fees[hash] = fee
                sentByOwner.insert(hash)
            }
            switch type {
            case "TransferContract":
                guard let to = TronAddress(try value.field("to_address", path + ".value").string(path + ".value.to_address")) else {
                    throw ReaderError.malformed(field: path + ".value.to_address")
                }
                // proto3: `amount` zero nao aparece.
                let amount = try value.optionalField("amount")?.unsigned(path + ".value.amount") ?? 0
                let outgoing = from == owner
                let incoming = to == owner
                if incoming, !outgoing, let suspicion = ActivityRules.judgeIncoming(asset: native, amount: amount) {
                    ActivityRules.count(suspicion, in: &suspicious)
                    continue
                }
                guard outgoing || incoming else { continue }
                items.append(ActivityItem(
                    id: "tron:\(hash)", chainID: "tron", direction: outgoing && incoming ? .other : (outgoing ? .sent : .received),
                    asset: native, amount: amount, counterparty: outgoing ? to.base58 : from.base58, date: date, status: status,
                    fee: outgoing ? fee : nil, hash: hash, explorerURL: explorer
                ))
            case "TransferAssetContract":
                // TRC-10: nenhum esta na lista curada.
                if from != owner { suspicious.unknownAsset += 1 }
            case "TriggerSmartContract":
                // A transferencia de USDT aparece pela lista TRC-20 (com o valor); aqui so
                // fica a taxa. Outra chamada do dono (aprovacao, troca) vira "outro".
                let targetText = try value.optionalField("contract_address").map { try $0.string(path + ".value.contract_address") }
                let target = targetText.flatMap { TronAddress($0) }
                if from == owner, target != usdtContract {
                    items.append(ActivityItem(
                        id: "tron:\(hash)", chainID: "tron", direction: .other, asset: native, amount: 0,
                        counterparty: target?.base58, date: date, status: status, fee: fee,
                        hash: hash, explorerURL: explorer
                    ))
                } else if from == owner, status == .failed {
                    items.append(ActivityItem(
                        id: "tron:\(hash)", chainID: "tron", direction: .sent, asset: TokenRegistry.find(chainID: "tron", contract: usdtContract.base58) ?? native,
                        amount: 0, counterparty: nil, date: date, status: .failed, fee: fee, hash: hash, explorerURL: explorer
                    ))
                }
            default:
                // Stake, delegacao, voto: so o que o dono fez.
                if from == owner {
                    items.append(ActivityItem(
                        id: "tron:\(hash)", chainID: "tron", direction: .other, asset: native, amount: 0, counterparty: nil,
                        date: date, status: status, fee: fee, hash: hash, explorerURL: explorer
                    ))
                }
            }
        }

        for (offset, item) in try trc20.field("data", "trc20").array("trc20.data").enumerated() {
            let path = "trc20.data[\(offset)]"
            guard try item.field("type", path).string(path + ".type") == "Transfer" else { continue }
            let hash = try item.field("transaction_id", path).string(path + ".transaction_id").lowercased()
            let date = Date(timeIntervalSince1970: TimeInterval(try item.field("block_timestamp", path).uint64(path + ".block_timestamp")) / 1000)
            guard let from = TronAddress(try item.field("from", path).string(path + ".from")),
                  let to = TronAddress(try item.field("to", path).string(path + ".to")),
                  let contract = TronAddress(try item.field("token_info", path).field("address", path + ".token_info").string(path + ".token_info.address"))
            else { throw ReaderError.malformed(field: path) }
            // So o contrato compilado conta; `token_info` (nome, simbolo, casas) e ignorado.
            let asset = contract == usdtContract ? TokenRegistry.find(chainID: "tron", contract: contract.base58) : nil
            let amount = try item.field("value", path).decimalString(path + ".value")
            let outgoing = from == owner
            let incoming = to == owner
            guard outgoing || incoming else { continue }
            if incoming, !outgoing, let suspicion = ActivityRules.judgeIncoming(asset: asset, amount: amount) {
                ActivityRules.count(suspicion, in: &suspicious)
                continue
            }
            guard let asset else { continue }
            items.append(ActivityItem(
                id: "tron:\(hash):\(offset)", chainID: "tron", direction: outgoing && incoming ? .other : (outgoing ? .sent : .received),
                asset: asset, amount: amount, counterparty: outgoing ? to.base58 : from.base58, date: date, status: .confirmed,
                fee: outgoing && sentByOwner.contains(hash) ? fees[hash] : nil, hash: hash, explorerURL: Chain.tron.explorerURL(tx: hash)
            ))
        }
        return ActivityRules.page(chainID: "tron", items: items, suspicious: suspicious)
    }
}
