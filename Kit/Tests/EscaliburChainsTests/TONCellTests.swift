import EscaliburChains
import EscaliburCore
import Foundation
import Testing

@Suite("TON celulas e BOC")
struct TONCellTests {
    @Test("CRC32C (RFC 3720, apendice B.4, e o vetor classico 123456789)")
    func crc32c() {
        #expect(CRC32C.checksum(Array("123456789".utf8)) == 0xE306_9283)
        #expect(CRC32C.checksum([UInt8](repeating: 0, count: 32)) == 0x8A91_36AA)
        #expect(CRC32C.checksum([UInt8](repeating: 0xFF, count: 32)) == 0x62A8_AB43)
        #expect(CRC32C.checksum((0..<32).map { UInt8($0) }) == 0x46DD_794E)
        #expect(CRC32C.checksum((0..<32).reversed().map { UInt8($0) }) == 0x113F_DB5C)
    }

    @Test("Hash da celula vazia: sha256(00 00)")
    func emptyCell() {
        #expect(TONCell.empty.hash.hex == "96a296d224f285c67bee93c30f8a309157f0daa35dc5b87e410b78630a09cfc7")
        #expect(TONCell.empty.depth == 0)
    }

    @Test("Codigo V4R2 e V5R1: o BOC constante bate com o hash publicado")
    func walletCodeHashes() throws {
        // V4R2: hash que tonkeeper/tongo (tvm/precompiled) e o wallet-core usam.
        let v4 = try TONWalletVersion.v4r2.code()
        #expect(v4.hash.hex == "feb5ff6820e2ff0d9483e7e0d62c817d846789fb4ae580c878866d959dabd5c0")
        #expect(v4.depth == 7)
        // V5R1: hash publicado em ton-blockchain/wallet-contract-v5 build/wallet_v5.compiled.json.
        let v5 = try TONWalletVersion.v5r1.code()
        #expect(v5.hash.hex == "20834b7b72b112147e1b2fb457b84e74d1a30f04f737d4f62a668e9552d2b72f")
        #expect(v5.depth == 6)
    }

    @Test("BOC oficial do W5 volta byte a byte (com CRC32C)")
    func officialBOCRoundTrip() throws {
        // O arquivo compilado oficial foi escrito pelo mesmo serializador do ton-core;
        // ler e escrever de novo tem de dar os mesmos bytes, CRC incluido.
        let hex = "b5ee9c7241021401000281000114ff00f4a413f4bcf2c80b01020120020d020148030402dcd020d749c120915b8f6320d70b1f2082106578746ebd21821073696e74bdb0925f03e082106578746eba8eb48020d72101d074d721fa4030fa44f828fa443058bd915be0ed44d0810141d721f4058307f40e6fa1319130e18040d721707fdb3ce03120d749810280b99130e070e2100f020120050c020120060902016e07080019adce76a2684020eb90eb85ffc00019af1df6a2684010eb90eb858fc00201480a0b0017b325fb51341c75c875c2c7e00011b262fb513435c280200019be5f0f6a2684080a0eb90fa02c0102f20e011e20d70b1f82107369676ebaf2e08a7f0f01e68ef0eda2edfb218308d722028308d723208020d721d31fd31fd31fed44d0d200d31f20d31fd3ffd70a000af90140ccf9109a28945f0adb31e1f2c087df02b35007b0f2d0845125baf2e0855036baf2e086f823bbf2d0882292f800de01a47fc8ca00cb1f01cf16c9ed542092f80fde70db3cd81003f6eda2edfb02f404216e926c218e4c0221d73930709421c700b38e2d01d72820761e436c20d749c008f2e09320d74ac002f2e09320d71d06c712c2005230b0f2d089d74cd7393001a4e86c128407bbf2e093d74ac000f2e093ed55e2d20001c000915be0ebd72c08142091709601d72c081c12e25210b1e30f20d74a111213009601fa4001fa44f828fa443058baf2e091ed44d0810141d718f405049d7fc8ca0040048307f453f2e08b8e14038307f45bf2e08c22d70a00216e01b3b0f2d090e2c85003cf1612f400c9ed54007230d72c08248e2d21f2e092d200ed44d0d2005113baf2d08f54503091319c01810140d721d70a00f2e08ee2c8ca0058cf16c9ed5493f2c08de20010935bdb31e1d74cd0b4d6c35e"
        let bytes = try #require([UInt8](hex: hex))
        let cell = try TONBOC.parseRoot(bytes)
        #expect(TONBOC.serialize(cell, crc32c: true).hex == hex)
    }

    @Test("State init V4R2: BOC com CRC, sem CRC e com indice, igual ao ton-core")
    func stateInitBOC() throws {
        // Fixtures/ton/ton-core-vectors.json, gerado por gerar-vetores.js (ton-core 0.63.1).
        let vectors = try TONCoreVectors.load()
        let wallet = try TONWallet(publicKey: #require([UInt8](hex: vectors.wallets[0].publicKey)), version: .v4r2)
        #expect(wallet.stateInit.hash.hex == vectors.stateInitBoc.hash)
        #expect(TONBOC.serialize(wallet.stateInit, crc32c: true).hex == vectors.stateInitBoc.crc)
        #expect(TONBOC.serialize(wallet.stateInit, crc32c: false).hex == vectors.stateInitBoc.plain)
        #expect(TONBOC.serialize(wallet.stateInit, crc32c: true, index: true).hex == vectors.stateInitBoc.indexed)
        for text in [vectors.stateInitBoc.crc, vectors.stateInitBoc.plain, vectors.stateInitBoc.indexed] {
            #expect(try TONBOC.parseRoot(#require([UInt8](hex: text))).hash.hex == vectors.stateInitBoc.hash)
        }
    }

    @Test("BOC malformado e recusado com motivo, sem derrubar nada")
    func malformedBOC() throws {
        let good = TONBOC.serialize(try TONWalletVersion.v4r2.code())
        var badCRC = good
        badCRC[badCRC.count - 1] ^= 0x01
        #expect(throws: TONCellError.malformedBOC("CRC32C")) { try TONBOC.parse(badCRC) }
        var badData = good
        badData[40] ^= 0x10
        #expect(throws: TONCellError.self) { try TONBOC.parse(badData) }
        #expect(throws: TONCellError.self) { try TONBOC.parse(Array(good.dropLast(10))) }
        #expect(throws: TONCellError.malformedBOC("bytes sobrando")) { try TONBOC.parse(good + [0]) }
        #expect(throws: TONCellError.malformedBOC("magica")) { try TONBOC.parse([0, 1, 2, 3] + good.dropFirst(4)) }
        #expect(throws: TONCellError.self) { try TONBOC.parse([]) }
        // Referencia para tras (ciclo possivel): celula 0 aponta para si mesma.
        let loop: [UInt8] = [0xB5, 0xEE, 0x9C, 0x72, 0x01, 0x01, 0x01, 0x01, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00]
        #expect(throws: TONCellError.malformedBOC("referencia fora de ordem")) { try TONBOC.parse(loop) }
    }

    @Test("Limites da celula: 1023 bits e 4 referencias")
    func limits() throws {
        var b = TONCellBuilder()
        try b.storeBytes([UInt8](repeating: 0xAB, count: 127))
        try b.storeUInt(0x7F, bits: 7)
        #expect(b.availableBits == 0)
        #expect(throws: TONCellError.bitOverflow) { try b.storeBit(true) }
        for _ in 0..<4 { try b.storeRef(.empty) }
        #expect(throws: TONCellError.refOverflow) { try b.storeRef(.empty) }
        let full = b.build()
        #expect(full.bitCount == 1023)
        #expect(full.depth == 1)
        // O BOC de uma celula cheia volta igual.
        #expect(try TONBOC.parseRoot(TONBOC.serialize(full)) == full)

        var c = TONCellBuilder()
        #expect(throws: TONCellError.valueTooLarge) { try c.storeUInt(8, bits: 3) }
        #expect(throws: TONCellError.valueTooLarge) { try c.storeInt(-129, bits: 8) }
        #expect(throws: TONCellError.valueTooLarge) { try c.storeCoins(BigUInt.power(of: 2, 120)) }
    }

    @Test("Escrita e leitura: inteiros, Coins, endereco e referencia")
    func roundTrip() throws {
        let address = try TONTestSupport.address("EQCKhieGGl3ZbJ2zzggHsSLaXtRzk0znVopbSxw2HLsorkdl")
        var b = TONCellBuilder()
        try b.storeBit(true)
        try b.storeUInt(0x29A9_A317, bits: 32)
        try b.storeInt(-1, bits: 8)
        try b.storeCoins(BigUInt(1_000_000_000))
        try b.storeCoins(0)
        try b.storeAddress(address)
        try b.storeAddress(nil)
        try b.storeMaybeRef(TONCell.empty)
        let cell = b.build()
        // 1 + 32 + 8 + (4 + 32) + 4 + 267 + 2 + 1
        #expect(cell.bitCount == 351)
        var s = cell.beginParse()
        #expect(try s.loadBit())
        #expect(try s.loadUInt(bits: 32) == 698_983_191)
        #expect(try s.loadInt(bits: 8) == -1)
        #expect(try s.loadCoins() == BigUInt(1_000_000_000))
        #expect(try s.loadCoins() == 0)
        #expect(try s.loadAddress() == address)
        #expect(try s.loadAddress() == nil)
        #expect(try s.loadMaybeRef() == .empty)
        #expect(s.remainingBits == 0)
        #expect(throws: TONCellError.sliceUnderflow) { try s.loadBit() }
    }

    @Test("Comentario: celulas encadeadas iguais as do ton-core")
    func comments() throws {
        // `comment()` do ton-core: op 0 + texto em string tail.
        let vectors = try TONCoreVectors.load()
        for vector in vectors.comments {
            let cell = try TONComment.cell(vector.text)
            #expect(cell.hash.hex == vector.hash, "\(vector.text.prefix(20))")
            #expect(TONBOC.serialize(cell).hex == vector.boc)
            #expect(try TONComment.text(of: cell) == vector.text)
        }
        // 123 bytes cabem na primeira celula (1023 - 32 bits); 124 ja encadeiam.
        #expect(try TONComment.cell(String(repeating: "a", count: 123)).refs.isEmpty)
        #expect(try TONComment.cell(String(repeating: "a", count: 124)).refs.count == 1)
    }

    @Test("Celula de biblioteca do USDT: o hash que o toncenter publica como jetton_wallet_code_hash")
    func libraryCell() throws {
        // toncenter /api/v3/jetton/masters (USDT): jetton_wallet_code_hash
        // iUaPAseOVwgC45l5yFFvw43wfqdqSDV+BTbyuns+43s= (conferido em 25/09/2026).
        let hash = try #require([UInt8](hex: "8f452d7a4dfd74066b682365177259ed05734435be76b5fd4bd5d8af2b7c3d68"))
        let library = try TONCell.library(codeHash: hash)
        #expect(library.hash.hex == "89468f02c78e570802e39979c8516fc38df07ea76a48357e0536f2ba7b3ee37b")
        // O BOC que o mestre devolve em get_jetton_data le para a mesma celula.
        let fromChain = try TONBOC.parseRoot(base64: "te6cckEBAQEAIwAIQgKPRS16Tf10BmtoI2UXclntBXNENb52tf1L1divK3w9aCBrv3Y=")
        #expect(fromChain == library)
        #expect(fromChain.isExotic)
    }
}
