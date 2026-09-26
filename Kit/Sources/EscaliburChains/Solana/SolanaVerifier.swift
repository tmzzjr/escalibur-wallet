import EscaliburCore
import Foundation

// O verificador: le uma mensagem (compilada aqui ou vinda de um agregador) e
// decide se o dono pode assinar. Fail-closed: o que ele nao reconhece, recusa.
//
// Ele olha as instrucoes de primeiro nivel. O que um programa permitido faz por
// dentro (as chamadas entre programas de uma rota da Jupiter, por exemplo) nao
// aparece na mensagem; para isso existe a simulacao (docs/seguranca.md §4.9) e a
// validacao dos argumentos da troca, que e da camada de troca.
//
// Recusas (docs/seguranca.md §4.1 e §4.6, docs/blockchain.md §2.3 e §3.5):
//   - pagador da taxa diferente do dono, ou outro signatario alem do dono;
//   - programa fora da lista compilada (ou fora do subconjunto pedido);
//   - AdvanceNonceAccount (nonce duravel: a transacao nao expira, tatica de
//     drainer), em qualquer posicao; na primeira, com motivo proprio;
//   - System Assign e qualquer instrucao do System Program alem de Transfer;
//   - Transfer de SOL, ou de token, para conta fora da lista de destinos aceitos;
//   - SPL Token: SetAuthority, Approve e ApproveChecked (delegado), CloseAccount
//     com destino diferente do dono, e tudo que nao estiver na lista curta;
//   - criacao de ATA para terceiro que nao seja o destino aceito (cada conta nova
//     custa o rent ao dono: uma mensagem com dez delas drena SOL);
//   - preco de CU vezes limite de CU acima do teto.

/// Tetos de taxa, compilados. A resposta de rede sugere um preco; estes numeros
/// dizem ate onde a carteira aceita ir, e um provedor malicioso nao os muda.
public enum SolanaLimits {
    /// Taxa base por assinatura, em lamports: 5.000 na rede principal
    /// (docs/blockchain.md §2.3). So entra na conta do saldo; quem cobra e a rede.
    public static let lamportsPerSignature: UInt64 = 5_000
    /// Teto do preco de prioridade: 10 lamports por unidade de computacao.
    public static let maxComputeUnitPrice: UInt64 = 10_000_000
    /// Teto da taxa de prioridade de uma transacao: 0,002 SOL.
    public static let maxPriorityFeeLamports: UInt64 = 2_000_000
    /// Limite de CU que o validador aceita numa transacao.
    public static let maxComputeUnitLimit: UInt32 = 1_400_000

    /// teto(preco * limite / 1.000.000), a conta do validador.
    public static func priorityFee(microLamportsPerUnit price: UInt64, units: UInt32) -> BigUInt {
        let product = BigUInt(price) * BigUInt(units)
        return (product + BigUInt(999_999)) / BigUInt(1_000_000)
    }
}

/// O que o verificador aceita, para uma mensagem especifica. O chamador so pode
/// estreitar a lista de programas, nunca ampliar.
public struct SolanaVerificationPolicy: Sendable {
    public let owner: SolanaPublicKey
    public let allowedPrograms: Set<SolanaProgram>
    /// Destinos aceitos: para Transfer de SOL, para a conta de destino de
    /// Transfer/TransferChecked de token e para ATA criado em nome de terceiro.
    /// Vazio: nenhuma transferencia passa.
    public let allowedRecipients: Set<SolanaPublicKey>
    public let maxPriorityFeeLamports: UInt64

    /// Sem valor padrao para os programas: quem chama diz quais espera, e o que
    /// nao disse fica recusado.
    public init(
        owner: SolanaPublicKey, allowedPrograms: Set<SolanaProgram>,
        allowedRecipients: Set<SolanaPublicKey> = [], maxPriorityFeeLamports: UInt64 = SolanaLimits.maxPriorityFeeLamports
    ) {
        self.owner = owner
        self.allowedPrograms = allowedPrograms
        self.allowedRecipients = allowedRecipients
        self.maxPriorityFeeLamports = min(maxPriorityFeeLamports, SolanaLimits.maxPriorityFeeLamports)
    }
}

/// Uma instrucao de primeiro nivel, decodificada.
public enum SolanaAction: Sendable, Equatable {
    case setComputeUnitLimit(UInt32)
    case setComputeUnitPrice(microLamports: UInt64)
    case setLoadedAccountsDataSizeLimit(UInt32)
    case requestHeapFrame(UInt32)
    case transferSOL(from: SolanaPublicKey, to: SolanaPublicKey, lamports: UInt64)
    case transferToken(program: SolanaTokenProgram, source: SolanaPublicKey, mint: SolanaPublicKey?, destination: SolanaPublicKey, authority: SolanaPublicKey, amount: UInt64, decimals: UInt8?)
    case closeTokenAccount(program: SolanaTokenProgram, account: SolanaPublicKey, destination: SolanaPublicKey)
    case syncNative(program: SolanaTokenProgram, account: SolanaPublicKey)
    case revokeDelegate(program: SolanaTokenProgram, account: SolanaPublicKey)
    case createAssociatedTokenAccount(idempotent: Bool, payer: SolanaPublicKey, account: SolanaPublicKey, owner: SolanaPublicKey, mint: SolanaPublicKey, tokenProgram: SolanaPublicKey)
    /// Instrucao da Jupiter: aceita pelo programa, argumentos conferidos pela camada de troca.
    case jupiter(data: [UInt8])
}

public struct SolanaVerifiedMessage: Sendable, Equatable {
    public let actions: [SolanaAction]
    public let computeUnitLimit: UInt32?
    public let computeUnitPrice: UInt64?
    /// A maior taxa de prioridade que esta mensagem pode cobrar, em lamports.
    public let maxPriorityFee: BigUInt
}

public enum SolanaVerificationError: Error, Equatable, Sendable {
    case malformed(SolanaMessage.Problem)
    case feePayerNotOwner(SolanaPublicKey?)
    case unexpectedSigners(Int)
    case programNotAllowed(SolanaPublicKey)
    case durableNonceFirstInstruction
    case durableNonce
    case assignAccount(SolanaPublicKey)
    case setAuthority
    case approveDelegate
    case closeAccountToStranger(SolanaPublicKey)
    /// CreateIdempotent/Create de conta de token para outra carteira que nao o destino aceito.
    case createsAccountForStranger(SolanaPublicKey)
    case transferToUnknown(SolanaPublicKey)
    case forbiddenInstruction(SolanaProgram, discriminator: UInt32)
    case malformedInstruction(SolanaProgram)
    case duplicateComputeBudget
    case priorityFeeAboveCap(fee: BigUInt, cap: UInt64)
}

public enum SolanaMessageVerifier {
    /// Confere a mensagem inteira contra a politica. `lookupTables` e o conteudo das
    /// tabelas citadas (v0), lido da cadeia pelo chamador.
    public static func verify(
        _ message: SolanaMessage, policy: SolanaVerificationPolicy, lookupTables: [SolanaAddressLookupTable] = []
    ) throws -> SolanaVerifiedMessage {
        do {
            try message.sanitize()
        } catch let problem as SolanaMessage.Problem {
            throw SolanaVerificationError.malformed(problem)
        }
        // Quem paga e quem assina vem so das chaves estaticas: conferido antes de
        // olhar qualquer tabela.
        guard message.feePayer == policy.owner else { throw SolanaVerificationError.feePayerNotOwner(message.feePayer) }
        guard message.header.numRequiredSignatures == 1 else {
            throw SolanaVerificationError.unexpectedSigners(Int(message.header.numRequiredSignatures))
        }
        let loaded: SolanaLoadedAddresses
        do {
            loaded = try message.resolveLookups(lookupTables)
            try message.sanitize(loaded: loaded)
        } catch let problem as SolanaMessage.Problem {
            throw SolanaVerificationError.malformed(problem)
        }

        let keys = message.accountKeys(loaded: loaded)
        var actions = [SolanaAction]()
        var limit: UInt32?
        var price: UInt64?
        var seenBudget = Set<UInt8>()

        for (position, ix) in message.instructions.enumerated() {
            let programID = keys[Int(ix.programIDIndex)]
            guard let program = SolanaProgram(id: programID), policy.allowedPrograms.contains(program) else {
                throw SolanaVerificationError.programNotAllowed(programID)
            }
            let accounts = ix.accountIndexes.map { keys[Int($0)] }
            switch program {
            case .computeBudget:
                let action = try decodeComputeBudget(ix.data, accountCount: accounts.count)
                guard seenBudget.insert(ix.data[0]).inserted else { throw SolanaVerificationError.duplicateComputeBudget }
                if case .setComputeUnitLimit(let units) = action { limit = units }
                if case .setComputeUnitPrice(let microLamports) = action { price = microLamports }
                actions.append(action)
            case .system:
                actions.append(try decodeSystem(ix.data, accounts: accounts, isFirst: position == 0, policy: policy))
            case .token, .token2022:
                let tokenProgram: SolanaTokenProgram = program == .token ? .token : .token2022
                actions.append(try decodeToken(ix.data, accounts: accounts, program: tokenProgram, policy: policy))
            case .associatedToken:
                actions.append(try decodeAssociatedToken(ix.data, accounts: accounts, policy: policy))
            case .jupiterV6:
                actions.append(.jupiter(data: ix.data))
            }
        }

        // Sem limite explicito, o validador pode usar ate o maximo: o teto e
        // conferido contra o pior caso. Limite declarado acima do maximo o validador
        // reduz ao maximo, e a conta aqui faz o mesmo.
        let units = min(limit ?? SolanaLimits.maxComputeUnitLimit, SolanaLimits.maxComputeUnitLimit)
        let fee = SolanaLimits.priorityFee(microLamportsPerUnit: price ?? 0, units: units)
        guard fee <= BigUInt(policy.maxPriorityFeeLamports) else {
            throw SolanaVerificationError.priorityFeeAboveCap(fee: fee, cap: policy.maxPriorityFeeLamports)
        }
        return SolanaVerifiedMessage(actions: actions, computeUnitLimit: limit, computeUnitPrice: price, maxPriorityFee: fee)
    }

    // MARK: Compute Budget

    static func decodeComputeBudget(_ data: [UInt8], accountCount: Int) throws -> SolanaAction {
        guard let tag = data.first, accountCount == 0 else { throw SolanaVerificationError.malformedInstruction(.computeBudget) }
        let body = Array(data.dropFirst())
        switch (tag, body.count) {
        case (1, 4): return .requestHeapFrame(littleEndian(body, as: UInt32.self))
        case (2, 4): return .setComputeUnitLimit(littleEndian(body, as: UInt32.self))
        case (3, 8): return .setComputeUnitPrice(microLamports: littleEndian(body, as: UInt64.self))
        case (4, 4): return .setLoadedAccountsDataSizeLimit(littleEndian(body, as: UInt32.self))
        case (1...4, _): throw SolanaVerificationError.malformedInstruction(.computeBudget)
        default: throw SolanaVerificationError.forbiddenInstruction(.computeBudget, discriminator: UInt32(tag))
        }
    }

    // MARK: System

    static let systemAssign: UInt32 = 1
    static let systemTransfer: UInt32 = 2
    static let systemAdvanceNonce: UInt32 = 4
    static let systemAssignWithSeed: UInt32 = 10

    static func decodeSystem(_ data: [UInt8], accounts: [SolanaPublicKey], isFirst: Bool, policy: SolanaVerificationPolicy) throws -> SolanaAction {
        guard data.count >= 4 else { throw SolanaVerificationError.malformedInstruction(.system) }
        let tag = littleEndian(Array(data.prefix(4)), as: UInt32.self)
        switch tag {
        case systemTransfer:
            guard data.count == 12, accounts.count == 2 else { throw SolanaVerificationError.malformedInstruction(.system) }
            let to = accounts[1]
            guard policy.allowedRecipients.contains(to) else { throw SolanaVerificationError.transferToUnknown(to) }
            return .transferSOL(from: accounts[0], to: to, lamports: littleEndian(Array(data[4..<12]), as: UInt64.self))
        case systemAdvanceNonce:
            throw isFirst ? SolanaVerificationError.durableNonceFirstInstruction : SolanaVerificationError.durableNonce
        case systemAssign, systemAssignWithSeed:
            throw SolanaVerificationError.assignAccount(accounts.first ?? policy.owner)
        default:
            throw SolanaVerificationError.forbiddenInstruction(.system, discriminator: tag)
        }
    }

    // MARK: SPL Token e Token-2022

    static func decodeToken(_ data: [UInt8], accounts: [SolanaPublicKey], program: SolanaTokenProgram, policy: SolanaVerificationPolicy) throws -> SolanaAction {
        let which: SolanaProgram = program == .token ? .token : .token2022
        guard let tag = data.first else { throw SolanaVerificationError.malformedInstruction(which) }
        switch tag {
        case 3:  // Transfer { amount }: [origem, destino, autoridade]
            guard data.count == 9, accounts.count >= 3 else { throw SolanaVerificationError.malformedInstruction(which) }
            guard policy.allowedRecipients.contains(accounts[1]) else { throw SolanaVerificationError.transferToUnknown(accounts[1]) }
            return .transferToken(program: program, source: accounts[0], mint: nil, destination: accounts[1], authority: accounts[2],
                                  amount: littleEndian(Array(data[1..<9]), as: UInt64.self), decimals: nil)
        case 12:  // TransferChecked { amount, decimals }: [origem, mint, destino, autoridade]
            guard data.count == 10, accounts.count >= 4 else { throw SolanaVerificationError.malformedInstruction(which) }
            guard policy.allowedRecipients.contains(accounts[2]) else { throw SolanaVerificationError.transferToUnknown(accounts[2]) }
            return .transferToken(program: program, source: accounts[0], mint: accounts[1], destination: accounts[2], authority: accounts[3],
                                  amount: littleEndian(Array(data[1..<9]), as: UInt64.self), decimals: data[9])
        case 4, 13:  // Approve, ApproveChecked
            throw SolanaVerificationError.approveDelegate
        case 5:  // Revoke: tira o delegado, so reduz poder de terceiros.
            guard data.count == 1, accounts.count >= 2 else { throw SolanaVerificationError.malformedInstruction(which) }
            return .revokeDelegate(program: program, account: accounts[0])
        case 6:  // SetAuthority
            throw SolanaVerificationError.setAuthority
        case 9:  // CloseAccount: [conta, destino dos lamports, autoridade]
            guard data.count == 1, accounts.count >= 3 else { throw SolanaVerificationError.malformedInstruction(which) }
            guard accounts[1] == policy.owner else { throw SolanaVerificationError.closeAccountToStranger(accounts[1]) }
            return .closeTokenAccount(program: program, account: accounts[0], destination: accounts[1])
        case 17:  // SyncNative: [conta de SOL embrulhado]
            guard data.count == 1, accounts.count == 1 else { throw SolanaVerificationError.malformedInstruction(which) }
            return .syncNative(program: program, account: accounts[0])
        default:
            throw SolanaVerificationError.forbiddenInstruction(which, discriminator: UInt32(tag))
        }
    }

    // MARK: Associated Token Account

    static func decodeAssociatedToken(_ data: [UInt8], accounts: [SolanaPublicKey], policy: SolanaVerificationPolicy) throws -> SolanaAction {
        // Dados vazios (formato antigo) ou [0] = Create; [1] = CreateIdempotent.
        // [2] = RecoverNested e qualquer outra coisa ficam de fora.
        let idempotent: Bool
        switch data {
        case [], [0]: idempotent = false
        case [1]: idempotent = true
        default:
            throw SolanaVerificationError.forbiddenInstruction(.associatedToken, discriminator: UInt32(data.first ?? 0))
        }
        guard accounts.count == 6, accounts[4] == SolanaProgramID.system,
              SolanaTokenProgram(programID: accounts[5]) != nil
        else { throw SolanaVerificationError.malformedInstruction(.associatedToken) }
        // Conta do proprio dono (rent recuperavel ao fechar) ou a conta de destino
        // aceita. O programa ATA ja confere que o endereco e o derivado.
        guard accounts[2] == policy.owner || policy.allowedRecipients.contains(accounts[1]) else {
            throw SolanaVerificationError.createsAccountForStranger(accounts[2])
        }
        return .createAssociatedTokenAccount(
            idempotent: idempotent, payer: accounts[0], account: accounts[1], owner: accounts[2], mint: accounts[3], tokenProgram: accounts[5]
        )
    }
}

extension SolanaMessageVerifier {
    /// Inteiro little-endian de exatamente o tamanho do tipo.
    static func littleEndian<T: FixedWidthInteger>(_ bytes: [UInt8], as type: T.Type = T.self) -> T {
        precondition(bytes.count == MemoryLayout<T>.size)
        var value: T = 0
        for (index, byte) in bytes.enumerated() {
            value |= T(byte) << (8 * index)
        }
        return value
    }
}
