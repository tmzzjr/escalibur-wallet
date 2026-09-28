import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// O motor de envio da Sui: so SUI, tirado da moeda de gas.
///
/// Junta o `SuiReader`, que le moedas, preco de referencia e epoca em dois provedores
/// concordando e simula em dois, e o `SuiPlanner`, que valida e monta. O caminho de um
/// plano:
/// 1. estado da conta em dois provedores;
/// 2. simulacao, em dois, de um envio de 1 MIST com as mesmas moedas e o mesmo destino:
///    o orcamento sai do maior custo das duas, mais 20%;
/// 3. o planejador monta a transacao e a revisao;
/// 4. a transacao exata e simulada de novo em dois provedores, e o planejador confere
///    que as duas simulacoes movem exatamente o valor para o destino e o gas do dono.
/// Nada aqui assina.
///
/// `feeLevel` nao se aplica: a Sui cobra o preco de referencia da epoca.
struct SuiSendEngine: SendEngine {
    let reader: SuiReader
    let deadlines: Deadlines

    init(reader: SuiReader = .shared, deadlines: Deadlines = .shared) {
        self.reader = reader
        self.deadlines = deadlines
    }

    // MARK: Destino

    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo {
        try Self.requireSui(chain)
        let destination = try Self.parsedDestination(address)
        guard !destination.isSystem else { throw SendEngineError.message(SuiEngineText.systemAddress) }
        // Na Sui nao ha conta a ativar nem tag: qualquer endereco recebe.
        return DestinationInfo(exists: true, requiresTag: false, isContract: false, activationMinimum: nil, note: nil)
    }

    // MARK: Maximo

    func spendable(_ request: SendRequest) async throws -> Spendable {
        do {
            let order = try Order(request)
            let state = try await reader.accountState(owner: order.sender)
            let estimate = try await reader.estimateGas(try SuiPlanner.estimationTransaction(owner: order.owner, to: request.destination, state: state))
            let budget = try SuiPlanner.budget(for: estimate, price: state.referenceGasPrice)
            return Spendable(
                amount: try SuiPlanner.maximumSendable(state, estimate: estimate),
                reserveNote: state.addressBalance > 0 ? SuiEngineText.addressBalanceNote(state.addressBalance) : nil,
                feeNote: SuiEngineText.feeNote(budget: budget)
            )
        } catch {
            throw SuiEngineText.userError(error)
        }
    }

    // MARK: Plano

    func plan(_ request: SendRequest) async throws -> SigningPlan {
        do {
            let order = try Order(request)
            let state = try await reader.accountState(owner: order.sender)
            let estimate = try await reader.estimateGas(try SuiPlanner.estimationTransaction(owner: order.owner, to: request.destination, state: state))
            var amount = request.amount
            if request.sendAll {
                // Nunca mais do que o dono viu; menos, se o saldo ou o gas mudaram.
                amount = min(amount, try SuiPlanner.maximumSendable(state, estimate: estimate))
                guard !amount.isZero else { throw SendEngineError.message(SuiEngineText.insufficient) }
            }
            let plan = try SuiPlanner.planSend(
                walletID: request.walletID, owner: order.owner, to: request.destination, amount: amount,
                state: state, estimate: estimate
            )
            guard let transfer = plan.transactions.first as? SuiTransfer else { throw SendEngineError.message(SuiEngineText.planMismatch) }
            try SuiPlanner.verifySimulation(plan, results: try await reader.simulate(transfer.data))
            return try Self.reviewed(plan, for: request)
        } catch {
            throw SuiEngineText.userError(error)
        }
    }

    // MARK: Transmissao e acompanhamento

    /// So transmite a transacao que `SuiSignedTransaction.parse` aceita. O id devolvido e
    /// o digesto calculado aqui, o mesmo que `status` procura.
    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String {
        try Self.requireSui(chain)
        guard signed.count == 1, let transaction = signed.first,
              let parsed = try? SuiSignedTransaction.parse(transaction)
        else { throw SendEngineError.message(SuiEngineText.notOurTransaction) }
        let id = parsed.data.digestBase58
        let receipt: BroadcastReceipt
        do {
            receipt = try await reader.broadcast(transaction)
        } catch {
            throw SuiEngineText.broadcastError(error)
        }
        guard receipt.id == id else { throw SendEngineError.message(SuiEngineText.answerMismatch) }
        if case .epoch(let epoch) = parsed.data.expiration { await deadlines.record(id, validUntilEpoch: epoch) }
        return id
    }

    /// A transacao nos dois provedores. Enquanto nao ha resultado final nos dois, ou a
    /// leitura falha, pendente: a tela continua perguntando.
    func status(_ id: String, chain: Chain) async -> TransferStatus {
        guard chain.id == Chain.sui.id else { return .pending }
        let epoch = await deadlines.validUntil(id)
        guard let status = try? await reader.status(of: id, validUntilEpoch: epoch) else { return .pending }
        switch status {
        case .notFound, .pending: return .pending
        case .confirmed(let checkpoint, _): return .confirmed(detail: SuiEngineText.confirmed(checkpoint))
        case .failed(let reason): return .failed(reason: SuiEngineText.failure(reason))
        }
    }

    // MARK: O pedido conferido

    /// O pedido conferido antes de qualquer leitura: rede, ativo, conta e destino.
    struct Order {
        let owner: SuiOwner
        let sender: SuiAddress

        init(_ request: SendRequest) throws {
            try SuiSendEngine.requireSui(request.chain)
            guard request.asset.chainID == Chain.sui.id, request.asset.kind == .native else {
                throw SendEngineError.message(SuiEngineText.unsupportedAsset)
            }
            guard request.account.chainID == Chain.sui.id,
                  let derived = try? SuiAddress(ed25519PublicKey: request.account.publicKey),
                  case .success(let stored) = SuiAddress.parse(request.account.address), stored == derived
            else { throw SendEngineError.message(SuiEngineText.keyMismatch) }
            _ = try SuiSendEngine.parsedDestination(request.destination)
            owner = SuiOwner(path: request.account.path, publicKey: request.account.publicKey)
            sender = derived
        }
    }

    static func requireSui(_ chain: Chain) throws {
        guard chain.id == Chain.sui.id else { throw SendEngineError.unsupported(chain) }
    }

    static func parsedDestination(_ text: String) throws -> SuiAddress {
        switch Address.validate(text, for: .sui) {
        case .failure(let problem):
            throw SendEngineError.message(SuiEngineText.address(problem))
        case .success(let destination):
            guard case .success(let address) = SuiAddress.parse(destination.address) else {
                throw SendEngineError.message(SuiEngineText.address(.malformed))
            }
            return address
        }
    }

    // MARK: Revisao

    /// O plano so sai se o destino dele for o pedido, sem tag. Acrescenta os avisos que
    /// dependem de onde o dono ja enviou: primeiro envio e endereco parecido com um
    /// conhecido (docs/seguranca.md §4.10).
    static func reviewed(_ plan: SigningPlan, for request: SendRequest) throws -> SigningPlan {
        let review = plan.review
        guard review.kind == .send, plan.chain.id == Chain.sui.id, plan.walletID == request.walletID,
              Address.sameRecipient(review.recipient, request.destination, chain: .sui), review.recipientTag == nil
        else { throw SendEngineError.message(SuiEngineText.planMismatch) }

        var warnings = review.warnings
        let known = request.knownAddresses
        if let lookalike = AddressPoisoning.lookalike(request.destination, among: known + [request.account.address], chain: .sui) {
            warnings.append(.lookalikeAddress(known: lookalike))
        }
        if !known.contains(where: { Address.sameRecipient($0, request.destination, chain: .sui) }) {
            warnings.append(.firstSendToAddress)
        }
        return plan.addingWarnings(warnings)
    }
}

extension SuiSendEngine {
    /// A ultima epoca em que cada transacao transmitida nesta execucao do app ainda pode
    /// entrar, para `status` saber quando "nao encontrada" vira "venceu". So na memoria:
    /// depois de reabrir o app, uma transacao sem registro fica pendente ate aparecer, o
    /// que nunca declara falha cedo demais.
    actor Deadlines {
        static let shared = Deadlines()
        static let capacity = 64

        private var entries: [(id: String, epoch: UInt64)] = []

        func record(_ id: String, validUntilEpoch epoch: UInt64) {
            entries.removeAll { $0.id == id }
            entries.append((id, epoch))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }

        func validUntil(_ id: String) -> UInt64? {
            entries.last { $0.id == id }?.epoch
        }
    }
}
