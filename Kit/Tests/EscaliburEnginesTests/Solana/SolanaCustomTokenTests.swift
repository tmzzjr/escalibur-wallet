import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburEngines
@testable import EscaliburNetwork

private typealias F = SolanaEngineFixtures

/// Moeda custom na Solana: o BONK (fora da lista) com uma conta de token do toly montada
/// aqui, sobre a rede gravada dos outros testes do motor. As casas salvas tem de ser as do
/// mint na rede; o aviso de nao verificado fica na revisao.
@Suite("Moeda custom: envio na Solana")
struct SolanaCustomTokenTests {
    static let mint = try! SolanaPublicKey(base58: "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263")

    static func asset(decimals: Int = 5, origin: Asset.Origin = .custom) -> Asset {
        Asset(chainID: "solana", kind: .token(contract: mint.base58), symbol: "Bonk", name: "Bonk", decimals: decimals, coingeckoID: nil,
              isStablecoin: false, origin: origin)
    }

    static func engine() async throws -> SolanaSendEngine {
        let network = try RecordedSolanaNetwork(balance: try F.recordedBalance())
        let source = try SolanaAssociatedToken.address(owner: F.toly, mint: mint, tokenProgram: .token)
        await network.setTokenState(SolanaTokenState(
            mint: mint, program: .token, decimals: 5, symbol: "Dezx…", isVerified: false, extensions: [],
            source: SolanaTokenAccountState(address: source, program: .token, mint: mint, owner: F.toly, amount: 10_000_000, isFrozen: false),
            tokenAccountRentMinimum: try F.rent("rpc-rent-165")
        ))
        await network.setSwapAsset(SolanaSwapAsset(mint: mint, program: .token, decimals: 5, symbol: "Dezx…", isVerified: false, extensions: []))
        return SolanaSendEngine(network: network, book: SolanaTransferBook(resendInterval: 0))
    }

    static func request(_ asset: Asset, to destination: SolanaPublicKey = F.exchange) -> SendRequest {
        SendRequest(
            walletID: UUID(), chain: .solana, asset: asset, account: F.account(F.toly), destination: destination.base58, tag: nil,
            amount: 1_000, sendAll: false, feeLevel: .normal, utxoUsage: nil
        )
    }

    @Test("transferChecked do mint salvo, com aviso de nao verificado e a mesma conferencia do app")
    func plan() async throws {
        let engine = try await Self.engine()
        let asset = Self.asset()
        let plan = try await engine.plan(Self.request(asset))
        #expect(plan.review.warnings.contains { if case .unverifiedToken = $0 { true } else { false } })
        try PlanIntentCheck.send(plan.review, asset: asset, amount: 1_000, ceiling: 1_000, chain: .solana)
        // O destino nunca e o proprio mint.
        await #expect(throws: SendEngineError.self) { _ = try await engine.plan(Self.request(asset, to: Self.mint)) }
    }

    @Test("Casas salvas diferentes das do mint: recusado; token so descoberto: recusado")
    func refused() async throws {
        let engine = try await Self.engine()
        await #expect(throws: SendEngineError.self) { _ = try await engine.plan(Self.request(Self.asset(decimals: 6))) }
        await #expect(throws: SendEngineError.self) { _ = try await engine.plan(Self.request(Self.asset(origin: .discovered))) }
    }
}
