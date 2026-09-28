import EscaliburChains
import EscaliburCore
import Foundation

/// Leitura de estado, simulacao, transmissao e acompanhamento da Sui, pelo gRPC-Web de
/// tres operadores independentes e sem chave (`Endpoints.sui`): a Sui Foundation, o
/// Suiscan e a NodeInfra, cada um com o proprio no (versao de build e checkpoint mais
/// antigo diferentes, conferido em 27/09/2026).
///
/// O que decide o dinheiro vem de dois provedores concordando (docs/seguranca.md §5.5):
/// as moedas de SUI do dono (id, versao, digesto e saldo, que entram como gas), o preco
/// de referencia do gas e a epoca. Diferenca rele uma vez, 1,5 s depois; a segunda vira
/// `providersDisagree`. A simulacao, para o orcamento e para a transacao exata, roda em
/// dois provedores, e as duas tem de dar certo.
///
/// Uma fonte so, com o motivo:
/// - o saldo da tela (`displayBalance`): exibicao; o plano rele em dois;
/// - o historico, pelo GraphQL da Sui Foundation (o unico indexador sem chave com o
///   historico inteiro); na falha dele, o `ListTransactions` de um no gRPC, que so
///   alcanca as ultimas duas semanas. Informativo: nada dali entra num plano.
///
/// Toda leitura confere antes, uma vez por provedor, que o no esta na rede principal: o
/// `chain_id` do `GetServiceInfo` (digesto do checkpoint de genese) tem de ser o
/// compilado.
public actor SuiReader {
    public static let shared = SuiReader()

    /// Digesto do checkpoint de genese da rede principal, em base58 (`GetServiceInfo`
    /// e `chainIdentifier` do GraphQL, iguais nos quatro provedores em 27/09/2026). O
    /// identificador curto do JSON-RPC antigo, `35834a8a`, sao os 4 primeiros bytes dele.
    public static let mainnetChainID = "4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S"

    /// Mais moedas que isso e a leitura recusa: a comparacao entre provedores precisa da
    /// lista inteira.
    static let maxCoinsRead = 1_000
    static let pageSize: UInt64 = 250

    let transport: ReaderTransport
    let pool: ProviderPool
    let providers: [Provider]
    let graphQL: URL?
    private var mainnetVerified: Set<String> = []

    public init(
        transport: ReaderTransport = HTTPClient.shared,
        providers: [ProviderPool.Provider] = Endpoints.sui,
        graphQL: URL? = Endpoints.suiGraphQL,
        pacing: TimeInterval = 0.25
    ) {
        // Os nos publicos limitam por IP, sem numero publicado: um quarto de segundo
        // entre chamadas ao mesmo host, e o 429 repete uma vez.
        let hosts = (providers.map(\.baseURL) + [graphQL].compactMap { $0 }).compactMap(\.host)
        self.transport = PacedTransport(base: transport, intervals: Dictionary(hosts.map { ($0, pacing) }, uniquingKeysWith: { a, _ in a }))
        self.pool = ProviderPool(providers)
        self.providers = providers
        self.graphQL = graphQL
    }

    // MARK: Estado para o plano

    /// Moedas de SUI, preco de referencia e epoca, em dois provedores concordando. O
    /// saldo de endereco vai junto, so para a tela (vale o menor dos dois).
    public func accountState(owner: SuiAddress) async throws -> SuiAccountState {
        try await agreedTwice { try await self.accountStatePair(owner) }
    }

    private func accountStatePair(_ owner: SuiAddress) async throws -> SuiAccountState {
        let readings = try await Quorum.collect(await pool.available(), pool: pool, count: 2) { provider in
            try await self.accountState(owner, at: provider)
        }.map(\.value)
        return try Self.merge(readings[0], readings[1])
    }

    /// Duas leituras do estado: as mesmas moedas (mesmo id, versao, digesto e saldo), o
    /// mesmo preco e a mesma epoca.
    static func merge(_ a: SuiAccountState, _ b: SuiAccountState) throws -> SuiAccountState {
        let order: (SuiCoin, SuiCoin) -> Bool = { $0.ref.objectID.hex < $1.ref.objectID.hex }
        guard a.coins.sorted(by: order) == b.coins.sorted(by: order) else { throw ReaderError.providersDisagree(field: "coins") }
        guard a.referenceGasPrice == b.referenceGasPrice else { throw ReaderError.providersDisagree(field: "reference_gas_price") }
        guard a.epoch == b.epoch else { throw ReaderError.providersDisagree(field: "epoch") }
        return SuiAccountState(
            coins: a.coins.sorted(by: order), referenceGasPrice: a.referenceGasPrice, epoch: a.epoch,
            addressBalance: min(a.addressBalance, b.addressBalance)
        )
    }

    private func accountState(_ owner: SuiAddress, at provider: Provider) async throws -> SuiAccountState {
        try await ensureMainnet(provider)
        let coins = try await coins(owner, at: provider)
        let epoch = try await epochReading(provider)
        let balance = try Self.parseBalance(
            try await call(provider, "sui.rpc.v2.StateService/GetBalance", Self.balanceRequest(owner)), coinType: SuiPlanner.suiCoinType
        )
        return SuiAccountState(coins: coins, referenceGasPrice: epoch.referenceGasPrice, epoch: epoch.epoch, addressBalance: balance.address)
    }

    /// Todas as moedas de SUI do dono num provedor, pagina a pagina.
    private func coins(_ owner: SuiAddress, at provider: Provider) async throws -> [SuiCoin] {
        var coins: [SuiCoin] = []
        var token: [UInt8]?
        repeat {
            let page = try Self.parseCoins(
                try await call(provider, "sui.rpc.v2.StateService/ListOwnedObjects", Self.coinsRequest(owner, pageToken: token)), owner: owner
            )
            coins += page.coins
            token = page.nextPageToken
            guard coins.count <= Self.maxCoinsRead else { throw ReaderError.unsupported("moedas demais") }
        } while token != nil
        return coins
    }

    // MARK: Simulacao

    /// A transacao simulada em dois provedores, sem assinatura. Cada resultado traz o
    /// sucesso, o gas e as variacoes de saldo, e o digesto que o provedor devolve tem de
    /// ser o da transacao enviada.
    public func simulate(_ transaction: SuiTransactionData) async throws -> [SuiSimulation] {
        let bytes = transaction.bcs()
        let digest = transaction.digestBase58
        return try await Quorum.collect(await pool.available(), pool: pool, count: 2) { provider in
            try await self.ensureMainnet(provider)
            let message = try await self.call(provider, "sui.rpc.v2.TransactionExecutionService/SimulateTransaction", Self.simulateRequest(bytes))
            return try Self.parseSimulation(message, digest: digest)
        }.map(\.value)
    }

    /// Custo de gas para o orcamento: a simulacao em dois provedores, as duas com
    /// sucesso, e a maior parcela das duas.
    public func estimateGas(_ transaction: SuiTransactionData) async throws -> SuiGasCost {
        let results = try await simulate(transaction)
        guard results.allSatisfy(\.success) else { throw ReaderError.executionReverted }
        return SuiGasCost.maximum(results[0].gas, results[1].gas)
    }

    // MARK: Transmissao e acompanhamento

    /// Os mesmos bytes assinados para ate dois provedores, um depois do outro. So sai
    /// transacao que `SuiSignedTransaction.parse` aceita (assinatura que verifica, chave
    /// do remetente, id igual ao digesto). O id devolvido e o calculado aqui; o que o
    /// provedor responde tem de ser igual. O resultado provisorio diz se a execucao deu
    /// certo ("success") ou falhou cobrando gas ("failure").
    public func broadcast(_ signed: SignedTransaction) async throws -> BroadcastReceipt {
        let parsed: SuiSignedTransaction
        do { parsed = try SuiSignedTransaction.parse(signed) } catch { throw ReaderError.broadcastMismatch }
        let id = parsed.data.digestBase58
        let request = Self.executeRequest(parsed.transactionBytes, signature: parsed.signature)
        var tally = BroadcastTally()
        var provisional: String?
        for provider in (await pool.available()).prefix(2) {
            do {
                try await ensureMainnet(provider)
                let message = try await call(provider, "sui.rpc.v2.TransactionExecutionService/ExecuteTransaction", request, timeout: 30)
                let outcome = try Self.parseExecution(message, digest: id)
                provisional = provisional ?? (outcome ? "success" : "failure")
                await pool.reportSuccess(provider)
                tally.add(.success(id), provider: provider)
            } catch {
                await Quorum.record(error, provider, pool)
                tally.add(.failure(error), provider: provider)
            }
        }
        return try tally.receipt(chainID: Chain.sui.id, id: id, provisional: provisional)
    }

    /// A transacao pelo digesto, em dois provedores (`BatchGetTransactions`, que diz "nao
    /// encontrada" no corpo). Final so com as duas concordando no resultado e com
    /// checkpoint. Nenhuma das duas conhecendo, e a epoca atual (dos dois) ja depois de
    /// `validUntilEpoch`: vencida, os validadores nao executam mais.
    public func status(of digest: String, validUntilEpoch: UInt64? = nil) async throws -> TransactionStatus {
        guard let bytes = Base58.bitcoin.decode(digest), bytes.count == 32 else { throw ReaderError.invalidInput("digesto") }
        let readings = try await Quorum.collect(await pool.available(), pool: pool, count: 2) { provider in
            try await self.ensureMainnet(provider)
            return try Self.parseTransactionLookup(
                try await self.call(provider, "sui.rpc.v2.LedgerService/BatchGetTransactions", Self.lookupRequest(digest)), digest: digest
            )
        }.map(\.value)
        switch (readings[0], readings[1]) {
        case (.found(let a, let checkpointA), .found(let b, let checkpointB)) where a == b && checkpointA != nil && checkpointB != nil:
            return a ? .confirmed(block: min(checkpointA ?? 0, checkpointB ?? 0), confirmations: nil) : .failed(reason: "execution")
        case (.found, _), (_, .found):
            return .pending
        case (.notFound, .notFound):
            if let validUntilEpoch, try await currentEpoch() > validUntilEpoch { return .failed(reason: "expired") }
            return .notFound
        }
    }

    /// A epoca atual em dois provedores concordando.
    public func currentEpoch() async throws -> UInt64 {
        try await Quorum.agree(await pool.available(), pool: pool, field: "epoch") { provider in
            try await self.ensureMainnet(provider)
            return try await self.epochReading(provider).epoch
        }
    }

    func epochReading(_ provider: Provider) async throws -> EpochReading {
        try Self.parseEpoch(try await call(provider, "sui.rpc.v2.LedgerService/GetEpoch", Self.epochRequest()))
    }

    // MARK: Saldo da tela

    /// O saldo para a tela: SUI total (moedas e saldo de endereco) e quantas outras
    /// moedas a conta tem, escondidas por padrao. Um provedor so; o plano rele em dois.
    public func displayBalance(owner text: String) async throws -> ChainBalance {
        guard case .success(let owner) = SuiAddress.parse(text) else { throw ReaderError.invalidInput("endereco") }
        let balances = try await Quorum.first(await pool.available(), pool: pool) { provider in
            try await self.ensureMainnet(provider)
            return try Self.parseBalances(try await self.call(provider, "sui.rpc.v2.StateService/ListBalances", Self.balancesRequest(owner)))
        }
        let sui = balances.first { $0.coinType == SuiPlanner.suiCoinType }?.total ?? 0
        let others = balances.filter { $0.coinType != SuiPlanner.suiCoinType && $0.total > 0 }.count
        return ChainBalance(
            chainID: Chain.sui.id, holdings: [Holding(asset: .native(.sui), amount: BigUInt(sui))],
            accountExists: true, unknownTokenCount: others, fetchedAt: .now
        )
    }

    // MARK: Transporte

    /// Uma chamada unaria: a unica mensagem de resposta.
    private func call(_ provider: Provider, _ method: String, _ message: SuiProtoWriter, timeout: TimeInterval = 10) async throws -> SuiProtoMessage {
        let data = try await transport.send(SuiGRPC.request(provider, method, message.bytes, timeout: timeout))
        let messages = try SuiGRPC.messages(data, method: method)
        guard messages.count == 1 else { throw ReaderError.malformed(field: method) }
        return try SuiProtoMessage(messages[0], path: method)
    }

    /// Uma chamada com varias respostas (`ListTransactions`).
    func stream(_ provider: Provider, _ method: String, _ message: SuiProtoWriter, timeout: TimeInterval = 30) async throws -> [SuiProtoMessage] {
        let data = try await transport.send(SuiGRPC.request(provider, method, message.bytes, timeout: timeout))
        return try SuiGRPC.messages(data, method: method).map { try SuiProtoMessage($0, path: method) }
    }

    /// Uma vez por provedor: o no e da rede principal.
    func ensureMainnet(_ provider: Provider) async throws {
        guard !mainnetVerified.contains(provider.name) else { return }
        let info = try await call(provider, "sui.rpc.v2.LedgerService/GetServiceInfo", SuiProtoWriter())
        guard try info.string(1, "chain_id") == Self.mainnetChainID, try info.string(2, "chain") == "mainnet" else {
            throw ReaderError.wrongNetwork
        }
        mainnetVerified.insert(provider.name)
    }

    /// As leituras sao de dois nos em checkpoints um pouco diferentes, e uma conta que
    /// acabou de enviar muda entre elas: diferenca na primeira vez rele uma vez.
    private func agreedTwice<T: Sendable>(_ read: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await read()
        } catch ReaderError.providersDisagree {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return try await read()
        }
    }

    // MARK: Pedidos

    static func epochRequest() -> SuiProtoWriter {
        var w = SuiProtoWriter()
        w.message(2, .fieldMask(["epoch", "reference_gas_price"]))
        return w
    }

    static func balanceRequest(_ owner: SuiAddress) -> SuiProtoWriter {
        var w = SuiProtoWriter()
        w.string(1, owner.hex)
        w.string(2, SuiPlanner.suiCoinType)
        return w
    }

    static func balancesRequest(_ owner: SuiAddress) -> SuiProtoWriter {
        var w = SuiProtoWriter()
        w.string(1, owner.hex)
        w.uint64(2, 100)
        return w
    }

    static func coinsRequest(_ owner: SuiAddress, pageToken: [UInt8]?) -> SuiProtoWriter {
        var w = SuiProtoWriter()
        w.string(1, owner.hex)
        w.uint64(2, pageSize)
        if let pageToken { w.bytes(3, pageToken) }
        w.message(4, .fieldMask(["object_id", "version", "digest", "owner", "object_type", "balance"]))
        w.string(5, SuiPlanner.suiCoinObjectType)
        return w
    }

    /// `Transaction { bcs: Bcs { value } }`.
    static func transaction(_ bytes: [UInt8]) -> SuiProtoWriter {
        var bcs = SuiProtoWriter()
        bcs.bytes(2, bytes)
        var tx = SuiProtoWriter()
        tx.message(1, bcs)
        return tx
    }

    static func simulateRequest(_ bytes: [UInt8]) -> SuiProtoWriter {
        var w = SuiProtoWriter()
        w.message(1, transaction(bytes))
        w.message(2, .fieldMask([
            "transaction.effects.transaction_digest", "transaction.effects.status", "transaction.effects.gas_used",
            "transaction.balance_changes",
        ]))
        return w
    }

    static func executeRequest(_ bytes: [UInt8], signature: [UInt8]) -> SuiProtoWriter {
        var bcs = SuiProtoWriter()
        bcs.bytes(2, signature)
        var userSignature = SuiProtoWriter()
        userSignature.message(1, bcs)
        var w = SuiProtoWriter()
        w.message(1, transaction(bytes))
        w.message(2, userSignature)
        w.message(3, .fieldMask(["digest", "effects.transaction_digest", "effects.status"]))
        return w
    }

    static func lookupRequest(_ digest: String) -> SuiProtoWriter {
        var w = SuiProtoWriter()
        w.string(1, digest)
        w.message(2, .fieldMask(["digest", "effects.status", "checkpoint"]))
        return w
    }

    // MARK: Leitura das respostas

    struct EpochReading: Equatable {
        let epoch: UInt64
        let referenceGasPrice: UInt64
    }

    /// `GetEpochResponse { Epoch epoch = 1 }`, `Epoch { epoch = 1, reference_gas_price = 8 }`.
    static func parseEpoch(_ message: SuiProtoMessage) throws -> EpochReading {
        let epoch = try message.requiredMessage(1, "epoch")
        return EpochReading(epoch: try epoch.requiredUInt64(1, "epoch"), referenceGasPrice: try epoch.requiredUInt64(8, "reference_gas_price"))
    }

    struct BalanceReading: Equatable {
        let coinType: String
        let total: UInt64
        let address: UInt64
        let coins: UInt64
    }

    /// `Balance { coin_type = 1, balance = 3, address_balance = 4, coin_balance = 5 }`. O
    /// proto3 omite o que e zero.
    static func parseBalanceMessage(_ message: SuiProtoMessage) throws -> BalanceReading {
        guard let coinType = normalizedType(try message.requiredString(1, "coin_type")) else {
            throw ReaderError.malformed(field: message.path + ".coin_type")
        }
        let total = try message.uint64(3, "balance") ?? 0
        let address = try message.uint64(4, "address_balance") ?? 0
        let coins = try message.uint64(5, "coin_balance") ?? 0
        // As duas parcelas somam o total. No sem as parcelas (so o total) vale como tudo
        // em moedas: o saldo de endereco so muda a nota da tela.
        let sum = address.addingReportingOverflow(coins)
        guard (!sum.overflow && sum.partialValue == total) || (address == 0 && coins == 0) else {
            throw ReaderError.malformed(field: message.path + ".balance")
        }
        return BalanceReading(coinType: coinType, total: total, address: address, coins: coins)
    }

    static func parseBalance(_ message: SuiProtoMessage, coinType: String) throws -> BalanceReading {
        guard let balance = try message.message(1, "balance") else {
            return BalanceReading(coinType: coinType, total: 0, address: 0, coins: 0)
        }
        let reading = try parseBalanceMessage(balance)
        guard reading.coinType == coinType else { throw ReaderError.responseMismatch(field: "balance.coin_type") }
        return reading
    }

    static func parseBalances(_ message: SuiProtoMessage) throws -> [BalanceReading] {
        try message.messages(1, "balances").map(parseBalanceMessage)
    }

    struct CoinPage {
        let coins: [SuiCoin]
        let nextPageToken: [UInt8]?
    }

    /// `ListOwnedObjectsResponse { repeated Object objects = 1; bytes next_page_token = 2 }`.
    /// Cada objeto tem de ser `Coin<SUI>` do dono pedido (dono do tipo endereco), com
    /// versao, digesto de 32 bytes e saldo.
    static func parseCoins(_ message: SuiProtoMessage, owner: SuiAddress) throws -> CoinPage {
        var coins: [SuiCoin] = []
        for object in try message.messages(1, "objects") {
            let path = object.path
            guard case .success(let id) = SuiAddress.parse(try object.requiredString(2, "object_id")) else {
                throw ReaderError.malformed(field: path + ".object_id")
            }
            let version = try object.requiredUInt64(3, "version")
            let ref: SuiObjectRef
            do {
                ref = try SuiObjectRef(objectID: id, version: version, digestBase58: try object.requiredString(4, "digest"))
            } catch let error as ReaderError {
                throw error
            } catch {
                throw ReaderError.malformed(field: path + ".digest")
            }
            let ownerMessage = try object.requiredMessage(5, "owner")
            guard try ownerMessage.uint64(1, "kind") == 1,
                  case .success(let objectOwner) = SuiAddress.parse(try ownerMessage.requiredString(2, "address")),
                  objectOwner == owner
            else { throw ReaderError.responseMismatch(field: path + ".owner") }
            guard normalizedType(try object.requiredString(6, "object_type")) == normalizedType(SuiPlanner.suiCoinObjectType) else {
                throw ReaderError.responseMismatch(field: path + ".object_type")
            }
            coins.append(SuiCoin(ref: ref, balance: try object.uint64(101, "balance") ?? 0))
        }
        let token = try message.bytes(2, "next_page_token")
        return CoinPage(coins: coins, nextPageToken: token.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// `SimulateTransactionResponse { ExecutedTransaction transaction = 1 }`, com
    /// `effects.transaction_digest`, `effects.status`, `effects.gas_used` e
    /// `balance_changes`.
    static func parseSimulation(_ message: SuiProtoMessage, digest: String) throws -> SuiSimulation {
        let executed = try message.requiredMessage(1, "transaction")
        let effects = try executed.requiredMessage(4, "effects")
        // A simulacao nao preenche o digesto de fora; o dos efeitos diz de que transacao
        // eles sao.
        guard try effects.string(7, "transaction_digest") == digest else { throw ReaderError.responseMismatch(field: "simulate.digest") }
        let success = try effects.requiredMessage(4, "status").bool(1, "success") ?? false
        let gasUsed = try effects.requiredMessage(6, "gas_used")
        let gas = SuiGasCost(
            computationCost: try gasUsed.uint64(1, "computation_cost") ?? 0,
            storageCost: try gasUsed.uint64(2, "storage_cost") ?? 0,
            storageRebate: try gasUsed.uint64(3, "storage_rebate") ?? 0
        )
        let changes = try executed.messages(8, "balance_changes").map { change -> SuiBalanceChange in
            guard case .success(let address) = SuiAddress.parse(try change.requiredString(1, "address")),
                  let coinType = normalizedType(try change.requiredString(2, "coin_type")),
                  let (negative, magnitude) = signedAmount(try change.requiredString(3, "amount"))
            else { throw ReaderError.malformed(field: change.path) }
            return SuiBalanceChange(address: address, coinType: coinType, negative: negative, magnitude: magnitude)
        }
        return SuiSimulation(success: success, gas: gas, balanceChanges: changes)
    }

    /// `ExecuteTransactionResponse { ExecutedTransaction transaction = 1 }`: o digesto
    /// devolvido tem de ser o da transacao; devolve se a execucao deu certo.
    static func parseExecution(_ message: SuiProtoMessage, digest: String) throws -> Bool {
        let executed = try message.requiredMessage(1, "transaction")
        guard let effects = try executed.message(4, "effects"), let status = try effects.message(4, "status") else {
            throw ReaderError.malformed(field: "execute.effects.status")
        }
        // O digesto de fora ou o dos efeitos: os dois, quando vierem, tem de ser o calculado.
        let reported = [try executed.string(1, "digest"), try effects.string(7, "transaction_digest")].compactMap { $0 }
        guard !reported.isEmpty, reported.allSatisfy({ $0 == digest }) else { throw ReaderError.broadcastMismatch }
        return try status.bool(1, "success") ?? false
    }

    enum Lookup: Equatable {
        case found(success: Bool, checkpoint: UInt64?)
        case notFound
    }

    /// `BatchGetTransactionsResponse { repeated GetTransactionResult transactions = 1 }`,
    /// cada um `oneof { ExecutedTransaction transaction = 1; google.rpc.Status error = 2 }`.
    /// So o codigo 5 (NOT_FOUND) vale como "nao encontrada"; outro erro e falha de leitura.
    static func parseTransactionLookup(_ message: SuiProtoMessage, digest: String) throws -> Lookup {
        let results = try message.messages(1, "transactions")
        guard results.count == 1 else { throw ReaderError.malformed(field: "transactions") }
        if let error = try results[0].message(2, "error") {
            guard try error.uint64(1, "code") == 5 else { throw ReaderError.providerError(code: "grpc-lookup") }
            return .notFound
        }
        let executed = try results[0].requiredMessage(1, "transaction")
        guard try executed.string(1, "digest") == digest else { throw ReaderError.responseMismatch(field: "transaction.digest") }
        guard let effects = try executed.message(4, "effects"), let status = try effects.message(4, "status") else {
            return .found(success: false, checkpoint: nil)
        }
        return .found(success: try status.bool(1, "success") ?? false, checkpoint: try executed.uint64(6, "checkpoint"))
    }

    // MARK: Formatos

    /// Tipo Move com os enderecos na forma longa ("0x2::sui::SUI" vira
    /// "0x000...0002::sui::SUI"). Nil se nao tiver o formato `endereco::modulo::nome`.
    static func normalizedType(_ text: String) -> String? {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("0x") {
                var end = text.index(index, offsetBy: 2)
                while end < text.endIndex, text[end].isHexDigit { end = text.index(after: end) }
                let digits = text[text.index(index, offsetBy: 2)..<end]
                guard !digits.isEmpty, digits.count <= 64 else { return nil }
                out += "0x" + String(repeating: "0", count: 64 - digits.count) + digits.lowercased()
                index = end
            } else {
                out.append(text[index])
                index = text.index(after: index)
            }
        }
        guard out.hasPrefix("0x"), out.contains("::") else { return nil }
        return out
    }

    /// "-2804976876" e "1000": sinal e modulo.
    static func signedAmount(_ text: String) -> (Bool, BigUInt)? {
        let negative = text.hasPrefix("-")
        let digits = negative ? String(text.dropFirst()) : text
        guard !digits.isEmpty, digits.count <= 40, digits.allSatisfy(\.isASCII), let value = BigUInt(decimal: digits) else { return nil }
        return (negative, value)
    }
}
