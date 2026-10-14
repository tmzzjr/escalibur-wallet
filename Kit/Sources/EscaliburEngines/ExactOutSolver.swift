import EscaliburCore
import Foundation

/// "Quanto quero receber" (pedido do dono, 14/10/2026): o valor a pagar que garante pelo
/// menos o recebido digitado.
///
/// Acha esse valor so com cotacoes de valor de entrada, as unicas que os motores
/// validam, montam e assinam. A troca continua sendo de entrada exata, com o minimo
/// gravado na transacao ou na ordem; o recebido digitado vira o alvo desse minimo. Nada
/// aqui toca no plano nem na assinatura.
public enum ExactOutSolver {
    public struct Solution: Sendable, Equatable {
        public let amountIn: BigUInt
        public let quote: TradeQuote
        /// O minimo garantido chegou ao recebido pedido. Falso so quando nem a ultima
        /// tentativa chegou (liquidez que acaba no caminho): a tela diz o que da.
        public let reached: Bool
    }

    public enum Failure: Error, Equatable {
        /// A cotacao veio sem minimo: nao ha taxa para estimar.
        case noOutput
    }

    /// Cotacoes por busca, contando a de sondagem.
    public static let attempts = 5
    /// Folga aceita acima do pedido antes de tentar pagar menos: 0,3%.
    static let overshootBasisPoints: UInt64 = 30
    /// Algarismos que contam no valor a pagar: 1,23457 ETH, e nao 1,234567891234 ETH.
    static let significantDigits = 6

    /// - Parameters:
    ///   - want: o recebido pedido, em unidades da rede do ativo comprado.
    ///   - start: a estimativa de partida (cotacao anterior ou preco de mercado); sem ela,
    ///     uma cotacao de uma unidade inteira (`unit`) da a taxa.
    ///   - inParts: o minimo que conta e o da troca em partes, quando a cotacao oferece.
    ///   - quote: a cotacao de valor de entrada do motor.
    ///   - isolation: roda no ator de quem chama (a tela), e a cotacao nao cruza de ator.
    public static func solve(
        want: BigUInt, start: BigUInt?, unit: BigUInt, inParts: Bool,
        isolation: isolated (any Actor)? = #isolation,
        quote: (BigUInt) async throws -> TradeQuote
    ) async throws -> Solution {
        guard !want.isZero else { throw Failure.noOutput }
        var remaining = attempts
        var guess: BigUInt
        if let start, !start.isZero {
            guess = start
        } else {
            let probe = try await quote(unit)
            remaining -= 1
            let got = probe.minimumOut(inParts: inParts && probe.parts != nil)
            guard !got.isZero else { throw Failure.noOutput }
            guess = ceilDiv(unit * want, got)
        }
        var best: Solution?
        var last: Solution?
        var tried = Set<BigUInt>()
        while remaining > 0 {
            try Task.checkCancellation()
            var amount = roundUp(guess)
            // A mesma cotacao de novo nao ensina nada: sobe um degrau do arredondamento.
            while tried.contains(amount) { amount = roundUp(amount + step(amount)) }
            tried.insert(amount)
            let fresh = try await quote(amount)
            remaining -= 1
            let got = fresh.minimumOut(inParts: inParts && fresh.parts != nil)
            guard !got.isZero else { throw Failure.noOutput }
            if got >= want {
                if best == nil || amount < best!.amountIn { best = Solution(amountIn: amount, quote: fresh, reached: true) }
                if got * BigUInt(10_000) <= want * BigUInt(10_000 + overshootBasisPoints) { break }
                guess = ceilDiv(amount * want, got)
            } else {
                last = Solution(amountIn: amount, quote: fresh, reached: false)
                // 0,1% a mais: o preco piora com o tamanho, e a proxima tentativa ja passa.
                guess = ceilDiv(amount * want * BigUInt(1_001), got * BigUInt(1_000))
            }
        }
        if let best { return best }
        guard let last else { throw Failure.noOutput }
        return last
    }

    /// Arredonda para cima, com `significantDigits` algarismos que contam.
    public static func roundUp(_ value: BigUInt) -> BigUInt {
        let digits = value.decimalString.count
        guard digits > significantDigits else { return value }
        let factor = BigUInt.power(of: 10, digits - significantDigits)
        let (quotient, remainder) = value.quotientAndRemainder(dividingBy: factor)
        return remainder.isZero ? value : (quotient + 1) * factor
    }

    /// O degrau do arredondamento no tamanho de `value` (no minimo 1).
    static func step(_ value: BigUInt) -> BigUInt {
        let digits = value.decimalString.count
        return digits > significantDigits ? BigUInt.power(of: 10, digits - significantDigits) : BigUInt(1)
    }

    public static func ceilDiv(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        let (quotient, remainder) = a.quotientAndRemainder(dividingBy: b)
        return remainder.isZero ? quotient : quotient + 1
    }
}
