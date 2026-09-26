import EscaliburCore
import Foundation

// O que o agregador propoe, lido do JSON e ainda sem nenhuma confianca.
//
// Esta camada so traduz o formato de instrucao da Jupiter ({programId, accounts
// [{pubkey, isSigner, isWritable}], data em base64}) para `SolanaInstruction`. Quem
// decide o que entra na mensagem e `SolanaSwapPlanner`: das instrucoes propostas so
// a de rota chega a mensagem, e so depois de decodificada e conferida; as de
// preparo e limpeza tem de ser iguais as que a carteira montaria sozinha, e a
// carteira usa as dela.
//
// Formato conferido ao vivo em 26/09/2026 contra `GET /swap/v2/build` e
// `GET /swap/v2/quote` (sem chave). Nomes de campo da documentacao da Jupiter.

/// A cotacao (`/swap/v2/quote`): serve para a tela mostrar o valor antes do dono
/// decidir. Nada daqui vai para a transacao.
public struct SolanaSwapQuote: Sendable, Equatable {
    public let inputMint: SolanaPublicKey
    public let outputMint: SolanaPublicKey
    public let inAmount: UInt64
    public let outAmount: UInt64
    /// O minimo com a tolerancia pedida, segundo o provedor.
    public let otherAmountThreshold: UInt64
    public let slippageBps: UInt16
    /// `platformFee.feeBps` quando o provedor aplicou taxa de plataforma; nil sem taxa.
    public let platformFeeBps: UInt16?
    /// Impacto no preco que o provedor declara, em porcento. So para aviso.
    public let priceImpactPercent: Double?

    public static func decodeJupiter(_ data: Data) throws -> SolanaSwapQuote {
        let raw: RawQuote
        do { raw = try JSONDecoder().decode(RawQuote.self, from: data) } catch { throw SolanaSwapProposalError.malformed("cotacao") }
        guard raw.swapMode == nil || raw.swapMode == "ExactIn" else { throw SolanaSwapProposalError.unsupportedSwapMode(raw.swapMode ?? "") }
        return SolanaSwapQuote(
            inputMint: try key(raw.inputMint), outputMint: try key(raw.outputMint),
            inAmount: try amount(raw.inAmount), outAmount: try amount(raw.outAmount),
            otherAmountThreshold: try amount(raw.otherAmountThreshold), slippageBps: raw.slippageBps,
            platformFeeBps: raw.platformFee?.feeBps, priceImpactPercent: percent(raw.priceImpactPct)
        )
    }
}

/// A proposta de troca (`/swap/v2/build`): cotacao mais instrucoes.
public struct SolanaSwapProposal: Sendable, Equatable {
    public let provider: String
    public let inputMint: SolanaPublicKey
    public let outputMint: SolanaPublicKey
    public let inAmount: UInt64
    public let outAmount: UInt64
    public let otherAmountThreshold: UInt64
    public let slippageBps: UInt16
    public let priceImpactPercent: Double?
    /// Preco de CU sugerido. Ignorado: a carteira estima e poe teto por conta propria.
    public let computeBudgetInstructions: [SolanaInstruction]
    public let setupInstructions: [SolanaInstruction]
    public let swapInstruction: SolanaInstruction
    public let cleanupInstruction: SolanaInstruction?
    public let otherInstructions: [SolanaInstruction]
    public let tipInstruction: SolanaInstruction?
    /// So os enderecos das tabelas. O conteudo que o provedor manda junto
    /// (`addressesByLookupTableAddress`) e descartado: a carteira le cada tabela da
    /// cadeia em dois RPCs.
    public let lookupTableAddresses: [SolanaPublicKey]

    public init(
        provider: String, inputMint: SolanaPublicKey, outputMint: SolanaPublicKey, inAmount: UInt64, outAmount: UInt64,
        otherAmountThreshold: UInt64, slippageBps: UInt16, priceImpactPercent: Double?,
        computeBudgetInstructions: [SolanaInstruction], setupInstructions: [SolanaInstruction], swapInstruction: SolanaInstruction,
        cleanupInstruction: SolanaInstruction?, otherInstructions: [SolanaInstruction], tipInstruction: SolanaInstruction?,
        lookupTableAddresses: [SolanaPublicKey]
    ) {
        self.provider = provider
        self.inputMint = inputMint
        self.outputMint = outputMint
        self.inAmount = inAmount
        self.outAmount = outAmount
        self.otherAmountThreshold = otherAmountThreshold
        self.slippageBps = slippageBps
        self.priceImpactPercent = priceImpactPercent
        self.computeBudgetInstructions = computeBudgetInstructions
        self.setupInstructions = setupInstructions
        self.swapInstruction = swapInstruction
        self.cleanupInstruction = cleanupInstruction
        self.otherInstructions = otherInstructions
        self.tipInstruction = tipInstruction
        self.lookupTableAddresses = lookupTableAddresses
    }

    public static func decodeJupiterBuild(_ data: Data) throws -> SolanaSwapProposal {
        let raw: RawBuild
        do { raw = try JSONDecoder().decode(RawBuild.self, from: data) } catch { throw SolanaSwapProposalError.malformed("build") }
        guard raw.swapMode == nil || raw.swapMode == "ExactIn" else { throw SolanaSwapProposalError.unsupportedSwapMode(raw.swapMode ?? "") }
        // A ordem das tabelas no JSON nao importa para a validade; a compilacao
        // percorre na ordem de bytes para o resultado nao depender do provedor.
        let tables = try (raw.addressesByLookupTableAddress ?? [:]).keys.map(key).sorted()
        return SolanaSwapProposal(
            provider: "Jupiter",
            inputMint: try key(raw.inputMint), outputMint: try key(raw.outputMint),
            inAmount: try amount(raw.inAmount), outAmount: try amount(raw.outAmount),
            otherAmountThreshold: try amount(raw.otherAmountThreshold), slippageBps: raw.slippageBps,
            priceImpactPercent: percent(raw.priceImpactPct),
            computeBudgetInstructions: try (raw.computeBudgetInstructions ?? []).map { try $0.instruction() },
            setupInstructions: try (raw.setupInstructions ?? []).map { try $0.instruction() },
            swapInstruction: try raw.swapInstruction.instruction(),
            cleanupInstruction: try raw.cleanupInstruction?.instruction(),
            otherInstructions: try (raw.otherInstructions ?? []).map { try $0.instruction() },
            tipInstruction: try raw.tipInstruction?.instruction(),
            lookupTableAddresses: tables
        )
    }
}

public enum SolanaSwapProposalError: Error, Equatable, Sendable {
    case malformed(String)
    case invalidKey(String)
    case invalidAmount(String)
    case unsupportedSwapMode(String)
}

// MARK: Formato cru

private struct RawPlatformFee: Decodable {
    let feeBps: UInt16?
}

private struct RawQuote: Decodable {
    let inputMint: String
    let outputMint: String
    let inAmount: String
    let outAmount: String
    let otherAmountThreshold: String
    let swapMode: String?
    let slippageBps: UInt16
    let platformFee: RawPlatformFee?
    let priceImpactPct: String?
}

private struct RawAccountMeta: Decodable {
    let pubkey: String
    let isSigner: Bool
    let isWritable: Bool
}

private struct RawInstruction: Decodable {
    let programId: String
    let accounts: [RawAccountMeta]
    let data: String

    func instruction() throws -> SolanaInstruction {
        guard let bytes = Data(base64Encoded: data) else { throw SolanaSwapProposalError.malformed("dados de instrucao") }
        return SolanaInstruction(
            programID: try key(programId),
            accounts: try accounts.map { SolanaAccountMeta(try key($0.pubkey), isSigner: $0.isSigner, isWritable: $0.isWritable) },
            data: Array(bytes)
        )
    }
}

private struct RawBuild: Decodable {
    let inputMint: String
    let outputMint: String
    let inAmount: String
    let outAmount: String
    let otherAmountThreshold: String
    let swapMode: String?
    let slippageBps: UInt16
    let priceImpactPct: String?
    let computeBudgetInstructions: [RawInstruction]?
    let setupInstructions: [RawInstruction]?
    let swapInstruction: RawInstruction
    let cleanupInstruction: RawInstruction?
    let otherInstructions: [RawInstruction]?
    let tipInstruction: RawInstruction?
    let addressesByLookupTableAddress: [String: [String]]?
}

private func key(_ text: String) throws -> SolanaPublicKey {
    do { return try SolanaPublicKey(base58: text) } catch { throw SolanaSwapProposalError.invalidKey(text) }
}

private func amount(_ text: String) throws -> UInt64 {
    guard let value = UInt64(text) else { throw SolanaSwapProposalError.invalidAmount(text) }
    return value
}

/// "0.0012" (fracao) vira 0,12 (porcento).
private func percent(_ text: String?) -> Double? {
    guard let text, let value = Double(text), value.isFinite else { return nil }
    return value * 100
}
