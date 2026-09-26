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

    // MARK: Segunda leva

    /// O que a Binance 8 (a unica conta de teste com chave publica conhecida) tem nas
    /// redes novas, conferido em 26/09/2026: XPL e 100 milhoes de USDT0 na Plasma; ETH na
    /// Linea e S na Sonic, sem stablecoin. Na X Layer, na Unichain e na Celo ela nao paga
    /// a taxa: o estado real dessas redes e conferido em EVMReaderLiveTests.secondWaveState,
    /// por endereco, e o plano completo espera uma conta com saldo e chave publica.
    static let secondWave: [(chain: Chain, stablecoin: String?)] = [(.plasma, "USDT"), (.linea, nil), (.sonic, nil)]

    @Test("Redes novas: envio nativo e de stablecoin com estado real, destino conferido no plano", arguments: secondWave.indices)
    func secondWaveSendPlans(index: Int) async throws {
        let (chain, stablecoin) = Self.secondWave[index]
        let engine = try #require(SendEngines.engine(for: chain))
        let info = try await engine.destination(A.binance14.checksummed, chain: chain)
        #expect(!info.isContract)

        let native = try await engine.plan(Self.send(chain, asset: .native(chain), amount: 1_000))
        #expect(native.review.kind == .send)
        #expect(native.review.recipient == A.binance14.checksummed)
        let transaction = try #require(native.transactions.first as? EVMTransaction)
        #expect(transaction.chainID == chain.evmChainID)
        #expect(transaction.transactionType == 2)

        if let stablecoin {
            let asset = try #require(TokenRegistry.assets(on: chain).first { $0.symbol == stablecoin })
            let token = try await engine.plan(Self.send(chain, asset: asset, amount: 1))
            #expect(token.review.recipient == A.binance14.checksummed)
            let call = try #require(token.transactions.first as? EVMTransaction)
            #expect(call.data == ERC20.transfer(to: A.binance14, amount: 1))
            if case .token(let contract) = asset.kind { #expect(call.to.checksummed == contract) }
        }
        Self.note("\(chain.id): nativo planejado, nonce \(transaction.nonce)\(stablecoin.map { ", \($0) planejado" } ?? "")")
    }

    @Test("Redes novas com troca: cotacao validada contra a allowlist; plano simulado onde a conta tem saldo",
          arguments: [Chain.plasma, .linea, .unichain, .sonic])
    func secondWaveTrade(chain: Chain) async throws {
        let engine = try #require(TradeEngines.engine(for: chain))
        let buy = try #require(TokenRegistry.assets(on: chain).first { $0.isStablecoin })
        // Uns poucos centavos da moeda nativa: 0,1 XPL, 0,0001 ETH, 1 S.
        let amount: BigUInt = switch chain.id {
        case "plasma": BigUInt(decimal: "100000000000000000")!
        case "sonic": BigUInt(decimal: "1000000000000000000")!
        default: BigUInt(decimal: "100000000000000")!
        }
        let request = TradeRequest(walletID: UUID(), chain: chain, account: A.binance8(on: chain), sell: .native(chain),
                                   buy: buy, amountIn: amount, slippageBasisPoints: 100)
        let quote = try await engine.quote(request)
        #expect(quote.providersCompared >= 1)
        #expect(quote.minimumOut > 0 && quote.minimumOut <= quote.expectedOut)
        for leg in quote.legs {
            let provider = try #require(TradeProvider.allCases.first { $0.displayName == leg.provider })
            #expect(TradeAllowlist.router(for: provider, on: chain) != nil, "\(chain.id) \(leg.provider)")
        }
        if ["plasma", "sonic"].contains(chain.id) {
            let plan = try await engine.plan(request, quote: quote)
            #expect(plan.review.kind == .swap)
            #expect(plan.review.lines.contains { $0.label.hasSuffix("Taxa da Escalibur") && $0.value == "Sem taxa da Escalibur" })
        }
        Self.note("\(chain.id): \(quote.providersCompared) provedores, pernas \(quote.legs.map(\.provider)), minimo \(quote.minimumOut)")
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

    @Test("Historico real da Base; BNB Chain, X Layer e Sonic dizem que ainda nao tem")
    func activity() async throws {
        let base = try #require(ActivitySources.source(for: .base))
        let entries = try await base.history(chain: .base, account: A.binance8(on: .base), usage: nil)
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.chainID == "base" })
        Self.note("base: \(entries.count) itens, \(entries.filter(\.suspicious).count) suspeitos")
        for chain in [Chain.bnb, .xlayer, .sonic] {
            let source = try #require(ActivitySources.source(for: chain))
            await #expect(throws: SendEngineError.self) { _ = try await source.history(chain: chain, account: A.binance8(on: chain), usage: nil) }
        }
    }
}
