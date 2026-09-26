import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Transmitir e acompanhar uma transacao da Solana, igual para envio e troca.
///
/// A transmissao manda os mesmos bytes assinados a dois provedores
/// (`SolanaBroadcaster`, com a simulacao previa do no ligada) e devolve o id
/// calculado dos bytes. O acompanhamento segue o prazo do blockhash: enquanto a rede
/// nao ve a transacao e o prazo nao passou, ela esta pendente e os mesmos bytes sao
/// reenviados (o `sendTransaction` vai com `maxRetries: 0`, e o no nao reenvia por
/// conta propria); passou do `lastValidBlockHeight` com folga na altura finalizada de
/// dois provedores, sem aparecer no historico de nenhum dos dois, ela nunca mais entra.
enum SolanaTransfers {
    static func transmit(
        _ signed: SignedTransaction, envelope: SolanaSignedEnvelope, network: any SolanaEngineNetwork, book: SolanaTransferBook,
        lastValidBlockHeight: UInt64?
    ) async throws -> String {
        let receipt = try await network.send(signed)
        // O transmissor so aceita a assinatura que ele mesmo tirou dos bytes; conferir
        // de novo aqui mantem o id da tela independente de qualquer resposta.
        guard receipt.signature == envelope.id else { throw SolanaEngineProblem.signedMismatch }
        await book.sent(envelope, signed: signed, lastValidBlockHeight: lastValidBlockHeight)
        return envelope.id
    }

    /// Onde a transacao esta agora. Falha de leitura nunca vira "falhou" nem
    /// "venceu": fica pendente, e a proxima consulta tenta de novo.
    static func status(_ id: String, network: any SolanaEngineNetwork, book: SolanaTransferBook) async -> TransferStatus {
        let transfer = await book.transfer(id)
        let state: SolanaConfirmation
        do {
            state = try await confirmation(id, deadline: transfer?.lastValidBlockHeight, known: transfer != nil, network: network)
        } catch {
            return .pending
        }
        switch state {
        case .pending:
            // A rede ainda nao viu e o prazo nao passou: os mesmos bytes de novo.
            if let signed = await book.claimResend(id) { _ = try? await network.send(signed) }
            return .pending
        case .processed:
            return .pending
        case .confirmed:
            await book.finished(id)
            return .confirmed(detail: "Confirmada na rede Solana.")
        case .finalized:
            await book.finished(id)
            return .confirmed(detail: "Finalizada na rede Solana.")
        case .failed:
            await book.finished(id)
            return .failed(reason: "A transação entrou num bloco e falhou. A taxa da rede foi cobrada e o valor não saiu.")
        case .expired:
            await book.finished(id)
            return .failed(reason: "A transação venceu antes de entrar num bloco. Nada foi debitado. Pode enviar de novo.")
        }
    }

    /// Blocos alem do `lastValidBlockHeight` antes de dizer que venceu: a altura
    /// finalizada anda atras da confirmada, e um no atrasado ainda poderia aceitar a
    /// transacao perto do limite. 150 blocos sao cerca de um minuto.
    static let expiryMargin: UInt64 = SolanaBroadcaster.expiryMargin

    /// O estado pela regra de `SolanaConfirmationTracker`. Sem prazo conhecido (a
    /// transacao nao foi transmitida nesta sessao), a busca vai direto ao historico e
    /// nunca conclui que venceu.
    ///
    /// "Venceu, pode enviar de novo" so com duas fontes (auditoria 2, M4): a altura
    /// finalizada nos dois provedores passou do prazo com folga, e o historico dos dois
    /// nao conhece a transacao. Com uma fonte so, um no que mente ou esta atrasado faria
    /// o dono pagar duas vezes.
    static func confirmation(_ id: String, deadline: UInt64?, known: Bool, network: any SolanaEngineNetwork) async throws -> SolanaConfirmation {
        if let status = try await network.signatureStatus(id, searchHistory: !known) {
            return SolanaConfirmationTracker.evaluate(status: status, currentBlockHeight: 0, lastValidBlockHeight: .max)
        }
        guard let deadline else { return .pending }
        let height = try await network.blockHeight()
        guard height > deadline else { return .pending }
        let (limit, overflow) = deadline.addingReportingOverflow(expiryMargin)
        guard !overflow, let finalized = try await network.finalizedBlockHeights().min(), finalized > limit else { return .pending }
        // O prazo passou nas duas fontes. Antes de dizer que venceu, o historico das duas:
        // ela pode ter entrado e saido do cache de status recentes.
        let histories = try await network.historyStatuses(id)
        guard histories.count >= 2 else { return .pending }
        if let found = histories.compactMap({ $0 }).first {
            return SolanaConfirmationTracker.evaluate(status: found, currentBlockHeight: 0, lastValidBlockHeight: .max)
        }
        return .expired
    }
}
