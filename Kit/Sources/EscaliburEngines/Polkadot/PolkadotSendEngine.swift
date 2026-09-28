import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// O motor de envio da Polkadot: so DOT, na Polkadot Asset Hub.
///
/// Junta o `PolkadotReader`, que le o bloco de referencia, o runtime, as duas contas e a
/// taxa da transacao exata em dois provedores concordando, e o `PolkadotPlanner`, que
/// valida e monta. Nada aqui assina.
///
/// `feeLevel` nao se aplica: a transacao sai sem gorjeta, e a taxa e a que o runtime
/// cobra pelo peso e pelo tamanho.
struct PolkadotSendEngine: SendEngine {
    let reader: PolkadotReader
    /// O relogio que data o plano. Troca so nos testes.
    let now: @Sendable () -> Date

    init(reader: PolkadotReader = .shared, now: @escaping @Sendable () -> Date = { .now }) {
        self.reader = reader
        self.now = now
    }

    // MARK: Destino

    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo {
        try Self.requirePolkadot(chain)
        let target = try Self.parsedDestination(address)
        do {
            let reading = try await reader.accountState(owner: target, destination: target)
            let exists = !reading.destination.total.isZero
            return DestinationInfo(
                exists: exists, requiresTag: false, isContract: false,
                activationMinimum: exists ? nil : PolkadotRuntime.existentialDeposit,
                note: exists ? nil : PolkadotEngineText.emptyDestination
            )
        } catch {
            throw PolkadotEngineText.userError(error)
        }
    }

    // MARK: Maximo

    func spendable(_ request: SendRequest) async throws -> Spendable {
        do {
            let order = try Order(request)
            let state = try await chainState(order, amount: 0)
            return Spendable(
                amount: PolkadotPlanner.maximumSendable(state),
                reserveNote: PolkadotEngineText.reserveNote(state.sender),
                feeNote: PolkadotEngineText.feeNote(state.fee)
            )
        } catch {
            throw PolkadotEngineText.userError(error)
        }
    }

    // MARK: Plano

    func plan(_ request: SendRequest) async throws -> SigningPlan {
        do {
            let order = try Order(request)
            let state = try await chainState(order, amount: request.amount)
            var amount = request.amount
            if request.sendAll {
                // Nunca mais do que o dono viu; menos, se o saldo ou a taxa mudaram.
                amount = min(amount, PolkadotPlanner.maximumSendable(state))
                guard !amount.isZero else { throw SendEngineError.message(PolkadotEngineText.insufficient) }
            }
            let plan = try PolkadotPlanner.planSend(
                walletID: request.walletID, owner: order.owner, to: request.destination, amount: amount, state: state, now: now()
            )
            return try Self.reviewed(plan, for: request)
        } catch {
            throw PolkadotEngineText.userError(error)
        }
    }

    /// O estado inteiro no mesmo bloco: contas e runtime em dois provedores, a conferencia
    /// do runtime antes de qualquer coisa ser montada, e a taxa da transacao exata.
    func chainState(_ order: Order, amount: BigUInt) async throws -> PolkadotChainState {
        let reading = try await reader.accountState(owner: order.sender, destination: order.destination)
        try PolkadotPlanner.checkRuntime(reading.runtime)
        let estimation = try PolkadotPlanner.feeEstimationExtrinsic(
            owner: order.owner, to: order.destination.ss58, amount: amount, sender: reading.sender,
            checkpoint: reading.checkpoint, runtime: reading.runtime
        )
        let fee: BigUInt
        do {
            fee = try await reader.fee(for: estimation, at: reading.checkpoint)
        } catch ReaderError.providerError {
            // Os nos responderam, mas nao avaliaram a transacao: o runtime nao a
            // decodifica como a carteira monta.
            throw SendEngineError.message(PolkadotEngineText.notDecoded)
        }
        return PolkadotChainState(
            checkpoint: reading.checkpoint, runtime: reading.runtime, sender: reading.sender, destination: reading.destination, fee: fee
        )
    }

    // MARK: Transmissao e acompanhamento

    /// So transmite a extrinsic que `PolkadotSignedExtrinsic.parse` aceita, com o id
    /// igual ao hash dos bytes. O id devolvido e o calculado aqui, o mesmo que `status`
    /// procura.
    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String {
        try Self.requirePolkadot(chain)
        guard signed.count == 1, let transaction = signed.first, (try? PolkadotSignedExtrinsic.parse(transaction)) != nil else {
            throw SendEngineError.message(PolkadotEngineText.notOurTransaction)
        }
        let id = transaction.id.lowercased()
        let receipt: BroadcastReceipt
        do {
            receipt = try await reader.broadcast(transaction)
        } catch {
            throw PolkadotEngineText.broadcastError(error)
        }
        guard receipt.id == id else { throw SendEngineError.message(PolkadotEngineText.answerMismatch) }
        return id
    }

    /// A transacao nos blocos finalizados. Enquanto nao aparece, ou a leitura falha,
    /// pendente: a tela continua perguntando.
    func status(_ id: String, chain: Chain) async -> TransferStatus {
        guard chain.id == Chain.polkadot.id, let status = try? await reader.status(of: id) else { return .pending }
        switch status {
        case .notFound, .pending: return .pending
        case .confirmed: return .confirmed(detail: PolkadotEngineText.confirmed)
        case .failed(let reason): return .failed(reason: PolkadotEngineText.failure(reason))
        }
    }

    // MARK: O pedido conferido

    /// O pedido conferido antes de qualquer leitura: rede, ativo, a chave contra o
    /// endereco guardado e o destino.
    struct Order {
        let owner: PolkadotOwner
        let sender: PolkadotAddress
        let destination: PolkadotAddress

        init(_ request: SendRequest) throws {
            try PolkadotSendEngine.requirePolkadot(request.chain)
            guard request.asset.chainID == Chain.polkadot.id, request.asset.kind == .native else {
                throw SendEngineError.message(PolkadotEngineText.unsupportedAsset)
            }
            guard request.account.chainID == Chain.polkadot.id, let sender = PolkadotAddress(accountID: request.account.publicKey),
                  sender.ss58 == request.account.address
            else { throw SendEngineError.message(PolkadotEngineText.keyMismatch) }
            owner = PolkadotOwner(path: request.account.path, publicKey: request.account.publicKey)
            self.sender = sender
            destination = try PolkadotSendEngine.parsedDestination(request.destination)
        }
    }

    static func requirePolkadot(_ chain: Chain) throws {
        guard chain.id == Chain.polkadot.id else { throw SendEngineError.unsupported(chain) }
    }

    static func parsedDestination(_ text: String) throws -> PolkadotAddress {
        switch Address.validate(text, for: .polkadot) {
        case .failure(let problem):
            throw SendEngineError.message(PolkadotEngineText.address(problem, text: text))
        case .success(let destination):
            guard case .success(let address) = PolkadotAddress.parse(destination.address) else {
                throw SendEngineError.message(PolkadotEngineText.address(.malformed, text: text))
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
        guard review.kind == .send, plan.chain.id == Chain.polkadot.id, plan.walletID == request.walletID,
              Address.sameRecipient(review.recipient, request.destination, chain: .polkadot), review.recipientTag == nil
        else { throw SendEngineError.message(PolkadotEngineText.planMismatch) }

        var warnings = review.warnings
        let known = request.knownAddresses
        if let lookalike = AddressPoisoning.lookalike(request.destination, among: known + [request.account.address], chain: .polkadot) {
            warnings.append(.lookalikeAddress(known: lookalike))
        }
        if !known.contains(where: { Address.sameRecipient($0, request.destination, chain: .polkadot) }) {
            warnings.append(.firstSendToAddress)
        }
        return plan.addingWarnings(warnings)
    }
}
