import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation

/// O motor de envio da Tron: TRX e USDT (TRC-20, contrato compilado em `TRC20.usdt`).
///
/// Junta o `TronReader`, que le o estado da rede com o consenso dele, e o
/// `TronPlanner`, que valida e monta. Nada aqui assina, nenhum valor que entra na
/// transacao e lido fora do leitor, e nenhuma resposta de um provedor so substitui o
/// consenso quando ele falha: o erro sobe como frase.
///
/// Taxa: o planejador e a unica formula. O maximo e a nota de custo saem de perguntar a
/// ele (`burn`), para a tela de valor e o plano nunca discordarem.
///
/// `feeLevel` nao se aplica: a Tron cobra preco fixo de banda e energia, lido da rede.
struct TronSendEngine: SendEngine {
    let reader: TronReader
    let deadlines: Deadlines
    /// O relogio. Os testes usam a hora das respostas gravadas, porque o leitor recusa
    /// bloco com mais de uma hora de diferenca do relogio.
    let now: @Sendable () -> Date

    init(reader: TronReader = .shared, deadlines: Deadlines = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.deadlines = deadlines
        self.now = now
    }

    enum Coin: Sendable, Equatable { case trx, usdt }

    // MARK: Destino

    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo {
        do {
            try Self.requireTron(chain)
            let target = try Self.destinationAddress(address)
            let state = try await reader.destinationState(target)
            // Teto da ativacao: a criacao da conta mais a banda da criacao sem stake. O
            // valor exato depende do stake de quem envia e sai no plano.
            let activationFee = state.parameters.createAccountFee + state.parameters.createAccountBandwidthFee
            return DestinationInfo(
                exists: state.activated, requiresTag: false, isContract: state.isContract,
                activationMinimum: state.activated ? nil : activationFee,
                note: TronEngineText.destinationNote(activated: state.activated, isContract: state.isContract, activationFee: activationFee)
            )
        } catch {
            throw TronEngineText.userError(error)
        }
    }

    // MARK: Maximo

    func spendable(_ request: SendRequest) async throws -> Spendable {
        do {
            let order = try Order(request)
            let at = now()
            let base = try await reader.networkState(owner: order.owner.address, intent: .trx(to: order.to, amount: 0), now: at)
            switch order.coin {
            case .trx:
                guard !base.trxBalance.isZero else { return Spendable(amount: 0) }
                let maximum = try Self.maximumTRX(order, state: base, now: at)
                return Spendable(
                    amount: maximum.amount,
                    feeNote: TronEngineText.trxFee(burn: maximum.burn, activates: !base.destinationActivated, memo: order.memo != nil)
                )
            case .usdt:
                switch base.ownerControl.verdict {
                case .compromised: throw SendEngineError.message(TronEngineText.compromised)
                case .notActivated: return Spendable(amount: base.usdtBalance, feeNote: TronEngineText.usdtWithoutAccountNote)
                case .soleOwner: break
                }
                guard !base.usdtBalance.isZero else { return Spendable(amount: 0) }
                // A energia depende do valor e do destino: a estimativa e a do saldo inteiro.
                let state = try await reader.networkState(owner: order.owner.address, intent: .usdt(to: order.to, amount: base.usdtBalance), now: at)
                let amount = min(base.usdtBalance, state.usdtBalance)
                let burn = try Self.burn(order, amount: amount, state: state, now: at)
                return Spendable(amount: amount, feeNote: TronEngineText.usdtFee(burn: burn, trxBalance: state.trxBalance, memo: order.memo != nil))
            }
        } catch {
            throw TronEngineText.userError(error)
        }
    }

    // MARK: Plano

    func plan(_ request: SendRequest) async throws -> SigningPlan {
        do {
            let order = try Order(request)
            // Permissoes antes de tudo: conta com controle dividido ou tomado nao chega a
            // ler saldo nem estimar energia (docs/blockchain.md §2.6).
            let control = try await reader.ownerControl(owner: order.owner.address)
            switch control.verdict {
            case .compromised: throw SendEngineError.message(TronEngineText.compromised)
            case .notActivated:
                throw SendEngineError.message(order.coin == .trx ? TronEngineText.ownerNotActivated : TronEngineText.usdtWithoutAccount)
            case .soleOwner: break
            }
            let at = now()
            let plan: SigningPlan
            switch order.coin {
            case .trx:
                let state = try await reader.networkState(owner: order.owner.address, intent: .trx(to: order.to, amount: request.amount), now: at)
                var amount = request.amount
                if request.sendAll {
                    // Nunca mais do que o dono viu; menos, se o saldo ou a taxa mudaram.
                    amount = min(amount, try Self.maximumTRX(order, state: state, now: at).amount)
                    guard !amount.isZero else { throw SendEngineError.message(TronEngineText.insufficientTRX) }
                }
                plan = try TronPlanner.planSendTRX(
                    walletID: order.walletID, owner: order.owner, to: order.to, amount: amount, memo: order.memo, state: state, now: at
                )
            case .usdt:
                let state = try await reader.networkState(owner: order.owner.address, intent: .usdt(to: order.to, amount: request.amount), now: at)
                plan = try TronPlanner.planSendUSDT(
                    walletID: order.walletID, owner: order.owner, to: order.to, amount: request.amount, memo: order.memo, state: state, now: at
                )
            }
            return try Self.reviewed(plan, for: request)
        } catch {
            throw TronEngineText.userError(error)
        }
    }

    // MARK: Transmissao e acompanhamento

    /// So transmite o que a carteira monta: a Transaction decodificada de volta, na forma
    /// canonica, com o txID igual ao SHA-256 do raw. O id devolvido e esse, calculado
    /// aqui a partir dos bytes.
    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String {
        try Self.requireTron(chain)
        guard signed.count == 1, let transaction = signed.first, transaction.chainID == Chain.tron.id,
              Hex.decode(transaction.encoded) == transaction.raw,
              let decoded = try? TronProtobuf.decodeSignedTransaction(transaction.raw),
              Hex.encode(decoded.raw.txID) == transaction.id.lowercased()
        else { throw SendEngineError.message(TronEngineText.notOurTransaction) }
        let id = Hex.encode(decoded.raw.txID)
        let receipt: BroadcastReceipt
        do {
            receipt = try await reader.broadcast(transaction)
        } catch {
            throw TronEngineText.broadcastError(error)
        }
        guard receipt.id == id else { throw SendEngineError.message(TronEngineText.answerMismatch) }
        // A expiracao gravada na propria transacao, no relogio da rede.
        await deadlines.record(id, expiresAt: Date(timeIntervalSince1970: TimeInterval(decoded.raw.expiration) / 1000))
        return id
    }

    /// Resultado no no solidificado de dois provedores. Enquanto nao ha resultado final,
    /// ou a leitura falha, pendente: a tela continua perguntando.
    func status(_ id: String, chain: Chain) async -> TransferStatus {
        guard chain.id == Chain.tron.id else { return .pending }
        let deadline = await deadlines.deadline(for: id)
        guard let status = try? await reader.status(of: id, expiresAt: deadline, now: now()) else { return .pending }
        switch status {
        case .notFound, .pending: return .pending
        case .confirmed: return .confirmed(detail: TronEngineText.confirmed)
        case .failed(let reason): return .failed(reason: TronEngineText.failure(reason))
        }
    }

    // MARK: O pedido conferido

    /// O pedido conferido antes de qualquer leitura: rede, conta, ativo e destino.
    struct Order {
        let walletID: UUID
        let owner: TronOwner
        let coin: Coin
        /// O destino como o dono digitou, ja validado (base58 da Tron nao tem outra grafia).
        let to: String
        let memo: String?

        init(_ request: SendRequest) throws {
            try TronSendEngine.requireTron(request.chain)
            walletID = request.walletID
            owner = try TronSendEngine.owner(request.account)
            coin = try TronSendEngine.coin(request.asset)
            to = try TronSendEngine.destinationAddress(request.destination).base58
            memo = request.tag.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    static func requireTron(_ chain: Chain) throws {
        guard chain.id == Chain.tron.id else { throw SendEngineError.unsupported(chain) }
    }

    /// A chave publica guardada tem de dar o endereco guardado: senao o plano sairia em
    /// nome de uma conta e a assinatura de outra.
    static func owner(_ account: DerivedAccount) throws -> TronOwner {
        guard account.chainID == Chain.tron.id,
              let owner = try? TronOwner(path: account.path, publicKey: account.publicKey),
              owner.address.base58 == account.address
        else { throw SendEngineError.message(TronEngineText.keyMismatch) }
        return owner
    }

    /// TRX, ou o USDT do contrato compilado. Qualquer outro TRC-20 ou TRC-10 fica fora.
    static func coin(_ asset: Asset) throws -> Coin {
        guard asset.chainID == Chain.tron.id else { throw SendEngineError.message(TronEngineText.unsupportedAsset) }
        switch asset.kind {
        case .native: return .trx
        case .token(let contract) where contract == TRC20.usdt.contract.base58: return .usdt
        case .token, .issued: throw SendEngineError.message(TronEngineText.unsupportedAsset)
        }
    }

    static func destinationAddress(_ text: String) throws -> TronAddress {
        switch Address.validate(text, for: .tron) {
        case .failure(let problem):
            throw SendEngineError.message(TronEngineText.address(problem))
        case .success(let destination):
            guard let address = TronAddress(base58: destination.address) else {
                throw SendEngineError.message(TronEngineText.address(.malformed))
            }
            return address
        }
    }

    // MARK: Taxa pelo planejador

    /// O que o planejador queimaria neste envio, em sun, perguntado a ele mesmo com o
    /// saldo de TRX zerado: a recusa diz quanto seria preciso (TRX: valor mais queima;
    /// USDT: so a queima). Se ele aceita com saldo zero, nada e queimado. Qualquer outra
    /// recusa (permissoes, destino, memo) sobe como e.
    static func burn(_ order: Order, amount: BigUInt, state: TronNetworkState, now: Date) throws -> BigUInt {
        let broke = TronNetworkState(
            block: state.block, trxBalance: 0, usdtBalance: state.usdtBalance, resources: state.resources,
            parameters: state.parameters, destinationActivated: state.destinationActivated,
            destinationIsContract: state.destinationIsContract, usdtEnergyEstimate: state.usdtEnergyEstimate,
            destinationHoldsUSDT: state.destinationHoldsUSDT, ownerControl: state.ownerControl
        )
        do {
            switch order.coin {
            case .trx:
                _ = try TronPlanner.planSendTRX(
                    walletID: order.walletID, owner: order.owner, to: order.to, amount: amount, memo: order.memo, state: broke, now: now
                )
            case .usdt:
                _ = try TronPlanner.planSendUSDT(
                    walletID: order.walletID, owner: order.owner, to: order.to, amount: amount, memo: order.memo, state: broke, now: now
                )
            }
            return 0
        } catch TronPlanError.insufficientTRX(let needed, _) {
            return needed.subtractingReportingUnderflow(amount) ?? needed
        } catch TronPlanError.noTRXForFees(let needed) {
            return needed
        }
    }

    /// O maior envio de TRX que o planejador aceita: o saldo menos o que ele queimaria
    /// mandando o saldo inteiro. Com valor menor a queima so diminui (o campo `amount`
    /// do protobuf encolhe e a banda cabe mais facil na cota), entao o resultado passa.
    static func maximumTRX(_ order: Order, state: TronNetworkState, now: Date) throws -> (amount: BigUInt, burn: BigUInt) {
        guard !state.trxBalance.isZero else { return (0, 0) }
        let burn = try burn(order, amount: state.trxBalance, state: state, now: now)
        return (state.trxBalance.subtractingReportingUnderflow(burn) ?? 0, burn)
    }

    // MARK: Revisao

    /// O plano so sai se o destino e o memo dele forem os pedidos. Acrescenta os avisos
    /// que dependem de onde o dono ja enviou: primeiro envio e endereco parecido com um
    /// conhecido (docs/seguranca.md §4.10). O resto do plano fica como o planejador fez.
    static func reviewed(_ plan: SigningPlan, for request: SendRequest) throws -> SigningPlan {
        let review = plan.review
        let memo = request.tag.flatMap { $0.isEmpty ? nil : $0 }
        guard review.kind == .send, plan.chain.id == Chain.tron.id, plan.walletID == request.walletID,
              Address.sameRecipient(review.recipient, request.destination, chain: .tron), review.recipientTag == memo
        else { throw SendEngineError.message(TronEngineText.planMismatch) }

        var warnings = review.warnings
        let known = request.knownAddresses
        if let lookalike = AddressPoisoning.lookalike(request.destination, among: known + [request.account.address], chain: .tron) {
            warnings.append(.lookalikeAddress(known: lookalike))
        }
        if !known.contains(where: { Address.sameRecipient($0, request.destination, chain: .tron) }) {
            warnings.append(.firstSendToAddress)
        }
        return plan.addingWarnings(warnings)
    }
}

extension TronSendEngine {
    /// A expiracao de cada transacao transmitida nesta execucao do app, para `status`
    /// saber quando "nao encontrada" vira "venceu". So na memoria e so as mais recentes:
    /// depois de reabrir o app, uma transacao sem registro fica pendente ate aparecer,
    /// o que nunca declara falha cedo demais.
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
