import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburEngines
@testable import EscaliburNetwork

private typealias F = SolanaEngineFixtures

/// O motor de envio da Solana contra a rede gravada: o plano sai do `SolanaPlanner`
/// de verdade, com o estado gravado, e o motor confere o que so ele ve.
@Suite("Solana: motor de envio")
struct SolanaSendEngineTests {
    let wallet = UUID()

    func engine(balance: BigUInt? = nil) async throws -> (SolanaSendEngine, RecordedSolanaNetwork, SolanaTransferBook) {
        let network = try RecordedSolanaNetwork(balance: try balance ?? F.recordedBalance())
        await network.setTokenState(try F.tolyUSDCState())
        let book = SolanaTransferBook(resendInterval: 0)
        return (SolanaSendEngine(network: network, book: book), network, book)
    }

    func request(
        _ asset: Asset, to destination: SolanaPublicKey, amount: BigUInt, owner: SolanaPublicKey = F.toly, sendAll: Bool = false,
        tag: String? = nil, chain: Chain = .solana
    ) -> SendRequest {
        SendRequest(
            walletID: wallet, chain: chain, asset: asset, account: F.account(owner), destination: destination.base58, tag: tag,
            amount: amount, sendAll: sendAll, feeLevel: .normal, utxoUsage: nil
        )
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

    // MARK: Destino

    @Test("Destino: carteira existente, conta nova com o minimo de ativacao")
    func destinations() async throws {
        let (engine, _, _) = try await engine()
        let wallet = try await engine.destination(F.exchange.base58, chain: .solana)
        #expect(wallet.exists && !wallet.isContract && wallet.activationMinimum == nil && !wallet.requiresTag)
        let fresh = try await engine.destination(F.nova.base58, chain: .solana)
        #expect(!fresh.exists && !fresh.isContract)
        #expect(fresh.activationMinimum == (try F.rent("rpc-rent-0")))
        #expect(fresh.note?.contains("—") == false)
    }

    @Test("Destino: conta de token, programa e mint sao recusados com o motivo")
    func refusedDestinations() async throws {
        let (engine, network, _) = try await engine()
        #expect(await message { try await engine.destination(F.exchangeUSDC.base58, chain: .solana) } == SolanaEngineMessages.tokenAccountDestination)
        #expect(await message { try await engine.destination(SolanaProgramID.jupiterV6.base58, chain: .solana) } == SolanaEngineMessages.programDestination)
        #expect(await message { try await engine.destination(F.usdcMint.base58, chain: .solana) } == SolanaEngineMessages.mintDestination)
        // Mint fora da lista: a rede diz que o dono e o Token Program, sem ser conta de token.
        await network.setAccount(F.nova, .programOwned(owner: SolanaProgramID.token))
        #expect(await message { try await engine.destination(F.nova.base58, chain: .solana) } == SolanaEngineMessages.mintDestination)
        #expect(await message { try await engine.destination("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045", chain: .solana) }
            == SolanaEngineMessages.text(SolanaEngineProblem.invalidDestination))
        #expect(await message { try await engine.destination(F.exchange.base58, chain: .ethereum) } == SolanaEngineMessages.text(SolanaEngineProblem.wrongChain))
    }

    // MARK: Quanto pode sair

    @Test("SOL: o saldo menos a taxa de um envio e a reserva de rent")
    func spendableSOL() async throws {
        let (engine, _, _) = try await engine()
        let spendable = try await engine.spendable(request(F.sol, to: F.exchange, amount: BigUInt()))
        let state = try F.state(balance: try F.recordedBalance())
        let fee = try SolanaPlanner.sendSOLFee(network: state)
        #expect(spendable.amount == state.balance - fee - state.rentExemptMinimum)
        #expect(spendable.reserveNote?.hasPrefix(SolanaAmountText.sol(state.rentExemptMinimum)) == true)
        #expect(spendable.feeNote?.contains(SolanaAmountText.sol(fee)) == true)
    }

    @Test("SOL: saldo abaixo da taxa mais a reserva, nada a enviar")
    func spendableSOLEmpty() async throws {
        let (engine, _, _) = try await engine(balance: BigUInt(600_000))
        #expect(try await engine.spendable(request(F.sol, to: F.exchange, amount: BigUInt())).amount.isZero)
    }

    @Test("USDC: o saldo do token, com SOL para a taxa e para a conta de token do destino")
    func spendableToken() async throws {
        let (engine, _, _) = try await engine()
        let balance = try F.tolyUSDCState().source.amount
        let existing = try await engine.spendable(request(F.usdc, to: F.exchange, amount: BigUInt()))
        #expect(existing.amount == balance)
        #expect(existing.feeNote?.hasPrefix("A taxa da rede, até") == true)
        let fresh = try await engine.spendable(request(F.usdc, to: F.nova, amount: BigUInt()))
        #expect(fresh.amount == balance)
        #expect(fresh.feeNote?.contains("criação da conta de USDC do destino") == true)
    }

    @Test("USDC sem SOL para a taxa e para a conta do destino: zero, com o motivo")
    func spendableTokenWithoutSOL() async throws {
        // Saldo gravado trocado por 0,001 SOL: nao cobre o rent de uma conta de token.
        let (engine, _, _) = try await engine(balance: BigUInt(1_000_000))
        let fresh = try await engine.spendable(request(F.usdc, to: F.nova, amount: BigUInt()))
        #expect(fresh.amount.isZero)
        #expect(fresh.feeNote?.hasPrefix("Falta SOL para a taxa da rede e para criar a conta de USDC") == true)
        // Destino que ja tem a conta de token: so a taxa, que 0,001 SOL cobre.
        #expect(try await engine.spendable(request(F.usdc, to: F.exchange, amount: BigUInt())).amount == (try F.tolyUSDCState().source.amount))
    }

    @Test("Token cujo mint, na rede, tem casas diferentes da lista: recusado")
    func spendableUnverifiedToken() async throws {
        let (engine, network, _) = try await engine()
        // Casas gravadas (6) trocadas por 9.
        await network.setTokenState(try F.tolyUSDCState(decimals: 9))
        #expect(await message { try await engine.spendable(request(F.usdc, to: F.exchange, amount: BigUInt())) }
            == SolanaEngineMessages.text(SolanaEngineProblem.tokenNotVerified))
    }

    // MARK: Plano

    @Test("Plano de SOL: o destino digitado em review.recipient, uma transacao do dono")
    func planSOL() async throws {
        let (engine, _, _) = try await engine()
        let plan = try await engine.plan(request(F.sol, to: F.exchange, amount: BigUInt(1_000_000)))
        #expect(plan.review.kind == .send && plan.chain == .solana && plan.walletID == wallet)
        #expect(plan.review.recipient == F.exchange.base58 && plan.review.recipientTag == nil)
        #expect(plan.review.lines.first { $0.label == "Para" }?.value == F.exchange.base58)
        let transaction = try #require(plan.transactions.first as? SolanaTransaction)
        #expect(transaction.signer == F.toly && transaction.signerPath == DefaultPaths.path(for: .solana))
    }

    @Test("Plano de USDC: recipient e a carteira digitada; a conta de token do destino aparece na revisao")
    func planToken() async throws {
        let (engine, _, _) = try await engine()
        let plan = try await engine.plan(request(F.usdc, to: F.exchange, amount: BigUInt(1_000_000)))
        #expect(plan.review.recipient == F.exchange.base58)
        #expect(plan.review.lines.first { $0.label == "Para" }?.value == F.exchange.base58)
        #expect(plan.review.lines.first { $0.label == "Conta de token do destino" }?.value == F.exchangeUSDC.base58)
        #expect(plan.review.title == "Enviar 1 USDC")

        // Carteira sem conta de USDC: a transacao cria a conta, e o destino continua a carteira.
        let fresh = try await engine.plan(request(F.usdc, to: F.nova, amount: BigUInt(1_000_000)))
        #expect(fresh.review.recipient == F.nova.base58)
        #expect(fresh.review.warnings.contains { if case .activatesAccount = $0 { true } else { false } })
    }

    @Test("Conta de token colada no lugar da carteira: recusada com o motivo, em SOL e em token")
    func tokenAccountDestination() async throws {
        let (engine, _, _) = try await engine()
        for asset in [F.sol, F.usdc] {
            #expect(await message { try await engine.plan(request(asset, to: F.exchangeUSDC, amount: BigUInt(1_000_000))) }
                == SolanaEngineMessages.tokenAccountDestination)
        }
    }

    @Test("Enviar tudo de SOL: o maximo e recalculado com o estado de agora e nunca passa do mostrado")
    func sendAll() async throws {
        let (engine, network, _) = try await engine()
        let shown = try await engine.spendable(request(F.sol, to: F.exchange, amount: BigUInt())).amount
        // O saldo cai 10.000 lamports entre a tela e o plano.
        await network.setBalance(try F.recordedBalance() - BigUInt(10_000))
        let lower = try await engine.plan(request(F.sol, to: F.exchange, amount: shown, sendAll: true))
        #expect(await network.plannedLamports.last == shown - BigUInt(10_000))
        #expect(lower.review.kind == .send)
        // O saldo sobe: vale o que a tela mostrou.
        await network.setBalance(try F.recordedBalance() + BigUInt(10_000))
        _ = try await engine.plan(request(F.sol, to: F.exchange, amount: shown, sendAll: true))
        #expect(await network.plannedLamports.last == shown)
    }

    @Test("Pedido fora do contrato: tag, token fora da lista, mint com outra caixa, conta que nao confere, outra rede")
    func refusedRequests() async throws {
        let (engine, _, _) = try await engine()
        let amount = BigUInt(1_000_000)
        #expect(await message { try await engine.plan(request(F.sol, to: F.exchange, amount: amount, tag: "123")) }
            == SolanaEngineMessages.text(SolanaEngineProblem.tagNotSupported))
        let unlisted = Asset(
            chainID: "solana", kind: .token(contract: "CSRvuL45tXnqYKqk9RXBksuaFQzsamp3ACT5pgEQTVzn"), symbol: "USDC", name: "USD Coin",
            decimals: 6, coingeckoID: nil, isStablecoin: true
        )
        #expect(await message { try await engine.plan(request(unlisted, to: F.exchange, amount: amount)) }
            == SolanaEngineMessages.text(SolanaEngineProblem.assetNotSupported))
        // Base58 distingue maiusculas: o mesmo texto com outra caixa e outro mint.
        let recased = Asset(
            chainID: "solana", kind: .token(contract: F.usdcMint.base58.lowercased()), symbol: "USDC", name: "USD Coin", decimals: 6,
            coingeckoID: "usd-coin", isStablecoin: true
        )
        #expect(await message { try await engine.plan(request(recased, to: F.exchange, amount: amount)) }
            == SolanaEngineMessages.text(SolanaEngineProblem.assetNotSupported))
        // Endereco guardado de uma conta e chave publica de outra.
        let mismatched = SendRequest(
            walletID: wallet, chain: .solana, asset: F.sol,
            account: DerivedAccount(chainID: "solana", path: DefaultPaths.path(for: .solana), address: F.exchange.base58, publicKey: F.toly.bytes, accountXPub: nil),
            destination: F.nova.base58, tag: nil, amount: amount, sendAll: false, feeLevel: .normal, utxoUsage: nil
        )
        #expect(await message { try await engine.plan(mismatched) } == SolanaEngineMessages.text(SolanaEngineProblem.accountMismatch))
        #expect(await message { try await engine.plan(request(F.sol, to: F.exchange, amount: amount, chain: .ethereum)) }
            == SolanaEngineMessages.text(SolanaEngineProblem.wrongChain))
    }

    @Test("Mint da lista com casas trocadas na rede: o planejador so avisa, o motor recusa")
    func unverifiedTokenPlan() async throws {
        let (engine, network, _) = try await engine()
        await network.setTokenState(try F.tolyUSDCState(decimals: 9))
        #expect(await message { try await engine.plan(request(F.usdc, to: F.exchange, amount: BigUInt(1_000_000))) }
            == SolanaEngineMessages.text(SolanaEngineProblem.tokenNotVerified))
    }

    @Test("Recusas do planejador chegam traduzidas: saldo, conta nova abaixo do minimo, valor zero")
    func plannerRefusals() async throws {
        let (engine, _, _) = try await engine(balance: BigUInt(2_000_000))
        #expect(await message { try await engine.plan(request(F.sol, to: F.exchange, amount: BigUInt(5_000_000))) }
            == SolanaEngineMessages.text(SolanaPlanError.insufficientFunds(needed: BigUInt(), available: BigUInt()), .sendSOL))
        #expect(await message { try await engine.plan(request(F.sol, to: F.nova, amount: BigUInt(1_000))) }
            == SolanaEngineMessages.text(SolanaPlanError.belowRentExemptMinimum(minimum: BigUInt()), .sendSOL))
        #expect(await message { try await engine.plan(request(F.sol, to: F.exchange, amount: BigUInt())) } == "Digite um valor maior que zero.")
    }

    // MARK: Transmissao e acompanhamento

    /// Um envio de SOL da chave de teste, planejado pelo motor e assinado aqui.
    func signedSend(_ engine: SolanaSendEngine, network: RecordedSolanaNetwork) async throws -> SignedTransaction {
        await network.setBalance(BigUInt(1_000_000_000))
        let plan = try await engine.plan(request(F.sol, to: F.exchange, amount: BigUInt(10_000_000), owner: try F.testKey()))
        return try F.sign(plan)
    }

    @Test("Transmissao: o id sai dos bytes assinados e o prazo do plano fica lembrado")
    func broadcast() async throws {
        let (engine, network, book) = try await engine()
        let signed = try await signedSend(engine, network: network)
        let id = try await engine.broadcast([signed], chain: .solana)
        let wire = try SolanaWireTransaction(bytes: signed.raw)
        #expect(id == wire.id && id == signed.id)
        #expect(await network.sent == [signed])
        #expect(await book.transfer(id)?.lastValidBlockHeight == (try F.lastValidBlockHeight()))
    }

    @Test("Transmissao: bytes adulterados, id trocado, base64 diferente ou duas transacoes nao saem")
    func broadcastRefusals() async throws {
        let (engine, network, _) = try await engine()
        let signed = try await signedSend(engine, network: network)
        var raw = signed.raw
        raw[raw.count - 1] ^= 0x01  // um byte da mensagem: a assinatura deixa de valer
        let tampered = SignedTransaction(chainID: signed.chainID, raw: raw, encoded: Data(raw).base64EncodedString(), id: signed.id)
        let wrongID = SignedTransaction(chainID: signed.chainID, raw: signed.raw, encoded: signed.encoded, id: String(signed.id.dropLast()) + "1")
        let wrongEncoding = SignedTransaction(chainID: signed.chainID, raw: signed.raw, encoded: Data(raw).base64EncodedString(), id: signed.id)
        let refused = SolanaEngineMessages.text(SolanaEngineProblem.signedMismatch)
        for bad in [[tampered], [wrongID], [wrongEncoding], [signed, signed], []] {
            #expect(await message { try await engine.broadcast(bad, chain: .solana) } == refused)
        }
        #expect(await network.sent.isEmpty)
    }

    @Test("Transmissao recusada na simulacao do no: mensagem nossa, sem o texto do provedor")
    func broadcastPreflight() async throws {
        let (engine, network, _) = try await engine()
        let signed = try await signedSend(engine, network: network)
        let recorded = try JSONDecoder().decode(RPCErrorEnvelope.self, from: try F.data("rpc-envio-recusado")).error
        // O erro que o transmissor de verdade tira da resposta gravada.
        let failure: any Error
        do {
            _ = try SolanaBroadcaster.receipt(for: signed, outcomes: [("gravado", .failure(recorded))])
            Issue.record("a resposta gravada e uma recusa")
            return
        } catch {
            failure = error
        }
        await network.setSendError(failure)
        let text = await message { try await engine.broadcast([signed], chain: .solana) }
        #expect(text == SolanaEngineMessages.text(SolanaBroadcastError.preflightFailed("")))
        #expect(text?.contains(recorded.message) == false)
    }

    @Test("Acompanhamento pelo prazo do blockhash: pendente reenvia, vencido falha, historico confirma")
    func status() async throws {
        let (engine, network, _) = try await engine()
        let deadline = try F.lastValidBlockHeight()
        let recorded = try F.statuses()

        // Nao visto e dentro do prazo: pendente, e os mesmos bytes saem de novo.
        let first = try await signedSend(engine, network: network)
        let pendingID = try await engine.broadcast([first], chain: .solana)
        await network.setHeight(deadline - 10)
        #expect(await engine.status(pendingID, chain: .solana) == .pending)
        #expect(await network.sent == [first, first])

        // Regressao M4: passou do prazo so na altura confirmada, ou na finalizada de uma
        // fonte so, ou sem a folga: continua pendente.
        await network.setHeight(deadline + 1)
        await network.setFinalized([deadline + 1, deadline + 1])
        #expect(await engine.status(pendingID, chain: .solana) == .pending)
        await network.setFinalized([deadline + 500, deadline + 10])
        #expect(await engine.status(pendingID, chain: .solana) == .pending)
        // Passou do prazo com folga nas duas fontes e nenhum historico conhece: venceu,
        // nada foi debitado.
        await network.setFinalized([deadline + 500, deadline + 400])
        guard case .failed(let expired) = await engine.status(pendingID, chain: .solana) else { Issue.record("deveria vencer"); return }
        #expect(expired.hasPrefix("A transação venceu"))

        // So o historico do segundo provedor conhece a transacao: nao venceu, entrou.
        let known = try await signedSend(engine, network: network)
        let knownID = try await engine.broadcast([known], chain: .solana)
        await network.setSecondHistory(knownID, try #require(recorded.first))
        #expect(await engine.status(knownID, chain: .solana) == .confirmed(detail: "Finalizada na rede Solana."))

        // Passou do prazo, mas o historico mostra que entrou: confirmada.
        let second = try await signedSend(engine, network: network)
        let landedID = try await engine.broadcast([second], chain: .solana)
        await network.setStatus(landedID, recent: nil, history: recorded[0])
        #expect(await engine.status(landedID, chain: .solana) == .confirmed(detail: "Finalizada na rede Solana."))

        // Entrou e falhou: a taxa foi cobrada; o erro do no nao aparece.
        let third = try await signedSend(engine, network: network)
        let failedID = try await engine.broadcast([third], chain: .solana)
        await network.setStatus(failedID, recent: recorded[1], history: nil)
        guard case .failed(let reason) = await engine.status(failedID, chain: .solana) else { Issue.record("deveria falhar"); return }
        #expect(reason.hasPrefix("A transação entrou num bloco e falhou") && !reason.contains("InsufficientFundsForRent"))
    }

    @Test("Acompanhamento sem leitura ou sem prazo conhecido nunca declara vencimento")
    func statusWithoutCertainty() async throws {
        let (engine, network, _) = try await engine()
        let signed = try await signedSend(engine, network: network)
        let id = try await engine.broadcast([signed], chain: .solana)
        await network.setHeight(UInt64.max)
        await network.setStatusFails(true)
        #expect(await engine.status(id, chain: .solana) == .pending)
        await network.setStatusFails(false)
        // Transacao de outra sessao: vai direto ao historico e, sem achar, fica pendente.
        let other = String(repeating: "1", count: 64)
        #expect(await engine.status(other, chain: .solana) == .pending)
        #expect(await network.statusQueries.last == true)
    }
}

/// `sendTransaction` recusado, como o no devolve.
private struct RPCErrorEnvelope: Decodable {
    let error: SolanaRPCError
}
