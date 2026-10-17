import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Ponte entre redes EVM: USDC pelo CCTP V2 da Circle, ETH e USDT pelo Across; e USDT da
/// Ethereum e da Arbitrum para a Tron pela Legacy Mesh da Tether (docs/seguranca.md 4.12).
///
/// - **Cotacao**: a taxa vem da Iris ou da API do Across, sem endereco do dono; o
///   `BridgeValidator` monta a calldata e aplica os tetos compilados.
/// - **Plano**: o estado das duas redes (implementacoes fixadas, dominio e token local no
///   destino, bloqueio, codigo do dono no destino, saldo, allowance, simulacao em duas
///   fontes) pelo `TradeStateReader`; o `BridgePlanner` monta a autorizacao exata e o
///   deposito.
/// - **Envio**: os bytes assinados, conferidos contra o plano, em ordem de nonce. Na
///   Ethereum, pelos relays com protecao de MEV.
/// - **Andamento**: a chegada so conta com a entrega conferida no destino em dois RPCs
///   (`BridgeArrival`, `EVMReader.verifyIncoming`).
public struct BridgeEngine: Sendable {
    let iris: CircleIrisClient
    let across: AcrossClient
    let state: TradeStateReader
    let reader: EVMReader
    let market: MarketService
    let tron: TronReader

    public static let shared = BridgeEngine()

    public init() {
        self.init(iris: CircleIrisClient(), across: AcrossClient(), state: TradeStateReader(), reader: .shared, market: .shared, tron: .shared)
    }

    init(iris: CircleIrisClient, across: AcrossClient, state: TradeStateReader, reader: EVMReader, market: MarketService,
         tron: TronReader = .shared) {
        self.iris = iris
        self.across = across
        self.state = state
        self.reader = reader
        self.market = market
        self.tron = tron
    }

    /// As redes da ponte na v1.
    public static var chains: [Chain] { BridgeAllowlist.chains.map(\.chain) }

    /// Os destinos: as redes de origem e a Tron (so USDT, pela Legacy Mesh da Tether).
    public static var destinations: [Chain] { BridgeAllowlist.destinations.map(\.chain) }

    /// O que a ponte move de `from` para `to`.
    public static func assets(from: Chain, to: Chain) -> [BridgeAsset] {
        guard let source = BridgeAllowlist.chain(from), let destination = BridgeAllowlist.chain(to) else { return [] }
        return BridgeAsset.allCases.filter { $0.available(from: source, to: destination) }
    }

    // MARK: Cotacao

    /// As opcoes da ponte para o pedido: no USDC entre redes com CCTP, a rapida (quando
    /// cabe) e a padrao; no resto (USDC de ou para a BNB, ETH, USDT), o Across. A primeira
    /// e a recomendada.
    public func quotes(_ intent: BridgeIntent, now: Date = .now) async throws -> [ValidatedBridgeQuote] {
        do {
            if BridgeAsset.usesMesh(intent.asset, from: intent.from, to: intent.to) {
                // Tudo do proprio contrato da Tether, em duas fontes; o preco do ETH so diz
                // quanto a taxa de mensagem pesa no valor.
                async let read = state.readMesh(intent: intent)
                async let price = intent.from.nativeETH ? usdPrice(.eth) : nil
                return [try BridgeValidator.mesh(intent, quote: try await read, nativeUSDPrice: await price, now: now)]
            }
            if BridgeAsset.usesCCTP(intent.asset, from: intent.from, to: intent.to), let source = intent.from.cctp, let destination = intent.to.cctp {
                async let fees = iris.fees(sourceDomain: source.domain, destinationDomain: destination.domain)
                async let allowance = try? iris.fastAllowance()
                let (levels, fast) = (try await fees, await allowance)
                var options = [ValidatedBridgeQuote]()
                if let quick = try? BridgeValidator.cctp(intent, route: .cctpFast, fees: levels, fastAllowance: fast, now: now) {
                    options.append(quick)
                }
                options.append(try BridgeValidator.cctp(intent, route: .cctpStandard, fees: levels, fastAllowance: nil, now: now))
                return options
            }
            guard let fromAcross = intent.from.across, let toAcross = intent.to.across else { throw BridgeRefusal.unsupportedRoute }
            let input = intent.asset.contract(on: intent.from) ?? fromAcross.wrappedNative
            let output = intent.asset.contract(on: intent.to) ?? toAcross.wrappedNative
            async let suggested = across.quote(
                inputToken: input, outputToken: output, originChainID: intent.from.chain.evmChainID ?? 0,
                destinationChainID: intent.to.chain.evmChainID ?? 0, amount: intent.amount
            )
            async let price = usdPrice(intent.asset)
            return [try BridgeValidator.across(intent, quote: try await suggested, usdPrice: await price, now: now)]
        } catch {
            throw BridgeEngineMessages.userFacing(error, .quote, chain: intent.from.chain)
        }
    }

    func usdPrice(_ asset: BridgeAsset) async -> TradeDecimal? {
        let id: String
        switch asset {
        case .eth: id = "ethereum"
        case .usdt: id = "tether"
        case .usdc: id = "usd-coin"
        case .wbtc: id = "wrapped-bitcoin"
        }
        guard let price = try? await market.quotes(ids: [id], currency: "usd")[id]?.price, price > 0 else { return nil }
        return TradeDecimal(String(format: "%.6f", price))
    }

    // MARK: Plano

    /// `destination`: a conta da mesma carteira na rede de destino. Tem de ter o mesmo
    /// endereco da origem: a ponte so leva para a propria conta.
    public func plan(
        _ quote: ValidatedBridgeQuote, walletID: UUID, account: DerivedAccount, destination: DerivedAccount,
        nonceQueue: PendingNonceQueue? = nil
    ) async throws -> SigningPlan {
        do {
            let chain = quote.intent.from.chain
            let owner = try EVMEngineSupport.account(account, chain: chain)
            guard owner.address == quote.intent.owner else { throw BridgeRefusal.ownerMismatch }
            if let recipient = quote.intent.tronRecipient {
                // Na Tron, quem recebe e a conta Tron desta carteira, e so com a chave dela no
                // controle: com outra chave nas permissoes, o USDT chegaria e nao sairia.
                guard destination.chainID == Chain.tron.id, TronAddress(base58: destination.address) == recipient else {
                    throw BridgeRefusal.ownerMismatch
                }
                switch try await tron.ownerControl(owner: recipient).verdict {
                case .soleOwner, .notActivated: break
                case .compromised: throw BridgeRefusal.tronAccountNotControlled
                }
            } else {
                let receiver = try EVMEngineSupport.account(destination, chain: quote.intent.to.chain)
                guard receiver.address == quote.intent.owner else { throw BridgeRefusal.ownerMismatch }
            }
            let read = try await state.readBridge(for: quote, localNextNonce: nonceQueue?.nextNonce)
            let applied = read.replacingNetwork(read.network.applying(nonceQueue))
            return try BridgePlanner.planDeposit(walletID: walletID, account: owner, quote: quote, state: applied)
        } catch {
            throw BridgeEngineMessages.userFacing(error, .plan, chain: quote.intent.from.chain)
        }
    }

    // MARK: Envio

    /// Transmite em ordem de nonce e devolve o hash do deposito (o ultimo).
    public func submit(_ signed: [SignedTransaction], plan: SigningPlan) async throws -> String {
        do {
            guard plan.review.kind == .bridge else { throw EVMEngineFailure.batchMismatch }
            let transactions = plan.transactions.compactMap { $0 as? EVMTransaction }
            guard transactions.count == plan.transactions.count else { throw EVMEngineFailure.batchMismatch }
            let ordered = try EVMEngineSupport.pairs(signed, transactions)
            let route: EVMBroadcastRoute = plan.chain.evmChainID == 1 ? .mevProtected : .publicMempool
            let ids = try await EVMEngineSupport.broadcast(ordered, chain: plan.chain, route: route, reader: reader)
            guard let deposit = ids.last else { throw EVMEngineFailure.batchMismatch }
            return deposit
        } catch {
            throw BridgeEngineMessages.userFacing(error, .submit, chain: plan.chain)
        }
    }

    // MARK: Andamento

    public enum Progress: Sendable, Equatable {
        /// O deposito ainda nao confirmou na origem.
        case depositPending
        /// O deposito reverteu: nada saiu da carteira alem da taxa de rede.
        case depositFailed
        /// Confirmado na origem; a ponte esta trabalhando.
        case inFlight
        /// A entrega da Circle falhou; o USDC queimado so pode ser cunhado para o dono.
        case needsClaim
        /// Chegou, conferido no destino em dois RPCs.
        case arrived(txHash: String, amount: BigUInt)
        /// O Across devolveu o deposito na origem.
        case refunded(txHash: String)
        /// O destino mostrou uma entrega que nao bate com o que foi assinado.
        case mismatch
    }

    public func progress(_ record: BridgeRecord) async throws -> Progress {
        guard let from = record.from, let to = record.to, let owner = record.ownerAddress else { return .mismatch }
        switch try await reader.status(of: record.depositTxHash, chain: from.chain) {
        case .failed: return .depositFailed
        case .notFound, .pending: return .depositPending
        case .confirmed: break
        }

        if record.route == .usdt0 {
            // O `guid` da mensagem sai do recibo do envio na origem (dois RPCs), e a entrega na
            // Tron tem de ter o OFTReceived dele, para a conta Tron, e o Transfer do USDT.
            guard let transfer = record.meshTransfer, let source = from.mesh else { return .mismatch }
            guard let deposit = try await reader.receiptLogs(chain: from.chain, hash: record.depositTxHash) else { return .inFlight }
            guard deposit.success, let guid = BridgeArrival.meshGUID(deposit.logs, transfer: transfer) else { return .mismatch }
            guard let delivery = try await tron.meshDelivery(oft: USDT0Mesh.tronOFT, guid: guid, since: record.createdAt.addingTimeInterval(-600)) else {
                return .inFlight
            }
            guard let amount = BridgeArrival.meshDelivered(delivery.logs, transfer: transfer, guid: guid, sourceEID: source.eid) else {
                return .mismatch
            }
            return .arrived(txHash: delivery.txID, amount: amount)
        }
        if record.route.isCCTP {
            guard let transfer = record.cctpTransfer, let source = from.cctp else { return .mismatch }
            let attested: CCTPAttested
            do {
                attested = try await iris.attested(sourceDomain: source.domain, burnTxHash: record.depositTxHash)
            } catch CircleIrisError.notFound {
                return .inFlight
            }
            guard attested.complete, let message = attested.message else { return .inFlight }
            do {
                try message.check(transfer, sourceMessenger: BridgeAllowlist.tokenMessenger, destinationMessenger: BridgeAllowlist.tokenMessenger)
            } catch {
                return .mismatch
            }
            switch attested.forward {
            case .pending: return .inFlight
            case .failed: return .needsClaim
            case .complete(let hash):
                // A cunhagem e a desta mensagem (nonce e origem), e nao uma antiga de mesmo valor.
                guard let minted = try await reader.receiptLogs(chain: to.chain, hash: hash) else { return .inFlight }
                guard minted.success, BridgeArrival.cctpMinted(minted.logs, message: message, transmitter: BridgeAllowlist.messageTransmitter) else {
                    return .mismatch
                }
                switch try await reader.verifyIncoming(chain: to.chain, hash: hash, owner: owner, contract: to.usdc, amount: message.mintedAmount) {
                case .confirmed: return .arrived(txHash: hash, amount: message.mintedAmount)
                case .notFound: return .inFlight
                case .mismatch, .unverifiable: return .mismatch
                }
            }
        }

        guard let transfer = record.acrossTransfer else { return .mismatch }
        let status = try await across.status(originChainID: from.chain.evmChainID ?? 0, depositTxHash: record.depositTxHash)
        switch status.state {
        case .pending, .expired:
            return .inFlight
        case .refunded:
            // So com o reembolso conferido na origem, em dois RPCs.
            guard let hash = status.refundTxHash, let originSpoke = from.across?.spokePool,
                  let refund = try await reader.receiptLogs(chain: from.chain, hash: hash), refund.success,
                  BridgeArrival.acrossRefunded(refund.logs, transfer: transfer, originSpoke: originSpoke)
            else { return .inFlight }
            return .refunded(txHash: hash)
        case .filled:
            // O deposito do dono, no recibo dele na origem: o `depositId` que a entrega tem
            // de carregar.
            guard let originSpoke = from.across?.spokePool,
                  let deposit = try await reader.receiptLogs(chain: from.chain, hash: record.depositTxHash) else { return .inFlight }
            guard deposit.success, let depositID = BridgeArrival.acrossDepositID(deposit.logs, transfer: transfer, originSpoke: originSpoke) else {
                return .mismatch
            }
            guard let hash = status.fillTxHash, let receipt = try await reader.receiptLogs(chain: to.chain, hash: hash) else { return .inFlight }
            guard receipt.success, let spoke = to.across?.spokePool,
                  BridgeArrival.acrossDelivered(receipt.logs, transfer: transfer, destinationSpoke: spoke, depositID: depositID,
                                                destinationWrappedNative: to.across?.wrappedNative ?? .zero) else {
                return .mismatch
            }
            return .arrived(txHash: hash, amount: transfer.outputAmount)
        }
    }
}

extension BridgeChainState {
    func replacingNetwork(_ network: EVMNetworkState) -> BridgeChainState {
        BridgeChainState(
            network: network, token: token, implementations: implementations, destinationDomain: destinationDomain,
            destinationLocalToken: destinationLocalToken, destinationBlacklisted: destinationBlacklisted,
            ownerHasCodeAtDestination: ownerHasCodeAtDestination, simulations: simulations, approveL1DataFee: approveL1DataFee,
            depositL1DataFee: depositL1DataFee, approveL1Gas: approveL1Gas, depositL1Gas: depositL1Gas
        )
    }
}

/// O texto que a tela mostra quando a ponte recusa ou falha. Toda recusa diz que nada foi
/// assinado.
enum BridgeEngineMessages {
    enum Operation { case quote, plan, submit }

    static func userFacing(_ error: Error, _ operation: Operation, chain: Chain = .ethereum) -> SendEngineError {
        if let ready = error as? SendEngineError { return ready }
        if let refusal = error as? BridgeRefusal, let message = text(for: refusal, chain: chain) { return .message(message) }
        if let message = EVMEngineMessages.specific(error, chain: chain) { return .message(message) }
        switch operation {
        case .quote: return .message(kitText("Não foi possível cotar a ponte agora. Tente de novo em instantes."))
        case .plan: return .message(kitText("Não foi possível preparar a ponte agora. Nada foi assinado."))
        case .submit: return .message(kitText("A transmissão não foi concluída. Confira a Atividade antes de tentar de novo."))
        }
    }

    static func text(for refusal: BridgeRefusal, chain: Chain) -> String? {
        let blocked = kitText("Nada foi assinado.")
        switch refusal {
        case .sameChain: return kitText("Escolha uma rede de destino diferente da origem.")
        case .unsupportedRoute: return kitText("A ponte ainda não leva esta moeda entre estas redes.")
        case .zeroAmount: return kitText("Digite um valor.")
        case .aboveBurnLimit(let limit):
            return kitText("O CCTP da Circle leva até \(EVMEngineText.amount(limit, decimals: 6, symbol: "USDC")) por vez. Faça em partes.")
        case .belowMinimum(let minimum): return kitText("Valor abaixo do mínimo desta rota agora (\(minimum.decimalString) na menor unidade).")
        case .aboveRouteLimit: return kitText("Valor acima do que esta rota do Across aceita agora. Tente um valor menor ou divida em partes.")
        case .fastUnavailable: return kitText("A transferência rápida da Circle está sem limite agora. Use a padrão.")
        case .feeAboveCap: return kitText("A taxa cotada passou do teto da carteira. \(blocked)")
        case .feeTooHigh(let percent): return kitText("A taxa da ponte levaria \(String(format: "%.1f", percent).replacingOccurrences(of: ".", with: NumberStyle.current.decimal))% do valor. Aumente o valor. \(blocked)")
        case .quoteMismatch, .quoteExpired: return kitText("A cotação venceu ou não passou na conferência. Cote de novo. \(blocked)")
        case .ownerMismatch: return kitText("A ponte só leva para a sua própria conta, e o endereço de destino desta carteira é outro. \(blocked)")
        case .missingTokenState: return kitText("Não foi possível ler o saldo agora. \(blocked)")
        case .insufficientTokenBalance: return kitText("Saldo insuficiente para este valor.")
        case .contractHasNoCode: return kitText("O contrato da ponte não respondeu como esperado. \(blocked)")
        case .implementationChanged(let what):
            return kitText("O código do contrato da ponte mudou (\(what)). Por segurança, a ponte fica desligada até a próxima atualização da Escalibur. \(blocked)")
        case .destinationDoesNotMint: return kitText("A rede de destino não confirmou que cunha este USDC. Ponte bloqueada. \(blocked)")
        case .destinationHasCode:
            return kitText("A sua conta na rede de destino tem código instalado (uma delegação ou contrato). Isso pode ser um varredor posto por quem conhece a sua frase. Ponte bloqueada. \(blocked)")
        case .destinationBlacklisted: return kitText("O USDC da rede de destino bloqueou esta conta: a cunhagem falharia. \(blocked)")
        case .simulationUnavailable: return kitText("A simulação de segurança não respondeu em duas fontes agora. \(blocked) Tente de novo em instantes.")
        case .simulationShape, .simulationFailed, .simulationUnexpectedTransfer, .simulationUnexpectedApproval, .simulationSpentWrong,
             .simulationEventMissing:
            return kitText("A simulação mostrou um movimento diferente do que a ponte prometia. Ponte bloqueada. \(blocked)")
        case .recipientMissing: return kitText("A ponte para a Tron leva só para a conta Tron desta carteira, e ela não foi encontrada. \(blocked)")
        case .meshPeerChanged:
            return kitText("O contrato da Tether mudou o caminho para a Tron. Por segurança, a ponte para a Tron fica desligada até a próxima atualização da Escalibur. \(blocked)")
        case .meshNoLiquidity(let available):
            return kitText("A Tether tem só \(EVMEngineText.amount(available, decimals: 6, symbol: "USDT")) disponíveis para a Tron agora. Tente um valor menor ou mais tarde.")
        case .tronAccountNotControlled:
            return kitText("A sua conta na Tron está sob o controle de outra chave: o USDT chegaria lá e não sairia por esta carteira. Ponte bloqueada. \(blocked)")
        case .plan(let error): return EVMEngineMessages.plan(error, chain: chain)
        }
    }
}
