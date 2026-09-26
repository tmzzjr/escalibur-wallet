import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

typealias F = SolanaTradeFixtures

/// O formato da instrucao de rota confere com o IDL do proprio programa.
@Suite("Solana troca: formato da rota da Jupiter")
struct SolanaTradeRouteFormatTests {
    struct IDL: Decodable {
        struct Instruction: Decodable {
            let name: String
            let discriminator: [UInt8]
            let accounts: [String]
            let eventAuthority: String?
            let args: [String]
        }
        let address: String
        let instructions: [Instruction]
        func instruction(_ name: String) throws -> Instruction { try #require(instructions.first { $0.name == name }) }
    }

    func idl() throws -> IDL { try JSONDecoder().decode(IDL.self, from: try F.load("jupiter-idl")) }

    @Test("Discriminantes: sha256(\"global:<nome>\")[0..8] igual ao IDL gravado na cadeia")
    func discriminators() throws {
        let idl = try idl()
        #expect(idl.address == JupiterRouteDecoder.programID.base58)
        for (name, constant) in [("route_v2", JupiterRouteDecoder.routeV2), ("shared_accounts_route_v2", JupiterRouteDecoder.sharedAccountsRouteV2)] {
            let anchor = Array(Hash.sha256(Array("global:\(name)".utf8)).prefix(8))
            #expect(anchor == constant, "\(name)")
            #expect(try idl.instruction(name).discriminator == constant, "\(name)")
        }
    }

    @Test("Posicoes de conta e ordem dos argumentos usadas pelo decodificador sao as do IDL")
    func positions() throws {
        let idl = try idl()
        let v2 = try idl.instruction("route_v2")
        #expect(v2.args.prefix(5) == ["in_amount", "quoted_out_amount", "slippage_bps", "platform_fee_bps", "positive_slippage_bps"])
        #expect(v2.args.last == "route_plan")
        #expect(v2.accounts[0] == "user_transfer_authority")
        #expect(v2.accounts[1] == "user_source_token_account")
        #expect(v2.accounts[2] == "user_destination_token_account")
        #expect(v2.accounts[3] == "source_mint" && v2.accounts[4] == "destination_mint")
        #expect(v2.accounts[5] == "source_token_program" && v2.accounts[6] == "destination_token_program")
        #expect(v2.accounts[7] == "destination_token_account" && v2.accounts[8] == "event_authority" && v2.accounts[9] == "program")

        let shared = try idl.instruction("shared_accounts_route_v2")
        #expect(shared.args.prefix(6) == ["id", "in_amount", "quoted_out_amount", "slippage_bps", "platform_fee_bps", "positive_slippage_bps"])
        #expect(shared.accounts[1] == "user_transfer_authority")
        #expect(shared.accounts[2] == "source_token_account")
        #expect(shared.accounts[5] == "destination_token_account")
        #expect(shared.accounts[6] == "source_mint" && shared.accounts[7] == "destination_mint")
        #expect(shared.accounts[8] == "source_token_program" && shared.accounts[9] == "destination_token_program")
        #expect(shared.accounts[10] == "event_authority" && shared.accounts[11] == "program")
        // As variantes antigas poem o plano de rota ANTES dos escalares: por isso sao recusadas.
        #expect(try idl.instruction("route").args.first == "route_plan")
        #expect(try idl.instruction("shared_accounts_route").args[1] == "route_plan")
    }

    @Test("Autoridade de eventos: PDA [\"__event_authority\"] do programa, igual ao IDL")
    func eventAuthority() throws {
        let derived = try SolanaPDA.findProgramAddress(seeds: [Array("__event_authority".utf8)], programID: SolanaProgramID.jupiterV6).address
        #expect(derived == JupiterRouteDecoder.eventAuthority)
        #expect(try idl().instruction("route_v2").eventAuthority == derived.base58)
    }

    @Test("Minimo garantido: cotado menos o piso da tolerancia, igual ao otherAmountThreshold da Jupiter")
    func minimum() {
        #expect(JupiterRoute.minimumOut(quoted: 6_080_466, slippageBps: 50) == 6_050_064)
        #expect(JupiterRoute.minimumOut(quoted: 1_216_759, slippageBps: 50) == 1_210_676)
        #expect(JupiterRoute.minimumOut(quoted: 41_123_821, slippageBps: 100) == 40_712_583)
        #expect(JupiterRoute.minimumOut(quoted: 1_000, slippageBps: 0) == 1_000)
        #expect(JupiterRoute.minimumOut(quoted: UInt64.max, slippageBps: 9_999) > 0)
        #expect(JupiterRoute.minimumOut(quoted: 1_000, slippageBps: 10_000) == 0)
        #expect(JupiterRoute.minimumOut(quoted: 1_000, slippageBps: UInt16.max) == 0)
    }

    @Test("Proposta gravada: campos, tabelas so pelo endereco, rota decodificada")
    func proposals() throws {
        let owner = try F.owner().publicKey
        #expect(owner.base58 == "9hdr8SYDibjubvqvXXymL53a78EFCvq9utaEuEvp2Qsw")

        let solUSDC = try F.proposal("build-sol-usdc")
        #expect(solUSDC.inputMint == SolanaWrappedSOL.mint && solUSDC.outputMint == F.usdcMint)
        #expect(solUSDC.inAmount == 50_000_000 && solUSDC.outAmount == 6_080_466 && solUSDC.otherAmountThreshold == 6_050_064)
        #expect(solUSDC.lookupTableAddresses.count == 4 && solUSDC.lookupTableAddresses == solUSDC.lookupTableAddresses.sorted())
        #expect(solUSDC.tipInstruction == nil && solUSDC.otherInstructions.isEmpty)
        let route = try JupiterRouteDecoder.decode(
            programID: solUSDC.swapInstruction.programID, accounts: solUSDC.swapInstruction.accounts.map(\.publicKey), data: solUSDC.swapInstruction.data
        )
        #expect(route.kind == .sharedAccountsRouteV2)
        #expect(route.inAmount == 50_000_000 && route.quotedOutAmount == 6_080_466 && route.slippageBps == 50)
        #expect(route.platformFeeBps == 0 && route.positiveSlippageBps == 0)
        #expect(route.userTransferAuthority == owner)
        #expect(route.sourceTokenAccount == (try F.ata(owner, SolanaWrappedSOL.mint)))
        #expect(route.destinationTokenAccount == (try F.ata(owner, F.usdcMint)))
        #expect(route.minimumOut == solUSDC.otherAmountThreshold)

        let usdcSOL = try F.proposal("build-usdc-sol")
        let v2 = try JupiterRouteDecoder.decode(
            programID: usdcSOL.swapInstruction.programID, accounts: usdcSOL.swapInstruction.accounts.map(\.publicKey), data: usdcSOL.swapInstruction.data
        )
        #expect(v2.kind == .routeV2 && v2.optionalDestination == nil && v2.slippageBps == 100)
        #expect(v2.destinationMint == SolanaWrappedSOL.mint)
    }

    @Test("Cotacao: formato do /swap/v2/quote")
    func quote() throws {
        let json = #"{"inputMint":"So11111111111111111111111111111111111111112","inAmount":"10000000","outputMint":"EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v","outAmount":"1217830","otherAmountThreshold":"1211741","swapMode":"ExactIn","slippageBps":50,"platformFee":null,"priceImpactPct":"0","routePlan":[],"contextSlot":450545280}"#
        let quote = try SolanaSwapQuote.decodeJupiter(Data(json.utf8))
        #expect(quote.outAmount == 1_217_830 && quote.otherAmountThreshold == 1_211_741 && quote.platformFeeBps == nil)
        let exactOut = json.replacingOccurrences(of: "ExactIn", with: "ExactOut")
        #expect(throws: SolanaSwapProposalError.unsupportedSwapMode("ExactOut")) { try SolanaSwapQuote.decodeJupiter(Data(exactOut.utf8)) }
    }
}

/// Rascunho, simulacao e plano, de ponta a ponta com as propostas gravadas.
@Suite("Solana troca: plano validado")
struct SolanaTradePlanTests {
    @Test("SOL -> USDC: rascunho, simulacao honesta, plano assinado e relido", arguments: ["sol-usdc", "usdc-sol", "usdc-usdt"])
    func endToEnd(_ which: String) throws {
        let owner = try F.owner().publicKey
        let testCase: F.Case = switch which {
        case "sol-usdc": F.solToUSDC()
        case "usdc-sol": try F.usdcToSOL(owner: owner)
        default: try F.usdcToUSDT(owner: owner)
        }
        let draft = try F.draft(testCase)
        #expect(draft.message.version == .v0)
        #expect(draft.message.feePayer == owner)
        #expect(draft.simulationAccounts.first == owner)
        // A transacao de simulacao tem a assinatura zerada e a mensagem do rascunho.
        let unsigned = try SolanaWireTransaction(base64: draft.simulationTransactionBase64)
        #expect(unsigned.messageBytes == draft.message.serialize())
        #expect(unsigned.signatures == [[UInt8](repeating: 0, count: 64)])

        let plan = try SolanaSwapPlanner.plan(draft, simulation: try F.honestSimulation(draft, units: 150_000), now: F.now)
        #expect(plan.review.kind == .swap)
        #expect(plan.chain == .solana)
        let transaction = try #require(plan.transactions.first as? SolanaTransaction)

        // CU limite = consumo * 1,1 (arredondado para cima) e preco dentro do teto.
        let verified = try SolanaMessageVerifier.verify(
            transaction.message,
            policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: Set(SolanaProgram.allCases), allowedRecipients: [try F.ata(owner, SolanaWrappedSOL.mint)]),
            lookupTables: try F.tables()
        )
        #expect(verified.computeUnitLimit == 165_000)
        #expect(verified.maxPriorityFee <= BigUInt(SolanaLimits.maxPriorityFeeLamports))

        // Assina como o EscaliburKeys faria (aqui com a chave de teste), monta e rele.
        let request = try #require(transaction.signingRequests.first)
        #expect(request.payload == transaction.message.serialize())
        let seed = F.seed()
        defer { seed.wipe() }
        let signed = try transaction.assemble(with: [ProducedSignature(bytes: try Ed25519.sign(request.payload, seed: seed))])
        let wire = try SolanaWireTransaction(bytes: signed.raw)
        #expect(wire.verifySignatures())
        #expect(wire.message == transaction.message)
        #expect(signed.raw.count <= SolanaTransaction.maxSerializedSize)

        // A rota na mensagem final e byte a byte a da proposta.
        let tables = try F.tables()
        let keys = wire.message.accountKeys(loaded: try wire.message.resolveLookups(tables))
        let routes = wire.message.instructions.filter { keys[Int($0.programIDIndex)] == SolanaProgramID.jupiterV6 }
        #expect(routes.count == 1)
        let proposal = try F.proposal(testCase.name)
        #expect(routes.first?.data == proposal.swapInstruction.data)
        #expect(routes.first.map { $0.accountIndexes.map { keys[Int($0)] } } == proposal.swapInstruction.accounts.map(\.publicKey))
    }

    @Test("Revisao em portugues: sai, entra no minimo, preco, taxa da rede, sem taxa da Escalibur, provedor")
    func review() throws {
        let draft = try F.draft(F.solToUSDC())
        let plan = try SolanaSwapPlanner.plan(draft, simulation: try F.honestSimulation(draft), now: F.now)
        let lines = Dictionary(plan.review.lines.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(plan.review.title == "Trocar 0,05 SOL por USDC")
        #expect(lines["Sai"] == "0,05 SOL")
        // Os movimentos saem da rota decodificada da mensagem compilada.
        #expect(plan.review.outgoing == PlanReview.Movement(assetID: "solana:native", amount: BigUInt(draft.route.inAmount)))
        #expect(plan.review.outgoing?.amount == 50_000_000)
        #expect(plan.review.incomingMinimum == PlanReview.Movement(
            assetID: "solana:EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", amount: BigUInt(draft.route.minimumOut)
        ))
        #expect(plan.review.incomingMinimum?.amount == 6_050_064)
        #expect(plan.review.beneficiary == (try F.owner().publicKey.base58))
        #expect(lines["Entra, no mínimo"] == "6,050064 USDC")
        #expect(lines["Estimativa"] == "6,080466 USDC")
        #expect(lines["Preço"] == "1 SOL ≈ 121,60932 USDC")
        #expect(lines["Tolerância de preço"] == "0,5%")
        #expect(lines["Escalibur"] == "Sem taxa da Escalibur")
        #expect(lines["Provedor"] == "Jupiter")
        #expect(lines["Taxa da rede"] != nil)
        #expect(lines["Criação da sua conta de USDC"] == "0,00148844 SOL")
        #expect(plan.review.warnings.contains(.activatesAccount(minimum: "0,00148844 SOL")))
        let receive = try #require(plan.review.lines.first { $0.label == "Recebe na sua conta de token" })
        let ownATA = try F.ata(try F.owner().publicKey, F.usdcMint)
        #expect(receive.verbatim && receive.value == ownATA.base58)
        for line in plan.review.lines {
            #expect(!line.value.contains("—") && !line.value.contains("–") && !line.label.contains("—"))
        }
    }

    @Test("Mint comprado com taxa do emissor: linha propria e aviso, sem bloquear")
    func issuerFee() throws {
        let feeUSDC = SolanaSwapAsset(mint: F.usdcMint, program: .token, decimals: 6, symbol: "USDC", isVerified: true,
                                      extensions: [.transferFee(basisPoints: 100, maximumFee: BigUInt(1_000_000))])
        let draft = try F.draft(F.solToUSDC(buy: feeUSDC))
        let plan = try SolanaSwapPlanner.plan(draft, simulation: try F.honestSimulation(draft), now: F.now)
        #expect(plan.review.lines.contains(PlanReview.Line("Taxa do emissor de USDC", "até 1%")))
        #expect(plan.review.warnings.contains(.highFee(percentOfAmount: 1)))
    }

    @Test("Prioridade absurda do RPC: o plano sai com a taxa no teto compilado")
    func priorityCap() throws {
        let draft = try F.draft(F.solToUSDC(), network: try F.network(price: 1_000_000_000_000))
        let plan = try SolanaSwapPlanner.plan(draft, simulation: try F.honestSimulation(draft), now: F.now)
        let transaction = try #require(plan.transactions.first as? SolanaTransaction)
        let verified = try SolanaMessageVerifier.verify(
            transaction.message,
            policy: SolanaVerificationPolicy(owner: try F.owner().publicKey, allowedPrograms: Set(SolanaProgram.allCases), allowedRecipients: [try F.ata(try F.owner().publicKey, SolanaWrappedSOL.mint)]),
            lookupTables: try F.tables()
        )
        #expect(verified.maxPriorityFee <= BigUInt(SolanaLimits.maxPriorityFeeLamports))
        #expect((verified.computeUnitPrice ?? 0) <= SolanaLimits.maxComputeUnitPrice)
    }
}

/// Cada recusa, com a proposta gravada adulterada num ponto so.
@Suite("Solana troca: recusas")
struct SolanaTradeRefusalTests {
    func refuses(_ expected: SolanaSwapError, case testCase: F.Case = F.solToUSDC(), network: SolanaNetworkState? = nil, _ mutate: (SolanaSwapProposal) throws -> SolanaSwapProposal = { $0 }) throws {
        let proposal = try mutate(try F.proposal(testCase.name))
        #expect(throws: expected) { try F.draft(testCase, proposal: proposal, network: network) }
    }

    @Test("Programa estranho no preparo")
    func strangeProgram() throws {
        let memo = SolanaInstruction(programID: try SolanaPublicKey(base58: "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"), accounts: [], data: Array("oi".utf8))
        try refuses(.unexpectedSetupInstruction(index: 4)) { F.with($0, setup: $0.setupInstructions + [memo]) }
    }

    @Test("Rota de outro programa no lugar da Jupiter")
    func notJupiter() throws {
        let impostor = try SolanaPublicKey(base58: "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr")
        try refuses(.route(.notJupiterProgram(impostor))) {
            F.with($0, swap: SolanaInstruction(programID: impostor, accounts: $0.swapInstruction.accounts, data: $0.swapInstruction.data))
        }
    }

    @Test("Destino da rota e o ATA de outra pessoa")
    func destinationOfStranger() throws {
        let strangerATA = try F.ata(F.stranger, F.usdcMint)
        // shared_accounts_route_v2: conta 5 = destination_token_account.
        try refuses(.destinationNotOwnerAccount(strangerATA)) { F.with($0, swap: F.patchedSwap($0.swapInstruction, account: 5, to: strangerATA)) }
        // route_v2 (USDC -> SOL): conta 2 = user_destination_token_account, conta 7 = destino opcional.
        let owner = try F.owner().publicKey
        let strangerWSOL = try F.ata(F.stranger, SolanaWrappedSOL.mint)
        try refuses(.destinationNotOwnerAccount(strangerWSOL), case: try F.usdcToSOL(owner: owner)) {
            F.with($0, swap: F.patchedSwap($0.swapInstruction, account: 2, to: strangerWSOL))
        }
        try refuses(.destinationNotOwnerAccount(strangerWSOL), case: try F.usdcToSOL(owner: owner)) {
            F.with($0, swap: F.patchedSwap($0.swapInstruction, account: 7, to: strangerWSOL))
        }
    }

    @Test("Autoridade de transferencia da rota nao e o dono")
    func authority() throws {
        try refuses(.authorityNotOwner(F.stranger)) { F.with($0, swap: F.patchedSwap($0.swapInstruction, account: 1, to: F.stranger)) }
    }

    @Test("Minimo menor que o mostrado ao dono")
    func minimumBelowShown() throws {
        try refuses(.minimumBelowShown(shown: BigUInt(6_050_065), route: 6_050_064), case: F.solToUSDC(minimumShown: BigUInt(6_050_065)))
        // Exatamente o mostrado passa.
        _ = try F.draft(F.solToUSDC(minimumShown: BigUInt(6_050_064)))
    }

    @Test("Valor cotado nos bytes menor que o da cotacao (minimo rebaixado por dentro)")
    func quotedOutLowered() throws {
        // shared v2: disc(8) + id(1) + in(8) -> quoted em 17.
        try refuses(.quotedOutMismatch(proposal: 6_080_466, route: 1)) {
            F.with($0, swap: F.patchedSwap($0.swapInstruction) { F.write(UInt64(1), into: &$0, at: 17) })
        }
        // Proposta e bytes rebaixados juntos: o minimo passa a nao bater com o threshold.
        try refuses(.minimumMismatch(proposal: 6_050_064, route: 995)) {
            F.with($0, swap: F.patchedSwap($0.swapInstruction) { F.write(UInt64(1_000), into: &$0, at: 17) }, outAmount: 1_000)
        }
    }

    @Test("Tolerancia nos bytes diferente da pedida, e tolerancia acima do teto")
    func slippage() throws {
        // shared v2: tolerancia em 25.
        try refuses(.slippageMismatch(expected: 50, found: 5_000)) {
            F.with($0, swap: F.patchedSwap($0.swapInstruction) { F.write(UInt16(5_000), into: &$0, at: 25) })
        }
        try refuses(.slippageTooHigh(600), case: F.solToUSDC(slippage: 600))
    }

    @Test("Taxa de plataforma diferente de zero, e taxa sobre ganho positivo")
    func platformFee() throws {
        // shared v2: platform_fee_bps em 27, positive_slippage_bps em 29.
        try refuses(.platformFee(20)) { F.with($0, swap: F.patchedSwap($0.swapInstruction) { F.write(UInt16(20), into: &$0, at: 27) }) }
        try refuses(.positiveSlippageFee(5_000)) { F.with($0, swap: F.patchedSwap($0.swapInstruction) { F.write(UInt16(5_000), into: &$0, at: 29) }) }
    }

    @Test("Valor de entrada nos bytes diferente do pedido")
    func inAmount() throws {
        try refuses(.inAmountMismatch(expected: 50_000_000, found: 60_000_000)) {
            F.with($0, swap: F.patchedSwap($0.swapInstruction) { F.write(UInt64(60_000_000), into: &$0, at: 9) })
        }
    }

    @Test("Rota antiga (plano antes dos escalares) nao tem decodificador: recusa")
    func legacyRoute() throws {
        let route: [UInt8] = [229, 23, 203, 151, 122, 227, 173, 42]
        try refuses(.route(.unsupportedInstruction(discriminator: route))) {
            F.with($0, swap: F.patchedSwap($0.swapInstruction) { $0.replaceSubrange(0..<8, with: route) })
        }
    }

    @Test("Gorjeta, instrucoes extras e orcamento com outro programa")
    func extras() throws {
        let tip = SolanaSystemInstruction.transfer(from: try F.owner().publicKey, to: F.stranger, lamports: 1_000_000)
        try refuses(.tipInstruction) { F.with($0, tip: .some(tip)) }
        try refuses(.otherInstructions(count: 1)) { F.with($0, other: [tip]) }
        try refuses(.unexpectedComputeBudgetInstruction(index: 1)) { F.with($0, computeBudget: $0.computeBudgetInstructions + [tip]) }
    }

    @Test("SetAuthority, Approve, CloseAccount para outro e AdvanceNonceAccount no preparo ou na limpeza")
    func forbiddenInstructions() throws {
        let owner = try F.owner().publicKey
        let wsol = try F.ata(owner, SolanaWrappedSOL.mint)
        let token = SolanaProgramID.token
        let setAuthority = SolanaInstruction(programID: token, accounts: [SolanaAccountMeta(wsol, isSigner: false, isWritable: true), SolanaAccountMeta(owner, isSigner: true, isWritable: false)], data: [6, 2, 1] + F.stranger.bytes)
        let approve = SolanaInstruction(programID: token, accounts: [SolanaAccountMeta(wsol, isSigner: false, isWritable: true), SolanaAccountMeta(F.stranger, isSigner: false, isWritable: false), SolanaAccountMeta(owner, isSigner: true, isWritable: false)], data: [4] + UInt64.max.littleEndianByteArray)
        let advanceNonce = SolanaInstruction(programID: SolanaProgramID.system, accounts: [SolanaAccountMeta(F.stranger, isSigner: false, isWritable: true), SolanaAccountMeta(owner, isSigner: true, isWritable: false)], data: [4, 0, 0, 0])
        for (index, bad) in [setAuthority, approve, advanceNonce].enumerated() {
            try refuses(.unexpectedSetupInstruction(index: 0), "caso \(index)") { F.with($0, setup: [bad] + $0.setupInstructions) }
        }
        let closeToStranger = SolanaSwapInstructions.closeAccount(account: wsol, destination: F.stranger, authority: owner)
        try refuses(.unexpectedCleanupInstruction) { F.with($0, cleanup: .some(closeToStranger)) }
        // Embrulhar mais SOL do que o valor da troca tambem nao passa.
        let overWrap = SolanaSystemInstruction.transfer(from: owner, to: wsol, lamports: 90_000_000)
        try refuses(.unexpectedSetupInstruction(index: 1)) { p in
            var setup = p.setupInstructions
            setup[1] = overWrap
            return F.with(p, setup: setup)
        }
    }

    func refuses(_ expected: SolanaSwapError, _ label: String, _ mutate: (SolanaSwapProposal) throws -> SolanaSwapProposal) throws {
        let proposal = try mutate(try F.proposal("build-sol-usdc"))
        #expect(throws: expected, "\(label)") { try F.draft(F.solToUSDC(), proposal: proposal) }
    }

    @Test("Mint comprado com delegado permanente ou hook de transferencia: bloqueia")
    func boughtMintExtensions() throws {
        let delegated = SolanaSwapAsset(mint: F.usdcMint, program: .token, decimals: 6, symbol: "USDC", isVerified: true, extensions: [.permanentDelegate])
        try refuses(.boughtMintPermanentDelegate, case: F.solToUSDC(buy: delegated))
        let hooked = SolanaSwapAsset(mint: F.usdcMint, program: .token, decimals: 6, symbol: "USDC", isVerified: true, extensions: [.transferHook])
        try refuses(.boughtMintTransferHook, case: F.solToUSDC(buy: hooked))
        let unknown = SolanaSwapAsset(mint: F.usdcMint, program: .token, decimals: 6, symbol: "USDC", isVerified: true, extensions: [.unknown("novidade")])
        try refuses(.unknownMintExtension("novidade"), case: F.solToUSDC(buy: unknown))
    }

    @Test("Proposta para outra troca que a pedida")
    func proposalMismatch() throws {
        let other = F.Case(
            name: "build-sol-usdc",
            intent: SolanaSwapIntent(sell: .sol, buy: F.usdc, amountIn: BigUInt(40_000_000), slippageBps: 50),
            accounts: F.solToUSDC().accounts
        )
        try refuses(.proposalMismatch("valor de entrada"), case: other)
        let otherMint = F.Case(name: "build-sol-usdc", intent: SolanaSwapIntent(sell: .sol, buy: F.usdt, amountIn: BigUInt(50_000_000), slippageBps: 50), accounts: F.solToUSDC().accounts)
        try refuses(.proposalMismatch("mint comprado"), case: otherMint)
    }

    @Test("Saldo, estado velho e tabela que falta")
    func stateProblems() throws {
        // Pico: valor + taxa do rascunho (5.000 + 50.000 micro-lamports * 1,4 M CU = 75.000) + rent do ATA de USDC + rent temporario do SOL embrulhado.
        try refuses(.insufficientFunds(needed: BigUInt(50_000_000) + BigUInt(75_000) + F.tokenRent + F.tokenRent, available: BigUInt(10_000_000)),
                    network: try F.network(balance: 10_000_000))
        try refuses(.plan(.staleNetworkState), network: try F.network(fetchedAt: F.now.addingTimeInterval(-120)))
        let proposal = try F.proposal("build-sol-usdc")
        let partial = try F.tables().filter { $0.address != proposal.lookupTableAddresses[0] }
        #expect(throws: SolanaSwapError.missingLookupTable(proposal.lookupTableAddresses[0])) { try F.draft(F.solToUSDC(), tables: partial) }
    }

    @Test("Conta de origem de outro dono, congelada ou sem saldo")
    func sourceAccount() throws {
        let owner = try F.owner().publicKey
        let base = try F.usdcToSOL(owner: owner)
        let frozen = F.Case(name: base.name, intent: base.intent, accounts: SolanaSwapAccounts(
            source: try F.tokenAccount(owner, F.usdcMint, amount: 7_000_000, frozen: true), destination: .missing,
            destinationRentMinimum: F.tokenRent, wrappedSOLRentMinimum: F.tokenRent))
        try refuses(.sourceAccountFrozen, case: frozen)
        let poor = F.Case(name: base.name, intent: base.intent, accounts: SolanaSwapAccounts(
            source: try F.tokenAccount(owner, F.usdcMint, amount: 1), destination: .missing,
            destinationRentMinimum: F.tokenRent, wrappedSOLRentMinimum: F.tokenRent))
        try refuses(.insufficientTokenBalance(needed: BigUInt(5_000_000), available: BigUInt(1)), case: poor)
        let strangers = F.Case(name: base.name, intent: base.intent, accounts: SolanaSwapAccounts(
            source: try F.tokenAccount(F.stranger, F.usdcMint, amount: 7_000_000), destination: .missing,
            destinationRentMinimum: F.tokenRent, wrappedSOLRentMinimum: F.tokenRent))
        try refuses(.sourceAccountMismatch, case: strangers)
    }
}

/// A Jupiter nao e a unica fonte de preco (auditoria 2, A2).
@Suite("Solana troca: preco de referencia e contas vigiadas")
struct SolanaTradeReferenceTests {
    @Test("Regressao A2: sem referencia, so dois stablecoins da lista trocam (pela paridade)")
    func noReference() throws {
        #expect(throws: SolanaSwapError.noPriceReference) { try F.draft(F.solToUSDC(reference: .none)) }
        let owner = try F.owner().publicKey
        let stable = try F.usdcToUSDT(owner: owner)
        #expect(stable.intent.reference.oracleOut == nil)
        _ = try F.draft(stable)
        // Token "estavel" fora da lista nao tem paridade.
        let impostor = SolanaSwapAsset(mint: F.stranger, program: .token, decimals: 6, symbol: "USDT", isVerified: false, extensions: [])
        #expect(SolanaSwapPlanner.listedStable(impostor) == nil)
        #expect(SolanaSwapPlanner.listedStable(F.usdt)?.symbol == "USDT")
    }

    @Test("Regressao A2: cotacao mais de 5% pior que a referencia recusa; entre 2% e 5% a revisao diz quanto")
    func farFromReference() throws {
        // A rota gravada cota 6,080466 USDC por 0,05 SOL.
        #expect(throws: SolanaSwapError.priceFarFromReference(deviationBps: 645)) {
            try F.draft(F.solToUSDC(reference: TradeMarketReference(oracleOut: 6_500_000)))
        }
        let draft = try F.draft(F.solToUSDC(reference: TradeMarketReference(oracleOut: 6_250_000)))
        let plan = try SolanaSwapPlanner.plan(draft, simulation: try F.honestSimulation(draft), now: F.now)
        #expect(plan.review.lines.contains(PlanReview.Line("Preço de referência", "2,71% pior que o preço médio de mercado")))
        let calm = try F.draft(F.solToUSDC())
        let quiet = try SolanaSwapPlanner.plan(calm, simulation: try F.honestSimulation(calm), now: F.now)
        #expect(!quiet.review.lines.contains { $0.label == "Preço de referência" })
    }

    @Test("Regressao A2: a simulacao olha as outras contas de token do dono nos mints da lista")
    func guardedAccounts() throws {
        let owner = try F.owner().publicKey
        let jupMint = try SolanaPublicKey(base58: "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN")
        let jupATA = try F.ata(owner, jupMint)
        let before = SolanaAccountSnapshot(
            address: jupATA, exists: true, lamports: 2_039_280, programOwner: SolanaProgramID.token,
            tokenMint: jupMint, tokenOwner: owner, tokenAmount: 1_000_000
        )
        let base = F.solToUSDC()
        let guarded = F.Case(name: base.name, intent: base.intent, accounts: SolanaSwapAccounts(
            source: nil, destination: .missing, destinationRentMinimum: F.tokenRent, wrappedSOLRentMinimum: F.tokenRent, guarded: [before]
        ))
        let draft = try F.draft(guarded)
        #expect(draft.simulationAccounts.contains(jupATA))
        let honest = try F.honestSimulation(draft).accounts
        _ = try SolanaSwapPlanner.plan(draft, simulation: SolanaSimulationOutcome(error: nil, unitsConsumed: 150_000, accounts: honest + [before]), now: F.now)

        let drained = SolanaAccountSnapshot(
            address: jupATA, exists: true, lamports: 2_039_280, programOwner: SolanaProgramID.token,
            tokenMint: jupMint, tokenOwner: owner, tokenAmount: 0
        )
        #expect(throws: SolanaSwapError.simulationTouchedOtherAccount(jupATA)) {
            try SolanaSwapPlanner.plan(draft, simulation: SolanaSimulationOutcome(error: nil, unitsConsumed: 150_000, accounts: honest + [drained]), now: F.now)
        }
        #expect(throws: SolanaSwapError.simulationTouchedOtherAccount(jupATA)) {
            try SolanaSwapPlanner.plan(draft, simulation: SolanaSimulationOutcome(
                error: nil, unitsConsumed: 150_000, accounts: honest + [.missing(jupATA)]
            ), now: F.now)
        }
        #expect(throws: SolanaSwapError.simulationMissingAccount(jupATA)) {
            try SolanaSwapPlanner.plan(draft, simulation: SolanaSimulationOutcome(error: nil, unitsConsumed: 150_000, accounts: honest), now: F.now)
        }
    }
}

/// A simulacao como segunda opiniao.
@Suite("Solana troca: conferencia da simulacao")
struct SolanaTradeSimulationTests {
    @Test("Simulacao com erro bloqueia")
    func failed() throws {
        let draft = try F.draft(F.solToUSDC())
        let outcome = SolanaSimulationOutcome(error: #"{"InstructionError":[5,{"Custom":6001}]}"#, unitsConsumed: 90_000, accounts: [])
        #expect(throws: SolanaSwapError.simulationFailed(#"{"InstructionError":[5,{"Custom":6001}]}"#)) { try SolanaSwapPlanner.plan(draft, simulation: outcome, now: F.now) }
        let noUnits = SolanaSimulationOutcome(error: nil, unitsConsumed: nil, accounts: try F.honestSimulation(draft).accounts)
        #expect(throws: SolanaSwapError.simulationNoComputeUnits) { try SolanaSwapPlanner.plan(draft, simulation: noUnits, now: F.now) }
    }

    @Test("Entra menos que o minimo na conta do dono")
    func receivedTooLittle() throws {
        let draft = try F.draft(F.solToUSDC())
        var accounts = try F.honestSimulation(draft).accounts
        let destination = accounts[1]
        accounts[1] = SolanaAccountSnapshot(address: destination.address, exists: true, lamports: destination.lamports, programOwner: destination.programOwner,
                                            tokenMint: destination.tokenMint, tokenOwner: destination.tokenOwner, tokenAmount: 6_050_063)
        #expect(throws: SolanaSwapError.simulationReceivedTooLittle(asset: "USDC", received: BigUInt(6_050_063), minimum: BigUInt(6_050_064))) {
            try SolanaSwapPlanner.plan(draft, simulation: SolanaSimulationOutcome(error: nil, unitsConsumed: 150_000, accounts: accounts), now: F.now)
        }
    }

    @Test("SOL do dono cai alem de valor, taxa e rent")
    func solDrained() throws {
        let draft = try F.draft(F.solToUSDC())
        var accounts = try F.honestSimulation(draft).accounts
        accounts[0] = SolanaAccountSnapshot(address: accounts[0].address, exists: true, lamports: accounts[0].lamports - 500_000_000, programOwner: SolanaProgramID.system)
        #expect(throws: (any Error).self) { try SolanaSwapPlanner.plan(draft, simulation: SolanaSimulationOutcome(error: nil, unitsConsumed: 150_000, accounts: accounts), now: F.now) }
        do {
            _ = try SolanaSwapPlanner.plan(draft, simulation: SolanaSimulationOutcome(error: nil, unitsConsumed: 150_000, accounts: accounts), now: F.now)
        } catch SolanaSwapError.simulationSpentTooMuch(let asset, _, _) {
            #expect(asset == "SOL")
        }
    }

    @Test("Token vendido sai mais que o valor")
    func tokenDrained() throws {
        let owner = try F.owner().publicKey
        let draft = try F.draft(try F.usdcToUSDT(owner: owner))
        var accounts = try F.honestSimulation(draft).accounts
        let source = accounts[1]
        accounts[1] = SolanaAccountSnapshot(address: source.address, exists: true, lamports: source.lamports, programOwner: source.programOwner,
                                            tokenMint: source.tokenMint, tokenOwner: source.tokenOwner, tokenAmount: 0)
        let tighter = SolanaSwapAccounts(source: try F.tokenAccount(owner, F.usdcMint, amount: 9_000_000), destination: draft.accountsForTest.destination,
                                         destinationRentMinimum: F.tokenRent, wrappedSOLRentMinimum: F.tokenRent)
        let draft2 = try F.draft(F.Case(name: "build-usdc-usdt", intent: draft.intent, accounts: tighter))
        #expect(throws: SolanaSwapError.simulationSpentTooMuch(asset: "USDC", spent: BigUInt(9_000_000), limit: BigUInt(5_000_000))) {
            try SolanaSwapPlanner.plan(draft2, simulation: SolanaSimulationOutcome(error: nil, unitsConsumed: 150_000, accounts: accounts), now: F.now)
        }
    }

    @Test("Conta de destino na simulacao com outro dono, ou faltando")
    func wrongAccount() throws {
        let draft = try F.draft(F.solToUSDC())
        var accounts = try F.honestSimulation(draft).accounts
        let destination = accounts[1]
        accounts[1] = SolanaAccountSnapshot(address: destination.address, exists: true, lamports: destination.lamports, programOwner: destination.programOwner,
                                            tokenMint: destination.tokenMint, tokenOwner: F.stranger, tokenAmount: destination.tokenAmount)
        #expect(throws: SolanaSwapError.simulationWrongAccount(destination.address)) {
            try SolanaSwapPlanner.plan(draft, simulation: SolanaSimulationOutcome(error: nil, unitsConsumed: 150_000, accounts: accounts), now: F.now)
        }
        #expect(throws: SolanaSwapError.simulationMissingAccount(destination.address)) {
            try SolanaSwapPlanner.plan(draft, simulation: SolanaSimulationOutcome(error: nil, unitsConsumed: 150_000, accounts: [accounts[0]]), now: F.now)
        }
    }

    @Test("Comprar SOL: o SOL do dono tem de subir pelo menos o minimo")
    func buySOL() throws {
        let owner = try F.owner().publicKey
        let draft = try F.draft(try F.usdcToSOL(owner: owner))
        _ = try SolanaSwapPlanner.plan(draft, simulation: try F.honestSimulation(draft), now: F.now)
        var accounts = try F.honestSimulation(draft).accounts
        accounts[0] = SolanaAccountSnapshot(address: owner, exists: true, lamports: 2_000_000_000, programOwner: SolanaProgramID.system)
        #expect(throws: (any Error).self) {
            try SolanaSwapPlanner.plan(draft, simulation: SolanaSimulationOutcome(error: nil, unitsConsumed: 150_000, accounts: accounts), now: F.now)
        }
    }

    @Test("Layout de conta de token: mint, dono e saldo; mint do Token-2022 nao vira conta")
    func snapshotLayout() throws {
        let owner = try F.owner().publicKey
        var data = F.usdcMint.bytes + owner.bytes + UInt64(123_456).littleEndianByteArray
        data += [UInt8](repeating: 0, count: 165 - data.count)
        let account = SolanaAccountSnapshot.parse(address: F.stranger, lamports: 2_039_280, programOwner: SolanaProgramID.token, data: data)
        #expect(account.tokenMint == F.usdcMint && account.tokenOwner == owner && account.tokenAmount == 123_456)
        var mint2022 = data + [UInt8](repeating: 0, count: 40)
        mint2022[165] = 1  // tipo Mint
        #expect(SolanaAccountSnapshot.parse(address: F.stranger, lamports: 1, programOwner: SolanaProgramID.token2022, data: mint2022).tokenMint == nil)
        mint2022[165] = 2  // tipo Account
        #expect(SolanaAccountSnapshot.parse(address: F.stranger, lamports: 1, programOwner: SolanaProgramID.token2022, data: mint2022).tokenAmount == 123_456)
        #expect(SolanaSimulationOutcome(error: nil, unitsConsumed: 100, accounts: []).suggestedComputeUnitLimit == 110)
        #expect(SolanaSimulationOutcome(error: nil, unitsConsumed: 5_000_000, accounts: []).suggestedComputeUnitLimit == SolanaLimits.maxComputeUnitLimit)
    }
}
