import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// Ordens limite pela CoW. O vetor oficial e a propria cadeia: o UID de uma ordem
/// liquidada vem do evento `Trade` do GPv2Settlement, calculado pelo contrato, e os 32
/// primeiros bytes dele sao o digesto EIP-712. Duas ordens reais da Base (Fixtures/trade,
/// `GET api.cow.fi/base/api/v1/orders/{uid}`, liquidadas nas transacoes
/// 0xd3fbe076...a4c2 e 0xc254f149...72a7) conferem dominio, tipo, digesto, appData e o
/// formato r || s || v da assinatura.
@Suite("Troca: ordens limite pela CoW")
struct TradeCoWTests {
    typealias S = TradeTestSupport
    typealias T = EVMTestSupport

    static let wallet = UUID()
    static let now = Date(timeIntervalSince1970: 1_790_400_000)

    static func order(fromFixture name: String) throws -> (CoWOrder, [String: Any]) {
        let root = try S.json(name)
        let order = CoWOrder(
            chain: .base, sellToken: T.address(root["sellToken"] as! String), buyToken: T.address(root["buyToken"] as! String),
            receiver: T.address(root["receiver"] as! String), sellAmount: BigUInt(decimal: root["sellAmount"] as! String)!,
            buyAmount: BigUInt(decimal: root["buyAmount"] as! String)!, validTo: UInt32((root["validTo"] as! NSNumber).uint32Value),
            appData: T.bytes(root["appData"] as! String), partiallyFillable: root["partiallyFillable"] as! Bool
        )
        return (order, root)
    }

    @Test("Constantes contra o fonte: TYPE_HASH, KIND_SELL, BALANCE_ERC20, cancelamento e seletores")
    func constants() throws {
        // GPv2Order.sol
        #expect(Hash.keccak256(Array(CoWProtocol.orderEncodedType.utf8)) == T.bytes("d5a25ba2e97094ad7d83dc28a6572da797d6b3e7fc6663bd93efb789fc17e489"))
        #expect(Hash.keccak256(Array("sell".utf8)) == T.bytes("f3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775"))
        #expect(Hash.keccak256(Array("erc20".utf8)) == T.bytes("5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9"))
        // cowprotocol/services, crates/model/src/order.rs (OrderCancellations::TYPE_HASH).
        #expect(Hash.keccak256(Array(CoWProtocol.cancellationsEncodedType.utf8)) == T.bytes("4c89efb91ae246f78d2fe68b47db2fa1444a121a4f2dc3fda7a5a408c2e3588e"))
        let order = try Self.order(fromFixture: "cow-base-order-limit").0
        #expect(try order.typedData().encodeType("Order") == CoWProtocol.orderEncodedType)
        #expect(CoWProtocol.invalidateOrderFunction.selector == T.bytes("15337bc0"))
        #expect(CoWProtocol.depositFunction.selector == T.bytes("d0e30db0"))
        #expect(CoWProtocol.settlement.checksummed == "0x9008D19f58AAbD9eD0D60971565AA8510560ab41")
        #expect(CoWProtocol.vaultRelayer.checksummed == "0xC92E8bdf79f0507f65a392b0ab4667716BFE0110")
    }

    @Test("Dominio: separador igual ao domainSeparator() lido do GPv2Settlement")
    func domainSeparator() throws {
        // eth_call domainSeparator() em 25/09/2026.
        let onChain: [(Chain, String)] = [
            (.ethereum, "c078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943"),
            (.base, "d72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b"),
            (.arbitrum, "69d78e7a7cafcaf924483f99f65e8f4e303a99a446db7ab319f9d40e940bced2"),
            // Segunda leva, 26/09/2026.
            (.plasma, "e1f9c97768e45812440cd3317c07069178cc2f69971fb204c0211d8bfb1f8e76"),
            (.linea, "b219bb2b8733b80b7ebef0229e7f0c91436f9a0a5b9705fa519237ae0493addb"),
        ]
        for (chain, separator) in onChain {
            let typed = try CoWPlanner.cancellationTypedData(chain: chain, uids: [[UInt8](repeating: 1, count: 56)])
            #expect(try typed.domainSeparator() == T.bytes(separator), "\(chain.id)")
        }
    }

    @Test("Ordens reais da Base: digesto = UID calculado pelo contrato, appData = keccak do documento, assinatura recupera o dono")
    func realOrders() throws {
        for name in ["cow-base-order-limit", "cow-base-order-market"] {
            let (order, root) = try Self.order(fromFixture: name)
            let owner = T.address(root["owner"] as! String)
            let uid = T.bytes(root["uid"] as! String)
            #expect(try order.uid(owner: owner) == uid, "\(name)")
            #expect(CoWProtocol.owner(ofUID: uid) == owner)
            #expect(CoWProtocol.validTo(ofUID: uid) == order.validTo)
            #expect(Hash.keccak256(Array((root["fullAppData"] as! String).utf8)) == order.appData)
            // r || s || v, v = 27 ou 28: ecrecover com v - 27 devolve o dono.
            let signature = T.bytes(root["signature"] as! String)
            #expect(signature.count == 65)
            #expect(signature[64] == 27 || signature[64] == 28)
            let recovered = try Secp256k1.recover(digest: try order.digest(), compact: Array(signature.prefix(64)),
                                                  recoveryID: signature[64] - 27, compressed: true)
            #expect(try EVMAddress(publicKey: recovered) == owner, "\(name)")
        }
    }

    @Test("Preco-alvo: buyAmount calculado localmente, arredondado para cima")
    func limitPrice() throws {
        // 1 ETH = 3.000,50 USDC: vender 0,5 ETH pede 1.500,25 USDC.
        let price = CoWLimitPrice("3000,50")!
        #expect(price.buyAmount(sellAmount: BigUInt(decimal: "500000000000000000")!, sellDecimals: 18, buyDecimals: 6) == 1_500_250_000)
        // 1 USDC = 0,000333 ETH, vendendo 1 unidade minima de USDC: arredonda para cima.
        let tiny = CoWLimitPrice("0.000333")!
        #expect(tiny.buyAmount(sellAmount: 1, sellDecimals: 6, buyDecimals: 18) == 333_000_000)
        #expect(tiny.buyAmount(sellAmount: 3, sellDecimals: 6, buyDecimals: 3) == 1)
        #expect(CoWLimitPrice("0") == nil)
        #expect(CoWLimitPrice("1.000,5") == nil)
        #expect(CoWLimitPrice("-3") == nil)
        #expect(CoWLimitPrice("3e3") == nil)
    }

    static func state(_ chain: Chain, allowance: BigUInt = 0, balance: BigUInt = 10_000_000_000, open: BigUInt = 0) -> CoWChainState {
        CoWChainState(
            network: EVMNetworkState(chain: chain, pendingNonces: [3, 3], baseFeePerGas: BigUInt(5_000_000),
                                     priorityFees: EVMPriorityFees(slow: 1_000_000, normal: 1_000_000, fast: 1_000_000),
                                     gasEstimate: 46_000, l1DataFee: BigUInt(1_000_000_000), nativeBalance: BigUInt(decimal: "2000000000000000000")!,
                                     destinationHasCode: true),
            sellToken: EVMTokenState(contractHasCode: true, balance: balance, allowance: allowance),
            wrapGasEstimate: 30_000, wrapL1DataFee: BigUInt(1_000_000_000), openOrdersSellTotal: open
        )
    }

    @Test("Ordem de USDC -> ETH na Base: approve exato ao VaultRelayer e a ordem assinada localmente")
    func planTokenOrder() throws {
        let account = try T.account(T.testKey)
        let intent = try CoWLimitOrderIntent(owner: S.owner, sell: .token(S.baseUSDC), buy: .native(.base), sellAmount: 100_000_000,
                                             price: CoWLimitPrice("0.0004")!, validFor: 3 * 24 * 3600)
        let plan = try CoWPlanner.planLimitOrder(walletID: Self.wallet, account: account, intent: intent, state: Self.state(.base), now: Self.now)
        let transactions = plan.signingPlan.transactions
        #expect(transactions.count == 2)
        let approve = transactions[0] as! EVMTransaction
        #expect(approve.to == S.baseUSDC.contract)
        #expect(approve.data == ERC20.approve(spender: CoWProtocol.vaultRelayer, amount: 100_000_000))
        #expect(approve.nonce == 3)
        let message = transactions[1] as! EIP712ValidatedMessage
        #expect(plan.order.buyAmount == BigUInt(decimal: "40000000000000000")!)
        #expect(plan.order.buyToken == CoWProtocol.buyNativeToken)
        #expect(plan.order.receiver == S.owner)
        #expect(plan.order.appData == CoWAppData.limitOrder.hash)
        #expect(plan.order.validTo == UInt32(Self.now.timeIntervalSince1970) + 3 * 24 * 3600)
        #expect(message.digest == Array(plan.uid.prefix(32)))
        #expect(plan.uid == (try plan.order.uid(owner: S.owner)))
        #expect(plan.prerequisiteCount == 1)
        #expect(plan.signingPlan.review.kind == .limitOrder)
        // Os movimentos sao os da ordem assinada: sellAmount, buyAmount e receiver.
        #expect(plan.signingPlan.review.outgoing == PlanReview.Movement(assetID: "base:0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", amount: 100_000_000))
        #expect(plan.signingPlan.review.incomingMinimum == PlanReview.Movement(assetID: "base:native", amount: plan.order.buyAmount))
        #expect(plan.signingPlan.review.beneficiary == plan.order.receiver.checksummed)
        let lines = Dictionary(uniqueKeysWithValues: plan.signingPlan.review.lines.map { ($0.label, $0.value) })
        #expect(lines["Recebe, no mínimo"] == "0,04\u{00A0}ETH")
        #expect(lines["Preço-alvo"] == "1\u{00A0}USDC = 0,0004\u{00A0}ETH")
        #expect(lines["Autorizado a gastar"] == "0xC92E8bdf79f0507f65a392b0ab4667716BFE0110")
        #expect(lines["Taxa da Escalibur"] == "Sem taxa da Escalibur")
        #expect(lines["Execução parcial"] == "Permitida")

        // Assinatura de ponta a ponta: r || s || v com v = 27/28, e recupera o dono.
        let signed = try message.assemble(with: [T.sign(message.digest, key: T.testKey)])
        #expect(signed.raw.count == 65 && (signed.raw[64] == 27 || signed.raw[64] == 28))
        let recovered = try Secp256k1.recover(digest: message.digest, compact: Array(signed.raw.prefix(64)),
                                              recoveryID: signed.raw[64] - 27, compressed: true)
        #expect(try EVMAddress(publicKey: recovered) == S.owner)
    }

    @Test("Uma ordem por token com teto na cadeia (auditoria 2, B4): a autorizacao termina exatamente no valor da ordem")
    func approvalCapIsExact() throws {
        let account = try T.account(T.testKey)
        let intent = try CoWLimitOrderIntent(owner: S.owner, sell: .token(S.baseUSDC), buy: .native(.base), sellAmount: 100_000_000,
                                             price: CoWLimitPrice("0.0004")!)
        func lines(_ plan: CoWLimitOrderPlan) -> [String: String] {
            Dictionary(uniqueKeysWithValues: plan.signingPlan.review.lines.map { ($0.label, $0.value) })
        }

        // Sobra de uma autorizacao antiga (500 USDC): o plano reduz para os 100 da ordem,
        // e a revisao diz por que.
        let reduced = try CoWPlanner.planLimitOrder(walletID: Self.wallet, account: account, intent: intent,
                                                    state: Self.state(.base, allowance: 500_000_000), now: Self.now)
        #expect(reduced.signingPlan.transactions.count == 2)
        let approve = try #require(reduced.signingPlan.transactions.first as? EVMTransaction)
        #expect(approve.to == S.baseUSDC.contract)
        #expect(approve.data == ERC20.approve(spender: CoWProtocol.vaultRelayer, amount: 100_000_000))
        #expect(lines(reduced)["Autorização atual"]?.contains("reduzida para o valor exato") == true)
        #expect(lines(reduced)["Outras ordens"]?.contains("vem só da CoW") == true)
        #expect(lines(reduced)["Outras ordens"]?.contains("não tiram mais que isso") == true)

        // Autorizacao ilimitada de outro app: tambem reduzida.
        let unlimited = try CoWPlanner.planLimitOrder(walletID: Self.wallet, account: account, intent: intent,
                                                      state: Self.state(.base, allowance: .uint256Max), now: Self.now)
        #expect((unlimited.signingPlan.transactions.first as? EVMTransaction)?.data == ERC20.approve(spender: CoWProtocol.vaultRelayer, amount: 100_000_000))

        // Ja exatamente no valor: so a ordem, sem transacao.
        let exact = try CoWPlanner.planLimitOrder(walletID: Self.wallet, account: account, intent: intent,
                                                  state: Self.state(.base, allowance: 100_000_000), now: Self.now)
        #expect(exact.signingPlan.transactions.count == 1)
        #expect(exact.signingPlan.transactions.first is EIP712ValidatedMessage)
        #expect(exact.prerequisiteCount == 0)
        #expect(lines(exact)["Autorização"] == "Já existe e é exatamente o valor da ordem")
        #expect(lines(exact)["Autorização atual"] == nil)

        // Com a soma confirmada, o teto e a soma: 50 abertos + 100 desta, com 900 de sobra.
        let stacked = try CoWPlanner.planLimitOrder(walletID: Self.wallet, account: account, intent: intent,
                                                    state: Self.state(.base, allowance: 900_000_000, open: 50_000_000),
                                                    stackingConfirmed: true, now: Self.now)
        #expect((stacked.signingPlan.transactions.first as? EVMTransaction)?.data == ERC20.approve(spender: CoWProtocol.vaultRelayer, amount: 150_000_000))

        // USDT da Ethereum com sobra: zera antes e aprova o valor exato, duas transacoes.
        let usdt = EVMToken(chain: .ethereum, contract: T.address("0xdAC17F958D2ee523a2206206994597C13D831ec7"), symbol: "USDT", decimals: 6)
        let usdtIntent = try CoWLimitOrderIntent(owner: S.owner, sell: .token(usdt), buy: .native(.ethereum), sellAmount: 100_000_000,
                                                 price: CoWLimitPrice("0.0004")!)
        let reset = try CoWPlanner.planLimitOrder(walletID: Self.wallet, account: account, intent: usdtIntent,
                                                  state: Self.state(.ethereum, allowance: 500_000_000), now: Self.now)
        let approvals = reset.signingPlan.transactions.compactMap { $0 as? EVMTransaction }
        #expect(approvals.map(\.data) == [
            ERC20.approve(spender: CoWProtocol.vaultRelayer, amount: 0), ERC20.approve(spender: CoWProtocol.vaultRelayer, amount: 100_000_000),
        ])
    }

    @Test("Ate cancelar: validTo no maximo pratico da CoW, dito na revisao; prazo entre 30 dias e isso recusa")
    func untilCancelled() throws {
        let account = try T.account(T.testKey)
        let intent = try CoWLimitOrderIntent(owner: S.owner, sell: .token(S.baseUSDC), buy: .native(.base), sellAmount: 100_000_000,
                                             price: CoWLimitPrice("0.0004")!, validFor: CoWProtocol.untilCancelledValidity)
        #expect(intent.isUntilCancelled)
        let plan = try CoWPlanner.planLimitOrder(walletID: Self.wallet, account: account, intent: intent, state: Self.state(.base), now: Self.now)
        #expect(plan.order.validTo == UInt32(Self.now.timeIntervalSince1970) + 364 * 24 * 3600)
        let line = try #require(plan.signingPlan.review.lines.first { $0.label == "Válida até" })
        #expect(line.value.contains("o prazo mais longo que a CoW aceita"))
        #expect(throws: CoWRefusal.validityOutOfRange) {
            try CoWLimitOrderIntent(owner: S.owner, sell: .token(S.baseUSDC), buy: .native(.base), sellAmount: 1,
                                    price: CoWLimitPrice("1")!, validFor: 60 * 24 * 3600)
        }
    }

    @Test("Vender ETH: embrulha para WETH, aprova o WETH exato, ordem vende WETH")
    func planNativeOrder() throws {
        let account = try T.account(T.testKey)
        let amount = BigUInt(decimal: "500000000000000000")!
        let intent = try CoWLimitOrderIntent(owner: S.owner, sell: .native(.base), buy: .token(S.baseUSDC), sellAmount: amount,
                                             price: CoWLimitPrice("3000")!)
        let plan = try CoWPlanner.planLimitOrder(walletID: Self.wallet, account: account, intent: intent,
                                                 state: Self.state(.base, balance: 0), now: Self.now)
        let transactions = plan.signingPlan.transactions
        #expect(transactions.count == 3)
        let approve = transactions[0] as! EVMTransaction
        let wrap = transactions[1] as! EVMTransaction
        let weth = CoWProtocol.wrappedNative(on: .base)!
        #expect(approve.to == weth.contract && approve.nonce == 3)
        #expect(wrap.to == weth.contract && wrap.value == amount && wrap.data == T.bytes("d0e30db0") && wrap.nonce == 4)
        #expect(plan.order.sellToken == weth.contract)
        #expect(plan.order.buyAmount == 1_500_000_000)
        #expect(plan.signingPlan.review.lines.contains { $0.label == "Antes" && $0.value.contains("WETH") })
        // Vende o nativo (o embrulho vai pelo mesmo valor), recebe USDC da lista.
        #expect(plan.signingPlan.review.outgoing == PlanReview.Movement(assetID: "base:native", amount: amount))
        #expect(wrap.value == plan.order.sellAmount)
        #expect(plan.signingPlan.review.incomingMinimum == PlanReview.Movement(
            assetID: "base:0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", amount: 1_500_000_000
        ))
    }

    @Test("Recusas: rede sem CoW, validade fora da janela, ordem aberta no mesmo token, outra conta")
    func refusals() throws {
        let account = try T.account(T.testKey)
        let opUSDC = EVMToken(chain: .optimism, contract: T.address("0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85"), symbol: "USDC", decimals: 6)
        #expect(throws: CoWRefusal.unsupportedChain) {
            try CoWLimitOrderIntent(owner: S.owner, sell: .token(opUSDC), buy: .native(.optimism), sellAmount: 1, price: CoWLimitPrice("1")!)
        }
        #expect(throws: CoWRefusal.validityOutOfRange) {
            try CoWLimitOrderIntent(owner: S.owner, sell: .token(S.baseUSDC), buy: .native(.base), sellAmount: 1, price: CoWLimitPrice("1")!, validFor: 1_800)
        }
        #expect(throws: CoWRefusal.validityOutOfRange) {
            try CoWLimitOrderIntent(owner: S.owner, sell: .token(S.baseUSDC), buy: .native(.base), sellAmount: 1, price: CoWLimitPrice("1")!, validFor: 31 * 24 * 3600)
        }
        let intent = try CoWLimitOrderIntent(owner: S.owner, sell: .token(S.baseUSDC), buy: .native(.base), sellAmount: 100_000_000, price: CoWLimitPrice("0.0004")!)
        #expect(throws: CoWRefusal.openOrderExists) {
            try CoWPlanner.planLimitOrder(walletID: Self.wallet, account: account, intent: intent, state: Self.state(.base, open: 50_000_000), now: Self.now)
        }
        // Com confirmacao, a aprovacao cobre exatamente a soma das duas.
        let stacked = try CoWPlanner.planLimitOrder(walletID: Self.wallet, account: account, intent: intent,
                                                    state: Self.state(.base, open: 50_000_000), stackingConfirmed: true, now: Self.now)
        #expect((stacked.signingPlan.transactions[0] as! EVMTransaction).data == ERC20.approve(spender: CoWProtocol.vaultRelayer, amount: 150_000_000))
        #expect(throws: CoWRefusal.insufficientBalance(needed: 150_000_000, available: 120_000_000)) {
            try CoWPlanner.planLimitOrder(walletID: Self.wallet, account: account, intent: intent,
                                          state: Self.state(.base, balance: 120_000_000, open: 50_000_000), stackingConfirmed: true, now: Self.now)
        }
        let other = try T.account("4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318")
        #expect(throws: TradeRefusal.ownerMismatch) {
            try CoWPlanner.planLimitOrder(walletID: Self.wallet, account: other, intent: intent, state: Self.state(.base), now: Self.now)
        }
        // A regra da mensagem recusa ordem com prazo alem de 30 dias, mesmo montada a mao.
        let far = CoWOrder(chain: .base, sellToken: S.baseUSDC.contract, buyToken: CoWProtocol.buyNativeToken, receiver: S.owner,
                           sellAmount: 1, buyAmount: 1, validTo: UInt32(Self.now.timeIntervalSince1970) + 40 * 24 * 3600,
                           appData: CoWAppData.limitOrder.hash, partiallyFillable: true)
        #expect(throws: EIP712Error.notAllowlisted) {
            try EIP712ValidatedMessage(far.typedData(), chain: .base, account: account,
                                       allowlist: [CoWPlanner.orderRule(chain: .base, order: far, now: Self.now)])
        }
        // "Ate cancelar" e exatamente o maximo pratico da CoW: passa; um dia alem, recusa.
        for (days, allowed) in [(364, true), (365, false), (200, false)] {
            let order = CoWOrder(chain: .base, sellToken: S.baseUSDC.contract, buyToken: CoWProtocol.buyNativeToken, receiver: S.owner,
                                 sellAmount: 1, buyAmount: 1, validTo: UInt32(Self.now.timeIntervalSince1970) + UInt32(days) * 24 * 3600,
                                 appData: CoWAppData.limitOrder.hash, partiallyFillable: true)
            let result = Result { try EIP712ValidatedMessage(order.typedData(), chain: .base, account: account,
                                                             allowlist: [CoWPlanner.orderRule(chain: .base, order: order, now: Self.now)]) }
            #expect(((try? result.get()) != nil) == allowed, "\(days) dias")
        }
        // Destinatario diferente do dono tambem.
        let elsewhere = CoWOrder(chain: .base, sellToken: S.baseUSDC.contract, buyToken: CoWProtocol.buyNativeToken, receiver: S.stranger,
                                 sellAmount: 1, buyAmount: 1, validTo: UInt32(Self.now.timeIntervalSince1970) + 7200,
                                 appData: CoWAppData.limitOrder.hash, partiallyFillable: true)
        #expect(throws: EIP712Error.notAllowlisted) {
            try EIP712ValidatedMessage(elsewhere.typedData(), chain: .base, account: account,
                                       allowlist: [CoWPlanner.orderRule(chain: .base, order: elsewhere, now: Self.now)])
        }
    }

    @Test("Cancelamento fora da cadeia: OrderCancellations(bytes[] orderUids) assinado; so UIDs do proprio dono")
    func offchainCancellation() throws {
        let account = try T.account(T.testKey)
        let uid = [UInt8](repeating: 0xAB, count: 32) + S.owner.bytes + [0x6A, 0xB9, 0x87, 0x8A]
        let plan = try CoWPlanner.planOffchainCancellation(walletID: Self.wallet, account: account, chain: .base, uids: [uid], now: Self.now)
        let message = plan.transactions[0] as! EIP712ValidatedMessage
        // hashStruct = keccak(TYPE_HASH || keccak(keccak(uid))), como o backend calcula.
        let typeHash = T.bytes("4c89efb91ae246f78d2fe68b47db2fa1444a121a4f2dc3fda7a5a408c2e3588e")
        let structHash = Hash.keccak256(typeHash + Hash.keccak256(Hash.keccak256(uid)))
        let separator = T.bytes("d72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b")
        #expect(message.digest == Hash.keccak256([0x19, 0x01] + separator + structHash))
        #expect(plan.review.kind == .cancelOrder)
        #expect(plan.review.lines.contains { $0.label == "Garantia" && $0.value.hasPrefix("Não é garantido") })
        let foreign = [UInt8](repeating: 0xAB, count: 32) + S.stranger.bytes + [0, 0, 0, 1]
        #expect(throws: CoWRefusal.invalidUID) {
            try CoWPlanner.planOffchainCancellation(walletID: Self.wallet, account: account, chain: .base, uids: [foreign], now: Self.now)
        }
    }

    @Test("Cancelamento na cadeia: invalidateOrder(uid) no GPv2Settlement, garantido")
    func onchainCancellation() throws {
        let account = try T.account(T.testKey)
        let uid = [UInt8](repeating: 0xCD, count: 32) + S.owner.bytes + [0x6A, 0xB9, 0x87, 0x8A]
        let network = EVMNetworkState(chain: .arbitrum, pendingNonces: [9, 9], baseFeePerGas: BigUInt(20_000_000),
                                      priorityFees: EVMPriorityFees(slow: 0, normal: 0, fast: 0), gasEstimate: 40_000,
                                      nativeBalance: BigUInt(decimal: "10000000000000000")!, destinationHasCode: true)
        let plan = try CoWPlanner.planOnchainCancellation(walletID: Self.wallet, account: account, chain: .arbitrum, uid: uid, state: network, now: Self.now)
        let transaction = plan.transactions[0] as! EVMTransaction
        #expect(transaction.to == CoWProtocol.settlement)
        #expect(transaction.value == 0)
        #expect(transaction.data == (try CoWProtocol.invalidateOrderFunction.encodeCall([.bytes(uid)])))
        #expect(plan.review.lines.contains { $0.label == "Garantia" && $0.value.hasPrefix("Garantido") })
        let foreign = [UInt8](repeating: 0xCD, count: 32) + S.stranger.bytes + [0, 0, 0, 1]
        #expect(throws: CoWRefusal.invalidUID) {
            try CoWPlanner.planOnchainCancellation(walletID: Self.wallet, account: account, chain: .arbitrum, uid: foreign, state: network, now: Self.now)
        }
        #expect(throws: CoWRefusal.unsupportedChain) {
            try CoWPlanner.planOnchainCancellation(walletID: Self.wallet, account: account, chain: .optimism, uid: uid, state: network, now: Self.now)
        }
    }

    @Test("Redes da CoW: oito, sem OP; embrulhados conferidos")
    func networks() {
        #expect(Chain.evmChains.filter(CoWProtocol.supports).map(\.id).sorted()
            == ["arbitrum", "avalanche", "base", "bnb", "ethereum", "linea", "plasma", "polygon"])
        #expect(CoWProtocol.apiNetwork(for: .plasma) == "plasma")
        #expect(CoWProtocol.apiNetwork(for: .linea) == "linea")
        #expect(CoWProtocol.apiNetwork(for: .unichain) == nil)
        #expect(CoWProtocol.wrappedNative(on: .plasma)?.contract.checksummed == "0x6100E367285b01F48D07953803A2d8dCA5D19873")
        #expect(CoWProtocol.wrappedNative(on: .plasma)?.symbol == "WXPL")
        #expect(CoWProtocol.wrappedNative(on: .linea)?.contract.checksummed == "0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f")
        #expect(CoWProtocol.apiNetwork(for: .arbitrum) == "arbitrum_one")
        #expect(CoWProtocol.apiNetwork(for: .optimism) == nil)
        #expect(CoWProtocol.wrappedNative(on: .polygon)?.symbol == "WPOL")
        #expect(CoWProtocol.wrappedNative(on: .bnb)?.contract.checksummed == "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c")
        #expect(CoWProtocol.wrappedNative(on: .avalanche)?.contract.checksummed == "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7")
        #expect(CoWAppData.limitOrder.hashHex == "0xc4bc024729643c016b25d21dd603367a17923f53d92d06dccf492ac0929d6eb6")
        #expect(!CoWAppData.limitOrder.json.contains("hooks"))
    }
}
