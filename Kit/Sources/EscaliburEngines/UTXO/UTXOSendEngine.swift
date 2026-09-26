import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Enviar Bitcoin, Litecoin e Dogecoin.
///
/// Junta o `UTXOReader` (descoberta por gap limit, moedas provadas pelo txid da
/// transacao anterior, taxa de pelo menos duas fontes) e o `UTXOPlanner` (selecao de
/// moedas, troco amarrado a xpub, tetos de taxa). O motor so escolhe o nivel de taxa e
/// o indice do troco; quem decide o que pode ser assinado e o planejador.
///
/// A xpub nunca sai do aparelho: a descoberta deriva os enderecos aqui e pergunta por
/// eles um a um. Nada e assinado aqui.
struct UTXOSendEngine: SendEngine {
    let chain: Chain
    let reader: UTXOReader

    /// Por plano, o uso de enderecos que ele deixa para tras (troco e o que a varredura
    /// achou), ate o app chamar `usage(after:current:)` depois de transmitir.
    static let planUsage = ShortLivedMemory<UUID, UTXOUsage>(lifetime: 30 * 60)



    init(chain: Chain, reader: UTXOReader) {
        self.chain = chain
        self.reader = reader
    }

    init?(chain: Chain) {
        guard chain.family == .utxo, let reader = try? UTXOReader(chain: chain) else { return nil }
        self.init(chain: chain, reader: reader)
    }

    // MARK: Destino

    /// Nas redes UTXO nao ha conta para consultar: todo endereco valido recebe, e nao
    /// existe tag. So confere o formato.
    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo {
        try requireChain(chain)
        if case .failure(let problem) = Address.validate(address, for: chain) {
            throw SendEngineError.message(UTXOEngineSupport.destinationText(problem, chain: chain))
        }
        return DestinationInfo(exists: true)
    }

    // MARK: Maximo

    /// O "enviar tudo" que o planejador montaria agora para este destino, com o nivel de
    /// taxa escolhido: o que as moedas gastaveis pagam, menos a taxa.
    func spendable(_ request: SendRequest) async throws -> Spendable {
        try check(request)
        do {
            let account = try UTXOEngineSupport.account(request.account, chain: chain)
            let discovery = try await discover(account, usage: request.utxoUsage)
            let state = try await reader.spendState(discovery)
            let rate = UTXOEngineSupport.rate(request.feeLevel, in: state.fees)
            let intent = UTXOSendIntent(destination: try destination(request), amount: .all, feeRate: rate, change: nil)
            let plan: SigningPlan
            do {
                plan = try UTXOPlanner.planSend(walletID: request.walletID, chain: chain, intent: intent, network: state.network)
            } catch UTXOPlanError.noSpendableCoins, UTXOPlanError.amountBelowDust {
                return Spendable(amount: BigUInt(), feeNote: UTXOEngineSupport.text(.noSpendableCoins, chain: chain))
            }
            guard let summary = UTXOEngineSupport.summary(plan) else { throw UTXOPlanError.internalCheckFailed }
            let fee = EngineFormat.amount(summary.fee, decimals: chain.nativeDecimals, symbol: chain.nativeSymbol)
            let left = state.network.coins.count - summary.inputCount
            return Spendable(
                amount: summary.amount,
                reserveNote: left > 0
                    ? "\(left) \(left == 1 ? "moeda pequena ou ainda sem confirmação fica" : "moedas pequenas ou ainda sem confirmação ficam") fora do máximo."
                    : nil,
                feeNote: "Já descontada a taxa da rede de \(fee), a \(UTXOEngineSupport.rateText(rate, chain: chain))."
            )
        } catch {
            throw UTXOEngineSupport.translate(error, chain: chain)
        }
    }

    // MARK: Plano

    func plan(_ request: SendRequest) async throws -> SigningPlan {
        try check(request)
        do {
            let account = try UTXOEngineSupport.account(request.account, chain: chain)
            let discovery = try await discover(account, usage: request.utxoUsage)
            return try await plan(request, account: account, discovery: discovery)
        } catch {
            throw UTXOEngineSupport.translate(error, chain: chain)
        }
    }

    /// O plano a partir de uma varredura ja feita: moedas, taxa e altura lidas agora, o
    /// troco no proximo indice livre da cadeia interna.
    func plan(_ request: SendRequest, account: UTXOAccount, discovery: UTXODiscovery) async throws -> SigningPlan {
        let state = try await reader.spendState(discovery)
        let rate = UTXOEngineSupport.rate(request.feeLevel, in: state.fees)
        var changeIndex: UInt32?
        var change: UTXOChangeAddress?
        if !request.sendAll {
            let index = try UTXOEngineSupport.changeIndex(usage: request.utxoUsage, discovery: discovery)
            change = try UTXOEngineSupport.changeAddress(account, index: index)
            changeIndex = index
        }
        let intent = UTXOSendIntent(
            destination: try destination(request),
            amount: request.sendAll ? .all : .exact(request.amount),
            feeRate: rate, change: change, knownAddresses: request.knownAddresses
        )
        let plan = try UTXOPlanner.planSend(walletID: request.walletID, chain: chain, intent: intent, network: state.network)

        var usage = UTXOEngineSupport.discoveredUsage(discovery)
        if let changeIndex, UTXOEngineSupport.summary(plan)?.change != nil {
            usage.changeUsed = max(usage.changeUsed, Int(changeIndex) + 1)
        }
        Self.planUsage.remember(usage, for: plan.id)
        return plan
    }

    /// Depois de transmitir: o troco usado e o que a varredura achou passam a contar
    /// como usados. Nunca volta atras, e nil quando nada muda.
    func usage(after plan: SigningPlan, current: UTXOUsage?) -> UTXOUsage? {
        guard plan.chain == chain, let floor = Self.planUsage.recall(plan.id) else { return nil }
        let base = current ?? UTXOUsage()
        let next = UTXOEngineSupport.merged(base, floor)
        return next == base ? nil : next
    }

    // MARK: Transmissao

    /// Transmite os mesmos bytes em todos os provedores e devolve o txid calculado aqui.
    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String {
        try requireChain(chain)
        guard signed.count == 1, let transaction = signed.first else {
            throw SendEngineError.message(NetworkFailureText.inconsistent)
        }
        let txid = try UTXOEngineSupport.localTxid(transaction, chain: chain)
        UTXODiscoveryCache.forgetAll()
        do {
            let receipt = try await reader.broadcast(transaction)
            guard receipt.txid == txid else { throw ChainReaderError.signedTransactionInconsistent }
        } catch {
            throw UTXOEngineSupport.translate(error, chain: chain)
        }
        return txid
    }

    /// Confirmada so quando dois provedores dizem confirmada, no mesmo bloco. Sem
    /// resposta, ou com respostas que nao fecham, continua pendente.
    func status(_ id: String, chain: Chain) async -> TransferStatus {
        guard chain == self.chain, let answer = try? await reader.status(txid: id) else { return .pending }
        return ChainTransferStatus.transfer(answer, finalLedger: false)
    }

    // MARK: Apoio

    private func discover(_ account: UTXOAccount, usage: UTXOUsage?) async throws -> UTXODiscovery {
        try await UTXODiscoveryCache.discover(account, usage: usage, reader: reader)
    }

    private func destination(_ request: SendRequest) throws -> Address.Destination {
        switch Address.validate(request.destination, for: chain) {
        case .success(let destination): return destination
        case .failure(let problem): throw SendEngineError.message(UTXOEngineSupport.destinationText(problem, chain: chain))
        }
    }

    private func requireChain(_ chain: Chain) throws {
        guard chain == self.chain else { throw SendEngineError.message(NetworkFailureText.wrongAccount) }
    }

    /// O pedido e desta rede, da moeda nativa e sem tag: nas redes UTXO nao existe tag,
    /// e uma tag digitada nao iria para lugar nenhum.
    private func check(_ request: SendRequest) throws {
        try requireChain(request.chain)
        guard request.asset.chainID == chain.id, request.asset.kind == .native else {
            throw SendEngineError.message("Nesta rede a carteira envia só \(chain.nativeSymbol).")
        }
        if let tag = request.tag, !tag.isEmpty {
            throw SendEngineError.message("A rede \(chain.name) não usa tag nem memo. Tire a tag para enviar.")
        }
    }
}
