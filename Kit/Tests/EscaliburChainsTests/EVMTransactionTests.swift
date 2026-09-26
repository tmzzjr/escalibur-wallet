import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

@Suite("EVM: transacoes")
struct EVMTransactionTests {
    typealias T = EVMTestSupport

    /// O exemplo do texto da EIP-155 (github.com/ethereum/EIPs, EIPS/eip-155.md,
    /// secao "Example"): nonce 9, 20 gwei, 21000, para 0x3535..., 1 ether, chave
    /// 0x4646...46. Assinado aqui com RFC 6979, que e deterministico, e comparado byte
    /// a byte com a transacao assinada publicada.
    @Test("EIP-155: exemplo da propria EIP, v = 37")
    func eip155Example() throws {
        let account = try T.account(T.testKey)
        let transaction = try EVMTransaction(
            chain: .ethereum, account: account, nonce: 9,
            fee: .legacy(gasPrice: BigUInt(20_000_000_000)), gasLimit: 21_000,
            to: T.address("0x3535353535353535353535353535353535353535"),
            value: BigUInt(decimal: "1000000000000000000")!, data: []
        )
        #expect(transaction.signingPayload.hex == "ec098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a764000080018080")
        #expect(transaction.signingDigest.hex == "daf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53")

        let signature = try T.sign(transaction.signingDigest, key: T.testKey)
        // v = recid + 35 + 2 * 1 = 37 no texto da EIP, entao recid = 0.
        #expect(signature.recoveryID == 0)
        #expect(BigUInt(bigEndian: signature.bytes.prefix(32)).decimalString == "18515461264373351373200002665853028612451056578545711640558177340181847433846")
        #expect(BigUInt(bigEndian: signature.bytes.suffix(32)).decimalString == "46948507304638947509940763649030358759909902576025900602547168820602576006531")

        let signed = try transaction.assemble(with: [signature])
        #expect(signed.encoded == "0xf86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83")
        // O byte 0x25 depois do valor e o v = 37.
        #expect(signed.raw[signed.raw.count - 67] == 0x25)
        #expect(signed.id == Hex.encode(Hash.keccak256(signed.raw), prefix: true))
        #expect(signed.id == "0x33469b22e9f636356c4160a87eb19df52b7412e8eac32a4a55ffe88ea8350788")
        #expect(signed.chainID == "ethereum")
    }

    /// Vetores de tipo 2 e de legado EIP-155 do ethers.js v6 (ethers-io/ethers.js,
    /// testcases/transactions.json.gz, colunas unsignedLondon/signedLondon e
    /// unsignedEip155/signedEip155). Subconjunto em Fixtures/evm/ethers-transactions.json.
    /// A assinatura sai daqui, com a chave do vetor, e tem de reproduzir o ethers byte
    /// a byte.
    @Test("Tipo 2 e EIP-155: vetores do ethers.js")
    func ethersVectors() throws {
        let vectors = try T.vectors("ethers-transactions")
        #expect(vectors.count >= 40)
        for vector in vectors {
            let name = vector["name"] as! String
            let key = String((vector["privateKey"] as! String).dropFirst(2))
            func field(_ key: String) -> BigUInt { T.big(vector[key] as! String) }
            let to = T.bytes(vector["to"] as! String)
            let data = T.bytes(vector["data"] as! String)

            let london = EVMTransactionFields(
                chainID: field("chainId"), nonce: field("nonce"),
                fee: .eip1559(maxPriorityFeePerGas: field("maxPriorityFeePerGas"), maxFeePerGas: field("maxFeePerGas")),
                gasLimit: field("gasLimit"), to: to, value: field("value"), data: data
            )
            #expect(Hex.encode(london.signingPayload, prefix: true) == vector["unsignedLondon"] as? String, "\(name) tipo 2 sem assinatura")
            let londonSignature = try T.sign(london.signingDigest, key: key)
            let londonSigned = london.signed(recoveryID: londonSignature.recoveryID!, r: Array(londonSignature.bytes.prefix(32)), s: Array(londonSignature.bytes.suffix(32)))
            #expect(Hex.encode(londonSigned, prefix: true) == vector["signedLondon"] as? String, "\(name) tipo 2 assinada")

            let legacy = EVMTransactionFields(
                chainID: field("chainId"), nonce: field("nonce"), fee: .legacy(gasPrice: field("gasPrice")),
                gasLimit: field("gasLimit"), to: to, value: field("value"), data: data
            )
            #expect(Hex.encode(legacy.signingPayload, prefix: true) == vector["unsignedEip155"] as? String, "\(name) EIP-155 sem assinatura")
            let legacySignature = try T.sign(legacy.signingDigest, key: key)
            let legacySigned = legacy.signed(recoveryID: legacySignature.recoveryID!, r: Array(legacySignature.bytes.prefix(32)), s: Array(legacySignature.bytes.suffix(32)))
            #expect(Hex.encode(legacySigned, prefix: true) == vector["signedEip155"] as? String, "\(name) EIP-155 assinada")
        }
    }

    @Test("O chainId sai da rede compilada, em todas as sete")
    func chainIDFromChain() throws {
        let account = try T.account(T.testKey)
        let expected: [(Chain, UInt64)] = [(.ethereum, 1), (.arbitrum, 42161), (.base, 8453), (.optimism, 10), (.polygon, 137), (.bnb, 56), (.avalanche, 43114)]
        for (chain, id) in expected {
            let transaction = try EVMTransaction(
                chain: chain, account: account, nonce: 0, fee: .eip1559(maxPriorityFeePerGas: 1, maxFeePerGas: 2),
                gasLimit: 21_000, to: T.address("0x3535353535353535353535353535353535353535"), value: 1, data: []
            )
            #expect(transaction.chainID == id)
            // O primeiro item da lista RLP do tipo 2 e o chainId.
            let expectedPrefix = RLP.uint(BigUInt(id)).encoded
            let body = Array(transaction.signingPayload.dropFirst(2))
            #expect(Array(body.prefix(expectedPrefix.count)) == expectedPrefix)
            #expect(transaction.signingPayload.first == 0x02)
            #expect(transaction.signingRequests.count == 1)
            #expect(transaction.signingRequests[0].scheme == .ecdsaRecoverable)
            #expect(transaction.signingRequests[0].expectedPublicKey == account.publicKey)
        }
        #expect(throws: EVMTransactionError.notEVMChain) {
            try EVMTransaction(chain: .bitcoin, account: account, nonce: 0, fee: .legacy(gasPrice: 1), gasLimit: 21_000,
                               to: .zero, value: 0, data: [])
        }
        #expect(throws: EVMTransactionError.gasLimitOutOfRange) {
            try EVMTransaction(chain: .ethereum, account: account, nonce: 0, fee: .legacy(gasPrice: 1), gasLimit: 16_777_217,
                               to: .zero, value: 0, data: [])
        }
    }

    @Test("Tipo 2 de ponta a ponta: yParity, hash e recusa de assinatura errada")
    func type2EndToEnd() throws {
        let account = try T.account(T.testKey)
        let transaction = try EVMTransaction(
            chain: .base, account: account, nonce: 7,
            fee: .eip1559(maxPriorityFeePerGas: BigUInt(1_000_000), maxFeePerGas: BigUInt(20_000_000)),
            gasLimit: 21_000, to: T.address("0x3535353535353535353535353535353535353535"),
            value: BigUInt(12_345), data: []
        )
        let signature = try T.sign(transaction.signingDigest, key: T.testKey)
        let signed = try transaction.assemble(with: [signature])
        #expect(signed.raw.first == 0x02)
        #expect(signed.id == Hex.encode(Hash.keccak256(signed.raw), prefix: true))
        #expect(signed.encoded == Hex.encode(signed.raw, prefix: true))
        // A assinatura fica no fim: yParity (0x80 ou 0x01), r e s.
        let fields = transaction.fields
        let expected = fields.signed(recoveryID: signature.recoveryID!, r: Array(signature.bytes.prefix(32)), s: Array(signature.bytes.suffix(32)))
        #expect(signed.raw == expected)

        // Id de recuperacao trocado: a chave recuperada nao e a da conta.
        let flipped = ProducedSignature(bytes: signature.bytes, recoveryID: signature.recoveryID! ^ 1)
        #expect(throws: SigningError.malformedSignature) { try transaction.assemble(with: [flipped]) }
        // s alto (n - s) e recusado pela EIP-2.
        let n = BigUInt(bigEndian: [UInt8](hex: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")!)
        let highS = (n - BigUInt(bigEndian: signature.bytes.suffix(32))).bigEndianBytes(padTo: 32)!
        let malleable = ProducedSignature(bytes: Array(signature.bytes.prefix(32)) + highS, recoveryID: signature.recoveryID! ^ 1)
        #expect(throws: SigningError.malformedSignature) { try transaction.assemble(with: [malleable]) }
        #expect(throws: SigningError.wrongSignatureCount) { try transaction.assemble(with: []) }
        #expect(throws: SigningError.malformedSignature) {
            try transaction.assemble(with: [ProducedSignature(bytes: signature.bytes, recoveryID: nil)])
        }
        // Assinatura de outra chave.
        let other = try T.sign(transaction.signingDigest, key: "0101010101010101010101010101010101010101010101010101010101010101")
        #expect(throws: SigningError.malformedSignature) { try transaction.assemble(with: [other]) }
    }
}
