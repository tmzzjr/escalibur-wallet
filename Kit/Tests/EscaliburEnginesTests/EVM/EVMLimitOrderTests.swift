@testable import EscaliburChains
import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburEngines
@testable import EscaliburNetwork

/// Ordem limite pela CoW e o cancelamento fora da cadeia, sem rede: estado sintetico, a
/// CoW de mentira conferindo a assinatura com o codigo real do `CoWClient`, e a Base pelo
/// transporte gravado.
@Suite("Motor EVM: ordem limite")
struct EVMLimitOrderTests {
    typealias F = EVMTradeFixtures
    typealias H = EVMTradeHarness

    static let week: TimeInterval = 7 * 86_400
    /// 100 USDC por no minimo 0,04 ETH.
    static let minimumOut = BigUInt(decimal: "40000000000000000")!

    static func request(minimumOut: BigUInt = minimumOut, validFor: TimeInterval? = week) throws -> LimitOrderRequest {
        LimitOrderRequest(walletID: UUID(), chain: .base, account: try EVMTestAccounts.testAccount(on: .base), sell: F.usdc,
                          buy: .native(.base), amountIn: F.amount, minimumOut: minimumOut, validFor: validFor)
    }

    @Test("Preco-alvo: o minimo que o dono calculou e reproduzido exatamente pela conta da CoW")
    func exactLimitPrice() throws {
        let amounts: [BigUInt] = [1, 7, 999, 100_000_000, BigUInt(decimal: "123456789012345678")!, BigUInt(decimal: "40000000000000000000000")!]
        let minimums: [BigUInt] = [1, 3, 1_000_003, BigUInt(decimal: "40000000000000000")!, BigUInt(decimal: "987654321987654321987")!]
        let decimals: [(Int, Int)] = [(6, 18), (18, 6), (18, 18), (6, 6), (8, 18), (18, 8)]
        var checked = 0
        for amount in amounts {
            for minimum in minimums {
                for (sell, buy) in decimals {
                    do {
                        let price = try EVMTradeEngine.limitPrice(minimumOut: minimum, sellAmount: amount, sellDecimals: sell, buyDecimals: buy)
                        #expect(price.buyAmount(sellAmount: amount, sellDecimals: sell, buyDecimals: buy) == minimum, "\(amount) \(minimum) \(sell) \(buy)")
                        checked += 1
                    } catch EVMEngineFailure.limitPriceNotRepresentable {
                        // So quando a escala passaria das 36 casas que o preco aceita.
                        #expect(amount.decimalString.count + buy - sell > 36)
                    }
                }
            }
        }
        #expect(checked > 150)
    }

    @Test("Ordem limite: autorizacao exata ao VaultRelayer e ordem EIP-712; o envio espera a autorizacao e devolve o UID")
    func limitOrder() async throws {
        let transport = try H.baseTransport()
        let cow = FakeCoW()
        let engine = H.engine(cow: cow, sources: [], transport: transport)
        let plan = try await engine.planLimitOrder(Self.request())
        #expect(plan.review.kind == .limitOrder)
        #expect(plan.review.transactionCount == 2)
        let approve = try #require(plan.transactions.first as? EVMTransaction)
        #expect(approve.data == ERC20.approve(spender: CoWProtocol.vaultRelayer, amount: F.amount))
        let order = try #require(plan.transactions.last as? EIP712ValidatedMessage)
        #expect(order.typedData.primaryType == "Order")
        #expect(order.typedData.message["buyAmount"] == .string(Self.minimumOut.decimalString))
        #expect(order.typedData.message["feeAmount"] == .string("0"))
        #expect(plan.review.lines.contains { $0.label == "Recebe, no mínimo" && $0.value == "0,04\u{00A0}ETH" })
        #expect(plan.review.lines.contains { $0.label == "Taxa da Escalibur" && $0.value == "Sem taxa da Escalibur" })

        let signed = try EVMTestAccounts.sign(plan)
        let result = try await engine.submit(signed, plan: plan)
        // O UID: digesto da ordem, dono e validTo. A CoW de mentira so aceitou depois de
        // conferir a assinatura com o codigo do cliente real.
        let uid = try #require(result.first.flatMap { Hex.decode($0) })
        #expect(result.count == 1 && uid.count == CoWProtocol.uidLength)
        #expect(Array(uid.prefix(32)) == order.digest)
        #expect(CoWProtocol.owner(ofUID: uid) == order.account.address)
        #expect(await cow.submitted == [uid])
        #expect(await cow.registered == [CoWAppData.limitOrder])
        // A autorizacao saiu e foi acompanhada antes da ordem.
        #expect(transport.calls("eth_sendRawTransaction").count == 2)
        #expect(!transport.calls("eth_getTransactionReceipt").isEmpty)

        // Um plano e enviado uma vez so.
        await #expect(throws: SendEngineError.message("A ordem venceu antes de ser enviada. Monte a ordem de novo.")) {
            _ = try await engine.submit(signed, plan: plan)
        }
    }

    @Test("Autorizacao revertida na cadeia: a ordem nao vai para a CoW")
    func prerequisiteFailed() async throws {
        let cow = FakeCoW()
        let engine = H.engine(cow: cow, sources: [], transport: try H.baseTransport(receiptStatus: "0x0"))
        let plan = try await engine.planLimitOrder(Self.request())
        await #expect(throws: SendEngineError.message("A autorização da ordem falhou na rede. A ordem não foi enviada.")) {
            _ = try await engine.submit(try EVMTestAccounts.sign(plan), plan: plan)
        }
        #expect(await cow.submitted.isEmpty)
    }

    @Test("Ordem aberta vendendo o mesmo token, validade fora da faixa e rede sem CoW: recusa")
    func refusals() async throws {
        let engine = H.engine(cow: FakeCoW(openTotal: 1), sources: [], transport: try H.baseTransport())
        await #expect(throws: SendEngineError.message("Já existe uma ordem limite aberta vendendo este token. Cancele a anterior antes de criar outra.")) {
            _ = try await engine.planLimitOrder(Self.request())
        }
        let fresh = H.engine(sources: [], transport: try H.baseTransport())
        await #expect(throws: SendEngineError.message("A validade da ordem precisa ficar entre 1 hora e 30 dias.")) {
            _ = try await fresh.planLimitOrder(Self.request(validFor: 31 * 86_400))
        }
        let optimism = H.engine(chain: .optimism, sources: [], transport: try H.baseTransport())
        let request = LimitOrderRequest(
            walletID: UUID(), chain: .optimism, account: try EVMTestAccounts.testAccount(on: .optimism), sell: .native(.optimism),
            buy: TokenRegistry.find(chainID: "optimism", contract: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85")!,
            amountIn: 1, minimumOut: 1, validFor: Self.week
        )
        await #expect(throws: SendEngineError.message("Ordens limite ainda não estão disponíveis na Optimism.")) {
            _ = try await optimism.planLimitOrder(request)
        }
    }

    @Test("Cancelamento fora da cadeia: plano EIP-712 das ordens do dono, assinatura conferida antes de ir a CoW")
    func cancellation() async throws {
        let cow = FakeCoW()
        let engine = H.engine(cow: cow, sources: [], transport: try H.baseTransport())
        let account = try EVMTestAccounts.testAccount(on: .base)
        let owner = try EVMAddress(account.address)
        let uid = [UInt8](repeating: 0xAB, count: 32) + owner.bytes + [0x70, 0x00, 0x00, 0x00]
        let plan = try engine.planLimitOrderCancellation(walletID: UUID(), account: account, orderUIDs: [Hex.encode(uid, prefix: true)])
        #expect(plan.review.kind == .cancelOrder)
        #expect(plan.review.lines.contains { $0.label == "Garantia" })
        try await engine.submitLimitOrderCancellation(try EVMTestAccounts.sign(plan), plan: plan)
        let cancelled = await cow.cancelled
        #expect(cancelled.count == 1 && cancelled.first?.uids == [uid] && cancelled.first?.owner == owner)

        // Ordem de outra conta: recusa antes de assinar.
        let foreign = [UInt8](repeating: 0xAB, count: 32) + EVMTestAccounts.binance8.bytes + [0x70, 0x00, 0x00, 0x00]
        #expect(throws: SendEngineError.message("Estas ordens não são desta conta.")) {
            _ = try engine.planLimitOrderCancellation(walletID: UUID(), account: account, orderUIDs: [Hex.encode(foreign, prefix: true)])
        }
    }

    @Test("Ate cancelar: a CoW exige prazo, e a ordem vale o maximo pratico dela, dito na revisao")
    func untilCancelled() async throws {
        let engine = H.engine(cow: FakeCoW(), sources: [], transport: try H.baseTransport())
        let before = Date()
        let plan = try await engine.planLimitOrder(Self.request(validFor: nil))
        let order = try #require(plan.transactions.last as? EIP712ValidatedMessage)
        guard case .number(let text)? = order.typedData.message["validTo"], let validTo = TimeInterval(text) else {
            Issue.record("validTo"); return
        }
        let expected = before.timeIntervalSince1970 + CoWProtocol.untilCancelledValidity
        #expect(validTo >= expected.rounded(.down) && validTo <= expected + 5)
        #expect(CoWProtocol.untilCancelledValidity < 31_536_000)
        #expect(plan.review.lines.contains { $0.label == "Válida até" && $0.value.contains("o prazo mais longo que a CoW aceita") })
    }

    static func status(uid: [UInt8], owner: EVMAddress, executed: BigUInt = 0) -> CoWOrderStatus {
        CoWOrderStatus(
            uid: uid, status: .open, invalidated: false, owner: owner, sellToken: F.usdcToken.contract,
            buyToken: CoWProtocol.buyNativeToken, receiver: owner, sellAmount: F.amount, buyAmount: minimumOut,
            validTo: 0x7000_0000, executedSellAmount: executed, executedBuyAmount: 0
        )
    }

    @Test("Ordens abertas da CoW: o que falta vender, o minimo pelo preco gravado e os dois jeitos de cancelar")
    func openOrders() async throws {
        let cow = FakeCoW()
        let chain = FakeTradeChain()
        let engine = H.engine(state: chain, cow: cow, sources: [], transport: try H.baseTransport())
        let account = try EVMTestAccounts.testAccount(on: .base)
        let owner = try EVMAddress(account.address)
        let uid = [UInt8](repeating: 0xAB, count: 32) + owner.bytes + [0x70, 0x00, 0x00, 0x00]
        await cow.setOpen([Self.status(uid: uid, owner: owner, executed: 25_000_000)])
        let orders = try await engine.openOrders(account: account)
        #expect(orders.count == 1)
        let open = try #require(orders.first)
        #expect(open.id == Hex.encode(uid, prefix: true))
        #expect(open.sell == F.usdc && open.buy == .native(.base))
        #expect(open.remainingSell == 75_000_000)
        #expect(open.minimumBuy == BigUInt(decimal: "30000000000000000")!)
        #expect(open.expiresAt == Date(timeIntervalSince1970: TimeInterval(0x7000_0000)))
        #expect(open.cancellations == [.offchain, .onchain] && open.sources == 1)

        // Pela CoW: o pedido assinado vai pelo `submit` como qualquer plano.
        let offchain = try await engine.planCancel(open, walletID: UUID(), account: account)
        #expect(offchain.review.kind == .cancelOrder)
        let ids = try await engine.submit(try EVMTestAccounts.sign(offchain), plan: offchain)
        #expect(ids == [open.id])
        #expect(await cow.cancelled.first?.uids == [uid])

        // Na cadeia: invalidateOrder(uid) no GPv2Settlement, com o gas da chamada exata.
        let onchain = try await engine.planCancel(open, walletID: UUID(), account: account, via: .onchain)
        #expect(onchain.review.kind == .cancelOrder && onchain.review.lines.contains { $0.label == "Garantia" })
        let transaction = try #require(onchain.transactions.first as? EVMTransaction)
        let expectedCall = try CoWProtocol.invalidateOrderCall(uid: uid)
        #expect(transaction.to == CoWProtocol.settlement && transaction.data == expectedCall)
        #expect(await chain.cancellationReads == [uid])

        // UID de outra conta nao vira plano.
        let foreign = [UInt8](repeating: 0xAB, count: 32) + EVMTestAccounts.binance8.bytes + [0x70, 0x00, 0x00, 0x00]
        let stranger = OpenOrder(
            id: Hex.encode(foreign, prefix: true), chain: .base, sellAssetID: open.sellAssetID, buyAssetID: open.buyAssetID,
            remainingSell: 1, minimumBuy: 1, expiresAt: nil, sources: 1, cancellations: [.onchain]
        )
        await #expect(throws: SendEngineError.self) { _ = try await engine.planCancel(stranger, walletID: UUID(), account: account) }
    }
}
