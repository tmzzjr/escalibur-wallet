import EscaliburCore
import Foundation

// O plano de ponte: de uma cotacao validada (BridgeValidator) a um `SigningPlan`.
//
// Etapas: approve exato ao TokenMessengerV2 ou ao SpokePool (com `approve(0)` antes no
// USDT da Ethereum), e o deposito. ETH nativo vai sem approve. Antes de montar, o plano
// confere o que depende da cadeia, nas duas pontas (docs/seguranca.md 4.12):
// - a implementacao de cada proxy da rota, na origem e no destino, igual a fixada;
// - CCTP: o destino e o dominio pedido e cunha exatamente o USDC compilado para esta
//   origem (`getLocalToken`), e o USDC do destino nao bloqueou o dono;
// - a conta do dono no destino nao tem codigo (delegacao EIP-7702 ou contrato);
// - saldo, allowance e a simulacao em duas fontes: sai exatamente o valor, so do ativo
//   movido, e o contrato emite o evento de deposito com os campos que o app montou.

/// O estado publico que o plano de ponte precisa, lido pela rede.
public struct BridgeChainState: Sendable {
    /// Origem: nonce, taxa e saldo nativo.
    public let network: EVMNetworkState
    /// O token movido na origem, com a allowance ao spender. `nil` se sai ETH nativo.
    public let token: EVMTokenState?
    /// A implementacao lida de cada proxy de `BridgePlanner.pins`, em duas fontes
    /// concordando, na mesma ordem.
    public let implementations: [EVMAddress]
    /// CCTP: `localDomain()` do MessageTransmitterV2 do destino.
    public let destinationDomain: UInt32?
    /// CCTP: `getLocalToken(dominio da origem, USDC da origem)` no TokenMinterV2 do destino.
    public let destinationLocalToken: EVMAddress?
    /// CCTP: `isBlacklisted(dono)` no USDC do destino.
    public let destinationBlacklisted: Bool?
    /// `eth_getCode(dono)` no destino nao vazio, em duas fontes concordando.
    public let ownerHasCodeAtDestination: Bool
    /// `eth_simulateV1` das chamadas de `BridgePlanner.simulationRequest`, uma por fonte.
    public let simulations: [TradeSimulation]
    public let approveL1DataFee: BigUInt?
    public let depositL1DataFee: BigUInt?
    public let approveL1Gas: UInt64
    public let depositL1Gas: UInt64
    /// Legacy Mesh: o UsdtOFT de origem lido de novo na hora do plano (par na Tron, token,
    /// taxa da Tether, liquidez e o que chega).
    public let mesh: MeshQuote?

    public init(
        network: EVMNetworkState, token: EVMTokenState?, implementations: [EVMAddress], destinationDomain: UInt32?,
        destinationLocalToken: EVMAddress?, destinationBlacklisted: Bool?, ownerHasCodeAtDestination: Bool,
        simulations: [TradeSimulation], approveL1DataFee: BigUInt? = nil, depositL1DataFee: BigUInt? = nil,
        approveL1Gas: UInt64 = 0, depositL1Gas: UInt64 = 0, mesh: MeshQuote? = nil
    ) {
        self.mesh = mesh
        self.network = network
        self.token = token
        self.implementations = implementations
        self.destinationDomain = destinationDomain
        self.destinationLocalToken = destinationLocalToken
        self.destinationBlacklisted = destinationBlacklisted
        self.ownerHasCodeAtDestination = ownerHasCodeAtDestination
        self.simulations = simulations
        self.approveL1DataFee = approveL1DataFee
        self.depositL1DataFee = depositL1DataFee
        self.approveL1Gas = approveL1Gas
        self.depositL1Gas = depositL1Gas
    }
}

/// Um proxy que o plano exige com a implementacao fixada.
public struct BridgePin: Sendable, Equatable {
    public let chain: Chain
    public let proxy: EVMAddress
    public let implementation: EVMAddress
    public let name: String
}

public enum BridgePlanner {
    // MARK: O que ler

    /// Os proxies da rota, na origem e no destino.
    public static func pins(for quote: ValidatedBridgeQuote) -> [BridgePin] {
        let from = quote.intent.from
        let to = quote.intent.to
        guard quote.callMatchesRoute else { return [] }
        // O UsdtOFT nao e proxy: o que se confere nele e o par na Tron e o token, a cada plano
        // (`BridgeChainState.mesh`).
        if case .mesh = quote.call { return [] }
        if case .cctp = quote.call {
            // Rede sem CCTP nao tem o que fixar: lista vazia, e o plano recusa.
            guard let source = from.cctp, let destination = to.cctp else { return [] }
            return [
                BridgePin(chain: from.chain, proxy: BridgeAllowlist.tokenMessenger, implementation: source.messengerImplementation, name: "TokenMessengerV2"),
                BridgePin(chain: from.chain, proxy: BridgeAllowlist.messageTransmitter, implementation: source.transmitterImplementation, name: "MessageTransmitterV2"),
                BridgePin(chain: to.chain, proxy: BridgeAllowlist.tokenMessenger, implementation: destination.messengerImplementation, name: "TokenMessengerV2"),
                BridgePin(chain: to.chain, proxy: BridgeAllowlist.messageTransmitter, implementation: destination.transmitterImplementation, name: "MessageTransmitterV2"),
            ]
        }
        guard let fromAcross = from.across, let toAcross = to.across else { return [] }
        var pins = [
            BridgePin(chain: from.chain, proxy: fromAcross.spokePool, implementation: fromAcross.implementation, name: "SpokePool"),
            BridgePin(chain: to.chain, proxy: toAcross.spokePool, implementation: toAcross.implementation, name: "SpokePool"),
        ]
        // O USDC da BNB e proxy com admin numa chave so: a implementacao fixada, nos dois
        // sentidos (chegando la nao ha simulacao do token).
        if quote.intent.asset == .usdc {
            for side in [from, to] {
                if let implementation = side.usdcImplementation {
                    pins.append(BridgePin(chain: side.chain, proxy: side.usdc, implementation: implementation, name: "USDC da Binance"))
                }
            }
        }
        return pins
    }

    public static let localDomainFunction = try! ABIFunction("localDomain()")
    public static let getLocalTokenFunction = try! ABIFunction("getLocalToken(uint32,bytes32)")
    public static let isBlacklistedFunction = try! ABIFunction("isBlacklisted(address)")

    /// `getLocalToken(dominio da origem, USDC da origem)`, para o TokenMinterV2 do destino.
    public static func localTokenQuery(_ intent: BridgeIntent) -> [UInt8] {
        guard let source = intent.from.cctp else { return [] }
        return (try? getLocalTokenFunction.encodeCall([.uint(BigUInt(source.domain)), .fixedBytes(CCTPMessage.word(intent.from.usdc))])) ?? []
    }

    public static func blacklistQuery(_ owner: EVMAddress) -> [UInt8] {
        (try? isBlacklistedFunction.encodeCall([.address(owner)])) ?? []
    }

    /// Os approves que faltam: nenhum para ETH nativo ou allowance que ja cobre; dois no
    /// USDT da Ethereum com allowance acima de zero.
    public static func approvals(for quote: ValidatedBridgeQuote, currentAllowance: BigUInt?) -> [BigUInt] {
        guard case .token(let token) = quote.intent.sell, quote.spender != nil else { return [] }
        let current = currentAllowance ?? 0
        guard current < quote.intent.amount else { return [] }
        if EVMPlanner.requiresZeroFirstApproval(token), !current.isZero { return [0, quote.intent.amount] }
        return [quote.intent.amount]
    }

    /// As chamadas que a simulacao tem de rodar, na ordem: approves e o deposito.
    public static func simulationRequest(for quote: ValidatedBridgeQuote, currentAllowance: BigUInt?) -> TradeSimulationRequest {
        let owner = quote.intent.owner
        let values = approvals(for: quote, currentAllowance: currentAllowance)
        var calls = [TradeSimulationRequest.Call]()
        if let token = quote.intent.sell.contract, let spender = quote.spender {
            for value in values {
                calls.append(.init(from: owner, to: token, value: 0, data: ERC20.approve(spender: spender, amount: value)))
            }
        }
        calls.append(.init(from: owner, to: quote.to, value: quote.value, data: quote.data))
        return TradeSimulationRequest(calls: calls, approvals: values)
    }

    // MARK: Plano

    public static func planDeposit(
        walletID: UUID, account: EVMAccount, quote: ValidatedBridgeQuote, state: BridgeChainState,
        speed: EVMFeeSpeed = .normal, format: EVMTransactionFormat = .eip1559, now: Date = .now
    ) throws -> SigningPlan {
        let intent = quote.intent
        let chain = intent.from.chain
        guard quote.callMatchesRoute else { throw BridgeRefusal.unsupportedRoute }
        guard account.address == intent.owner else { throw BridgeRefusal.ownerMismatch }
        guard !quote.isExpired(now: now) else { throw BridgeRefusal.quoteExpired }
        guard state.network.chain.id == chain.id else { throw BridgeRefusal.plan(.chainMismatch) }

        // A calldata que vai ser assinada e a que o app monta de novo agora, do pedido.
        try reencode(quote)

        // O codigo atras de cada proxy, nas duas pontas.
        let pins = pins(for: quote)
        // Rota sem contrato fixado nao vira plano (uma lista vazia passaria em branco). A
        // Legacy Mesh nao tem proxy: no lugar, o UsdtOFT lido de novo agora.
        if case .mesh(let transfer) = quote.call {
            try checkMesh(state.mesh, transfer: transfer, intent: intent)
        } else {
            guard !pins.isEmpty else { throw BridgeRefusal.unsupportedRoute }
        }
        guard state.implementations.count == pins.count else { throw BridgeRefusal.implementationChanged("leitura incompleta") }
        for (pin, found) in zip(pins, state.implementations) where found != pin.implementation {
            throw BridgeRefusal.implementationChanged("\(pin.name) na \(pin.chain.name)")
        }

        // O destino.
        if case .cctp = quote.call {
            guard let destination = intent.to.cctp, state.destinationDomain == destination.domain else { throw BridgeRefusal.destinationDoesNotMint }
            guard state.destinationLocalToken == intent.to.usdc else { throw BridgeRefusal.destinationDoesNotMint }
            guard state.destinationBlacklisted == false else { throw BridgeRefusal.destinationBlacklisted }
        }
        guard !state.ownerHasCodeAtDestination else { throw BridgeRefusal.destinationHasCode }

        // Saldo e approves.
        var approvalValues = [BigUInt]()
        if case .token = intent.sell {
            guard let tokenState = state.token, tokenState.contractHasCode, let allowance = tokenState.allowance else {
                throw BridgeRefusal.missingTokenState
            }
            guard tokenState.balance >= intent.amount else {
                throw BridgeRefusal.insufficientTokenBalance(needed: intent.amount, available: tokenState.balance)
            }
            approvalValues = approvals(for: quote, currentAllowance: allowance)
        }

        let request = simulationRequest(for: quote, currentAllowance: state.token?.allowance)
        guard request.approvals == approvalValues else { throw BridgeRefusal.simulationShape }
        let gas = try BridgeSimulationCheck.verify(state.simulations, request: request, quote: quote)

        var transactions = [EVMTransaction]()
        var approveQuote: EVMFeeQuote?
        if case .token(let token) = intent.sell, let spender = quote.spender, !approvalValues.isEmpty, let tokenState = state.token {
            let approveGas = (gas.approvals.max() ?? 0) + state.approveL1Gas
            let approveState = TradePlanner.derivedState(state.network, gas: approveGas, l1: state.approveL1DataFee, hasCode: true)
            let approvePlan: SigningPlan
            do {
                approvePlan = try EVMPlanner.planApprove(
                    walletID: walletID, account: account, token: token, spender: spender, amount: .exact(intent.amount),
                    state: approveState, tokenState: tokenState, policy: EVMCallPolicy(approvedSpenders: [spender]),
                    speed: speed, format: format, now: now
                )
                approveQuote = try EVMFeeCalculator.quote(chain: chain, state: approveState, speed: speed, format: format, plainTransfer: false)
            } catch let error as EVMPlanError {
                throw BridgeRefusal.plan(error)
            }
            let approves = approvePlan.transactions.compactMap { $0 as? EVMTransaction }
            guard approves.count == approvalValues.count else { throw BridgeRefusal.simulationShape }
            transactions += approves
        }

        let depositState = TradePlanner.derivedState(state.network, gas: gas.deposit + state.depositL1Gas, l1: state.depositL1DataFee, hasCode: true)
        let depositQuote: EVMFeeQuote
        let nonce: UInt64
        do {
            depositQuote = try EVMFeeCalculator.quote(chain: chain, state: depositState, speed: speed, format: format, plainTransfer: false)
            nonce = try EVMFeeCalculator.nonce(state.network) + UInt64(transactions.count)
        } catch let error as EVMPlanError {
            throw BridgeRefusal.plan(error)
        }
        let deposit: EVMTransaction
        do {
            deposit = try EVMTransaction(
                chain: chain, account: account, nonce: nonce, fee: depositQuote.fee, gasLimit: depositQuote.gasLimit,
                to: quote.to, value: quote.value, data: quote.data
            )
        } catch {
            throw BridgeRefusal.plan(.gasLimitAboveCap)
        }
        transactions.append(deposit)

        let approveCost = (approveQuote?.maxCost ?? 0) * BigUInt(approvalValues.count)
        let needed = approveCost + depositQuote.maxCost + quote.value
        guard state.network.nativeBalance >= needed else {
            throw BridgeRefusal.plan(.insufficientNativeBalance(needed: needed, available: state.network.nativeBalance))
        }

        let review = BridgeReview.review(
            quote: quote, approvalValues: approvalValues, approveQuote: approveQuote, depositQuote: depositQuote,
            firstNonce: transactions.first?.nonce ?? nonce
        )
        return SigningPlan(walletID: walletID, chain: chain, review: review, transactions: transactions, createdAt: now)
    }

    /// Monta a calldata de novo a partir da transferencia e confere byte a byte, e confere
    /// a transferencia contra o pedido: dono dos dois lados, ativos e redes compilados.
    static func reencode(_ quote: ValidatedBridgeQuote) throws {
        let intent = quote.intent
        switch quote.call {
        case .cctp(let transfer):
            guard quote.route.isCCTP, let source = intent.from.cctp, let destination = intent.to.cctp,
                  quote.to == BridgeAllowlist.tokenMessenger, quote.value.isZero,
                  quote.spender == BridgeAllowlist.tokenMessenger,
                  transfer.owner == intent.owner, transfer.recipient == intent.owner, transfer.amount == intent.amount,
                  transfer.usdc == intent.from.usdc, transfer.sourceDomain == source.domain,
                  transfer.destinationDomain == destination.domain, transfer.sourceDomain != transfer.destinationDomain,
                  transfer.maxFee < transfer.amount,
                  [CCTPCalldata.fastFinality, CCTPCalldata.standardFinality].contains(transfer.finality),
                  try CCTPCalldata.encodeDeposit(transfer) == quote.data
            else { throw BridgeRefusal.quoteMismatch("queima") }
        case .across(let transfer):
            guard let fromAcross = intent.from.across, let toAcross = intent.to.across else { throw BridgeRefusal.unsupportedRoute }
            let input = intent.asset.contract(on: intent.from) ?? fromAcross.wrappedNative
            let output = intent.asset.contract(on: intent.to) ?? toAcross.wrappedNative
            guard quote.route == .across, quote.to == fromAcross.spokePool,
                  transfer.owner == intent.owner, transfer.recipient == intent.owner,
                  transfer.inputToken == input, transfer.outputToken == output, transfer.inputAmount == intent.amount,
                  // Na unidade mais fina: o USDC da BNB tem 18 casas, o da Base 6.
                  BridgeAsset.fits(transfer.outputAmount, outputDecimals: intent.asset.decimals(on: intent.to),
                                   within: transfer.inputAmount, inputDecimals: intent.asset.decimals(on: intent.from)),
                  transfer.originChainID == intent.from.chain.evmChainID, transfer.destinationChainID == intent.to.chain.evmChainID,
                  transfer.exclusiveRelayer == nil, transfer.exclusivityDeadline == 0,
                  transfer.nativeInput == intent.asset.isNativeInput(on: intent.from), quote.value == transfer.value,
                  quote.spender == (intent.asset.isNativeInput(on: intent.from) ? nil : fromAcross.spokePool),
                  try AcrossCalldata.encode(transfer) == quote.data
            else { throw BridgeRefusal.quoteMismatch("depósito") }
        case .mesh(let transfer):
            guard let source = intent.from.mesh, let recipient = intent.tronRecipient, quote.route == .usdt0,
                  quote.to == source.oft, quote.spender == source.oft, quote.value == transfer.nativeFee,
                  transfer.sourceChainID == intent.from.chain.evmChainID, transfer.oft == source.oft,
                  transfer.owner == intent.owner, transfer.recipient == recipient, transfer.amount == intent.amount,
                  !transfer.minimumReceived.isZero, transfer.minimumReceived <= transfer.amount,
                  quote.minimumReceived == transfer.minimumReceived,
                  !transfer.nativeFee.isZero, transfer.nativeFee <= USDT0Mesh.nativeFeeCap,
                  try MeshCalldata.encode(transfer) == quote.data
            else { throw BridgeRefusal.quoteMismatch("envio") }
            // E lida de volta pelo decodificador estrito: a Tron, a conta da carteira, o valor,
            // o minimo, a taxa de mensagem e o troco para o dono, sem opcao nem chamada.
            let read = try MeshCalldata.decode(quote.data, owner: intent.owner)
            guard read.recipient == recipient, read.amount == intent.amount, read.minimum == transfer.minimumReceived,
                  read.nativeFee == transfer.nativeFee
            else { throw BridgeRefusal.quoteMismatch("envio") }
        }
    }

    /// A Legacy Mesh na hora do plano: o contrato ainda entrega pelo UsdtOFT da Tron e puxa o
    /// USDT da lista, a taxa da Tether e a da cotacao (ou menor), e a Tron tem liquidez.
    static func checkMesh(_ mesh: MeshQuote?, transfer: MeshTransfer, intent: BridgeIntent) throws {
        guard let mesh, let source = intent.from.mesh else { throw BridgeRefusal.meshPeerChanged }
        guard mesh.token == source.usdt, mesh.tronPeer == USDT0Mesh.tronPeerWord else { throw BridgeRefusal.meshPeerChanged }
        guard mesh.feeBps <= BigUInt(USDT0Mesh.feeCapBps) else { throw BridgeRefusal.feeAboveCap }
        guard mesh.sent == transfer.amount, mesh.received >= transfer.minimumReceived else { throw BridgeRefusal.quoteMismatch("valor") }
        guard mesh.maxAmount >= transfer.minimumReceived else { throw BridgeRefusal.meshNoLiquidity(available: mesh.maxAmount) }
        guard mesh.lzTokenFee.isZero, mesh.nativeFee <= transfer.nativeFee else { throw BridgeRefusal.quoteMismatch("taxa de mensagem") }
    }
}

// MARK: Simulacao

/// A segunda opiniao sobre o deposito (docs/seguranca.md 4.9 e 4.12): sai do dono
/// exatamente o valor, so do ativo movido; nenhum Approval alem do exato; e o contrato
/// emite o evento de deposito com os campos que o app montou.
enum BridgeSimulationCheck {
    static let depositForBurnTopic = Hash.keccak256(Array(
        "DepositForBurn(address,uint256,address,bytes32,uint32,bytes32,bytes32,uint256,uint32,bytes)".utf8))
    static let depositForBurnData = try! ABIFunction("e(uint256,bytes32,uint32,bytes32,bytes32,uint256,bytes)")
    static let fundsDepositedTopic = Hash.keccak256(Array(
        "FundsDeposited(bytes32,bytes32,uint256,uint256,uint256,uint256,uint32,uint32,uint32,bytes32,bytes32,bytes32,bytes)".utf8))
    static let fundsDepositedData = try! ABIFunction("e(bytes32,bytes32,uint256,uint256,uint32,uint32,uint32,bytes32,bytes32,bytes)")

    static func verify(_ simulations: [TradeSimulation], request: TradeSimulationRequest, quote: ValidatedBridgeQuote) throws
        -> (approvals: [UInt64], deposit: UInt64) {
        guard Set(simulations.map(\.source)).count >= 2 else { throw BridgeRefusal.simulationUnavailable }
        var approvalGas = [UInt64](repeating: .max, count: request.approvals.count)
        var depositGas = UInt64.max
        for simulation in simulations {
            let (approvals, deposit) = try verify(simulation, request: request, quote: quote)
            for index in approvals.indices { approvalGas[index] = min(approvalGas[index], approvals[index]) }
            depositGas = min(depositGas, deposit)
        }
        return (approvalGas, depositGas)
    }

    static func verify(_ simulation: TradeSimulation, request: TradeSimulationRequest, quote: ValidatedBridgeQuote) throws
        -> (approvals: [UInt64], deposit: UInt64) {
        let intent = quote.intent
        let owner = intent.owner
        guard simulation.calls.count == request.approvals.count + 1 else { throw BridgeRefusal.simulationShape }
        for (index, call) in simulation.calls.enumerated() where !call.success { throw BridgeRefusal.simulationFailed(call: index) }

        for (index, expected) in request.approvals.enumerated() {
            for log in simulation.calls[index].logs {
                try refuseApprovalForAll(log, owner: owner)
                if let transfer = TradeSimulationCheck.parseTransfer(log), transfer.from == owner, !transfer.value.isZero {
                    throw BridgeRefusal.simulationUnexpectedTransfer(token: log.address)
                }
                if let approval = TradeSimulationCheck.parseApproval(log), approval.owner == owner {
                    guard log.address == intent.sell.contract, approval.spender == quote.spender, approval.value == expected else {
                        throw BridgeRefusal.simulationUnexpectedApproval(token: log.address, spender: approval.spender)
                    }
                }
            }
        }

        let deposit = simulation.calls[simulation.calls.count - 1]
        let moved = intent.sell.contract ?? TradeSimulationCheck.nativePseudoToken
        var spent = BigUInt()
        var nativeSent = BigUInt()
        var sawEvent = false
        for log in deposit.logs {
            try refuseApprovalForAll(log, owner: owner)
            // Legacy Mesh: a taxa de mensagem sai como `msg.value` do dono para o UsdtOFT, e so
            // ate o valor assinado (a sobra volta pelo EndpointV2).
            if case .mesh = quote.call, log.address == TradeSimulationCheck.nativePseudoToken,
               let transfer = TradeSimulationCheck.parseTransfer(log), transfer.from == owner, transfer.to != owner {
                guard transfer.to == quote.to else { throw BridgeRefusal.simulationUnexpectedTransfer(token: log.address) }
                nativeSent = nativeSent + transfer.value
                continue
            }
            if let approval = TradeSimulationCheck.parseApproval(log), approval.owner == owner {
                // O consumo da allowance pelo contrato da ponte.
                guard log.address == intent.sell.contract, approval.spender == quote.spender, approval.value <= intent.amount else {
                    throw BridgeRefusal.simulationUnexpectedApproval(token: log.address, spender: approval.spender)
                }
            }
            if let transfer = TradeSimulationCheck.parseTransfer(log), transfer.from == owner, transfer.to != owner, !transfer.value.isZero {
                guard log.address == moved else { throw BridgeRefusal.simulationUnexpectedTransfer(token: log.address) }
                spent = spent + transfer.value
            }
            if try matchesDepositEvent(log, quote: quote) { sawEvent = true }
        }
        guard spent == intent.amount else { throw BridgeRefusal.simulationSpentWrong(found: spent, expected: intent.amount) }
        guard nativeSent <= quote.value else { throw BridgeRefusal.simulationSpentWrong(found: nativeSent, expected: quote.value) }
        guard sawEvent else { throw BridgeRefusal.simulationEventMissing }
        return (simulation.calls.prefix(request.approvals.count).map(\.gasUsed), deposit.gasUsed)
    }

    static func refuseApprovalForAll(_ log: TradeSimulatedLog, owner: EVMAddress) throws {
        guard log.topics.count >= 2, log.topics[0] == TradeSimulationCheck.approvalForAllTopic,
              TradeSimulationCheck.topicAddress(log.topics[1]) == owner else { return }
        throw BridgeRefusal.simulationUnexpectedApproval(token: log.address, spender: log.topics.count > 2 ? TradeSimulationCheck.topicAddress(log.topics[2]) ?? .zero : .zero)
    }

    /// O evento de deposito do contrato da ponte, com cada campo igual ao que o app montou.
    /// Evento do mesmo tipo com outro campo e recusa, nao "outro evento".
    static func matchesDepositEvent(_ log: TradeSimulatedLog, quote: ValidatedBridgeQuote) throws -> Bool {
        let owner = quote.intent.owner
        switch quote.call {
        case .cctp(let transfer):
            guard log.address == BridgeAllowlist.tokenMessenger, log.topics.first == depositForBurnTopic else { return false }
            guard log.topics.count == 4,
                  TradeSimulationCheck.topicAddress(log.topics[1]) == transfer.usdc,
                  TradeSimulationCheck.topicAddress(log.topics[2]) == owner,
                  BigUInt(bigEndian: log.topics[3]) == BigUInt(transfer.finality),
                  let fields = try? depositForBurnData.decodeCall(depositForBurnData.selector + log.data), fields.count == 7,
                  fields[0] == .uint(transfer.amount),
                  fields[1] == .fixedBytes(CCTPMessage.word(transfer.recipient)),
                  fields[2] == .uint(BigUInt(transfer.destinationDomain)),
                  fields[3] == .fixedBytes(CCTPMessage.word(BridgeAllowlist.tokenMessenger)),
                  fields[4] == .fixedBytes([UInt8](repeating: 0, count: 32)),
                  fields[5] == .uint(transfer.maxFee),
                  fields[6] == .bytes(CCTPCalldata.forwardHookData)
            else { throw BridgeRefusal.simulationEventMissing }
            return true
        case .across(let transfer):
            guard let spoke = quote.intent.from.across?.spokePool, log.address == spoke, log.topics.first == fundsDepositedTopic else { return false }
            guard log.topics.count == 4,
                  BigUInt(bigEndian: log.topics[1]) == BigUInt(transfer.destinationChainID),
                  log.topics[3] == CCTPMessage.word(owner),
                  let fields = try? fundsDepositedData.decodeCall(fundsDepositedData.selector + log.data), fields.count == 10,
                  fields[0] == .fixedBytes(CCTPMessage.word(transfer.inputToken)),
                  fields[1] == .fixedBytes(CCTPMessage.word(transfer.outputToken)),
                  fields[2] == .uint(transfer.inputAmount),
                  fields[3] == .uint(transfer.outputAmount),
                  fields[4] == .uint(BigUInt(transfer.quoteTimestamp)),
                  fields[5] == .uint(BigUInt(transfer.fillDeadline)),
                  fields[6] == .uint(0),
                  fields[7] == .fixedBytes(CCTPMessage.word(owner)),
                  fields[8] == .fixedBytes([UInt8](repeating: 0, count: 32)),
                  fields[9] == .bytes([])
            else { throw BridgeRefusal.simulationEventMissing }
            return true
        case .mesh(let transfer):
            // OFTSent(guid, dstEid, fromAddress, amountSentLD, amountReceivedLD) do UsdtOFT de
            // origem: para a Tron, do dono, o valor inteiro, chegando pelo menos o minimo.
            guard log.address == transfer.oft, log.topics.first == USDT0Mesh.oftSentTopic else { return false }
            guard log.topics.count == 3, log.topics[2] == CCTPMessage.word(owner), log.data.count == 96,
                  BigUInt(bigEndian: Array(log.data[0..<32])) == BigUInt(USDT0Mesh.tronEID),
                  BigUInt(bigEndian: Array(log.data[32..<64])) == transfer.amount,
                  BigUInt(bigEndian: Array(log.data[64..<96])) >= transfer.minimumReceived,
                  BigUInt(bigEndian: Array(log.data[64..<96])) <= transfer.amount
            else { throw BridgeRefusal.simulationEventMissing }
            return true
        }
    }
}
