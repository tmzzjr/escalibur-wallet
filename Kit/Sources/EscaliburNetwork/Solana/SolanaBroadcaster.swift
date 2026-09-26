import EscaliburChains
import EscaliburCore
import Foundation

// Transmissao e acompanhamento.
//
// Os mesmos bytes assinados vao para dois provedores ao mesmo tempo, e sao
// reenviados (os mesmos bytes, nunca reassinados: o Ed25519 do CryptoKit e
// aleatorizado e outra assinatura seria outro id) ate a rede confirmar ou ate a
// altura de bloco passar do `lastValidBlockHeight`, quando a transacao nunca mais
// pode entrar.
//
// O `/tx/v1/submit` da Jupiter (e o novo `tx.jup.ag`) existe e aceita a chamada sem
// chave, mas exige uma gorjeta de pelo menos 0,001 SOL para uma das 16 contas de
// gorjeta da Jupiter DENTRO da transacao (conferido em 26/09/2026: sem ela recusa
// com "Transaction must include a Jupiter tip instruction"). Como os mesmos bytes
// vao a todos os provedores, a gorjeta seria cobrada em todo envio, e o verificador
// recusa transferencia de SOL para conta fora do destino. Por isso nao e terceira via.

/// O resultado do envio.
public struct SolanaBroadcastReceipt: Sendable, Equatable {
    /// O id da transacao (a primeira assinatura), o mesmo de `SignedTransaction.id`.
    public let signature: String
    /// Provedores que aceitaram.
    public let acceptedBy: [String]
    /// Provedores que recusaram, com o motivo.
    public let rejections: [String: String]
}

public enum SolanaBroadcastError: Error, Sendable, Equatable {
    case wrongChain
    case malformedTransaction
    /// A simulacao previa do no (`skipPreflight: false`) recusou: a transacao falharia.
    case preflightFailed(String)
    /// Nenhum provedor aceitou.
    case rejected([String: String])
}

/// Onde a transacao esta.
public enum SolanaConfirmation: Sendable, Equatable {
    /// O no ainda nao viu, e o blockhash ainda vale.
    case pending
    case processed(slot: UInt64)
    case confirmed(slot: UInt64)
    case finalized(slot: UInt64)
    /// Entrou num bloco e falhou: a taxa foi cobrada, o resto nao aconteceu.
    case failed(slot: UInt64, error: String)
    /// O blockhash venceu sem a transacao entrar: nunca mais entra. Pode montar outra.
    case expired

    public var isFinal: Bool {
        switch self {
        case .finalized, .failed, .expired: return true
        case .pending, .processed, .confirmed: return false
        }
    }
}

/// Ate onde acompanhar.
public enum SolanaCommitment: String, Sendable {
    case processed, confirmed, finalized
}

public enum SolanaConfirmationTracker {
    /// O estado a partir do `getSignatureStatuses` e da altura de bloco atual.
    public static func evaluate(status: SolanaSignatureStatus?, currentBlockHeight: UInt64, lastValidBlockHeight: UInt64) -> SolanaConfirmation {
        guard let status else {
            return currentBlockHeight > lastValidBlockHeight ? .expired : .pending
        }
        if let error = status.error { return .failed(slot: status.slot, error: error) }
        switch status.confirmationStatus {
        case "finalized": return .finalized(slot: status.slot)
        case "confirmed": return .confirmed(slot: status.slot)
        default: return .processed(slot: status.slot)
        }
    }
}

/// Uma linha do `getSignatureStatuses`.
public struct SolanaSignatureStatus: Sendable, Equatable {
    public let slot: UInt64
    public let confirmationStatus: String?
    public let error: String?

    public init(slot: UInt64, confirmationStatus: String?, error: String?) {
        self.slot = slot
        self.confirmationStatus = confirmationStatus
        self.error = error
    }

    init(_ raw: RPCSignatureStatus) {
        self.init(slot: raw.slot, confirmationStatus: raw.confirmationStatus, error: raw.err.flatMap { $0.isNull ? nil : $0.compactText })
    }
}

public actor SolanaBroadcaster {
    public static let shared = SolanaBroadcaster()

    let client: HTTPClient
    let pool: ProviderPool
    let reader: SolanaNetworkReader

    public init(client: HTTPClient = .shared, providers: [ProviderPool.Provider] = Endpoints.solana, reader: SolanaNetworkReader = .shared) {
        self.client = client
        self.pool = ProviderPool(providers)
        self.reader = reader
    }

    /// Envia para dois provedores ao mesmo tempo, com `skipPreflight: false` (o no
    /// simula antes e recusa o que falharia). Basta um aceitar.
    public func send(_ signed: SignedTransaction) async throws -> SolanaBroadcastReceipt {
        try await send(signed, skipPreflight: false)
    }

    func send(_ signed: SignedTransaction, skipPreflight: Bool) async throws -> SolanaBroadcastReceipt {
        guard signed.chainID == Chain.solana.id else { throw SolanaBroadcastError.wrongChain }
        // Os bytes que vao sao os bytes assinados; o base64 e conferido contra eles.
        guard Data(base64Encoded: signed.encoded).map(Array.init) == signed.raw else { throw SolanaBroadcastError.malformedTransaction }
        let providers = Array(await pool.available().prefix(2))
        let client = self.client
        let params: [JSONValue] = [
            .string(signed.encoded),
            .object([
                "encoding": .string("base64"), "skipPreflight": .bool(skipPreflight),
                "preflightCommitment": .string("confirmed"), "maxRetries": .number(0),
            ]),
        ]
        let outcomes = await withTaskGroup(of: (String, Result<String, Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let signature: String = try await SolanaRPC.call(provider.baseURL, "sendTransaction", params, client: client)
                        return (provider.name, .success(signature))
                    } catch {
                        return (provider.name, .failure(error))
                    }
                }
            }
            var all = [(String, Result<String, Error>)]()
            for await outcome in group { all.append(outcome) }
            return all
        }
        return try Self.receipt(for: signed, outcomes: outcomes)
    }

    /// Junta as respostas dos provedores. Pura, para teste.
    static func receipt(for signed: SignedTransaction, outcomes: [(String, Result<String, Error>)]) throws -> SolanaBroadcastReceipt {
        var accepted = [String]()
        var rejections = [String: String]()
        var preflight: String?
        for (name, result) in outcomes {
            switch result {
            case .success(let signature):
                // Provedor que devolve outro id esta mentindo ou quebrado.
                if signature == signed.id { accepted.append(name) } else { rejections[name] = "id diferente: \(signature)" }
            case .failure(let error as SolanaRPCError):
                if error.message.localizedCaseInsensitiveContains("already been processed") {
                    accepted.append(name)
                } else {
                    rejections[name] = error.message
                    // -32002: falha na simulacao previa (preflight).
                    if error.code == -32002 { preflight = error.message }
                }
            case .failure(let error):
                rejections[name] = String(describing: error)
            }
        }
        guard !accepted.isEmpty else {
            if let preflight { throw SolanaBroadcastError.preflightFailed(preflight) }
            throw SolanaBroadcastError.rejected(rejections)
        }
        return SolanaBroadcastReceipt(signature: signed.id, acceptedBy: accepted.sorted(), rejections: rejections)
    }

    /// O status de uma assinatura agora.
    public func status(of signature: String, searchHistory: Bool = false) async throws -> SolanaSignatureStatus? {
        let result: RPCContextual<[RPCSignatureStatus?]> = try await reader.call(
            "getSignatureStatuses", [.array([.string(signature)]), .object(["searchTransactionHistory": .bool(searchHistory)])]
        )
        return result.value.first.flatMap { $0 }.map(SolanaSignatureStatus.init)
    }

    /// Acompanha ate `target` (confirmada ou finalizada), falha ou vencimento,
    /// reenviando os mesmos bytes enquanto a transacao nao aparece. Os reenvios
    /// usam `skipPreflight: true`: o no ja simulou no primeiro envio, e a mesma
    /// transacao em voo faria a simulacao repetida falhar sem motivo real.
    public func waitForConfirmation(
        _ signed: SignedTransaction, lastValidBlockHeight: UInt64, target: SolanaCommitment = .confirmed,
        pollInterval: Duration = .seconds(2), timeout: Duration = .seconds(120)
    ) async throws -> SolanaConfirmation {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var last = SolanaConfirmation.pending
        while clock.now < deadline {
            let status = try? await self.status(of: signed.id)
            let height = (try? await reader.blockHeight()) ?? 0
            var state = SolanaConfirmationTracker.evaluate(status: status, currentBlockHeight: height, lastValidBlockHeight: lastValidBlockHeight)
            if state == .expired {
                // Antes de declarar vencida, procura no historico: pode ter entrado.
                let history = try? await self.status(of: signed.id, searchHistory: true)
                state = SolanaConfirmationTracker.evaluate(status: history, currentBlockHeight: height, lastValidBlockHeight: lastValidBlockHeight)
            }
            last = state
            if state.isFinal || Self.reached(state, target) { return state }
            if state == .pending { _ = try? await send(signed, skipPreflight: true) }
            try await Task.sleep(for: pollInterval, clock: clock)
        }
        return last
    }

    static func reached(_ state: SolanaConfirmation, _ target: SolanaCommitment) -> Bool {
        switch (state, target) {
        case (.finalized, _): return true
        case (.confirmed, .confirmed), (.confirmed, .processed): return true
        case (.processed, .processed): return true
        default: return false
        }
    }
}
