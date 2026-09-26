import EscaliburCore
import Foundation

/// Tamanho e selecao de moedas.
///
/// A selecao segue o Bitcoin Core (wallet/coinselection.cpp): Branch and Bound para
/// achar um conjunto que pague o envio sem troco, e alternativas com troco quando
/// nao ha; entre as solucoes, fica a de menor desperdicio ("waste"). Tudo inteiro,
/// em satoshis, e deterministico: a mesma entrada da sempre a mesma transacao.
enum UTXOSizing {
    /// Peso exato da transacao, com assinaturas de pior caso.
    ///
    /// Numa transacao com witness, cada entrada que nao e segwit ainda escreve uma
    /// pilha vazia (1 byte de witness), e marker e flag somam 2 bytes de witness.
    static func weight(inputs: [UTXOInputKind], outputs: [UTXOScriptType]) -> Int {
        let hasWitness = inputs.contains { $0.isSegwit }
        var base = 4 + UTXOByteWriter.compactSizeLength(inputs.count) + UTXOByteWriter.compactSizeLength(outputs.count) + 4
        var witness = hasWitness ? 2 : 0
        for kind in inputs {
            base += kind.nonWitnessSize
            if hasWitness { witness += kind.isSegwit ? kind.witnessSize : 1 }
        }
        base += outputs.reduce(0) { $0 + $1.outputSize }
        return base * 4 + witness
    }
}

/// Uma moeda que pode entrar na selecao.
struct UTXOSelectionCoin {
    let id: Int
    let value: UInt64
    /// Taxa para gastar esta moeda agora.
    let fee: UInt64
    /// Taxa para gasta-la num momento de taxa de longo prazo.
    let longTermFee: UInt64

    /// Valor efetivo: o que a moeda acrescenta depois de pagar a propria entrada.
    var effectiveValue: Int64 { Int64(value) - Int64(fee) }
}

struct UTXOSelectionParameters {
    /// Valor enviado mais a taxa da parte fixa (cabecalho e saida do destino).
    let target: Int64
    /// Taxa da saida de troco agora.
    let changeOutputFee: Int64
    /// Custo de criar o troco e gasta-lo depois. Uma sobra menor que isso vale mais
    /// como taxa do que como moeda.
    let costOfChange: Int64
    /// Menor troco que compensa criar: acima do dust e do custo de gasta-lo.
    let minViableChange: Int64
}

struct UTXOSelectionResult: Equatable {
    let ids: [Int]
    let withChange: Bool
    let waste: Int64
}

enum UTXOCoinSelection {
    /// Tentativas do Branch and Bound, as mesmas do Core (TOTAL_TRIES).
    static let totalTries = 100_000

    /// Escolhe as moedas. Devolve `nil` quando nem todas juntas pagam o envio.
    static func select(_ coins: [UTXOSelectionCoin], _ p: UTXOSelectionParameters) -> UTXOSelectionResult? {
        let usable = coins.filter { $0.effectiveValue > 0 }
        var options = [UTXOSelectionResult]()

        if let bnb = branchAndBound(usable, p) { options.append(bnb) }

        // Com troco: o troco precisa sair viavel depois de pagar a propria saida.
        let withChangeTarget = p.target + p.changeOutputFee + p.minViableChange
        let largestFirst = usable.sorted { ($0.effectiveValue, $1.id) > ($1.effectiveValue, $0.id) }
        if let accumulated = accumulate(largestFirst, until: withChangeTarget) {
            options.append(result(accumulated, withChange: true, p))
        }
        // A menor moeda que sozinha paga tudo com troco: uma entrada so, pouco rastro.
        if let single = usable.filter({ $0.effectiveValue >= withChangeTarget }).min(by: { ($0.effectiveValue, $0.id) < ($1.effectiveValue, $1.id) }) {
            options.append(result([single], withChange: true, p))
        }
        // Ultimo recurso: da para pagar, mas o troco nao sairia viavel. A sobra vira
        // taxa, e a tela mostra quanto.
        if options.isEmpty, let accumulated = accumulate(largestFirst, until: p.target) {
            options.append(result(accumulated, withChange: false, p))
        }
        return options.min { ($0.waste, $0.ids.count) < ($1.waste, $1.ids.count) }
    }

    private static func accumulate(_ ordered: [UTXOSelectionCoin], until target: Int64) -> [UTXOSelectionCoin]? {
        var total: Int64 = 0
        var picked = [UTXOSelectionCoin]()
        for coin in ordered {
            picked.append(coin)
            total += coin.effectiveValue
            if total >= target { return picked }
        }
        return nil
    }

    /// Desperdicio (GetSelectionWaste do Core): quanto se paga a mais por gastar
    /// estas entradas agora em vez de numa hora de taxa de longo prazo, mais o custo
    /// do troco ou a sobra que vira taxa.
    private static func result(_ picked: [UTXOSelectionCoin], withChange: Bool, _ p: UTXOSelectionParameters) -> UTXOSelectionResult {
        let inputs = picked.reduce(Int64(0)) { $0 + Int64($1.fee) - Int64($1.longTermFee) }
        let selected = picked.reduce(Int64(0)) { $0 + $1.effectiveValue }
        let tail = withChange ? p.costOfChange : selected - p.target
        return UTXOSelectionResult(ids: picked.map(\.id).sorted(), withChange: withChange, waste: inputs + tail)
    }

    /// Branch and Bound (Murch, "An Evaluation of Coin Selection Strategies"),
    /// transcrito de SelectCoinsBnB do Core: procura um conjunto cujo valor efetivo
    /// fique entre `target` e `target + costOfChange`, que dispensa troco.
    static func branchAndBound(_ coins: [UTXOSelectionCoin], _ p: UTXOSelectionParameters) -> UTXOSelectionResult? {
        let pool = coins.sorted { ($0.effectiveValue, $1.id) > ($1.effectiveValue, $0.id) }
        guard !pool.isEmpty else { return nil }
        var available = pool.reduce(Int64(0)) { $0 + $1.effectiveValue }
        guard available >= p.target else { return nil }
        let feeRateIsHigh = pool[0].fee > pool[0].longTermFee

        var value: Int64 = 0
        var waste: Int64 = 0
        var selection = [Int]()
        var best: [Int]?
        var bestWaste = Int64.max
        var index = 0

        for _ in 0..<totalTries {
            var backtrack = false
            if value + available < p.target || value > p.target + p.costOfChange || (waste > bestWaste && feeRateIsHigh) {
                backtrack = true
            } else if value >= p.target {
                let total = waste + (value - p.target)
                if total <= bestWaste {
                    best = selection
                    bestWaste = total
                }
                backtrack = true
            }

            if backtrack {
                guard let last = selection.last else { break }
                // Devolve ao "disponivel" as moedas puladas depois da ultima incluida
                // e passa a explorar o ramo que exclui a ultima incluida.
                index -= 1
                while index > last {
                    available += pool[index].effectiveValue
                    index -= 1
                }
                let coin = pool[index]
                value -= coin.effectiveValue
                waste -= Int64(coin.fee) - Int64(coin.longTermFee)
                selection.removeLast()
            } else {
                let coin = pool[index]
                available -= coin.effectiveValue
                let previousExcluded = !selection.isEmpty && selection.last != index - 1
                let sameAsPrevious = index > 0 && coin.effectiveValue == pool[index - 1].effectiveValue && coin.fee == pool[index - 1].fee
                // Moeda igual a anterior que foi excluida daria o mesmo ramo: pula.
                if selection.isEmpty || !previousExcluded || !sameAsPrevious {
                    selection.append(index)
                    value += coin.effectiveValue
                    waste += Int64(coin.fee) - Int64(coin.longTermFee)
                }
            }
            index += 1
        }

        guard let found = best else { return nil }
        let picked = found.map { pool[$0] }
        return result(picked, withChange: false, p)
    }
}
