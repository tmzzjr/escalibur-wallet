import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburEngines
@testable import EscaliburNetwork

private typealias F = SolanaEngineFixtures

/// O motor de troca da Solana contra propostas gravadas da Jupiter (taker = chave de
/// teste), tabelas lidas da cadeia e o `SolanaSwapPlanner` de verdade.
@Suite("Solana: motor de troca")
struct SolanaTradeEngineTests {
    let wallet = UUID()
    /// Saldo sintetico da chave de teste: 2 SOL.
    static let balance = BigUInt(2_000_000_000)

    /// O oraculo das gravacoes: 1 SOL por uns 121,6 dolares, o preco que a Jupiter cotou.
    static let prices = FakeOracle(prices: ["solana": "121.6", "usd-coin": "1"])

    func engine(prices: FakeOracle = prices) async throws -> (SolanaTradeEngine, RecordedSolanaNetwork, SolanaTransferBook) {
        let network = try RecordedSolanaNetwork(balance: Self.balance)
        await network.setSwapAsset(try F.usdcSwapAsset())
        await network.setTables(try F.tables())
        await network.setProposal(try F.proposal("jupiter-build-sol-usdc"))
        await network.setProposal(try F.proposal("jupiter-build-usdc-sol"))
        let book = SolanaTransferBook(resendInterval: 0)
        return (SolanaTradeEngine(network: network, book: book, prices: prices), network, book)
    }

    /// As contas de token da chave de teste para cada proposta gravada: sem conta de
    /// USDC (compra), ou com 7 USDC (venda).
    func accounts(sellingUSDC: Bool) throws -> SolanaSwapAccounts {
        let rent = try F.rent("rpc-rent-165")
        guard sellingUSDC else { return SolanaSwapAccounts(source: nil, destination: .missing, destinationRentMinimum: rent, wrappedSOLRentMinimum: rent) }
        let owner = try F.testKey()
        let source = SolanaTokenAccountState(
            address: try SolanaAssociatedToken.address(owner: owner, mint: F.usdcMint, tokenProgram: .token), program: .token, mint: F.usdcMint,
            owner: owner, amount: BigUInt(7_000_000), isFrozen: false
        )
        return SolanaSwapAccounts(source: source, destination: .missing, destinationRentMinimum: rent, wrappedSOLRentMinimum: rent)
    }

    /// Os pedidos das duas propostas gravadas: 0,05 SOL por USDC a 0,5%, e 5 USDC por SOL a 1%.
    func solToUSDC(amount: BigUInt = BigUInt(50_000_000), slippage: Int = 50, chain: Chain = .solana) throws -> TradeRequest {
        TradeRequest(walletID: wallet, chain: chain, account: F.account(try F.testKey()), sell: F.sol, buy: F.usdc, amountIn: amount, slippageBasisPoints: slippage)
    }

    func usdcToSOL() throws -> TradeRequest {
        TradeRequest(walletID: wallet, chain: .solana, account: F.account(try F.testKey()), sell: F.usdc, buy: F.sol, amountIn: BigUInt(5_000_000), slippageBasisPoints: 100)
    }

    func message(_ body: () async throws -> some Any) async -> String? {
        do {
            _ = try await body()
            return nil
        } catch let SendEngineError.message(text) {
            return text
        } catch {
            Issue.record("erro sem traducao: \(error)")
            return nil
        }
    }

    /// A mesma proposta com outros numeros no JSON, sem mexer nos bytes da rota.
    static func with(_ p: SolanaSwapProposal, outAmount: UInt64? = nil, threshold: UInt64? = nil, impact: Double?? = nil) -> SolanaSwapProposal {
        SolanaSwapProposal(
            provider: p.provider, inputMint: p.inputMint, outputMint: p.outputMint, inAmount: p.inAmount, outAmount: outAmount ?? p.outAmount,
            otherAmountThreshold: threshold ?? p.otherAmountThreshold, slippageBps: p.slippageBps, priceImpactPercent: impact ?? p.priceImpactPercent,
            computeBudgetInstructions: p.computeBudgetInstructions, setupInstructions: p.setupInstructions, swapInstruction: p.swapInstruction,
            cleanupInstruction: p.cleanupInstruction, otherInstructions: p.otherInstructions, tipInstruction: p.tipInstruction,
            lookupTableAddresses: p.lookupTableAddresses
        )
    }

    /// A proposta SOL -> USDC gravada com o valor cotado rebaixado nos bytes da rota
    /// (`shared_accounts_route_v2`: discriminante, id u8, in u64, cotado u64) e no JSON,
    /// coerente: a mesma rota, com um minimo menor que o da cotacao.
    static func lowered(_ p: SolanaSwapProposal, by delta: UInt64) -> SolanaSwapProposal {
        let quoted = p.outAmount - delta
        var data = p.swapInstruction.data
        for (index, byte) in quoted.littleEndianByteArray.enumerated() { data[17 + index] = byte }
        let swap = SolanaInstruction(programID: p.swapInstruction.programID, accounts: p.swapInstruction.accounts, data: data)
        return SolanaSwapProposal(
            provider: p.provider, inputMint: p.inputMint, outputMint: p.outputMint, inAmount: p.inAmount, outAmount: quoted,
            otherAmountThreshold: JupiterRoute.minimumOut(quoted: quoted, slippageBps: p.slippageBps), slippageBps: p.slippageBps,
            priceImpactPercent: p.priceImpactPercent, computeBudgetInstructions: p.computeBudgetInstructions, setupInstructions: p.setupInstructions,
            swapInstruction: swap, cleanupInstruction: p.cleanupInstruction, otherInstructions: p.otherInstructions, tipInstruction: p.tipInstruction,
            lookupTableAddresses: p.lookupTableAddresses
        )
    }

    // MARK: Cotacao

    @Test("Cotacao SOL -> USDC: o minimo e o que a rota montada garante na cadeia")
    func quoteSOLToUSDC() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        let before = Date()
        let quote = try await engine.quote(try solToUSDC())
        // Da proposta gravada: 6.080.466 cotados a 0,5%. O minimo e calculado dos bytes
        // da rota compilada: q - piso(q * 50 / 10000).
        #expect(quote.amountIn == BigUInt(50_000_000))
        #expect(quote.expectedOut == BigUInt(6_080_466))
        #expect(quote.minimumOut == BigUInt(JupiterRoute.minimumOut(quoted: 6_080_466, slippageBps: 50)))
        #expect(quote.minimumOut == BigUInt(6_050_064))
        #expect(quote.sell == F.sol && quote.buy == F.usdc)
        #expect(quote.legs == [TradeQuote.Leg(provider: "Jupiter", fraction: 1, amountIn: BigUInt(50_000_000), expectedOut: BigUInt(6_080_466))])
        #expect(quote.providersCompared == 1 && quote.alternatives.isEmpty && !quote.needsApproval)
        #expect(quote.priceImpactPercent == 0)
        #expect(quote.expiresAt > before && quote.expiresAt <= Date().addingTimeInterval(SolanaTradeEngine.quoteLifetime))
        #expect(quote.providerFeeNote?.contains("Sem taxa da Escalibur") == true)
    }

    @Test("Regressao A2: sem preco de referencia, SOL por USDC recusa na cotacao e no plano; longe demais tambem")
    func referenceRequired() async throws {
        let (blind, network, _) = try await engine(prices: FakeOracle(prices: nil))
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        let text = await message { try await blind.quote(try solToUSDC()) }
        #expect(text == SolanaEngineMessages.text(.noPriceReference))

        let (far, farNetwork, _) = try await engine(prices: FakeOracle(prices: ["solana": "130", "usd-coin": "1"]))
        await farNetwork.setSwapAccounts(try accounts(sellingUSDC: false))
        let farText = await message { try await far.quote(try solToUSDC()) }
        #expect(farText?.contains("pior que o preço de referência do mercado") == true)

        // O plano pede a referencia de novo e a entrega ao planejador.
        let (engine, recorded, _) = try await engine()
        await recorded.setSwapAccounts(try accounts(sellingUSDC: false))
        let quote = try await engine.quote(try solToUSDC())
        _ = try await engine.plan(try solToUSDC(), quote: quote)
        #expect(await recorded.references.last?.oracleOut == BigUInt(6_080_000))
    }

    @Test("Cotacao USDC -> SOL (route_v2): minimo garantido dos bytes")
    func quoteUSDCToSOL() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: true))
        let quote = try await engine.quote(try usdcToSOL())
        #expect(quote.expectedOut == BigUInt(41_123_821))
        #expect(quote.minimumOut == BigUInt(JupiterRoute.minimumOut(quoted: 41_123_821, slippageBps: 100)))
    }

    @Test("Minimo ou valor anunciados pela Jupiter diferentes dos bytes da rota: a cotacao recusa em vez de mostrar")
    func advertisedNumbers() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        let recorded = try F.proposal("jupiter-build-sol-usdc")
        // O JSON promete 1 a mais que os bytes garantem.
        await network.setProposal(Self.with(recorded, threshold: recorded.otherAmountThreshold + 1))
        #expect(await message { try await engine.quote(try solToUSDC()) } == SolanaEngineMessages.routeRefused)
        await network.setProposal(Self.with(recorded, outAmount: recorded.outAmount + 1))
        #expect(await message { try await engine.quote(try solToUSDC()) } == SolanaEngineMessages.routeRefused)
    }

    @Test("Mensagem grande demais para um pacote: a cotacao pede rota com menos contas")
    func routeLadder() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        await network.setTablesTooSmallOnFirstProposal()
        let quote = try await engine.quote(try solToUSDC())
        #expect(await network.requestedRouteLimits == [nil, 40])
        #expect(quote.minimumOut == BigUInt(6_050_064))
    }

    @Test("Tabela de enderecos sem dois RPCs concordando: a cotacao falha, sem aceitar resposta unica")
    func lookupConsensus() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        await network.setTables([])
        let text = await message { try await engine.quote(try solToUSDC()) }
        #expect(text?.hasPrefix("Os provedores da rede Solana não concordaram") == true)
    }

    @Test("Pedido fora do contrato: tolerancia acima do teto ou negativa, mesmo ativo, valor zero, outra rede")
    func refusedRequests() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        let slippage = SolanaEngineMessages.text(SolanaEngineProblem.slippageOutOfRange)
        #expect(await message { try await engine.quote(try solToUSDC(slippage: 501)) } == slippage)
        #expect(await message { try await engine.quote(try solToUSDC(slippage: -1)) } == slippage)
        #expect(await message { try await engine.quote(try solToUSDC(amount: BigUInt())) } == "Digite um valor maior que zero.")
        let same = TradeRequest(walletID: wallet, chain: .solana, account: F.account(try F.testKey()), sell: F.usdc, buy: F.usdc, amountIn: BigUInt(1), slippageBasisPoints: 50)
        #expect(await message { try await engine.quote(same) } == "Escolha dois ativos diferentes para trocar.")
        #expect(await message { try await engine.quote(try solToUSDC(chain: .ethereum)) } == SolanaEngineMessages.text(SolanaEngineProblem.wrongChain))
    }

    @Test("Token da lista com casas trocadas na rede: a cotacao recusa")
    func unverifiedQuote() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        await network.setSwapAsset(try F.usdcSwapAsset(decimals: 9))
        #expect(await message { try await engine.quote(try solToUSDC()) } == SolanaEngineMessages.text(SolanaEngineProblem.tokenNotVerified))
    }

    // MARK: Plano

    @Test("Plano: outra proposta, montada, simulada e presa ao minimo que a cotacao mostrou")
    func plan() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        let request = try solToUSDC()
        let quote = try await engine.quote(request)
        let plan = try await engine.plan(request, quote: quote)
        #expect(await network.shownMinimums == [quote.minimumOut])
        #expect(plan.review.kind == .swap && plan.chain == .solana && plan.walletID == wallet)
        #expect(plan.review.lines.first { $0.label == "Sai" }?.value == "0,05 SOL")
        #expect(plan.review.lines.contains { $0.label == "Escalibur" && $0.value == "Sem taxa da Escalibur" })
        let transaction = try #require(plan.transactions.first as? SolanaTransaction)
        #expect(transaction.signer == (try F.testKey()) && transaction.message.version == .v0)
    }

    @Test("Plano: proposta que garante menos que a tela mostrou e trocada por outra; nunca aceita menos")
    func planBelowShown() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        let request = try solToUSDC()
        let quote = try await engine.quote(request)
        let lower = Self.lowered(try F.proposal("jupiter-build-sol-usdc"), by: 200)
        #expect(BigUInt(JupiterRoute.minimumOut(quoted: lower.outAmount, slippageBps: 50)) < quote.minimumOut)

        // Primeira proposta abaixo do mostrado, a segunda volta ao preco da cotacao.
        await network.queuePlanProposals([lower])
        let plan = try await engine.plan(request, quote: quote)
        #expect(await network.shownMinimums == [quote.minimumOut, quote.minimumOut])
        #expect(plan.review.lines.first { $0.label == "Entra, no mínimo" }?.value == "6,050064 USDC")

        // Todas abaixo: o preco mudou de verdade, e o dono fica sabendo.
        await network.queuePlanProposals(Array(repeating: lower, count: SolanaTradeEngine.planAttempts))
        let text = await message { try await engine.plan(request, quote: quote) }
        #expect(text?.hasPrefix("O preço mudou desde a cotação") == true)
    }

    @Test("Plano recusa cotacao de outra troca e cotacao vencida")
    func planQuoteChecks() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        let quote = try await engine.quote(try solToUSDC())
        #expect(await message { try await engine.plan(try solToUSDC(amount: BigUInt(40_000_000)), quote: quote) }
            == SolanaEngineMessages.text(SolanaEngineProblem.quoteMismatch))
        let old = TradeQuote(
            sell: quote.sell, buy: quote.buy, amountIn: quote.amountIn, expectedOut: quote.expectedOut, minimumOut: quote.minimumOut,
            priceImpactPercent: quote.priceImpactPercent, networkFeeFiat: nil, providerFeeNote: nil, legs: quote.legs, alternatives: [],
            providersCompared: 1, needsApproval: false, expiresAt: Date().addingTimeInterval(-1)
        )
        #expect(await message { try await engine.plan(try solToUSDC(), quote: old) } == SolanaEngineMessages.text(SolanaEngineProblem.quoteExpired))
        #expect(await network.shownMinimums.isEmpty)
    }

    @Test("Plano com impacto no preco no degrau de bloqueio: recusa, mesmo com a cotacao na mao")
    func blockedImpact() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        // Impacto gravado (0%) trocado por 20%.
        await network.setProposal(Self.with(try F.proposal("jupiter-build-sol-usdc"), impact: .some(20)))
        let quote = try await engine.quote(try solToUSDC())
        #expect(PriceImpact.level(quote.priceImpactPercent) == .blocked)
        #expect(await message { try await engine.plan(try solToUSDC(), quote: quote) } == SolanaEngineMessages.text(SolanaEngineProblem.priceImpactTooHigh))
    }

    @Test("Plano: casas do token vendido trocadas na rede mudariam o valor da revisao; recusa")
    func soldDecimals() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: true))
        let request = try usdcToSOL()
        let quote = try await engine.quote(request)
        // Entre a cotacao e o plano, a rede passa a dizer 9 casas para o USDC: a revisao
        // mostraria "Sai 0,005 USDC" para 5 USDC.
        await network.setSwapAsset(try F.usdcSwapAsset(decimals: 9))
        #expect(await message { try await engine.plan(request, quote: quote) } == SolanaEngineMessages.text(SolanaEngineProblem.planMismatch))
    }

    @Test("Plano: token comprado com casas trocadas vira token fora da lista; recusa")
    func boughtUnverified() async throws {
        let (engine, network, _) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        let request = try solToUSDC()
        let quote = try await engine.quote(request)
        await network.setSwapAsset(try F.usdcSwapAsset(decimals: 9))
        #expect(await message { try await engine.plan(request, quote: quote) } == SolanaEngineMessages.text(SolanaEngineProblem.tokenNotVerified))
    }

    // MARK: Transmissao

    @Test("Envio da troca: os bytes do plano, o id calculado aqui e o prazo do plano")
    func submit() async throws {
        let (engine, network, book) = try await engine()
        await network.setSwapAccounts(try accounts(sellingUSDC: false))
        let request = try solToUSDC()
        let plan = try await engine.plan(request, quote: try await engine.quote(request))
        let signed = try F.sign(plan)
        let ids = try await engine.submit([signed], plan: plan)
        #expect(ids == [signed.id])
        #expect(await network.sent == [signed])
        let transaction = try #require(plan.transactions.first as? SolanaTransaction)
        #expect(await book.transfer(signed.id)?.lastValidBlockHeight == transaction.lastValidBlockHeight)

        // Uma transacao valida do mesmo dono, mas de outro plano (um envio de SOL): nao sai
        // com este plano.
        let owner = SolanaOwner(path: DefaultPaths.path(for: .solana), publicKey: try F.testKey())
        let otherPlan = try SolanaPlanner.planSendSOL(
            walletID: wallet, owner: owner, to: F.exchange.base58, lamports: BigUInt(10_000_000), destination: .system(lamports: BigUInt(1)),
            network: try F.state(balance: Self.balance)
        )
        let refused = SolanaEngineMessages.text(SolanaEngineProblem.signedMismatch)
        #expect(await message { try await engine.submit([try F.sign(otherPlan)], plan: plan) } == refused)
        #expect(await message { try await engine.submit([], plan: plan) } == refused)
        #expect(await network.sent == [signed])
    }

    @Test("Ordem limite fica de fora na v1, dita como fato")
    func limitOrders() async throws {
        let (engine, _, _) = try await engine()
        #expect(!engine.supportsLimitOrders)
        #expect(!engine.limitCustodyNote.contains("—") && !engine.limitCustodyNote.contains("–"))
        let order = LimitOrderRequest(
            walletID: wallet, chain: .solana, account: F.account(try F.testKey()), sell: F.sol, buy: F.usdc, amountIn: BigUInt(1),
            minimumOut: BigUInt(1), validFor: 3600
        )
        #expect(await message { try await engine.planLimitOrder(order) } == SolanaEngineMessages.text(SolanaEngineProblem.limitOrdersUnavailable))
    }
}
