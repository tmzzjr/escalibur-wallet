import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation

/// Envio na Solana: SOL e os tokens SPL da lista compilada.
///
/// O motor so junta as pecas. Quem le e o modulo de rede; quem valida e monta e o
/// `SolanaPlanner`, pelo `SolanaPlanningService`. Aqui ficam as conferencias que so
/// o motor pode fazer, porque so ele ve o pedido inteiro:
///   - a conta do dono gera o endereco guardado;
///   - so SOL e token da lista; token cujo mint, lido da rede, tem outras casas e
///     recusado;
///   - conta de token colada no lugar de carteira e recusada com o motivo, antes
///     do plano;
///   - o destino que volta no plano (`review.recipient`) e o digitado, a transacao e
///     uma so, do dono, no caminho dele;
///   - o id transmitido e recalculado dos bytes assinados.
struct SolanaSendEngine: SendEngine {
    static let shared = SolanaSendEngine(network: SolanaLiveNetwork(), book: .shared)

    let network: any SolanaEngineNetwork
    let book: SolanaTransferBook

    // MARK: Destino

    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo {
        do {
            try SolanaEngineGuard.chain(chain)
            let key = try SolanaEngineGuard.destination(address)
            switch try await network.destinationAccount(key) {
            case .nonexistent:
                // Endereco nunca usado: um envio de SOL so cria a conta com pelo menos o
                // minimo de rent. Este metodo nao recebe o ativo; num envio de token esse
                // minimo nao se aplica (a conta de token do destino e paga pelo dono, e o
                // plano mostra quanto).
                let minimum = try await network.emptyAccountRentMinimum()
                return DestinationInfo(exists: false, isContract: !key.isOnCurve, activationMinimum: minimum, note: Self.note(for: key, exists: false))
            case .system:
                return DestinationInfo(exists: true, isContract: !key.isOnCurve, note: Self.note(for: key, exists: true))
            case .tokenAccount:
                throw SolanaEngineProblem.destinationIsTokenAccount
            case .programOwned(let owner):
                // Dono Token ou Token-2022 sem ser conta de token: o proprio mint.
                throw SolanaTokenProgram(programID: owner) == nil ? SolanaEngineProblem.destinationIsProgram : SolanaEngineProblem.destinationIsMint
            }
        } catch {
            throw SolanaEngineMessages.map(error, .destination)
        }
    }

    static func note(for key: SolanaPublicKey, exists: Bool) -> String? {
        if !key.isOnCurve {
            return "Este endereço é de uma conta de programa, como um cofre multiassinatura. Envio de SOL passa com aviso; envio de token não."
        }
        return exists ? nil : "Este endereço ainda não existe na Solana. Um envio de SOL precisa cobrir a reserva mínima da rede."
    }

    // MARK: Quanto pode sair

    func spendable(_ request: SendRequest) async throws -> Spendable {
        var flow = SolanaEngineMessages.Flow.sendSOL
        do {
            try SolanaEngineGuard.chain(request.chain)
            let owner = try SolanaEngineGuard.owner(request.account)
            // O destino so ajusta a estimativa (prioridade das contas gravaveis, conta
            // de token a criar). Destino ainda invalido nao impede a conta.
            let destination = try? SolanaEngineGuard.destination(request.destination)
            switch try SolanaEngineAsset(request.asset) {
            case .sol:
                return try await spendableSOL(owner: owner, destination: destination)
            case .token(let mint, let listed):
                flow = .sendToken
                return try await spendableToken(owner: owner, mint: mint, listed: listed, destination: destination)
            }
        } catch {
            throw SolanaEngineMessages.map(error, flow)
        }
    }

    /// SOL: o saldo menos a taxa de um envio e a reserva de rent. A reserva fica
    /// porque a conta so pode terminar zerada ou acima dela, e a taxa real sai do
    /// consumo simulado, quase sempre menor que o limite padrao usado aqui: a sobra
    /// entre as duas cai na reserva, nunca abaixo dela.
    func spendableSOL(owner: SolanaOwner, destination: SolanaPublicKey?) async throws -> Spendable {
        let state = try await network.networkState(owner: owner.publicKey, writableAccounts: destination.map { [$0] } ?? [])
        let fee = try SolanaPlanner.sendSOLFee(network: state)
        let reserve = state.rentExemptMinimum
        let amount = state.balance.subtractingReportingUnderflow(fee + reserve) ?? BigUInt()
        return Spendable(
            amount: amount,
            reserveNote: "\(SolanaAmountText.sol(reserve)) ficam na conta: é a reserva mínima que a rede exige para ela continuar existindo.",
            feeNote: "Taxa da rede de até \(SolanaAmountText.sol(fee)) já descontada."
        )
    }

    /// Token: o saldo inteiro do token, desde que o SOL cubra a taxa e, se o destino
    /// ainda nao tiver conta deste token, o rent dela. Sem SOL para isso, zero, com o
    /// motivo na nota. E estimativa: quem decide e o planejador, com o estado da hora.
    func spendableToken(owner: SolanaOwner, mint: SolanaPublicKey, listed: Asset, destination: SolanaPublicKey?) async throws -> Spendable {
        let token = try await network.tokenState(owner: owner.publicKey, mint: mint)
        guard token.isVerified, Int(token.decimals) == listed.decimals else { throw SolanaEngineProblem.tokenNotVerified }
        // Sem destino legivel, o pior caso: criar a conta de token dele.
        var createsAccount = true
        var writable = [token.source.address]
        if let destination {
            switch try await network.destinationAccount(destination) {
            case .nonexistent, .system:
                if destination.isOnCurve,
                   case .existing(let account) = try await network.destinationTokenAccount(owner: destination, mint: mint, program: token.program) {
                    createsAccount = false
                    writable.append(account.address)
                }
            case .tokenAccount(let account):
                createsAccount = false
                writable.append(account.address)
            case .programOwned:
                break
            }
        }
        let state = try await network.networkState(owner: owner.publicKey, writableAccounts: writable)
        let fee = SolanaFeeCeiling.fee(state, units: SolanaPlanner.tokenTransferComputeUnits(token.program, createsAccount: createsAccount))
        let rent = createsAccount ? token.tokenAccountRentMinimum : BigUInt()
        let needed = fee + rent
        let covered: Bool
        if let remainder = state.balance.subtractingReportingUnderflow(needed) {
            // A mesma regra do planejador: a conta termina zerada ou acima da reserva.
            covered = remainder.isZero || remainder >= state.rentExemptMinimum
        } else {
            covered = false
        }
        let symbol = listed.symbol
        let note: String
        switch (covered, createsAccount) {
        case (true, true):
            note = "A taxa da rede e a criação da conta de \(symbol) do destino, até \(SolanaAmountText.sol(needed)), saem do seu saldo de SOL."
        case (true, false):
            note = "A taxa da rede, até \(SolanaAmountText.sol(fee)), sai do seu saldo de SOL."
        case (false, true):
            note = "Falta SOL para a taxa da rede e para criar a conta de \(symbol) do destino. Deposite SOL nesta carteira para enviar \(symbol)."
        case (false, false):
            note = "Falta SOL para a taxa da rede. Deposite SOL nesta carteira para enviar \(symbol)."
        }
        return Spendable(amount: covered ? token.source.amount : BigUInt(), reserveNote: nil, feeNote: note)
    }

    // MARK: Plano

    func plan(_ request: SendRequest) async throws -> SigningPlan {
        var flow = SolanaEngineMessages.Flow.sendSOL
        do {
            try SolanaEngineGuard.chain(request.chain)
            let asset = try SolanaEngineAsset(request.asset)
            guard (request.tag ?? "").isEmpty else { throw SolanaEngineProblem.tagNotSupported }
            let owner = try SolanaEngineGuard.owner(request.account)
            let destination = try SolanaEngineGuard.destination(request.destination)
            let plan: SigningPlan
            switch asset {
            case .sol:
                let lamports = request.sendAll ? try await sendAllLamports(shown: request.amount, owner: owner, destination: destination) : request.amount
                plan = try await network.planSendSOL(walletID: request.walletID, owner: owner, to: request.destination, lamports: lamports)
            case .token(let mint, _):
                flow = .sendToken
                // Conta de token colada no lugar de carteira: o planejador aceitaria, mas
                // o destino do plano seria o dono dela, nao o endereco digitado, e o app
                // recusaria sem dizer por que. Recusa aqui, com o motivo.
                if case .tokenAccount = try await network.destinationAccount(destination) { throw SolanaEngineProblem.destinationIsTokenAccount }
                plan = try await network.planSendToken(walletID: request.walletID, owner: owner, to: request.destination, mint: mint, amount: request.amount)
                // Mint da lista com casas diferentes na rede: o planejador so avisa.
                if plan.review.warnings.contains(where: { if case .unverifiedToken = $0 { true } else { false } }) {
                    throw SolanaEngineProblem.tokenNotVerified
                }
            }
            try Self.check(plan, request: request, owner: owner)
            await book.planned(plan)
            return plan
        } catch {
            throw SolanaEngineMessages.map(error, flow)
        }
    }

    /// "Enviar tudo" de SOL: o maximo recalculado com o estado de agora, nunca acima
    /// do que a tela mostrou. A prioridade pode ter subido desde `spendable`; com o
    /// valor antigo, o plano deixaria na conta menos que a reserva e seria recusado.
    func sendAllLamports(shown: BigUInt, owner: SolanaOwner, destination: SolanaPublicKey) async throws -> BigUInt {
        let now = try await spendableSOL(owner: owner, destination: destination).amount
        guard !now.isZero else { throw SolanaEngineProblem.nothingToSpend }
        return min(shown, now)
    }

    /// O plano que voltou e o do pedido: rede, carteira, envio, destino digitado sem
    /// tag, e uma transacao so, do dono, no caminho de derivacao dele. O app confere o
    /// destino de novo antes de assinar; esta e a mesma regra, do lado do motor.
    static func check(_ plan: SigningPlan, request: SendRequest, owner: SolanaOwner) throws {
        guard plan.chain == .solana, plan.walletID == request.walletID, plan.review.kind == .send,
              Address.sameRecipient(plan.review.recipient, request.destination, chain: .solana), plan.review.recipientTag == nil,
              plan.transactions.count == 1, let transaction = plan.transactions.first as? SolanaTransaction,
              transaction.signer == owner.publicKey, transaction.signerPath == owner.path
        else { throw SolanaEngineProblem.planMismatch }
    }

    // MARK: Transmissao

    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String {
        do {
            try SolanaEngineGuard.chain(chain)
            guard signed.count == 1 else { throw SolanaEngineProblem.signedMismatch }
            let envelope = try SolanaSignedEnvelope(signed[0])
            return try await SolanaTransfers.transmit(signed[0], envelope: envelope, network: network, book: book, lastValidBlockHeight: nil)
        } catch {
            throw SolanaEngineMessages.map(error, .broadcast)
        }
    }

    func status(_ id: String, chain: Chain) async -> TransferStatus {
        guard chain == .solana else { return .failed(reason: SolanaEngineMessages.text(SolanaEngineProblem.wrongChain)) }
        return await SolanaTransfers.status(id, network: network, book: book)
    }
}
