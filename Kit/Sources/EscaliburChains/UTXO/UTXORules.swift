import EscaliburCore
import Foundation

/// Taxa por tamanho virtual, em satoshis por 1000 vbytes (sat/kvB).
///
/// A unidade do Bitcoin Core (`CFeeRate`). Guarda fracoes de sat/vB sem `Double`:
/// 0,644 sat/vB vira 644 sat/kvB. No Dogecoin, que nao tem segwit, vbyte e byte.
public struct UTXOFeeRate: Hashable, Comparable, Sendable, Codable {
    public let satPerKvB: UInt64

    public init(satPerKvB: UInt64) { self.satPerKvB = satPerKvB }

    public init(satPerVByte: UInt64) {
        let (value, overflow) = satPerVByte.multipliedReportingOverflow(by: 1000)
        satPerKvB = overflow ? .max : value
    }

    /// Taxa de um tamanho virtual, arredondada para cima como o `GetFee` do Core.
    /// Arredondar para baixo daria uma taxa efetiva abaixo da escolhida, e um no com
    /// piso exato recusaria a transacao.
    public func fee(virtualSize: Int) -> UInt64 {
        let (product, overflow) = satPerKvB.multipliedReportingOverflow(by: UInt64(max(0, virtualSize)))
        guard !overflow else { return .max }
        return product / 1000 + (product % 1000 == 0 ? 0 : 1)
    }

    /// Taxa de um peso (BIP-141): o tamanho virtual e o peso dividido por 4, para cima.
    public func fee(weight: Int) -> UInt64 { fee(virtualSize: (weight + 3) / 4) }

    public static func < (a: UTXOFeeRate, b: UTXOFeeRate) -> Bool { a.satPerKvB < b.satPerKvB }
}

/// Regras fixas de cada rede UTXO: literais compilados, nunca vindos de provedor.
public struct UTXORules: Sendable {
    /// Versao de transacao que a carteira cria.
    public let transactionVersion: UInt32
    public let segwit: Bool
    /// Piso de taxa. Abaixo disso a propagacao nao e garantida.
    public let minimumFeeRate: UTXOFeeRate
    /// Taxa de longo prazo, para medir o desperdicio na selecao de moedas: gastar uma
    /// entrada hoje custa `taxa atual`, gastar depois custaria esta.
    public let longTermFeeRate: UTXOFeeRate
    /// Teto absoluto de taxa por transacao. Acima disso e erro, nao escolha.
    public let maxAbsoluteFee: UInt64
    /// MAX_MONEY da rede: nenhum valor valido passa disso.
    public let maxMoney: UInt64
    /// Moedas ate este valor nao entram sozinhas na selecao (ver `protectionThreshold`).
    public let smallCoinFloor: UInt64
    /// Piso da taxa de descarte, a que mede quanto custara gastar um troco depois.
    public let discardFeeRateFloor: UTXOFeeRate

    /// dustrelayfee padrao do Bitcoin Core: 3 sat/vB. [W, docs/blockchain.md §2.1]
    public static let dustRelayFeePerVByte: UInt64 = 3

    /// Peso maximo de transacao padrao (MAX_STANDARD_TX_WEIGHT do Core). Acima disso
    /// os nos nao repassam.
    public static let maxStandardWeight = 400_000

    /// nSequence que sinaliza RBF (BIP-125) e mantem o nLockTime valendo.
    public static let rbfSequence: UInt32 = 0xFFFF_FFFD

    /// nLockTime abaixo disto e altura de bloco; acima, horario Unix.
    public static let lockTimeThreshold: UInt32 = 500_000_000

    public static func `for`(_ chain: Chain) -> UTXORules {
        switch chain.id {
        case Chain.litecoin.id:
            // Litecoin Core herda as politicas do Bitcoin Core: minrelay de 1 lit/vB,
            // maxtxfee de 0,1 LTC, MAX_MONEY de 84 milhoes. [P]
            return UTXORules(
                transactionVersion: 2, segwit: true,
                minimumFeeRate: UTXOFeeRate(satPerVByte: 1), longTermFeeRate: UTXOFeeRate(satPerVByte: 10),
                maxAbsoluteFee: 10_000_000, maxMoney: 84_000_000 * 100_000_000, smallCoinFloor: 1_000,
                discardFeeRateFloor: UTXOFeeRate(satPerVByte: dustRelayFeePerVByte)
            )
        case Chain.dogecoin.id:
            // Dogecoin Core 1.14: taxa recomendada 0,01 DOGE/kB (1000 koinu/B), dust
            // de 0,01 DOGE, MAX_MONEY de 10 bilhoes. Sem segwit. Versao 1, que e
            // padrao em qualquer no. [P]
            return UTXORules(
                transactionVersion: 1, segwit: false,
                minimumFeeRate: UTXOFeeRate(satPerKvB: 1_000_000), longTermFeeRate: UTXOFeeRate(satPerKvB: 1_000_000),
                maxAbsoluteFee: 100 * 100_000_000, maxMoney: 10_000_000_000 * 100_000_000, smallCoinFloor: 1_000,
                discardFeeRateFloor: UTXOFeeRate(satPerKvB: 1_000_000)
            )
        default:
            // Bitcoin: piso de 1 sat/vB (nos antigos ainda pedem 1; o Core 30 aceita
            // 0,1), taxa de consolidacao de 10 sat/vB (DEFAULT_CONSOLIDATE_FEERATE),
            // maxtxfee de 0,1 BTC (DEFAULT_TRANSACTION_MAXFEE). [W, docs/blockchain.md §2.1]
            return UTXORules(
                transactionVersion: 2, segwit: true,
                minimumFeeRate: UTXOFeeRate(satPerVByte: 1), longTermFeeRate: UTXOFeeRate(satPerVByte: 10),
                maxAbsoluteFee: 10_000_000, maxMoney: 21_000_000 * 100_000_000, smallCoinFloor: 1_000,
                discardFeeRateFloor: UTXOFeeRate(satPerVByte: dustRelayFeePerVByte)
            )
        }
    }

    /// Taxa com que se mede o custo de gastar o troco no futuro (`m_discard_feerate`
    /// do Core): a atual, limitada entre o piso de descarte e a de longo prazo.
    public func discardFeeRate(for feeRate: UTXOFeeRate) -> UTXOFeeRate {
        max(discardFeeRateFloor, min(feeRate, longTermFeeRate))
    }

    /// Moedas ate este valor ficam de fora da selecao automatica.
    ///
    /// Saidas de 330 ou 546 sats costumam carregar inscricao ou runa, e gasta-las
    /// como troco queima o ativo. O teto e o maior entre 1.000 unidades e o dust do
    /// tipo: no Dogecoin, onde o dust e 0,01 DOGE, a mesma protecao cobre as
    /// "doginals". O dono ainda pode gastar essas moedas escolhendo-as a mao.
    public func protectionThreshold(for kind: UTXOInputKind, chain: Chain) -> UInt64 {
        max(smallCoinFloor, UTXOParams.for(chain).dustThreshold(for: kind.outputType, chain: chain))
    }
}
