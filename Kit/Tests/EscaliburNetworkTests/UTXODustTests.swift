import EscaliburChains
import Foundation
import Testing
@testable import EscaliburNetwork

@Suite("UTXO: poeira nao trava o envio")
struct UTXODustTests {
    func claim(_ seed: UInt8, _ value: UInt64) -> UTXOUnspentClaim {
        UTXOUnspentClaim(outpoint: UTXOOutpoint(txid: UTXOTxID(bytes: [UInt8](repeating: seed, count: 32))!, vout: 0), claimedValue: value, height: 1)
    }

    func address(_ index: UInt32) -> UTXODerivedAddress {
        UTXODerivedAddress(address: "a\(index)", path: DerivationPath(components: [index]), publicKey: [], scriptPubKey: [], isChange: false, index: index)
    }

    @Test("Abaixo do minimo fica de fora sem ser baixada; so as maiores ate o teto sao conferidas")
    func selection() {
        let dust = (0..<300).map { claim(UInt8($0 % 250), 546) }
        let listed = [
            (address(0), [claim(251, 90_000)] + dust),
            (address(1), [claim(252, 5_000), claim(253, 700_000)]),
        ]
        let (kept, skipped) = UTXOReader.selectClaims(listed, minimumValue: 1_000, maxCoins: 2)
        let keptValues = kept.flatMap { $0.1 }.map(\.claimedValue).sorted()
        #expect(keptValues == [90_000, 700_000])
        #expect(skipped.filter { $0.reason == .uneconomic }.count == 300)
        #expect(skipped.filter { $0.reason == .overLimit }.map(\.outpoint) == [claim(252, 5_000).outpoint])
        // Cada moeda mantida continua no endereco dela (a chave que assina e a dele).
        #expect(kept[0].1.map(\.claimedValue) == [90_000])
        #expect(kept[1].1.map(\.claimedValue) == [700_000])
    }

    @Test("Sem minimo e com teto folgado, nada fica de fora")
    func noFilter() {
        let listed = [(address(0), [claim(1, 10), claim(2, 20)])]
        let (kept, skipped) = UTXOReader.selectClaims(listed, minimumValue: 0, maxCoins: 200)
        #expect(kept[0].1.count == 2)
        #expect(skipped.isEmpty)
    }
}
