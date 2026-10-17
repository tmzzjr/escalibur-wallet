@testable import EscaliburChains
import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburEngines
@testable import EscaliburNetwork

/// A troca imediata pela CoW ao lado dos quatro agregadores (as cotacoes gravadas de 100
/// USDC por ETH na Base), a troca em partes da ordem grande e o andamento da ordem. A CoW
/// e de mentira, cotando o que cada teste diz; a assinatura passa pela conferencia real
/// do `CoWClient`.
@Suite("Motor EVM: troca pela CoW")
struct EVMCoWSwapTests {
    typealias F = EVMTradeFixtures
    typealias H = EVMTradeHarness

    /// A maior estimativa entre os agregadores e a melhor cotacao deles.
    static func aggregators() throws -> (maxExpected: BigUInt, best: TradeCandidate) {
        let quotes = try F.baseProviders.map { try F.validated($0) }
        let best = try #require(try EVMTradeEngineTests.expectedRanking().first)
        return (quotes.map(\.expectedOut).max() ?? 0, best)
    }

    static func scaled(_ value: BigUInt, _ numerator: Int, _ denominator: Int) -> BigUInt {
        value * BigUInt(numerator) / BigUInt(denominator)
    }

    /// Precos do oraculo para que 100 USDC valham `reference` em ETH.
    static func prices(reference: BigUInt) -> [String: String] {
        let micros = BigUInt(100) * BigUInt.power(of: 10, 24) / reference
        let text = micros.decimalString
        return ["usd-coin": "1", "ethereum": String(text.dropLast(6)) + "." + String(text.suffix(6))]
    }

    func engine(cow: FakeCoW, prices: [String: String]? = nil, state: FakeTradeChain = FakeTradeChain(),
                transport: EVMFixtureTransport? = nil) throws -> EVMTradeEngine {
        H.engine(state: state, cow: cow, prices: prices, sources: try H.sources(EVMCallCounter()), transport: try transport ?? H.baseTransport())
    }

    // MARK: Cotacao

    @Test("A CoW garante mais: a troca vai pela CoW, com o minimo exato da cotacao menos a tolerancia")
    func cowWins() async throws {
        let (maxExpected, _) = try Self.aggregators()
        let bought = Self.scaled(maxExpected, 1_010, 1_000)
        let quote = try await engine(cow: FakeCoW(quotes: [F.amount: bought])).quote(F.request())
        #expect(quote.execution == .order)
        #expect(quote.legs.count == 1 && quote.legs[0].provider == "CoW" && quote.legs[0].amountIn == F.amount)
        #expect(quote.expectedOut == bought)
        #expect(quote.minimumOut == bought * BigUInt(9_950) / BigUInt(10_000))
        #expect(quote.alternatives.count == 6 && quote.providersCompared == 7)
        #expect(quote.needsApproval)
        #expect(quote.parts == nil)
        #expect(quote.providerFeeNote?.contains("já saíram da cotação") == true)
    }

    @Test("A CoW garante menos: fica a dos agregadores, com a CoW entre as alternativas")
    func aggregatorWins() async throws {
        let (maxExpected, best) = try Self.aggregators()
        let bought = Self.scaled(maxExpected, 980, 1_000)
        let quote = try await engine(cow: FakeCoW(quotes: [F.amount: bought])).quote(F.request())
        #expect(quote.execution == .transactions)
        #expect(quote.legs[0].provider == best.quote.provider.displayName)
        #expect(quote.minimumOut == best.quote.guaranteedOut)
        let cow = try #require(quote.alternatives.first { $0.provider == "CoW" })
        #expect(cow.out == bought * BigUInt(9_950) / BigUInt(10_000))
        #expect(quote.providersCompared == 7)
    }

    @Test("Sem referencia, cotacao da CoW mais de 5% acima dos agregadores e inflada: fica de fora")
    func inflatedWithoutReference() async throws {
        let (maxExpected, best) = try Self.aggregators()
        let quote = try await engine(cow: FakeCoW(quotes: [F.amount: Self.scaled(maxExpected, 1_060, 1_000)])).quote(F.request())
        #expect(quote.execution == .transactions)
        #expect(quote.legs[0].provider == best.quote.provider.displayName)
        #expect(!quote.alternatives.contains { $0.provider == "CoW" })
    }

    @Test("Com referencia: CoW mais de 5% pior, ou mais de 5% melhor, fica de fora")
    func anchoredToReference() async throws {
        let (maxExpected, _) = try Self.aggregators()
        let prices = Self.prices(reference: maxExpected)
        for factor in [940, 1_060] {
            let quote = try await engine(cow: FakeCoW(quotes: [F.amount: Self.scaled(maxExpected, factor, 1_000)]), prices: prices).quote(F.request())
            #expect(quote.execution == .transactions, "\(factor)")
            #expect(!quote.alternatives.contains { $0.provider == "CoW" }, "\(factor)")
        }
    }

    @Test("Ordem aberta vendendo o mesmo token: a CoW fica de fora da troca imediata")
    func openOrderKeepsCoWOut() async throws {
        let (maxExpected, _) = try Self.aggregators()
        let quote = try await engine(cow: FakeCoW(openTotal: 1, quotes: [F.amount: Self.scaled(maxExpected, 1_010, 1_000)])).quote(F.request())
        #expect(quote.execution == .transactions)
        #expect(!quote.alternatives.contains { $0.provider == "CoW" })
    }

    @Test("Ordem grande: o preco de 25% rende 0,2% a mais, e a troca em partes vira opcao")
    func partsOption() async throws {
        let (maxExpected, _) = try Self.aggregators()
        // Referencia 2% acima dos agregadores: a CoW cheia perde quase 2% para ela, e o
        // preco de 25% do valor fica 1% melhor que o cheio.
        let reference = Self.scaled(maxExpected, 1_020, 1_000)
        let full = Self.scaled(maxExpected, 1_001, 1_000)
        let sample = Self.scaled(maxExpected, 1_010, 4_000)
        let cow = FakeCoW(quotes: [F.amount: full, F.amount / 4: sample])
        let quote = try await engine(cow: cow, prices: Self.prices(reference: reference)).quote(F.request())
        #expect(quote.execution == .order)
        let parts = try #require(quote.parts)
        #expect(parts.expectedOut == sample * F.amount / (F.amount / 4))
        #expect(parts.minimumOut == parts.expectedOut * BigUInt(9_950) / BigUInt(10_000))
        #expect(parts.minimumOut > quote.minimumOut)
        #expect(parts.sampleShareBps == 2_500 && parts.validFor == 3_600)
        #expect(quote.minimumOut(inParts: true) == parts.minimumOut)
        #expect(await cow.quoted.contains(F.amount / 4))

        // Ganho menor que 0,2%: sem opcao.
        let flat = FakeCoW(quotes: [F.amount: full, F.amount / 4: Self.scaled(maxExpected, 1_002, 4_000)])
        let none = try await engine(cow: flat, prices: Self.prices(reference: reference)).quote(F.request())
        #expect(none.parts == nil)
    }

    @Test("Ordem pequena, perto da referencia: nem cota a fracao")
    func noPartsForSmallOrders() async throws {
        let (maxExpected, _) = try Self.aggregators()
        let cow = FakeCoW(quotes: [F.amount: Self.scaled(maxExpected, 1_001, 1_000)])
        let quote = try await engine(cow: cow, prices: Self.prices(reference: maxExpected)).quote(F.request())
        #expect(quote.parts == nil)
        #expect(await cow.quoted == [F.amount])
    }

    // MARK: Plano e envio

    @Test("Plano pela CoW: ordem assinada com exatamente o minimo mostrado, execucao parcial, 30 minutos, revisao de troca")
    func plan() async throws {
        let (maxExpected, _) = try Self.aggregators()
        let cow = FakeCoW(quotes: [F.amount: Self.scaled(maxExpected, 1_010, 1_000)])
        let transport = try H.baseTransport()
        let engine = try engine(cow: cow, transport: transport)
        let quote = try await engine.quote(F.request())
        let plan = try await engine.plan(F.request(), quote: quote)

        #expect(plan.review.kind == .swap)
        #expect(plan.review.transactionCount == 2)
        let approve = try #require(plan.transactions.first as? EVMTransaction)
        #expect(approve.data == ERC20.approve(spender: CoWProtocol.vaultRelayer, amount: F.amount))
        let order = try #require(plan.transactions.last as? EIP712ValidatedMessage)
        #expect(order.typedData.message["buyAmount"] == .string(quote.minimumOut.decimalString))
        #expect(order.typedData.message["sellAmount"] == .string(F.amount.decimalString))
        #expect(order.typedData.message["partiallyFillable"] == .bool(true))
        if case .number(let text)? = order.typedData.message["validTo"], let validTo = Double(text) {
            #expect(abs(validTo - Date().timeIntervalSince1970 - CoWProtocol.instantValidity) < 30)
        } else {
            Issue.record("validTo")
        }
        #expect(plan.review.incomingMinimum?.amount == quote.minimumOut)
        #expect(plan.review.lines.contains { $0.label == "Entra, no mínimo" })
        #expect(plan.review.lines.contains { $0.label == "Prazo" && $0.value.hasPrefix("30 minutos") })
        #expect(!plan.review.title.contains("em partes"))

        let signed = try EVMTestAccounts.sign(plan)
        let result = try await engine.submit(signed, plan: plan)
        let uid = try #require(result.first.flatMap { Hex.decode($0) })
        #expect(uid.count == CoWProtocol.uidLength && Array(uid.prefix(32)) == order.digest)
        #expect(await cow.submitted == [uid])
        // A autorizacao saiu (pelas duas fontes) e foi acompanhada antes da ordem.
        #expect(transport.calls("eth_sendRawTransaction").count == 2)
        #expect(await cow.registered == [CoWAppData.limitOrder])
    }

    @Test("Em partes: o minimo das partes, valendo 1 hora")
    func planInParts() async throws {
        let (maxExpected, _) = try Self.aggregators()
        let cow = FakeCoW(quotes: [F.amount: Self.scaled(maxExpected, 1_001, 1_000), F.amount / 4: Self.scaled(maxExpected, 1_010, 4_000)])
        let engine = try engine(cow: cow, prices: Self.prices(reference: Self.scaled(maxExpected, 1_020, 1_000)))
        let quote = try await engine.quote(F.request())
        let parts = try #require(quote.parts)
        let request = TradeRequest(walletID: UUID(), chain: .base, account: try EVMTestAccounts.testAccount(on: .base), sell: F.usdc,
                                   buy: .native(.base), amountIn: F.amount, slippageBasisPoints: 50, inParts: true)
        let plan = try await engine.plan(request, quote: quote)
        let order = try #require(plan.transactions.last as? EIP712ValidatedMessage)
        #expect(order.typedData.message["buyAmount"] == .string(parts.minimumOut.decimalString))
        if case .number(let text)? = order.typedData.message["validTo"], let validTo = Double(text) {
            #expect(abs(validTo - Date().timeIntervalSince1970 - CoWProtocol.partsValidity) < 30)
        } else {
            Issue.record("validTo")
        }
        #expect(plan.review.title.hasSuffix("em partes"))
        #expect(plan.review.lines.contains { $0.label == "Prazo" && $0.value.hasPrefix("60 minutos") })
    }

    @Test("Cotacao sem opcao em partes nao planeja em partes; cotacao dos agregadores nao vira ordem")
    func refusesMismatchedExecution() async throws {
        let (maxExpected, _) = try Self.aggregators()
        let engine = try engine(cow: FakeCoW(quotes: [F.amount: Self.scaled(maxExpected, 980, 1_000)]))
        let quote = try await engine.quote(F.request())
        #expect(quote.execution == .transactions && quote.parts == nil)
        let request = TradeRequest(walletID: UUID(), chain: .base, account: try EVMTestAccounts.testAccount(on: .base), sell: F.usdc,
                                   buy: .native(.base), amountIn: F.amount, slippageBasisPoints: 50, inParts: true)
        await #expect(throws: SendEngineError.message("A cotação não corresponde a esta troca. Atualize a cotação e revise de novo.")) {
            _ = try await engine.plan(request, quote: quote)
        }
    }

    @Test("Intencao da troca imediata so com o prazo de 30 minutos; em partes, so com 1 hora")
    func styleValidity() throws {
        let owner = try EVMAddress(EVMTestAccounts.testAccount(on: .base).address)
        let price = try #require(CoWLimitPrice("0.0004"))
        #expect(throws: CoWRefusal.validityOutOfRange) {
            _ = try CoWLimitOrderIntent(owner: owner, sell: .token(F.usdcToken), buy: .native(.base), sellAmount: F.amount, price: price,
                                        validFor: 3_600, style: .instant)
        }
        #expect(throws: CoWRefusal.validityOutOfRange) {
            _ = try CoWLimitOrderIntent(owner: owner, sell: .token(F.usdcToken), buy: .native(.base), sellAmount: F.amount, price: price,
                                        validFor: CoWProtocol.instantValidity, style: .parts)
        }
        // A ordem limite continua sem aceitar 30 minutos.
        #expect(throws: CoWRefusal.validityOutOfRange) {
            _ = try CoWLimitOrderIntent(owner: owner, sell: .token(F.usdcToken), buy: .native(.base), sellAmount: F.amount, price: price,
                                        validFor: CoWProtocol.instantValidity)
        }
    }

    // MARK: Andamento

    static func status(uid: [UInt8], owner: EVMAddress, state: CoWOrderStatus.Status, executedSell: BigUInt, executedBuy: BigUInt,
                       validTo: UInt32, invalidated: Bool = false) -> CoWOrderStatus {
        CoWOrderStatus(
            uid: uid, status: state, invalidated: invalidated, owner: owner, sellToken: F.usdcToken.contract,
            buyToken: CoWProtocol.buyNativeToken, receiver: owner, sellAmount: F.amount, buyAmount: BigUInt(40_000_000_000_000_000),
            validTo: validTo, executedSellAmount: executedSell, executedBuyAmount: executedBuy
        )
    }

    @Test("Andamento: aberta em 40%, preenchida, vencida e cancelada; ordem de outra conta recusa")
    func progress() async throws {
        let account = try EVMTestAccounts.testAccount(on: .base)
        let owner = try EVMAddress(account.address)
        let future = UInt32(Date().timeIntervalSince1970 + 600)
        let past = UInt32(Date().timeIntervalSince1970 - 60)
        let uid = [UInt8](repeating: 0xAB, count: 32) + owner.bytes + withUnsafeBytes(of: future.bigEndian) { Array($0) }
        let id = Hex.encode(uid, prefix: true)
        let cow = FakeCoW()
        let engine = try engine(cow: cow)

        await cow.setStatus(Self.status(uid: uid, owner: owner, state: .open, executedSell: 40_000_000, executedBuy: 16_000_000_000_000_000, validTo: future))
        let open = try await engine.orderProgress(id: id, account: account)
        #expect(open.state == .open && open.fraction == 0.4 && !open.isFinal)
        #expect(open.receivedBuy == 16_000_000_000_000_000 && open.minimumBuy == 40_000_000_000_000_000)

        await cow.setStatus(Self.status(uid: uid, owner: owner, state: .fulfilled, executedSell: F.amount, executedBuy: 40_100_000_000_000_000, validTo: future))
        let filled = try await engine.orderProgress(id: id, account: account)
        #expect(filled.state == .filled && filled.fraction == 1 && filled.isFinal)

        await cow.setStatus(Self.status(uid: uid, owner: owner, state: .open, executedSell: 10_000_000, executedBuy: 1, validTo: past))
        #expect(try await engine.orderProgress(id: id, account: account).state == .expired)

        await cow.setStatus(Self.status(uid: uid, owner: owner, state: .open, executedSell: 0, executedBuy: 0, validTo: future, invalidated: true))
        #expect(try await engine.orderProgress(id: id, account: account).state == .cancelled)

        let stranger = [UInt8](repeating: 0xAB, count: 32) + [UInt8](repeating: 0x11, count: 20) + withUnsafeBytes(of: future.bigEndian) { Array($0) }
        await #expect(throws: SendEngineError.message("Estas ordens não são desta conta.")) {
            _ = try await engine.orderProgress(id: Hex.encode(stranger, prefix: true), account: account)
        }
    }

    @Test("Ordens abertas trazem o total e o recebido, para a tela mostrar quanto ja foi preenchido")
    func openOrdersCarryFill() {
        let owner = try! EVMAddress(EVMTestAccounts.testAccount(on: .base).address)
        let future = UInt32(Date().timeIntervalSince1970 + 600)
        let uid = [UInt8](repeating: 0xAB, count: 32) + owner.bytes + withUnsafeBytes(of: future.bigEndian) { Array($0) }
        let order = EVMTradeEngine.openOrder(chain: .base)(
            Self.status(uid: uid, owner: owner, state: .open, executedSell: 25_000_000, executedBuy: 10_000_000_000_000_000, validTo: future)
        )
        #expect(order.totalSell == F.amount && order.remainingSell == 75_000_000)
        #expect(order.receivedBuy == 10_000_000_000_000_000)
        #expect(order.filledFraction == 0.25)
    }
}

@Suite("Troca de token fora da lista")
struct EVMUnlistedTradeTests {
    /// O SHIB de ponte da BNB Chain, fora da lista (o BNB Frog Inu, exemplo antigo, entrou
    /// nela em 14/10/2026).
    static let frog = Asset(chainID: "bnb", kind: .token(contract: "0x2859e4544c4bb03966803b044a93563bd2d0dd4d"), symbol: "SHIB",
                            name: "SHIBA INU", decimals: 18, coingeckoID: nil, isStablecoin: false, origin: .discovered)

    @Test("Token que a carteira tem e moeda adicionada entram na troca; no envio, so a adicionada")
    func resolve() throws {
        #expect(throws: EVMEngineFailure.assetNotListed) { _ = try EVMEngineSupport.resolve(Self.frog, on: .bnb) }
        #expect(throws: EVMEngineFailure.assetNotListed) { _ = try EVMEngineSupport.resolve(Self.frog, on: .bnb, allowCustom: true) }
        guard case .token(let token) = try EVMEngineSupport.resolve(Self.frog, on: .bnb, allowUnlisted: true) else {
            Issue.record("token")
            return
        }
        #expect(token.decimals == 18 && token.symbol == "SHIB")
        // Outra rede: recusa.
        #expect(throws: EVMEngineFailure.assetNotListed) { _ = try EVMEngineSupport.resolve(Self.frog, on: .base, allowUnlisted: true) }
    }
}

@Suite("Troca de token fora da lista ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"))
struct EVMUnlistedTradeLiveTests {
    @Test("BNB Frog Inu por BNB na BNB Chain: os provedores cotam")
    func quote() async throws {
        let engine = try #require(EVMTradeEngine(chain: .bnb))
        let request = TradeRequest(walletID: UUID(), chain: .bnb, account: try EVMTestAccounts.testAccount(on: .bnb), sell: EVMUnlistedTradeTests.frog,
                                   buy: .native(.bnb), amountIn: BigUInt.power(of: 10, 18) * BigUInt(1_000_000), slippageBasisPoints: 100)
        let quote = try await engine.quote(request)
        print("BNBFROG -> BNB: \(quote.legs.map(\.provider)) garantido \(quote.minimumOut) comparados \(quote.providersCompared)")
        #expect(!quote.minimumOut.isZero)
    }
}
