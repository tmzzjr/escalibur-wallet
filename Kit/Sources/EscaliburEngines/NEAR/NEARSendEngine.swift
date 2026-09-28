import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// O motor de envio da NEAR: so NEAR, da conta implicita do dono.
///
/// Junta o `NEARReader`, que le o bloco de referencia, as duas contas, a chave de acesso
/// do dono, o preco do gas e as regras do protocolo em dois provedores concordando, e o
/// `NEARPlanner`, que valida e monta. Nada aqui assina.
///
/// `feeLevel` nao se aplica: a NEAR nao tem gorjeta na transacao comum, e a taxa e o gas
/// fixo da transferencia ao preco do bloco.
struct NEARSendEngine: SendEngine {
    let reader: NEARReader
    /// O relogio que data o plano. Troca so nos testes.
    let now: @Sendable () -> Date

    init(reader: NEARReader = .shared, now: @escaping @Sendable () -> Date = { .now }) {
        self.reader = reader
        self.now = now
    }

    // MARK: Destino

    /// Conta com nome tem de existir, lida em dois provedores: sem isso, nada segue. Conta
    /// implicita pode ainda nao existir; o primeiro envio a cria.
    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo {
        try Self.requireNEAR(chain)
        let target = try Self.parsedDestination(address)
        do {
            let state = try await reader.destination(target)
            if target.kind == .named, state == nil { throw SendEngineError.message(NEAREngineText.namedMissing) }
            let contract = state?.hasContract ?? false
            return DestinationInfo(
                exists: state != nil, requiresTag: false, isContract: contract, activationMinimum: nil,
                note: state == nil ? NEAREngineText.newImplicit : (contract ? NEAREngineText.contractDestination : nil)
            )
        } catch {
            throw NEAREngineText.userError(error)
        }
    }

    // MARK: Maximo

    func spendable(_ request: SendRequest) async throws -> Spendable {
        do {
            let order = try Order(request)
            let state = try await chainState(order)
            let cost = NEARTransferCost.transfer(to: order.destination, destinationExists: state.destination != nil, rules: state.rules)
            return Spendable(
                amount: NEARPlanner.maximumSendable(to: order.destination, state: state),
                reserveNote: NEAREngineText.reserveNote(state.sender, rules: state.rules),
                feeNote: NEAREngineText.feeNote(cost)
            )
        } catch {
            throw NEAREngineText.userError(error)
        }
    }

    // MARK: Plano

    func plan(_ request: SendRequest) async throws -> SigningPlan {
        do {
            let order = try Order(request)
            let state = try await chainState(order)
            var amount = request.amount
            if request.sendAll {
                // Nunca mais do que o dono viu; menos, se o saldo ou a taxa mudaram.
                amount = min(amount, NEARPlanner.maximumSendable(to: order.destination, state: state))
                guard !amount.isZero else { throw SendEngineError.message(NEAREngineText.insufficient) }
            }
            let plan = try NEARPlanner.planSend(
                walletID: request.walletID, owner: order.owner, to: request.destination, amount: amount, state: state, now: now()
            )
            return try Self.reviewed(plan, for: request)
        } catch {
            throw NEAREngineText.userError(error)
        }
    }

    /// O estado inteiro no mesmo bloco, em dois provedores. A conta do dono tem de existir
    /// e ter a chave dele com acesso total.
    func chainState(_ order: Order) async throws -> NEARChainState {
        let reading = try await reader.state(owner: order.sender, publicKey: order.owner.publicKey, destination: order.destination)
        guard let sender = reading.sender else { throw SendEngineError.message(NEAREngineText.accountMissing) }
        guard let accessKey = reading.accessKey else { throw SendEngineError.message(NEAREngineText.keyNotOnAccount) }
        return NEARChainState(
            checkpoint: reading.checkpoint, sender: sender, accessKey: accessKey, destination: reading.destination, rules: reading.rules
        )
    }

    // MARK: Transmissao e acompanhamento

    /// So transmite a transacao que `NEARSignedTransaction.parse` aceita, com o id igual
    /// ao hash dos bytes. O id devolvido e o calculado aqui, o mesmo que `status` procura.
    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String {
        try Self.requireNEAR(chain)
        guard signed.count == 1, let transaction = signed.first, (try? NEARSignedTransaction.parse(transaction)) != nil else {
            throw SendEngineError.message(NEAREngineText.notOurTransaction)
        }
        let receipt: BroadcastReceipt
        do {
            receipt = try await reader.broadcast(transaction)
        } catch {
            throw NEAREngineText.broadcastError(error)
        }
        guard receipt.id == transaction.id else { throw SendEngineError.message(NEAREngineText.answerMismatch) }
        return transaction.id
    }

    /// O resultado em dois provedores. Enquanto nao e final, ou a leitura falha,
    /// pendente: a tela continua perguntando.
    func status(_ id: String, chain: Chain) async -> TransferStatus {
        guard chain.id == Chain.near.id, let status = try? await reader.status(of: id) else { return .pending }
        switch status {
        case .notFound, .pending: return .pending
        case .confirmed: return .confirmed(detail: NEAREngineText.confirmed)
        case .failed(let reason): return .failed(reason: NEAREngineText.failure(reason))
        }
    }

    // MARK: O pedido conferido

    /// O pedido conferido antes de qualquer leitura: rede, ativo, a chave contra a conta
    /// guardada e o destino.
    struct Order {
        let owner: NEAROwner
        let sender: NEARAccountID
        let destination: NEARAccountID

        init(_ request: SendRequest) throws {
            try NEARSendEngine.requireNEAR(request.chain)
            guard request.asset.chainID == Chain.near.id, request.asset.kind == .native else {
                throw SendEngineError.message(NEAREngineText.unsupportedAsset)
            }
            guard request.account.chainID == Chain.near.id, let sender = NEARAccountID(implicitPublicKey: request.account.publicKey),
                  sender.text == request.account.address
            else { throw SendEngineError.message(NEAREngineText.keyMismatch) }
            owner = NEAROwner(path: request.account.path, publicKey: request.account.publicKey)
            self.sender = sender
            destination = try NEARSendEngine.parsedDestination(request.destination)
        }
    }

    static func requireNEAR(_ chain: Chain) throws {
        guard chain.id == Chain.near.id else { throw SendEngineError.unsupported(chain) }
    }

    static func parsedDestination(_ text: String) throws -> NEARAccountID {
        switch Address.validate(text, for: .near) {
        case .failure(let problem):
            throw SendEngineError.message(NEAREngineText.address(problem))
        case .success(let destination):
            guard case .success(let account) = NEARAccountID.parse(destination.address) else {
                throw SendEngineError.message(NEAREngineText.address(.malformed))
            }
            return account
        }
    }

    // MARK: Revisao

    /// O plano so sai se o destino dele for o pedido, sem tag. Acrescenta os avisos que
    /// dependem de onde o dono ja enviou: primeiro envio e conta parecida com uma
    /// conhecida (docs/seguranca.md §4.10).
    static func reviewed(_ plan: SigningPlan, for request: SendRequest) throws -> SigningPlan {
        let review = plan.review
        guard review.kind == .send, plan.chain.id == Chain.near.id, plan.walletID == request.walletID,
              Address.sameRecipient(review.recipient, request.destination, chain: .near), review.recipientTag == nil
        else { throw SendEngineError.message(NEAREngineText.planMismatch) }

        var warnings = review.warnings
        let known = request.knownAddresses
        if let lookalike = AddressPoisoning.lookalike(request.destination, among: known + [request.account.address], chain: .near) {
            warnings.append(.lookalikeAddress(known: lookalike))
        }
        if !known.contains(where: { Address.sameRecipient($0, request.destination, chain: .near) }) {
            warnings.append(.firstSendToAddress)
        }
        return plan.addingWarnings(warnings)
    }
}
