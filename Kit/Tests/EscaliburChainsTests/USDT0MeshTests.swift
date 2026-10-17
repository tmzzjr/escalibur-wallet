import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// USDT para a Tron pela Legacy Mesh da Tether, sem rede: a calldata montada e lida de volta,
/// o validador com os tetos, o plano com estado e simulacao sinteticos, a chegada conferida
/// pelo `guid`, e cada ataque recusado (docs/seguranca.md 4.12).
@Suite("Ponte: USDT para a Tron pela Legacy Mesh da Tether")
struct USDT0MeshTests {
    typealias T = EVMTestSupport
    typealias S = TradeTestSupport

    static let wallet = UUID()
    static let now = Date(timeIntervalSince1970: 1_791_769_979)
    static let owner = S.owner
    /// Uma conta Tron qualquer, como a da carteira.
    static let recipient = TronAddress(account20: [UInt8](hex: "03343ee91f76117d4380b71aac0629a39c3f8a0e")!)!
    static let ethUSD = TradeDecimal("2400")!
    /// A taxa de mensagem vista ao vivo em 17/10/2026: 0,00472945 ETH.
    static let liveNativeFee = BigUInt(4_729_450_000_000_000)

    static func intent(_ amount: BigUInt = 1_000_000_000, from: Chain = .ethereum) throws -> BridgeIntent {
        try BridgeIntent(owner: owner, asset: .usdt, from: from, to: .tron, amount: amount, tronRecipient: recipient)
    }

    static func read(_ intent: BridgeIntent, feeBps: BigUInt = 3, token: EVMAddress? = nil, peer: [UInt8]? = nil,
                     maxAmount: BigUInt = BigUInt(20_311_498_460_000), received: BigUInt? = nil, nativeFee: BigUInt? = nil,
                     lzTokenFee: BigUInt = 0) -> MeshQuote {
        let source = intent.from.mesh!
        let fee = intent.amount * feeBps / BigUInt(10_000)
        return MeshQuote(token: token ?? source.usdt, tronPeer: peer ?? USDT0Mesh.tronPeerWord, feeBps: feeBps, maxAmount: maxAmount,
                         sent: intent.amount, received: received ?? intent.amount - fee, nativeFee: nativeFee ?? liveNativeFee,
                         lzTokenFee: lzTokenFee)
    }

    static func quote(_ intent: BridgeIntent? = nil) throws -> ValidatedBridgeQuote {
        let intent = try intent ?? Self.intent()
        return try BridgeValidator.mesh(intent, quote: read(intent), nativeUSDPrice: ethUSD, now: now)
    }

    static func transfer(_ quote: ValidatedBridgeQuote) -> MeshTransfer {
        guard case .mesh(let transfer) = quote.call else { fatalError("nao e mesh") }
        return transfer
    }

    // MARK: Eventos e simulacao sinteticos

    static func oftSentLog(_ transfer: MeshTransfer, received: BigUInt? = nil, dstEid: UInt32 = USDT0Mesh.tronEID,
                           guid: [UInt8] = guid) -> TradeSimulatedLog {
        TradeSimulatedLog(
            address: transfer.oft, topics: [USDT0Mesh.oftSentTopic, guid, S.topic(transfer.owner)],
            data: S.word(BigUInt(dstEid)) + S.word(transfer.amount) + S.word(received ?? transfer.minimumReceived)
        )
    }

    static let guid = [UInt8](hex: "98a393e6f0e2e9cf0ad5246b4c1f05a3d398afb8242bc23fb170dfaa3c1227b6")!

    /// Uma simulacao honesta: approve exato ao UsdtOFT; no envio, o USDT saindo do dono, a taxa
    /// de mensagem como valor nativo para o UsdtOFT e o OFTSent com os campos montados.
    static func simulation(_ quote: ValidatedBridgeQuote, source: String, allowance: BigUInt = 0, native: (to: EVMAddress, value: BigUInt)? = nil,
                           event: TradeSimulatedLog? = nil, extra: [TradeSimulatedLog] = []) -> TradeSimulation {
        let intent = quote.intent
        let transfer = transfer(quote)
        let request = BridgePlanner.simulationRequest(for: quote, currentAllowance: allowance)
        var calls = request.approvals.map { value in
            TradeSimulatedCall(success: true, gasUsed: 46_000, logs: [S.approvalLog(intent.sell.contract!, owner: owner, spender: quote.spender!, value)])
        }
        let fee = native ?? (quote.to, quote.value)
        calls.append(TradeSimulatedCall(success: true, gasUsed: 210_000, logs: [
            S.transferLog(TradeConstants.eeeeSentinel, from: owner, to: fee.to, fee.value),
            S.transferLog(intent.sell.contract!, from: owner, to: quote.to, intent.amount),
            event ?? oftSentLog(transfer),
        ] + extra))
        return TradeSimulation(source: source, calls: calls)
    }

    static func state(_ quote: ValidatedBridgeQuote, allowance: BigUInt = 0, mesh: MeshQuote?? = nil,
                      simulations: [TradeSimulation]? = nil) -> BridgeChainState {
        let intent = quote.intent
        return BridgeChainState(
            network: S.network(intent.from.chain), token: EVMTokenState(contractHasCode: true, balance: intent.amount, allowance: allowance),
            implementations: [], destinationDomain: nil, destinationLocalToken: nil, destinationBlacklisted: nil,
            ownerHasCodeAtDestination: false,
            simulations: simulations ?? [simulation(quote, source: "a", allowance: allowance), simulation(quote, source: "b", allowance: allowance)],
            mesh: mesh ?? read(intent)
        )
    }

    static func plan(_ quote: ValidatedBridgeQuote, _ state: BridgeChainState) throws -> SigningPlan {
        try BridgePlanner.planDeposit(walletID: wallet, account: try T.account(T.testKey), quote: quote, state: state, now: now)
    }

    // MARK: Pedido e contrato

    @Test("Rotas: USDT so da Ethereum e da Arbitrum para a Tron; nada sai da Tron; a conta Tron so quando o destino e a Tron")
    func routes() throws {
        for chain in BridgeAllowlist.chains {
            let expected = chain.chain.id == "ethereum" || chain.chain.id == "arbitrum"
            #expect(BridgeAsset.usdt.available(from: chain, to: BridgeAllowlist.tron) == expected, "\(chain.chain.id)")
            for asset in [BridgeAsset.usdc, .eth, .wbtc] { #expect(!asset.available(from: chain, to: BridgeAllowlist.tron)) }
        }
        #expect(BridgeAsset.allCases.allSatisfy { !$0.available(from: BridgeAllowlist.tron, to: BridgeAllowlist.ethereum) })
        #expect(!BridgeAllowlist.chains.contains { $0.chain == .tron } && BridgeAllowlist.chain(.tron) == BridgeAllowlist.tron)
        #expect(throws: BridgeRefusal.recipientMissing) {
            try BridgeIntent(owner: Self.owner, asset: .usdt, from: .ethereum, to: .tron, amount: 1_000_000)
        }
        #expect(throws: BridgeRefusal.recipientMissing) {
            try BridgeIntent(owner: Self.owner, asset: .usdt, from: .ethereum, to: .arbitrum, amount: 1_000_000, tronRecipient: Self.recipient)
        }
        for from in [Chain.bnb, .base, .plasma, .unichain] {
            #expect(throws: BridgeRefusal.unsupportedRoute) {
                try BridgeIntent(owner: Self.owner, asset: .usdt, from: from, to: .tron, amount: 1_000_000, tronRecipient: Self.recipient)
            }
        }
        #expect(throws: BridgeRefusal.unsupportedRoute) {
            try BridgeIntent(owner: Self.owner, asset: .usdt, from: .tron, to: .ethereum, amount: 1_000_000)
        }
        // O USDT da Tron e o da lista.
        #expect(BridgeAsset.usdt.asset(on: BridgeAllowlist.tron)?.id == "tron:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t")
    }

    @Test("Seletores, eventos e enderecos conferidos com o que a cadeia mostrou")
    func constants() {
        #expect(Hex.encode(USDT0Mesh.sendFunction.selector) == "c7c7f5b3")
        #expect(Hex.encode(USDT0Mesh.quoteOFTFunction.selector) == "0d35b415")
        #expect(Hex.encode(USDT0Mesh.quoteSendFunction.selector) == "3b6f743b")
        #expect(Hex.encode(USDT0Mesh.oftSentTopic) == "85496b760a4b7f8d66384b9df21b381f5d1b1e79f229a47aaf4c232edc2fe59a")
        // O topico do OFTReceived que a Tron mostrou numa entrega real (17/10/2026).
        #expect(Hex.encode(BridgeArrival.oftReceivedTopic) == "efed6d3500546b29533b128a29e3a94d70788727f0507505ac12eaf2e578fd9c")
        #expect(Hex.encode(USDT0Mesh.tronOFT.account20) == "3a08f76772e200653bb55c2a92998daca62e0e97")
        #expect(Hex.encode(USDT0Mesh.tronUSDT.account20) == "a614f803b6fd780986a42c78ec9c7f77e6ded13c")
        #expect(USDT0Mesh.tronPeerWord == [UInt8](repeating: 0, count: 12) + USDT0Mesh.tronOFT.account20)
        #expect(USDT0Mesh.sources[1]?.oft == T.address("0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0"))
        #expect(USDT0Mesh.sources[42161]?.oft == T.address("0x77652D5aba086137b595875263FC200182919B92"))
        #expect(BridgeAllowlist.ethereum.mesh?.usdt == BridgeAllowlist.ethereum.usdt)
        #expect(BridgeAllowlist.arbitrum.mesh?.usdt == BridgeAllowlist.arbitrum.usdt)
    }

    @Test("Calldata: montada e lida de volta; outro destino, opcoes, chamada, lzToken ou troco para outro: recusa")
    func calldata() throws {
        let transfer = Self.transfer(try Self.quote())
        let data = try MeshCalldata.encode(transfer)
        let read = try MeshCalldata.decode(data, owner: Self.owner)
        #expect(read.recipient == Self.recipient && read.amount == transfer.amount && read.minimum == transfer.minimumReceived
                && read.nativeFee == transfer.nativeFee)
        #expect(throws: BridgeRefusal.quoteMismatch("envio")) { try MeshCalldata.decode(data, owner: S.stranger) }

        func encoded(eid: UInt32 = USDT0Mesh.tronEID, to: [UInt8]? = nil, options: [UInt8] = [], compose: [UInt8] = [], command: [UInt8] = [],
                     lzToken: BigUInt = 0) throws -> [UInt8] {
            try USDT0Mesh.sendFunction.encodeCall([
                .tuple([.uint(BigUInt(eid)), .fixedBytes(to ?? USDT0Mesh.recipientWord(Self.recipient)), .uint(transfer.amount),
                        .uint(transfer.minimumReceived), .bytes(options), .bytes(compose), .bytes(command)]),
                .tuple([.uint(transfer.nativeFee), .uint(lzToken)]), .address(Self.owner),
            ])
        }
        #expect(try encoded() == data)
        let dirtyWord = [UInt8](repeating: 0, count: 11) + [1] + Self.recipient.account20
        for hostile in [try encoded(eid: 30101), try encoded(to: dirtyWord), try encoded(options: [0, 3]), try encoded(compose: [1]),
                        try encoded(command: [1]), try encoded(lzToken: 1)] {
            #expect(throws: BridgeRefusal.self) { try MeshCalldata.decode(hostile, owner: Self.owner) }
        }
    }

    // MARK: Validador

    @Test("Validador: 1.000 USDT chegam 999,70 na conta Tron, taxa de mensagem com folga de 10%, nada vem de API")
    func honestQuote() throws {
        let quote = try Self.quote()
        let transfer = Self.transfer(quote)
        let source = try #require(BridgeAllowlist.ethereum.mesh)
        #expect(quote.route == .usdt0 && quote.callMatchesRoute)
        #expect(quote.to == source.oft && quote.spender == source.oft)
        #expect(quote.minimumReceived == 999_700_000 && quote.bridgeFee == 300_000)
        #expect(transfer.recipient == Self.recipient && transfer.owner == Self.owner && transfer.amount == 1_000_000_000)
        #expect(quote.value == transfer.nativeFee && transfer.nativeFee == BigUInt(5_202_395_000_000_000))
        // 0,0052 ETH a US$ 2.400 sobre US$ 1.000: uns 1,25%, mais 0,03% da Tether.
        #expect(abs(quote.messageFeePercent - 1.2485748) < 0.0001)
        #expect(abs(quote.feePercent - 1.2785748) < 0.0001)
        #expect(quote.intent.recipientText == Self.recipient.base58)
        // Da Arbitrum, o USDT0 de la.
        let arbitrum = try Self.quote(try Self.intent(from: .arbitrum))
        #expect(arbitrum.to == USDT0Mesh.sources[42161]?.oft && arbitrum.intent.sell.contract == BridgeAllowlist.arbitrum.usdt)
        // Sem preco, a taxa de mensagem nao entra na porcentagem (e a revisao mostra em ETH).
        let unpriced = try BridgeValidator.mesh(try Self.intent(), quote: Self.read(try Self.intent()), nativeUSDPrice: nil, now: Self.now)
        #expect(unpriced.messageFeePercent == 0)
    }

    @Test("Validador recusa: contrato apontando para outro par ou token, taxa da Tether acima do teto, valor diferente, sem liquidez, lzToken, taxa de mensagem acima do teto, taxa que come o valor")
    func hostileQuote() throws {
        let intent = try Self.intent()
        func validate(_ read: MeshQuote, _ intent: BridgeIntent? = nil, price: TradeDecimal? = Self.ethUSD) throws {
            _ = try BridgeValidator.mesh(intent ?? Self.intent(), quote: read, nativeUSDPrice: price, now: Self.now)
        }
        #expect(throws: BridgeRefusal.meshPeerChanged) { try validate(Self.read(intent, token: S.stranger)) }
        #expect(throws: BridgeRefusal.meshPeerChanged) { try validate(Self.read(intent, peer: USDT0Mesh.recipientWord(Self.recipient))) }
        #expect(throws: BridgeRefusal.feeAboveCap) { try validate(Self.read(intent, feeBps: 11)) }
        #expect(throws: BridgeRefusal.quoteMismatch("valor")) { try validate(Self.read(intent, received: intent.amount)) }
        #expect(throws: BridgeRefusal.meshNoLiquidity(available: 5_000_000)) { try validate(Self.read(intent, maxAmount: 5_000_000)) }
        #expect(throws: BridgeRefusal.quoteMismatch("taxa de mensagem")) { try validate(Self.read(intent, lzTokenFee: 1)) }
        #expect(throws: BridgeRefusal.quoteMismatch("taxa de mensagem")) { try validate(Self.read(intent, nativeFee: 0)) }
        // 0,019 ETH com a folga passa do teto de 0,02 ETH.
        #expect(throws: BridgeRefusal.feeAboveCap) { try validate(Self.read(intent, nativeFee: BigUInt(19_000_000_000_000_000))) }
        // 100 USDT: a taxa de mensagem (uns US$ 12,50) leva mais de 5% do valor.
        let small = try Self.intent(100_000_000)
        #expect(throws: BridgeRefusal.self) { try validate(Self.read(small), small) }
        // O pedido nao e para a Tron: o validador da Mesh nao monta.
        let evm = try BridgeIntent(owner: Self.owner, asset: .usdt, from: .ethereum, to: .arbitrum, amount: 1_000_000_000)
        #expect(throws: BridgeRefusal.unsupportedRoute) { _ = try BridgeValidator.mesh(evm, quote: Self.read(intent), nativeUSDPrice: nil) }
    }

    // MARK: Plano

    @Test("Plano honesto: autorizar o exato ao contrato da Tether e enviar; revisao com a conta Tron, o USDT da Tron e a taxa de entrega")
    func honestPlan() throws {
        let quote = try Self.quote()
        let plan = try Self.plan(quote, Self.state(quote))
        #expect(plan.transactions.count == 2)
        let approve = try #require(plan.transactions.first as? EVMTransaction)
        let send = try #require(plan.transactions.last as? EVMTransaction)
        #expect(approve.to == BridgeAllowlist.ethereum.usdt && approve.data == ERC20.approve(spender: quote.to, amount: quote.intent.amount))
        #expect(send.to == quote.to && send.data == quote.data && send.value == quote.value)
        let lines = Dictionary(plan.review.lines.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(lines["Para"] == "Tron" && lines["Endereço que recebe"] == Self.recipient.base58)
        #expect(lines["Recebe"] == "A sua conta na Tron")
        #expect(lines["Taxa da Tether"] == "0,3\u{00A0}USDT")
        #expect(lines["Taxa de entrega"]?.contains("LayerZero") == true && lines["Taxa de entrega"]?.contains("volta para você") == true)
        #expect(lines["Contrato da Tether"] == quote.to.checksummed)
        #expect(plan.review.beneficiary == Self.recipient.base58)
        #expect(plan.review.incomingMinimum == PlanReview.Movement(assetID: "tron:TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", amount: 999_700_000))
        // A conferencia do app contra o pedido, com os ativos de cada rede e a conta Tron.
        let sell = try #require(BridgeAsset.usdt.asset(on: BridgeAllowlist.ethereum))
        let receive = try #require(BridgeAsset.usdt.asset(on: BridgeAllowlist.tron))
        try PlanIntentCheck.bridge(plan.review, sell: sell, amount: quote.intent.amount, from: .ethereum, receive: receive,
                                   minimumOut: quote.minimumReceived, to: .tron, owner: Self.recipient.base58)
        #expect(throws: PlanIntentCheck.Mismatch.wrongBeneficiary) {
            try PlanIntentCheck.bridge(plan.review, sell: sell, amount: quote.intent.amount, from: .ethereum, receive: receive,
                                       minimumOut: quote.minimumReceived, to: .tron, owner: "TFG4wBaDQ8sHWWP1ACeSGnoNR6RRzevLPt")
        }
        // USDT da Ethereum com autorizacao antiga acima de zero: zera antes.
        let stale = try Self.plan(quote, Self.state(quote, allowance: 5))
        #expect(stale.transactions.count == 3)
    }

    @Test("Simulacao: taxa de mensagem para outro, nativo a mais, outro token saindo, evento para outra rede ou com outro valor: recusa")
    func hostileSimulation() throws {
        let quote = try Self.quote()
        let transfer = Self.transfer(quote)
        func refuse(_ simulation: TradeSimulation) {
            #expect(throws: BridgeRefusal.self) {
                _ = try Self.plan(quote, Self.state(quote, simulations: [simulation, Self.simulation(quote, source: "b")]))
            }
        }
        refuse(Self.simulation(quote, source: "a", native: (S.stranger, quote.value)))
        refuse(Self.simulation(quote, source: "a", native: (quote.to, quote.value + 1)))
        refuse(Self.simulation(quote, source: "a", extra: [S.transferLog(BridgeAllowlist.ethereum.usdc, from: Self.owner, to: S.stranger, 1)]))
        refuse(Self.simulation(quote, source: "a", event: Self.oftSentLog(transfer, dstEid: 30110)))
        refuse(Self.simulation(quote, source: "a", event: Self.oftSentLog(transfer, received: transfer.minimumReceived - 1)))
        refuse(Self.simulation(quote, source: "a", extra: [S.approvalLog(BridgeAllowlist.ethereum.usdt!, owner: Self.owner, spender: S.stranger, 1)]))
        // Uma fonte so nao basta.
        #expect(throws: BridgeRefusal.self) {
            _ = try Self.plan(quote, Self.state(quote, simulations: [Self.simulation(quote, source: "a"), Self.simulation(quote, source: "a")]))
        }
    }

    @Test("Na hora do plano: contrato sem leitura, apontando para outro par, taxa maior, sem liquidez ou taxa de mensagem acima da assinada: recusa")
    func planTimeChecks() throws {
        let quote = try Self.quote()
        let intent = quote.intent
        #expect(throws: BridgeRefusal.meshPeerChanged) { _ = try Self.plan(quote, Self.state(quote, mesh: .some(nil))) }
        #expect(throws: BridgeRefusal.meshPeerChanged) {
            _ = try Self.plan(quote, Self.state(quote, mesh: Self.read(intent, peer: USDT0Mesh.recipientWord(Self.recipient))))
        }
        #expect(throws: BridgeRefusal.quoteMismatch("valor")) { _ = try Self.plan(quote, Self.state(quote, mesh: Self.read(intent, feeBps: 5))) }
        #expect(throws: BridgeRefusal.feeAboveCap) { _ = try Self.plan(quote, Self.state(quote, mesh: Self.read(intent, feeBps: 20))) }
        #expect(throws: BridgeRefusal.meshNoLiquidity(available: 1)) { _ = try Self.plan(quote, Self.state(quote, mesh: Self.read(intent, maxAmount: 1))) }
        #expect(throws: BridgeRefusal.quoteMismatch("taxa de mensagem")) {
            _ = try Self.plan(quote, Self.state(quote, mesh: Self.read(intent, nativeFee: quote.value + 1)))
        }
        // Taxa da Tether menor na hora do plano: chega mais que o minimo, e passa.
        _ = try Self.plan(quote, Self.state(quote, mesh: Self.read(intent, feeBps: 1)))
    }

    @Test("Calldata adulterada depois de validada nao vira plano: outra conta Tron, outro minimo, outra taxa de mensagem")
    func tamperedQuote() throws {
        let quote = try Self.quote()
        let transfer = Self.transfer(quote)
        let other = TronAddress(account20: [UInt8](repeating: 7, count: 20))!
        let variants = [
            MeshTransfer(sourceChainID: 1, oft: transfer.oft, owner: Self.owner, recipient: other, amount: transfer.amount,
                         minimumReceived: transfer.minimumReceived, nativeFee: transfer.nativeFee),
            MeshTransfer(sourceChainID: 1, oft: transfer.oft, owner: Self.owner, recipient: Self.recipient, amount: transfer.amount,
                         minimumReceived: 1, nativeFee: transfer.nativeFee),
            MeshTransfer(sourceChainID: 1, oft: transfer.oft, owner: Self.owner, recipient: Self.recipient, amount: transfer.amount,
                         minimumReceived: transfer.minimumReceived, nativeFee: transfer.nativeFee * BigUInt(2)),
        ]
        for variant in variants {
            var tampered = quote
            tampered = ValidatedBridgeQuote(
                intent: quote.intent, route: .usdt0, call: .mesh(transfer), to: quote.to, value: quote.value,
                data: try MeshCalldata.encode(variant), spender: quote.spender, minimumReceived: quote.minimumReceived,
                expectedReceived: quote.expectedReceived, bridgeFee: quote.bridgeFee, estimatedSeconds: quote.estimatedSeconds,
                createdAt: quote.createdAt
            )
            #expect(throws: BridgeRefusal.quoteMismatch("envio")) { _ = try Self.plan(tampered, Self.state(quote)) }
        }
    }

    // MARK: Chegada

    /// Os logs de uma entrega na Tron como a cadeia mostrou (17/10/2026): o Transfer do USDT
    /// do UsdtOFT para a conta, o OFTReceived e o evento do endpoint.
    static func deliveryLogs(guid: [UInt8] = guid, to: TronAddress = recipient, amount: BigUInt, srcEid: UInt32 = 30101,
                             paidTo: TronAddress? = nil, paidFrom: EVMAddress? = nil, paid: BigUInt? = nil) -> [TradeSimulatedLog] {
        let oft = EVMAddress(uncheckedBytes: USDT0Mesh.tronOFT.account20)
        let usdt = EVMAddress(uncheckedBytes: USDT0Mesh.tronUSDT.account20)
        return [
            S.transferLog(usdt, from: paidFrom ?? oft, to: EVMAddress(uncheckedBytes: (paidTo ?? to).account20), paid ?? amount),
            TradeSimulatedLog(address: oft, topics: [BridgeArrival.oftReceivedTopic, guid, USDT0Mesh.recipientWord(to)],
                              data: S.word(BigUInt(srcEid)) + S.word(amount)),
            TradeSimulatedLog(address: T.address("0x0af59750d5db5460e5d89e268c474d5f7407c061"), topics: [[UInt8](repeating: 0x3c, count: 32)],
                              data: S.word(BigUInt(srcEid))),
        ]
    }

    @Test("Chegada: o guid sai do OFTSent do recibo; a entrega precisa do OFTReceived dele, para a conta Tron, e do Transfer do USDT")
    func arrival() throws {
        let quote = try Self.quote()
        let transfer = Self.transfer(quote)
        let receipt = [S.transferLog(BridgeAllowlist.ethereum.usdt!, from: Self.owner, to: transfer.oft, transfer.amount), Self.oftSentLog(transfer)]
        #expect(BridgeArrival.meshGUID(receipt, transfer: transfer) == Self.guid)
        #expect(BridgeArrival.meshGUID([Self.oftSentLog(transfer, dstEid: 30110)], transfer: transfer) == nil)
        let other = MeshTransfer(sourceChainID: 1, oft: transfer.oft, owner: S.stranger, recipient: Self.recipient, amount: transfer.amount,
                                 minimumReceived: transfer.minimumReceived, nativeFee: transfer.nativeFee)
        #expect(BridgeArrival.meshGUID(receipt, transfer: other) == nil)

        let amount = transfer.minimumReceived
        #expect(BridgeArrival.meshDelivered(Self.deliveryLogs(amount: amount), transfer: transfer, guid: Self.guid, sourceEID: 30101) == amount)
        let stranger = TronAddress(account20: [UInt8](repeating: 9, count: 20))!
        let wrong: [[TradeSimulatedLog]] = [
            Self.deliveryLogs(guid: [UInt8](repeating: 1, count: 32), amount: amount),
            Self.deliveryLogs(to: stranger, amount: amount),
            Self.deliveryLogs(amount: amount, srcEid: 30110),
            Self.deliveryLogs(amount: amount - 1),
            Self.deliveryLogs(amount: amount, paidTo: stranger),
            Self.deliveryLogs(amount: amount, paidFrom: S.stranger),
            Self.deliveryLogs(amount: amount, paid: amount - 1),
            Array(Self.deliveryLogs(amount: amount).dropFirst()),
        ]
        for logs in wrong { #expect(BridgeArrival.meshDelivered(logs, transfer: transfer, guid: Self.guid, sourceEID: 30101) == nil) }
    }

    @Test("Registro: guarda a conta Tron e a taxa de mensagem assinadas, reconstroi o envio, e o registro antigo continua lendo")
    func record() throws {
        let quote = try Self.quote()
        let record = BridgeRecord(quote: quote, walletID: Self.wallet, depositTxHash: "0x" + String(repeating: "AB", count: 32), now: Self.now)
        #expect(record.route == .usdt0 && record.toChainID == "tron" && record.tronRecipient == Self.recipient.base58)
        #expect(record.meshTransfer == Self.transfer(quote))
        #expect(record.to == BridgeAllowlist.tron)
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(BridgeRecord.self, from: data) == record)
        // Um registro de antes da Tron, sem os campos novos.
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old["route"] = "across"
        old.removeValue(forKey: "tronRecipient")
        old.removeValue(forKey: "messageFee")
        let decoded = try JSONDecoder().decode(BridgeRecord.self, from: try JSONSerialization.data(withJSONObject: old))
        #expect(decoded.tronRecipient == nil && decoded.messageFee == nil && decoded.meshTransfer == nil)
    }
}
