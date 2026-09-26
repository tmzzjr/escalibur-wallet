import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// A carteira de teste publica ("abandon ... about") tem na Solana as contas de USDC e
/// USDT com o dono trocado por um atacante (SetAuthority), e a propria conta de SOL
/// entregue a um programa (Assign): o saldo aparece e nao sai. Sao os golpes de
/// verdade, vistos ao vivo em 2026-09-26, e servem de amostra.
@Suite("Solana: conta de token com dono trocado, ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct SolanaHijackedAccountLiveTests {
    static let demo = try! SolanaPublicKey(base58: "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
    static let usdc = TokenRegistry.tokens.first { $0.chainID == "solana" && $0.symbol == "USDC" }!

    @Test("O ATA de USDC com outro dono e recusado com o aviso proprio, e a troca nao monta")
    func hijackedATA() async throws {
        let network = SolanaLiveNetwork()
        let mint = try SolanaPublicKey(base58: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
        await #expect(throws: SolanaAccountParseError.tokenAccountOwnerChanged) {
            _ = try await network.destinationTokenAccount(owner: Self.demo, mint: mint, program: .token)
        }
        let account = DerivedAccount(chainID: "solana", path: DefaultPaths.path(for: .solana), address: Self.demo.base58,
                                     publicKey: Self.demo.bytes, accountXPub: nil)
        let request = TradeRequest(walletID: UUID(), chain: .solana, account: account, sell: .native(.solana), buy: Self.usdc,
                                   amountIn: BigUInt(10_000_000), slippageBasisPoints: 50)
        let trade = SolanaTradeEngine(network: network, book: SolanaTransferBook())
        do {
            _ = try await trade.quote(request)
            Issue.record("a troca para uma conta de outro dono nao pode cotar")
        } catch SendEngineError.message(let text) {
            #expect(text.contains("outro dono"))
        }
    }

    @Test("Conta de SOL entregue a um programa: recusada antes de montar, com o aviso proprio")
    func assignedOwner() async throws {
        await #expect(throws: SolanaAccountParseError.ownerAssignedToProgram) {
            _ = try await SolanaNetworkReader.shared.networkState(owner: Self.demo)
        }
        #expect(SolanaEngineMessages.map(SolanaAccountParseError.ownerAssignedToProgram, .swap).localizedDescription.isEmpty == false)
    }
}
