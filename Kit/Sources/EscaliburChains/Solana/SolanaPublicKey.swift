import EscaliburCore
import Foundation

/// Um endereco da Solana: 32 bytes, exibidos em Base58 (alfabeto do Bitcoin), sem
/// checksum. Uma letra trocada continua sendo um endereco valido de outra conta, por
/// isso a interface confere o endereco inteiro, e as contas derivadas aqui (PDA,
/// ATA) sao conferidas contra vetores das implementacoes de referencia.
public struct SolanaPublicKey: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public let bytes: [UInt8]

    public enum Problem: Error, Equatable, Sendable {
        case malformed
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw Problem.malformed }
        self.bytes = bytes
    }

    public init(base58 text: String) throws {
        guard (32...44).contains(text.count), let raw = Base58.bitcoin.decode(text), raw.count == 32 else {
            throw Problem.malformed
        }
        self.bytes = raw
    }

    /// So para constantes compiladas deste modulo: um literal errado tem de parar o
    /// programa no primeiro uso, nunca virar um endereco qualquer.
    init(constant text: String) {
        guard let key = try? SolanaPublicKey(base58: text) else {
            preconditionFailure("constante Solana invalida: \(text)")
        }
        self = key
    }

    public var base58: String { Base58.bitcoin.encode(bytes) }
    public var description: String { base58 }

    /// Ordem dos bytes, a mesma do `BTreeMap<Address, _>` do solana-sdk. E ela que
    /// decide a ordem das contas dentro de cada grupo da mensagem.
    public static func < (a: SolanaPublicKey, b: SolanaPublicKey) -> Bool {
        a.bytes.lexicographicallyPrecedes(b.bytes)
    }

    /// Estes 32 bytes sao um ponto da curva Ed25519 (portanto podem ter chave
    /// privada)? Um PDA nunca esta na curva. Ver Edwards25519.swift.
    public var isOnCurve: Bool { Edwards25519.isOnCurve(bytes) }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        try self.init(base58: text)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base58)
    }
}

// MARK: Enderecos derivados de programa

public enum SolanaPDA {
    public enum Problem: Error, Equatable, Sendable {
        /// Mais de 16 sementes (contando o bump), ou uma semente com mais de 32 bytes.
        case maxSeedsExceeded
        case maxSeedLengthExceeded
        /// O hash caiu na curva: este conjunto de sementes nao gera PDA.
        case onCurve
        /// Nenhum dos 256 bumps gerou endereco fora da curva.
        case noViableBump
    }

    /// Limites do `solana-address` (MAX_SEEDS, MAX_SEED_LEN).
    public static let maxSeeds = 16
    public static let maxSeedLength = 32
    static let marker = Array("ProgramDerivedAddress".utf8)

    /// `create_program_address`: sha256(sementes || programa || "ProgramDerivedAddress"),
    /// recusado se o resultado estiver na curva.
    public static func createProgramAddress(seeds: [[UInt8]], programID: SolanaPublicKey) throws -> SolanaPublicKey {
        guard seeds.count <= maxSeeds else { throw Problem.maxSeedsExceeded }
        guard seeds.allSatisfy({ $0.count <= maxSeedLength }) else { throw Problem.maxSeedLengthExceeded }
        let hash = Hash.sha256(seeds.flatMap { $0 } + programID.bytes + marker)
        guard !Edwards25519.isOnCurve(hash) else { throw Problem.onCurve }
        return try SolanaPublicKey(bytes: hash)
    }

    /// `find_program_address`: o primeiro bump, de 255 para baixo, cujo endereco
    /// cai fora da curva. O bump entra como a ultima semente, entao sobram 15 para
    /// o chamador.
    public static func findProgramAddress(seeds: [[UInt8]], programID: SolanaPublicKey) throws -> (address: SolanaPublicKey, bump: UInt8) {
        guard seeds.count < maxSeeds else { throw Problem.maxSeedsExceeded }
        guard seeds.allSatisfy({ $0.count <= maxSeedLength }) else { throw Problem.maxSeedLengthExceeded }
        var bump = UInt8.max
        while true {
            if let address = try? createProgramAddress(seeds: seeds + [[bump]], programID: programID) {
                return (address, bump)
            }
            if bump == 0 { throw Problem.noViableBump }
            bump -= 1
        }
    }
}

// MARK: Conta de token associada (ATA)

/// Os dois programas de token que a carteira movimenta.
public enum SolanaTokenProgram: String, Sendable, Codable, CaseIterable {
    /// SPL Token original.
    case token
    /// Token-2022 (Token Extensions).
    case token2022

    public var programID: SolanaPublicKey {
        switch self {
        case .token: return SolanaProgramID.token
        case .token2022: return SolanaProgramID.token2022
        }
    }

    public init?(programID: SolanaPublicKey) {
        switch programID {
        case SolanaProgramID.token: self = .token
        case SolanaProgramID.token2022: self = .token2022
        default: return nil
        }
    }
}

public enum SolanaAssociatedToken {
    public enum Problem: Error, Equatable, Sendable {
        /// O dono nao esta na curva: provavelmente o endereco colado ja e uma conta
        /// de token (ou outro PDA). Derivar o ATA de um ATA gera uma conta que
        /// ninguem consegue movimentar, e o token fica preso para sempre.
        case ownerOffCurve
    }

    /// O ATA de `owner` para `mint`: PDA do programa ATA com as sementes
    /// [dono, programa de token, mint]. O programa de token faz parte da semente, e
    /// por isso o mesmo mint em Token e Token-2022 da enderecos diferentes.
    ///
    /// `allowOwnerOffCurve` so deve ser ligado quando o dono comprovadamente e uma
    /// conta de programa que aceita token (cofre multisig, por exemplo), nunca
    /// para um endereco colado sem conferencia. E o mesmo contrato do
    /// `getAssociatedTokenAddress` do spl-token.
    public static func address(
        owner: SolanaPublicKey, mint: SolanaPublicKey, tokenProgram: SolanaTokenProgram, allowOwnerOffCurve: Bool = false
    ) throws -> SolanaPublicKey {
        if !allowOwnerOffCurve, !owner.isOnCurve { throw Problem.ownerOffCurve }
        return try SolanaPDA.findProgramAddress(
            seeds: [owner.bytes, tokenProgram.programID.bytes, mint.bytes],
            programID: SolanaProgramID.associatedToken
        ).address
    }
}
