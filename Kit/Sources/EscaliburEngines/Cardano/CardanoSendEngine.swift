import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// O motor de envio da Cardano: so ADA.
///
/// Junta o `CardanoReader`, que le moedas, parametros de protocolo e ponta da cadeia na
/// Koios e no backend da Yoroi, as duas concordando, e o `CardanoPlanner`, que valida e
/// monta. Na Cardano nao ha simulacao a fazer: a transacao so entra se as entradas
/// fecharem exatamente com as saidas e a taxa, e cada moeda usada e uma que as duas fontes
/// listaram com o mesmo valor. Nada aqui assina.
///
/// `feeLevel` nao se aplica: a taxa e a minima que o protocolo exige para o tamanho.
struct CardanoSendEngine: SendEngine {
    let reader: CardanoReader
    let deadlines: Deadlines
    /// O relogio que confere a ponta lida e data o plano. Troca so nos testes.
    let now: @Sendable () -> Date

    init(reader: CardanoReader = .shared, deadlines: Deadlines = .shared, now: @escaping @Sendable () -> Date = { .now }) {
        self.reader = reader
        self.deadlines = deadlines
        self.now = now
    }

    // MARK: Destino

    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo {
        try Self.requireCardano(chain)
        try Self.checkDestination(address)
        // Na Cardano nao ha conta a ativar nem tag: o endereco de carteira recebe.
        return DestinationInfo(exists: true, requiresTag: false, isContract: false, activationMinimum: nil, note: nil)
    }

    // MARK: Maximo

    func spendable(_ request: SendRequest) async throws -> Spendable {
        do {
            let source = try Self.source(request)
            let state = try await reader.spendState(owner: source.address)
            let maximum = try CardanoPlanner.maximumSendable(source: source, to: request.destination, state: state, now: now())
            let locked = state.utxos.filter { !$0.isPlainADA }.reduce(UInt64(0)) { $0 + $1.lovelace }
            let plain = state.utxos.filter(\.isPlainADA).count
            var notes: [String] = []
            if locked > 0 { notes.append(CardanoEngineText.lockedNote(locked)) }
            if plain > CardanoPlanner.maxInputs { notes.append(CardanoEngineText.tooManyCoinsNote) }
            return Spendable(
                amount: maximum, reserveNote: notes.isEmpty ? nil : notes.joined(separator: " "), feeNote: CardanoEngineText.feeNote
            )
        } catch {
            throw CardanoEngineText.userError(error)
        }
    }

    // MARK: Plano

    func plan(_ request: SendRequest) async throws -> SigningPlan {
        do {
            let source = try Self.source(request)
            let state = try await reader.spendState(owner: source.address)
            var amount: BigUInt? = request.amount
            if request.sendAll {
                let maximum = try CardanoPlanner.maximumSendable(source: source, to: request.destination, state: state, now: now())
                guard !maximum.isZero else { throw SendEngineError.message(CardanoEngineText.insufficient) }
                // Tudo, se couber no que o dono viu; se o saldo cresceu, so o que ele viu.
                if maximum <= request.amount { amount = nil }
            }
            let plan = try CardanoPlanner.planSend(
                walletID: request.walletID, source: source, to: request.destination, amount: amount, state: state, now: now()
            )
            return try Self.reviewed(plan, for: request)
        } catch {
            throw CardanoEngineText.userError(error)
        }
    }

    // MARK: Transmissao e acompanhamento

    /// So transmite a transacao que `CardanoSignedTransaction.parse` aceita e cujo id e o
    /// hash do corpo. O id devolvido e o calculado aqui, o mesmo que `status` procura.
    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String {
        try Self.requireCardano(chain)
        guard signed.count == 1, let transaction = signed.first,
              let parsed = try? CardanoSignedTransaction.parse(transaction.raw), parsed.signaturesVerify,
              Hex.encode(parsed.body.hash) == transaction.id
        else { throw SendEngineError.message(CardanoEngineText.notOurTransaction) }
        let receipt: BroadcastReceipt
        do {
            receipt = try await reader.broadcast(transaction)
        } catch {
            throw CardanoEngineText.broadcastError(error)
        }
        guard receipt.id == transaction.id else { throw SendEngineError.message(CardanoEngineText.answerMismatch) }
        await deadlines.record(transaction.id, validUntilSlot: parsed.body.ttl)
        return transaction.id
    }

    /// A transacao nas duas fontes. Enquanto as duas nao a veem num bloco, ou a leitura
    /// falha, pendente: a tela continua perguntando.
    func status(_ id: String, chain: Chain) async -> TransferStatus {
        guard chain.id == Chain.cardano.id else { return .pending }
        let ttl = await deadlines.validUntil(id)
        guard let status = try? await reader.status(of: id, validUntilSlot: ttl) else { return .pending }
        switch status {
        case .notFound, .pending: return .pending
        case .confirmed(_, let confirmations): return .confirmed(detail: CardanoEngineText.confirmed(confirmations))
        case .failed(let reason): return .failed(reason: CardanoEngineText.failure(reason))
        }
    }

    // MARK: O pedido conferido

    /// A conta e o destino conferidos antes de qualquer leitura. A chave contra o endereco
    /// e conferida pelo planejador.
    static func source(_ request: SendRequest) throws -> CardanoSource {
        try requireCardano(request.chain)
        guard request.asset.chainID == Chain.cardano.id, request.asset.kind == .native else {
            throw SendEngineError.message(CardanoEngineText.unsupportedAsset)
        }
        guard request.account.chainID == Chain.cardano.id else { throw SendEngineError.message(CardanoEngineText.keyMismatch) }
        try checkDestination(request.destination)
        return CardanoSource(path: request.account.path, publicKey: request.account.publicKey, address: request.account.address)
    }

    static func requireCardano(_ chain: Chain) throws {
        guard chain.id == Chain.cardano.id else { throw SendEngineError.unsupported(chain) }
    }

    static func checkDestination(_ text: String) throws {
        if case .failure(let problem) = Address.validate(text, for: .cardano) {
            throw SendEngineError.message(CardanoEngineText.address(problem))
        }
    }

    // MARK: Revisao

    /// O plano so sai se o destino dele for o pedido, sem tag. Acrescenta os avisos que
    /// dependem de onde o dono ja enviou: primeiro envio e endereco parecido com um
    /// conhecido (docs/seguranca.md §4.10).
    static func reviewed(_ plan: SigningPlan, for request: SendRequest) throws -> SigningPlan {
        let review = plan.review
        guard review.kind == .send, plan.chain.id == Chain.cardano.id, plan.walletID == request.walletID,
              Address.sameRecipient(review.recipient, request.destination, chain: .cardano), review.recipientTag == nil
        else { throw SendEngineError.message(CardanoEngineText.planMismatch) }

        var warnings = review.warnings
        let known = request.knownAddresses
        if let lookalike = AddressPoisoning.lookalike(request.destination, among: known + [request.account.address], chain: .cardano) {
            warnings.append(.lookalikeAddress(known: lookalike))
        }
        if !known.contains(where: { Address.sameRecipient($0, request.destination, chain: .cardano) }) {
            warnings.append(.firstSendToAddress)
        }
        return plan.addingWarnings(warnings)
    }
}

extension CardanoSendEngine {
    /// O ultimo slot em que cada transacao transmitida nesta execucao do app ainda pode
    /// entrar, para `status` saber quando "nao encontrada" vira "venceu". So na memoria:
    /// depois de reabrir o app, uma transacao sem registro fica pendente ate aparecer, o
    /// que nunca declara falha cedo demais.
    actor Deadlines {
        static let shared = Deadlines()
        static let capacity = 64

        private var entries: [(id: String, slot: UInt64)] = []

        func record(_ id: String, validUntilSlot slot: UInt64) {
            entries.removeAll { $0.id == id }
            entries.append((id, slot))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }

        func validUntil(_ id: String) -> UInt64? {
            entries.last { $0.id == id }?.slot
        }
    }
}
