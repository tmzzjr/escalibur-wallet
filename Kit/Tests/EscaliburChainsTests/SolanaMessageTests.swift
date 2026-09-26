import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// Mensagem e transacao da Solana, byte a byte, contra os testes do solana-sdk,
/// do web3.js e da Kit, e contra transacoes reais da rede principal.
///
/// O Ed25519 do CryptoKit e aleatorizado: a assinatura nunca e comparada com a do
/// vetor. Compara-se a mensagem, verifica-se a assinatura do vetor sobre ela, e a
/// montagem com a assinatura do vetor tem de reproduzir os bytes do vetor.
@Suite("Solana: mensagem e transacao")
struct SolanaMessageTests {
    static func secureSeed(_ bytes: [UInt8]) -> SecureBytes {
        let seed = SecureBytes(capacity: 32)
        seed.replaceAll(with: bytes)
        return seed
    }

    /// Instrucoes com as contas no papel que a mensagem declara.
    static func decompile(_ message: SolanaMessage, loaded: SolanaLoadedAddresses = .none) -> [SolanaInstruction] {
        let keys = message.accountKeys(loaded: loaded)
        return message.instructions.map { ix in
            SolanaInstruction(
                programID: keys[Int(ix.programIDIndex)],
                accounts: ix.accountIndexes.map {
                    SolanaAccountMeta(keys[Int($0)], isSigner: message.isSigner(index: Int($0)), isWritable: message.isWritable(index: Int($0), loaded: loaded))
                },
                data: ix.data
            )
        }
    }

    static func key(first byte: UInt8) throws -> SolanaPublicKey {
        try SolanaPublicKey(bytes: [byte] + [UInt8](repeating: 0x5A, count: 31))
    }

    // MARK: compact-u16

    @Test("compact-u16: solana-sdk short-vec/src/lib.rs (codificacao, alias e estouro)")
    func shortVec() throws {
        let ref = try SolanaFixtures.load("reference-vectors", as: SolanaFixtures.Reference.self)
        for pair in ref.shortvec.encode {
            let value = try #require(pair[0].int)
            let bytes = try SolanaFixtures.hex(try #require(pair[1].text))
            #expect(SolanaShortVec.encode(value) == bytes, "\(value)")
            let decoded = try SolanaShortVec.decode(bytes)
            #expect(decoded.value == value)
            #expect(decoded.length == bytes.count)
        }
        for hex in ref.shortvec.reject {
            let bytes = try SolanaFixtures.hex(hex)
            #expect(throws: SolanaShortVec.Problem.self, "\(hex)") { try SolanaShortVec.decode(bytes) }
        }
    }

    // MARK: Codec

    @Test("Codec v0 e legado: bytes do teste da Kit (codecs/v0 e codecs/legacy, message-test.ts)")
    func kitCodec() throws {
        let ref = try SolanaFixtures.load("reference-vectors", as: SolanaFixtures.Reference.self)
        let v = ref.kitCodecMessage
        let header = SolanaMessageHeader(numRequiredSignatures: v.header[0], numReadonlySignedAccounts: v.header[1], numReadonlyUnsignedAccounts: v.header[2])
        let keys = try v.staticAccounts.map { try SolanaPublicKey(bytes: try SolanaFixtures.hex($0)) }
        let blockhash = try SolanaBlockhash(bytes: try SolanaFixtures.hex(v.lifetimeToken))
        #expect(blockhash.base58 == "gBxS1f6uyyGPuW5MzGBukidSb71jdsCb5fZaoSzULE5")
        #expect(keys[0].base58 == "k7FaK87WHGVXzkaoHb7CdVPgkKDQhZ29VLDeBVbDfYn")
        let instructions = try v.instructions.map {
            SolanaCompiledInstruction(programIDIndex: $0.programIndex, accountIndexes: $0.accounts, data: try SolanaFixtures.hex($0.data))
        }
        let lookups = try v.lookups.map {
            SolanaAddressTableLookup(tableAddress: try SolanaPublicKey(bytes: try SolanaFixtures.hex($0.table)), writableIndexes: $0.writable, readonlyIndexes: $0.readonly)
        }
        #expect(lookups[0].tableAddress.base58 == "3yS1JFVT284y8z1LC9MRoWxZjzFrdoD5axKsZiyMsfC7")

        let v0 = try SolanaMessage(version: .v0, header: header, staticAccountKeys: keys, recentBlockhash: blockhash, instructions: instructions, addressTableLookups: lookups)
        #expect(v0.serialize() == (try SolanaFixtures.hex(v.expectedV0)))
        #expect(try SolanaMessage.deserialize(try SolanaFixtures.hex(v.expectedV0)) == v0)

        let v0Plain = try SolanaMessage(version: .v0, header: header, staticAccountKeys: keys, recentBlockhash: blockhash, instructions: instructions)
        #expect(v0Plain.serialize() == (try SolanaFixtures.hex(v.expectedV0NoLookups)))

        let legacy = try SolanaMessage(version: .legacy, header: header, staticAccountKeys: keys, recentBlockhash: blockhash, instructions: instructions)
        #expect(legacy.serialize() == (try SolanaFixtures.hex(v.expectedLegacy)))
        #expect(try SolanaMessage.deserialize(try SolanaFixtures.hex(v.expectedLegacy)) == legacy)

        // O vetor e so de codec: 3 signatarios mais 1 somente leitura nao cabem em 3
        // chaves, e o programa no indice 0 seria o pagador. O validador recusaria, e
        // o `sanitize` tambem.
        #expect(throws: SolanaMessage.Problem.headerOutOfBounds) { try legacy.sanitize() }
        let payerAsProgram = try SolanaMessage(
            version: .legacy, header: SolanaMessageHeader(numRequiredSignatures: 1, numReadonlySignedAccounts: 0, numReadonlyUnsignedAccounts: 1),
            staticAccountKeys: keys, recentBlockhash: blockhash, instructions: instructions
        )
        #expect(throws: SolanaMessage.Problem.programIsFeePayer) { try payerAsProgram.sanitize() }
        #expect(throws: SolanaMessage.Problem.lookupTablesNotAllowedInLegacy) {
            try SolanaMessage(version: .legacy, header: header, staticAccountKeys: keys, recentBlockhash: blockhash, instructions: instructions, addressTableLookups: lookups)
        }
    }

    @Test("Transferencia de SOL do web3.js (transaction.test.ts, parse wire format and serialize)")
    func web3LegacyTransfer() throws {
        let ref = try SolanaFixtures.load("reference-vectors", as: SolanaFixtures.Reference.self)
        let v = ref.web3LegacyTransfer
        let seed = Self.secureSeed(try SolanaFixtures.hex(v.senderHex))
        defer { seed.wipe() }
        let sender = try SolanaPublicKey(bytes: try Ed25519.publicKey(of: seed))
        let expected = try #require(Data(base64Encoded: v.signedBase64)).map { $0 }

        let message = try SolanaMessage.compileLegacy(
            payer: sender,
            instructions: [SolanaSystemInstruction.transfer(from: sender, to: try SolanaFixtures.key(v.recipient), lamports: v.lamports)],
            recentBlockhash: try SolanaBlockhash(base58: v.recentBlockhash)
        )
        // A mensagem que a carteira monta e exatamente a do vetor.
        #expect(message.serialize() == Array(expected[65...]))
        #expect(message.header == SolanaMessageHeader(numRequiredSignatures: 1, numReadonlySignedAccounts: 0, numReadonlyUnsignedAccounts: 1))

        // Montar com a assinatura do vetor reproduz os bytes do vetor.
        let vectorSignature = Array(expected[1..<65])
        let transaction = try SolanaTransaction(message: message, signerPath: DefaultPaths.path(for: .solana), signer: sender, lastValidBlockHeight: 9999)
        #expect(transaction.signingRequests.count == 1)
        #expect(transaction.signingRequests[0].payload == Array(expected[65...]))
        #expect(transaction.signingRequests[0].expectedPublicKey == sender.bytes)
        #expect(transaction.signingRequests[0].scheme == .ed25519)
        let signed = try transaction.assemble(with: [ProducedSignature(bytes: vectorSignature)])
        #expect(signed.raw == expected)
        #expect(signed.encoded == v.signedBase64)
        #expect(signed.id == Base58.bitcoin.encode(vectorSignature))
        #expect(signed.chainID == "solana")

        // Assinando aqui (CryptoKit, aleatorizado): outra assinatura, mesma mensagem, valida.
        let ours = try Ed25519.sign(transaction.messageBytes, seed: seed)
        let reassembled = try transaction.assemble(with: [ProducedSignature(bytes: ours)])
        #expect(Array(reassembled.raw[65...]) == Array(expected[65...]))
        let wire = try SolanaWireTransaction(bytes: reassembled.raw)
        #expect(wire.verifySignatures())
        #expect(wire.id == reassembled.id)
    }

    @Test("Transacao de exemplo do solana-sdk (transaction/src/lib.rs, test_sdk_serialize)")
    func sdkSampleTransaction() throws {
        let ref = try SolanaFixtures.load("reference-vectors", as: SolanaFixtures.Reference.self)
        let v = ref.sdkSampleTransaction
        let keypair = try SolanaFixtures.hex(v.keypair)
        let seed = Self.secureSeed(Array(keypair.prefix(32)))
        defer { seed.wipe() }
        let payer = try SolanaPublicKey(bytes: try Ed25519.publicKey(of: seed))
        #expect(payer.bytes == Array(keypair.suffix(32)))
        let expected = try SolanaFixtures.hex(v.serialized)

        let instruction = SolanaInstruction(
            programID: try SolanaPublicKey(bytes: try SolanaFixtures.hex(v.programId)),
            accounts: [
                SolanaAccountMeta(payer, isSigner: true, isWritable: true),
                SolanaAccountMeta(try SolanaPublicKey(bytes: try SolanaFixtures.hex(v.to)), isSigner: false, isWritable: true),
            ],
            data: try SolanaFixtures.hex(v.data)
        )
        let message = try SolanaMessage.compileLegacy(payer: payer, instructions: [instruction], recentBlockhash: try SolanaBlockhash(bytes: [UInt8](repeating: 0, count: 32)))
        #expect(message.serialize() == Array(expected[65...]))
        let signature = Array(expected[1..<65])
        #expect(Ed25519.verify(signature: signature, message: message.serialize(), publicKey: payer.bytes))
        let transaction = try SolanaTransaction(message: message, signerPath: DefaultPaths.path(for: .solana), signer: payer, lastValidBlockHeight: 0)
        #expect(try transaction.assemble(with: [ProducedSignature(bytes: signature)]).raw == expected)
    }

    // MARK: Compilacao

    @Test("Ordem das chaves: grupos e pagador primeiro (web3.js, accountKeys are ordered)")
    func accountOrdering() throws {
        let ref = try SolanaFixtures.load("reference-vectors", as: SolanaFixtures.Reference.self)
        let v = ref.web3AccountOrdering
        let payer = try SolanaFixtures.key(v.payer)
        let program = try SolanaFixtures.key(v.programId)
        var metas = [SolanaAccountMeta]()
        for text in v.readonly.reversed() { metas.append(SolanaAccountMeta(try SolanaFixtures.key(text), isSigner: false, isWritable: false)) }
        for text in v.writable.reversed() { metas.append(SolanaAccountMeta(try SolanaFixtures.key(text), isSigner: false, isWritable: true)) }
        for text in v.readonlySigners.reversed() { metas.append(SolanaAccountMeta(try SolanaFixtures.key(text), isSigner: true, isWritable: false)) }
        for text in v.writableSigners.reversed() { metas.append(SolanaAccountMeta(try SolanaFixtures.key(text), isSigner: true, isWritable: true)) }
        metas.append(SolanaAccountMeta(payer, isSigner: true, isWritable: true))
        let message = try SolanaMessage.compileLegacy(
            payer: payer, instructions: [SolanaInstruction(programID: program, accounts: metas, data: [])],
            recentBlockhash: try SolanaBlockhash(bytes: [UInt8](repeating: 7, count: 32))
        )
        let keys = message.staticAccountKeys.map(\.base58)
        #expect(message.header == SolanaMessageHeader(numRequiredSignatures: 5, numReadonlySignedAccounts: 2, numReadonlyUnsignedAccounts: 3))
        // Os tres primeiros grupos batem com o web3.js inclusive na ordem interna.
        #expect(Array(keys[0..<7]) == [v.payer] + v.writableSigners + v.readonlySigners + v.writable)
        // No ultimo grupo o web3.js ordena pelo texto Base58 (localeCompare) e poe
        // Di1M antes de DYzz; o solana-sdk ordena pelos bytes, e esta carteira segue
        // o solana-sdk. As duas ordens sao validas para a rede.
        #expect(Set(keys[7...]) == Set(v.readonly + [v.programId]))
        #expect(Array(keys[7...]) == (v.readonly + [v.programId]).sorted { try! SolanaFixtures.key($0) < SolanaFixtures.key($1) })
        #expect(keys[7] == "DYzzsfHTgaNhCgn7wMaciAYuwYsGqtVNg9PeFZhH93Pc")
    }

    @Test("Papel de conta repetida e a uniao dos papeis (web3.js, collapses signedness and writability)")
    func duplicateAccounts() throws {
        let ref = try SolanaFixtures.load("reference-vectors", as: SolanaFixtures.Reference.self)
        let v = ref.web3DuplicateAccounts
        let k = { (text: String) in try SolanaFixtures.key(text) }
        let metas = [
            SolanaAccountMeta(try k(v.account5), isSigner: false, isWritable: false),
            SolanaAccountMeta(try k(v.account5), isSigner: false, isWritable: false),
            SolanaAccountMeta(try k(v.account4), isSigner: false, isWritable: false),
            SolanaAccountMeta(try k(v.account4), isSigner: false, isWritable: true),
            SolanaAccountMeta(try k(v.account3), isSigner: false, isWritable: false),
            SolanaAccountMeta(try k(v.account3), isSigner: true, isWritable: false),
            SolanaAccountMeta(try k(v.account2), isSigner: false, isWritable: true),
            SolanaAccountMeta(try k(v.account2), isSigner: true, isWritable: false),
            SolanaAccountMeta(try k(v.payer), isSigner: true, isWritable: true),
        ]
        let message = try SolanaMessage.compileLegacy(
            payer: try k(v.payer), instructions: [SolanaInstruction(programID: try k(v.programId), accounts: metas, data: [])],
            recentBlockhash: try SolanaBlockhash(bytes: [UInt8](repeating: 7, count: 32))
        )
        let keys = message.staticAccountKeys.map(\.base58)
        #expect(Array(keys[0..<4]) == [v.payer, v.account2, v.account3, v.account4])
        // Ultimo grupo em ordem de bytes (o web3.js poe o programa antes, por texto).
        #expect(Array(keys[4...]) == [v.account5, v.programId])
        #expect(message.header == SolanaMessageHeader(numRequiredSignatures: 3, numReadonlySignedAccounts: 1, numReadonlyUnsignedAccounts: 2))
        #expect(message.instructions[0].accountIndexes == [4, 4, 3, 3, 2, 2, 1, 1, 0])
    }

    @Test("Compilacao v0 com tabela: solana-sdk (versions/v0/mod.rs, test_try_compile)")
    func sdkV0Compile() throws {
        let keys = try (1...7).map { try Self.key(first: UInt8($0)) }  // em ordem crescente, como new_unique
        let payer = keys[0], program = keys[6]
        let instruction = SolanaInstruction(programID: program, accounts: [
            SolanaAccountMeta(keys[1], isSigner: true, isWritable: true),
            SolanaAccountMeta(keys[2], isSigner: true, isWritable: false),
            SolanaAccountMeta(keys[3], isSigner: false, isWritable: true),
            SolanaAccountMeta(keys[4], isSigner: false, isWritable: true),
            SolanaAccountMeta(keys[5], isSigner: false, isWritable: false),
        ], data: [])
        let table0 = SolanaAddressLookupTable(address: try Self.key(first: 0xA0), addresses: [keys[4], keys[5], keys[6]])
        let table1 = SolanaAddressLookupTable(address: try Self.key(first: 0xA1), addresses: [])
        let blockhash = try SolanaBlockhash(bytes: [UInt8](repeating: 9, count: 32))
        let message = try SolanaMessage.compileV0(payer: payer, instructions: [instruction], recentBlockhash: blockhash, lookupTables: [table0, table1])

        #expect(message.version == .v0)
        #expect(message.header == SolanaMessageHeader(numRequiredSignatures: 3, numReadonlySignedAccounts: 1, numReadonlyUnsignedAccounts: 1))
        #expect(message.staticAccountKeys == [keys[0], keys[1], keys[2], keys[3], program])
        #expect(message.instructions == [SolanaCompiledInstruction(programIDIndex: 4, accountIndexes: [1, 2, 3, 5, 6], data: [])])
        // O programa invocado (keys[6]) esta na tabela mas nunca sai dela: programa
        // tem de ser chave estatica. A tabela vazia nao aparece.
        #expect(message.addressTableLookups == [SolanaAddressTableLookup(tableAddress: table0.address, writableIndexes: [0], readonlyIndexes: [1])])

        let loaded = try message.resolveLookups([table0, table1])
        #expect(loaded == SolanaLoadedAddresses(writable: [keys[4]], readonly: [keys[5]]))
        try message.sanitize(loaded: loaded)
        #expect(Self.decompile(message, loaded: loaded)[0].accounts.map(\.publicKey) == Array(keys[1...5]))
        let roundTrip = try SolanaMessage.deserialize(message.serialize())
        #expect(roundTrip == message)
        #expect(message.serialize().first == 0x80)
    }

    @Test("Compilacao v0: web3.js (message-tests/v0.test.ts, compile)")
    func web3V0Compile() throws {
        let keys = try (1...7).map { try Self.key(first: UInt8($0)) }
        let payer = keys[0]
        let instructions = [
            SolanaInstruction(programID: keys[4], accounts: [
                SolanaAccountMeta(keys[1], isSigner: true, isWritable: true),
                SolanaAccountMeta(keys[2], isSigner: false, isWritable: false),
                SolanaAccountMeta(keys[3], isSigner: false, isWritable: false),
            ], data: [0]),
            SolanaInstruction(programID: keys[1], accounts: [
                SolanaAccountMeta(keys[2], isSigner: true, isWritable: false),
                SolanaAccountMeta(keys[3], isSigner: false, isWritable: true),
            ], data: [0, 0]),
            SolanaInstruction(programID: keys[3], accounts: [
                SolanaAccountMeta(keys[5], isSigner: false, isWritable: true),
                SolanaAccountMeta(keys[6], isSigner: false, isWritable: false),
            ], data: [0, 0, 0]),
        ]
        let table = SolanaAddressLookupTable(address: try Self.key(first: 0xB0), addresses: keys)
        let message = try SolanaMessage.compileV0(
            payer: payer, instructions: instructions, recentBlockhash: try SolanaBlockhash(bytes: Hash.sha256(Array("test".utf8))), lookupTables: [table]
        )
        #expect(message.staticAccountKeys == [payer, keys[1], keys[2], keys[3], keys[4]])
        #expect(message.header == SolanaMessageHeader(numRequiredSignatures: 3, numReadonlySignedAccounts: 1, numReadonlyUnsignedAccounts: 1))
        #expect(message.addressTableLookups == [SolanaAddressTableLookup(tableAddress: table.address, writableIndexes: [5], readonlyIndexes: [6])])
        #expect(message.instructions == [
            SolanaCompiledInstruction(programIDIndex: 4, accountIndexes: [1, 2, 3], data: [0]),
            SolanaCompiledInstruction(programIDIndex: 1, accountIndexes: [2, 3], data: [0, 0]),
            SolanaCompiledInstruction(programIDIndex: 3, accountIndexes: [5, 6], data: [0, 0, 0]),
        ])
    }

    @Test("Gravavel e signatario pela posicao (web3.js, v0.test.ts isAccountWritable/isAccountSigner)")
    func writability() throws {
        let keys = try (1...4).map { try Self.key(first: UInt8($0)) }
        let lookups = try [0xC0, 0xC1].map {
            SolanaAddressTableLookup(tableAddress: try Self.key(first: UInt8($0)), writableIndexes: [0], readonlyIndexes: [1])
        }
        let message = try SolanaMessage(
            version: .v0, header: SolanaMessageHeader(numRequiredSignatures: 2, numReadonlySignedAccounts: 1, numReadonlyUnsignedAccounts: 1),
            staticAccountKeys: keys, recentBlockhash: try SolanaBlockhash(bytes: Hash.sha256(Array("test".utf8))), instructions: [], addressTableLookups: lookups
        )
        let loaded = SolanaLoadedAddresses(writable: [try Self.key(first: 0xD0), try Self.key(first: 0xD1)], readonly: [try Self.key(first: 0xD2), try Self.key(first: 0xD3)])
        #expect((0..<8).map { message.isWritable(index: $0, loaded: loaded) } == [true, false, true, false, true, true, false, false])
        #expect((0..<8).map { message.isSigner(index: $0) } == [true, true, false, false, false, false, false, false])
    }

    // MARK: Leitura estrita

    @Test("Leitura recusa v1, bytes sobrando, truncamento e comprimento com alias")
    func strictDecoding() throws {
        let ref = try SolanaFixtures.load("reference-vectors", as: SolanaFixtures.Reference.self)
        let valid = try SolanaFixtures.hex(ref.kitCodecMessage.expectedV0)
        // A tx v1 (0x81, ativa desde 15/09/2026) fica fora: recusada, nunca lida como v0.
        #expect(throws: SolanaMessage.Problem.unsupportedVersion(1)) { try SolanaMessage.deserialize([0x81] + valid.dropFirst()) }
        #expect(throws: SolanaMessage.Problem.trailingBytes) { try SolanaMessage.deserialize(valid + [0]) }
        #expect(throws: SolanaMessage.Problem.malformed) { try SolanaMessage.deserialize(Array(valid.dropLast())) }
        #expect(throws: SolanaMessage.Problem.malformed) { try SolanaMessage.deserialize([]) }
        // O numero de chaves (3) escrito como alias de 2 bytes (83 00).
        var aliased = Array(valid[0..<4]) + [0x83, 0x00]
        aliased += valid[5...]
        #expect(throws: SolanaMessage.Problem.malformed) { try SolanaMessage.deserialize(aliased) }
    }

    @Test("Sanidade: as regras do validador")
    func sanitizeRules() throws {
        let keys = try (1...3).map { try Self.key(first: UInt8($0)) }
        let blockhash = try SolanaBlockhash(bytes: [UInt8](repeating: 1, count: 32))
        func message(_ header: (UInt8, UInt8, UInt8), _ ix: [SolanaCompiledInstruction], keys: [SolanaPublicKey] = keys) throws -> SolanaMessage {
            try SolanaMessage(version: .legacy, header: SolanaMessageHeader(numRequiredSignatures: header.0, numReadonlySignedAccounts: header.1, numReadonlyUnsignedAccounts: header.2),
                              staticAccountKeys: keys, recentBlockhash: blockhash, instructions: ix)
        }
        let ok = SolanaCompiledInstruction(programIDIndex: 2, accountIndexes: [0, 1], data: [])
        try message((1, 0, 1), [ok]).sanitize()
        #expect(throws: SolanaMessage.Problem.headerOutOfBounds) { try message((3, 0, 1), [ok]).sanitize() }
        #expect(throws: SolanaMessage.Problem.noWritableFeePayer) { try message((1, 1, 1), [ok]).sanitize() }
        #expect(throws: SolanaMessage.Problem.programIndexOutOfBounds) {
            try message((1, 0, 1), [SolanaCompiledInstruction(programIDIndex: 3, accountIndexes: [], data: [])]).sanitize()
        }
        #expect(throws: SolanaMessage.Problem.accountIndexOutOfBounds) {
            try message((1, 0, 1), [SolanaCompiledInstruction(programIDIndex: 2, accountIndexes: [3], data: [])]).sanitize()
        }
        #expect(throws: SolanaMessage.Problem.duplicateAccount(keys[0])) { try message((1, 0, 1), [ok], keys: [keys[0], keys[0], keys[2]]).sanitize() }
        // v0: consulta vazia e programa vindo de tabela.
        let emptyLookup = try SolanaMessage(
            version: .v0, header: SolanaMessageHeader(numRequiredSignatures: 1, numReadonlySignedAccounts: 0, numReadonlyUnsignedAccounts: 1),
            staticAccountKeys: keys, recentBlockhash: blockhash, instructions: [ok],
            addressTableLookups: [SolanaAddressTableLookup(tableAddress: try Self.key(first: 9), writableIndexes: [], readonlyIndexes: [])]
        )
        #expect(throws: SolanaMessage.Problem.emptyLookup) { try emptyLookup.sanitize() }
        let programFromTable = try SolanaMessage(
            version: .v0, header: SolanaMessageHeader(numRequiredSignatures: 1, numReadonlySignedAccounts: 0, numReadonlyUnsignedAccounts: 1),
            staticAccountKeys: keys, recentBlockhash: blockhash, instructions: [SolanaCompiledInstruction(programIDIndex: 3, accountIndexes: [], data: [])],
            addressTableLookups: [SolanaAddressTableLookup(tableAddress: try Self.key(first: 9), writableIndexes: [], readonlyIndexes: [0])]
        )
        #expect(throws: SolanaMessage.Problem.programIndexOutOfBounds) { try programFromTable.sanitize() }
        #expect(throws: SolanaMessage.Problem.missingLookupTable(try Self.key(first: 9))) { try programFromTable.resolveLookups([]) }
        let shortTable = SolanaAddressLookupTable(address: try Self.key(first: 9), addresses: [])
        #expect(throws: SolanaMessage.Problem.lookupIndexOutOfBounds(try Self.key(first: 9), 0)) { try programFromTable.resolveLookups([shortTable]) }
    }

    // MARK: Transacao

    @Test("Montagem recusa assinatura errada, a mais ou de outra chave")
    func assembleRejectsBadSignatures() throws {
        let seed = Self.secureSeed([UInt8](repeating: 0x42, count: 32))
        defer { seed.wipe() }
        let signer = try SolanaPublicKey(bytes: try Ed25519.publicKey(of: seed))
        let message = try SolanaMessage.compileLegacy(
            payer: signer, instructions: [SolanaSystemInstruction.transfer(from: signer, to: try Self.key(first: 1), lamports: 1)],
            recentBlockhash: try SolanaBlockhash(bytes: [UInt8](repeating: 3, count: 32))
        )
        let transaction = try SolanaTransaction(message: message, signerPath: DefaultPaths.path(for: .solana), signer: signer, lastValidBlockHeight: 1)
        let good = try Ed25519.sign(transaction.messageBytes, seed: seed)
        #expect(throws: SigningError.wrongSignatureCount) { try transaction.assemble(with: []) }
        #expect(throws: SigningError.wrongSignatureCount) { try transaction.assemble(with: [ProducedSignature(bytes: good), ProducedSignature(bytes: good)]) }
        #expect(throws: SigningError.malformedSignature) { try transaction.assemble(with: [ProducedSignature(bytes: Array(good.prefix(63)))]) }
        var flipped = good
        flipped[10] ^= 1
        #expect(throws: SigningError.malformedSignature) { try transaction.assemble(with: [ProducedSignature(bytes: flipped)]) }
        let other = Self.secureSeed([UInt8](repeating: 0x43, count: 32))
        defer { other.wipe() }
        #expect(throws: SigningError.malformedSignature) {
            try transaction.assemble(with: [ProducedSignature(bytes: try Ed25519.sign(transaction.messageBytes, seed: other))])
        }
        _ = try transaction.assemble(with: [ProducedSignature(bytes: good)])
    }

    @Test("Transacao so com o pagador assinando e dentro de 1232 bytes")
    func transactionLimits() throws {
        let payer = try Self.key(first: 1)
        let blockhash = try SolanaBlockhash(bytes: [UInt8](repeating: 3, count: 32))
        let twoSigners = try SolanaMessage.compileLegacy(
            payer: payer,
            instructions: [SolanaInstruction(programID: try Self.key(first: 9), accounts: [SolanaAccountMeta(try Self.key(first: 2), isSigner: true, isWritable: false)], data: [])],
            recentBlockhash: blockhash
        )
        #expect(throws: SolanaMessage.Problem.malformed) {
            try SolanaTransaction(message: twoSigners, signerPath: DefaultPaths.path(for: .solana), signer: payer, lastValidBlockHeight: 1)
        }
        let huge = try SolanaMessage.compileLegacy(
            payer: payer, instructions: [SolanaInstruction(programID: try Self.key(first: 9), accounts: [], data: [UInt8](repeating: 0, count: 1100))],
            recentBlockhash: blockhash
        )
        #expect(throws: SolanaTransactionProblem.tooLarge(1 + 64 + huge.serialize().count)) {
            try SolanaTransaction(message: huge, signerPath: DefaultPaths.path(for: .solana), signer: payer, lastValidBlockHeight: 1)
        }
    }

    // MARK: Rede principal

    @Test("Transacoes reais: id, assinaturas, releitura byte a byte e resolucao das ALTs")
    func mainnetTransactions() throws {
        let fixtures = try SolanaFixtures.load("mainnet-transactions", as: SolanaFixtures.Mainnet.self)
        let tables = try fixtures.tables()
        #expect(fixtures.transactions.count == 6)
        for item in fixtures.transactions {
            let raw = try #require(Data(base64Encoded: item.base64)).map { $0 }
            let wire = try SolanaWireTransaction(bytes: raw)
            #expect(wire.id == item.signature, "\(item.name)")
            #expect(wire.verifySignatures(), "\(item.name)")
            // A leitura e estrita e canonica: reescrever da os mesmos bytes.
            #expect(wire.message.serialize() == wire.messageBytes, "\(item.name)")
            #expect(SolanaShortVec.encode(wire.signatures.count) + wire.signatures.flatMap { $0 } + wire.message.serialize() == raw)
            if wire.message.version == .v0 {
                let loaded = try #require(item.loadedAddresses)
                let resolved = try wire.message.resolveLookups(tables)
                // A mesma resolucao que o no fez (meta.loadedAddresses).
                #expect(resolved.writable.map(\.base58) == loaded.writable, "\(item.name)")
                #expect(resolved.readonly.map(\.base58) == loaded.readonly, "\(item.name)")
                try wire.message.sanitize(loaded: resolved)
            } else {
                #expect(item.loadedAddresses.map { $0.writable.isEmpty && $0.readonly.isEmpty } ?? true)
                try wire.message.sanitize()
            }
        }
    }

    @Test("Envio real de USDC: as instrucoes da carteira reproduzem a transacao da rede")
    func mainnetUSDCSendSemantics() throws {
        let fixtures = try SolanaFixtures.load("mainnet-transactions", as: SolanaFixtures.Mainnet.self)
        let real = try SolanaWireTransaction(base64: try fixtures.transaction("usdc-send-create-ata").base64)
        let payer = try SolanaFixtures.key("8psAwG4hjPMuxvNC5f2szDCNYW9Sjixv9RSP3rdx8SKF")
        let toly = try SolanaFixtures.key("86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY")
        let usdc = try SolanaFixtures.key("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
        let source = try SolanaAssociatedToken.address(owner: payer, mint: usdc, tokenProgram: .token)
        let destination = try SolanaAssociatedToken.address(owner: toly, mint: usdc, tokenProgram: .token)
        // A origem e o destino da transacao real sao os ATAs que a carteira deriva.
        #expect(real.message.staticAccountKeys.contains(source))
        #expect(destination.base58 == "9SHQTA66Ekh7ZgMnKWsjxXk6DwXku8przs45E8bcEe38")

        let ours = try SolanaMessage.compileLegacy(payer: payer, instructions: [
            SolanaComputeBudgetInstruction.setComputeUnitLimit(100_000),
            SolanaComputeBudgetInstruction.setComputeUnitPrice(microLamports: 500),
            SolanaAssociatedTokenInstruction.createIdempotent(payer: payer, associatedAccount: destination, owner: toly, mint: usdc, tokenProgram: .token),
            SolanaTokenInstruction.transferChecked(tokenProgram: .token, source: source, mint: usdc, destination: destination, owner: payer, amount: 100, decimals: 6),
        ], recentBlockhash: real.message.recentBlockhash)

        // Mesmas instrucoes, mesmas contas nos mesmos papeis, mesmos dados. A ordem
        // das chaves dentro dos grupos difere (a carteira de origem ordenou pelo
        // texto, como o web3.js), e por isso os bytes nao sao iguais.
        #expect(Self.decompile(ours) == Self.decompile(real.message))
        #expect(ours.header == real.message.header)
        #expect(Set(ours.staticAccountKeys) == Set(real.message.staticAccountKeys))
        #expect(ours.staticAccountKeys.first == payer)
    }
}
