import CryptoKit
import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// A checagem "ponto na curva Ed25519", os enderecos derivados de programa (PDA) e
/// as contas de token associadas (ATA). Um erro aqui manda token para uma conta que
/// ninguem controla, entao cada peca e conferida por mais de uma fonte:
///   - vetores dos testes da Kit (@solana/kit), do solana-sdk e do web3.js;
///   - um oraculo independente em Python (criterio de Euler, outro algoritmo);
///   - chaves geradas pelo CryptoKit (sempre na curva);
///   - contas de token reais da rede principal.
@Suite("Solana: curva, PDA e ATA")
struct SolanaCurveTests {
    static let p = BigUInt(bigEndian: [0x7F] + [UInt8](repeating: 0xFF, count: 30) + [0xED])

    static func integer(_ element: FieldElement25519) -> BigUInt {
        BigUInt(bigEndian: element.packed.reversed())
    }

    @Test("Constantes d e sqrt(-1) conferidas com aritmetica independente (BigUInt)")
    func constants() {
        let p = Self.p
        let d = Self.integer(.d)
        // d = -121665/121666  <=>  d * 121666 + 121665 ≡ 0 (mod p)
        #expect((d * BigUInt(121_666) + BigUInt(121_665)) % p == BigUInt())
        let i = Self.integer(.sqrtMinusOne)
        #expect((i * i + BigUInt(1)) % p == BigUInt())
        // p em 16 limbs empacota como p - p = 0 (forma canonica).
        let pBytes = [0xED] + [UInt8](repeating: 0xFF, count: 30) + [0x7F]
        #expect(FieldElement25519(unpacking: pBytes).packed == [UInt8](repeating: 0, count: 32))
    }

    /// Bytes pseudoaleatorios deterministicos (SHA-256 de um contador): falha
    /// reproduzivel, e nenhuma fonte de aleatoriedade fora do SecRandomCopyBytes.
    static func sample(_ label: String, _ index: Int) -> [UInt8] {
        Hash.sha256(Array("\(label)/\(index)".utf8))
    }

    @Test("Aritmetica do corpo contra BigUInt em 40 pares")
    func fieldArithmetic() {
        for index in 0..<40 {
            var a = Self.sample("a", index)
            var b = Self.sample("b", index)
            a[31] &= 0x7F
            b[31] &= 0x7F
            let fa = FieldElement25519(unpacking: a)
            let fb = FieldElement25519(unpacking: b)
            let ia = BigUInt(bigEndian: a.reversed()) % Self.p
            let ib = BigUInt(bigEndian: b.reversed()) % Self.p
            #expect(Self.integer(fa * fb) == (ia * ib) % Self.p)
            #expect(Self.integer(fa + fb) == (ia + ib) % Self.p)
            #expect(Self.integer(fa - fb) == (ia + Self.p - ib) % Self.p)
        }
    }

    @Test("Vetores de curva da Kit (curve-test.ts)")
    func kitCurveVectors() throws {
        let ref = try SolanaFixtures.load("reference-vectors", as: SolanaFixtures.Reference.self)
        for hex in ref.curve.onCurveBytes { #expect(Edwards25519.isOnCurve(try SolanaFixtures.hex(hex)), "\(hex)") }
        for hex in ref.curve.offCurveBytes { #expect(!Edwards25519.isOnCurve(try SolanaFixtures.hex(hex)), "\(hex)") }
        // Carteira, System Program, Token Program e Squads estao na curva; ATA e
        // conta do Squads, nao.
        for text in ref.curve.onCurveAddresses { #expect(try SolanaFixtures.key(text).isOnCurve, "\(text)") }
        for text in ref.curve.offCurveAddresses { #expect(try !SolanaFixtures.key(text).isOnCurve, "\(text)") }
        // web3.js, publickey.test.ts#isOnCurve: o PDA do issue 11950.
        #expect(try !SolanaFixtures.key("12rqwuEgBYiGhBrDJStCiqEtzQpTTiZbh7teNVLuYcFA").isOnCurve)
    }

    @Test("Concorda com o oraculo em Python em 414 entradas, inclusive as de borda do dalek")
    func pythonOracle() throws {
        let oracle = try SolanaFixtures.load("curve-oracle", as: SolanaFixtures.Oracle.self)
        #expect(oracle.cases.count == 414)
        for item in oracle.cases {
            #expect(Edwards25519.isOnCurve(try SolanaFixtures.hex(item.hex)) == item.onCurve, "\(item.note ?? item.hex)")
        }
    }

    @Test("A raiz encontrada fecha a equacao da curva e respeita o bit de sinal")
    func decompressedPointSatisfiesCurve() throws {
        let oracle = try SolanaFixtures.load("curve-oracle", as: SolanaFixtures.Oracle.self)
        for item in oracle.cases where item.onCurve {
            let bytes = try SolanaFixtures.hex(item.hex)
            let (x, y) = try #require(Edwards25519.decompress(bytes))
            // -x^2 + y^2 = 1 + d x^2 y^2
            let x2 = x.squared, y2 = y.squared
            #expect(y2 - x2 == FieldElement25519.one + FieldElement25519.d * x2 * y2)
            // Bit de sinal: a paridade de x, salvo x = 0, que o dalek aceita com sinal 1.
            if x != FieldElement25519.zero { #expect(x.parity == bytes[31] >> 7) }
        }
    }

    @Test("Toda chave publica do CryptoKit esta na curva")
    func cryptoKitKeysAreOnCurve() throws {
        for index in 0..<64 {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.sample("chave", index)).publicKey.rawRepresentation
            #expect(Edwards25519.isOnCurve(Array(key)))
        }
    }

    @Test("Tamanho errado nunca e ponto")
    func wrongLength() {
        #expect(!Edwards25519.isOnCurve([UInt8](repeating: 0, count: 31)))
        #expect(!Edwards25519.isOnCurve([UInt8](repeating: 0, count: 33)))
    }

    // MARK: PDA

    @Test("createProgramAddress: solana-sdk (address/src/lib.rs) e web3.js (publickey.test.ts)")
    func createProgramAddress() throws {
        let ref = try SolanaFixtures.load("reference-vectors", as: SolanaFixtures.Reference.self)
        #expect(ref.createProgramAddress.count == 9)
        for vector in ref.createProgramAddress {
            let seeds = try vector.seeds.map { try SolanaFixtures.hex($0) }
            let address = try SolanaPDA.createProgramAddress(seeds: seeds, programID: try SolanaFixtures.key(vector.program))
            #expect(address.base58 == vector.expected, "\(vector.source)")
        }
    }

    @Test("findProgramAddress: Kit (program-derived-address-test.ts), inclusive bump 251")
    func findProgramAddress() throws {
        let ref = try SolanaFixtures.load("reference-vectors", as: SolanaFixtures.Reference.self)
        #expect(ref.findProgramAddress.count == 8)
        for vector in ref.findProgramAddress {
            let seeds = try vector.seeds.map { try SolanaFixtures.hex($0) }
            let program = try SolanaFixtures.key(vector.program)
            let (address, bump) = try SolanaPDA.findProgramAddress(seeds: seeds, programID: program)
            #expect(address.base58 == vector.expected, "\(vector.program)")
            #expect(bump == vector.bump)
            // Bump abaixo de 255 prova que os hashes dos bumps acima cairam NA curva:
            // cada um e um vetor positivo de ponto na curva vindo da referencia.
            for higher in stride(from: 255, to: Int(bump), by: -1) {
                let hash = Hash.sha256(seeds.flatMap { $0 } + [UInt8(higher)] + program.bytes + Array("ProgramDerivedAddress".utf8))
                #expect(Edwards25519.isOnCurve(hash), "bump \(higher) de \(vector.program)")
            }
        }
    }

    @Test("Limites de semente do solana-address")
    func seedLimits() throws {
        let program = try SolanaFixtures.key("BPFLoaderUpgradeab1e11111111111111111111111")
        #expect(throws: SolanaPDA.Problem.maxSeedLengthExceeded) {
            try SolanaPDA.createProgramAddress(seeds: [[UInt8](repeating: 127, count: 33)], programID: program)
        }
        #expect(throws: SolanaPDA.Problem.maxSeedsExceeded) {
            try SolanaPDA.createProgramAddress(seeds: (1...17).map { [UInt8($0)] }, programID: program)
        }
        _ = try SolanaPDA.createProgramAddress(seeds: [[UInt8](repeating: 0, count: 32)], programID: program)
        _ = try SolanaPDA.createProgramAddress(seeds: (1...16).map { [UInt8($0)] }, programID: program)
        // Com o bump, sobram 15 sementes para o find (Kit: "actual: 18, maxSeeds: 16").
        #expect(throws: SolanaPDA.Problem.maxSeedsExceeded) {
            try SolanaPDA.findProgramAddress(seeds: [[UInt8]](repeating: [], count: 16), programID: program)
        }
    }

    // MARK: ATA

    @Test("ATA: vetores do spl-token (index.test.ts) e contas reais da rede principal (USDC e PYUSD Token-2022)")
    func associatedTokenAddresses() throws {
        let ref = try SolanaFixtures.load("reference-vectors", as: SolanaFixtures.Reference.self)
        #expect(ref.associatedTokenAddress.count == 8)
        for vector in ref.associatedTokenAddress {
            let program = try #require(SolanaTokenProgram(rawValue: vector.program))
            let address = try SolanaAssociatedToken.address(
                owner: try SolanaFixtures.key(vector.owner), mint: try SolanaFixtures.key(vector.mint),
                tokenProgram: program, allowOwnerOffCurve: vector.allowOwnerOffCurve
            )
            #expect(address.base58 == vector.expected, "\(vector.source)")
        }
    }

    @Test("ATA de dono fora da curva e recusado sem confirmacao (TokenOwnerOffCurveError)")
    func ataOfAnATAIsRefused() throws {
        // spl-token, index.test.ts: getAssociatedTokenAddress(mint, ATA) rejeita.
        let ata = try SolanaFixtures.key("DShWnroshVbeUp28oopA3Pu7oFPDBtC1DBmPECXXAQ9n")
        let mint = try SolanaFixtures.key("7o36UsWR1JQLpZ9PE2gn9L4SQ69CNNiWAXd4Jt7rqz9Z")
        #expect(throws: SolanaAssociatedToken.Problem.ownerOffCurve) {
            try SolanaAssociatedToken.address(owner: ata, mint: mint, tokenProgram: .token)
        }
    }

    @Test("O mesmo mint da ATAs diferentes em Token e Token-2022")
    func programIsPartOfTheSeed() throws {
        let owner = try SolanaFixtures.key("86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY")
        let mint = try SolanaFixtures.key("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
        let classic = try SolanaAssociatedToken.address(owner: owner, mint: mint, tokenProgram: .token)
        let extensions = try SolanaAssociatedToken.address(owner: owner, mint: mint, tokenProgram: .token2022)
        #expect(classic != extensions)
        #expect(classic.base58 == "9SHQTA66Ekh7ZgMnKWsjxXk6DwXku8przs45E8bcEe38")
    }

    @Test("O endereco da tarefa para o USDC nao e o mint do USDC")
    func usdcMintLookalike() throws {
        // O pedido citava EPjFWJ5aTtV7dfbjbXf3aKstYEqLrDpBDQRbCnxjW3u, que nao existe na
        // rede principal (getAccountInfo nulo em 25/09/2026). O mint do USDC e
        // EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v. Mesmo prefixo, conta
        // diferente: o motivo de a revisao mostrar o mint inteiro.
        let lookalike = try SolanaFixtures.key("EPjFWJ5aTtV7dfbjbXf3aKstYEqLrDpBDQRbCnxjW3u")
        let usdc = try SolanaFixtures.key("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
        #expect(lookalike != usdc)
        #expect(lookalike.base58.prefix(5) == usdc.base58.prefix(5))
    }

    @Test("Chaves: Base58, ordem de bytes, Codable")
    func publicKeyBasics() throws {
        #expect(throws: SolanaPublicKey.Problem.malformed) { try SolanaPublicKey(base58: "12345") }
        #expect(throws: SolanaPublicKey.Problem.malformed) { try SolanaPublicKey(bytes: [0, 1]) }
        // web3.js, publickey.test.ts#toBase58
        let three = try SolanaPublicKey(bytes: [3] + [UInt8](repeating: 0, count: 31))
        #expect(three.base58 == "CiDwVBFgWV9E5MvXWoLgnEgn2hK7rJikbvfWavzAQz3")
        #expect(try SolanaPublicKey(bytes: [UInt8](repeating: 0, count: 32)).base58 == "11111111111111111111111111111111")
        #expect(try SolanaPublicKey(bytes: [UInt8](repeating: 0, count: 31) + [1]) < three)
        let encoded = try JSONEncoder().encode(three)
        #expect(try JSONDecoder().decode(SolanaPublicKey.self, from: encoded) == three)
    }
}
