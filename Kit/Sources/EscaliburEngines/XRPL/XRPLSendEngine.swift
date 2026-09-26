import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Enviar XRP.
///
/// Junta o `XRPLReader` (conta do dono e destino lidos em dois servidores no mesmo
/// ledger validado; reservas e taxa do `server_info`) e o `XRPLPlanner` (RequireDest,
/// DepositAuth, DisallowXRP, reserva de ativacao, teto de taxa, LastLedgerSequence de
/// ledger validado + 20). A tag de destino sai de `SendRequest.tag`. Nada e assinado
/// aqui.
struct XRPLSendEngine: SendEngine {
    let reader: XRPLReader

    init(reader: XRPLReader = .shared) {
        self.reader = reader
    }

    // MARK: Destino

    /// Se a conta existe e se exige tag (lsfRequireDestTag). Conta que nao existe so
    /// nasce com a reserva base, lida agora do `server_info`.
    ///
    /// `destinationState` pede a conta de origem so para o `deposit_authorized`, que o
    /// plano le de novo com a conta certa. Aqui vai o proprio destino, que sempre pode
    /// depositar em si mesmo: a resposta nao e usada.
    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo {
        try requireChain(chain)
        guard case .success(let parsed) = Address.validate(address, for: .xrpl) else {
            throw SendEngineError.message(XRPLEngineSupport.text(.invalidDestination(.malformed)))
        }
        do {
            let state = try await reader.destinationState(address: parsed.address, source: parsed.address)
            guard state.readings.count >= 2, Set(state.readings).count == 1 else {
                throw SendEngineError.message(NetworkFailureText.disagree)
            }
            switch state.readings[0] {
            case .notFound:
                let ledger = try await reader.ledgerState()
                return DestinationInfo(
                    exists: false, activationMinimum: ledger.reserveBase,
                    note: "Esta conta ainda não existe no XRP Ledger. O primeiro envio ativa a conta e precisa ser de pelo menos \(XRPLEngineSupport.xrp(ledger.reserveBase))."
                )
            case .found(let flags):
                var notes: [String] = []
                if flags & XRPLAccountFlags.disallowXRP != 0 {
                    notes.append("Esta conta pediu para não receber XRP. Nesta versão a carteira não envia para ela.")
                }
                if flags & XRPLAccountFlags.depositAuth != 0 {
                    notes.append("Esta conta só aceita depósitos de quem ela autorizou antes. O envio é conferido na revisão.")
                }
                return DestinationInfo(
                    exists: true, requiresTag: flags & XRPLAccountFlags.requireDestTag != 0,
                    note: notes.isEmpty ? nil : notes.joined(separator: " ")
                )
            }
        } catch {
            throw XRPLEngineSupport.translate(error)
        }
    }

    // MARK: Maximo

    /// Saldo menos a reserva (base mais uma por objeto da conta) menos a taxa.
    func spendable(_ request: SendRequest) async throws -> Spendable {
        try check(request)
        let owner = try XRPLEngineSupport.owner(request.account)
        do {
            async let ledgerState = reader.ledgerState()
            async let accountState = reader.accountState(address: owner)
            let ledger = try await ledgerState
            let account: XRPLAccountState
            do {
                account = try await accountState
            } catch ReaderError.accountNotFound {
                return Spendable(
                    amount: BigUInt(),
                    reserveNote: "Esta conta ainda não existe no XRP Ledger. Ela passa a existir quando receber pelo menos \(XRPLEngineSupport.xrp(ledger.reserveBase))."
                )
            }
            let fee = XRPLPlanner.fee(openLedgerFee: ledger.openLedgerFee)
            guard fee <= XRPLPlanner.maxFeeDrops else { throw XRPLPlanError.feeAboveCap(fee: fee, cap: XRPLPlanner.maxFeeDrops) }
            let reserve = ledger.reserveBase + BigUInt(account.ownerCount) * ledger.reserveIncrement
            let objects = account.ownerCount == 0
                ? ""
                : " \(account.ownerCount == 1 ? "Inclui 1 objeto da conta" : "Inclui \(account.ownerCount) objetos da conta"), como linha de confiança ou oferta aberta."
            return Spendable(
                amount: XRPLPlanner.spendable(account: account, ledger: ledger).subtractingReportingUnderflow(fee) ?? BigUInt(),
                reserveNote: "\(XRPLEngineSupport.xrp(reserve)) ficam reservados pela rede enquanto a conta existir.\(objects)",
                feeNote: "Já descontada a taxa da rede, de \(XRPLEngineSupport.xrp(fee))."
            )
        } catch {
            throw XRPLEngineSupport.translate(error)
        }
    }

    // MARK: Plano

    func plan(_ request: SendRequest) async throws -> SigningPlan {
        try check(request)
        let owner = try XRPLEngineSupport.owner(request.account)
        let tag = try XRPLEngineSupport.tag(request.tag)
        do {
            async let ledgerState = reader.ledgerState()
            async let accountState = reader.accountState(address: owner)
            async let destinationState = reader.destinationState(address: request.destination, source: owner)
            let ledger = try await ledgerState
            let account = try await accountState
            let destination = try await destinationState
            // "Enviar tudo" com o estado lido agora, nao com o maximo que a tela mostrou.
            let drops = request.sendAll
                ? XRPLPlanner.spendable(account: account, ledger: ledger)
                    .subtractingReportingUnderflow(XRPLPlanner.fee(openLedgerFee: ledger.openLedgerFee)) ?? BigUInt()
                : request.amount
            return try XRPLPlanner.planSend(
                XRPLSendIntent(destination: request.destination, destinationTag: tag, drops: drops),
                signer: try .init(path: request.account.path, publicKey: request.account.publicKey),
                account: account, ledger: ledger, destination: destination, walletID: request.walletID
            )
        } catch {
            throw XRPLEngineSupport.translate(error)
        }
    }

    // MARK: Transmissao

    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String {
        try requireChain(chain)
        guard signed.count == 1, let transaction = signed.first else {
            throw SendEngineError.message(NetworkFailureText.inconsistent)
        }
        let ledger: XRPLLedgerState
        do {
            ledger = try await reader.ledgerState()
        } catch {
            throw XRPLEngineSupport.translate(error)
        }
        return try await Self.submit(transaction, validatedLedger: ledger.validatedLedgerIndex, reader: reader).id
    }

    /// Transmite uma transacao assinada e devolve o id calculado aqui e o resultado
    /// provisorio do servidor.
    ///
    /// Antes, confere que ela ainda pode entrar: o LastLedgerSequence gravado nela tem de
    /// estar a frente do ultimo ledger validado. Depois, guarda esse numero para o
    /// acompanhamento.
    static func submit(
        _ signed: SignedTransaction, validatedLedger: UInt32, reader: XRPLReader
    ) async throws -> (id: String, provisional: String?) {
        let id = try XRPLEngineSupport.localID(signed)
        guard let last = XRPLEngineSupport.lastLedgerSequence(signed.raw) else {
            throw SendEngineError.message(NetworkFailureText.inconsistent)
        }
        guard last > validatedLedger else {
            throw SendEngineError.message("O prazo da transação venceu antes do envio. Nada foi debitado. Revise de novo.")
        }
        do {
            let receipt = try await reader.broadcast(signed)
            guard receipt.id.uppercased() == id else { throw ReaderError.broadcastMismatch }
            XRPLSubmissions.lastLedger.remember(last, for: id)
            return (id, receipt.provisionalResult)
        } catch {
            throw XRPLEngineSupport.translate(error)
        }
    }

    /// Final quando dois servidores dizem o mesmo. Com o LastLedgerSequence guardado na
    /// transmissao, "nao achada" com a busca completa ate ele vira "venceu".
    func status(_ id: String, chain: Chain) async -> TransferStatus {
        guard chain == .xrpl else { return .pending }
        let last = XRPLSubmissions.lastLedger.recall(id.uppercased())
        guard let answer = try? await reader.status(of: id, lastLedgerSequence: last) else { return .pending }
        return Self.transfer(answer)
    }

    static func transfer(_ status: TransactionStatus) -> TransferStatus {
        switch status {
        case .notFound, .pending:
            return .pending
        case .confirmed(let block, _):
            return .confirmed(detail: block.map { "Validada no ledger \(EngineFormat.grouped($0)), que já é final." })
        case .failed(let reason):
            if reason == "expired" {
                return .failed(reason: "O prazo venceu antes de a transação entrar num ledger. Nada foi debitado.")
            }
            return .failed(reason: "A transação entrou num ledger e falhou. Só a taxa foi cobrada.")
        }
    }

    // MARK: Apoio

    private func requireChain(_ chain: Chain) throws {
        guard chain == .xrpl else { throw SendEngineError.message(NetworkFailureText.wrongAccount) }
    }

    /// O pedido e do XRP Ledger e em XRP: o planejador de envio so envia XRP.
    private func check(_ request: SendRequest) throws {
        try requireChain(request.chain)
        guard request.asset.chainID == Chain.xrpl.id, request.asset.kind == .native else {
            throw SendEngineError.message("Enviar tokens pelo XRP Ledger chega numa atualização em breve. XRP já funciona.")
        }
    }
}
