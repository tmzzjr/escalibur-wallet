import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// Planejamento validado, de ponta a ponta: intencao e estado da rede entram, sai
/// um `SigningPlan`; a transacao e assinada aqui com uma chave de teste (Ed25519
/// do Core, nunca em codigo de producao de EscaliburChains), montada, relida e
/// verificada. E cada recusa tem o seu teste.
@Suite("Solana: planejamento validado")
struct SolanaPlannerTests {
    static let wallet = UUID()
    static let seedBytes = [UInt8](repeating: 0x5E, count: 32)
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static let toly = try! SolanaPublicKey(base58: "86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY")
    static let usdc = try! SolanaPublicKey(base58: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
    static let pyusd = try! SolanaPublicKey(base58: "2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo")
    static let tolyUSDC = try! SolanaPublicKey(base58: "9SHQTA66Ekh7ZgMnKWsjxXk6DwXku8przs45E8bcEe38")

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

    static func network(
        balance: UInt64 = 1_000_000_000, price: UInt64 = 50_000, simulated: UInt32? = nil,
        fetchedAt: Date = now, lastValid: UInt64 = 1_150, current: UInt64 = 1_000
    ) throws -> SolanaNetworkState {
        SolanaNetworkState(
            recentBlockhash: try SolanaBlockhash(base58: "EETubP5AKHgjPAhzPAFcb8BAY1hMH639CWCFTqi3hq1k"),
            lastValidBlockHeight: lastValid, currentBlockHeight: current, fetchedAt: fetchedAt,
            balance: BigUInt(balance), rentExemptMinimum: BigUInt(890_880),
            suggestedComputeUnitPrice: price, simulatedComputeUnits: simulated
        )
    }

    /// Assina como o EscaliburKeys faria (aqui, com a chave de teste), monta e relê.
    static func signAndCheck(_ plan: SigningPlan) throws -> (SignedTransaction, SolanaWireTransaction) {
        #expect(plan.chain == .solana)
        #expect(plan.transactions.count == 1)
        let transaction = try #require(plan.transactions.first as? SolanaTransaction)
        let request = try #require(transaction.signingRequests.first)
        #expect(request.curve == .ed25519)
        #expect(request.scheme == .ed25519)
        #expect(request.path == DefaultPaths.path(for: .solana))
        let seed = seed()
        defer { seed.wipe() }
        #expect(request.expectedPublicKey == (try Ed25519.publicKey(of: seed)))
        let signature = try Ed25519.sign(request.payload, seed: seed)
        let signed = try transaction.assemble(with: [ProducedSignature(bytes: signature)])
        let wire = try SolanaWireTransaction(bytes: signed.raw)
        #expect(wire.verifySignatures())
        #expect(wire.id == signed.id)
        #expect(signed.id == Base58.bitcoin.encode(signature))
        #expect(Data(base64Encoded: signed.encoded).map(Array.init) == signed.raw)
        #expect(wire.messageBytes == transaction.messageBytes)
        #expect(signed.raw.count <= SolanaTransaction.maxSerializedSize)
        return (signed, wire)
    }

    static func line(_ plan: SigningPlan, _ label: String) -> String? {
        plan.review.lines.first { $0.label == label }?.value
    }

    // MARK: SOL

    @Test("Enviar SOL: plano, revisao, assinatura e verificacao")
    func sendSOL() throws {
        let owner = try Self.owner()
        let plan = try SolanaPlanner.planSendSOL(
            walletID: Self.wallet, owner: owner, to: Self.toly.base58, lamports: BigUInt(100_000_000),
            destination: .system(lamports: BigUInt(5_000_000_000)), network: try Self.network(), now: Self.now
        )
        let (_, wire) = try Self.signAndCheck(plan)
        // 5000 de assinatura + teto(50.000 * 2.000 / 1e6) = 100 de prioridade.
        #expect(try SolanaPlanner.sendSOLFee(network: try Self.network()) == BigUInt(5_100))
        #expect(plan.review.kind == .send)
        #expect(plan.review.title == "Enviar 0,1 SOL")
        #expect(Self.line(plan, "Para") == Self.toly.base58)
        #expect(plan.review.lines.first { $0.label == "Para" }?.verbatim == true)
        #expect(Self.line(plan, "Taxa da rede") == "0,0000051 SOL")
        #expect(Self.line(plan, "Inclui prioridade") == "0,0000001 SOL")
        #expect(Self.line(plan, "Total") == "0,1000051 SOL")
        #expect(Self.line(plan, "Saldo depois") == "0,8999949 SOL")
        #expect(plan.review.warnings.isEmpty)

        let message = wire.message
        #expect(message.version == .legacy)
        #expect(message.feePayer == owner.publicKey)
        #expect(message.recentBlockhash.base58 == "EETubP5AKHgjPAhzPAFcb8BAY1hMH639CWCFTqi3hq1k")
        #expect(SolanaMessageTests.decompile(message).map(\.data) == [
            [2] + UInt32(2_000).littleEndianByteArray,
            [3] + UInt64(50_000).littleEndianByteArray,
            [2, 0, 0, 0] + UInt64(100_000_000).littleEndianByteArray,
        ])
        // A mensagem que sai do planejador passa no verificador sozinha.
        _ = try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: owner.publicKey, allowedPrograms: [.computeBudget, .system], allowedRecipients: [Self.toly]))
    }

    @Test("SOL para conta nova: minimo de rent, com aviso de ativacao")
    func sendSOLToNewAccount() throws {
        let owner = try Self.owner()
        let fresh = try SolanaPublicKey(bytes: Hash.sha256(Array("destino novo".utf8)))
        #expect(throws: SolanaPlanError.belowRentExemptMinimum(minimum: BigUInt(890_880))) {
            try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner, to: fresh.base58, lamports: BigUInt(890_879),
                                          destination: .nonexistent, network: try Self.network(), now: Self.now)
        }
        let plan = try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner, to: fresh.base58, lamports: BigUInt(890_880),
                                                 destination: .nonexistent, network: try Self.network(), now: Self.now)
        #expect(plan.review.warnings.contains(.activatesAccount(minimum: "0,00089088 SOL")))
        _ = try Self.signAndCheck(plan)
    }

    @Test("SOL: sobra abaixo do rent recusada; enviar tudo (sobra zero) aceito; saldo insuficiente")
    func sendSOLRemainder() throws {
        let owner = try Self.owner()
        let network = try Self.network(balance: 1_000_000_000)
        let fee = try SolanaPlanner.sendSOLFee(network: network)
        let everything = BigUInt(1_000_000_000) - fee
        let plan = try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner, to: Self.toly.base58, lamports: everything,
                                                 destination: .system(lamports: BigUInt(1)), network: network, now: Self.now)
        #expect(Self.line(plan, "Saldo depois") == "0 SOL")
        #expect(throws: SolanaPlanError.leavesBalanceBelowRent(remainder: BigUInt(100), minimum: BigUInt(890_880))) {
            try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner, to: Self.toly.base58, lamports: everything - BigUInt(100),
                                          destination: .system(lamports: BigUInt(1)), network: network, now: Self.now)
        }
        #expect(throws: SolanaPlanError.insufficientFunds(needed: everything + BigUInt(1) + fee, available: BigUInt(1_000_000_000))) {
            try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner, to: Self.toly.base58, lamports: everything + BigUInt(1),
                                          destination: .system(lamports: BigUInt(1)), network: network, now: Self.now)
        }
    }

    @Test("SOL: destino conta de token ou de programa e recusado; fora da curva gera aviso")
    func sendSOLDestinationKinds() throws {
        let owner = try Self.owner()
        let tokenAccount = SolanaTokenAccountState(address: Self.tolyUSDC, program: .token, mint: Self.usdc, owner: Self.toly, amount: BigUInt(1), isFrozen: false)
        #expect(throws: SolanaPlanError.destinationIsTokenAccount) {
            try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner, to: Self.tolyUSDC.base58, lamports: BigUInt(10_000_000),
                                          destination: .tokenAccount(tokenAccount), network: try Self.network(), now: Self.now)
        }
        let stake = try SolanaPublicKey(base58: "Stake11111111111111111111111111111111111111")
        #expect(throws: SolanaPlanError.destinationOwnedByProgram(stake)) {
            try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner, to: Self.toly.base58, lamports: BigUInt(10_000_000),
                                          destination: .programOwned(owner: stake), network: try Self.network(), now: Self.now)
        }
        // Um cofre (PDA) dono de SOL e conta de sistema fora da curva: passa com aviso.
        let vault = try SolanaPublicKey(base58: "2DRxyJDsDccGL6mb8PLMsKQTCU3C7xUq8aprz53VcW4k")
        let plan = try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner, to: vault.base58, lamports: BigUInt(10_000_000),
                                                 destination: .system(lamports: BigUInt(2_000_000)), network: try Self.network(), now: Self.now)
        #expect(plan.review.warnings == [.destinationIsContract])
    }

    @Test("Prioridade: teto por CU e teto da transacao, contra provedor malicioso")
    func priorityCaps() throws {
        let owner = try Self.owner()
        let greedy = try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner, to: Self.toly.base58, lamports: BigUInt(100_000_000),
                                                   destination: .system(lamports: BigUInt(1)), network: try Self.network(price: .max), now: Self.now)
        let (_, wire) = try Self.signAndCheck(greedy)
        #expect(SolanaMessageTests.decompile(wire.message)[1].data == [3] + SolanaLimits.maxComputeUnitPrice.littleEndianByteArray)
        // 2.000 CU a 10 lamports/CU = 20.000 lamports de prioridade.
        #expect(Self.line(greedy, "Taxa da rede") == "0,000025 SOL")

        // Com limite simulado alto, o preco cai para caber no teto de 0,002 SOL.
        let big = try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner, to: Self.toly.base58, lamports: BigUInt(100_000_000),
                                                destination: .system(lamports: BigUInt(1)), network: try Self.network(price: .max, simulated: 1_400_000), now: Self.now)
        let (_, bigWire) = try Self.signAndCheck(big)
        let decoded = SolanaMessageTests.decompile(bigWire.message)
        #expect(decoded[0].data == [2] + UInt32(1_400_000).littleEndianByteArray)
        #expect(decoded[1].data == [3] + UInt64(1_428_571).littleEndianByteArray)
        #expect(Self.line(big, "Inclui prioridade") == "0,002 SOL")

        // Preco zero: sem SetComputeUnitPrice.
        let free = try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner, to: Self.toly.base58, lamports: BigUInt(100_000_000),
                                                 destination: .system(lamports: BigUInt(1)), network: try Self.network(price: 0), now: Self.now)
        #expect(SolanaMessageTests.decompile(try Self.signAndCheck(free).1.message).count == 2)
        #expect(Self.line(free, "Inclui prioridade") == nil)

        for bad: UInt32 in [0, 1_400_001] {
            #expect(throws: SolanaPlanError.invalidComputeUnitLimit(bad)) {
                try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner, to: Self.toly.base58, lamports: BigUInt(100_000_000),
                                              destination: .system(lamports: BigUInt(1)), network: try Self.network(simulated: bad), now: Self.now)
            }
        }
    }

    @Test("Estado velho, blockhash vencendo, caminho nao endurecido, destino invalido, valor zero")
    func sendSOLGuards() throws {
        let owner = try Self.owner()
        func plan(_ to: String = SolanaPlannerTests.toly.base58, lamports: BigUInt = BigUInt(1_000_000), network: SolanaNetworkState? = nil,
                  owner: SolanaOwner? = nil) throws -> SigningPlan {
            try SolanaPlanner.planSendSOL(walletID: Self.wallet, owner: owner ?? (try Self.owner()), to: to, lamports: lamports,
                                          destination: .system(lamports: BigUInt(1)), network: network ?? (try Self.network()), now: Self.now)
        }
        #expect(throws: SolanaPlanError.staleNetworkState) { try plan(network: try Self.network(fetchedAt: Self.now.addingTimeInterval(-61))) }
        #expect(throws: SolanaPlanError.staleNetworkState) { try plan(network: try Self.network(fetchedAt: Self.now.addingTimeInterval(30))) }
        #expect(throws: SolanaPlanError.blockhashExpiring) { try plan(network: try Self.network(lastValid: 1_029)) }
        // 20 s depois da leitura: ~50 blocos a menos de folga.
        #expect(throws: SolanaPlanError.blockhashExpiring) {
            try plan(network: try Self.network(fetchedAt: Self.now.addingTimeInterval(-20), lastValid: 1_070))
        }
        _ = try plan(network: try Self.network(fetchedAt: Self.now.addingTimeInterval(-20), lastValid: 1_080))
        #expect(throws: SolanaPlanError.signerPathNotHardened) {
            try plan(owner: SolanaOwner(path: DerivationPath("m/44'/501'/0'/0")!, publicKey: owner.publicKey))
        }
        #expect(throws: SolanaPlanError.invalidDestination(.malformed)) { try plan("naoeendereco") }
        #expect(throws: SolanaPlanError.invalidDestination(.otherNetwork(.ethereum))) { try plan("0x9858EfFD232B4033E47d90003D41EC34EcaEda94") }
        #expect(throws: SolanaPlanError.destinationIsOwner) { try plan(owner.publicKey.base58) }
        // Programa da lista (System Program, o "endereco de queima") nunca e destino.
        #expect(throws: SolanaPlanError.destinationIsKnownProgram) { try plan("11111111111111111111111111111111") }
        #expect(throws: SolanaPlanError.destinationIsKnownProgram) { try plan(SolanaProgramID.token.base58) }
        #expect(throws: SolanaPlanError.zeroAmount) { try plan(lamports: BigUInt()) }
        #expect(throws: SolanaPlanError.amountTooLarge) { try plan(lamports: BigUInt(UInt64.max) + BigUInt(1)) }
        // Espacos colados em volta do endereco sao aceitos, como no resto da carteira.
        _ = try plan("  \(Self.toly.base58)\n")
    }

    // MARK: Token

    static func usdc(owner: SolanaOwner, amount: UInt64 = 50_000_000, frozen: Bool = false, extensions: [SolanaMintExtension] = [],
                     program: SolanaTokenProgram = .token, mint: SolanaPublicKey = usdc, verified: Bool = true, symbol: String = "USDC") throws -> SolanaTokenState {
        let source = try SolanaAssociatedToken.address(owner: owner.publicKey, mint: mint, tokenProgram: program)
        return SolanaTokenState(
            mint: mint, program: program, decimals: 6, symbol: symbol, isVerified: verified, extensions: extensions,
            source: SolanaTokenAccountState(address: source, program: program, mint: mint, owner: owner.publicKey, amount: BigUInt(amount), isFrozen: frozen),
            tokenAccountRentMinimum: BigUInt(2_039_280)
        )
    }

    static var tolyATA: SolanaTokenAccountState {
        SolanaTokenAccountState(address: tolyUSDC, program: .token, mint: usdc, owner: toly, amount: BigUInt(561_367_767), isFrozen: false)
    }

    @Test("Enviar USDC para ATA existente: so TransferChecked, conta derivada conferida")
    func sendTokenExistingATA() throws {
        let owner = try Self.owner()
        let token = try Self.usdc(owner: owner)
        let plan = try SolanaPlanner.planSendToken(
            walletID: Self.wallet, owner: owner, to: Self.toly.base58, amount: BigUInt(12_500_000), token: token,
            destination: .system(lamports: BigUInt(10)), destinationTokenAccount: .existing(Self.tolyATA), network: try Self.network(), now: Self.now
        )
        let (_, wire) = try Self.signAndCheck(plan)
        #expect(plan.review.title == "Enviar 12,5 USDC")
        #expect(Self.line(plan, "Para") == Self.toly.base58)
        #expect(Self.line(plan, "Conta de token do destino") == Self.tolyUSDC.base58)
        #expect(Self.line(plan, "Mint") == Self.usdc.base58)
        #expect(Self.line(plan, "Taxa da rede") == "0,0000065 SOL")  // 5000 + teto(50.000 * 30.000 / 1e6)
        #expect(plan.review.warnings.isEmpty)
        let instructions = SolanaMessageTests.decompile(wire.message)
        #expect(instructions.count == 3)
        #expect(instructions[2] == SolanaInstruction(programID: SolanaProgramID.token, accounts: [
            SolanaAccountMeta(token.source.address, isSigner: false, isWritable: true),
            SolanaAccountMeta(Self.usdc, isSigner: false, isWritable: false),
            SolanaAccountMeta(Self.tolyUSDC, isSigner: false, isWritable: true),
            SolanaAccountMeta(owner.publicKey, isSigner: true, isWritable: true),  // pagador: gravavel
        ], data: [12] + UInt64(12_500_000).littleEndianByteArray + [6]))
    }

    @Test("Enviar USDC para quem nao tem ATA: CreateIdempotent com o rent informado, na revisao")
    func sendTokenCreatesATA() throws {
        let owner = try Self.owner()
        let plan = try SolanaPlanner.planSendToken(
            walletID: Self.wallet, owner: owner, to: Self.toly.base58, amount: BigUInt(1_000_000), token: try Self.usdc(owner: owner),
            destination: .system(lamports: BigUInt(10)), destinationTokenAccount: .missing, network: try Self.network(), now: Self.now
        )
        let (_, wire) = try Self.signAndCheck(plan)
        #expect(Self.line(plan, "Criação da conta de token do destino") == "0,00203928 SOL")
        #expect(plan.review.warnings == [.activatesAccount(minimum: "0,00203928 SOL")])
        // 5000 + teto(50.000 * 70.000 / 1e6) = 8500; saldo 1 SOL - 8500 - 2.039.280.
        #expect(Self.line(plan, "Saldo de SOL depois") == "0,99795222 SOL")
        let instructions = SolanaMessageTests.decompile(wire.message)
        #expect(instructions.map(\.programID) == [SolanaProgramID.computeBudget, SolanaProgramID.computeBudget, SolanaProgramID.associatedToken, SolanaProgramID.token])
        #expect(instructions[0].data == [2] + UInt32(70_000).littleEndianByteArray)
        #expect(instructions[2].data == [1])
        #expect(instructions[2].accounts.map(\.publicKey) == [owner.publicKey, Self.tolyUSDC, Self.toly, Self.usdc, SolanaProgramID.system, SolanaProgramID.token])
        // Mesma forma do envio real de USDC da rede principal (fixture usdc-send-create-ata).
        let fixtures = try SolanaFixtures.load("mainnet-transactions", as: SolanaFixtures.Mainnet.self)
        let real = try SolanaWireTransaction(base64: try fixtures.transaction("usdc-send-create-ata").base64)
        #expect(SolanaMessageTests.decompile(real.message).map(\.programID) == instructions.map(\.programID))
        #expect(wire.message.header == real.message.header)

        // Sem SOL para o rent da conta nova: recusado antes de assinar.
        #expect(throws: SolanaPlanError.insufficientFunds(needed: BigUInt(2_039_280 + 8_500), available: BigUInt(2_000_000))) {
            try SolanaPlanner.planSendToken(
                walletID: Self.wallet, owner: owner, to: Self.toly.base58, amount: BigUInt(1_000_000), token: try Self.usdc(owner: owner),
                destination: .system(lamports: BigUInt(10)), destinationTokenAccount: .missing, network: try Self.network(balance: 2_000_000), now: Self.now
            )
        }
    }

    @Test("Endereco colado e uma conta de token: usa direto, nunca o ATA do ATA")
    func sendTokenToTokenAccount() throws {
        let owner = try Self.owner()
        let token = try Self.usdc(owner: owner)
        let plan = try SolanaPlanner.planSendToken(
            walletID: Self.wallet, owner: owner, to: Self.tolyUSDC.base58, amount: BigUInt(1_000_000), token: token,
            destination: .tokenAccount(Self.tolyATA), destinationTokenAccount: .missing, network: try Self.network(), now: Self.now
        )
        let (_, wire) = try Self.signAndCheck(plan)
        #expect(Self.line(plan, "Para") == Self.toly.base58)
        #expect(Self.line(plan, "Conta de token digitada") == Self.tolyUSDC.base58)
        let transfer = try #require(SolanaMessageTests.decompile(wire.message).last)
        #expect(transfer.accounts[2].publicKey == Self.tolyUSDC)
        #expect(!SolanaMessageTests.decompile(wire.message).contains { $0.programID == SolanaProgramID.associatedToken })

        let otherMint = SolanaTokenAccountState(address: Self.tolyUSDC, program: .token, mint: Self.pyusd, owner: Self.toly, amount: BigUInt(1), isFrozen: false)
        #expect(throws: SolanaPlanError.tokenAccountMismatch) {
            try SolanaPlanner.planSendToken(walletID: Self.wallet, owner: owner, to: Self.tolyUSDC.base58, amount: BigUInt(1), token: token,
                                            destination: .tokenAccount(otherMint), destinationTokenAccount: .missing, network: try Self.network(), now: Self.now)
        }
        let frozen = SolanaTokenAccountState(address: Self.tolyUSDC, program: .token, mint: Self.usdc, owner: Self.toly, amount: BigUInt(1), isFrozen: true)
        #expect(throws: SolanaPlanError.tokenAccountFrozen) {
            try SolanaPlanner.planSendToken(walletID: Self.wallet, owner: owner, to: Self.tolyUSDC.base58, amount: BigUInt(1), token: token,
                                            destination: .tokenAccount(frozen), destinationTokenAccount: .missing, network: try Self.network(), now: Self.now)
        }
        // O mesmo ATA, mas a rede diz que o endereco ainda nao existe: esta fora da
        // curva, e sem confirmacao do dono a carteira nao deriva o ATA dele.
        #expect(throws: SolanaPlanError.destinationOffCurve) {
            try SolanaPlanner.planSendToken(walletID: Self.wallet, owner: owner, to: Self.tolyUSDC.base58, amount: BigUInt(1), token: token,
                                            destination: .nonexistent, destinationTokenAccount: .missing, network: try Self.network(), now: Self.now)
        }
        // Colar o endereco do proprio mint (USDC para o contrato do USDC).
        #expect(throws: SolanaPlanError.destinationIsMint) {
            try SolanaPlanner.planSendToken(walletID: Self.wallet, owner: owner, to: Self.usdc.base58, amount: BigUInt(1), token: token,
                                            destination: .programOwned(owner: SolanaProgramID.token), destinationTokenAccount: .missing, network: try Self.network(), now: Self.now)
        }
        #expect(throws: SolanaPlanError.destinationOwnedByProgram(SolanaProgramID.system)) {
            try SolanaPlanner.planSendToken(walletID: Self.wallet, owner: owner, to: Self.toly.base58, amount: BigUInt(1), token: token,
                                            destination: .programOwned(owner: SolanaProgramID.system), destinationTokenAccount: .missing, network: try Self.network(), now: Self.now)
        }
    }

    @Test("Cofre fora da curva com confirmacao explicita: ATA derivado com aviso")
    func sendTokenToVault() throws {
        let owner = try Self.owner()
        // Dono PDA real da fixture de ATA Token-2022 (PYUSD).
        let vault = try SolanaPublicKey(base58: "ARu4n5mFdZogZAravu7CcizaojWnS6oqka37gdLT5SZn")
        let token = try Self.usdc(owner: owner, program: .token2022, mint: Self.pyusd, symbol: "PYUSD")
        let plan = try SolanaPlanner.planSendToken(
            walletID: Self.wallet, owner: owner, to: vault.base58, amount: BigUInt(1_000_000), token: token,
            destination: .system(lamports: BigUInt(1)), destinationTokenAccount: .missing, allowOffCurveOwner: true,
            network: try Self.network(), now: Self.now
        )
        #expect(Self.line(plan, "Conta de token do destino") == "UoC1nnbTTENjJumPn5AQz15A1HLU9Qg7GKv4RCmqdC3")
        #expect(plan.review.warnings.contains(.destinationIsContract))
        let (_, wire) = try Self.signAndCheck(plan)
        #expect(SolanaMessageTests.decompile(wire.message).last?.programID == SolanaProgramID.token2022)
    }

    @Test("Token-2022: recusa PermanentDelegate, TransferHook, NonTransferable, pausa e extensao desconhecida")
    func token2022Refusals() throws {
        let owner = try Self.owner()
        let cases: [(SolanaMintExtension, SolanaPlanError)] = [
            (.permanentDelegate, .permanentDelegate),
            (.transferHook, .transferHook),
            (.nonTransferable, .nonTransferable),
            (.paused, .tokenPaused),
            (.unknown("confidentialMintBurn"), .unknownMintExtension("confidentialMintBurn")),
        ]
        for (ext, error) in cases {
            let token = try Self.usdc(owner: owner, extensions: [ext], program: .token2022, mint: Self.pyusd, symbol: "PYUSD")
            #expect(throws: error) {
                try SolanaPlanner.planSendToken(walletID: Self.wallet, owner: owner, to: Self.toly.base58, amount: BigUInt(1), token: token,
                                                destination: .system(lamports: BigUInt(1)), destinationTokenAccount: .missing, network: try Self.network(), now: Self.now)
            }
        }
        // Conta nova nasceria congelada: a transferencia falharia. Conta existente (ja
        // descongelada pelo emissor) passa.
        let frozenDefault = try Self.usdc(owner: owner, extensions: [.defaultAccountStateFrozen], program: .token2022, mint: Self.pyusd, symbol: "PYUSD")
        #expect(throws: SolanaPlanError.defaultAccountStateFrozen) {
            try SolanaPlanner.planSendToken(walletID: Self.wallet, owner: owner, to: Self.toly.base58, amount: BigUInt(1), token: frozenDefault,
                                            destination: .system(lamports: BigUInt(1)), destinationTokenAccount: .missing, network: try Self.network(), now: Self.now)
        }
        let recipient = try SolanaPublicKey(base58: "Fe3yJKWb3JET3HVfifNZxR9P1FLfj9dRwKJ6TZdkwqKR")
        let existing = SolanaTokenAccountState(address: try SolanaPublicKey(base58: "7K1wMJyKCtehdt5MJjVdUzugpugcro8ZJ15xAJq6rxAx"),
                                               program: .token2022, mint: Self.pyusd, owner: recipient, amount: BigUInt(), isFrozen: false)
        _ = try Self.signAndCheck(try SolanaPlanner.planSendToken(
            walletID: Self.wallet, owner: owner, to: recipient.base58, amount: BigUInt(1), token: frozenDefault,
            destination: .system(lamports: BigUInt(1)), destinationTokenAccount: .existing(existing), network: try Self.network(), now: Self.now
        ))
    }

    @Test("Token-2022 com taxa do emissor: aviso e valor liquido na revisao")
    func transferFeeWarning() throws {
        let owner = try Self.owner()
        let token = try Self.usdc(owner: owner, extensions: [.transferFee(basisPoints: 150, maximumFee: BigUInt(1_000_000))],
                                  program: .token2022, mint: Self.pyusd, symbol: "PYUSD")
        let plan = try SolanaPlanner.planSendToken(
            walletID: Self.wallet, owner: owner, to: Self.toly.base58, amount: BigUInt(10_000_000), token: token,
            destination: .system(lamports: BigUInt(1)), destinationTokenAccount: .missing, network: try Self.network(), now: Self.now
        )
        #expect(Self.line(plan, "Taxa do emissor do token") == "0,15 PYUSD")
        #expect(Self.line(plan, "O destino recebe") == "9,85 PYUSD")
        #expect(plan.review.warnings.contains(.highFee(percentOfAmount: 1.5)))
        _ = try Self.signAndCheck(plan)
    }

    @Test("Taxa do emissor: vetores do token-2022 (interface/src/extension/transfer_fee/mod.rs)")
    func issuerFeeVectors() {
        let one: UInt64 = 10_000
        let max = BigUInt(5_000)
        // calculate_fee_max (1 bp, maximo 5.000)
        for amount in [UInt64.max, 5_000 * one, 5_000 * one + 1, 5_000 * one - 1] {
            #expect(SolanaPlanner.issuerFee(amount: BigUInt(amount), basisPoints: 1, maximum: max) == max)
        }
        // calculate_fee_min
        #expect(SolanaPlanner.issuerFee(amount: BigUInt(1), basisPoints: 1, maximum: max) == BigUInt(1))
        #expect(SolanaPlanner.issuerFee(amount: BigUInt(2), basisPoints: 1, maximum: max) == BigUInt(1))
        #expect(SolanaPlanner.issuerFee(amount: BigUInt(one), basisPoints: 1, maximum: max) == BigUInt(1))
        #expect(SolanaPlanner.issuerFee(amount: BigUInt(one + 1), basisPoints: 1, maximum: max) == BigUInt(2))
        #expect(SolanaPlanner.issuerFee(amount: BigUInt(), basisPoints: 1, maximum: max) == BigUInt())
        // calculate_fee_zero
        for amount in [0, UInt64.max, 1, one] {
            #expect(SolanaPlanner.issuerFee(amount: BigUInt(amount), basisPoints: 0, maximum: BigUInt(UInt64.max)) == BigUInt())
            #expect(SolanaPlanner.issuerFee(amount: BigUInt(amount), basisPoints: 10_000, maximum: BigUInt()) == BigUInt())
        }
    }

    @Test("Conta de origem: ATA do dono, mesmo mint, saldo suficiente, nao congelada")
    func sourceChecks() throws {
        let owner = try Self.owner()
        func plan(_ token: SolanaTokenState, amount: UInt64 = 1_000) throws -> SigningPlan {
            try SolanaPlanner.planSendToken(walletID: Self.wallet, owner: owner, to: Self.toly.base58, amount: BigUInt(amount), token: token,
                                            destination: .system(lamports: BigUInt(1)), destinationTokenAccount: .existing(Self.tolyATA), network: try Self.network(), now: Self.now)
        }
        #expect(throws: SolanaPlanError.insufficientTokenBalance(needed: BigUInt(50_000_001), available: BigUInt(50_000_000))) {
            try plan(try Self.usdc(owner: owner), amount: 50_000_001)
        }
        #expect(throws: SolanaPlanError.tokenAccountFrozen) { try plan(try Self.usdc(owner: owner, frozen: true)) }
        let good = try Self.usdc(owner: owner)
        let wrongAddress = SolanaTokenState(
            mint: good.mint, program: good.program, decimals: good.decimals, symbol: good.symbol, isVerified: true, extensions: [],
            source: SolanaTokenAccountState(address: Self.tolyUSDC, program: .token, mint: Self.usdc, owner: owner.publicKey, amount: BigUInt(9_999), isFrozen: false),
            tokenAccountRentMinimum: good.tokenAccountRentMinimum
        )
        #expect(throws: SolanaPlanError.tokenAccountMismatch) { try plan(wrongAddress) }
        // Programa do mint trocado: o ATA derivado muda, e a origem informada nao bate.
        let wrongProgram = SolanaTokenState(
            mint: good.mint, program: .token2022, decimals: good.decimals, symbol: good.symbol, isVerified: true, extensions: [],
            source: good.source, tokenAccountRentMinimum: good.tokenAccountRentMinimum
        )
        #expect(throws: SolanaPlanError.tokenAccountMismatch) { try plan(wrongProgram) }
        // ATA do destino informado com outro dono.
        let impostor = SolanaTokenAccountState(address: Self.tolyUSDC, program: .token, mint: Self.usdc, owner: owner.publicKey, amount: BigUInt(), isFrozen: false)
        #expect(throws: SolanaPlanError.tokenAccountMismatch) {
            try SolanaPlanner.planSendToken(walletID: Self.wallet, owner: owner, to: Self.toly.base58, amount: BigUInt(1), token: good,
                                            destination: .system(lamports: BigUInt(1)), destinationTokenAccount: .existing(impostor), network: try Self.network(), now: Self.now)
        }
        // Mint fora da lista curada: passa, com aviso.
        let unverified = try Self.usdc(owner: owner, verified: false, symbol: "USDC")
        #expect(try plan(unverified).review.warnings == [.unverifiedToken(symbol: "USDC")])
    }

    @Test("Texto dos valores: virgula decimal, sem arredondar")
    func amountText() {
        #expect(SolanaAmountText.sol(BigUInt(1_500_000_000)) == "1,5 SOL")
        #expect(SolanaAmountText.sol(BigUInt(5_000)) == "0,000005 SOL")
        #expect(SolanaAmountText.sol(BigUInt(1)) == "0,000000001 SOL")
        #expect(SolanaAmountText.sol(BigUInt()) == "0 SOL")
        #expect(SolanaAmountText.format(BigUInt(10_000_000), decimals: 6, symbol: "USDC") == "10 USDC")
        #expect(SolanaAmountText.format(BigUInt(42), decimals: 0, symbol: "NFT") == "42 NFT")
        #expect(SolanaAmountText.format(BigUInt(UInt64.max), decimals: 9, symbol: "SOL") == "18.446.744.073,709551615 SOL")
        #expect(SolanaAmountText.format(BigUInt(1_250_000_000), decimals: 6, symbol: "USDC") == "1.250 USDC")
        #expect(SolanaAmountText.format(BigUInt(123_456), decimals: 0, symbol: "X") == "123.456 X")
        #expect(SolanaAmountText.format(BigUInt(999), decimals: 0, symbol: "X") == "999 X")
    }
}
