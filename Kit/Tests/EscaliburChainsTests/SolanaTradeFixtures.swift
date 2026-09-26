import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

/// Fixtures da troca na Solana (Fixtures/solana-troca), gravadas em 26/09/2026:
///
/// - `build-*.json`: respostas reais de `GET api.jup.ag/swap/v2/build` (sem chave)
///   com `taker` = a chave de teste deste arquivo (semente 0x5E repetida, endereco
///   9hdr8SYDibjubvqvXXymL53a78EFCvq9utaEuEvp2Qsw). SOL->USDC e USDC->USDT vieram
///   em `shared_accounts_route_v2`; USDC->SOL em `route_v2`.
/// - `lookup-tables.json`: o conteudo de cada tabela citada, lido da cadeia em dois
///   RPCs (identicos entre si).
/// - `jupiter-idl.json`: trecho do IDL Anchor do programa da Jupiter, lido da cadeia.
enum SolanaTradeFixtures {
    static let seedBytes = [UInt8](repeating: 0x5E, count: 32)
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static let usdcMint = try! SolanaPublicKey(base58: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
    static let usdtMint = try! SolanaPublicKey(base58: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB")
    /// Uma carteira qualquer (toly.sol), para fazer papel de terceiro.
    static let stranger = try! SolanaPublicKey(base58: "86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY")

    static let usdc = SolanaSwapAsset(mint: usdcMint, program: .token, decimals: 6, symbol: "USDC", isVerified: true, extensions: [])
    static let usdt = SolanaSwapAsset(mint: usdtMint, program: .token, decimals: 6, symbol: "USDT", isVerified: true, extensions: [])

    /// Rent de conta de token (165 bytes) e de conta vazia, lidos ao vivo em 26/09/2026.
    static let tokenRent = BigUInt(1_488_440)
    static let emptyRent = BigUInt(650_240)

    static func load(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solana-troca"))
        return try Data(contentsOf: url)
    }

    static func proposal(_ name: String) throws -> SolanaSwapProposal {
        try SolanaSwapProposal.decodeJupiterBuild(try load(name))
    }

    static func tables() throws -> [SolanaAddressLookupTable] {
        struct File: Decodable { let tables: [String: [String]] }
        let file = try JSONDecoder().decode(File.self, from: try load("lookup-tables"))
        return try file.tables.map { address, keys in
            SolanaAddressLookupTable(address: try SolanaPublicKey(base58: address), addresses: try keys.map { try SolanaPublicKey(base58: $0) })
        }
    }

    static func seed() -> SecureBytes {
        let seed = SecureBytes(capacity: 32)
        seed.replaceAll(with: seedBytes)
        return seed
    }

    static func owner() throws -> SolanaOwner {
        let seed = seed()
        defer { seed.wipe() }
        return SolanaOwner(path: DefaultPaths.path(for: .solana), publicKey: try SolanaPublicKey(bytes: try Ed25519.publicKey(of: seed)))
    }

    static func network(balance: UInt64 = 2_000_000_000, price: UInt64 = 50_000, fetchedAt: Date = now) throws -> SolanaNetworkState {
        SolanaNetworkState(
            recentBlockhash: try SolanaBlockhash(base58: "EETubP5AKHgjPAhzPAFcb8BAY1hMH639CWCFTqi3hq1k"),
            lastValidBlockHeight: 1_150, currentBlockHeight: 1_000, fetchedAt: fetchedAt,
            balance: BigUInt(balance), rentExemptMinimum: emptyRent, suggestedComputeUnitPrice: price
        )
    }

    static func ata(_ owner: SolanaPublicKey, _ mint: SolanaPublicKey) throws -> SolanaPublicKey {
        try SolanaAssociatedToken.address(owner: owner, mint: mint, tokenProgram: .token)
    }

    /// Conta de token do dono com saldo (para vender token).
    static func tokenAccount(_ owner: SolanaPublicKey, _ mint: SolanaPublicKey, amount: UInt64, frozen: Bool = false) throws -> SolanaTokenAccountState {
        SolanaTokenAccountState(address: try ata(owner, mint), program: .token, mint: mint, owner: owner, amount: BigUInt(amount), isFrozen: frozen)
    }

    /// Os tres casos gravados, com intencao e contas coerentes.
    struct Case {
        let name: String
        let intent: SolanaSwapIntent
        let accounts: SolanaSwapAccounts
    }

    static func solToUSDC(slippage: UInt16 = 50, minimumShown: BigUInt? = nil, buy: SolanaSwapAsset = usdc) -> Case {
        Case(
            name: "build-sol-usdc",
            intent: SolanaSwapIntent(sell: .sol, buy: buy, amountIn: BigUInt(50_000_000), slippageBps: slippage, minimumOutShown: minimumShown),
            accounts: SolanaSwapAccounts(source: nil, destination: .missing, destinationRentMinimum: tokenRent, wrappedSOLRentMinimum: tokenRent)
        )
    }

    static func usdcToSOL(owner: SolanaPublicKey) throws -> Case {
        Case(
            name: "build-usdc-sol",
            intent: SolanaSwapIntent(sell: usdc, buy: .sol, amountIn: BigUInt(5_000_000), slippageBps: 100),
            accounts: SolanaSwapAccounts(
                source: try tokenAccount(owner, usdcMint, amount: 7_000_000), destination: .missing,
                destinationRentMinimum: tokenRent, wrappedSOLRentMinimum: tokenRent
            )
        )
    }

    static func usdcToUSDT(owner: SolanaPublicKey) throws -> Case {
        Case(
            name: "build-usdc-usdt",
            intent: SolanaSwapIntent(sell: usdc, buy: usdt, amountIn: BigUInt(5_000_000), slippageBps: 30),
            accounts: SolanaSwapAccounts(
                source: try tokenAccount(owner, usdcMint, amount: 5_000_000),
                destination: .existing(try tokenAccount(owner, usdtMint, amount: 1_000)),
                destinationRentMinimum: tokenRent, wrappedSOLRentMinimum: tokenRent
            )
        )
    }

    static func draft(_ testCase: Case, proposal: SolanaSwapProposal? = nil, network: SolanaNetworkState? = nil, tables: [SolanaAddressLookupTable]? = nil) throws -> SolanaSwapDraft {
        try SolanaSwapPlanner.draft(
            walletID: UUID(), owner: try owner(), intent: testCase.intent, proposal: try proposal ?? self.proposal(testCase.name),
            lookupTables: try tables ?? self.tables(), accounts: testCase.accounts, network: try network ?? self.network(), now: now
        )
    }

    /// Uma simulacao que confirma exatamente o que a rota promete.
    static func honestSimulation(_ draft: SolanaSwapDraft, units: UInt64 = 150_000, receivedExtra: UInt64 = 0) throws -> SolanaSimulationOutcome {
        let owner = try owner().publicKey
        let intent = draft.intent
        let network = try network()
        let minimum = draft.route.minimumOut + receivedExtra
        var accounts = [SolanaAccountSnapshot]()
        var lamports = network.balance.uint64! - 5_000
        if intent.sell.isNativeSOL { lamports -= intent.amountIn.uint64! }
        if intent.buy.isNativeSOL { lamports += minimum }
        accounts.append(SolanaAccountSnapshot(address: owner, exists: true, lamports: lamports, programOwner: SolanaProgramID.system))
        if !intent.sell.isNativeSOL, let source = draft.accountsForTest.source {
            accounts.append(SolanaAccountSnapshot(
                address: source.address, exists: true, lamports: 2_039_280, programOwner: SolanaProgramID.token,
                tokenMint: intent.sell.mint, tokenOwner: owner, tokenAmount: source.amount.uint64! - intent.amountIn.uint64!
            ))
        }
        if !intent.buy.isNativeSOL {
            var previous: UInt64 = 0
            if case .existing(let state) = draft.accountsForTest.destination { previous = state.amount.uint64! }
            accounts.append(SolanaAccountSnapshot(
                address: try ata(owner, intent.buy.mint), exists: true, lamports: 2_039_280, programOwner: SolanaProgramID.token,
                tokenMint: intent.buy.mint, tokenOwner: owner, tokenAmount: previous + minimum
            ))
        }
        return SolanaSimulationOutcome(error: nil, unitsConsumed: units, accounts: accounts)
    }

    /// Troca campos da proposta sem mexer no resto.
    static func with(
        _ p: SolanaSwapProposal, setup: [SolanaInstruction]? = nil, swap: SolanaInstruction? = nil, cleanup: SolanaInstruction?? = nil,
        other: [SolanaInstruction]? = nil, tip: SolanaInstruction?? = nil, computeBudget: [SolanaInstruction]? = nil,
        inAmount: UInt64? = nil, outAmount: UInt64? = nil, threshold: UInt64? = nil, slippage: UInt16? = nil
    ) -> SolanaSwapProposal {
        SolanaSwapProposal(
            provider: p.provider, inputMint: p.inputMint, outputMint: p.outputMint, inAmount: inAmount ?? p.inAmount,
            outAmount: outAmount ?? p.outAmount, otherAmountThreshold: threshold ?? p.otherAmountThreshold, slippageBps: slippage ?? p.slippageBps,
            priceImpactPercent: p.priceImpactPercent, computeBudgetInstructions: computeBudget ?? p.computeBudgetInstructions,
            setupInstructions: setup ?? p.setupInstructions, swapInstruction: swap ?? p.swapInstruction,
            cleanupInstruction: cleanup ?? p.cleanupInstruction, otherInstructions: other ?? p.otherInstructions,
            tipInstruction: tip ?? p.tipInstruction, lookupTableAddresses: p.lookupTableAddresses
        )
    }

    /// A instrucao de rota com bytes trocados.
    static func patchedSwap(_ ix: SolanaInstruction, _ patch: (inout [UInt8]) -> Void) -> SolanaInstruction {
        var data = ix.data
        patch(&data)
        return SolanaInstruction(programID: ix.programID, accounts: ix.accounts, data: data)
    }

    /// A instrucao de rota com uma conta trocada.
    static func patchedSwap(_ ix: SolanaInstruction, account index: Int, to key: SolanaPublicKey) -> SolanaInstruction {
        var accounts = ix.accounts
        accounts[index] = SolanaAccountMeta(key, isSigner: accounts[index].isSigner, isWritable: accounts[index].isWritable)
        return SolanaInstruction(programID: ix.programID, accounts: accounts, data: ix.data)
    }

    static func write<T: FixedWidthInteger>(_ value: T, into data: inout [UInt8], at offset: Int) {
        for (index, byte) in value.littleEndianByteArray.enumerated() { data[offset + index] = byte }
    }
}

extension SolanaSwapDraft {
    var accountsForTest: SolanaSwapAccounts { accounts }
}
