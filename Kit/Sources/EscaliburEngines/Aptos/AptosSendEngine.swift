import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// O motor de envio da Aptos: so APT, por `0x1::aptos_account::transfer`.
///
/// Junta o `AptosReader`, que le sequencia, chave de autenticacao, saldo, destino e preco
/// do gas em dois provedores concordando e simula em dois, e o `AptosPlanner`, que valida e
/// monta. O caminho de um plano:
/// 1. estado da conta em dois provedores, na mesma versao do ledger;
/// 2. simulacao, em dois, de um envio de 1 octa ao mesmo destino: o gas maximo sai do
///    maior gas usado das duas, mais 20%;
/// 3. o planejador monta a transacao e a revisao;
/// 4. a transacao exata e simulada de novo em dois provedores, e o planejador confere
///    que as duas simulam os mesmos bytes e movem exatamente o valor da loja de APT do
///    dono para a do destino, mais a taxa.
/// Nada aqui assina.
///
/// `feeLevel` nao se aplica: o preco e o `gas_estimate` da rede, o mesmo nos dois
/// provedores.
struct AptosSendEngine: SendEngine {
    let reader: AptosReader
    let deadlines: Deadlines
    /// O relogio. Os testes fixam a hora perto da hora do ledger gravado.
    let now: @Sendable () -> Date

    init(reader: AptosReader = .shared, deadlines: Deadlines = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader
        self.deadlines = deadlines
        self.now = now
    }

    // MARK: Destino

    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo {
        try Self.requireAptos(chain)
        let destination = try Self.parsedDestination(address)
        guard !destination.isSystem else { throw SendEngineError.message(AptosEngineText.systemAddress) }
        let exists: Bool
        do {
            exists = try await reader.destinationExists(destination)
        } catch {
            throw AptosEngineText.userError(error)
        }
        // Na Aptos nao ha minimo nem tag: qualquer endereco recebe, e o envio cria a conta.
        return DestinationInfo(exists: exists, requiresTag: false, isContract: false, activationMinimum: nil,
                               note: exists ? nil : AptosEngineText.newAccountNote)
    }

    // MARK: Maximo

    func spendable(_ request: SendRequest) async throws -> Spendable {
        do {
            let order = try Order(request)
            let at = now()
            let state = try await reader.accountState(owner: order.sender, destination: order.destination)
            let estimation = try AptosPlanner.estimationTransaction(owner: order.owner, to: request.destination, state: state, now: at)
            let gasUsed = try await reader.estimateGasUsed(estimation, publicKey: order.owner.publicKey)
            let maxGas = try AptosPlanner.maxGas(forGasUsed: gasUsed, price: state.gasUnitPrice)
            return Spendable(
                amount: try AptosPlanner.maximumSendable(state, gasUsed: gasUsed),
                reserveNote: nil,
                feeNote: AptosEngineText.feeNote(maximum: maxGas * state.gasUnitPrice, createsAccount: !state.destinationExists)
            )
        } catch {
            throw AptosEngineText.userError(error)
        }
    }

    // MARK: Plano

    func plan(_ request: SendRequest) async throws -> SigningPlan {
        do {
            let order = try Order(request)
            let at = now()
            let state = try await reader.accountState(owner: order.sender, destination: order.destination)
            let estimation = try AptosPlanner.estimationTransaction(owner: order.owner, to: request.destination, state: state, now: at)
            let gasUsed = try await reader.estimateGasUsed(estimation, publicKey: order.owner.publicKey)
            var amount = request.amount
            if request.sendAll {
                // Nunca mais do que o dono viu; menos, se o saldo ou o gas mudaram.
                amount = min(amount, try AptosPlanner.maximumSendable(state, gasUsed: gasUsed))
                guard !amount.isZero else { throw SendEngineError.message(AptosEngineText.insufficient) }
            }
            let plan = try AptosPlanner.planSend(
                walletID: request.walletID, owner: order.owner, to: request.destination, amount: amount,
                state: state, gasUsed: gasUsed, now: at
            )
            guard let transfer = plan.transactions.first as? AptosTransfer else { throw SendEngineError.message(AptosEngineText.planMismatch) }
            try AptosPlanner.verifySimulation(plan, results: try await reader.simulate(transfer.raw, publicKey: transfer.publicKey))
            return try Self.reviewed(plan, for: request)
        } catch {
            throw AptosEngineText.userError(error)
        }
    }

    // MARK: Transmissao e acompanhamento

    /// So transmite a transacao que `AptosSignedTransaction.parse` aceita. O id devolvido
    /// e o hash calculado aqui, o mesmo que `status` procura.
    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String {
        try Self.requireAptos(chain)
        guard signed.count == 1, let transaction = signed.first,
              let parsed = try? AptosSignedTransaction.parse(transaction)
        else { throw SendEngineError.message(AptosEngineText.notOurTransaction) }
        let id = AptosSignedTransaction.hash(of: parsed.bytes)
        let receipt: BroadcastReceipt
        do {
            receipt = try await reader.broadcast(transaction)
        } catch {
            throw AptosEngineText.broadcastError(error)
        }
        guard receipt.id == id else { throw SendEngineError.message(AptosEngineText.answerMismatch) }
        await deadlines.record(id, expiresAt: parsed.raw.expirationTimestampSecs)
        return id
    }

    /// A transacao nos dois provedores. Enquanto nao ha resultado final nos dois, ou a
    /// leitura falha, pendente: a tela continua perguntando.
    func status(_ id: String, chain: Chain) async -> TransferStatus {
        guard chain.id == Chain.aptos.id else { return .pending }
        let expiresAt = await deadlines.expiresAt(id)
        guard let status = try? await reader.status(of: id, expiresAt: expiresAt) else { return .pending }
        switch status {
        case .notFound, .pending: return .pending
        case .confirmed(let version, _): return .confirmed(detail: AptosEngineText.confirmed(version))
        case .failed(let reason): return .failed(reason: AptosEngineText.failure(reason))
        }
    }

    // MARK: O pedido conferido

    /// O pedido conferido antes de qualquer leitura: rede, ativo, conta e destino.
    struct Order {
        let owner: AptosOwner
        let sender: AptosAddress
        let destination: AptosAddress

        init(_ request: SendRequest) throws {
            try AptosSendEngine.requireAptos(request.chain)
            guard request.asset.chainID == Chain.aptos.id, request.asset.kind == .native else {
                throw SendEngineError.message(AptosEngineText.unsupportedAsset)
            }
            guard request.account.chainID == Chain.aptos.id,
                  let derived = try? AptosAddress(ed25519PublicKey: request.account.publicKey),
                  case .success(let stored) = AptosAddress.parse(request.account.address), stored == derived
            else { throw SendEngineError.message(AptosEngineText.keyMismatch) }
            destination = try AptosSendEngine.parsedDestination(request.destination)
            owner = AptosOwner(path: request.account.path, publicKey: request.account.publicKey)
            sender = derived
        }
    }

    static func requireAptos(_ chain: Chain) throws {
        guard chain.id == Chain.aptos.id else { throw SendEngineError.unsupported(chain) }
    }

    static func parsedDestination(_ text: String) throws -> AptosAddress {
        switch Address.validate(text, for: .aptos) {
        case .failure(let problem):
            throw SendEngineError.message(AptosEngineText.address(problem))
        case .success(let destination):
            guard case .success(let address) = AptosAddress.parse(destination.address) else {
                throw SendEngineError.message(AptosEngineText.address(.malformed))
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
        guard review.kind == .send, plan.chain.id == Chain.aptos.id, plan.walletID == request.walletID,
              Address.sameRecipient(review.recipient, request.destination, chain: .aptos), review.recipientTag == nil
        else { throw SendEngineError.message(AptosEngineText.planMismatch) }

        var warnings = review.warnings
        let known = request.knownAddresses
        if let lookalike = AddressPoisoning.lookalike(request.destination, among: known + [request.account.address], chain: .aptos) {
            warnings.append(.lookalikeAddress(known: lookalike))
        }
        if !known.contains(where: { Address.sameRecipient($0, request.destination, chain: .aptos) }) {
            warnings.append(.firstSendToAddress)
        }
        return plan.addingWarnings(warnings)
    }
}

extension AptosSendEngine {
    /// A validade (segundos Unix, hora do ledger) de cada transacao transmitida nesta
    /// execucao do app, para `status` saber quando "nao encontrada" vira "venceu". So na
    /// memoria: depois de reabrir o app, uma transacao sem registro fica pendente ate
    /// aparecer, o que nunca declara falha cedo demais.
    actor Deadlines {
        static let shared = Deadlines()
        static let capacity = 64

        private var entries: [(id: String, expiresAt: UInt64)] = []

        func record(_ id: String, expiresAt: UInt64) {
            let key = id.lowercased()
            entries.removeAll { $0.id == key }
            entries.append((key, expiresAt))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }

        func expiresAt(_ id: String) -> UInt64? {
            let key = id.lowercased()
            return entries.last { $0.id == key }?.expiresAt
        }
    }
}
