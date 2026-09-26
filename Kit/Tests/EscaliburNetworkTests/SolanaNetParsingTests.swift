import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Respostas reais dos RPCs publicos, gravadas em 26/09/2026 (FixturesSolana/).
/// Contas: toly.sol (86xC...), o ATA de USDC dele (9SHQ...), os mints de USDC e
/// PYUSD, o programa da Jupiter, um endereco vazio e uma tabela de enderecos usada
/// pela Jupiter (CdAS...). Simulacoes: a troca SOL -> USDC montada pelo planejador
/// para toly.sol e uma transferencia impossivel. Envio: uma transacao assinada por
/// chave descartavel sem saldo, recusada no preflight.
enum SolanaNetFixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "FixturesSolana"))
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ name: String, method: String = "fixture", as type: T.Type = T.self) throws -> T {
        try SolanaRPC.decode(try data(name), method: method, as: T.self)
    }

    static let toly = try! SolanaPublicKey(base58: "86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY")
    static let tolyUSDC = try! SolanaPublicKey(base58: "9SHQTA66Ekh7ZgMnKWsjxXk6DwXku8przs45E8bcEe38")
    static let usdc = try! SolanaPublicKey(base58: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
    static let pyusd = try! SolanaPublicKey(base58: "2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo")
}

private typealias N = SolanaNetFixtures

@Suite("Solana rede: contas vigiadas na troca")
struct SolanaNetGuardedTests {
    @Test("Regressao A2: os ATAs do dono nos mints da lista, fora os dois lados da troca")
    func guardedAccounts() throws {
        // O ATA de USDC de toly.sol e o gravado (9SHQ...): a derivacao e a do Token classico.
        let all = SolanaNetworkReader.guardedAccounts(owner: N.toly, excluding: [])
        #expect(all.contains(N.tolyUSDC))
        #expect(all.count == TokenRegistry.tokens.filter { $0.chainID == Chain.solana.id }.count)
        let withoutUSDC = SolanaNetworkReader.guardedAccounts(owner: N.toly, excluding: [N.usdc])
        #expect(!withoutUSDC.contains(N.tolyUSDC) && withoutUSDC.count == all.count - 1)
    }
}

@Suite("Solana rede: leitura de contas")
struct SolanaNetAccountTests {
    func account(_ name: String) throws -> RPCAccount? {
        try N.decode(name, as: RPCContextualOptional<RPCAccount>.self).value
    }

    @Test("Destino: carteira com lamports exatos (u64, sem passar por Double)")
    func system() throws {
        let destination = try SolanaAccountParser.destination(try account("account-system"), address: N.toly)
        #expect(destination == .system(lamports: BigUInt(1_328_297_670_391)))
    }

    @Test("Destino: conta de token colada, com mint, dono e saldo")
    func tokenAccount() throws {
        let destination = try SolanaAccountParser.destination(try account("account-token"), address: N.tolyUSDC)
        guard case .tokenAccount(let state) = destination else { Issue.record("esperava conta de token"); return }
        #expect(state.mint == N.usdc && state.owner == N.toly && state.program == .token)
        #expect(state.amount == BigUInt(561_367_767) && !state.isFrozen)
    }

    @Test("Destino: programa, mint (nao e conta de token) e endereco nunca usado")
    func others() throws {
        #expect(try SolanaAccountParser.destination(try account("account-program"), address: SolanaProgramID.jupiterV6)
                == .programOwned(owner: try SolanaPublicKey(base58: "BPFLoaderUpgradeab1e11111111111111111111111")))
        #expect(try SolanaAccountParser.destination(try account("account-mint-usdc"), address: N.usdc) == .programOwned(owner: SolanaProgramID.token))
        #expect(try SolanaAccountParser.destination(try account("account-null"), address: N.toly) == .nonexistent)
    }

    @Test("Mint do Token: casas, sem extensoes, conta de 165 bytes")
    func usdcMint() throws {
        let mint = try SolanaAccountParser.mint(fromResponse: try N.data("account-mint-usdc"), address: N.usdc)
        #expect(mint.program == .token && mint.decimals == 6 && mint.extensions.isEmpty && mint.tokenAccountSize == 165)
    }

    @Test("Mint do Token-2022 (PYUSD): delegado permanente; hook sem programa e taxa zero nao contam; ATA de 187 bytes")
    func pyusdMint() throws {
        let mint = try SolanaAccountParser.mint(fromResponse: try N.data("account-mint-pyusd"), address: N.pyusd)
        #expect(mint.program == .token2022 && mint.decimals == 6)
        #expect(mint.extensions == [.permanentDelegate])
        #expect(mint.extensionNames.contains("transferHook") && mint.extensionNames.contains("confidentialTransferMint"))
        // Conferido na cadeia: os ATAs de PYUSD tem 187 bytes (immutableOwner, transferFeeAmount, transferHookAccount).
        #expect(mint.tokenAccountSize == 187)
        #expect(throws: SolanaAccountParseError.notAMint(owner: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")) {
            try SolanaAccountParser.mint(fromResponse: try N.data("account-token"), address: N.tolyUSDC)
        }
    }

    @Test("Extensoes: taxa com u64 exato, delegado, hook, congelado, pausado, desconhecida")
    func extensions() throws {
        let json = #"""
        {"jsonrpc":"2.0","id":1,"result":{"context":{"slot":1},"value":{"owner":"TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb","lamports":1,"executable":false,"data":{"program":"spl-token-2022","space":300,"parsed":{"type":"mint","info":{"decimals":9,"extensions":[
          {"extension":"transferFeeConfig","state":{"newerTransferFee":{"epoch":900,"maximumFee":18446744073709551615,"transferFeeBasisPoints":250},"olderTransferFee":{"epoch":800,"maximumFee":5,"transferFeeBasisPoints":100}}},
          {"extension":"permanentDelegate","state":{"delegate":null}},
          {"extension":"transferHook","state":{"authority":null,"programId":"HooK111111111111111111111111111111111111111"}},
          {"extension":"defaultAccountState","state":{"accountState":"frozen"}},
          {"extension":"pausableConfig","state":{"authority":null,"paused":true}},
          {"extension":"metadataPointer","state":{}},
          {"extension":"algoNovo","state":{}}
        ]}}}}}}
        """#
        let mint = try SolanaAccountParser.mint(fromResponse: Data(json.utf8), address: N.pyusd)
        #expect(mint.extensions == [
            .transferFee(basisPoints: 250, maximumFee: BigUInt(UInt64.max)), .transferHook, .defaultAccountStateFrozen, .paused, .unknown("algoNovo"),
        ])
    }

    @Test("Tabela de enderecos: layout, desativada, outro dono, e o acordo entre duas leituras")
    func lookupTable() throws {
        let address = try SolanaPublicKey(base58: "CdASjXYwMVqf4PSq6j3uTrqDRKJoKEP6wtFLXhJYpUCi")
        let raw = try #require(try account("account-alt"))
        let table = try SolanaAccountParser.lookupTable(raw, address: address)
        let bytes = try #require(raw.data.bytes)
        #expect(table.addresses.count == (bytes.count - 56) / 32)
        #expect(table.addresses.count == 252)
        #expect(table.addresses.first == (try SolanaPublicKey(bytes: Array(bytes[56..<88]))))

        var deactivated = bytes
        deactivated[4] = 0x10
        #expect(throws: SolanaAccountParseError.lookupTableDeactivated) { try SolanaAccountParser.lookupTable(bytes: deactivated, address: address) }
        var wrongType = bytes
        wrongType[0] = 2
        #expect(throws: SolanaAccountParseError.notALookupTable) { try SolanaAccountParser.lookupTable(bytes: wrongType, address: address) }
        #expect(throws: SolanaAccountParseError.notALookupTable) { try SolanaAccountParser.lookupTable(try account("account-system"), address: address) }

        let shorter = SolanaAddressLookupTable(address: address, addresses: Array(table.addresses.prefix(200)))
        #expect(SolanaAccountParser.agree(table, table) == table)
        #expect(SolanaAccountParser.agree(table, shorter) == shorter)
        var swapped = table.addresses
        swapped[7] = N.toly
        #expect(SolanaAccountParser.agree(table, SolanaAddressLookupTable(address: address, addresses: swapped)) == nil)
    }
}

@Suite("Solana rede: estado para transacao")
struct SolanaNetStateTests {
    @Test("Blockhash, altura, saldo e rent gravados decodificam exatos")
    func state() throws {
        let latest = try N.decode("latest-blockhash", as: RPCContextual<RPCBlockhash>.self)
        #expect(latest.value.blockhash == "CnKX7V8DmVDN4LHHDxgYgjN9S7HHne1guXASxYHtafRH" && latest.value.lastValidBlockHeight == 428_586_980)
        let epoch = try N.decode("epoch-info", as: RPCEpochInfo.self)
        #expect(epoch.blockHeight == 428_586_960 && epoch.absoluteSlot == 450_547_148)
        #expect(try N.decode("balance", as: RPCContextual<UInt64>.self).value == 1_328_297_670_391)
        #expect(try N.decode("rent-0", as: UInt64.self) == 650_240)
    }

    @Test("Janela do blockhash: o slot no lugar da altura (bug visto num provedor publico) e recusado")
    func window() throws {
        try SolanaNetworkReader.checkWindow(lastValid: 428_586_980, current: 428_586_960)
        // getBlockHeight com commitment devolvia 450547020 (o slot) nesse provedor.
        #expect(throws: SolanaInconsistentResponse.self) { try SolanaNetworkReader.checkWindow(lastValid: 428_586_980, current: 450_547_020) }
        #expect(throws: SolanaInconsistentResponse.self) { try SolanaNetworkReader.checkWindow(lastValid: 428_586_980, current: 428_000_000) }
    }

    @Test("Prioridade: percentil 50 a 75, grampeado; lista gravada da rede principal")
    func priority() throws {
        let fees = try N.decode("prioritization-fees", as: [RPCPrioritizationFee].self).map(\.prioritizationFee)
        #expect(fees.count == 150)
        let sorted = fees.sorted()
        #expect(SolanaAccountParser.priorityFee(fees, percentile: 75) == sorted[112])
        #expect(SolanaAccountParser.priorityFee(fees, percentile: 50) == sorted[74])
        let sample: [UInt64] = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90]
        #expect(SolanaAccountParser.priorityFee(sample, percentile: 50) == 40)
        #expect(SolanaAccountParser.priorityFee(sample, percentile: 75) == 70)
        #expect(SolanaAccountParser.priorityFee(sample, percentile: 99) == 70)
        #expect(SolanaAccountParser.priorityFee(sample, percentile: 1) == 40)
        #expect(SolanaAccountParser.priorityFee([], percentile: 75) == 0)
    }

    @Test("Simulacao gravada da troca SOL -> USDC: sucesso, consumo e contas do dono")
    func simulationOK() throws {
        let value = try N.decode("simulate-swap-ok", as: RPCContextual<RPCSimulation>.self).value
        let outcome = try SolanaNetworkReader.outcome(value, accounts: [N.toly, N.tolyUSDC])
        #expect(outcome.succeeded)
        #expect(outcome.unitsConsumed == 143_739)
        #expect(outcome.suggestedComputeUnitLimit == 158_113)
        #expect(outcome.accounts[0].lamports == 1_328_291_003_196 && outcome.accounts[0].programOwner == SolanaProgramID.system)
        #expect(outcome.accounts[1].tokenMint == N.usdc && outcome.accounts[1].tokenOwner == N.toly)
        #expect((outcome.accounts[1].tokenAmount ?? 0) > 561_367_767)
    }

    @Test("Simulacao gravada que falha: erro em texto, conta nula")
    func simulationFail() throws {
        let value = try N.decode("simulate-fail", as: RPCContextual<RPCSimulation>.self).value
        let outcome = try SolanaNetworkReader.outcome(value, accounts: [N.toly])
        #expect(!outcome.succeeded)
        #expect(outcome.error == #"{"InstructionError":[0,{"Custom":1}]}"#)
        #expect(outcome.accounts == [.missing(N.toly)])
        #expect(throws: SolanaInconsistentResponse.self) { try SolanaNetworkReader.outcome(value, accounts: [N.toly, N.usdc]) }
    }
}

@Suite("Solana rede: transmissao e acompanhamento")
struct SolanaNetBroadcastTests {
    static let signed = SignedTransaction(chainID: "solana", raw: [1, 2, 3], encoded: "AQID", id: "SigDaTransacao")

    @Test("Erro de preflight gravado vira SolanaRPCError -32002")
    func preflightFixture() throws {
        #expect(throws: SolanaRPCError(code: -32002, message: "Transaction simulation failed: Attempt to debit an account but found no record of a prior credit.")) {
            _ = try N.decode("send-preflight-error", method: "sendTransaction", as: String.self)
        }
    }

    @Test("Dois provedores: basta um aceitar; id diferente e recusa; ja processada conta como aceita")
    func receipt() throws {
        let preflight = SolanaRPCError(code: -32002, message: "Transaction simulation failed: insufficient funds")
        let ok = try SolanaBroadcaster.receipt(for: Self.signed, outcomes: [("a", .success("SigDaTransacao")), ("b", .failure(preflight))])
        #expect(ok.acceptedBy == ["a"] && ok.rejections["b"] != nil && ok.signature == "SigDaTransacao")
        #expect(throws: SolanaBroadcastError.preflightFailed(preflight.message)) {
            try SolanaBroadcaster.receipt(for: Self.signed, outcomes: [("a", .failure(preflight)), ("b", .failure(preflight))])
        }
        #expect(throws: SolanaBroadcastError.rejected(["a": "id diferente: OutroId"])) {
            try SolanaBroadcaster.receipt(for: Self.signed, outcomes: [("a", .success("OutroId"))])
        }
        let processed = SolanaRPCError(code: -32002, message: "Transaction simulation failed: This transaction has already been processed")
        #expect(try SolanaBroadcaster.receipt(for: Self.signed, outcomes: [("a", .failure(processed))]).acceptedBy == ["a"])
    }

    @Test("Status gravados: finalizada, falhou, desconhecida; e o vencimento pela altura")
    func statuses() throws {
        let raw = try N.decode("signature-statuses", as: RPCContextual<[RPCSignatureStatus?]>.self).value
        let statuses = raw.map { $0.map(SolanaSignatureStatus.init) }
        #expect(statuses.count == 3)
        #expect(SolanaConfirmationTracker.evaluate(status: statuses[0], currentBlockHeight: 10, lastValidBlockHeight: 5) == .finalized(slot: 450_546_679))
        #expect(SolanaConfirmationTracker.evaluate(status: statuses[1], currentBlockHeight: 1, lastValidBlockHeight: 5)
                == .failed(slot: 450_070_138, error: #"{"InsufficientFundsForRent":{"account_index":9}}"#))
        #expect(SolanaConfirmationTracker.evaluate(status: statuses[2], currentBlockHeight: 5, lastValidBlockHeight: 5) == .pending)
        #expect(SolanaConfirmationTracker.evaluate(status: statuses[2], currentBlockHeight: 6, lastValidBlockHeight: 5) == .expired)
        let confirmed = SolanaSignatureStatus(slot: 9, confirmationStatus: "confirmed", error: nil)
        #expect(SolanaConfirmationTracker.evaluate(status: confirmed, currentBlockHeight: 99, lastValidBlockHeight: 5) == .confirmed(slot: 9))
        #expect(SolanaBroadcaster.reached(.confirmed(slot: 9), .confirmed))
        #expect(!SolanaBroadcaster.reached(.confirmed(slot: 9), .finalized))
        #expect(SolanaBroadcaster.reached(.finalized(slot: 9), .finalized))
        #expect(!SolanaBroadcaster.reached(.processed(slot: 9), .confirmed))
    }
}
