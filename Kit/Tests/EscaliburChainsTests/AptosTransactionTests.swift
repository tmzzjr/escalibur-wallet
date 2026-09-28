import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

/// A transacao da Aptos contra dois tipos de referencia:
/// - o vetor do wallet-core da Trust Wallet (trustwallet/wallet-core, commit
///   d40d24a63d92619167903369308bf0e2f7eb3a59, `rust/chains/tw_aptos/tests/signer.rs`,
///   `test_aptos_sign_transaction_transfer`): a transacao em BCS, a assinatura deles
///   (RFC 8032, deterministica) verificando sobre a mensagem que montamos, os bytes
///   assinados e o hash, que e o da transacao transmitida na devnet
///   (0xb4d62afd...2467);
/// - quatro transferencias reais da rede principal (`Fixtures/aptos/mainnet-transferencias.json`,
///   lidas da API em 28/09/2026): remontadas dos campos, a assinatura de cada uma verifica
///   sobre a nossa mensagem, e o hash dos nossos bytes e o hash que a rede deu.
@Suite("Aptos transacao em BCS")
struct AptosTransactionTests {
    static let key = "5d996aa76b3212142792d9130796cd2e11e3c445a93118c08414df4f66bc60ec"
    static let publicKey = [UInt8](hex: "ea526ba1710343d953461ff68641f1b7df5f23b9042ffa2d2a798d3adb3f3d6c")!
    static let sender = address("0x07968dab936c1bad187c60ce4082f307d030d780e91e694ae03aef16aba73f30")

    static func address(_ text: String) -> AptosAddress {
        guard case .success(let address) = AptosAddress.parse(text) else { fatalError("endereco de teste invalido") }
        return address
    }

    /// A API do fullnode escreve o argumento `address` sem os zeros a esquerda
    /// ("0xcf86...", 63 digitos, na transacao 7391609190). A carteira nao aceita essa forma
    /// digitada; aqui ela e completada so para remontar a transacao gravada.
    static func apiAddress(_ text: String) -> AptosAddress {
        let digits = String(text.dropFirst(2))
        return address("0x" + String(repeating: "0", count: 64 - digits.count) + digits)
    }

    static func seed(_ hex: String = key) -> SecureBytes {
        let seed = SecureBytes(capacity: 32)
        seed.replaceAll(with: [UInt8](hex: hex)!)
        return seed
    }

    static let walletCoreRaw = "07968dab936c1bad187c60ce4082f307d030d780e91e694ae03aef16aba73f3063000000000000000200000000000000000000000000000000000000000000000000000000000000010d6170746f735f6163636f756e74087472616e7366657200022007968dab936c1bad187c60ce4082f307d030d780e91e694ae03aef16aba73f3008e803000000000000fe4d3200000000006400000000000000c2276ada0000000021"
    static let walletCoreSignature = "5707246db31e2335edc4316a7a656a11691d1d1647f6e864d1ab12f43428aaaf806cf02120d0b608cdd89c5c904af7b137432aacdd60cc53f9fad7bd33578e01"

    static let walletCoreTransaction = AptosRawTransaction(
        sender: sender, sequenceNumber: 99, recipient: sender, amount: 1000, maxGasAmount: 3_296_766,
        gasUnitPrice: 100, expirationTimestampSecs: 3_664_390_082, chainID: 33
    )

    @Test("BCS, mensagem assinada, bytes assinados e hash do vetor do wallet-core")
    func walletCoreVector() throws {
        let raw = Self.walletCoreTransaction
        #expect(Hex.encode(raw.bcs()) == Self.walletCoreRaw)
        #expect(Hex.encode(AptosRawTransaction.signingSalt) == "b5e97db07fa0bd0e5598aa3643a9bc6f6693bddc1a9fec9e674a461eaa00b193")
        let signature = [UInt8](hex: Self.walletCoreSignature)!
        #expect(Ed25519.verify(signature: signature, message: raw.signingMessage, publicKey: Self.publicKey))
        let signed = AptosSignedTransaction.signedBytes(raw: raw.bcs(), publicKey: Self.publicKey, signature: signature)
        #expect(Hex.encode(signed) == Self.walletCoreRaw + "0020" + Hex.encode(Self.publicKey) + "40" + Self.walletCoreSignature)
        #expect(AptosSignedTransaction.hash(of: signed) == "0xb4d62afd3862116e060dd6ad9848ccb50c2bc177799819f1d29c059ae2042467")
        #expect(try AptosRawTransaction.decode(raw.bcs()) == raw)
    }

    struct MainnetTransfer: Decodable {
        struct Payload: Decodable { let function: String; let arguments: [String]; let type_arguments: [String] }
        struct Signature: Decodable { let public_key: String; let signature: String; let type: String }
        let version: String
        let hash: String
        let sender: String
        let sequence_number: String
        let max_gas_amount: String
        let gas_unit_price: String
        let expiration_timestamp_secs: String
        let payload: Payload
        let signature: Signature
        let success: Bool
    }

    static func mainnet() throws -> [MainnetTransfer] {
        let url = try #require(Bundle.module.url(forResource: "mainnet-transferencias", withExtension: "json", subdirectory: "Fixtures/aptos"))
        return try JSONDecoder().decode([MainnetTransfer].self, from: Data(contentsOf: url))
    }

    @Test("Transferencias reais da rede principal: mesma assinatura, mesmo hash")
    func mainnetTransfers() throws {
        let transfers = try Self.mainnet()
        #expect(transfers.count == 4)
        // Uma delas tem destino com zero a esquerda, e a assinatura cobre os 32 bytes.
        #expect(transfers.contains { $0.payload.arguments[0].count == 65 })
        for tx in transfers {
            #expect(tx.payload.function == "0x1::aptos_account::transfer" && tx.payload.type_arguments.isEmpty && tx.success)
            let raw = AptosRawTransaction(
                sender: Self.address(tx.sender), sequenceNumber: UInt64(tx.sequence_number)!,
                recipient: Self.apiAddress(tx.payload.arguments[0]), amount: UInt64(tx.payload.arguments[1])!,
                maxGasAmount: UInt64(tx.max_gas_amount)!, gasUnitPrice: UInt64(tx.gas_unit_price)!,
                expirationTimestampSecs: UInt64(tx.expiration_timestamp_secs)!, chainID: AptosPlanner.mainnetChainID
            )
            let key = [UInt8](hex: String(tx.signature.public_key.dropFirst(2)))!
            let signature = [UInt8](hex: String(tx.signature.signature.dropFirst(2)))!
            #expect(Ed25519.verify(signature: signature, message: raw.signingMessage, publicKey: key), "\(tx.version)")
            #expect(try AptosAddress(ed25519PublicKey: key) == raw.sender, "\(tx.version)")
            let signed = AptosSignedTransaction.signedBytes(raw: raw.bcs(), publicKey: key, signature: signature)
            #expect(AptosSignedTransaction.hash(of: signed) == tx.hash, "\(tx.version)")
            // E a transacao assinada passa pela conferencia de transmissao.
            let packed = SignedTransaction(chainID: "aptos", raw: signed, encoded: Hex.encode(signed), id: tx.hash)
            #expect(try AptosSignedTransaction.parse(packed).raw == raw)
        }
    }

    @Test("Assinar, montar e conferir de ponta a ponta; adulteracao recusada")
    func signAssembleParse() throws {
        let seed = Self.seed()
        defer { seed.wipe() }
        let raw = AptosRawTransaction(
            sender: Self.sender, sequenceNumber: 7, recipient: Self.address("0xa816db9fa6e242878969f54c5e8ae5081f01ffc9442c0c055ef62a9b02459cc6"),
            amount: 100_000_000, maxGasAmount: 200, gasUnitPrice: 100, expirationTimestampSecs: 1_790_570_883, chainID: 1
        )
        let transfer = try AptosTransfer(raw: raw, path: DerivationPath("m/44'/637'/0'/0'/0'")!, publicKey: Self.publicKey)
        #expect(transfer.signingRequests == [SigningRequest(
            path: DerivationPath("m/44'/637'/0'/0'/0'")!, curve: .ed25519, scheme: .ed25519,
            payload: AptosRawTransaction.signingSalt + raw.bcs(), expectedPublicKey: Self.publicKey
        )])
        let signature = try Ed25519.sign(transfer.signingMessage, seed: seed)
        let signed = try transfer.assemble(with: [ProducedSignature(bytes: signature)])
        #expect(signed.chainID == "aptos" && signed.encoded == Hex.encode(signed.raw))
        #expect(signed.id == AptosSignedTransaction.hash(of: signed.raw))
        let parsed = try AptosSignedTransaction.parse(signed)
        #expect(parsed.raw == raw && parsed.publicKey == Self.publicKey)

        // Assinatura de outra mensagem nao monta.
        let other = try Ed25519.sign(Array("outra".utf8), seed: seed)
        #expect(throws: SigningError.malformedSignature) { try transfer.assemble(with: [ProducedSignature(bytes: other)]) }
        // Um byte trocado nos campos, ou outro id, ou outra rede: recusado.
        var tampered = signed.raw
        tampered[80] ^= 0x01
        #expect(throws: AptosTransactionError.malformed) {
            try AptosSignedTransaction.parse(SignedTransaction(chainID: "aptos", raw: tampered, encoded: Hex.encode(tampered), id: signed.id))
        }
        #expect(throws: AptosTransactionError.malformed) {
            try AptosSignedTransaction.parse(SignedTransaction(chainID: "aptos", raw: signed.raw, encoded: signed.encoded, id: "0x" + String(repeating: "0", count: 64)))
        }
        #expect(throws: AptosTransactionError.malformed) {
            try AptosSignedTransaction.parse(SignedTransaction(chainID: "sui", raw: signed.raw, encoded: signed.encoded, id: signed.id))
        }
        // Chain id da devnet (o vetor do wallet-core) nao sai pela carteira.
        let devnet = try AptosTransfer(raw: Self.walletCoreTransaction, path: DerivationPath("m/44'/637'/0'/0'/0'")!, publicKey: Self.publicKey)
        let devnetSigned = try devnet.assemble(with: [ProducedSignature(bytes: try Ed25519.sign(devnet.signingMessage, seed: seed))])
        #expect(throws: AptosTransactionError.malformed) { try AptosSignedTransaction.parse(devnetSigned) }
    }

    @Test("Leitura estrita: outro modulo, outra funcao, argumento de tipo e bytes a mais recusados")
    func strictDecode() throws {
        let bytes = Self.walletCoreTransaction.bcs()
        #expect(throws: AptosTransactionError.malformed) { try AptosRawTransaction.decode(bytes + [0]) }
        #expect(throws: AptosTransactionError.malformed) { try AptosRawTransaction.decode(Array(bytes.dropLast())) }
        // "aptos_account" vira "aptos_accounu".
        var module = bytes
        module[40 + 1 + 32 + 13] ^= 0x01
        #expect(throws: AptosTransactionError.malformed) { try AptosRawTransaction.decode(module) }
        // Payload de script (variante 0) no lugar de EntryFunction.
        var script = bytes
        script[40] = 0
        #expect(throws: AptosTransactionError.malformed) { try AptosRawTransaction.decode(script) }
    }

    @Test("Endereco: forma longa, curta so para os especiais do AIP-40, e recusas")
    func addressRules() {
        let long = "0xa816db9fa6e242878969f54c5e8ae5081f01ffc9442c0c055ef62a9b02459cc6"
        #expect(Address.validate(long.uppercased().replacingOccurrences(of: "0X", with: "0x"), for: .aptos) == .success(.init(address: long, tag: nil)))
        #expect(Address.validate("0x1", for: .aptos) == .success(.init(address: "0x" + String(repeating: "0", count: 63) + "1", tag: nil)))
        #expect(Self.address("0xa").isSpecial && Self.address("0xa").isSystem && !Self.address(long).isSystem)
        // Forma curta de endereco comum, sem o 0x (formato da NEAR), comprido demais.
        #expect(Address.validate("0x" + String(long.dropFirst(3)), for: .aptos) == .failure(.malformed))
        #expect(Address.validate("0x10", for: .aptos) == .failure(.malformed))
        #expect(Address.validate(String(long.dropFirst(2)), for: .aptos) == .failure(.malformed))
        #expect(Address.validate(long + "0", for: .aptos) == .failure(.malformed))
        // Endereco EVM na Aptos: outra rede, com nome. Sui na Aptos: valido (o texto nao diz).
        #expect(Address.validate("0x52908400098527886E0F7030069857D2E4169EE7", for: .aptos) == .failure(.otherNetwork(.ethereum)))
        #expect(Address.guessChain(long) == nil)
        #expect(Address.sameRecipient(long, long.uppercased().replacingOccurrences(of: "0X", with: "0x"), chain: .aptos))
    }

    @Test("Loja primaria de APT: o objeto derivado que aparece nos eventos reais")
    func primaryStore() {
        // Transacao 7391617458 da rede principal: Withdraw da loja do remetente e Deposit na
        // loja do destino.
        #expect(Self.address("0x966e3ee07a3403a72f44c53f457d34c7148c2c8812c8d52509f54d4a00a36c41").primaryAPTStore.hex
            == "0x3b5121ef6927ad5bb67516dc53579efb4f1797fcfaa4ee31879aa5f9781bf3e1")
        #expect(Self.address("0xa816db9fa6e242878969f54c5e8ae5081f01ffc9442c0c055ef62a9b02459cc6").primaryAPTStore.hex
            == "0xeea824e020ff35fb0a2f8660e687e39f9d76c8c6ca3a9dac54e38c58d27bef5d")
    }
}
