import EscaliburCore
import Foundation

// A simulacao como segunda opiniao (docs/seguranca.md §4.9).
//
// A camada de rede roda `simulateTransaction` pedindo o estado final das contas do
// dono; aqui fica so o formato neutro do resultado e a leitura do layout de conta
// de token, para que a conferencia do efeito seja pura e testavel. Drainers
// detectam simulacao, entao isto e a segunda camada, nunca a unica: a primeira e a
// decodificacao do que se assina.

/// O estado de uma conta, lido da cadeia ou do fim de uma simulacao.
public struct SolanaAccountSnapshot: Sendable, Equatable {
    public let address: SolanaPublicKey
    /// false quando a conta nao existe (ou deixou de existir, fechada na transacao).
    public let exists: Bool
    public let lamports: UInt64
    /// O programa dono da conta. nil se a conta nao existe.
    public let programOwner: SolanaPublicKey?
    /// Preenchidos quando a conta e uma conta de token (Token ou Token-2022).
    public let tokenMint: SolanaPublicKey?
    public let tokenOwner: SolanaPublicKey?
    public let tokenAmount: UInt64?

    public init(
        address: SolanaPublicKey, exists: Bool, lamports: UInt64, programOwner: SolanaPublicKey?,
        tokenMint: SolanaPublicKey? = nil, tokenOwner: SolanaPublicKey? = nil, tokenAmount: UInt64? = nil
    ) {
        self.address = address
        self.exists = exists
        self.lamports = lamports
        self.programOwner = programOwner
        self.tokenMint = tokenMint
        self.tokenOwner = tokenOwner
        self.tokenAmount = tokenAmount
    }

    public static func missing(_ address: SolanaPublicKey) -> SolanaAccountSnapshot {
        SolanaAccountSnapshot(address: address, exists: false, lamports: 0, programOwner: nil)
    }

    /// Le os bytes crus de uma conta. Conta de token: mint (0..32), dono (32..64),
    /// saldo u64 (64..72), o layout base do SPL Token, que o Token-2022 mantem.
    /// No Token-2022 uma conta com extensoes passa de 165 bytes e tem o tipo no
    /// byte 165 (2 = conta; 1 = mint); um mint com extensoes tambem passa de 165, e
    /// por isso o tipo e conferido.
    public static func parse(address: SolanaPublicKey, lamports: UInt64, programOwner: SolanaPublicKey, data: [UInt8]) -> SolanaAccountSnapshot {
        var isTokenAccount = false
        switch SolanaTokenProgram(programID: programOwner) {
        case .token: isTokenAccount = data.count == 165
        case .token2022: isTokenAccount = data.count == 165 || (data.count > 165 && data[165] == 2)
        case nil: break
        }
        guard isTokenAccount,
              let mint = try? SolanaPublicKey(bytes: Array(data[0..<32])),
              let owner = try? SolanaPublicKey(bytes: Array(data[32..<64]))
        else {
            return SolanaAccountSnapshot(address: address, exists: true, lamports: lamports, programOwner: programOwner)
        }
        var amount: UInt64 = 0
        for index in 0..<8 { amount |= UInt64(data[64 + index]) << (8 * index) }
        return SolanaAccountSnapshot(
            address: address, exists: true, lamports: lamports, programOwner: programOwner,
            tokenMint: mint, tokenOwner: owner, tokenAmount: amount
        )
    }
}

/// O resultado de `simulateTransaction`, ja traduzido pela camada de rede.
public struct SolanaSimulationOutcome: Sendable, Equatable {
    /// `value.err`, em texto. nil quando a simulacao passou.
    public let error: String?
    public let unitsConsumed: UInt64?
    /// O estado final das contas pedidas, na ordem pedida.
    public let accounts: [SolanaAccountSnapshot]
    public let logs: [String]

    public init(error: String?, unitsConsumed: UInt64?, accounts: [SolanaAccountSnapshot], logs: [String] = []) {
        self.error = error
        self.unitsConsumed = unitsConsumed
        self.accounts = accounts
        self.logs = logs
    }

    public var succeeded: Bool { error == nil }

    /// Limite de CU a partir do consumo simulado: consumo * 1,1, arredondado para
    /// cima, dentro do maximo do validador (docs/blockchain.md §2.3).
    public var suggestedComputeUnitLimit: UInt32? {
        guard let units = unitsConsumed, units > 0 else { return nil }
        let padded = units + (units + 9) / 10
        return UInt32(min(padded, UInt64(SolanaLimits.maxComputeUnitLimit)))
    }
}

/// Uma transacao sem assinatura, no formato de rede, so para simular com
/// `sigVerify: false`: a assinatura vai zerada. Nao serve para transmitir.
public enum SolanaSimulationEncoding {
    public static func unsignedTransactionBase64(_ message: SolanaMessage) -> String {
        let raw = SolanaShortVec.encode(Int(message.header.numRequiredSignatures))
            + [UInt8](repeating: 0, count: 64 * Int(message.header.numRequiredSignatures))
            + message.serialize()
        return Data(raw).base64EncodedString()
    }
}
