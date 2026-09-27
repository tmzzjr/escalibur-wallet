import EscaliburChains
import EscaliburCore
import Foundation

/// O destino de um envio TON como a rede o ve, antes de haver valor e origem.
public struct TONDestinationState: Sendable, Equatable {
    public let status: TONAccountStatus
    /// Hash do codigo, calculado aqui do BOC que o provedor mandou; so em conta ativa.
    public let codeHash: [UInt8]?

    public init(status: TONAccountStatus, codeHash: [UInt8]?) {
        self.status = status
        self.codeHash = codeHash
    }
}

/// Leitura de estado, transmissao e historico da TON.
///
/// Provedores: a API JSON-RPC v2 da toncenter aceita o endereco no corpo do POST
/// (estado, get-methods, estimativa, transmissao). A tonapi e a segunda fonte, de outro
/// operador; ela so tem GET com o endereco no caminho, e isso fica aceito e documentado
/// (docs/seguranca.md §5.3). O historico e o acompanhamento usam a tonapi e a v3 da
/// toncenter, pelo mesmo motivo.
///
/// O que decide para onde vai o dinheiro ou quanto sai vem das duas, e as duas tem de
/// concordar (auditoria 2, B3): o `seqno`; status, saldo e codigo da conta do dono e do
/// destino; o saldo, o dono e o mestre da carteira jetton. Uma fonte so, com o motivo:
/// - a taxa estimada (`estimateFee`, so a toncenter emula): nao entra na mensagem (a
///   rede cobra o custo real) e fica sob o teto compilado `TONPlanner.feeCeiling`; uma
///   fonte mentindo so encolhe o "enviar tudo" ou faz o plano recusar;
/// - o endereco da carteira jetton (`get_wallet_address`): a carteira usa o endereco
///   calculado aqui, e a leitura so confere; uma fonte mentindo so faz recusar;
/// - o historico (so a tonapi agrupa eventos): informativo, nada dali entra num plano.
///
/// O hash do codigo das contas e calculado aqui, do BOC do codigo que o provedor manda:
/// ninguem diz "isto e uma V4R2", o hash diz.
public actor TONReader {
    public static let shared = TONReader()

    let transport: ReaderTransport
    let rpcPool: ProviderPool
    let apiPool: ProviderPool
    let apiProviders: [Provider]

    /// A transferencia planejada, do jeito que o `TONPlanner` vai montar: a estimativa de
    /// taxa usa a mesma mensagem.
    public enum Intent: Sendable, Equatable {
        /// `amount` em nanoton.
        case ton(to: String, amount: BigUInt, comment: String?)
        /// `amount` em unidades de 6 casas.
        case usdt(to: String, amount: BigUInt, comment: String?)

        var destination: String {
            switch self {
            case .ton(let to, _, _), .usdt(let to, _, _): return to
            }
        }
    }

    public init(
        transport: ReaderTransport = HTTPClient.shared,
        rpc: [ProviderPool.Provider] = Endpoints.tonJSONRPC,
        api: [ProviderPool.Provider] = Endpoints.ton
    ) {
        // toncenter e tonapi sem chave: 1 requisicao por segundo por IP em cada uma.
        self.transport = PacedTransport(base: transport, intervals: ["toncenter.com": 1.05, "tonapi.io": 1.05])
        self.rpcPool = ProviderPool(rpc)
        self.apiPool = ProviderPool(api)
        self.apiProviders = api
    }

    // MARK: Estado para o plano

    /// Estado da carteira do dono (status, saldo e hash do codigo, e o `seqno`), do
    /// destino (status, hash do codigo), tudo em dois provedores concordando, e a taxa
    /// estimada da mensagem que o plano vai montar, com assinatura desligada na emulacao.
    /// Taxa zero ou acima de `TONPlanner.feeCeiling` e recusada aqui.
    public func chainState(wallet: TONWallet, intent: Intent, now: Date = .now) async throws -> TONChainState {
        guard case .success(let resolved) = Address.validate(intent.destination, for: .ton),
              case .success(let destination) = TONAddress.parse(resolved.address)
        else { throw ReaderError.invalidInput("destino") }
        let owner = try await agreedAccount(wallet.address)
        let seqno = owner.status == .uninitialized ? 0 : try await agreedSeqno(wallet.address)
        let target = try await agreedAccount(destination.address)

        let message: TONOutgoingMessage
        switch intent {
        case .ton(_, let amount, let comment):
            let bounce = destination.bounceable != false && target.status == .active
            message = TONOutgoingMessage(destination: destination.address, amount: amount, bounce: bounce, body: try Self.commentCell(comment))
        case .usdt(_, let amount, let comment):
            let body = try TONJetton.transferBody(
                queryID: UInt64(Self.unixTime(now)), amount: amount, destination: destination.address,
                responseDestination: wallet.address, forwardTON: TONJetton.forwardTON, comment: comment
            )
            message = TONOutgoingMessage(destination: try TONJetton.usdtWallet(owner: wallet.address), amount: TONJetton.attachedTON, bounce: true, body: body)
        }
        let validUntil = Self.unixTime(now.addingTimeInterval(TONPlanner.validitySeconds))
        let fee = try await estimateFee(wallet: wallet, seqno: seqno, validUntil: validUntil, message: message, deploy: owner.status == .uninitialized)
        return TONChainState(
            accountStatus: owner.status, seqno: seqno, balance: owner.balance, codeHash: owner.codeHash,
            destinationStatus: target.status, destinationCodeHash: target.codeHash, estimatedFee: fee
        )
    }

    /// Status e hash do codigo de uma conta qualquer, a mesma leitura em dois provedores
    /// que `chainState` faz do destino. Para a tela do destino; o plano le de novo em
    /// `chainState`.
    public func destinationState(_ address: TONAddress) async throws -> TONDestinationState {
        let reading = try await agreedAccount(address)
        return TONDestinationState(status: reading.status, codeHash: reading.codeHash)
    }

    /// A carteira jetton de USDT do dono (`get_wallet_address` no mestre compilado,
    /// conferida contra o calculo local, que e o endereco usado) e o saldo dela
    /// (`get_wallet_data` na toncenter e na tonapi, conferindo dono e mestre nas duas).
    /// Carteira jetton ainda nao criada, nas duas, tem saldo zero.
    public func jettonState(owner: TONAddress) async throws -> TONJettonState {
        let expected = try TONJetton.usdtWallet(owner: owner)
        let reported = try await jettonWalletAddress(owner: owner)
        guard reported == expected else { throw ReaderError.responseMismatch(field: "get_wallet_address") }
        let balance = try await jettonBalance(wallet: expected, owner: owner)
        return TONJettonState(ownerJettonWallet: expected.raw, balance: balance)
    }

    // MARK: Transmissao e acompanhamento

    /// A mensagem externa (BOC base64) na toncenter (`sendBocReturnHash`) e na tonapi
    /// (`blockchain/message`), os mesmos bytes. O id e o hash da mensagem, calculado aqui.
    public func broadcast(_ signed: SignedTransaction) async throws -> BroadcastReceipt {
        guard signed.chainID == Chain.ton.id, let decoded = Data(base64Encoded: signed.encoded), [UInt8](decoded) == signed.raw,
              let root = try? TONBOC.parseRoot(signed.raw), Hex.encode(root.hash) == signed.id.lowercased()
        else { throw ReaderError.broadcastMismatch }
        let transport = self.transport
        let id = signed.id.lowercased()
        let targets: [(Provider, ProviderPool)] = (await rpcPool.available()).map { ($0, rpcPool) }
            + apiProviders.filter { $0.name == "tonapi" }.map { ($0, apiPool) }
        var tally = BroadcastTally()
        for (provider, pool) in targets {
            do {
                if provider.name == "tonapi" {
                    _ = try await transport.send(.post(provider.baseURL.adding(path: "blockchain/message"), .object(["boc": .string(signed.encoded)])))
                } else {
                    let result = try await rpc(provider, "sendBocReturnHash", ["boc": .string(signed.encoded)])
                    let hash = try result.field("hash", "sendBocReturnHash").string("sendBocReturnHash.hash")
                    guard let bytes = Data(base64Encoded: hash), Hex.encode(bytes) == id else { throw ReaderError.broadcastMismatch }
                }
                await pool.reportSuccess(provider)
                tally.add(.success(id), provider: provider)
            } catch {
                await Quorum.record(error, provider, pool)
                tally.add(.failure(error), provider: provider)
            }
        }
        return try tally.receipt(chainID: Chain.ton.id, id: id)
    }

    /// A transacao da carteira que processou a mensagem externa, pela tonapi e pela v3 da
    /// toncenter. Final so com as duas concordando. Diz o resultado na carteira do dono
    /// (a mensagem foi aceita e o envio saiu); o que acontece depois no destino e outra
    /// transacao. Sem nada nas duas e com `expiresAt` (o valid_until) passado ha mais de
    /// um minuto, vencida: o contrato nao aceita mais a mensagem.
    public func status(of messageHash: String, expiresAt: Date? = nil, now: Date = .now) async throws -> TransactionStatus {
        guard let bytes = Hex.decode(messageHash), bytes.count == 32 else { throw ReaderError.invalidInput("hash") }
        let hash = Hex.encode(bytes)
        let transport = self.transport
        let readings = try await Quorum.collect(apiProviders, pool: apiPool, count: 2) { (provider: Provider) async throws -> TransactionStatus? in
            if provider.name == "tonapi" {
                let data: Data
                do {
                    data = try await transport.send(.get(provider.baseURL.adding(path: "blockchain/messages/\(hash)/transaction")))
                } catch HTTPClient.Failure.status(404) {
                    return nil
                }
                return try Self.parseTonapiTransaction(StrictJSON.parse(data))
            }
            let url = provider.baseURL.adding(path: "transactionsByMessage").adding(query: [("msg_hash", hash), ("direction", "in")])
            return try Self.parseToncenterTransactions(StrictJSON.parse(try await transport.send(.get(url))))
        }.map(\.value)
        if let first = readings[0], readings[1] == first { return first }
        if readings.contains(where: { $0 != nil }) { return .pending }
        if let expiresAt, now.timeIntervalSince(expiresAt) > 60 { return .failed(reason: "expired") }
        return .notFound
    }

    // MARK: Historico

    /// Eventos da tonapi (`/accounts/{a}/events`): transferencias de TON e de jetton ja
    /// agrupadas por operacao. Comentarios nao entram (sao o canal do golpe do link).
    public func history(address: TONAddress) async throws -> ActivityPage {
        guard let tonapi = apiProviders.first(where: { $0.name == "tonapi" }) else {
            throw ReaderError.unsupported("historico sem indexador")
        }
        let url = tonapi.baseURL.adding(path: "accounts/" + address.raw + "/events").adding(query: [("limit", "\(ActivityRules.pageSize)")])
        let json = try StrictJSON.parse(try await transport.send(.get(url, timeout: 30)))
        return try Self.parseEvents(json, owner: address)
    }

    // MARK: Leituras

    struct AccountReading: Sendable, Equatable {
        let status: TONAccountStatus
        let balance: BigUInt
        let codeHash: [UInt8]?
    }

    /// So o provedor da tonapi, a segunda fonte de cada leitura em par.
    private var tonapiProviders: [Provider] { apiProviders.filter { $0.name == "tonapi" } }

    /// As duas APIs leem em momentos um pouco diferentes, e uma carteira que acabou de
    /// enviar (ou de ser ativada) muda entre as leituras: diferenca na primeira vez rele
    /// as duas uma vez, e so a segunda diferenca vira erro.
    private func agreedTwice<T: Sendable>(_ read: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await read()
        } catch ReaderError.providersDisagree {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return try await read()
        }
    }

    /// Status, saldo e hash do codigo de uma conta: `getAddressInformation` na toncenter
    /// (POST) e `blockchain/accounts` na tonapi, as duas respondendo e concordando
    /// (`mergeAccounts`). Sem contingencia de uma fonte so: a conta do destino decide o
    /// bounce e se o destino e contrato de token, e a do dono decide o maximo.
    private func agreedAccount(_ address: TONAddress) async throws -> AccountReading {
        try await agreedTwice { try await self.accountPair(address) }
    }

    private func accountPair(_ address: TONAddress) async throws -> AccountReading {
        let transport = self.transport
        let tonapi = tonapiProviders
        async let center: AccountReading = Quorum.first(await rpcPool.available(), pool: rpcPool) { provider in
            try Self.parseAddressInformation(try await self.rpc(provider, "getAddressInformation", ["address": .string(address.raw)]))
        }
        async let api: AccountReading = Quorum.first(tonapi, pool: apiPool) { provider in
            let url = provider.baseURL.adding(path: "blockchain/accounts/" + address.raw)
            do {
                return try Self.parseTonapiAccount(StrictJSON.parse(try await transport.send(.get(url))), address: address)
            } catch HTTPClient.Failure.status(404) {
                // A tonapi responde 404 para conta que nunca existiu; a toncenter, estado
                // "uninitialized" com saldo zero.
                return AccountReading(status: .uninitialized, balance: 0, codeHash: nil)
            }
        }
        return try Self.mergeAccounts(try await center, try await api)
    }

    /// Duas leituras da mesma conta: o mesmo status e o mesmo codigo. O saldo muda de um
    /// bloco para outro e vale o menor, que so pode fazer o plano pedir menos ou recusar.
    static func mergeAccounts(_ a: AccountReading, _ b: AccountReading) throws -> AccountReading {
        guard a.status == b.status else { throw ReaderError.providersDisagree(field: "account.status") }
        guard a.codeHash == b.codeHash else { throw ReaderError.providersDisagree(field: "account.code") }
        return AccountReading(status: a.status, balance: min(a.balance, b.balance), codeHash: a.codeHash)
    }

    /// `seqno` na toncenter (POST) e na tonapi; os dois tem de ser iguais.
    private func agreedSeqno(_ address: TONAddress) async throws -> UInt32 {
        try await agreedTwice { try await self.seqnoPair(address) }
    }

    private func seqnoPair(_ address: TONAddress) async throws -> UInt32 {
        let transport = self.transport
        let tonapi = tonapiProviders
        async let center: UInt32 = Quorum.first(await rpcPool.available(), pool: rpcPool) { provider in
            try Self.parseSeqno(toncenter: try await self.rpc(provider, "runGetMethod", [
                "address": .string(address.raw), "method": .string("seqno"), "stack": .array([]),
            ]))
        }
        async let api: UInt32 = Quorum.first(tonapi, pool: apiPool) { provider in
            let url = provider.baseURL.adding(path: "blockchain/accounts/" + address.raw + "/methods/seqno")
            return try Self.parseSeqno(tonapi: StrictJSON.parse(try await transport.send(.get(url))))
        }
        let (a, b) = try await (center, api)
        guard a == b else { throw ReaderError.providersDisagree(field: "seqno") }
        return a
    }

    /// Emulacao com a assinatura desligada (`ignore_chksig`) do corpo que o plano vai
    /// assinar, com 64 bytes zerados no lugar da assinatura. Soma as taxas da origem:
    /// encaminhamento de entrada, armazenamento, gas e encaminhamento da saida.
    ///
    /// Uma fonte so (a tonapi nao tem este metodo com o endereco no corpo): a taxa nao
    /// entra na mensagem, a rede cobra o custo real, e o valor passa pelo teto compilado.
    private func estimateFee(wallet: TONWallet, seqno: UInt32, validUntil: UInt32, message: TONOutgoingMessage, deploy: Bool) async throws -> BigUInt {
        let body = try Self.emulationBody(wallet: wallet, seqno: seqno, validUntil: validUntil, messages: [message])
        var params: [String: StrictJSON] = [
            "address": .string(wallet.address.raw), "body": .string(TONBOC.serializeBase64(body)), "ignore_chksig": .bool(true),
        ]
        if deploy {
            params["init_code"] = .string(TONBOC.serializeBase64(wallet.code))
            params["init_data"] = .string(TONBOC.serializeBase64(wallet.data))
        }
        let frozen = params
        let fee = try await Quorum.first(await rpcPool.available(), pool: rpcPool) { provider in
            try Self.parseEstimateFee(try await self.rpc(provider, "estimateFee", frozen))
        }
        guard !fee.isZero, fee <= TONPlanner.feeCeiling else { throw ReaderError.implausibleValue(field: "estimateFee") }
        return fee
    }

    /// `get_wallet_address` no mestre, na toncenter; na falha, na tonapi. Uma fonte so
    /// basta: o endereco que o plano usa e o calculado aqui (`TONJetton.usdtWallet`), e
    /// esta leitura so confere que o mestre ainda calcula o mesmo. Uma fonte mentindo so
    /// consegue fazer a carteira recusar.
    private func jettonWalletAddress(owner: TONAddress) async throws -> TONAddress {
        var builder = TONCellBuilder()
        try builder.storeAddress(owner)
        let slice = TONBOC.serializeBase64(builder.build())
        do {
            return try await Quorum.first(await rpcPool.available(), pool: rpcPool) { provider in
                let result = try await self.rpc(provider, "runGetMethod", [
                    "address": .string(TONJetton.usdtMaster.raw), "method": .string("get_wallet_address"),
                    "stack": .array([.array([.string("tvm.Slice"), .string(slice)])]),
                ])
                let stack = try Self.toncenterStack(result, method: "get_wallet_address")
                guard let first = stack.first else { throw ReaderError.malformed(field: "get_wallet_address.stack") }
                return try Self.address(fromCell: try Self.toncenterCell(first, "get_wallet_address"), "get_wallet_address")
            }
        } catch {
            guard let tonapi = apiProviders.first(where: { $0.name == "tonapi" }) else { throw error }
            let url = tonapi.baseURL.adding(path: "blockchain/accounts/" + TONJetton.usdtMaster.raw + "/methods/get_wallet_address")
                .adding(query: [("args", owner.raw)])
            let stack = try Self.tonapiStack(StrictJSON.parse(try await transport.send(.get(url))), method: "get_wallet_address")
            guard let first = stack.first else { throw ReaderError.malformed(field: "get_wallet_address.stack") }
            return try Self.address(fromCell: try Self.tonapiCell(first, "get_wallet_address"), "get_wallet_address")
        }
    }

    /// O saldo da carteira jetton em `get_wallet_data` na toncenter e na tonapi. As duas
    /// tem de dizer o mesmo dono e o mestre compilado; o saldo e o menor das duas.
    /// Carteira que nao responde ao get-method nas duas e nao esta ativa (ainda nao
    /// criada) tem saldo zero; uma responde e a outra nao, as fontes discordam.
    private func jettonBalance(wallet: TONAddress, owner: TONAddress) async throws -> BigUInt {
        try await agreedTwice { try await self.jettonBalancePair(wallet: wallet, owner: owner) }
    }

    private func jettonBalancePair(wallet: TONAddress, owner: TONAddress) async throws -> BigUInt {
        let transport = self.transport
        let tonapi = tonapiProviders
        async let center: JettonWalletData? = Quorum.first(await rpcPool.available(), pool: rpcPool) { provider in
            try Self.parseJettonWalletData(toncenter: try await self.rpc(provider, "runGetMethod", [
                "address": .string(wallet.raw), "method": .string("get_wallet_data"), "stack": .array([]),
            ]))
        }
        async let api: JettonWalletData? = Quorum.first(tonapi, pool: apiPool) { provider in
            let url = provider.baseURL.adding(path: "blockchain/accounts/" + wallet.raw + "/methods/get_wallet_data")
            do {
                return try Self.parseJettonWalletData(tonapi: StrictJSON.parse(try await transport.send(.get(url))))
            } catch HTTPClient.Failure.status(404) {
                return nil
            }
        }
        let (a, b) = try await (center, api)
        if let balance = try Self.mergeJettonData(a, b, owner: owner) { return balance }
        // Get-method falhou nas duas: carteira jetton ainda nao criada tem saldo zero;
        // ativa e sem resposta e defeito do provedor.
        let state = try await agreedAccount(wallet)
        guard state.status != .active else { throw ReaderError.malformed(field: "get_wallet_data") }
        return 0
    }

    /// As duas leituras de `get_wallet_data`: cada uma com o dono pedido e o mestre
    /// compilado; o saldo e o menor. `nil` quando nenhuma respondeu.
    static func mergeJettonData(_ a: JettonWalletData?, _ b: JettonWalletData?, owner: TONAddress) throws -> BigUInt? {
        for reading in [a, b].compactMap({ $0 }) where reading.owner != owner || reading.master != TONJetton.usdtMaster {
            throw ReaderError.responseMismatch(field: "get_wallet_data")
        }
        switch (a, b) {
        case (let x?, let y?): return min(x.balance, y.balance)
        case (nil, nil): return nil
        default: throw ReaderError.providersDisagree(field: "get_wallet_data")
        }
    }

    // MARK: HTTP

    /// Uma chamada a API JSON-RPC v2 da toncenter (espacada pelo `PacedTransport`).
    private func rpc(_ provider: Provider, _ method: String, _ params: [String: StrictJSON]) async throws -> StrictJSON {
        let body: StrictJSON = .object(["id": .int(1), "jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)])
        let json = try StrictJSON.parse(try await transport.send(.post(provider.baseURL, body)))
        guard try json.field("ok", method).bool(method + ".ok") else {
            let code = (try? json.field("code", method).int64(method + ".code")).map(String.init) ?? "error"
            throw ReaderError.providerError(code: ReaderError.sanitized(code))
        }
        return try json.field("result", method)
    }

    // MARK: Corpo para a emulacao

    /// O corpo assinado que `TONTransfer` monta, com a assinatura zerada. O layout e
    /// refeito aqui (o do modulo de redes e interno) e conferido contra o `signingHash`
    /// publico do `TONTransfer` com os mesmos campos: se um dia os dois divergirem, a
    /// estimativa para, em vez de estimar outra mensagem.
    static func emulationBody(wallet: TONWallet, seqno: UInt32, validUntil: UInt32, messages: [TONOutgoingMessage]) throws -> TONCell {
        let mode = TONSendMode.standard
        var unsigned = TONCellBuilder()
        switch wallet.version {
        case .v4r2:
            try unsigned.storeUInt(UInt64(wallet.walletID), bits: 32)
            try unsigned.storeUInt(UInt64(validUntil), bits: 32)
            try unsigned.storeUInt(UInt64(seqno), bits: 32)
            try unsigned.storeUInt(0, bits: 8)
            for message in messages {
                try unsigned.storeUInt(UInt64(mode), bits: 8)
                try unsigned.storeRef(message.cell())
            }
        case .v5r1:
            var previous = TONCell.empty
            for message in messages {
                var node = TONCellBuilder()
                try node.storeRef(previous)
                try node.storeUInt(0x0EC3_C86D, bits: 32)
                try node.storeUInt(UInt64(mode), bits: 8)
                try node.storeRef(message.cell())
                previous = node.build()
            }
            try unsigned.storeUInt(0x7369_676E, bits: 32)
            try unsigned.storeUInt(UInt64(wallet.walletID), bits: 32)
            try unsigned.storeUInt(UInt64(validUntil), bits: 32)
            try unsigned.storeUInt(UInt64(seqno), bits: 32)
            try unsigned.storeMaybeRef(previous)
            try unsigned.storeBit(false)
        }
        let reference = try TONTransfer(
            wallet: wallet, path: DerivationPath(components: [DerivationPath.hardened(44), DerivationPath.hardened(607), DerivationPath.hardened(0)]), seqno: seqno, validUntil: validUntil,
            messages: messages, mode: mode, deploy: false
        )
        guard unsigned.build().hash == reference.signingHash else { throw ReaderError.unsupported("layout da carteira divergiu") }

        let zeros = [UInt8](repeating: 0, count: 64)
        var signed = TONCellBuilder()
        switch wallet.version {
        case .v4r2:
            try signed.storeBytes(zeros)
            try signed.storeBuilder(unsigned)
        case .v5r1:
            try signed.storeBuilder(unsigned)
            try signed.storeBytes(zeros)
        }
        return signed.build()
    }

    static func commentCell(_ comment: String?) throws -> TONCell? {
        guard let comment, !comment.isEmpty else { return nil }
        do { return try TONComment.cell(comment) } catch { throw ReaderError.invalidInput("comentario") }
    }

    static func unixTime(_ date: Date) -> UInt32 {
        let seconds = date.timeIntervalSince1970
        guard seconds > 0 else { return 0 }
        return seconds >= Double(UInt32.max) ? UInt32.max : UInt32(seconds)
    }

    // MARK: Parse

    static func codeHash(boc: [UInt8], _ path: String) throws -> [UInt8] {
        do { return try TONBOC.parseRoot(boc).hash } catch { throw ReaderError.malformed(field: path) }
    }

    /// toncenter v2 `getAddressInformation`: `state` "active", "uninitialized" ou
    /// "frozen"; `code` em BOC base64, vazio sem contrato.
    static func parseAddressInformation(_ result: StrictJSON) throws -> AccountReading {
        let path = "getAddressInformation"
        let state = try result.field("state", path).string(path + ".state")
        let status: TONAccountStatus
        switch state {
        case "active": status = .active
        case "uninitialized": status = .uninitialized
        case "frozen": status = .frozen
        default: throw ReaderError.malformed(field: path + ".state")
        }
        let balance = try result.field("balance", path).integer(path + ".balance")
        var hash: [UInt8]?
        if status == .active {
            let code = try result.field("code", path).string(path + ".code")
            guard let bytes = Data(base64Encoded: code), !bytes.isEmpty else { throw ReaderError.malformed(field: path + ".code") }
            hash = try codeHash(boc: [UInt8](bytes), path + ".code")
        }
        return AccountReading(status: status, balance: balance, codeHash: hash)
    }

    /// tonapi `blockchain/accounts/{a}`: `status` "active", "uninit", "nonexist" ou
    /// "frozen"; `code` em BOC hex.
    static func parseTonapiAccount(_ json: StrictJSON, address: TONAddress) throws -> AccountReading {
        let path = "blockchain/accounts"
        guard case .success(let parsed) = TONAddress.parse(try json.field("address", path).string(path + ".address")),
              parsed.address == address
        else { throw ReaderError.responseMismatch(field: path + ".address") }
        let status: TONAccountStatus
        switch try json.field("status", path).string(path + ".status") {
        case "active": status = .active
        case "uninit", "nonexist": status = .uninitialized
        case "frozen": status = .frozen
        default: throw ReaderError.malformed(field: path + ".status")
        }
        let balance = try json.field("balance", path).integer(path + ".balance")
        var hash: [UInt8]?
        if status == .active {
            guard let code = Hex.decode(try json.field("code", path).string(path + ".code")), !code.isEmpty else {
                throw ReaderError.malformed(field: path + ".code")
            }
            hash = try codeHash(boc: code, path + ".code")
        }
        return AccountReading(status: status, balance: balance, codeHash: hash)
    }

    static func toncenterStack(_ result: StrictJSON, method: String) throws -> [StrictJSON] {
        guard try result.field("exit_code", method).int64(method + ".exit_code") == 0 else {
            throw ReaderError.providerError(code: "exit_code")
        }
        return try result.field("stack", method).array(method + ".stack")
    }

    static func tonapiStack(_ json: StrictJSON, method: String) throws -> [StrictJSON] {
        guard try json.field("success", method).bool(method + ".success"),
              try json.field("exit_code", method).int64(method + ".exit_code") == 0
        else { throw ReaderError.providerError(code: "exit_code") }
        return try json.field("stack", method).array(method + ".stack")
    }

    /// Numero da pilha: `["num", "0x157"]` (toncenter) ou `{"type":"num","num":"0x157"}` (tonapi).
    static func stackNumber(_ item: StrictJSON, _ path: String) throws -> BigUInt {
        let text: String
        if let pair = item.arrayValue {
            guard pair.count == 2, try pair[0].string(path) == "num" else { throw ReaderError.malformed(field: path) }
            text = try pair[1].string(path)
        } else {
            guard try item.field("type", path).string(path + ".type") == "num" else { throw ReaderError.malformed(field: path) }
            text = try item.field("num", path).string(path + ".num")
        }
        guard text.hasPrefix("0x"), text.count <= 66, let value = BigUInt(hex: text) else { throw ReaderError.malformed(field: path) }
        return value
    }

    static func toncenterCell(_ item: StrictJSON, _ path: String) throws -> TONCell {
        guard let pair = item.arrayValue, pair.count == 2, ["cell", "slice"].contains(try pair[0].string(path)),
              let bytes = Data(base64Encoded: try pair[1].field("bytes", path).string(path + ".bytes"))
        else { throw ReaderError.malformed(field: path) }
        do { return try TONBOC.parseRoot([UInt8](bytes)) } catch { throw ReaderError.malformed(field: path) }
    }

    static func tonapiCell(_ item: StrictJSON, _ path: String) throws -> TONCell {
        guard ["cell", "slice"].contains(try item.field("type", path).string(path + ".type")),
              let bytes = Hex.decode(try item.field(try item.field("type", path).string(path), path).string(path))
        else { throw ReaderError.malformed(field: path) }
        do { return try TONBOC.parseRoot(bytes) } catch { throw ReaderError.malformed(field: path) }
    }

    static func address(fromCell cell: TONCell, _ path: String) throws -> TONAddress {
        var slice = cell.beginParse()
        guard let address = try? slice.loadAddress() else { throw ReaderError.malformed(field: path) }
        return address
    }

    static func parseSeqno(toncenter result: StrictJSON) throws -> UInt32 {
        let stack = try toncenterStack(result, method: "seqno")
        guard stack.count == 1, let value = try stackNumber(stack[0], "seqno.stack").uint64, let seqno = UInt32(exactly: value) else {
            throw ReaderError.malformed(field: "seqno.stack")
        }
        return seqno
    }

    static func parseSeqno(tonapi json: StrictJSON) throws -> UInt32 {
        let stack = try tonapiStack(json, method: "seqno")
        guard stack.count == 1, let value = try stackNumber(stack[0], "seqno.stack").uint64, let seqno = UInt32(exactly: value) else {
            throw ReaderError.malformed(field: "seqno.stack")
        }
        return seqno
    }

    static func parseEstimateFee(_ result: StrictJSON) throws -> BigUInt {
        let fees = try result.field("source_fees", "estimateFee")
        let path = "estimateFee.source_fees"
        return try ["in_fwd_fee", "storage_fee", "gas_fee", "fwd_fee"].reduce(BigUInt()) { sum, key in
            sum + (try fees.field(key, path).integer(path + "." + key))
        }
    }

    struct JettonWalletData: Sendable, Equatable {
        let balance: BigUInt
        let owner: TONAddress
        let master: TONAddress
    }

    /// `get_wallet_data` (TEP-74): saldo, dono, mestre, codigo. Codigo de saida diferente
    /// de zero devolve `nil` (carteira que talvez nao exista).
    static func parseJettonWalletData(toncenter result: StrictJSON) throws -> JettonWalletData? {
        guard try result.field("exit_code", "get_wallet_data").int64("get_wallet_data.exit_code") == 0 else { return nil }
        let stack = try result.field("stack", "get_wallet_data").array("get_wallet_data.stack")
        guard stack.count >= 3 else { throw ReaderError.malformed(field: "get_wallet_data.stack") }
        return JettonWalletData(
            balance: try stackNumber(stack[0], "get_wallet_data.balance"),
            owner: try address(fromCell: try toncenterCell(stack[1], "get_wallet_data.owner"), "get_wallet_data.owner"),
            master: try address(fromCell: try toncenterCell(stack[2], "get_wallet_data.master"), "get_wallet_data.master")
        )
    }

    /// tonapi `blockchain/accounts/{a}/methods/get_wallet_data`: a mesma pilha, com
    /// `success` falso ou codigo de saida diferente de zero devolvendo `nil`.
    static func parseJettonWalletData(tonapi json: StrictJSON) throws -> JettonWalletData? {
        let path = "get_wallet_data"
        guard try json.field("success", path).bool(path + ".success"),
              try json.field("exit_code", path).int64(path + ".exit_code") == 0
        else { return nil }
        let stack = try json.field("stack", path).array(path + ".stack")
        guard stack.count >= 3 else { throw ReaderError.malformed(field: path + ".stack") }
        return JettonWalletData(
            balance: try stackNumber(stack[0], path + ".balance"),
            owner: try address(fromCell: try tonapiCell(stack[1], path + ".owner"), path + ".owner"),
            master: try address(fromCell: try tonapiCell(stack[2], path + ".master"), path + ".master")
        )
    }

    /// A transacao da tonapi para uma mensagem: sucesso e fase de computacao e de acao
    /// sem erro, e nao abortada.
    static func parseTonapiTransaction(_ json: StrictJSON) throws -> TransactionStatus {
        let path = "message.transaction"
        let aborted = try json.field("aborted", path).bool(path + ".aborted")
        let success = try json.field("success", path).bool(path + ".success")
        let compute = try json.optionalField("compute_phase")?.optionalField("success")?.bool(path + ".compute_phase.success") ?? false
        let action = try json.optionalField("action_phase")?.optionalField("success")?.bool(path + ".action_phase.success") ?? true
        guard !aborted, success, compute, action else { return .failed(reason: "aborted") }
        return .confirmed(block: nil, confirmations: nil)
    }

    static func parseToncenterTransactions(_ json: StrictJSON) throws -> TransactionStatus? {
        let list = try json.field("transactions", "transactionsByMessage").array("transactionsByMessage.transactions")
        guard let tx = list.first else { return nil }
        let path = "transactionsByMessage.transactions[0].description"
        let description = try tx.field("description", "transactionsByMessage.transactions[0]")
        let aborted = try description.field("aborted", path).bool(path + ".aborted")
        let compute = try description.optionalField("compute_ph")?.optionalField("success")?.bool(path + ".compute_ph.success") ?? false
        let action = try description.optionalField("action")?.optionalField("success")?.bool(path + ".action.success") ?? true
        guard !aborted, compute, action else { return .failed(reason: "aborted") }
        return .confirmed(block: nil, confirmations: nil)
    }

    static func sameAddress(_ json: StrictJSON?, _ address: TONAddress) -> Bool {
        guard let text = try? json?.field("address", "account").string("account.address"),
              case .success(let parsed) = TONAddress.parse(text)
        else { return false }
        return parsed.address == address
    }

    static func rawAddress(_ json: StrictJSON?) -> String? {
        guard let text = try? json?.field("address", "account").string("account.address"),
              case .success(let parsed) = TONAddress.parse(text)
        else { return nil }
        return parsed.address.raw
    }

    /// tonapi `/accounts/{a}/events`.
    static func parseEvents(_ json: StrictJSON, owner: TONAddress) throws -> ActivityPage {
        let native = Asset.native(.ton)
        let usdt = TokenRegistry.find(chainID: "ton", contract: TONJetton.usdtMaster.friendly(bounceable: true))
        var items: [ActivityItem] = []
        var suspicious = SuspiciousSummary()
        for (offset, event) in try json.field("events", "events").array("events.events").enumerated() {
            let path = "events[\(offset)]"
            let eventID = try event.field("event_id", path).string(path + ".event_id")
            let date = Date(timeIntervalSince1970: TimeInterval(try event.field("timestamp", path).uint64(path + ".timestamp")))
            let inProgress = try event.field("in_progress", path).bool(path + ".in_progress")
            let flagged = try event.optionalField("is_scam")?.bool(path + ".is_scam") ?? false
            let extra = try event.field("extra", path).int64(path + ".extra")
            let explorer = Chain.ton.explorerURL(tx: eventID)
            let actions = try event.field("actions", path).array(path + ".actions")

            var ownerInitiated = false
            var pending: [(index: Int, direction: ActivityItem.Direction, asset: Asset, amount: BigUInt, counterparty: String?, status: ActivityItem.Status)] = []
            for (index, action) in actions.enumerated() {
                let actionPath = path + ".actions[\(index)]"
                let type = try action.field("type", actionPath).string(actionPath + ".type")
                let ok = try action.field("status", actionPath).string(actionPath + ".status") == "ok"
                let status: ActivityItem.Status = inProgress ? .pending : (ok ? .confirmed : .failed)
                switch type {
                case "TonTransfer":
                    let body = try action.field("TonTransfer", actionPath)
                    let outgoing = sameAddress(body.optionalField("sender"), owner)
                    let incoming = sameAddress(body.optionalField("recipient"), owner)
                    let amount = try body.field("amount", actionPath + ".TonTransfer").integer(actionPath + ".TonTransfer.amount")
                    if outgoing { ownerInitiated = true }
                    if incoming, !outgoing, let suspicion = ActivityRules.judgeIncoming(asset: native, amount: amount, flaggedByProvider: flagged) {
                        ActivityRules.count(suspicion, in: &suspicious)
                        continue
                    }
                    guard outgoing || incoming else { continue }
                    pending.append((index, outgoing && incoming ? .other : (outgoing ? .sent : .received), native, amount,
                                    rawAddress(outgoing ? body.optionalField("recipient") : body.optionalField("sender")), status))
                case "JettonTransfer":
                    let body = try action.field("JettonTransfer", actionPath)
                    let outgoing = sameAddress(body.optionalField("sender"), owner)
                    let incoming = sameAddress(body.optionalField("recipient"), owner)
                    let master = rawAddress(body.optionalField("jetton"))
                    // So o mestre compilado conta; nome e simbolo da resposta sao ignorados.
                    let asset = master == TONJetton.usdtMaster.raw ? usdt : nil
                    let amount = try body.field("amount", actionPath + ".JettonTransfer").decimalString(actionPath + ".JettonTransfer.amount")
                    if outgoing { ownerInitiated = true }
                    if incoming, !outgoing, let suspicion = ActivityRules.judgeIncoming(asset: asset, amount: amount, flaggedByProvider: flagged) {
                        ActivityRules.count(suspicion, in: &suspicious)
                        continue
                    }
                    guard outgoing || incoming, let asset else { continue }
                    pending.append((index, outgoing && incoming ? .other : (outgoing ? .sent : .received), asset, amount,
                                    rawAddress(outgoing ? body.optionalField("recipient") : body.optionalField("sender")), status))
                case "SmartContractExec":
                    let body = try action.field("SmartContractExec", actionPath)
                    if sameAddress(body.optionalField("executor"), owner) {
                        ownerInitiated = true
                        pending.append((index, .other, native, 0, rawAddress(body.optionalField("contract")), status))
                    }
                default:
                    continue
                }
            }
            // Taxa: `extra` negativo e o que a conta pagou alem das acoes, quando foi ela
            // que iniciou.
            let fee: BigUInt? = ownerInitiated && extra < 0 ? BigUInt(UInt64(-extra)) : nil
            let outs = pending.filter { $0.direction == .sent }
            let ins = pending.filter { $0.direction == .received }
            if ownerInitiated, let out = outs.first, let into = ins.first, out.asset != into.asset {
                items.append(ActivityItem(
                    id: "ton:\(eventID):swap", chainID: "ton", direction: .swap, asset: out.asset, amount: out.amount,
                    receivedAsset: into.asset, receivedAmount: into.amount, counterparty: nil, date: date, status: out.status,
                    fee: fee, hash: eventID, explorerURL: explorer
                ))
                continue
            }
            for entry in pending {
                items.append(ActivityItem(
                    id: "ton:\(eventID):\(entry.index)", chainID: "ton", direction: entry.direction, asset: entry.asset,
                    amount: entry.amount, counterparty: entry.counterparty, date: date, status: entry.status,
                    fee: entry.direction == .received ? nil : fee, hash: eventID, explorerURL: explorer
                ))
            }
        }
        return ActivityRules.page(chainID: "ton", items: items, suspicious: suspicious)
    }
}
