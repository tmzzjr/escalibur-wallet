import EscaliburCore
import Foundation

/// Enderecos de programa, compilados. Nunca vem de resposta de rede: um programa
/// trocado numa resposta faria a carteira montar (e o dono assinar) uma instrucao
/// para um contrato qualquer. Os seis foram conferidos executaveis na rede
/// principal por `getAccountInfo` em 25/09/2026.
public enum SolanaProgramID {
    /// solana-sdk, `solana_sdk_ids::system_program`.
    public static let system = SolanaPublicKey(constant: "11111111111111111111111111111111")
    /// solana-sdk, `solana_sdk_ids::compute_budget`.
    public static let computeBudget = SolanaPublicKey(constant: "ComputeBudget111111111111111111111111111111")
    /// solana-program/token, `declare_id!` do programa SPL Token.
    public static let token = SolanaPublicKey(constant: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
    /// solana-program/token-2022, `declare_id!`.
    public static let token2022 = SolanaPublicKey(constant: "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")
    /// solana-program/associated-token-account, `declare_id!`.
    public static let associatedToken = SolanaPublicKey(constant: "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")
    /// Jupiter Aggregator v6 (docs de integracao da Jupiter). So entra aqui para a
    /// camada de troca futura. E um programa atualizavel (BPFLoaderUpgradeable):
    /// confiar nele e confiar em quem detem a autoridade de atualizacao, e por isso
    /// cada mensagem pede a Jupiter explicitamente na politica do verificador.
    public static let jupiterV6 = SolanaPublicKey(constant: "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4")
}

/// A lista de programas que uma mensagem assinada por esta carteira pode invocar
/// (docs/seguranca.md §4.6). E um enum, nao uma lista de enderecos: nao existe
/// jeito de acrescentar um programa em tempo de execucao, so de usar um
/// subconjunto destes.
public enum SolanaProgram: String, Sendable, CaseIterable, Codable {
    case computeBudget
    case system
    case token
    case token2022
    case associatedToken
    case jupiterV6

    public var id: SolanaPublicKey {
        switch self {
        case .computeBudget: return SolanaProgramID.computeBudget
        case .system: return SolanaProgramID.system
        case .token: return SolanaProgramID.token
        case .token2022: return SolanaProgramID.token2022
        case .associatedToken: return SolanaProgramID.associatedToken
        case .jupiterV6: return SolanaProgramID.jupiterV6
        }
    }

    public init?(id: SolanaPublicKey) {
        guard let found = Self.allCases.first(where: { $0.id == id }) else { return nil }
        self = found
    }
}

// MARK: Construtores de instrucao

/// System Program. Os dados sao o enum `SystemInstruction` em bincode:
/// discriminante u32 little-endian seguido dos campos.
public enum SolanaSystemInstruction {
    static let transferTag: UInt32 = 2

    /// `Transfer { lamports }`: contas [origem (gravavel, assina), destino (gravavel)].
    public static func transfer(from: SolanaPublicKey, to: SolanaPublicKey, lamports: UInt64) -> SolanaInstruction {
        SolanaInstruction(
            programID: SolanaProgramID.system,
            accounts: [
                SolanaAccountMeta(from, isSigner: true, isWritable: true),
                SolanaAccountMeta(to, isSigner: false, isWritable: true),
            ],
            data: transferTag.littleEndianByteArray + lamports.littleEndianByteArray
        )
    }
}

/// Compute Budget. Um byte de discriminante e o valor em little-endian, sem contas.
public enum SolanaComputeBudgetInstruction {
    static let setComputeUnitLimitTag: UInt8 = 2
    static let setComputeUnitPriceTag: UInt8 = 3

    /// Teto de unidades de computacao da transacao inteira.
    public static func setComputeUnitLimit(_ units: UInt32) -> SolanaInstruction {
        SolanaInstruction(programID: SolanaProgramID.computeBudget, accounts: [], data: [setComputeUnitLimitTag] + units.littleEndianByteArray)
    }

    /// Preco de prioridade em micro-lamports por unidade de computacao. A taxa de
    /// prioridade cobrada e teto(preco * limite / 1.000.000) lamports.
    public static func setComputeUnitPrice(microLamports: UInt64) -> SolanaInstruction {
        SolanaInstruction(programID: SolanaProgramID.computeBudget, accounts: [], data: [setComputeUnitPriceTag] + microLamports.littleEndianByteArray)
    }
}

/// SPL Token e Token-2022 (mesmo layout para as instrucoes basicas).
public enum SolanaTokenInstruction {
    static let transferCheckedTag: UInt8 = 12

    /// `TransferChecked { amount, decimals }`: contas [origem (gravavel), mint,
    /// destino (gravavel), dono (assina)]. O "checked" faz o programa conferir o
    /// mint e as casas decimais: um valor montado com as casas erradas (100 USDC
    /// virando 100.000.000) falha em vez de transferir.
    public static func transferChecked(
        tokenProgram: SolanaTokenProgram, source: SolanaPublicKey, mint: SolanaPublicKey, destination: SolanaPublicKey,
        owner: SolanaPublicKey, amount: UInt64, decimals: UInt8
    ) -> SolanaInstruction {
        SolanaInstruction(
            programID: tokenProgram.programID,
            accounts: [
                SolanaAccountMeta(source, isSigner: false, isWritable: true),
                SolanaAccountMeta(mint, isSigner: false, isWritable: false),
                SolanaAccountMeta(destination, isSigner: false, isWritable: true),
                SolanaAccountMeta(owner, isSigner: true, isWritable: false),
            ],
            data: [transferCheckedTag] + amount.littleEndianByteArray + [decimals]
        )
    }
}

/// Associated Token Account program.
public enum SolanaAssociatedTokenInstruction {
    static let createIdempotentTag: UInt8 = 1

    /// `CreateIdempotent`: cria o ATA se ainda nao existir e nao falha se existir.
    /// Contas: [pagador (gravavel, assina), ATA (gravavel), dono da carteira, mint,
    /// System Program, programa de token]. O pagador paga o rent da conta nova.
    public static func createIdempotent(
        payer: SolanaPublicKey, associatedAccount: SolanaPublicKey, owner: SolanaPublicKey, mint: SolanaPublicKey,
        tokenProgram: SolanaTokenProgram
    ) -> SolanaInstruction {
        SolanaInstruction(
            programID: SolanaProgramID.associatedToken,
            accounts: [
                SolanaAccountMeta(payer, isSigner: true, isWritable: true),
                SolanaAccountMeta(associatedAccount, isSigner: false, isWritable: true),
                SolanaAccountMeta(owner, isSigner: false, isWritable: false),
                SolanaAccountMeta(mint, isSigner: false, isWritable: false),
                SolanaAccountMeta(SolanaProgramID.system, isSigner: false, isWritable: false),
                SolanaAccountMeta(tokenProgram.programID, isSigner: false, isWritable: false),
            ],
            data: [createIdempotentTag]
        )
    }
}
