import EscaliburChains
import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburEngines

/// Os motores EVM contra os provedores reais, so com ESCALIBUR_REDE=1. **So leitura: nada
/// e assinado nem transmitido.** Os planos saem com o estado real e param antes do
/// assinador.
///
/// A conta e a "Binance 8" (0xF977...aceC), carteira quente de exchange com saldo nativo e
/// USDC na Base e na Ethereum, sem codigo; a chave publica foi recuperada de uma
/// assinatura na cadeia (ver `EVMTestAccounts`). O destino e a "Binance 14", sem codigo.
/// A chave da EIP-155 nao entra aqui: o endereco dela tem delegacao para um sweeper.
@Suite("Motores EVM ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct EVMEnginesLiveTests {
    typealias A = EVMTestAccounts

    /// O detalhe so sai com ESCALIBUR_REDE_DETALHE=1.
    static func note(_ text: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["ESCALIBUR_REDE_DETALHE"] == "1" { print("[ao vivo] " + text()) }
    }

    static func usdc(_ chain: Chain) throws -> Asset {
        try #require(TokenRegistry.assets(on: chain).first { $0.symbol == "USDC" })
    }

    static func send(_ chain: Chain, asset: Asset, amount: BigUInt, sendAll: Bool = false) -> SendRequest {
        SendRequest(walletID: UUID(), chain: chain, asset: asset, account: A.binance8(on: chain), destination: A.binance14.checksummed,
                    tag: nil, amount: amount, sendAll: sendAll, feeLevel: .normal, utxoUsage: nil)
    }

    @Test("Envio com estado real na Base e na Ethereum: nativo e USDC, destino conferido no plano", arguments: [Chain.base, .ethereum])
    func sendPlans(chain: Chain) async throws {
        let engine = try #require(SendEngines.engine(for: chain))
        let info = try await engine.destination(A.binance14.checksummed, chain: chain)
        #expect(!info.isContract)

        let native = try await engine.plan(Self.send(chain, asset: .native(chain), amount: 1_000))
        #expect(native.review.kind == .send)
        #expect(native.review.recipient == A.binance14.checksummed)
        #expect(native.transactions.count == 1)

        // USDC: a transferencia exata passa pelo eth_call de dois provedores antes de sair.
        let token = try await engine.plan(Self.send(chain, asset: try Self.usdc(chain), amount: 1))
        #expect(token.review.recipient == A.binance14.checksummed)
        let transaction = try #require(token.transactions.first as? EVMTransaction)
        #expect(transaction.data == ERC20.transfer(to: A.binance14, amount: 1))

        let spendable = try await engine.spendable(Self.send(chain, asset: .native(chain), amount: 0, sendAll: true))
        #expect(spendable.amount > 0)
        let tokenSpendable = try await engine.spendable(Self.send(chain, asset: try Self.usdc(chain), amount: 0, sendAll: true))
        #expect(tokenSpendable.amount > 0)
        let nonce = (native.transactions.first as? EVMTransaction)?.nonce
        Self.note("\(chain.id): nativo e USDC planejados, nonce \(nonce.map(String.init) ?? "-"), avisos \(token.review.warnings)")
    }

    @Test("Troca na Base: rodada entre provedores, recotacao e plano com a simulacao real")
    func tradeBase() async throws {
        let engine = try #require(TradeEngines.engine(for: .base))
        let request = TradeRequest(walletID: UUID(), chain: .base, account: A.binance8(on: .base), sell: .native(.base),
                                   buy: try Self.usdc(.base), amountIn: BigUInt(1_000_000_000_000_000), slippageBasisPoints: 50)
        let quote = try await engine.quote(request)
        #expect(quote.providersCompared >= 1)
        #expect(quote.minimumOut > 0 && quote.minimumOut <= quote.expectedOut)
        #expect(!quote.needsApproval)
        let plan = try await engine.plan(request, quote: quote)
        #expect(plan.review.kind == .swap)
        #expect(plan.review.transactionCount == plan.transactions.count)
        #expect(plan.review.lines.contains { $0.label.hasSuffix("Taxa da Escalibur") && $0.value == "Sem taxa da Escalibur" })
        Self.note("base: \(quote.providersCompared) provedores, pernas \(quote.legs.map(\.provider)), minimo \(quote.minimumOut), "
            + "impacto \(quote.priceImpactPercent.map { "\($0)%" } ?? "-"), plano com \(plan.transactions.count) transacao(oes)")
    }

    @Test("Ordem limite na Base: estado real, embrulho e autorizacao simulados, sem assinar nem enviar")
    func limitOrderBase() async throws {
        let engine = try #require(TradeEngines.engine(for: .base))
        let request = LimitOrderRequest(walletID: UUID(), chain: .base, account: A.binance8(on: .base), sell: .native(.base),
                                        buy: try Self.usdc(.base), amountIn: BigUInt(1_000_000_000_000_000), minimumOut: 10_000_000,
                                        validFor: 86_400)
        let plan = try await engine.planLimitOrder(request)
        #expect(plan.review.kind == .limitOrder)
        #expect(plan.transactions.last is EIP712ValidatedMessage)
        Self.note("base: ordem limite com \(plan.review.transactionCount) etapas: \(plan.review.title)")
    }

    @Test("Historico real da Base; a BNB Chain diz que ainda nao tem")
    func activity() async throws {
        let base = try #require(ActivitySources.source(for: .base))
        let entries = try await base.history(chain: .base, account: A.binance8(on: .base), usage: nil)
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.chainID == "base" })
        Self.note("base: \(entries.count) itens, \(entries.filter(\.suspicious).count) suspeitos")
        let bnb = try #require(ActivitySources.source(for: .bnb))
        await #expect(throws: SendEngineError.self) { _ = try await bnb.history(chain: .bnb, account: A.binance8(on: .bnb), usage: nil) }
    }
}
