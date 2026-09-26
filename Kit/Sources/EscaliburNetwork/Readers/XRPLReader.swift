import EscaliburChains
import EscaliburCore
import Foundation

/// Leitura de estado, transmissao e historico do XRP Ledger, pela API JSON-RPC do
/// rippled (POST, endereco sempre no corpo).
///
/// Consenso: as leituras da conta e do destino vem de dois servidores **no mesmo ledger
/// validado**. O primeiro responde em `validated`; o segundo e perguntado pelo numero do
/// ledger que o primeiro usou. No mesmo ledger, dois servidores honestos dao o mesmo
/// Sequence, saldo e flags, e qualquer diferenca e mentira ou defeito.
public actor XRPLReader {
    public static let shared = XRPLReader()

    let transport: ReaderTransport
    let pool: ProviderPool

    public init(transport: ReaderTransport = HTTPClient.shared, providers: [ProviderPool.Provider] = Endpoints.xrpl) {
        self.transport = transport
        self.pool = ProviderPool(providers)
    }

    /// Rede principal. `network_id` diferente disso no `server_info` e servidor de outra
    /// rede (testnet 1, devnet 2, sidechains acima de 1024).
    static let mainnetNetworkID: UInt64 = 0
    /// Ledger validado com mais de um minuto e servidor atrasado: o LastLedgerSequence
    /// sairia velho e a sequence tambem.
    static let maxValidatedAge: UInt64 = 60
    /// Faixas de sanidade das reservas (hoje 1 XRP e 0,2 XRP). Mudam por votacao, entao
    /// nao sao constantes do plano; mas 100 XRP de base ou 10 XRP por objeto seriam
    /// servidor mentindo para travar a conta.
    static let maxReserveBase = BigUInt(100_000_000)
    static let maxReserveIncrement = BigUInt(10_000_000)
    static let healthyStates: Set<String> = ["full", "proposing", "validating"]

    // MARK: Estado para o plano

    /// `server_info` (ledger validado, reservas em drops) e `fee` (`open_ledger_fee`), do
    /// mesmo servidor. O teto da taxa fica com `XRPLPlanner` (1.000 drops).
    public func ledgerState() async throws -> XRPLLedgerState {
        let transport = self.transport
        return try await Quorum.first(await pool.available(), pool: pool) { provider in
            let info = try Self.checked(try await Self.call(transport, provider.baseURL, "server_info", [:]), "server_info")
            let fee = try Self.checked(try await Self.call(transport, provider.baseURL, "fee", [:]), "fee")
            return try Self.parseLedgerState(serverInfo: info, fee: fee)
        }
    }

    /// `account_info` do dono em dois servidores, no mesmo ledger validado. As duas
    /// leituras de Sequence vao para o plano, que exige que sejam iguais.
    public func accountState(address: String) async throws -> XRPLAccountState {
        guard XRPLAddress.accountID(address) != nil else { throw ReaderError.invalidInput("endereco") }
        let readings = try await pinnedPair { provider, ledger in
            try await self.accountReading(provider, address: address, ledger: ledger)
        }
        guard case .found(let first) = readings[0].value, case .found(let second) = readings[1].value else {
            if case .notFound = readings[0].value, case .notFound = readings[1].value { throw ReaderError.accountNotFound }
            throw ReaderError.providersDisagree(field: "account_info")
        }
        guard first.balance == second.balance, first.ownerCount == second.ownerCount, first.flags == second.flags else {
            throw ReaderError.providersDisagree(field: "account_info")
        }
        return XRPLAccountState(
            address: address, sequenceReadings: [first.sequence, second.sequence],
            balance: first.balance, ownerCount: first.ownerCount, flags: first.flags, ledgerIndex: readings[0].ledger
        )
    }

    /// O destino em dois servidores, no mesmo ledger: existe? com que flags? Com
    /// lsfDepositAuth, `deposit_authorized` (origem = dono) nos dois.
    ///
    /// `address` pode ser r... ou X-address; o estado sai com o r... correspondente, que
    /// e o que `XRPLPlanner.planSend` confere.
    public func destinationState(address: String, source: String) async throws -> XRPLDestinationState {
        guard case .success(let resolved) = Address.validate(address, for: .xrpl),
              XRPLAddress.accountID(source) != nil
        else { throw ReaderError.invalidInput("endereco") }
        let classic = resolved.address
        let readings = try await pinnedPair { provider, ledger in
            try await self.accountReading(provider, address: classic, ledger: ledger)
        }
        let mapped: [XRPLDestinationState.Reading] = readings.map {
            switch $0.value {
            case .notFound: return .notFound
            case .found(let account): return .found(flags: account.flags)
            }
        }
        var preauthorized = false
        if case .found(let flags) = mapped[0], flags & XRPLAccountFlags.depositAuth != 0 {
            let ledger = readings[0].ledger
            let transport = self.transport
            preauthorized = try await Quorum.agree(await pool.available(), pool: pool, field: "deposit_authorized") { provider in
                let result = try Self.checked(try await Self.call(transport, provider.baseURL, "deposit_authorized", [
                    "source_account": .string(source), "destination_account": .string(classic), "ledger_index": .int(ledger),
                ]), "deposit_authorized")
                return try result.field("deposit_authorized", "deposit_authorized").bool("deposit_authorized.deposit_authorized")
            }
        }
        return XRPLDestinationState(address: classic, readings: mapped, depositPreauthorized: preauthorized)
    }

    // MARK: Transmissao e acompanhamento

    /// `submit` com o `tx_blob`. Um servidor basta (ele repassa a rede); o proximo so e
    /// tentado se o primeiro nao respondeu. Recusa do motor (tef, tem, tel, ter) e
    /// definitiva e volta como `broadcastRejected`.
    public func broadcast(_ signed: SignedTransaction) async throws -> BroadcastReceipt {
        // O id e SHA512Half("TXN\0" + blob): conferido aqui para o acompanhamento seguir
        // exatamente a transacao que foi assinada.
        guard signed.chainID == Chain.xrpl.id, Hex.decode(signed.encoded) == signed.raw,
              Hex.encode(Hash.sha512Half([0x54, 0x58, 0x4E, 0x00] + signed.raw)).uppercased() == signed.id.uppercased()
        else { throw ReaderError.broadcastMismatch }
        var lastError: Error = ReaderError.notEnoughProviders(needed: 1, got: 0)
        for provider in await pool.available() {
            do {
                let result = try Self.checked(
                    try await Self.call(transport, provider.baseURL, "submit", ["tx_blob": .string(signed.encoded)]), "submit"
                )
                let engine = try Self.parseSubmit(result, expectedID: signed.id)
                await pool.reportSuccess(provider)
                return BroadcastReceipt(chainID: Chain.xrpl.id, id: signed.id.uppercased(), acceptedBy: [provider.name], provisionalResult: engine)
            } catch let error as ReaderError {
                if case .broadcastRejected(.alreadyKnown, _) = error {
                    return BroadcastReceipt(chainID: Chain.xrpl.id, id: signed.id.uppercased(), acceptedBy: [provider.name])
                }
                if case .broadcastRejected = error { throw error }
                if case .broadcastMismatch = error { throw error }
                await Quorum.record(error, provider, pool)
                lastError = error
            } catch {
                await Quorum.record(error, provider, pool)
                lastError = error
            }
        }
        throw lastError
    }

    /// `tx` pelo hash. Final (validado, ou vencido sem entrar) so quando dois servidores
    /// dizem o mesmo. Com `lastLedgerSequence`, "nao achado" com a busca completa ate
    /// ele vira `failed("expired")`: depois desse ledger a transacao nao entra mais.
    public func status(of hash: String, lastLedgerSequence: UInt32? = nil) async throws -> TransactionStatus {
        guard let bytes = Hex.decode(hash), bytes.count == 32 else { throw ReaderError.invalidInput("hash") }
        var params: [String: StrictJSON] = ["transaction": .string(hash.uppercased()), "binary": .bool(false)]
        if let last = lastLedgerSequence {
            params["min_ledger"] = .int(last > 500 ? last - 500 : 1)
            params["max_ledger"] = .int(last)
        }
        let frozen = params
        let transport = self.transport
        let readings = try await Quorum.collect(await pool.available(), pool: pool, count: 2) { provider in
            try Self.parseTxStatus(try await Self.call(transport, provider.baseURL, "tx", frozen))
        }.map(\.value)
        if readings[0] == readings[1], readings[0].isFinal { return readings[0] }
        if readings.contains(where: { $0 != .notFound }) { return .pending }
        return .notFound
    }

    // MARK: Historico

    /// `account_tx` do dono, mais recente primeiro. Valor recebido sempre pelo
    /// `delivered_amount` (via `XRPLIncomingPayment`), com o pagamento parcial marcado.
    public func history(address: String) async throws -> ActivityPage {
        guard XRPLAddress.accountID(address) != nil else { throw ReaderError.invalidInput("endereco") }
        let transport = self.transport
        return try await Quorum.first(await pool.available(), pool: pool) { provider in
            let result = try Self.checked(try await Self.call(transport, provider.baseURL, "account_tx", [
                "account": .string(address), "limit": .int(ActivityRules.pageSize), "api_version": .int(2),
                "ledger_index_min": .number("-1"), "ledger_index_max": .number("-1"), "forward": .bool(false),
            ]), "account_tx")
            return try Self.parseHistory(result, owner: address)
        }
    }

    // MARK: Leituras

    enum AccountReading: Sendable, Equatable {
        case notFound
        case found(Account)

        struct Account: Sendable, Equatable {
            let sequence: UInt32
            let balance: BigUInt
            let ownerCount: UInt32
            let flags: UInt32
        }
    }

    /// Uma leitura e o ledger validado em que ela foi feita.
    struct Pinned<T: Sendable & Equatable>: Sendable, Equatable {
        let value: T
        let ledger: UInt32
    }

    /// Duas leituras de servidores diferentes no mesmo ledger validado. O numero do
    /// ledger sai de `ledger` (validado) no primeiro servidor que responde; as leituras
    /// sao feitas por numero, porque os servidores Clio (s1 e s2 da Ripple) nao dizem em
    /// que ledger responderam quando a conta nao existe. Servidor que ainda nao tem o
    /// ledger (`lgrNotFound`) e trocado pelo proximo.
    private func pinnedPair<T: Sendable & Equatable>(
        _ read: @escaping @Sendable (Provider, UInt32) async throws -> T
    ) async throws -> [Pinned<T>] {
        let providers = await pool.available()
        let transport = self.transport
        let ledger = try await Quorum.first(providers, pool: pool) { provider in
            try Self.parseValidatedLedger(try Self.checked(try await Self.call(transport, provider.baseURL, "ledger", [
                "ledger_index": .string("validated"),
            ]), "ledger"))
        }
        let readings = try await Quorum.collect(providers, pool: pool, count: 2) { provider in
            try await read(provider, ledger)
        }
        return readings.map { Pinned(value: $0.value, ledger: ledger) }
    }

    private func accountReading(_ provider: Provider, address: String, ledger: UInt32) async throws -> AccountReading {
        let result = try await Self.call(transport, provider.baseURL, "account_info", [
            "account": .string(address), "ledger_index": .int(ledger),
        ])
        return try Self.parseAccountInfo(result, address: address, ledger: ledger)
    }

    // MARK: JSON-RPC

    static func call(_ transport: ReaderTransport, _ url: URL, _ method: String, _ params: [String: StrictJSON]) async throws -> StrictJSON {
        let body: StrictJSON = .object(["method": .string(method), "params": .array([.object(params)])])
        let json = try StrictJSON.parse(try await transport.send(.post(url, body)))
        return try json.field("result", method)
    }

    /// Resultado com `status: "error"` vira `providerError` com o nome do erro do
    /// rippled (`actMalformed`, `lgrNotFound`), nunca a mensagem.
    static func checked(_ result: StrictJSON, _ method: String) throws -> StrictJSON {
        if let error = result.optionalField("error") {
            throw ReaderError.providerError(code: ReaderError.sanitized((try? error.string(method + ".error")) ?? "error"))
        }
        return result
    }

    // MARK: Parse

    static func parseLedgerState(serverInfo: StrictJSON, fee: StrictJSON) throws -> XRPLLedgerState {
        let info = try serverInfo.field("info", "server_info")
        if let network = info.optionalField("network_id") {
            guard try network.uint64("server_info.info.network_id") == mainnetNetworkID else { throw ReaderError.wrongNetwork }
        }
        let state = try info.field("server_state", "server_info.info").string("server_info.info.server_state")
        guard healthyStates.contains(state) else { throw ReaderError.implausibleValue(field: "server_info.info.server_state") }
        let validated = try info.field("validated_ledger", "server_info.info")
        let path = "server_info.info.validated_ledger"
        let age = try validated.optionalField("age")?.uint64(path + ".age") ?? 0
        guard age <= maxValidatedAge else { throw ReaderError.implausibleValue(field: path + ".age") }
        let seq = try validated.field("seq", path).uint32(path + ".seq")
        let base = try validated.field("reserve_base_xrp", path).scaledDecimal(path + ".reserve_base_xrp", scale: 6)
        let increment = try validated.field("reserve_inc_xrp", path).scaledDecimal(path + ".reserve_inc_xrp", scale: 6)
        guard !base.isZero, base <= maxReserveBase else { throw ReaderError.implausibleValue(field: path + ".reserve_base_xrp") }
        guard increment <= maxReserveIncrement else { throw ReaderError.implausibleValue(field: path + ".reserve_inc_xrp") }
        let openLedgerFee = try fee.field("drops", "fee").field("open_ledger_fee", "fee.drops").decimalString("fee.drops.open_ledger_fee")
        return XRPLLedgerState(validatedLedgerIndex: seq, reserveBase: base, reserveIncrement: increment, openLedgerFee: openLedgerFee)
    }

    static func parseValidatedLedger(_ result: StrictJSON) throws -> UInt32 {
        guard try result.field("validated", "ledger").bool("ledger.validated") else {
            throw ReaderError.implausibleValue(field: "ledger.validated")
        }
        let index = try result.field("ledger_index", "ledger").uint32("ledger.ledger_index")
        guard index > 0 else { throw ReaderError.implausibleValue(field: "ledger.ledger_index") }
        return index
    }

    /// `account_info` num ledger fixo. `actNotFound` e a conta inexistente naquele ledger;
    /// quando o servidor informa o ledger, tem de ser o pedido.
    static func parseAccountInfo(_ result: StrictJSON, address: String, ledger: UInt32) throws -> AccountReading {
        if let reported = result.optionalField("ledger_index") {
            guard try reported.uint32("account_info.ledger_index") == ledger else {
                throw ReaderError.responseMismatch(field: "account_info.ledger_index")
            }
        }
        if let error = result.optionalField("error") {
            let code = (try? error.string("account_info.error")) ?? "error"
            guard code == "actNotFound" else { throw ReaderError.providerError(code: ReaderError.sanitized(code)) }
            return .notFound
        }
        guard try result.field("validated", "account_info").bool("account_info.validated") else {
            throw ReaderError.implausibleValue(field: "account_info.validated")
        }
        let data = try result.field("account_data", "account_info")
        let path = "account_info.account_data"
        guard try data.field("Account", path).string(path + ".Account") == address else {
            throw ReaderError.responseMismatch(field: path + ".Account")
        }
        return .found(AccountReading.Account(
            sequence: try data.field("Sequence", path).uint32(path + ".Sequence"),
            balance: try data.field("Balance", path).decimalString(path + ".Balance"),
            ownerCount: try data.field("OwnerCount", path).uint32(path + ".OwnerCount"),
            flags: try data.field("Flags", path).uint32(path + ".Flags")
        ))
    }

    /// O `engine_result` provisorio, ou a recusa. O hash que o servidor calculou tem de
    /// ser o local.
    static func parseSubmit(_ result: StrictJSON, expectedID: String) throws -> String {
        let engine = try result.field("engine_result", "submit").string("submit.engine_result")
        if let hash = result.optionalField("tx_json")?.optionalField("hash") {
            guard try hash.string("submit.tx_json.hash").uppercased() == expectedID.uppercased() else {
                throw ReaderError.broadcastMismatch
            }
        }
        if engine == "tesSUCCESS" || engine == "terQUEUED" || engine.hasPrefix("tec") { return engine }
        throw ReaderError.broadcastRejected(rejection(engine), code: ReaderError.sanitized(engine))
    }

    static func rejection(_ engine: String) -> BroadcastRejection {
        switch engine {
        case "tefALREADY": return .alreadyKnown
        case "tefPAST_SEQ": return .nonceTooLow
        case "terPRE_SEQ": return .nonceTooHigh
        case "tefMAX_LEDGER": return .expired
        case "terINSUF_FEE_B": return .insufficientFunds
        case "tefBAD_SIGNATURE", "temBAD_SIGNATURE", "tefBAD_AUTH", "tefBAD_AUTH_MASTER", "temINVALID": return .invalidSignature
        case "temBAD_NETWORK_ID", "telREQUIRES_NETWORK_ID", "telNETWORK_ID_MAKES_TX_NON_CANONICAL": return .wrongNetwork
        default:
            if engine.hasPrefix("telINSUF_FEE") || engine.hasPrefix("telCAN_NOT_QUEUE") || engine == "temBAD_FEE" { return .underpriced }
            return .other
        }
    }

    static func parseTxStatus(_ result: StrictJSON) throws -> TransactionStatus {
        if let error = result.optionalField("error") {
            let code = (try? error.string("tx.error")) ?? "error"
            guard code == "txnNotFound" else { throw ReaderError.providerError(code: ReaderError.sanitized(code)) }
            if try result.optionalField("searched_all")?.bool("tx.searched_all") == true { return .failed(reason: "expired") }
            return .notFound
        }
        guard try result.optionalField("validated")?.bool("tx.validated") == true else { return .pending }
        let meta = try result.field("meta", "tx")
        let code = try meta.field("TransactionResult", "tx.meta").string("tx.meta.TransactionResult")
        let ledger = try result.field("ledger_index", "tx").uint64("tx.ledger_index")
        return code == "tesSUCCESS" ? .confirmed(block: ledger, confirmations: nil) : .failed(reason: code)
    }

    static func parseHistory(_ result: StrictJSON, owner: String) throws -> ActivityPage {
        guard try result.field("account", "account_tx").string("account_tx.account") == owner else {
            throw ReaderError.responseMismatch(field: "account_tx.account")
        }
        var items: [ActivityItem] = []
        var suspicious = SuspiciousSummary()
        let native = Asset.native(.xrpl)
        for (offset, entry) in try result.field("transactions", "account_tx").array("account_tx.transactions").enumerated() {
            let path = "account_tx.transactions[\(offset)]"
            let tx = try entry.field("tx_json", path)
            let hash = try entry.field("hash", path).string(path + ".hash").uppercased()
            let type = try tx.field("TransactionType", path + ".tx_json").string(path + ".tx_json.TransactionType")
            let sender = try tx.field("Account", path + ".tx_json").string(path + ".tx_json.Account")
            let validated = try entry.optionalField("validated")?.bool(path + ".validated") ?? false
            let result = try entry.optionalField("meta")?.field("TransactionResult", path + ".meta").string(path + ".meta.TransactionResult")
            let status: ActivityItem.Status = !validated ? .pending : (result == "tesSUCCESS" ? .confirmed : .failed)
            let date = try rippleDate(tx, entry, path)
            let fee = sender == owner ? try tx.field("Fee", path + ".tx_json").decimalString(path + ".tx_json.Fee") : nil
            let explorer = Chain.xrpl.explorerURL(tx: hash)

            guard type == "Payment" else {
                // Acao da propria conta (linha de confianca, oferta, ajuste). O que outras
                // contas fizeram e so tocou esta (oferta consumida) nao entra.
                if sender == owner {
                    items.append(ActivityItem(
                        id: "xrpl:\(hash)", chainID: "xrpl", direction: .other, asset: native, amount: 0, counterparty: nil,
                        date: date, status: status, fee: fee, hash: hash, explorerURL: explorer
                    ))
                }
                continue
            }
            let destination = try tx.field("Destination", path + ".tx_json").string(path + ".tx_json.Destination")
            let outgoing = sender == owner
            let incoming = destination == owner

            switch XRPLIncomingPayment.read(json: entry.serialized) {
            case .delivered(let delivery):
                guard case .xrp(let drops) = delivery.delivered else {
                    // Token emitido: a lista curada da carteira ainda nao tem nenhum no XRP
                    // Ledger, entao nao ha ativo verificado para mostrar.
                    if incoming, !outgoing { suspicious.unknownAsset += 1 }
                    continue
                }
                if incoming, !outgoing, let suspicion = ActivityRules.judgeIncoming(asset: native, amount: drops) {
                    ActivityRules.count(suspicion, in: &suspicious)
                    continue
                }
                let direction: ActivityItem.Direction = outgoing && incoming ? .other : (outgoing ? .sent : .received)
                items.append(ActivityItem(
                    id: "xrpl:\(hash)", chainID: "xrpl", direction: direction, asset: native, amount: drops,
                    counterparty: outgoing ? destination : sender, date: date, status: status, fee: fee, hash: hash,
                    explorerURL: explorer, isPartialPayment: delivery.isPartialPayment
                ))
            case .failed, .notValidated:
                // Envio do dono que falhou (a taxa foi cobrada) ou ainda sem validacao: o
                // valor entregue e zero ou desconhecido, e nao se mostra o `Amount`.
                guard outgoing else { continue }
                items.append(ActivityItem(
                    id: "xrpl:\(hash)", chainID: "xrpl", direction: .sent, asset: native, amount: 0,
                    counterparty: destination, date: date, status: status == .confirmed ? .failed : status, fee: fee,
                    hash: hash, explorerURL: explorer
                ))
            case .deliveredAmountUnavailable, .notAPayment, .unsupported:
                continue
            }
        }
        return ActivityRules.page(chainID: "xrpl", items: items, suspicious: suspicious)
    }

    /// `tx_json.date` (segundos desde 01/01/2000) ou `close_time_iso`.
    static func rippleDate(_ tx: StrictJSON, _ entry: StrictJSON, _ path: String) throws -> Date {
        if let seconds = tx.optionalField("date") {
            return Date(timeIntervalSince1970: XRPLPlanner.rippleEpoch + TimeInterval(try seconds.uint64(path + ".tx_json.date")))
        }
        return try EVMReader.isoDate(try entry.field("close_time_iso", path).string(path + ".close_time_iso"), path + ".close_time_iso")
    }
}
