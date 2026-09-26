import EscaliburCore
import Foundation

// A instrucao de rota da Jupiter v6, decodificada dos bytes que o dono assina.
//
// O agregador propoe a rota; o que vale e o que esta nos bytes. Daqui saem o valor
// que entra, o valor cotado, a tolerancia, a taxa de plataforma e as contas que
// importam (quem autoriza, de onde sai, para onde vai), e e contra isso que a
// validacao da troca confere a intencao do dono. O JSON da cotacao so serve para
// conferir consistencia: se ele disser uma coisa e os bytes outra, recusa.
//
// Fonte do formato: o IDL Anchor do proprio programa, lido na cadeia em 26/09/2026
// (conta C88XWfp26heEmDkmfSzeXP7Fd7GQJ2j9dDTUsyiZbUTa, a conta de IDL derivada de
// JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4). Discriminante Anchor =
// sha256("global:<nome>")[0..8]; os testes recalculam e conferem com o IDL.
//
// So as variantes v2 de entrada exata sao aceitas (`route_v2` e
// `shared_accounts_route_v2`), que sao as que o `/swap/v2/build` devolve hoje. Nelas
// os argumentos escalares vem ANTES do plano de rota, em posicoes fixas. Nas
// variantes antigas (`route`, `shared_accounts_route`) eles vem DEPOIS de um
// `Vec<RoutePlanStep>` cujo enum `Swap` tem 189 variantes de tamanhos diferentes, e
// o Anchor ignora bytes sobrando no fim: ler "os ultimos 19 bytes" deixaria um
// provedor anexar bytes e mentir o minimo. Sem decodificador completo, sem
// assinatura: essas variantes sao recusadas.

/// A rota decodificada.
public struct JupiterRoute: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case routeV2
        case sharedAccountsRouteV2
    }

    public let kind: Kind
    public let inAmount: UInt64
    /// O valor que a cotacao prometeu. O minimo garantido sai dele e da tolerancia.
    public let quotedOutAmount: UInt64
    public let slippageBps: UInt16
    /// Taxa do integrador, cobrada pelo programa. A Escalibur exige o valor compilado (zero).
    public let platformFeeBps: UInt16
    /// Fatia do ganho acima da cotacao que iria para o integrador. Exigido zero.
    public let positiveSlippageBps: UInt16
    /// Quem assina a saida dos tokens. Tem de ser o dono.
    public let userTransferAuthority: SolanaPublicKey
    public let sourceTokenAccount: SolanaPublicKey
    public let destinationTokenAccount: SolanaPublicKey
    /// So em `route_v2`: a conta de destino opcional. `nil` quando a Jupiter passou o
    /// marcador de ausente (o proprio id do programa, convencao do Anchor).
    public let optionalDestination: SolanaPublicKey?
    public let sourceMint: SolanaPublicKey
    public let destinationMint: SolanaPublicKey
    public let sourceTokenProgram: SolanaPublicKey
    public let destinationTokenProgram: SolanaPublicKey
    public let eventAuthority: SolanaPublicKey

    /// O minimo que o programa garante entregar: cotado menos a tolerancia,
    /// arredondado a favor do dono (q - piso(q * bps / 10000)). E o mesmo numero que
    /// a Jupiter devolve como `otherAmountThreshold`.
    public var minimumOut: UInt64 {
        Self.minimumOut(quoted: quotedOutAmount, slippageBps: slippageBps)
    }

    public static func minimumOut(quoted: UInt64, slippageBps: UInt16) -> UInt64 {
        // Tolerancia de 100% ou mais: nada garantido. Tambem evita que o quociente
        // abaixo passe de 64 bits.
        guard slippageBps < 10_000 else { return 0 }
        let (slice, _) = UInt64(10_000).dividingFullWidth(quoted.multipliedFullWidth(by: UInt64(slippageBps)))
        return quoted - slice
    }
}

public enum JupiterRouteError: Error, Equatable, Sendable {
    case notJupiterProgram(SolanaPublicKey)
    /// Discriminante de outra instrucao (as rotas antigas, as de saida exata, claim...).
    case unsupportedInstruction(discriminator: [UInt8])
    case malformed
    case tooFewAccounts(Int)
    case wrongEventAuthority(SolanaPublicKey)
    case wrongProgramAccount(SolanaPublicKey)
}

public enum JupiterRouteDecoder {
    /// Jupiter Aggregator v6. O mesmo literal de `SolanaProgramID.jupiterV6`,
    /// repetido aqui so para a comparacao ficar explicita no decodificador.
    public static var programID: SolanaPublicKey { SolanaProgramID.jupiterV6 }

    /// PDA ["__event_authority"] do programa (constante do IDL). Os testes derivam e conferem.
    public static let eventAuthority = SolanaPublicKey(constant: "D8cy77BBepLMngZx6ZukaTff5hCt1HrWyKk3Hnd9oitf")

    /// sha256("global:route_v2")[0..8]
    static let routeV2: [UInt8] = [187, 100, 250, 204, 49, 196, 175, 20]
    /// sha256("global:shared_accounts_route_v2")[0..8]
    static let sharedAccountsRouteV2: [UInt8] = [209, 152, 83, 147, 124, 254, 216, 233]

    /// Decodifica a instrucao de rota. `accounts` sao as chaves na ordem da
    /// instrucao, ja resolvidas (tabelas de enderecos incluidas).
    public static func decode(programID: SolanaPublicKey, accounts: [SolanaPublicKey], data: [UInt8]) throws -> JupiterRoute {
        guard programID == Self.programID else { throw JupiterRouteError.notJupiterProgram(programID) }
        guard data.count >= 8 else { throw JupiterRouteError.malformed }
        let discriminator = Array(data.prefix(8))
        var reader = LittleEndianReader(Array(data.dropFirst(8)))
        switch discriminator {
        case routeV2:
            // route_v2(in_amount u64, quoted_out_amount u64, slippage_bps u16,
            //          platform_fee_bps u16, positive_slippage_bps u16, route_plan Vec)
            // Contas: 0 user_transfer_authority, 1 user_source_token_account,
            // 2 user_destination_token_account, 3 source_mint, 4 destination_mint,
            // 5 source_token_program, 6 destination_token_program,
            // 7 destination_token_account (opcional), 8 event_authority, 9 program.
            guard accounts.count >= 10 else { throw JupiterRouteError.tooFewAccounts(accounts.count) }
            let scalars = try readScalars(&reader)
            try checkTail(eventAuthority: accounts[8], program: accounts[9])
            return JupiterRoute(
                kind: .routeV2, inAmount: scalars.inAmount, quotedOutAmount: scalars.quoted, slippageBps: scalars.slippage,
                platformFeeBps: scalars.platformFee, positiveSlippageBps: scalars.positiveSlippage,
                userTransferAuthority: accounts[0], sourceTokenAccount: accounts[1], destinationTokenAccount: accounts[2],
                optionalDestination: accounts[7] == Self.programID ? nil : accounts[7],
                sourceMint: accounts[3], destinationMint: accounts[4],
                sourceTokenProgram: accounts[5], destinationTokenProgram: accounts[6], eventAuthority: accounts[8]
            )
        case sharedAccountsRouteV2:
            // shared_accounts_route_v2(id u8, in_amount u64, quoted_out_amount u64,
            //          slippage_bps u16, platform_fee_bps u16, positive_slippage_bps u16, route_plan Vec)
            // Contas: 0 program_authority, 1 user_transfer_authority, 2 source_token_account,
            // 3 program_source_token_account, 4 program_destination_token_account,
            // 5 destination_token_account, 6 source_mint, 7 destination_mint,
            // 8 source_token_program, 9 destination_token_program, 10 event_authority, 11 program.
            guard accounts.count >= 12 else { throw JupiterRouteError.tooFewAccounts(accounts.count) }
            _ = try reader.read(UInt8.self)
            let scalars = try readScalars(&reader)
            try checkTail(eventAuthority: accounts[10], program: accounts[11])
            return JupiterRoute(
                kind: .sharedAccountsRouteV2, inAmount: scalars.inAmount, quotedOutAmount: scalars.quoted, slippageBps: scalars.slippage,
                platformFeeBps: scalars.platformFee, positiveSlippageBps: scalars.positiveSlippage,
                userTransferAuthority: accounts[1], sourceTokenAccount: accounts[2], destinationTokenAccount: accounts[5],
                optionalDestination: nil,
                sourceMint: accounts[6], destinationMint: accounts[7],
                sourceTokenProgram: accounts[8], destinationTokenProgram: accounts[9], eventAuthority: accounts[10]
            )
        default:
            throw JupiterRouteError.unsupportedInstruction(discriminator: discriminator)
        }
    }

    private struct Scalars {
        let inAmount: UInt64
        let quoted: UInt64
        let slippage: UInt16
        let platformFee: UInt16
        let positiveSlippage: UInt16
    }

    private static func readScalars(_ reader: inout LittleEndianReader) throws -> Scalars {
        let scalars = Scalars(
            inAmount: try reader.read(UInt64.self), quoted: try reader.read(UInt64.self), slippage: try reader.read(UInt16.self),
            platformFee: try reader.read(UInt16.self), positiveSlippage: try reader.read(UInt16.self)
        )
        // O plano de rota vem depois: pelo menos o comprimento do Vec (u32) e um passo.
        let steps = try reader.read(UInt32.self)
        guard steps > 0 else { throw JupiterRouteError.malformed }
        return scalars
    }

    private static func checkTail(eventAuthority: SolanaPublicKey, program: SolanaPublicKey) throws {
        guard eventAuthority == Self.eventAuthority else { throw JupiterRouteError.wrongEventAuthority(eventAuthority) }
        guard program == Self.programID else { throw JupiterRouteError.wrongProgramAccount(program) }
    }
}

/// Leitor little-endian para dados Borsh.
struct LittleEndianReader {
    let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= bytes.count else { throw JupiterRouteError.malformed }
        var value: T = 0
        for index in 0..<size {
            value |= T(bytes[offset + index]) << (8 * index)
        }
        offset += size
        return value
    }
}
