import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore
@testable import EscaliburEngines

@Suite("Troca: quanto quero receber")
struct ExactOutSolverTests {
    static let sell = Asset.native(.ethereum)
    static let buy = TokenRegistry.tokens.first { $0.chainID == "ethereum" && $0.symbol == "USDC" }!
    static let ether = BigUInt.power(of: 10, 18)
    static let dollar = BigUInt.power(of: 10, 6)

    /// Um motor de mentira: o minimo para cada valor, contando as cotacoes pedidas.
    final class Market: @unchecked Sendable {
        let minimum: (BigUInt) -> BigUInt
        var parts: ((BigUInt) -> BigUInt)?
        private(set) var asked: [BigUInt] = []

        init(_ minimum: @escaping (BigUInt) -> BigUInt) { self.minimum = minimum }

        func quote(_ amount: BigUInt) async throws -> TradeQuote {
            asked.append(amount)
            let out = minimum(amount)
            return TradeQuote(
                sell: ExactOutSolverTests.sell, buy: ExactOutSolverTests.buy, amountIn: amount, expectedOut: out, minimumOut: out,
                priceImpactPercent: nil, networkFeeFiat: nil, providerFeeNote: nil, legs: [], alternatives: [], providersCompared: 1,
                needsApproval: false, expiresAt: Date().addingTimeInterval(60),
                parts: parts.map { .init(expectedOut: $0(amount), minimumOut: $0(amount), sampleShareBps: 2_500, validFor: 3_600) }
            )
        }
    }

    /// 1 ETH = 3.000 USDC, menos 0,5% de tolerancia.
    static func linear(_ amount: BigUInt) -> BigUInt { amount * BigUInt(2_985) * dollar / ether }

    @Test("Preco linear: o minimo garantido chega ao pedido, com no maximo 0,3% a mais, e o valor a pagar com 6 algarismos")
    func linearPrice() async throws {
        let market = Market(Self.linear)
        let want = BigUInt(1_000) * Self.dollar
        let solution = try await ExactOutSolver.solve(want: want, start: Self.ether / BigUInt(3), unit: Self.ether, inParts: false, quote: market.quote)
        #expect(solution.reached)
        #expect(solution.quote.minimumOut >= want)
        #expect(solution.quote.minimumOut * BigUInt(10_000) <= want * BigUInt(10_030))
        #expect(solution.amountIn == solution.quote.amountIn)
        #expect(solution.amountIn.decimalString.trimmingCharacters(in: CharacterSet(charactersIn: "0")).count <= 6)
        #expect(market.asked.count <= ExactOutSolver.attempts)
    }

    @Test("Impacto que cresce com o tamanho: converge e nunca devolve um minimo abaixo do pedido")
    func priceImpact() async throws {
        // Quanto maior, pior: perde 1% a cada 10 ETH.
        let market = Market { amount in
            let base = Self.linear(amount)
            let loss = base * amount / (Self.ether * BigUInt(1_000))
            return base > loss ? base - loss : BigUInt(0)
        }
        let want = BigUInt(60_000) * Self.dollar
        let solution = try await ExactOutSolver.solve(want: want, start: nil, unit: Self.ether, inParts: false, quote: market.quote)
        #expect(solution.reached)
        #expect(solution.quote.minimumOut >= want)
        #expect(market.asked.first == Self.ether, "sem estimativa, a primeira cotacao e de uma unidade")
        #expect(market.asked.count <= ExactOutSolver.attempts)
    }

    @Test("Liquidez que acaba antes do pedido: devolve o que da, marcado como nao alcancado")
    func liquidityCap() async throws {
        let cap = BigUInt(500) * Self.dollar
        let market = Market { amount in min(Self.linear(amount), cap) }
        let solution = try await ExactOutSolver.solve(want: BigUInt(1_000) * Self.dollar, start: Self.ether, unit: Self.ether, inParts: false, quote: market.quote)
        #expect(!solution.reached)
        #expect(solution.quote.minimumOut == cap)
        #expect(market.asked.count == ExactOutSolver.attempts)
        #expect(Set(market.asked).count == market.asked.count, "nunca pede a mesma cotacao duas vezes")
    }

    @Test("Em partes, o alvo e o minimo da troca em partes")
    func inParts() async throws {
        let market = Market(Self.linear)
        market.parts = { amount in Self.linear(amount) * BigUInt(1_010) / BigUInt(1_000) }
        let want = BigUInt(10_000) * Self.dollar
        let solution = try await ExactOutSolver.solve(want: want, start: Self.ether * BigUInt(3), unit: Self.ether, inParts: true, quote: market.quote)
        #expect(solution.reached)
        #expect(solution.quote.minimumOut(inParts: true) >= want)
        #expect(solution.quote.minimumOut < want, "o minimo de uma vez so fica abaixo: paga-se menos em partes")
    }

    @Test("Cotacao sem minimo e pedido zero: erro, sem valor inventado")
    func noOutput() async {
        let market = Market { _ in BigUInt(0) }
        await #expect(throws: ExactOutSolver.Failure.noOutput) {
            _ = try await ExactOutSolver.solve(want: Self.dollar, start: nil, unit: Self.ether, inParts: false, quote: market.quote)
        }
        await #expect(throws: ExactOutSolver.Failure.noOutput) {
            _ = try await ExactOutSolver.solve(want: BigUInt(0), start: Self.ether, unit: Self.ether, inParts: false, quote: Market(Self.linear).quote)
        }
    }

    @Test("Arredonda para cima com 6 algarismos")
    func rounding() {
        #expect(ExactOutSolver.roundUp(BigUInt(1_234_567_891)) == BigUInt(1_234_570_000))
        #expect(ExactOutSolver.roundUp(BigUInt(1_234_560_000)) == BigUInt(1_234_560_000))
        #expect(ExactOutSolver.roundUp(BigUInt(999)) == BigUInt(999))
        #expect(ExactOutSolver.roundUp(BigUInt(999_999_1)) == BigUInt(10_000_000))
    }
}
