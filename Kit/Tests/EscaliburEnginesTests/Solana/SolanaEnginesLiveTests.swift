import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburEngines
@testable import EscaliburNetwork

/// Os motores da Solana contra a rede principal e a Jupiter de verdade. So com
/// ESCALIBUR_REDE=1.
///
/// O dono e o toly.sol, conta publica com saldo, usada so como chave publica: os
/// planos saem ate o `SigningPlan` e param ai. Nada e assinado e nada e transmitido.
@Suite("Solana: motores ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct SolanaEnginesLiveTests {
    static let toly = try! SolanaPublicKey(base58: "86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY")
    static let tolyUSDC = try! SolanaPublicKey(base58: "9SHQTA66Ekh7ZgMnKWsjxXk6DwXku8przs45E8bcEe38")
    /// Carteira quente de exchange, sempre existente e com conta de USDC.
    static let exchange = try! SolanaPublicKey(base58: "5tzFkiKscXHK5ZXCGbXZxdw7gTjjD1mBwuoFbhUvuAi9")
    static let exchangeUSDC = try! SolanaPublicKey(base58: "FzbcyEZ9m8xjtergWgWDq7mfPoHEbboBF791B6cTpzbq")
    /// Chave publica cuja semente e sha256("escalibur: motores solana, destino nunca usado").
    static let nova = try! SolanaPublicKey(base58: "5tFUx2GVxip3kMhdwHG1yPGP2gYMzAikagio3GgyLAZZ")
    static let usdc = TokenRegistry.tokens.first { $0.chainID == "solana" && $0.symbol == "USDC" }!

    let wallet = UUID()
    let send = SolanaSendEngine(network: SolanaLiveNetwork(), book: SolanaTransferBook())
    let trade = SolanaTradeEngine(network: SolanaLiveNetwork(), book: SolanaTransferBook())

    var account: DerivedAccount {
        DerivedAccount(chainID: "solana", path: DefaultPaths.path(for: .solana), address: Self.toly.base58, publicKey: Self.toly.bytes, accountXPub: nil)
    }

    func request(_ asset: Asset, to destination: SolanaPublicKey, amount: BigUInt) -> SendRequest {
        SendRequest(
            walletID: wallet, chain: .solana, asset: asset, account: account, destination: destination.base58, tag: nil, amount: amount,
            sendAll: false, feeLevel: .normal, utxoUsage: nil
        )
    }

    @Test("Destino: carteira existente, conta nova com o minimo de rent, conta de token recusada")
    func destinations() async throws {
        let wallet = try await send.destination(Self.exchange.base58, chain: .solana)
        #expect(wallet.exists && wallet.activationMinimum == nil)
        let fresh = try await send.destination(Self.nova.base58, chain: .solana)
        #expect(!fresh.exists)
        #expect((fresh.activationMinimum ?? BigUInt()) > BigUInt(100_000))
        await #expect(throws: SendEngineError.message(SolanaEngineMessages.tokenAccountDestination)) {
            try await send.destination(Self.exchangeUSDC.base58, chain: .solana)
        }
    }

    @Test("Quanto pode sair: SOL menos taxa e reserva; USDC inteiro com SOL para a taxa")
    func spendable() async throws {
        let sol = try await send.spendable(request(.native(.solana), to: Self.exchange, amount: BigUInt()))
        #expect(sol.amount > BigUInt(1_000_000_000))
        let usdc = try await send.spendable(request(Self.usdc, to: Self.exchange, amount: BigUInt()))
        #expect(!usdc.amount.isZero)
        #expect(usdc.feeNote?.hasPrefix("A taxa da rede") == true)
    }

    @Test("Plano de SOL ate o SigningPlan, com CU medido, sem assinar: recipient e o digitado")
    func planSOL() async throws {
        let plan = try await send.plan(request(.native(.solana), to: Self.exchange, amount: BigUInt(1_000_000)))
        #expect(plan.review.kind == .send && plan.review.recipient == Self.exchange.base58)
        #expect(Address.sameRecipient(plan.review.recipient, Self.exchange.base58, chain: .solana))
        let transaction = try #require(plan.transactions.first as? SolanaTransaction)
        #expect(transaction.signer == Self.toly && transaction.message.feePayer == Self.toly)
    }

    @Test("Plano de USDC ate o SigningPlan, sem assinar: recipient e a carteira digitada, nao a conta de token")
    func planUSDC() async throws {
        let plan = try await send.plan(request(Self.usdc, to: Self.exchange, amount: BigUInt(1_000_000)))
        #expect(plan.review.recipient == Self.exchange.base58)
        #expect(plan.review.lines.first { $0.label == "Para" }?.value == Self.exchange.base58)
        #expect(plan.review.lines.first { $0.label == "Conta de token do destino" }?.value == Self.exchangeUSDC.base58)
        #expect(plan.review.title == "Enviar 1 USDC")
        let transaction = try #require(plan.transactions.first as? SolanaTransaction)
        #expect(transaction.signer == Self.toly)
    }

    @Test("Troca SOL -> USDC: cotacao com minimo dos bytes e plano preso a ele, sem assinar e sem transmitir")
    func swap() async throws {
        let request = TradeRequest(
            walletID: wallet, chain: .solana, account: account, sell: .native(.solana), buy: Self.usdc, amountIn: BigUInt(10_000_000),
            slippageBasisPoints: 50
        )
        let quote = try await trade.quote(request)
        #expect(!quote.minimumOut.isZero && quote.minimumOut <= quote.expectedOut)
        #expect(quote.legs.first?.provider == "Jupiter" && quote.providersCompared == 1)
        let plan: SigningPlan
        do {
            plan = try await trade.plan(request, quote: quote)
        } catch SendEngineError.message(let text) where text.hasPrefix("O preço mudou") {
            // O mercado andou contra nas tres propostas do plano: recusa correta. Cota de
            // novo e planeja uma vez mais, como a tela faria.
            plan = try await trade.plan(request, quote: try await trade.quote(request))
        }
        #expect(plan.review.kind == .swap)
        #expect(plan.review.lines.contains { $0.label == "Entra, no mínimo" })
        #expect(plan.review.lines.contains { $0.value == "Sem taxa da Escalibur" })
        let transaction = try #require(plan.transactions.first as? SolanaTransaction)
        #expect(transaction.signer == Self.toly && transaction.message.version == .v0)
        #expect(transaction.serializedSize <= SolanaTransaction.maxSerializedSize)
    }

    @Test("Historico do toly na forma da Atividade, com as suspeitas marcadas")
    func history() async throws {
        let entries = try await SolanaActivitySource(network: SolanaLiveNetwork()).history(chain: .solana, account: account, usage: nil)
        #expect(!entries.isEmpty && entries.count <= SolanaActivitySource.limit)
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries.allSatisfy { $0.chainID == "solana" && $0.hash == $0.id })
    }
}
