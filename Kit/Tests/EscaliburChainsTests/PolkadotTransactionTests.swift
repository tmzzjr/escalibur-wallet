import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

enum PolkadotVectors {
    struct Real: Decodable {
        let extrinsic: String
        let hash: String
        let signer: String
        let publicKey: String
        let dest: String
        let amount: String
        let nonce: UInt32
        let era: String
        let birth: UInt64
        let birthHash: String
        let specVersion: UInt32
        let transactionVersion: UInt32
        let payload: String
    }

    struct PolkadotJS: Decodable {
        struct Case: Decodable {
            let seed: String
            let publicKey: String
            let signer: String
            let dest: String
            let amount: String
            let nonce: UInt32
            let blockNumber: UInt64
            let blockHash: String
            let era: String
            let call: String
            let payload: String
            let signature: String
            let extrinsic: String
            let hash: String
        }
        let genesis: String
        let specVersion: UInt32
        let transactionVersion: UInt32
        let casos: [Case]
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/polkadot"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    static func bytes(_ hex: String) -> [UInt8] { [UInt8](hex: hex)! }

    static func address(_ text: String) throws -> PolkadotAddress {
        guard case .success(let address) = PolkadotAddress.parse(text) else { throw PolkadotPlanError.invalidDestination(.malformed) }
        return address
    }
}

/// SCALE, era e a extrinsic assinada contra tres fontes: transferencias reais da rede
/// principal no runtime de hoje (a assinatura original verifica sobre o payload montado
/// aqui, e a extrinsic sai byte a byte igual), o polkadot-js com os metadados ao vivo, e
/// o wallet-core da Trust Wallet (uma transferencia transmitida na Kusama Asset Hub, com
/// as mesmas extensoes).
@Suite("Polkadot: SCALE, era e extrinsic")
struct PolkadotTransactionTests {
    @Test("Compactos da tabela do SCALE, e a forma nao minima recusada")
    func compact() throws {
        // docs.substrate.io, "SCALE encoding", tabela de `Compact`.
        let table: [(UInt64, String)] = [
            (0, "00"), (1, "04"), (42, "a8"), (63, "fc"), (64, "0101"), (69, "1501"), (16383, "fdff"),
            (16384, "02000100"), (65535, "feff0300"), (1_073_741_823, "feffffff"), (1_073_741_824, "0300000040"),
            (100_000_000_000_000, "0b00407a10f35a"),
        ]
        for (value, hex) in table {
            #expect(Hex.encode(PolkadotSCALE.compact(BigUInt(value))) == hex)
            var reader = PolkadotSCALE.Reader(PolkadotVectors.bytes(hex))
            #expect(try reader.compact() == BigUInt(value))
            try reader.requireEnd()
        }
        // u128 cheio (saldo maximo).
        let max = BigUInt(bigEndian: [UInt8](repeating: 0xFF, count: 16))
        #expect(Hex.encode(PolkadotSCALE.compact(max)) == "33" + String(repeating: "ff", count: 16))
        for bad in ["0100", "02000000", "0300000000", "03ffffff3f"] {
            var reader = PolkadotSCALE.Reader(PolkadotVectors.bytes(bad))
            #expect(throws: PolkadotSCALE.Failure.nonCanonical) { try reader.compact() }
        }
    }

    @Test("Era mortal: vetores do wallet-core e do polkadot-js, e a leitura de volta")
    func era() throws {
        // wallet-core, SignTransfer_9fd062: bloco 3.541.050, periodo 64, "a503".
        #expect(Hex.encode(PolkadotEra(period: 64, current: 3_541_050).encoded) == "a503")
        let vectors = try PolkadotVectors.load("polkadotjs-vetores", as: PolkadotVectors.PolkadotJS.self)
        for item in vectors.casos {
            #expect(Hex.encode(PolkadotEra(period: 64, current: item.blockNumber).encoded, prefix: true) == item.era)
        }
        let era = PolkadotEra(period: PolkadotRuntime.eraPeriod, current: 21_173_079)
        #expect(era.period == 256 && era.birth(current: 21_173_079) == 21_173_079 && era.death(current: 21_173_079) == 21_173_334)
        var reader = PolkadotSCALE.Reader(era.encoded)
        #expect(try PolkadotEra.decode(&reader) == era)
        var immortal = PolkadotSCALE.Reader([0x00])
        #expect(throws: PolkadotSCALE.Failure.nonCanonical) { try PolkadotEra.decode(&immortal) }
    }

    @Test("Transferencias reais da rede principal remontadas byte a byte")
    func realTransfers() throws {
        for real in try PolkadotVectors.load("transferencias-reais", as: [PolkadotVectors.Real].self) {
            let sender = try PolkadotVectors.address(real.signer)
            #expect(sender.accountID == PolkadotVectors.bytes(real.publicKey))
            let fields = PolkadotTransferFields(
                sender: sender, destination: try PolkadotVectors.address(real.dest), amount: BigUInt(decimal: real.amount)!,
                nonce: real.nonce, blockNumber: real.birth, blockHash: PolkadotVectors.bytes(real.birthHash),
                specVersion: real.specVersion, transactionVersion: real.transactionVersion, eraPeriod: 4096
            )
            #expect(Hex.encode(fields.era.encoded, prefix: true) == real.era)
            #expect(Hex.encode(fields.payload, prefix: true) == real.payload)
            #expect(fields.signingMessage == fields.payload)
            let raw = PolkadotVectors.bytes(real.extrinsic)
            let decoded = try PolkadotSignedExtrinsic.decode(raw)
            // A assinatura que a rede aceitou verifica sobre o payload montado aqui.
            #expect(Ed25519.verify(signature: decoded.signature, message: fields.signingMessage, publicKey: sender.accountID))
            #expect(fields.extrinsic(signature: decoded.signature) == raw)
            #expect(PolkadotSignedExtrinsic.id(of: raw) == real.hash)
            #expect(decoded.nonce == real.nonce && decoded.amount == fields.amount && decoded.destination == fields.destination)
        }
    }

    @Test("polkadot-js: chamada, payload e extrinsic com os metadados de hoje")
    func polkadotJS() throws {
        let vectors = try PolkadotVectors.load("polkadotjs-vetores", as: PolkadotVectors.PolkadotJS.self)
        #expect(PolkadotVectors.bytes(vectors.genesis) == PolkadotRuntime.genesisHash)
        #expect(vectors.transactionVersion == PolkadotRuntime.transactionVersion)
        for item in vectors.casos {
            let seed = SecureBytes(capacity: 32)
            defer { seed.wipe() }
            seed.replaceAll(with: PolkadotVectors.bytes(item.seed))
            let key = try Ed25519.publicKey(of: seed)
            #expect(Hex.encode(key, prefix: true) == item.publicKey)
            let fields = PolkadotTransferFields(
                sender: try #require(PolkadotAddress(accountID: key)), destination: try PolkadotVectors.address(item.dest),
                amount: BigUInt(decimal: item.amount)!, nonce: item.nonce, blockNumber: item.blockNumber,
                blockHash: PolkadotVectors.bytes(item.blockHash), specVersion: vectors.specVersion,
                transactionVersion: vectors.transactionVersion, eraPeriod: 64
            )
            #expect(Hex.encode(fields.call, prefix: true) == item.call)
            #expect(Hex.encode(fields.payload, prefix: true) == item.payload)
            let signature = Array(PolkadotVectors.bytes(item.signature).dropFirst())
            #expect(Ed25519.verify(signature: signature, message: fields.signingMessage, publicKey: key))
            let raw = fields.extrinsic(signature: signature)
            #expect(Hex.encode(raw, prefix: true) == item.extrinsic)
            #expect(PolkadotSignedExtrinsic.id(of: raw) == item.hash)
        }
    }

    @Test("wallet-core: transferencia transmitida na Kusama Asset Hub, com CheckMetadataHash")
    func trustWalletKusamaAssetHub() throws {
        // trustwallet/wallet-core, rust/tw_tests/tests/chains/polkadot/polkadot_sign.rs,
        // test_sign_transfer_kusama_asset_hub (transmitida: assethub-kusama.subscan.io,
        // 0xc3dd4b24...). Mesmas extensoes da Polkadot Asset Hub de hoje; a chamada e
        // transfer_allow_death (0a00), montada aqui a mao so para o vetor.
        let signed = PolkadotVectors.bytes("49028400bf14d379a6d161a3cfcbb12dc1ae6c9a5e89c9c22924060e8fecab41e6124acf00a26875c8f4f1760319ffaa1a4a44d0841fec3a7d7abf0c820ac931574e18cda960bedbc32886fc9d050b4ebf291db1ded94e6ee55cfb83372cc800fceeacea03f500040000000a000038858d284516bcf0991d66e09c18815afb33c22f1d0d29cf43be56debd5777610700046bf414")
        let publicKey = Array(signed[4..<36])
        let signature = Array(signed[37..<101])
        let destination = try #require(PolkadotAddress(accountID: Array(signed[signed.count - 38..<signed.count - 6])))
        let fields = PolkadotTransferFields(
            sender: try #require(PolkadotAddress(accountID: publicKey)), destination: destination, amount: 90_000_000_000,
            nonce: 1, blockNumber: 11_410_063, blockHash: PolkadotVectors.bytes("a08d580076533e7262904ea3105c7abb1923e10b4a44c2b8e2121fca23c99d63"),
            specVersion: 1_009_002, transactionVersion: 15, eraPeriod: 64,
            genesisHash: PolkadotVectors.bytes("48239ef607d7928874027a43a67689209727dfb3d3dc5e5b03a39bdc2eda771a")
        )
        let call = [UInt8]([0x0A, 0x00, 0x00]) + destination.accountID + PolkadotSCALE.compact(fields.amount)
        let payload = call + fields.explicitExtensions + fields.implicitExtensions
        #expect(Ed25519.verify(signature: signature, message: payload, publicKey: publicKey))
        let body = [UInt8]([0x84, 0x00]) + publicKey + [0x00] + signature + fields.explicitExtensions + call
        #expect(PolkadotSCALE.compact(BigUInt(body.count)) + body == signed)
    }

    @Test("Assinar e montar: a mesma mensagem, id do hash, e so a assinatura certa entra")
    func assemble() throws {
        let seed = SecureBytes(capacity: 32)
        defer { seed.wipe() }
        seed.replaceAll(with: [UInt8](repeating: 0x46, count: 32))
        let key = try Ed25519.publicKey(of: seed)
        let fields = PolkadotTransferFields(
            sender: try #require(PolkadotAddress(accountID: key)), destination: try PolkadotVectors.address(PolkadotAddressTests.alicePolkadot),
            amount: 5_000_000_000, nonce: 3, blockNumber: 21_173_079,
            blockHash: [UInt8](repeating: 7, count: 32), specVersion: 2_005_000, transactionVersion: 15
        )
        let transfer = PolkadotTransfer(fields: fields, path: DefaultPaths.path(for: .polkadot))
        let request = try #require(transfer.signingRequests.first)
        #expect(request.curve == .ed25519 && request.scheme == .ed25519 && request.expectedPublicKey == key)
        #expect(request.payload == fields.payload)
        let signature = try Ed25519.sign(request.payload, seed: seed)
        let signed = try transfer.assemble(with: [ProducedSignature(bytes: signature)])
        #expect(signed.chainID == "polkadot" && signed.encoded == Hex.encode(signed.raw, prefix: true))
        #expect(signed.id == Hex.encode(Blake2b.hash(signed.raw, outputLength: 32), prefix: true))
        let parsed = try PolkadotSignedExtrinsic.parse(signed)
        #expect(parsed.amount == 5_000_000_000 && parsed.nonce == 3 && parsed.era.period == 256)

        var wrong = signature
        wrong[0] ^= 1
        #expect(throws: SigningError.malformedSignature) { try transfer.assemble(with: [ProducedSignature(bytes: wrong)]) }
        #expect(throws: SigningError.wrongSignatureCount) { try transfer.assemble(with: []) }
    }

    @Test("Extrinsic fora do formato da carteira e recusada antes de sair")
    func parseRefusals() throws {
        let real = try PolkadotVectors.load("transferencias-reais", as: [PolkadotVectors.Real].self)[0]
        let raw = PolkadotVectors.bytes(real.extrinsic)
        func signed(_ bytes: [UInt8], id: String? = nil, chain: String = "polkadot") -> SignedTransaction {
            SignedTransaction(chainID: chain, raw: bytes, encoded: Hex.encode(bytes, prefix: true), id: id ?? PolkadotSignedExtrinsic.id(of: bytes))
        }
        #expect((try? PolkadotSignedExtrinsic.parse(signed(raw))) != nil)
        // Outra rede, id que nao e o hash, forma codificada diferente.
        #expect(throws: (any Error).self) { try PolkadotSignedExtrinsic.parse(signed(raw, chain: "kusama")) }
        #expect(throws: (any Error).self) { try PolkadotSignedExtrinsic.parse(signed(raw, id: real.hash.replacingOccurrences(of: "7b", with: "7c"))) }
        #expect(throws: (any Error).self) {
            try PolkadotSignedExtrinsic.parse(SignedTransaction(chainID: "polkadot", raw: raw, encoded: "0x00", id: PolkadotSignedExtrinsic.id(of: raw)))
        }
        // Byte a mais no fim (o tamanho declarado corrigido), chamada trocada, gorjeta e
        // assinatura sr25519.
        var trailing = Array(raw.dropFirst(2)) + [0x00]
        trailing = PolkadotSCALE.compact(BigUInt(trailing.count)) + trailing
        #expect(throws: (any Error).self) { try PolkadotSignedExtrinsic.parse(signed(trailing)) }
        let callOffset = raw.count - 35 - PolkadotSCALE.compact(BigUInt(decimal: real.amount)!).count
        var otherCall = raw
        otherCall[callOffset + 1] = 0x00
        #expect(throws: (any Error).self) { try PolkadotSignedExtrinsic.parse(signed(otherCall)) }
        var sr25519 = raw
        sr25519[36] = 0x01
        #expect(throws: (any Error).self) { try PolkadotSignedExtrinsic.parse(signed(sr25519)) }
        var tip = raw
        tip[callOffset - 3] = 0x04
        #expect(throws: (any Error).self) { try PolkadotSignedExtrinsic.parse(signed(tip)) }
    }
}
