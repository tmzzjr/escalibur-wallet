import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

/// Vetores oficiais da Sui: transacoes que o wallet-core da Trust Wallet montou,
/// assinou e a rede principal aceitou (trustwallet/wallet-core, commit
/// bbb99135847aa71898f085a6c681e3fbb162e530, `rust/tw_tests/tests/chains/sui/sui_sign.rs`
/// e `test_cases.rs`). O Ed25519 da Trust e deterministico e o do CryptoKit nao: o teste
/// confere a mensagem (o digesto que a chave assina) e que a assinatura publicada verifica
/// sobre ele, nunca compara assinatura nova com a publicada.
@Suite("Sui transacao")
struct SuiTransactionTests {
    struct Vector {
        let name: String
        let transaction: String
        let signature: String
        /// O digesto que o explorador mostra (o link "Successfully broadcasted" do teste).
        let digest: String
        let privateKey: String
    }

    static let key54e8 = "7e6682f7bf479ef0f627823cffd4e1a940a7af33e5fb39d9e0f631d2ecc5daff"
    static let sender54e8 = "0x54e80d76d790c277f5a44f3ce92f53d26f5894892bf395dee6375988876be6b2"

    static let vectors: [Vector] = [
        // test_sui_sign_direct_transfer: o layout exato do envio da Escalibur.
        Vector(
            name: "sign_direct_transfer",
            transaction: "AAACAAgQJwAAAAAAAAAgJZ/4B0q0Jcu0ifI24Y4I8D8aeFa998eih3vWT3OLUBUCAgABAQAAAQEDAAAAAAEBANV1rX8Y6UhGKlz2mPVk7zlKdSpx/sYkk6+KBVwBLA1QAQbywsjB2JZN8QGdZhbpcFcZvrq9kx2idVy5SM635olk7AIAAAAAAAAgYEVuxmf1zRBGdoDr+VDtMpIFF12s2Ua7I2ru1XyGF8/Vda1/GOlIRipc9pj1ZO85SnUqcf7GJJOvigVcASwNUAEAAAAAAAAA0AcAAAAAAAAA",
            signature: "APxPduNVvHj2CcRcHOtiP2aBR9qP3vO2Cb0g12PI64QofDB6ks33oqe/i/iCTLcop2rBrkczwrayZuJOdi7gvwNqfN7sFqdcD/Z4e8I1YQlGkDMCK7EOgmydRDqfH8C9jg==",
            digest: "HkPo6rYPyDY53x1MBszvSZVZyixVN7CHvCJGX381czAh",
            privateKey: "3823dce5288ab55dd1c00d97e91933c613417fdb282a0b8b01a7f5f5a533b266"
        ),
        // transfer_d4ay9tdb: PaySui para dois destinos.
        Vector(
            name: "transfer_d4ay9tdb",
            transaction: "AAAEAAjoAwAAAAAAAAAIUMMAAAAAAAAAIKcXWr3V7ZLr4605DbNmxqcGR4zfUXzebPmGMAZc2jd6ACBU6A1215DCd/WkTzzpL1PSb1iUiSvzld7mN1mIh2vmsgMCAAIBAAABAQABAQMAAAAAAQIAAQEDAAABAAEDAFToDXbXkMJ39aRPPOkvU9JvWJSJK/OV3uY3WYiHa+ayAWNgILOn3HsRw6pvQZsX+KnBLn95ox0b3S3mcLTt1jAFeHEaBQAAAAAgGGuNnxrqusosgjP3gQ3jBjnhapGNBlcU0yTaupXpa0BU6A1215DCd/WkTzzpL1PSb1iUiSvzld7mN1mIh2vmsu4CAAAAAAAAwMYtAAAAAAAA",
            signature: "AEh44B7iGArEHF1wOLAQJMLNgGnaIwn3gKPC92vtDJqITDETAM5z9plaxio1xomt6/cZReQ5FZaQsMC6l7E0BwmF69FEH+T5VPvl3GB3vwCOEZpeJpKXxvcIPQAdKsh2/g==",
            digest: "D4Ay9TdBJjXkGmrZSstZakpEWskEQHaWURP6xWPRXbAm",
            privateKey: key54e8
        ),
        // test_sui_sign_split_sui: PaySui para tres destinos.
        Vector(
            name: "split_sui",
            transaction: "AAAEAAjwSQIAAAAAAAAIQA0DAAAAAAAACKCGAQAAAAAAACBU6A1215DCd/WkTzzpL1PSb1iUiSvzld7mN1mIh2vmsgICAAMBAAABAQABAgABAwMAAAAAAwAAAQADAAACAAEDAFToDXbXkMJ39aRPPOkvU9JvWJSJK/OV3uY3WYiHa+ayAWNgILOn3HsRw6pvQZsX+KnBLn95ox0b3S3mcLTt1jAFxYoeBQAAAAAg6qe+uHxDnn7q4cupb3Z1reQK3m4sh6efYtcz8fWA6C9U6A1215DCd/WkTzzpL1PSb1iUiSvzld7mN1mIh2vmsu4CAAAAAAAAwM9qAAAAAAAA",
            signature: "AAN/lP/bRRsgdDS/QCSl45D5gHdKv4Aow0Hmkcot6w+84vd2X+nvOgxyYo2BMInBIbsCqlOtnn8t9zo2+dNSegGF69FEH+T5VPvl3GB3vwCOEZpeJpKXxvcIPQAdKsh2/g==",
            digest: "GNoQj54Ra8qGbzbvD25KXEYTsRDKTH5SSjLtHftGNwBM",
            privateKey: key54e8
        ),
        // test_sui_sign_merge_sui: Pay com MergeCoins de duas moedas e gas a parte.
        Vector(
            name: "merge_sui",
            transaction: "AAAEAQAQIFS3Z2pGsbrnJBNNyWLbcp8ziaz3nT1vPCe6AYoEBMaKHgUAAAAAIP0+kx97Pe9YDREgUkz6oiMWshB9Lmh378kj8zPFQKydAQDztVqI/mMf3HeGIcM0lB3YJFNzb6Asf27/1EQcOKgFzMaKHgUAAAAAIIxpeFeM16YQBcGe5g1g/yPrBg49nG7O3ONFnBMQpao8AAiQ0AMAAAAAAAAgVOgNdteQwnf1pE886S9T0m9YlIkr85Xe5jdZiIdr5rIDAwEAAAEBAQACAQAAAQECAAEBAwEAAAABAwBU6A1215DCd/WkTzzpL1PSb1iUiSvzld7mN1mIh2vmsgFjYCCzp9x7EcOqb0GbF/ipwS5/eaMdG90t5nC07dYwBcuKHgUAAAAAIP8OWIzz7zyhJZG6luM+fwC+wc/3IWtHtGWeD/6h5YNwVOgNdteQwnf1pE886S9T0m9YlIkr85Xe5jdZiIdr5rLuAgAAAAAAAAAJPQAAAAAAAA==",
            signature: "AAjKOQKQuLYdWN798F50O0dtLtRWsAa6bl/C4xJHnJaEIpRbYdhlxRXXfcSDpB6/YI14YU5P+auk6KsFGOBZmg2F69FEH+T5VPvl3GB3vwCOEZpeJpKXxvcIPQAdKsh2/g==",
            digest: "68wBKsZyYXmCUydDmabQ71kTcFWTfDG7tFmTLk1HgNdN",
            privateKey: key54e8
        ),
        // test_sui_sign_transfer_all_sui: TransferObjects(GasCoin) com tres moedas de gas.
        Vector(
            name: "transfer_all_sui",
            transaction: "AAABACD4h+cHcBdVRRHnNtQ0JDY9qUbYqnSCJfawVGMKCxwK5QEBAQABAABU6A1215DCd/WkTzzpL1PSb1iUiSvzld7mN1mIh2vmsgMQIFS3Z2pGsbrnJBNNyWLbcp8ziaz3nT1vPCe6AYoEBMyKHgUAAAAAIInt9ZC5H/D+LXQVrm5FMVRbXYYja9DzMY7xtj9fmTgOY2Ags6fcexHDqm9Bmxf4qcEuf3mjHRvdLeZwtO3WMAXMih4FAAAAACBt7mQv2i7T+meqMktoDf8lCK0rhyCHnv7MB+dzIwEWXfQk6DbJFYxT5zYdJO2Bh17wa5iEZct1Vh4DX49C8A0zzIoeBQAAAAAgWhna69UsKB/zNdrxzcL1x4N3cD4QnQllvgrYmNa0dqdU6A1215DCd/WkTzzpL1PSb1iUiSvzld7mN1mIh2vmsu4CAAAAAAAAQEtMAAAAAAAA",
            signature: "AC+cq5DVVb97CpvtgbPer5tC1TpyItXPuvZsC7mQySyrVks/eymaovfZL62zCjtyjM2gpVGt2Hy8xDLIIb5YiAaF69FEH+T5VPvl3GB3vwCOEZpeJpKXxvcIPQAdKsh2/g==",
            digest: "3yNCCsiEFMyoNcsCniCcSQ9AFZY2WVoQWGa56fcd1nvh",
            privateKey: key54e8
        ),
    ]

    static func bytes(_ base64: String) throws -> [UInt8] {
        [UInt8](try #require(Data(base64Encoded: base64)))
    }

    static func publicKey(_ privateKey: String) throws -> [UInt8] {
        let seed = SecureBytes(capacity: 32)
        defer { seed.wipe() }
        seed.replaceAll(with: try #require([UInt8](hex: privateKey)))
        return try Ed25519.publicKey(of: seed)
    }

    static func address(_ text: String) throws -> SuiAddress {
        guard case .success(let address) = SuiAddress.parse(text) else { throw SuiTransactionError.malformed }
        return address
    }

    @Test("Transacoes transmitidas pelo wallet-core: BCS, digesto, mensagem assinada e remetente")
    func trustWalletVectors() throws {
        for vector in Self.vectors {
            let raw = try Self.bytes(vector.transaction)
            let data = try SuiTransactionData.decode(raw)
            #expect(data.bcs() == raw, "\(vector.name)")
            #expect(data.digestBase58 == vector.digest, "\(vector.name)")

            // flag 0x00 (Ed25519) || assinatura || chave publica.
            let signature = try Self.bytes(vector.signature)
            #expect(signature.count == 97 && signature[0] == 0x00)
            let publicKey = Array(signature.suffix(32))
            #expect(try Self.publicKey(vector.privateKey) == publicKey, "\(vector.name)")
            #expect(Ed25519.verify(signature: Array(signature[1..<65]), message: data.signingDigest, publicKey: publicKey), "\(vector.name)")
            #expect(try SuiAddress(ed25519PublicKey: publicKey) == data.sender, "\(vector.name)")
            #expect(data.gas.owner == data.sender)
        }
    }

    @Test("O digesto que a chave assina e o TX_HASH publicado (intencao 0, 0, 0 e BLAKE2b-256)")
    func signingDigest() throws {
        let raw = try Self.bytes(Self.vectors[1].transaction)
        // test_cases.rs, transfer_d4ay9tdb::TX_HASH.
        #expect(SuiTransactionData.signingDigest(of: raw).hex == "4c171457873befef70077461909ae40ac67bdad476b832b9c09b589cd698578f")
    }

    @Test("O envio da carteira monta os mesmos bytes do sign_direct_transfer")
    func payFromGasMatchesVector() throws {
        let sender = try Self.address("0xd575ad7f18e948462a5cf698f564ef394a752a71fec62493af8a055c012c0d50")
        let gasCoin = try SuiObjectRef(
            objectID: Self.address("0x06f2c2c8c1d8964df1019d6616e9705719bebabd931da2755cb948ceb7e68964"),
            version: 748, digestBase58: "7UoYeVzREVT17ZyYbRTsKzRCec5xJWm6FMh8AKaDPdDx"
        )
        let data = SuiTransactionData.payFromGas(
            sender: sender,
            recipient: try Self.address("0x259ff8074ab425cbb489f236e18e08f03f1a7856bdf7c7a2877bd64f738b5015"),
            amount: 10_000,
            gas: SuiGasData(payment: [gasCoin], owner: sender, price: 1, budget: 2_000),
            expiration: .none
        )
        #expect(data.bcs() == (try Self.bytes(Self.vectors[0].transaction)))
        #expect(data.digestBase58 == "HkPo6rYPyDY53x1MBszvSZVZyixVN7CHvCJGX381czAh")
        #expect(SuiPlanner.sendParameters(data)?.1 == 10_000)
    }

    @Test("Um PaySui de dois destinos montado campo a campo da os bytes do D4Ay9")
    func buildTwoRecipients() throws {
        let sender = try Self.address(Self.sender54e8)
        let data = SuiTransactionData(
            inputs: [
                .pure(UInt64(1_000).littleEndianByteArray), .pure(UInt64(50_000).littleEndianByteArray),
                .pure(try Self.address("0xa7175abdd5ed92ebe3ad390db366c6a706478cdf517cde6cf98630065cda377a").bytes),
                .pure(sender.bytes),
            ],
            commands: [
                .splitCoins(.gasCoin, amounts: [.input(0), .input(1)]),
                .transferObjects([.nestedResult(0, 0)], to: .input(2)),
                .transferObjects([.nestedResult(0, 1)], to: .input(3)),
            ],
            sender: sender,
            gas: SuiGasData(
                payment: [try SuiObjectRef(
                    objectID: Self.address("0x636020b3a7dc7b11c3aa6f419b17f8a9c12e7f79a31d1bdd2de670b4edd63005"),
                    version: 85_619_064, digestBase58: "2eKuWbZSVfpFVfg8FXY9wP6W5AFXnTchSoUdp7obyYZ5"
                )],
                owner: sender, price: 750, budget: 3_000_000
            ),
            expiration: .none
        )
        #expect(data.bcs() == (try Self.bytes(Self.vectors[1].transaction)))
    }

    @Test("Validade por epoca: variante 1 e a epoca em u64")
    func epochExpiration() throws {
        let base = try SuiTransactionData.decode(try Self.bytes(Self.vectors[0].transaction))
        let expiring = SuiTransactionData(inputs: base.inputs, commands: base.commands, sender: base.sender, gas: base.gas, expiration: .epoch(1_264))
        let bytes = expiring.bcs()
        #expect(Array(bytes.suffix(9)) == [0x01] + UInt64(1_264).littleEndianByteArray)
        #expect(try SuiTransactionData.decode(bytes) == expiring)
        #expect(expiring.digest != base.digest)
    }

    @Test("Leitura recusa chamada Move, objeto compartilhado, sobra e ULEB128 nao canonico")
    func decodeRefusals() throws {
        // test_sui_sign_undelegate_sui: MoveCall com objeto compartilhado.
        let moveCall = try Self.bytes("AAACAQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQEAAAAAAAAAAQEATTIRsVaaJCJtZyt95O2wj6nhm08C2rickjbk/IxKsS2wcSAFAAAAACA8frAQitBlYHSw54BYKrEOpjPNXZtUQcp8CBCgeteO2QEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMKc3VpX3N5c3RlbRZyZXF1ZXN0X3dpdGhkcmF3X3N0YWtlAAIBAAABAQBU6A1215DCd/WkTzzpL1PSb1iUiSvzld7mN1mIh2vmsgEQIFS3Z2pGsbrnJBNNyWLbcp8ziaz3nT1vPCe6AYoEBLFxIAUAAAAAIJAmR388UsDK20u66hpL0Yo017timzGO1w9bTx3rP9fAVOgNdteQwnf1pE886S9T0m9YlIkr85Xe5jdZiIdr5rLuAgAAAAAAAEBUiQAAAAAAAA==")
        #expect(throws: SuiTransactionError.unsupported) { try SuiTransactionData.decode(moveCall) }

        let raw = try Self.bytes(Self.vectors[0].transaction)
        #expect(throws: SuiTransactionError.malformed) { try SuiTransactionData.decode(raw + [0]) }
        #expect(throws: SuiTransactionError.malformed) { try SuiTransactionData.decode(Array(raw.dropLast())) }
        // A quantidade de entradas (2) escrita com um zero a mais: 0x82 0x00.
        var padded = raw
        padded.replaceSubrange(2..<3, with: [0x82, 0x00])
        #expect(throws: SuiTransactionError.malformed) { try SuiTransactionData.decode(padded) }
    }

    @Test("Transferencia assinada: bytes, assinatura serializada, id e conferencia antes de transmitir")
    func assembleAndParse() throws {
        let key = "3823dce5288ab55dd1c00d97e91933c613417fdb282a0b8b01a7f5f5a533b266"
        let publicKey = try Self.publicKey(key)
        let data = try SuiTransactionData.decode(try Self.bytes(Self.vectors[0].transaction))
        let transfer = try SuiTransfer(data: data, path: DerivationPath("m/44'/784'/0'/0'/0'")!, publicKey: publicKey)
        #expect(transfer.signingRequests.count == 1)
        #expect(transfer.signingRequests[0].payload == data.signingDigest)
        #expect(transfer.signingRequests[0].scheme == .ed25519)

        // A assinatura publicada da Trust, que verifica sobre o mesmo digesto.
        let published = try Self.bytes(Self.vectors[0].signature)
        let signed = try transfer.assemble(with: [ProducedSignature(bytes: Array(published[1..<65]))])
        #expect(signed.id == "HkPo6rYPyDY53x1MBszvSZVZyixVN7CHvCJGX381czAh")
        #expect(signed.raw == data.bcs() + published)
        #expect(signed.encoded == Self.vectors[0].transaction + "." + Self.vectors[0].signature)
        let parsed = try SuiSignedTransaction.parse(signed)
        #expect(parsed.data == data)
        #expect(parsed.signature == published)

        // Assinatura de outra mensagem, id trocado ou partes que nao batem: recusa.
        #expect(throws: SigningError.malformedSignature) {
            try transfer.assemble(with: [ProducedSignature(bytes: [UInt8](repeating: 1, count: 64))])
        }
        let wrongID = SignedTransaction(chainID: "sui", raw: signed.raw, encoded: signed.encoded, id: "D4Ay9TdBJjXkGmrZSstZakpEWskEQHaWURP6xWPRXbAm")
        #expect(throws: SuiTransactionError.malformed) { try SuiSignedTransaction.parse(wrongID) }
        var tampered = signed.raw
        tampered[10] ^= 1
        let mismatch = SignedTransaction(chainID: "sui", raw: tampered, encoded: signed.encoded, id: signed.id)
        #expect(throws: SuiTransactionError.malformed) { try SuiSignedTransaction.parse(mismatch) }

        // Chave que nao da o remetente: a transferencia nem nasce.
        #expect(throws: SuiPlanError.keyMismatch) {
            try SuiTransfer(data: data, path: DerivationPath("m/44'/784'/0'/0'/0'")!, publicKey: try Self.publicKey(Self.key54e8))
        }
    }
}
