import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Envio da moeda nativa e dos tokens da lista curada nas redes EVM.
///
/// O caminho de um envio:
///
/// 1. O pedido e conferido: rede do motor, conta derivada desta rede (endereco igual ao
///    da chave), ativo da lista curada, destino EVM valido (EIP-55 quando tem caixa
///    mista) e sem tag.
/// 2. O estado vem do `EVMReader`: nonce pending de dois provedores, baseFee e gorjetas
///    de dois, estimativa da chamada exata, codigo do destino e saldos com dois
///    provedores concordando no mesmo bloco. Cada provedor tem o `eth_chainId` conferido
///    contra o compilado antes da primeira resposta contar.
/// 3. O `EVMPlanner` monta e valida (tetos de taxa, saldo, destino bloqueado).
/// 4. Transferencia de token, ou qualquer envio para destino com codigo: a transacao
///    exata do plano roda com `eth_call` em dois provedores. Se um reverte ou os dois
///    divergem, o plano nao sai (docs/seguranca.md 4.9).
/// 5. O plano sai com `review.recipient`, que o app confere contra o que o dono digitou.
///
/// Nada aqui assina. A transmissao manda os bytes que o app devolve, e o id e o keccak
/// deles, calculado aqui.
public struct EVMSendEngine: SendEngine {
    public let chain: Chain
    let reader: EVMReader
    /// O preco dos ativos, so para o aviso de taxa alta no envio de token (a taxa e paga
    /// no nativo, e o valor esta no token). Sem ele, sem aviso.
    let prices: (any TradePriceOracle)?

    /// `nil` fora das sete redes EVM compiladas.
    public init?(chain: Chain) {
        self.init(chain: chain, reader: .shared, prices: MarketPriceOracle.shared)
    }

    init?(chain: Chain, reader: EVMReader, prices: (any TradePriceOracle)? = nil) {
        guard EVMEngineSupport.isSupported(chain) else { return nil }
        self.chain = chain
        self.reader = reader
        self.prices = prices
    }

    // MARK: Destino

    public func destination(_ address: String, chain: Chain) async throws -> DestinationInfo {
        do {
            guard chain.id == self.chain.id else { throw EVMEngineFailure.wrongChain }
            let recipient = try EVMAddress(address)
            // A mesma guarda do plano, antes do valor: router, contrato de token e o
            // endereco zero sao recusados ja aqui.
            do {
                _ = try EVMCallGuard.inspect(
                    EVMCallProposal(transactionType: 2, to: recipient, value: 1, data: []), policy: EVMEngineSupport.sendPolicy(chain)
                )
            } catch let refusal as EVMCallRefusal {
                throw EVMPlanError.refused(refusal)
            }
            let isContract = try await reader.hasCode(chain: chain, address: recipient)
            return DestinationInfo(
                exists: true, requiresTag: false, isContract: isContract,
                note: isContract ? "Este endereço é um contrato, não uma carteira comum. Confira se ele aceita \(chain.nativeSymbol) e tokens." : nil
            )
        } catch {
            throw EVMEngineMessages.userFacing(error, .destination, chain: self.chain)
        }
    }

    // MARK: Disponivel

    /// Nativo: o saldo menos a taxa maxima de um envio para este destino. Token: o saldo
    /// do token, desde que o saldo nativo cubra a taxa maxima da transferencia; se nao
    /// cobre, zero, com a nota dizendo por que.
    public func spendable(_ request: SendRequest) async throws -> Spendable {
        do {
            let context = try EVMSendContext(request, chain: chain)
            let speed = EVMEngineSupport.speed(request.feeLevel)
            switch context.asset {
            case .native:
                // O gas de uma transferencia nao depende do valor; o plano recalcula com o
                // valor exato.
                let state = try await reader.networkState(
                    chain: chain, account: context.account.address, intent: .native(to: context.recipient, amount: 0)
                )
                let amount = try EVMPlanner.maxNativeSendAmount(chain: chain, state: state, speed: speed)
                return Spendable(amount: amount, feeNote: "A taxa máxima da rede já está descontada.")
            case .token(let token):
                let tokenState = try await reader.tokenState(token: token, owner: context.account.address)
                guard !tokenState.balance.isZero else { return Spendable(amount: 0) }
                let state = try await reader.networkState(
                    chain: chain, account: context.account.address, intent: .token(token, to: context.recipient, amount: tokenState.balance)
                )
                do {
                    _ = try EVMPlanner.planTokenSend(
                        walletID: request.walletID, account: context.account, token: token, to: context.recipient,
                        amount: tokenState.balance, state: state, tokenState: tokenState, speed: speed,
                        policy: EVMEngineSupport.sendPolicy(chain)
                    )
                } catch EVMPlanError.insufficientNativeBalance {
                    return Spendable(
                        amount: 0,
                        feeNote: "A taxa da rede é paga em \(chain.nativeSymbol), e o saldo de \(chain.nativeSymbol) não cobre a taxa agora."
                    )
                }
                return Spendable(amount: tokenState.balance, feeNote: "A taxa da rede é paga à parte, em \(chain.nativeSymbol).")
            }
        } catch {
            throw EVMEngineMessages.userFacing(error, .spendable, chain: chain)
        }
    }

    // MARK: Plano

    public func plan(_ request: SendRequest) async throws -> SigningPlan {
        do {
            return try await makePlan(request)
        } catch {
            throw EVMEngineMessages.userFacing(error, .sendPlan, chain: chain)
        }
    }

    func makePlan(_ request: SendRequest) async throws -> SigningPlan {
        let context = try EVMSendContext(request, chain: chain)
        let speed = EVMEngineSupport.speed(request.feeLevel)
        let policy = EVMEngineSupport.sendPolicy(chain)
        let owner = context.account.address
        let plan: SigningPlan
        let simulate: Bool
        var isTokenTransfer = false

        switch context.asset {
        case .native:
            // O nonce: duas fontes, e a diferenca entre elas so passa com a fila local.
            let state = try await reader.networkState(
                chain: chain, account: owner, intent: .native(to: context.recipient, amount: request.amount)
            ).applying(request.nonceQueue)
            // "Enviar tudo" e recalculado com o estado deste plano: o disponivel que a tela
            // mostrou pode ter sido calculado com outra baseFee.
            let amount = request.sendAll ? try EVMPlanner.maxNativeSendAmount(chain: chain, state: state, speed: speed) : request.amount
            if request.sendAll, amount.isZero {
                // A taxa maxima ja passa do saldo: nao ha o que enviar.
                throw EVMPlanError.insufficientNativeBalance(needed: 0, available: state.nativeBalance)
            }
            plan = try EVMPlanner.planNativeSend(
                walletID: request.walletID, account: context.account, chain: chain, to: context.recipient, amount: amount,
                state: state, speed: speed, policy: policy
            )
            simulate = state.destinationHasCode
        case .token(let token):
            var policy = policy
            if context.isCustom {
                // Moeda custom: as casas salvas tem de ser as da rede agora, em dois
                // provedores; e o proprio contrato nunca e destino.
                let onChain = try await reader.tokenDecimals(chain: chain, contract: token.contract)
                guard onChain == Int(token.decimals) else { throw EVMEngineFailure.customDecimalsChanged }
                policy.blockedRecipients.insert(token.contract)
            }
            let tokenState = try await reader.tokenState(token: token, owner: owner)
            let amount = request.sendAll ? tokenState.balance : request.amount
            let state = try await reader.networkState(chain: chain, account: owner, intent: .token(token, to: context.recipient, amount: amount))
                .applying(request.nonceQueue)
            plan = try EVMPlanner.planTokenSend(
                walletID: request.walletID, account: context.account, token: token, to: context.recipient, amount: amount,
                state: state, tokenState: tokenState, valueInNativeUnits: await nativeValue(of: amount, asset: request.asset),
                speed: speed, policy: policy
            )
            simulate = true
            isTokenTransfer = true
        }

        guard plan.transactions.count == 1, let transaction = plan.transactions.first as? EVMTransaction else {
            throw EVMEngineFailure.batchMismatch
        }
        if simulate {
            let returned = try await reader.simulateCall(
                chain: chain, from: owner, to: transaction.to, value: transaction.value, data: transaction.data
            )
            if isTokenTransfer, !Self.transferSucceeded(returned) { throw EVMEngineFailure.transferReturnedFalse }
        }
        guard Address.sameRecipient(plan.review.recipient, request.destination, chain: chain) else {
            throw EVMEngineFailure.recipientMismatch
        }
        var warnings = Self.warnings(recipient: context.recipient, known: request.knownAddresses, chain: chain)
        if context.isCustom, case .token(let token) = context.asset { warnings.append(.unverifiedToken(symbol: token.symbol)) }
        return EVMEngineSupport.adding(warnings, to: plan)
    }

    /// O valor do envio de token em wei do nativo, pelo preco de mercado: e o que o aviso
    /// de taxa alta compara com a taxa (auditoria 2, B1). Sem preco, nil e sem aviso.
    func nativeValue(of amount: BigUInt, asset: Asset) async -> BigUInt? {
        guard let prices, let tokenID = asset.coingeckoID else { return nil }
        let nativeID = chain.coingeckoID
        guard let quotes = try? await prices.usdPrices(Array(Set([tokenID, nativeID]))),
              let tokenPrice = quotes[tokenID], let nativePrice = quotes[nativeID]
        else { return nil }
        return TradeMarketReference(
            amountIn: amount, sellDecimals: asset.decimals, buyDecimals: chain.nativeDecimals, sellPriceUSD: tokenPrice, buyPriceUSD: nativePrice
        ).oracleOut
    }

    /// `transfer` sem retorno (USDT e outros tokens antigos) ou com `true` ABI. Qualquer
    /// outra coisa, inclusive `false` sem revert, e recusa.
    static func transferSucceeded(_ returned: [UInt8]) -> Bool {
        if returned.isEmpty { return true }
        return returned.count == 32 && returned.prefix(31).allSatisfy { $0 == 0 } && returned[31] == 1
    }

    /// Os avisos que dependem do historico do dono: primeiro envio para o endereco e
    /// endereco parecido com um para onde ja enviou (docs/seguranca.md 4.10).
    static func warnings(recipient: EVMAddress, known: [String], chain: Chain) -> [PlanReview.Warning] {
        var warnings = [PlanReview.Warning]()
        let text = recipient.checksummed
        if !known.contains(where: { Address.sameRecipient($0, text, chain: chain) }) {
            warnings.append(.firstSendToAddress)
        }
        if let similar = AddressPoisoning.lookalike(text, among: known, chain: chain) {
            warnings.append(.lookalikeAddress(known: similar))
        }
        return warnings
    }

    // MARK: Transmissao

    /// Um envio EVM e uma transacao so. Sai pela rota publica, os mesmos bytes para dois
    /// provedores, e o id devolvido e o keccak dos bytes.
    public func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String {
        do {
            guard chain.id == self.chain.id else { throw EVMEngineFailure.wrongChain }
            guard signed.count == 1, let transaction = signed.first, transaction.chainID == chain.id else {
                throw EVMEngineFailure.batchMismatch
            }
            let local = Hex.encode(Hash.keccak256(transaction.raw), prefix: true)
            let receipt = try await reader.broadcast(transaction, chain: chain, route: .publicMempool)
            guard receipt.id.lowercased() == local else { throw ReaderError.broadcastMismatch }
            return local
        } catch {
            throw EVMEngineMessages.userFacing(error, .broadcast, chain: self.chain)
        }
    }

    public func status(_ id: String, chain: Chain) async -> TransferStatus {
        guard chain.id == self.chain.id, let status = try? await reader.status(of: id, chain: chain) else { return .pending }
        return Self.transferStatus(status)
    }

    /// Confirmado so com dois provedores de acordo no recibo (o leitor exige).
    static func transferStatus(_ status: TransactionStatus) -> TransferStatus {
        switch status {
        case .notFound, .pending:
            return .pending
        case .confirmed(_, let confirmations):
            guard let confirmations, confirmations > 1 else { return .confirmed(detail: "Confirmado na rede.") }
            return .confirmed(detail: "Confirmado na rede, com \(confirmations) confirmações.")
        case .failed:
            return .failed(reason: "A transação entrou na rede, mas o contrato recusou. A taxa da rede foi cobrada.")
        }
    }
}

/// Um pedido de envio ja conferido.
struct EVMSendContext {
    let account: EVMAccount
    let asset: EVMResolvedAsset
    let recipient: EVMAddress
    /// Moeda custom do dono, fora da lista.
    let isCustom: Bool

    init(_ request: SendRequest, chain: Chain) throws {
        guard request.chain.id == chain.id else { throw EVMEngineFailure.wrongChain }
        if let tag = request.tag, !tag.isEmpty { throw EVMEngineFailure.tagNotSupported }
        account = try EVMEngineSupport.account(request.account, chain: chain)
        asset = try EVMEngineSupport.resolve(request.asset, on: chain, allowCustom: true)
        isCustom = request.asset.isCustom && TokenRegistry.listed(chainID: chain.id, kind: request.asset.kind) == nil
        recipient = try EVMAddress(request.destination)
    }
}
