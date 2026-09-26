import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra a rede principal e a Jupiter de verdade. So com ESCALIBUR_REDE=1.
///
/// O dono aqui e uma conta publica com saldo (toly.sol), usada so como chave
/// publica: nada e assinado e nada e transmitido. O caminho de derivacao e o padrao
/// e nunca chega a um assinador.
@Suite("Solana ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct SolanaNetLiveTests {
    static let toly = try! SolanaPublicKey(base58: "86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY")
    static let usdc = try! SolanaPublicKey(base58: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
    static let pyusd = try! SolanaPublicKey(base58: "2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo")
    /// Destino do envio de teste: a carteira de uma exchange, sempre existente.
    static let destination = "5tzFkiKscXHK5ZXCGbXZxdw7gTjjD1mBwuoFbhUvuAi9"
    static var owner: SolanaOwner { SolanaOwner(path: DefaultPaths.path(for: .solana), publicKey: toly) }

    let reader = SolanaNetworkReader()

    @Test("Estado da rede: blockhash dentro da janela, saldo, rent e prioridade")
    func networkState() async throws {
        let state = try await reader.networkState(owner: Self.toly, writableAccounts: [Self.usdc])
        #expect(state.currentBlockHeight <= state.lastValidBlockHeight)
        #expect(state.lastValidBlockHeight - state.currentBlockHeight <= 300)
        #expect(state.balance > BigUInt(1_000_000_000))
        // Rent de conta vazia em 2026: 650.240 lamports (docs/blockchain.md §0.5); so conferimos a ordem de grandeza.
        #expect(state.rentExemptMinimum > BigUInt(100_000) && state.rentExemptMinimum < BigUInt(2_000_000))
        #expect(abs(state.fetchedAt.timeIntervalSinceNow) < 30)
    }

    @Test("Destino: carteira, conta de token com o mint, programa")
    func destinations() async throws {
        guard case .system = try await reader.destinationAccount(Self.toly) else { Issue.record("toly deveria ser carteira"); return }
        let ata = try SolanaAssociatedToken.address(owner: Self.toly, mint: Self.usdc, tokenProgram: .token)
        guard case .tokenAccount(let state) = try await reader.destinationAccount(ata) else { Issue.record("ATA deveria ser conta de token"); return }
        #expect(state.mint == Self.usdc)
        #expect(state.owner == Self.toly)
        guard case .programOwned = try await reader.destinationAccount(SolanaProgramID.jupiterV6) else { Issue.record("programa"); return }
        guard case .existing = try await reader.destinationTokenAccount(owner: Self.toly, mint: Self.usdc, program: .token) else {
            Issue.record("ATA de USDC do toly deveria existir"); return
        }
    }

    @Test("Mint: USDC no Token, PYUSD no Token-2022 com delegado permanente")
    func mints() async throws {
        let usdc = try await reader.mintInfo(Self.usdc)
        #expect(usdc.program == .token && usdc.decimals == 6 && usdc.extensions.isEmpty)
        let pyusd = try await reader.mintInfo(Self.pyusd)
        #expect(pyusd.program == .token2022)
        #expect(pyusd.extensions.contains(.permanentDelegate))
        let state = try await reader.tokenState(owner: Self.toly, mint: Self.usdc)
        #expect(state.symbol == "USDC" && state.isVerified)
        #expect(state.tokenAccountRentMinimum > BigUInt(1_000_000))
    }

    @Test("Plano de envio de SOL ate o SigningPlan, com CU medido na simulacao, sem assinar")
    func planSendSOL() async throws {
        let service = SolanaPlanningService(reader: reader)
        let plan = try await service.planSendSOL(walletID: UUID(), owner: Self.owner, to: Self.destination, lamports: BigUInt(1_000_000))
        let transaction = try #require(plan.transactions.first as? SolanaTransaction)
        #expect(transaction.message.feePayer == Self.toly)
        #expect(plan.review.kind == .send)
        #expect(plan.review.lines.contains { $0.label == "Taxa da rede" })
    }

    @Test("Troca SOL -> USDC pela Jupiter ate o SigningPlan, sem assinar e sem transmitir")
    func planSwap() async throws {
        let service = SolanaPlanningService(reader: reader)
        let quote = try await service.quoteSwap(sellMint: SolanaWrappedSOL.mint, buyMint: Self.usdc, amountIn: 10_000_000, slippageBps: 50)
        #expect(quote.outputMint == Self.usdc)
        #expect(quote.platformFeeBps == nil || quote.platformFeeBps == 0)
        let plan = try await service.planSwap(
            walletID: UUID(), owner: Self.owner, sellMint: SolanaWrappedSOL.mint, buyMint: Self.usdc, amountIn: BigUInt(10_000_000), slippageBps: 50
        )
        let transaction = try #require(plan.transactions.first as? SolanaTransaction)
        #expect(transaction.message.version == .v0)
        #expect(transaction.message.feePayer == Self.toly)
        #expect(plan.review.kind == .swap)
        #expect(plan.review.lines.contains { $0.value == "Sem taxa da Escalibur" })
        #expect(plan.review.lines.contains { $0.label == "Entra, no mínimo" })
        #expect(transaction.serializedSize <= SolanaTransaction.maxSerializedSize)
    }

    @Test("Tabela de enderecos da Jupiter lida de dois RPCs concordando")
    func lookupTables() async throws {
        let address = try SolanaPublicKey(base58: "CdASjXYwMVqf4PSq6j3uTrqDRKJoKEP6wtFLXhJYpUCi")
        let tables = try await reader.lookupTables([address])
        #expect(tables.count == 1 && tables[0].address == address)
        #expect(tables[0].addresses.count >= 252)
    }

    @Test("Status de uma transacao antiga: finalizada; assinatura desconhecida: nenhum")
    func statuses() async throws {
        let broadcaster = SolanaBroadcaster(reader: reader)
        let known = "5GQzAVMZ2TLEiRZeXt1MejGTPnYPYq84kJjkKCZ46wTMurgFeHfGkPaZguxjh42nXNWqxHu9bGnKFrqYG83A5ggA"
        let status = try await broadcaster.status(of: known, searchHistory: true)
        #expect(status?.confirmationStatus == "finalized" && status?.error == nil)
        let unknown = String(repeating: "1", count: 64)
        #expect(try await broadcaster.status(of: unknown, searchHistory: false) == nil)
    }

    @Test("Troca USDC -> SOL ate o SigningPlan (route_v2, desembrulho no fim)")
    func planSwapToSOL() async throws {
        let service = SolanaPlanningService(reader: reader)
        let plan = try await service.planSwap(
            walletID: UUID(), owner: Self.owner, sellMint: Self.usdc, buyMint: SolanaWrappedSOL.mint, amountIn: BigUInt(2_000_000), slippageBps: 50
        )
        #expect(plan.review.title == "Trocar 2 USDC por SOL")
        #expect(plan.review.lines.contains { $0.label == "Recebe em" && $0.value == Self.toly.base58 })
    }

    @Test("Historico recente: efeito liquido e suspeitas")
    func history() async throws {
        let history = SolanaHistoryReader(reader: reader)
        let activity = try await history.recentActivity(owner: Self.toly, limit: 10)
        #expect(!activity.isEmpty)
        #expect(activity.count <= 10)
        #expect(activity.map(\.slot) == activity.map(\.slot).sorted(by: >))
    }
}
