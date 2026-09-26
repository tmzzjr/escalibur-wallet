import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

/// Serializacao, txID, assinatura e TaPoS contra transacoes reais da mainnet.
///
/// Fonte dos vetores: Fixtures/tron/transacoes-mainnet.json, respostas cruas de
/// `POST https://api.trongrid.io/wallet/gettransactionbyid` (txIDs 40faad32...,
/// f9d62436..., 197d2038..., 94bd6f1f..., 8f0df00f...), mais os blocos citados pelo
/// TaPoS e os recibos. Numeros de campo: java-tron, protocol/src/main/protos/core/Tron.proto,
/// commit d5c3d1d1fd0cad12f09c4346d6ac937ab2cbb071.
@Suite("Tron: protobuf e vetores de mainnet")
struct TronProtobufTests {

    @Test("Varint: exemplos da documentacao do protobuf (encoding.md: 150 -> 96 01)")
    func varint() throws {
        var w = TronProtoWriter()
        w.varint(150)
        #expect(w.bytes == [0x96, 0x01])
        var big = TronProtoWriter()
        big.varint(UInt64(Int64.max))
        #expect(big.bytes == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        var reader = TronProtoReader([0x96, 0x01])
        #expect(try reader.readVarint() == 150)
        // Varint de 11 bytes e overflow no decimo byte sao recusados.
        var overlong = TronProtoReader([UInt8](repeating: 0xFF, count: 10) + [0x01])
        #expect(throws: TronProtobuf.Failure.self) { try overlong.readVarint() }
        var overflow = TronProtoReader([UInt8](repeating: 0xFF, count: 9) + [0x02])
        #expect(throws: TronProtobuf.Failure.self) { try overflow.readVarint() }
    }

    @Test("Raw montado dos campos do JSON reproduz raw_data_hex e txID de cada tx da mainnet")
    func serializationMatchesMainnet() throws {
        let transactions = try TronFixtures.transactions()
        #expect(transactions.count == 5)
        for tx in transactions {
            let raw = try TronFixtures.rawFromJSON(tx.rawData)
            #expect(Hex.encode(raw.serialized()) == tx.rawDataHex, "\(tx.note)")
            #expect(Hex.encode(raw.txID) == tx.txID, "\(tx.note)")
            // E o caminho inverso: decodificar o hex da o mesmo raw.
            #expect(try TronRawTransaction.decode(Hex.decode(tx.rawDataHex)!) == raw, "\(tx.note)")
        }
    }

    @Test("type_url e ContractType batem com a mainnet")
    func typeURLs() throws {
        for tx in try TronFixtures.transactions() {
            let contract = (tx.rawData["contract"] as! [[String: Any]])[0]
            let url = (contract["parameter"] as! [String: Any])["type_url"] as! String
            let raw = try TronRawTransaction.decode(Hex.decode(tx.rawDataHex)!)
            #expect(raw.contract.typeURL == url)
        }
        #expect(TronContract.transferTypeURL == "type.googleapis.com/protocol.TransferContract")
        #expect(TronContract.triggerSmartContractTypeURL == "type.googleapis.com/protocol.TriggerSmartContract")
    }

    @Test("A assinatura real recupera o dono, com v = 0x00, 0x1b ou 0x1c")
    func mainnetSignaturesRecoverOwner() throws {
        var seen = Set<UInt8>()
        for tx in try TronFixtures.transactions() {
            let raw = try TronRawTransaction.decode(Hex.decode(tx.rawDataHex)!)
            #expect(tx.signature.count == 65)
            let v = tx.signature[64]
            seen.insert(v)
            // java-tron Rsv.fromSignature: v < 27 e recid cru; senao recid + 27.
            let recid = v >= 27 ? v - 27 : v
            let key = try Secp256k1.recover(digest: raw.txID, compact: Array(tx.signature.prefix(64)), recoveryID: recid)
            #expect(try TronAddress(publicKey: key) == raw.contract.owner, "\(tx.note)")
        }
        #expect(seen.isSuperset(of: [0x00, 0x1B, 0x1C]))
    }

    @Test("assemble com a assinatura real reproduz os 65 bytes do TronWeb e o txID")
    func assembleMatchesMainnetSignature() throws {
        // As txs com v = 0x1b e 0x1c foram assinadas na forma do TronWeb (recid + 27),
        // a mesma que o assemble produz: os 65 bytes tem de sair identicos.
        for tx in try TronFixtures.transactions() where tx.signature[64] >= 27 {
            let raw = try TronRawTransaction.decode(Hex.decode(tx.rawDataHex)!)
            let recid = tx.signature[64] - 27
            let compact = Array(tx.signature.prefix(64))
            let publicKey = try Secp256k1.recover(digest: raw.txID, compact: compact, recoveryID: recid, compressed: true)
            let transaction = try TronTransaction(raw: raw, path: DefaultPaths.path(for: .tron), publicKey: publicKey)
            #expect(transaction.signingRequests.count == 1)
            #expect(transaction.signingRequests[0].payload == Hash.sha256(Hex.decode(tx.rawDataHex)!))
            #expect(transaction.signingRequests[0].scheme == .ecdsaRecoverable)

            let signed = try transaction.assemble(with: [ProducedSignature(bytes: compact, recoveryID: recid)])
            #expect(signed.id == tx.txID)
            #expect(signed.chainID == "tron")
            #expect(signed.encoded == Hex.encode(signed.raw))
            let decoded = try TronProtobuf.decodeSignedTransaction(signed.raw)
            #expect(decoded.raw == raw)
            #expect(decoded.signatures == [tx.signature])
            // Transaction { 1: raw, 2: signature }: 0a <len> raw 12 41 sig.
            let rawBytes = Hex.decode(tx.rawDataHex)!
            #expect(Array(signed.raw.suffix(67)) == [0x12, 0x41] + tx.signature)
            #expect(Array(signed.raw[3..<(3 + rawBytes.count)]) == rawBytes)
        }
    }

    @Test("assemble recusa assinatura de outra chave, de outro digesto ou mal formada")
    func assembleRejectsBadSignatures() throws {
        let txs = try TronFixtures.transactions()
        let first = txs[0]
        let raw = try TronRawTransaction.decode(Hex.decode(first.rawDataHex)!)
        let recid = first.signature[64] >= 27 ? first.signature[64] - 27 : first.signature[64]
        let compact = Array(first.signature.prefix(64))
        let publicKey = try Secp256k1.recover(digest: raw.txID, compact: compact, recoveryID: recid, compressed: true)
        let transaction = try TronTransaction(raw: raw, path: DefaultPaths.path(for: .tron), publicKey: publicKey)

        // Assinatura de outra transacao (outro digesto).
        let other = txs[1]
        let otherRecid = other.signature[64] >= 27 ? other.signature[64] - 27 : other.signature[64]
        #expect(throws: SigningError.malformedSignature) {
            try transaction.assemble(with: [ProducedSignature(bytes: Array(other.signature.prefix(64)), recoveryID: otherRecid)])
        }
        // recid trocado recupera outra chave.
        #expect(throws: SigningError.malformedSignature) {
            try transaction.assemble(with: [ProducedSignature(bytes: compact, recoveryID: recid ^ 1)])
        }
        #expect(throws: SigningError.malformedSignature) {
            try transaction.assemble(with: [ProducedSignature(bytes: compact, recoveryID: nil)])
        }
        #expect(throws: SigningError.malformedSignature) {
            try transaction.assemble(with: [ProducedSignature(bytes: first.signature, recoveryID: recid)])
        }
        #expect(throws: SigningError.wrongSignatureCount) { try transaction.assemble(with: []) }

        // Chave publica que nao e a dona do contrato: nem monta.
        let stranger = try Secp256k1.recover(digest: Hash.sha256(Hex.decode(other.rawDataHex)!),
                                             compact: Array(other.signature.prefix(64)), recoveryID: otherRecid, compressed: true)
        if try TronAddress(publicKey: stranger) != raw.contract.owner {
            #expect(throws: TronPlanError.ownerKeyMismatch) {
                try TronTransaction(raw: raw, path: DefaultPaths.path(for: .tron), publicKey: stranger)
            }
        }
    }

    @Test("TaPoS: bloco citado -> ref_block_bytes e ref_block_hash de cada tx da mainnet")
    func tapos() throws {
        let blocks = try TronFixtures.blocks()
        var matched = 0
        for tx in try TronFixtures.transactions() {
            let raw = try TronRawTransaction.decode(Hex.decode(tx.rawDataHex)!)
            for block in blocks {
                let reference = try TronBlockReference(number: block.number, idHex: block.id, timestamp: block.timestamp)
                if reference.refBlockBytes == raw.refBlockBytes {
                    #expect(reference.refBlockHash == raw.refBlockHash, "\(tx.note)")
                    matched += 1
                }
            }
        }
        #expect(matched == 5)

        // 86571717 = 0x0528FAC5: ref_block_bytes = fac5; id[8..<16] = 322285f2e2bfa4a1.
        let block = try TronBlockReference(
            number: 86_571_717, idHex: "000000000528fac5322285f2e2bfa4a1aceb9f47efdd4ef88bc85dde0d9c336b", timestamp: 1_790_387_544_000
        )
        #expect(Hex.encode(block.refBlockBytes) == "fac5")
        #expect(Hex.encode(block.refBlockHash) == "322285f2e2bfa4a1")
        // Bloco mais novo que o relogio: vale a hora do bloco; bloco atrasado: vale o relogio.
        #expect(block.expiration(now: 1_790_387_540_000) == 1_790_387_544_000 + 60_000)
        #expect(block.expiration(now: 1_790_387_574_000) == 1_790_387_574_000 + 60_000)

        // Numero de um bloco com id de outro: recusa.
        #expect(throws: TronPlanError.invalidBlockReference) {
            try TronBlockReference(number: 86_571_718, idHex: "000000000528fac5322285f2e2bfa4a1aceb9f47efdd4ef88bc85dde0d9c336b", timestamp: 1)
        }
        #expect(throws: TronPlanError.invalidBlockReference) {
            try TronBlockReference(number: 86_571_717, idHex: "000000000528fac5322285f2e2bfa4a1", timestamp: 1)
        }
    }

    @Test("Bandwidth calculada bate com o recibo da rede (net_usage e net_fee)")
    func bandwidthMatchesReceipts() throws {
        let receipts = try TronFixtures.receipts()
        for tx in try TronFixtures.transactions() {
            let raw = try TronRawTransaction.decode(Hex.decode(tx.rawDataHex)!)
            let bytes = TronTransaction.bandwidthBytes(of: raw)
            let receipt = try #require(receipts[tx.txID]).receipt
            if let usage = receipt["net_usage"] as? NSNumber {
                #expect(bytes == usage.uint64Value, "\(tx.note)")
            } else {
                // Sem cota: queimou bytes x 1.000 sun (getTransactionFee).
                #expect(bytes * 1_000 == (receipt["net_fee"] as! NSNumber).uint64Value, "\(tx.note)")
            }
        }
    }

    @Test("Memo: a tx 8f0df00f... pagou energy_fee + 1 TRX de getMemoFee")
    func memoFeeReceipt() throws {
        let id = "8f0df00f2adad2260b914df32e5a4f2a777b49b7cea75fd59cce098af38812fe"
        let entry = try #require(try TronFixtures.receipts()[id])
        let energyFee = (entry.receipt["energy_fee"] as! NSNumber).int64Value
        #expect(entry.fee == energyFee + 1_000_000)
        // 130.285 de energy a 100 sun (getEnergyFee).
        #expect(energyFee == 130_285 * 100)
        let tx = try #require(try TronFixtures.transactions().first { $0.txID == id })
        let raw = try TronRawTransaction.decode(Hex.decode(tx.rawDataHex)!)
        #expect(String(decoding: raw.memo, as: UTF8.self) == "202609260939444993")
    }

    @Test("Decodificacao estrita: contrato fora da lista, campo extra e forma nao canonica")
    func strictDecoding() throws {
        let tx = try TronFixtures.transactions()[0]
        let raw = try TronRawTransaction.decode(Hex.decode(tx.rawDataHex)!)
        let bytes = raw.serialized()

        // AccountPermissionUpdateContract (46) nao decodifica, nem com type_url coerente.
        var any = TronProtoWriter()
        any.bytes(1, Array("type.googleapis.com/protocol.AccountPermissionUpdateContract".utf8))
        any.bytes(2, [0x0A, 0x15] + raw.contract.owner.bytes)
        var contract = TronProtoWriter()
        contract.int64(1, 46)
        contract.message(2, any.bytes)
        var permissionUpdate = TronProtoWriter()
        permissionUpdate.bytes(1, raw.refBlockBytes)
        permissionUpdate.bytes(4, raw.refBlockHash)
        permissionUpdate.int64(8, UInt64(raw.expiration))
        permissionUpdate.message(11, contract.bytes)
        #expect(throws: TronProtobuf.Failure.unsupportedContract(type: 46)) {
            try TronRawTransaction.decode(permissionUpdate.bytes)
        }

        // TransferContract com type_url de TriggerSmartContract.
        var lying = TronProtoWriter()
        var lyingAny = TronProtoWriter()
        lyingAny.bytes(1, Array(TronContract.triggerSmartContractTypeURL.utf8))
        lyingAny.bytes(2, raw.contract.parameterValue())
        var lyingContract = TronProtoWriter()
        lyingContract.int64(1, 1)
        lyingContract.message(2, lyingAny.bytes)
        lying.bytes(1, raw.refBlockBytes)
        lying.bytes(4, raw.refBlockHash)
        lying.int64(8, UInt64(raw.expiration))
        lying.message(11, lyingContract.bytes)
        #expect(throws: TronProtobuf.Failure.self) { try TronRawTransaction.decode(lying.bytes) }

        // Campo 3 (ref_block_num) no raw: a carteira nao produz, nao aceita.
        #expect(throws: TronProtobuf.Failure.unexpectedField(message: "Transaction.raw", field: 3)) {
            try TronRawTransaction.decode(bytes + [0x18, 0x01])
        }
        // Dois contratos.
        var twice = TronProtoWriter()
        twice.message(11, raw.contract.serialized())
        #expect(throws: TronProtobuf.Failure.wrongContractCount(2)) {
            try TronRawTransaction.decode(bytes + twice.bytes)
        }
        // Campo repetido (expiration duas vezes).
        var dup = TronProtoWriter()
        dup.int64(8, 1)
        #expect(throws: TronProtobuf.Failure.self) { try TronRawTransaction.decode(bytes + dup.bytes) }
        // Fora de ordem decodifica os mesmos campos, mas nao reserializa igual.
        var reordered = TronProtoWriter()
        reordered.bytes(4, raw.refBlockHash)
        reordered.bytes(1, raw.refBlockBytes)
        reordered.int64(8, UInt64(raw.expiration))
        reordered.message(11, raw.contract.serialized())
        reordered.int64(14, UInt64(raw.timestamp))
        #expect(throws: TronProtobuf.Failure.notCanonical) { try TronRawTransaction.decode(reordered.bytes) }
        // Truncado.
        #expect(throws: TronProtobuf.Failure.truncated) { try TronRawTransaction.decode(Array(bytes.dropLast())) }
        // Transaction com `ret`.
        let signed = TronProtobuf.signedTransaction(raw: raw, signatures: [tx.signature])
        #expect(throws: TronProtobuf.Failure.unexpectedField(message: "Transaction", field: 5)) {
            try TronProtobuf.decodeSignedTransaction(signed + [0x2A, 0x00])
        }
    }

    @Test("Valores fora de int64 nao viram transacao")
    func int64Range() throws {
        let tx = try TronFixtures.transactions()[0]
        let raw = try TronRawTransaction.decode(Hex.decode(tx.rawDataHex)!)
        let tooBig = BigUInt(UInt64(Int64.max)) + 1
        #expect(throws: TronProtobuf.Failure.valueOutOfRange) {
            try TronRawTransaction(
                refBlockBytes: raw.refBlockBytes, refBlockHash: raw.refBlockHash, expiration: raw.expiration,
                contract: .transfer(owner: raw.contract.owner, to: raw.contract.owner, amount: tooBig), timestamp: raw.timestamp
            )
        }
        #expect(throws: TronProtobuf.Failure.valueOutOfRange) {
            try TronRawTransaction(
                refBlockBytes: raw.refBlockBytes, refBlockHash: raw.refBlockHash, expiration: raw.expiration,
                contract: raw.contract, timestamp: raw.timestamp, feeLimit: tooBig
            )
        }
        // Varint com o bit 63 ligado (int64 negativo) no amount.
        var negative = TronProtoWriter()
        negative.varint(UInt64(Int64.max) + 1)
        var reader = TronProtoReader([0x18] + negative.bytes)
        let (_, value) = try #require(try reader.next())
        #expect(throws: TronProtobuf.Failure.valueOutOfRange) { try value.int64(message: "x", field: 3) }
    }
}
