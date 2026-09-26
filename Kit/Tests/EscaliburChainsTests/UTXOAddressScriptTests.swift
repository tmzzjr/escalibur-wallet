import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// Do endereco ao scriptPubKey que recebe o dinheiro. Um byte errado aqui manda o
/// valor para um script que ninguem gasta.
@Suite("UTXO endereco e script")
struct UTXOAddressScriptTests {
    @Test("BIP-173 e BIP-350: enderecos segwit validos viram o script do BIP")
    func segwitValid() throws {
        // bitcoin/bips bip-0350.mediawiki e bip-0173.mediawiki, secoes "Test vectors"
        // e "Examples" (so os de rede principal).
        let vectors = [
            ("BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4", "0014751e76e8199196d454941c45d1b3a323f1433bd6"),
            ("bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3", "00201863143c14c5166804bd19203356da136c985678cd4d27a1b8c6329604903262"),
            ("bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0", "512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"),
        ]
        for (address, script) in vectors {
            let built = try UTXOScript.scriptPubKey(for: address, chain: .bitcoin)
            #expect(built.hex == script, "\(address)")
            #expect(UTXOScript.address(for: built, chain: .bitcoin) == address.lowercased())
        }
    }

    @Test("BIP-350: programas validos mas fora do que a carteira paga sao recusados")
    func segwitUnsupported() {
        // Validos pelo BIP-350, mas v1 com 40 bytes, v2 e v16 nao tem regra de gasto
        // hoje: dinheiro mandado para la fica a merce de um soft fork futuro.
        for address in [
            "bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kw508d6qejxtdg4y5r3zarvary0c5xw7kt5nd6y",
            "BC1SW50QGDZ25J",
            "bc1zw508d6qejxtdg4y5r3zarvaryvaxxpcs",
        ] {
            #expect(throws: Address.Problem.unsupportedType) { try UTXOScript.scriptPubKey(for: address, chain: .bitcoin) }
        }
    }

    @Test("BIP-350 e BIP-173: enderecos invalidos de rede principal sao recusados")
    func segwitInvalid() {
        let invalid = [
            // BIP-350
            "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqh2y7hd",
            "BC1S0XLXVLHEMJA6C4DQV22UAPCTQUPFHLXM9H8Z3K2E72Q4K9HCZ7VQ54WELL",
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kemeawh",
            "bc1p38j9r5y49hruaue7wxjce0updqjuyyx0kh56v8s25huc6995vvpql3jow4",
            "BC130XLXVLHEMJA6C4DQV22UAPCTQUPFHLXM9H8Z3K2E72Q4K9HCZ7VQ7ZWS8R",
            "bc1pw5dgrnzv",
            "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7v8n0nx0muaewav253zgeav",
            "BC1QR508D6QEJXTDG4Y5R3ZARVARYV98GJ9P",
            "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7v07qwwzcrf",
            "bc1gmk9yu",
            // BIP-173
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5",
            "BC13W508D6QEJXTDG4Y5R3ZARVARY0C5XW7KN40WF2",
            "bc1rw5uspcuh",
            "bc10w508d6qejxtdg4y5r3zarvary0c5xw7kw508d6qejxtdg4y5r3zarvary0c5xw7kw5rljs90",
            "bc1zw508d6qejxtdg4y5r3zarvaryvqyzf3du",
            // Validos no BIP-173 original, invalidos desde o BIP-350: v1+ em Bech32.
            "bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kw508d6qejxtdg4y5r3zarvary0c5xw7k7grplx",
            "BC1SW50QA3JX3S",
            "bc1zw508d6qejxtdg4y5r3zarvaryvg6kdaj",
        ]
        for address in invalid {
            #expect(throws: (any Error).self, "\(address)") { try UTXOScript.scriptPubKey(for: address, chain: .bitcoin) }
        }
    }

    @Test("key_io_valid.json do Bitcoin Core: enderecos de rede principal")
    func coreKeyIO() throws {
        // Fonte: bitcoin/bitcoin src/test/data/key_io_valid.json (Fixtures/utxo/key-io-main.json).
        let root = try #require(try UTXOFixtures.json("key-io-main") as? [String: Any])
        let vectors = try #require(root["vectors"] as? [[String]])
        #expect(vectors.count == 14)
        var paid = 0
        for vector in vectors {
            let (address, script) = (vector[0], vector[1])
            if script.hasPrefix("52") {
                // Witness v2: valido, mas a carteira nao paga.
                #expect(throws: Address.Problem.unsupportedType) { try UTXOScript.scriptPubKey(for: address, chain: .bitcoin) }
                continue
            }
            let built = try UTXOScript.scriptPubKey(for: address, chain: .bitcoin)
            #expect(built.hex == script, "\(address)")
            #expect(UTXOScript.address(for: built, chain: .bitcoin) == address)
            paid += 1
        }
        #expect(paid == 12)
    }

    @Test("Litecoin e Dogecoin: script de cada tipo, e endereco de outra rede recusado")
    func litecoinDogecoin() throws {
        // Enderecos de "abandon x11 about" (os mesmos do AddressVectorTests).
        let ltc = try UTXOScript.scriptPubKey(for: "ltc1qjmxnz78nmc8nq77wuxh25n2es7rzm5c2rkk4wh", chain: .litecoin)
        #expect(UTXOScript.classify(ltc)?.type == .p2wpkh)
        #expect(UTXOScript.address(for: ltc, chain: .litecoin) == "ltc1qjmxnz78nmc8nq77wuxh25n2es7rzm5c2rkk4wh")
        let doge = try UTXOScript.scriptPubKey(for: "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC", chain: .dogecoin)
        #expect(UTXOScript.classify(doge)?.type == .p2pkh)
        #expect(UTXOScript.address(for: doge, chain: .dogecoin) == "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC")

        // Litecoin P2SH: so a forma nova (M, 0x32) e aceita. A antiga (3, 0x05) e
        // identica ao P2SH do Bitcoin, e aceitar faria um endereco de Bitcoin colado
        // na tela de LTC passar sem aviso; ela e recusada como endereco de Bitcoin.
        let hash = [UInt8](repeating: 0x42, count: 20)
        let modern = Base58.bitcoin.encodeCheck([0x32] + hash)
        let legacy = Base58.bitcoin.encodeCheck([0x05] + hash)
        #expect(modern.hasPrefix("M"))
        #expect(try UTXOScript.scriptPubKey(for: modern, chain: .litecoin) == UTXOScript.p2sh(hash))
        #expect(throws: Address.Problem.otherNetwork(.bitcoin)) { try UTXOScript.scriptPubKey(for: legacy, chain: .litecoin) }
        #expect(UTXOScript.address(for: UTXOScript.p2sh(hash), chain: .litecoin) == modern)

        // Dogecoin P2SH (0x16) e sem segwit.
        let dogeP2SH = Base58.bitcoin.encodeCheck([0x16] + hash)
        #expect(try UTXOScript.scriptPubKey(for: dogeP2SH, chain: .dogecoin) == UTXOScript.p2sh(hash))
        #expect(UTXOScript.address(for: UTXOScript.p2wpkh(hash), chain: .dogecoin) == nil)

        // Endereco de Bitcoin na tela de Litecoin: recusado com o nome da outra rede.
        #expect(throws: Address.Problem.otherNetwork(.bitcoin)) {
            try UTXOScript.scriptPubKey(for: "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu", chain: .litecoin)
        }
        #expect(throws: Address.Problem.otherNetwork(.dogecoin)) {
            try UTXOScript.scriptPubKey(for: "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC", chain: .bitcoin)
        }
    }

    @Test("Dust por tipo de script e tamanho das entradas")
    func dustAndSizes() {
        // Bitcoin Core, policy.cpp GetDustThreshold com dustrelayfee 3 sat/vB.
        let btc = UTXOParams.for(.bitcoin)
        #expect(btc.dustThreshold(for: .p2pkh, chain: .bitcoin) == 546)
        #expect(btc.dustThreshold(for: .p2sh, chain: .bitcoin) == 540)
        #expect(btc.dustThreshold(for: .p2wpkh, chain: .bitcoin) == 294)
        #expect(btc.dustThreshold(for: .p2wsh, chain: .bitcoin) == 330)
        #expect(btc.dustThreshold(for: .p2tr, chain: .bitcoin) == 330)
        let ltc = UTXOParams.for(.litecoin)
        #expect(ltc.dustThreshold(for: .p2wpkh, chain: .litecoin) == 294)
        // Dogecoin: limite fixo de 0,01 DOGE.
        let doge = UTXOParams.for(.dogecoin)
        #expect(UTXOScriptType.allCases.allSatisfy { doge.dustThreshold(for: $0, chain: .dogecoin) == 1_000_000 })

        // vsize por entrada de docs/blockchain.md §2.1: 68, 91, 148.
        #expect((UTXOInputKind.p2wpkh.inputWeight + 3) / 4 == 68)
        #expect((UTXOInputKind.p2shP2wpkh.inputWeight + 3) / 4 == 91)
        #expect((UTXOInputKind.p2pkh.inputWeight + 3) / 4 == 148)
        // Uma entrada P2WPKH e duas saidas P2WPKH: 141 vB com assinatura de pior caso.
        #expect((UTXOSizing.weight(inputs: [.p2wpkh], outputs: [.p2wpkh, .p2wpkh]) + 3) / 4 == 141)
        // P2PKH puro, sem witness: 1 entrada e 2 saidas P2PKH, 226 bytes.
        #expect(UTXOSizing.weight(inputs: [.p2pkh], outputs: [.p2pkh, .p2pkh]) == 226 * 4)
    }

    @Test("Peso estimado cobre o peso real das transacoes assinadas")
    func estimateCoversReal() throws {
        // BIP-143 P2SH-P2WPKH: 1 entrada, 2 saidas P2PKH. A estimativa usa assinatura
        // de 72 bytes; a real tem 71, entao a estimativa fica 1 WU acima.
        let nested = try UTXOTransaction(hex: UTXOBIP143Vectors.nestedSigned)
        let estimate = UTXOSizing.weight(inputs: [.p2shP2wpkh], outputs: [.p2pkh, .p2pkh])
        #expect(estimate >= nested.weight)
        #expect(estimate - nested.weight <= 1)
    }
}
