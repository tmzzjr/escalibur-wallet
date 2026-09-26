import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Um lado de uma troca na DEX do XRP Ledger: o `Asset` da carteira e o que ele e no
/// ledger. XRP, ou token da lista curada com moeda e emissor.
struct XRPLTradeSide: Equatable {
    let asset: Asset
    /// nil no XRP.
    let curated: XRPLCuratedAsset?

    var isXRP: Bool { curated == nil }

    var book: XRPLBookAsset {
        guard let curated else { return .xrp }
        return .issued(currency: curated.currency, issuer: curated.issuer)
    }

    /// O lado da oferta com `units` na menor unidade do `Asset`.
    func offerAsset(_ units: BigUInt) -> XRPLOfferAsset {
        guard let curated else { return .xrp(drops: units) }
        return .issued(currency: curated.currency, issuer: curated.issuer, value: XRPLUnits.decimalText(units, decimals: asset.decimals))
    }

    /// O mesmo valor como vai gravado na transacao, para conferir o plano.
    func amount(_ units: BigUInt) throws -> XRPLAmount {
        guard let curated else { return .xrp(drops: units) }
        let value = try XRPLDecimal(XRPLUnits.decimalText(units, decimals: asset.decimals))
        return .issued(try XRPLIssuedAmount(value: value, currency: curated.currency, issuer: curated.issuer))
    }
}

/// Valores do ledger na menor unidade do `Asset` da carteira, e de volta.
///
/// XRP ja vem em drops (6 casas, as do `Asset` nativo). Token vem como mantissa e
/// expoente decimal, e vira inteiro com as casas que a lista curada da ao `Asset`.
enum XRPLUnits {
    /// Expoente decimal acima do qual o valor nao e de ninguem: estado inventado.
    static let maxShift = 40

    static func units(_ amount: XRPLAmount, decimals: Int, roundingUp: Bool) -> BigUInt? {
        switch amount {
        case .xrp(let drops):
            return decimals == Chain.xrpl.nativeDecimals ? drops : nil
        case .issued(let issued):
            return units(issued.value, decimals: decimals, roundingUp: roundingUp)
        }
    }

    static func units(_ value: XRPLDecimal, decimals: Int, roundingUp: Bool) -> BigUInt? {
        guard !value.isNegative else { return nil }
        guard !value.isZero else { return BigUInt() }
        let mantissa = BigUInt(value.mantissa)
        let shift = value.exponent + decimals
        if shift >= 0 {
            guard shift <= maxShift else { return nil }
            return mantissa * BigUInt.power(of: 10, shift)
        }
        guard -shift <= maxShift else { return roundingUp ? BigUInt(1) : BigUInt() }
        let (quotient, remainder) = mantissa.quotientAndRemainder(dividingBy: BigUInt.power(of: 10, -shift))
        return roundingUp && !remainder.isZero ? quotient + BigUInt(1) : quotient
    }

    /// "12.5" para 12500000 com 6 casas: ponto decimal, sem zeros sobrando, como o JSON
    /// e o `XRPLDecimal` leem.
    static func decimalText(_ units: BigUInt, decimals: Int) -> String {
        let digits = units.decimalString
        guard decimals > 0 else { return digits }
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let cut = padded.index(padded.endIndex, offsetBy: -decimals)
        var fraction = String(padded[cut...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? String(padded[..<cut]) : "\(padded[..<cut]).\(fraction)"
    }
}

/// O preenchimento de uma venda contra o livro de ofertas, oferta por oferta.
struct XRPLBookFill: Equatable {
    /// Quanto chega entregando exatamente o valor de entrada.
    let out: BigUInt
    /// A melhor oferta, para o impacto no preco.
    let bestGets: BigUInt
    let bestPays: BigUInt

    /// Consome as ofertas do melhor preco para o pior ate entregar `amountIn`.
    ///
    /// O que se paga e arredondado para cima e o que se recebe para baixo, para a cotacao
    /// nunca prometer mais do que o livro da. nil quando o livro lido nao cobre o valor.
    /// Pools AMM (XLS-30) nao aparecem no livro: a rede pode executar melhor que isto,
    /// nunca pior que o minimo gravado na oferta.
    static func fill(_ offers: [XRPLBookOffer], amountIn: BigUInt, sell: XRPLTradeSide, buy: XRPLTradeSide) -> XRPLBookFill? {
        var priced: [(gets: BigUInt, pays: BigUInt)] = offers.compactMap { offer in
            guard let gets = XRPLUnits.units(offer.takerGets, decimals: buy.asset.decimals, roundingUp: false),
                  let pays = XRPLUnits.units(offer.takerPays, decimals: sell.asset.decimals, roundingUp: true),
                  !gets.isZero, !pays.isZero
            else { return nil }
            return (gets, pays)
        }
        // Melhor preco primeiro: mais recebido por unidade paga. A ordem do servidor nao
        // e premissa.
        priced.sort { $0.gets * $1.pays > $1.gets * $0.pays }
        guard let best = priced.first, !amountIn.isZero else { return nil }
        var remaining = amountIn
        var out = BigUInt()
        for offer in priced where !remaining.isZero {
            if remaining >= offer.pays {
                out = out + offer.gets
                remaining = remaining - offer.pays
            } else {
                out = out + offer.gets * remaining / offer.pays
                remaining = BigUInt()
            }
        }
        guard remaining.isZero, !out.isZero else { return nil }
        return XRPLBookFill(out: out, bestGets: best.gets, bestPays: best.pays)
    }
}

/// A conta depois da linha de confianca, para planejar a oferta que vem em seguida
/// (Sequence n + 1). Quem junta os dois planos e confere a sequencia e
/// `XRPLPlanner.combineTrustlineAndOffer`, em EscaliburChains.
enum XRPLPlanComposer {
    /// A conta depois da primeira transacao, para planejar a segunda: Sequence mais um,
    /// a taxa a menos no saldo e um objeto a mais (a linha de confianca).
    static func stateAfter(_ plan: SigningPlan, account: XRPLAccountState) throws -> XRPLAccountState {
        guard plan.transactions.count == 1, let transaction = plan.transactions.first as? XRPLTransaction,
              case .trustSet = transaction.body, account.sequenceReadings.allSatisfy({ $0 < UInt32.max })
        else { throw XRPLPlanError.transaction(.invalidSequence) }
        guard let balance = account.balance.subtractingReportingUnderflow(transaction.fee) else {
            throw XRPLPlanError.insufficientFunds(spendable: account.balance, required: transaction.fee)
        }
        return XRPLAccountState(
            address: account.address, sequenceReadings: account.sequenceReadings.map { $0 + 1 },
            balance: balance, ownerCount: account.ownerCount + 1, flags: account.flags
        )
    }
}
