import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// O motor de envio da TON: TON e USDT (jetton do mestre compilado em `TONJetton`).
///
/// Junta o `TONReader`, que le o estado com o consenso dele (`seqno`, as contas do dono
/// e do destino e o saldo de USDT em dois provedores concordando), e o `TONPlanner`, que
/// valida e monta. Nada aqui assina, nenhum valor
/// que entra na mensagem e lido fora do leitor, e o destino segue para o planejador
/// exatamente como o dono digitou: a grafia (UQ, EQ ou raw) decide o bounce, pela regra
/// do planejador.
///
/// `feeLevel` nao se aplica: a TON nao tem mercado de taxa; a rede cobra o custo real.
struct TONSendEngine: SendEngine {
    let reader: TONReader
    let deadlines: Deadlines
    /// O relogio. Os testes fixam a hora para a validade e o `query_id` serem os mesmos.
    let now: @Sendable () -> Date

    init(reader: TONReader = .shared, deadlines: Deadlines = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.deadlines = deadlines
        self.now = now
    }

    enum Coin: Sendable, Equatable { case ton, usdt }

    // MARK: Destino

    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo {
        do {
            try Self.requireTON(chain)
            let target = try Self.parsedDestination(address)
            let state = try await reader.destinationState(target.address)
            // Mestre ou carteira jetton do USDT no lugar de uma carteira: os dois
            // planejadores recusam. Qualquer outro codigo pode ser carteira de outra
            // versao, e nao ha como dizer que e contrato.
            let tokenContract = target.address == TONJetton.usdtMaster || TONJetton.isUSDTJettonWallet(codeHash: state.codeHash)
            return DestinationInfo(
                exists: state.status != .uninitialized, requiresTag: false, isContract: tokenContract,
                activationMinimum: nil, note: TONEngineText.destinationNote(status: state.status, tokenContract: tokenContract)
            )
        } catch {
            throw TONEngineText.userError(error)
        }
    }

    // MARK: Maximo

    func spendable(_ request: SendRequest) async throws -> Spendable {
        var coin: Coin?
        do {
            let order = try Order(request)
            coin = order.coin
            let at = now()
            switch order.coin {
            case .ton:
                let state = try await reader.chainState(
                    wallet: order.wallet, intent: .ton(to: request.destination, amount: request.amount, comment: order.comment), now: at
                )
                return Spendable(
                    amount: Self.maximumTON(state),
                    reserveNote: TONEngineText.margin(state.estimatedFee),
                    feeNote: TONEngineText.tonFee(state.estimatedFee, activatesWallet: state.accountStatus == .uninitialized)
                )
            case .usdt:
                let jetton = try await reader.jettonState(owner: order.wallet.address)
                guard !jetton.balance.isZero else { return Spendable(amount: 0) }
                let state = try await reader.chainState(
                    wallet: order.wallet, intent: .usdt(to: request.destination, amount: jetton.balance, comment: order.comment), now: at
                )
                return Spendable(
                    amount: jetton.balance,
                    feeNote: TONEngineText.usdtFee(attached: TONJetton.attachedTON, fee: state.estimatedFee, balance: state.balance)
                )
            }
        } catch {
            throw TONEngineText.userError(error, coin: coin)
        }
    }

    // MARK: Plano

    func plan(_ request: SendRequest) async throws -> SigningPlan {
        var coin: Coin?
        do {
            let order = try Order(request)
            coin = order.coin
            let at = now()
            let plan: SigningPlan
            switch order.coin {
            case .ton:
                let state = try await reader.chainState(
                    wallet: order.wallet, intent: .ton(to: request.destination, amount: request.amount, comment: order.comment), now: at
                )
                var amount = request.amount
                if request.sendAll {
                    // Nunca mais do que o dono viu; menos, se o saldo ou a taxa mudaram.
                    amount = min(amount, Self.maximumTON(state))
                    guard !amount.isZero else { throw SendEngineError.message(TONEngineText.insufficientTON) }
                }
                plan = try TONPlanner.planSendTON(
                    walletID: request.walletID, wallet: order.wallet, path: order.path, to: request.destination,
                    amount: amount, comment: order.comment, state: state, now: at
                )
            case .usdt:
                let jetton = try await reader.jettonState(owner: order.wallet.address)
                let amount = request.sendAll ? min(request.amount, jetton.balance) : request.amount
                let state = try await reader.chainState(
                    wallet: order.wallet, intent: .usdt(to: request.destination, amount: amount, comment: order.comment), now: at
                )
                plan = try TONPlanner.planSendUSDT(
                    walletID: request.walletID, wallet: order.wallet, path: order.path, to: request.destination,
                    amount: amount, comment: order.comment, state: state, jetton: jetton, now: at
                )
            }
            return try Self.reviewed(plan, for: request)
        } catch {
            throw TONEngineText.userError(error, coin: coin)
        }
    }

    // MARK: Transmissao e acompanhamento

    /// So transmite uma mensagem externa (`ext_in_msg_info$10`) cujo hash de celula e o
    /// id que veio com ela. O id devolvido e esse hash, calculado aqui a partir dos
    /// bytes, e e o mesmo que `status` procura.
    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String {
        try Self.requireTON(chain)
        guard signed.count == 1, let message = signed.first, message.chainID == Chain.ton.id,
              let decoded = Data(base64Encoded: message.encoded), [UInt8](decoded) == message.raw,
              let root = try? TONBOC.parseRoot(message.raw), Self.isExternalInbound(root),
              Hex.encode(root.hash) == message.id.lowercased()
        else { throw SendEngineError.message(TONEngineText.notOurTransaction) }
        let id = Hex.encode(root.hash)
        let sentAt = now()
        let receipt: BroadcastReceipt
        do {
            receipt = try await reader.broadcast(message)
        } catch {
            throw TONEngineText.broadcastError(error)
        }
        guard receipt.id == id else { throw SendEngineError.message(TONEngineText.answerMismatch) }
        // O `valid_until` da mensagem e a hora do plano mais a validade, e o plano e
        // anterior a transmissao: este prazo nunca vem antes do verdadeiro.
        await deadlines.record(id, expiresAt: sentAt.addingTimeInterval(TONPlanner.validitySeconds))
        return id
    }

    /// A transacao da carteira que processou a mensagem, nas duas APIs. Enquanto nao ha
    /// resultado final, ou a leitura falha, pendente: a tela continua perguntando.
    func status(_ id: String, chain: Chain) async -> TransferStatus {
        guard chain.id == Chain.ton.id else { return .pending }
        let deadline = await deadlines.deadline(for: id)
        guard let status = try? await reader.status(of: id, expiresAt: deadline, now: now()) else { return .pending }
        switch status {
        case .notFound, .pending: return .pending
        case .confirmed: return .confirmed(detail: TONEngineText.confirmed)
        case .failed(let reason): return .failed(reason: TONEngineText.failure(reason))
        }
    }

    // MARK: O pedido conferido

    /// O pedido conferido antes de qualquer leitura: rede, carteira, ativo e destino.
    struct Order {
        let wallet: TONWallet
        let path: DerivationPath
        let coin: Coin
        let comment: String?

        init(_ request: SendRequest) throws {
            try TONSendEngine.requireTON(request.chain)
            wallet = try TONSendEngine.wallet(of: request.account)
            path = request.account.path
            coin = try TONSendEngine.coin(request.asset)
            _ = try TONSendEngine.parsedDestination(request.destination)
            comment = request.tag.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    static func requireTON(_ chain: Chain) throws {
        guard chain.id == Chain.ton.id else { throw SendEngineError.unsupported(chain) }
    }

    /// A carteira do dono. A mesma chave tem um endereco por versao de contrato, e a
    /// versao certa e a que da o endereco guardado da conta (V4R2 nas carteiras novas,
    /// W5 em algumas importadas). Nenhuma versao dando o endereco: a conta nao confere.
    static func wallet(of account: DerivedAccount) throws -> TONWallet {
        guard account.chainID == Chain.ton.id, case .success(let stored) = TONAddress.parse(account.address) else {
            throw SendEngineError.message(TONEngineText.keyMismatch)
        }
        for version in TONWalletVersion.allCases {
            if let wallet = try? TONWallet(publicKey: account.publicKey, version: version), wallet.address == stored.address {
                return wallet
            }
        }
        throw SendEngineError.message(TONEngineText.keyMismatch)
    }

    /// TON, ou o USDT do mestre compilado. Qualquer outro jetton fica fora.
    static func coin(_ asset: Asset) throws -> Coin {
        guard asset.chainID == Chain.ton.id else { throw SendEngineError.message(TONEngineText.unsupportedAsset) }
        if asset.isCustom, let reason = CustomToken.sendUnavailableReason(.ton) { throw SendEngineError.unavailable(reason) }
        switch asset.kind {
        case .native:
            return .ton
        case .token(let contract):
            guard case .success(let master) = TONAddress.parse(contract), master.address == TONJetton.usdtMaster else {
                throw SendEngineError.message(TONEngineText.unsupportedAsset)
            }
            return .usdt
        case .issued:
            throw SendEngineError.message(TONEngineText.unsupportedAsset)
        }
    }

    static func parsedDestination(_ text: String) throws -> TONAddress.Parsed {
        switch Address.validate(text, for: .ton) {
        case .failure(let problem):
            throw SendEngineError.message(TONEngineText.address(problem))
        case .success(let destination):
            guard case .success(let parsed) = TONAddress.parse(destination.address) else {
                throw SendEngineError.message(TONEngineText.address(.malformed))
            }
            return parsed
        }
    }

    /// Os dois primeiros bits da celula raiz: `ext_in_msg_info$10`.
    static func isExternalInbound(_ root: TONCell) -> Bool {
        var slice = root.beginParse()
        return (try? slice.loadUInt(bits: 2)) == 0b10
    }

    // MARK: Maximo

    /// O saldo menos a taxa estimada e mais uma taxa de folga. O planejador aceita ate
    /// saldo menos taxa, mas a taxa cobrada e a da execucao real: se passar da estimativa
    /// com a conta no limite, a transferencia falha na fase de acao e a taxa e cobrada do
    /// mesmo jeito. Com valor menor a mensagem nao cresce, entao a estimativa vale.
    static func maximumTON(_ state: TONChainState) -> BigUInt {
        state.balance.subtractingReportingUnderflow(state.estimatedFee + state.estimatedFee) ?? 0
    }

    // MARK: Revisao

    /// O plano so sai se o destino e o comentario dele forem os pedidos. Acrescenta os
    /// avisos que dependem de onde o dono ja enviou: primeiro envio e endereco parecido
    /// com um conhecido (docs/seguranca.md §4.10). O resto fica como o planejador fez.
    static func reviewed(_ plan: SigningPlan, for request: SendRequest) throws -> SigningPlan {
        let review = plan.review
        let comment = request.tag.flatMap { $0.isEmpty ? nil : $0 }
        guard review.kind == .send, plan.chain.id == Chain.ton.id, plan.walletID == request.walletID,
              Address.sameRecipient(review.recipient, request.destination, chain: .ton), review.recipientTag == comment
        else { throw SendEngineError.message(TONEngineText.planMismatch) }

        var warnings = review.warnings
        let known = request.knownAddresses
        if let lookalike = AddressPoisoning.lookalike(request.destination, among: known + [request.account.address], chain: .ton) {
            warnings.append(.lookalikeAddress(known: lookalike))
        }
        if !known.contains(where: { Address.sameRecipient($0, request.destination, chain: .ton) }) {
            warnings.append(.firstSendToAddress)
        }
        return plan.addingWarnings(warnings)
    }
}

extension TONSendEngine {
    /// O prazo de cada mensagem transmitida nesta execucao do app, para `status` saber
    /// quando "nao encontrada" vira "venceu". So na memoria e so as mais recentes: depois
    /// de reabrir o app, uma mensagem sem registro fica pendente ate aparecer, o que
    /// nunca declara falha cedo demais.
    actor Deadlines {
        static let shared = Deadlines()
        static let capacity = 64

        private var entries: [(id: String, expiresAt: Date)] = []

        func record(_ id: String, expiresAt: Date) {
            let key = id.lowercased()
            entries.removeAll { $0.id == key }
            entries.append((key, expiresAt))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }

        func deadline(for id: String) -> Date? {
            let key = id.lowercased()
            return entries.last { $0.id == key }?.expiresAt
        }
    }
}
