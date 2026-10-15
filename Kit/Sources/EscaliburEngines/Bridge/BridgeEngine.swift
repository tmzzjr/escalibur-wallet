import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Ponte entre redes EVM: USDC pelo CCTP V2 da Circle, ETH e USDT pelo Across
/// (docs/seguranca.md 4.12).
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

    public static let shared = BridgeEngine()

    public init() {
        self.init(iris: CircleIrisClient(), across: AcrossClient(), state: TradeStateReader(), reader: .shared, market: .shared)
    }

    init(iris: CircleIrisClient, across: AcrossClient, state: TradeStateReader, reader: EVMReader, market: MarketService) {
        self.iris = iris
        self.across = across
        self.state = state
        self.reader = reader
        self.market = market
    }

    /// As redes da ponte na v1.
    public static var chains: [Chain] { BridgeAllowlist.chains.map(\.chain) }

    /// O que a ponte move de `from` para `to`.
    public static func assets(from: Chain, to: Chain) -> [BridgeAsset] {
        guard let source = BridgeAllowlist.chain(from), let destination = BridgeAllowlist.chain(to) else { return [] }
        return BridgeAsset.allCases.filter { $0.available(from: source, to: destination) }
    }

    // MARK: Cotacao

    /// As opcoes da ponte para o pedido: no USDC, a rapida (quando cabe) e a padrao; nas
    /// outras moedas, o Across. A primeira e a recomendada.
    public func quotes(_ intent: BridgeIntent, now: Date = .now) async throws -> [ValidatedBridgeQuote] {
        do {
            if intent.asset == .usdc {
                async let fees = iris.fees(sourceDomain: intent.from.cctpDomain, destinationDomain: intent.to.cctpDomain)
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
            let receiver = try EVMEngineSupport.account(destination, chain: quote.intent.to.chain)
            guard owner.address == quote.intent.owner, receiver.address == quote.intent.owner else { throw BridgeRefusal.ownerMismatch }
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

        if record.route.isCCTP {
            guard let transfer = record.cctpTransfer else { return .mismatch }
            let attested: CCTPAttested
            do {
                attested = try await iris.attested(sourceDomain: from.cctpDomain, burnTxHash: record.depositTxHash)
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
            guard let hash = status.refundTxHash else { return .inFlight }
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
                  BridgeArrival.acrossDelivered(receipt.logs, transfer: transfer, destinationSpoke: spoke, depositID: depositID) else {
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
        case .quote: return .message("Não foi possível cotar a ponte agora. Tente de novo em instantes.")
        case .plan: return .message("Não foi possível preparar a ponte agora. Nada foi assinado.")
        case .submit: return .message("A transmissão não foi concluída. Confira a Atividade antes de tentar de novo.")
        }
    }

    static func text(for refusal: BridgeRefusal, chain: Chain) -> String? {
        let blocked = "Nada foi assinado."
        switch refusal {
        case .sameChain: return "Escolha uma rede de destino diferente da origem."
        case .unsupportedRoute: return "A ponte ainda não leva esta moeda entre estas redes."
        case .zeroAmount: return "Digite um valor."
        case .aboveBurnLimit(let limit):
            return "O CCTP da Circle leva até \(EVMEngineText.amount(limit, decimals: 6, symbol: "USDC")) por vez. Faça em partes."
        case .belowMinimum(let minimum): return "Valor abaixo do mínimo desta rota agora (\(minimum.decimalString) na menor unidade)."
        case .aboveRouteLimit: return "Valor acima do que esta rota do Across aceita agora. Tente um valor menor ou divida em partes."
        case .fastUnavailable: return "A transferência rápida da Circle está sem limite agora. Use a padrão."
        case .feeAboveCap: return "A taxa cotada passou do teto da carteira. \(blocked)"
        case .feeTooHigh(let percent): return "A taxa da ponte levaria \(String(format: "%.1f", percent).replacingOccurrences(of: ".", with: ","))% do valor. Aumente o valor. \(blocked)"
        case .quoteMismatch, .quoteExpired: return "A cotação venceu ou não passou na conferência. Cote de novo. \(blocked)"
        case .ownerMismatch: return "A ponte só leva para a sua própria conta, e o endereço de destino desta carteira é outro. \(blocked)"
        case .missingTokenState: return "Não foi possível ler o saldo agora. \(blocked)"
        case .insufficientTokenBalance: return "Saldo insuficiente para este valor."
        case .contractHasNoCode: return "O contrato da ponte não respondeu como esperado. \(blocked)"
        case .implementationChanged(let what):
            return "O código do contrato da ponte mudou (\(what)). Por segurança, a ponte fica desligada até a próxima atualização da Escalibur. \(blocked)"
        case .destinationDoesNotMint: return "A rede de destino não confirmou que cunha este USDC. Ponte bloqueada. \(blocked)"
        case .destinationHasCode:
            return "A sua conta na rede de destino tem código instalado (uma delegação ou contrato). Isso pode ser um varredor posto por quem conhece a sua frase. Ponte bloqueada. \(blocked)"
        case .destinationBlacklisted: return "O USDC da rede de destino bloqueou esta conta: a cunhagem falharia. \(blocked)"
        case .simulationUnavailable: return "A simulação de segurança não respondeu em duas fontes agora. \(blocked) Tente de novo em instantes."
        case .simulationShape, .simulationFailed, .simulationUnexpectedTransfer, .simulationUnexpectedApproval, .simulationSpentWrong,
             .simulationEventMissing:
            return "A simulação mostrou um movimento diferente do que a ponte prometia. Ponte bloqueada. \(blocked)"
        case .plan(let error): return EVMEngineMessages.plan(error, chain: chain)
        }
    }
}
