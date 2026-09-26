import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// O verificador de mensagem: aceita o que so movimenta o que o dono quis, recusa o
/// resto. Conferido em transacoes reais da Jupiter v6 (com ALTs) e em mensagens
/// montadas aqui com cada instrucao perigosa.
@Suite("Solana: verificador de mensagem")
struct SolanaVerifierTests {
    static let owner = try! SolanaPublicKey(bytes: [0x11] + [UInt8](repeating: 0x21, count: 31))
    static let stranger = try! SolanaPublicKey(bytes: [0x33] + [UInt8](repeating: 0x44, count: 31))
    static let tokenAccount = try! SolanaPublicKey(bytes: [0x55] + [UInt8](repeating: 0x66, count: 31))
    static let memo = try! SolanaPublicKey(base58: "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr")
    static let blockhash = try! SolanaBlockhash(bytes: [UInt8](repeating: 0x77, count: 32))
    static let all = Set(SolanaProgram.allCases)

    static func message(_ instructions: [SolanaInstruction], payer: SolanaPublicKey = owner) throws -> SolanaMessage {
        try SolanaMessage.compileLegacy(payer: payer, instructions: instructions, recentBlockhash: blockhash)
    }

    static func verify(_ instructions: [SolanaInstruction], recipients: Set<SolanaPublicKey> = [], programs: Set<SolanaProgram> = Set(SolanaProgram.allCases)) throws -> SolanaVerifiedMessage {
        try SolanaMessageVerifier.verify(try message(instructions), policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: programs, allowedRecipients: recipients))
    }

    static func token(_ data: [UInt8], _ accounts: [SolanaAccountMeta], program: SolanaTokenProgram = .token) -> SolanaInstruction {
        SolanaInstruction(programID: program.programID, accounts: accounts, data: data)
    }

    static func w(_ key: SolanaPublicKey) -> SolanaAccountMeta { SolanaAccountMeta(key, isSigner: false, isWritable: true) }
    static func r(_ key: SolanaPublicKey) -> SolanaAccountMeta { SolanaAccountMeta(key, isSigner: false, isWritable: false) }
    static var signer: SolanaAccountMeta { SolanaAccountMeta(owner, isSigner: true, isWritable: false) }

    // MARK: Transacoes reais

    static func mainnet(_ name: String) throws -> (SolanaMessage, [SolanaAddressLookupTable]) {
        let fixtures = try SolanaFixtures.load("mainnet-transactions", as: SolanaFixtures.Mainnet.self)
        let wire = try SolanaWireTransaction(base64: try fixtures.transaction(name).base64)
        return (wire.message, try fixtures.tables())
    }

    @Test("Jupiter v6 real (ALTs, CreateIdempotent, rota, CloseAccount para o dono): aceita")
    func jupiterSwapAccepted() throws {
        let (message, tables) = try Self.mainnet("jupiter-swap-unwrap")
        let owner = try SolanaFixtures.key("64hqS9kpwvbWtbL6Dhi9cj7PiYCrio68vAMG4j5qkGMn")
        let verified = try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: Self.all), lookupTables: tables)
        #expect(verified.computeUnitLimit == 115_338)
        #expect(verified.computeUnitPrice == 56_710)
        // teto(115338 * 56710 / 1e6) = teto(6540,81798)
        #expect(verified.maxPriorityFee == BigUInt(6_541))
        #expect(verified.actions.count == 5)
        guard case .jupiter = verified.actions[3] else { Issue.record("rota da Jupiter nao reconhecida"); return }
        #expect(verified.actions[4] == .closeTokenAccount(
            program: .token, account: try SolanaFixtures.key("9NFrMc3EXxdy1URxVpfp6VGE8XzWSHpTQmWCTxUTW1cq"), destination: owner
        ))

        // Sem a Jupiter no subconjunto pedido, o mesmo swap e recusado.
        #expect(throws: SolanaVerificationError.programNotAllowed(SolanaProgramID.jupiterV6)) {
            try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: [.computeBudget, .associatedToken, .token]), lookupTables: tables)
        }
        // Outra carteira nao pode assinar como pagadora desta mensagem.
        #expect(throws: SolanaVerificationError.feePayerNotOwner(owner)) {
            try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: Self.owner, allowedPrograms: Self.all), lookupTables: tables)
        }
        // Sem o conteudo das tabelas nao ha como saber que contas a mensagem toca.
        #expect(throws: SolanaVerificationError.self) {
            try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: Self.all))
        }
    }

    @Test("Jupiter real que embrulha SOL: Transfer so passa para o ATA de wSOL do proprio dono")
    func jupiterWrapSOL() throws {
        let (message, tables) = try Self.mainnet("jupiter-swap-wrap-sol")
        let owner = try SolanaFixtures.key("8953xsCX2M5unADjuTGruB2qBjhehVLSrw7Y1kAAwMQr")
        let wsol = try SolanaAssociatedToken.address(
            owner: owner, mint: try SolanaFixtures.key("So11111111111111111111111111111111111111112"), tokenProgram: .token
        )
        #expect(wsol.base58 == "3DhrX33GF5nc4oc4rUgXwLep9o3sDgTPfvCoeXDkuKAf")
        #expect(throws: SolanaVerificationError.transferToUnknown(wsol)) {
            try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: Self.all), lookupTables: tables)
        }
        let verified = try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: Self.all, allowedRecipients: [wsol]), lookupTables: tables)
        #expect(verified.actions.contains(.transferSOL(from: owner, to: wsol, lamports: 5_000_000_000)))
        #expect(verified.actions.contains(.syncNative(program: .token, account: wsol)))
    }

    @Test("Jupiter real com transferencia de token a terceiro e Memo: recusa as duas")
    func jupiterWithMemo() throws {
        let (message, tables) = try Self.mainnet("jupiter-swap-memo")
        let owner = try SolanaFixtures.key("77777nPhGvFUVAj6uq8MGyLneBt4SMwCScYZDzzztdsa")
        let destination = try SolanaFixtures.key("WnMhmqDqhsVDBVy4uFMMfS2K46LHoUwCgo5qAfP5u1K")
        #expect(throws: SolanaVerificationError.transferToUnknown(destination)) {
            try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: Self.all), lookupTables: tables)
        }
        #expect(throws: SolanaVerificationError.programNotAllowed(Self.memo)) {
            try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: Self.all, allowedRecipients: [destination]), lookupTables: tables)
        }
    }

    @Test("Jupiter real com dois signatarios: recusa")
    func twoSigners() throws {
        let (message, tables) = try Self.mainnet("jupiter-two-signers")
        let owner = try SolanaFixtures.key("AHtMkeTqYx1R27kNFBgbg4WguGo9jCuLDPVgPK9sPFh8")
        #expect(throws: SolanaVerificationError.unexpectedSigners(2)) {
            try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: Self.all), lookupTables: tables)
        }
    }

    @Test("Jupiter real com gorjeta em SOL para terceiro: recusa")
    func tipToStranger() throws {
        let (message, tables) = try Self.mainnet("jupiter-swap-tip")
        let owner = try SolanaFixtures.key("DmQSnFzRoENh3weu6EtBBhHTpQBQSsvjpMX8iYKRygQ4")
        #expect(throws: SolanaVerificationError.transferToUnknown(try SolanaFixtures.key("DttWaMuVvTiduZRnguLF7jNxTgiMBZ1hyAumKUiL2KRL"))) {
            try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: Self.all), lookupTables: tables)
        }
    }

    @Test("Envio real de USDC: aceito so com o ATA do destino na lista")
    func usdcSend() throws {
        let (message, _) = try Self.mainnet("usdc-send-create-ata")
        let owner = try SolanaFixtures.key("8psAwG4hjPMuxvNC5f2szDCNYW9Sjixv9RSP3rdx8SKF")
        let destination = try SolanaFixtures.key("9SHQTA66Ekh7ZgMnKWsjxXk6DwXku8przs45E8bcEe38")
        let policy = SolanaVerificationPolicy(owner: owner, allowedPrograms: [.computeBudget, .token, .associatedToken], allowedRecipients: [destination])
        let verified = try SolanaMessageVerifier.verify(message, policy: policy)
        #expect(verified.actions.last == .transferToken(
            program: .token, source: try SolanaAssociatedToken.address(owner: owner, mint: try SolanaFixtures.key("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"), tokenProgram: .token),
            mint: try SolanaFixtures.key("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"), destination: destination, authority: owner, amount: 100, decimals: 6
        ))
        // Sem o destino na lista, ja a criacao do ATA de outra carteira e recusada.
        #expect(throws: SolanaVerificationError.createsAccountForStranger(try SolanaFixtures.key("86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY"))) {
            try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: owner, allowedPrograms: Self.all))
        }
    }

    // MARK: Instrucoes perigosas

    @Test("SPL Token: SetAuthority, Approve, ApproveChecked sao recusados (Token e Token-2022)")
    func authorityAndDelegate() throws {
        for program in SolanaTokenProgram.allCases {
            #expect(throws: SolanaVerificationError.setAuthority) {
                try Self.verify([Self.token([6, 2, 1] + Self.stranger.bytes, [Self.w(Self.tokenAccount), Self.signer], program: program)])
            }
            #expect(throws: SolanaVerificationError.approveDelegate) {
                try Self.verify([Self.token([4] + UInt64.max.littleEndianByteArray, [Self.w(Self.tokenAccount), Self.r(Self.stranger), Self.signer], program: program)])
            }
            #expect(throws: SolanaVerificationError.approveDelegate) {
                try Self.verify([Self.token([13] + UInt64(1).littleEndianByteArray + [6], [Self.w(Self.tokenAccount), Self.r(Self.stranger), Self.r(Self.stranger), Self.signer], program: program)])
            }
        }
    }

    @Test("CloseAccount: so com destino = dono")
    func closeAccount() throws {
        #expect(throws: SolanaVerificationError.closeAccountToStranger(Self.stranger)) {
            try Self.verify([Self.token([9], [Self.w(Self.tokenAccount), Self.w(Self.stranger), Self.signer])])
        }
        let ok = try Self.verify([Self.token([9], [Self.w(Self.tokenAccount), Self.w(Self.owner), Self.signer])])
        #expect(ok.actions == [.closeTokenAccount(program: .token, account: Self.tokenAccount, destination: Self.owner)])
    }

    @Test("AdvanceNonceAccount: recusado como primeira instrucao e em qualquer outra posicao")
    func durableNonce() throws {
        let nonce = SolanaInstruction(programID: SolanaProgramID.system, accounts: [
            Self.w(Self.stranger), Self.r(try SolanaFixtures.key("SysvarRecentB1ockHashes11111111111111111111")), Self.signer,
        ], data: [4, 0, 0, 0])
        let transfer = SolanaSystemInstruction.transfer(from: Self.owner, to: Self.stranger, lamports: 1)
        #expect(throws: SolanaVerificationError.durableNonceFirstInstruction) {
            try Self.verify([nonce, transfer], recipients: [Self.stranger])
        }
        #expect(throws: SolanaVerificationError.durableNonce) {
            try Self.verify([transfer, nonce], recipients: [Self.stranger])
        }
    }

    @Test("System: Assign na conta do dono e CreateAccount sao recusados; Transfer so para destino aceito")
    func systemProgram() throws {
        let assign = SolanaInstruction(programID: SolanaProgramID.system, accounts: [SolanaAccountMeta(Self.owner, isSigner: true, isWritable: true)],
                                       data: [1, 0, 0, 0] + Self.stranger.bytes)
        #expect(throws: SolanaVerificationError.assignAccount(Self.owner)) { try Self.verify([assign]) }
        let create = SolanaInstruction(programID: SolanaProgramID.system, accounts: [SolanaAccountMeta(Self.owner, isSigner: true, isWritable: true), Self.w(Self.stranger)],
                                       data: [0, 0, 0, 0] + [UInt8](repeating: 0, count: 48))
        #expect(throws: SolanaVerificationError.forbiddenInstruction(.system, discriminator: 0)) { try Self.verify([create]) }
        let transfer = SolanaSystemInstruction.transfer(from: Self.owner, to: Self.stranger, lamports: 42)
        #expect(throws: SolanaVerificationError.transferToUnknown(Self.stranger)) { try Self.verify([transfer]) }
        #expect(try Self.verify([transfer], recipients: [Self.stranger]).actions == [.transferSOL(from: Self.owner, to: Self.stranger, lamports: 42)])
        let short = SolanaInstruction(programID: SolanaProgramID.system, accounts: [SolanaAccountMeta(Self.owner, isSigner: true, isWritable: true), Self.w(Self.stranger)], data: [2, 0, 0, 0, 1])
        #expect(throws: SolanaVerificationError.malformedInstruction(.system)) { try Self.verify([short], recipients: [Self.stranger]) }
    }

    @Test("Programa fora da lista, ou fora do subconjunto pedido, e recusado")
    func programAllowlist() throws {
        #expect(throws: SolanaVerificationError.programNotAllowed(Self.memo)) {
            try Self.verify([SolanaInstruction(programID: Self.memo, accounts: [], data: Array("oi".utf8))])
        }
        let transfer = SolanaSystemInstruction.transfer(from: Self.owner, to: Self.stranger, lamports: 1)
        #expect(throws: SolanaVerificationError.programNotAllowed(SolanaProgramID.system)) {
            try Self.verify([transfer], recipients: [Self.stranger], programs: [.computeBudget, .token])
        }
        // A lista e compilada: os seis programas, e nada alem deles.
        #expect(SolanaProgram.allCases.map(\.id.base58) == [
            "ComputeBudget111111111111111111111111111111", "11111111111111111111111111111111",
            "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA", "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",
            "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL", "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4",
        ])
    }

    @Test("Pagador diferente do dono e signatario extra sao recusados")
    func feePayerAndSigners() throws {
        let transfer = SolanaSystemInstruction.transfer(from: Self.stranger, to: Self.owner, lamports: 1)
        let message = try Self.message([transfer], payer: Self.stranger)
        #expect(throws: SolanaVerificationError.feePayerNotOwner(Self.stranger)) {
            try SolanaMessageVerifier.verify(message, policy: SolanaVerificationPolicy(owner: Self.owner, allowedPrograms: Self.all, allowedRecipients: [Self.owner]))
        }
        let coSigned = SolanaSystemInstruction.transfer(from: Self.stranger, to: Self.owner, lamports: 1)
        #expect(throws: SolanaVerificationError.unexpectedSigners(2)) { try Self.verify([coSigned], recipients: [Self.owner]) }
    }

    @Test("Compute Budget: teto de prioridade (preco x limite), pior caso sem limite, duplicata e formato")
    func computeBudget() throws {
        let limit = SolanaComputeBudgetInstruction.setComputeUnitLimit(200_000)
        // 200.000 CU a 10 lamports/CU = 2.000.000 lamports: exatamente o teto.
        _ = try Self.verify([limit, SolanaComputeBudgetInstruction.setComputeUnitPrice(microLamports: 10_000_000)])
        #expect(throws: SolanaVerificationError.priorityFeeAboveCap(fee: BigUInt(2_000_001), cap: 2_000_000)) {
            try Self.verify([limit, SolanaComputeBudgetInstruction.setComputeUnitPrice(microLamports: 10_000_005)])
        }
        // Sem limite, vale o maximo de 1.400.000 CU.
        #expect(throws: SolanaVerificationError.priorityFeeAboveCap(fee: BigUInt(2_800_000), cap: 2_000_000)) {
            try Self.verify([SolanaComputeBudgetInstruction.setComputeUnitPrice(microLamports: 2_000_000)])
        }
        // Preco no maximo de u64: a conta nao estoura (BigUInt) e e recusada.
        #expect(throws: SolanaVerificationError.priorityFeeAboveCap(fee: BigUInt(decimal: "25825441703193372261")!, cap: 2_000_000)) {
            try Self.verify([SolanaComputeBudgetInstruction.setComputeUnitPrice(microLamports: UInt64.max)])
        }
        // Limite declarado acima de 1.400.000 vale 1.400.000, como no validador.
        let huge = SolanaComputeBudgetInstruction.setComputeUnitLimit(.max)
        #expect(try Self.verify([huge, SolanaComputeBudgetInstruction.setComputeUnitPrice(microLamports: 1_000)]).maxPriorityFee == BigUInt(1_400))
        #expect(throws: SolanaVerificationError.duplicateComputeBudget) { try Self.verify([limit, limit]) }
        #expect(throws: SolanaVerificationError.forbiddenInstruction(.computeBudget, discriminator: 0)) {
            try Self.verify([SolanaInstruction(programID: SolanaProgramID.computeBudget, accounts: [], data: [0, 0, 0, 0, 0])])
        }
        #expect(throws: SolanaVerificationError.malformedInstruction(.computeBudget)) {
            try Self.verify([SolanaInstruction(programID: SolanaProgramID.computeBudget, accounts: [], data: [2, 0, 0])])
        }
        // A politica nunca aceita teto acima do compilado.
        #expect(SolanaVerificationPolicy(owner: Self.owner, allowedPrograms: Self.all, maxPriorityFeeLamports: .max).maxPriorityFeeLamports == SolanaLimits.maxPriorityFeeLamports)
    }

    @Test("Token e ATA: so a lista curta de instrucoes")
    func tokenAllowlist() throws {
        for program in SolanaTokenProgram.allCases {
            let which: SolanaProgram = program == .token ? .token : .token2022
            // MintTo, Burn, FreezeAccount, InitializeAccount3.
            for tag: UInt8 in [7, 8, 10, 18] {
                #expect(throws: SolanaVerificationError.forbiddenInstruction(which, discriminator: UInt32(tag))) {
                    try Self.verify([Self.token([tag] + UInt64(1).littleEndianByteArray, [Self.w(Self.tokenAccount), Self.w(Self.stranger), Self.signer], program: program)])
                }
            }
            let revoke = try Self.verify([Self.token([5], [Self.w(Self.tokenAccount), Self.signer], program: program)])
            #expect(revoke.actions == [.revokeDelegate(program: program, account: Self.tokenAccount)])
        }
        let mint = try SolanaFixtures.key("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
        let create = SolanaAssociatedTokenInstruction.createIdempotent(payer: Self.owner, associatedAccount: Self.tokenAccount, owner: Self.stranger, mint: mint, tokenProgram: .token)
        // Conta de token para terceiro: so se for o destino aceito (o rent sai do dono).
        #expect(throws: SolanaVerificationError.createsAccountForStranger(Self.stranger)) { try Self.verify([create]) }
        let accepted = try Self.verify([create], recipients: [Self.tokenAccount])
        #expect(accepted.actions == [.createAssociatedTokenAccount(idempotent: true, payer: Self.owner, account: Self.tokenAccount, owner: Self.stranger, mint: mint, tokenProgram: SolanaProgramID.token)])
        let own = SolanaAssociatedTokenInstruction.createIdempotent(payer: Self.owner, associatedAccount: Self.tokenAccount, owner: Self.owner, mint: mint, tokenProgram: .token2022)
        #expect(try Self.verify([own]).actions == [.createAssociatedTokenAccount(idempotent: true, payer: Self.owner, account: Self.tokenAccount, owner: Self.owner, mint: mint, tokenProgram: SolanaProgramID.token2022)])
        let recoverNested = SolanaInstruction(programID: SolanaProgramID.associatedToken, accounts: create.accounts, data: [2])
        #expect(throws: SolanaVerificationError.forbiddenInstruction(.associatedToken, discriminator: 2)) { try Self.verify([recoverNested]) }
    }
}
