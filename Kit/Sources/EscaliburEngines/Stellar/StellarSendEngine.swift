import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// Enviar XLM e os ativos da lista curada pela Stellar.
///
/// Junta o `StellarReader` (sequence da conta confirmada por dois provedores, destino
/// lido nos dois, com o memo obrigatorio do SEP-29 valendo se qualquer um disser) e o
/// `StellarPlanner` (CreateAccount para destino novo, reserva, teto de taxa, validade de
/// 180 s). O memo sai de `SendRequest.tag`. Nada e assinado aqui.
struct StellarSendEngine: SendEngine {
    let reader: StellarReader

    init(reader: StellarReader = StellarReader()) {
        self.reader = reader
    }

    // MARK: Destino

    /// Se a conta existe e se exige memo. Conta que nao existe recebe so XLM, por um
    /// CreateAccount de pelo menos o minimo do planejador (duas reservas de base).
    func destination(_ address: String, chain: Chain) async throws -> DestinationInfo {
        try requireChain(chain)
        guard case .success(let parsed) = Address.validate(address, for: .stellar) else {
            throw SendEngineError.message(StellarPlanError.invalidDestination(.malformed).reason)
        }
        do {
            let state = try await reader.destination(address)
            if state.exists {
                // Endereco M ja carrega o id do cliente: o SEP-29 nao se aplica a ele.
                let requiresMemo = state.memoRequired && parsed.tag == nil
                return DestinationInfo(
                    exists: true, requiresTag: requiresMemo,
                    note: requiresMemo ? "Esta conta exige memo (SEP-29). Sem ele o depósito se perde." : nil
                )
            }
            let minimum = try StellarEngineSupport.activationMinimum(try await reader.networkState())
            return DestinationInfo(
                exists: false, activationMinimum: minimum,
                note: "Esta conta ainda não existe na Stellar. O primeiro envio cria a conta, só pode ser em XLM e precisa ser de pelo menos \(StellarEngineSupport.xlm(minimum))."
            )
        } catch {
            throw StellarEngineSupport.translate(error)
        }
    }

    // MARK: Maximo

    /// XLM: saldo menos a reserva da conta e das subentradas, o que ofertas ja
    /// prometeram vender e a taxa. Ativo emitido: o saldo livre da linha de confianca.
    func spendable(_ request: SendRequest) async throws -> Spendable {
        try requireChain(request.chain)
        let source = try StellarEngineSupport.source(request.account)
        let asset = try StellarEngineSupport.stellar(request.asset)
        do {
            async let owner = reader.ownerAccount(source.account)
            async let networkState = reader.networkState()
            let network = try await networkState
            guard let account = try await owner else {
                return Spendable(amount: BigUInt(), reserveNote: StellarEngineSupport.accountMissing)
            }
            guard let fee = StellarEngineSupport.feePerOperation(network) else { throw StellarPlanError.feeAboveCeiling }
            _ = try StellarEngineSupport.activationMinimum(network)
            let free = account.spendable(baseReserve: network.baseReserve)
            if asset.isNative {
                let locked = account.balance.subtractingReportingUnderflow(free) ?? BigUInt()
                return Spendable(
                    amount: free.subtractingReportingUnderflow(fee) ?? BigUInt(),
                    reserveNote: "\(StellarEngineSupport.xlm(locked)) ficam reservados pela rede enquanto a conta, as linhas de confiança e as ofertas dela existirem.",
                    feeNote: "Já descontada a taxa máxima da rede, de \(StellarEngineSupport.xlm(fee))."
                )
            }
            guard let line = account.trustline(for: asset) else {
                return Spendable(amount: BigUInt(), reserveNote: "A conta ainda não aceita \(asset.code).")
            }
            return Spendable(
                amount: line.available,
                feeNote: free >= fee ? "A taxa da rede sai em XLM." : "Falta XLM livre para pagar a taxa da rede."
            )
        } catch {
            throw StellarEngineSupport.translate(error)
        }
    }

    // MARK: Plano

    func plan(_ request: SendRequest) async throws -> SigningPlan {
        try requireChain(request.chain)
        let source = try StellarEngineSupport.source(request.account)
        let asset = try StellarEngineSupport.stellar(request.asset)
        let memo = try StellarEngineSupport.memo(request.tag)
        do {
            async let owner = reader.ownerAccount(source.account)
            async let networkState = reader.networkState()
            async let destinationState = reader.destination(request.destination)
            let network = try await networkState
            let destination = try await destinationState
            guard let account = try await owner else { throw SendEngineError.message(StellarEngineSupport.accountMissing) }
            let context = StellarPlanContext(
                walletID: request.walletID, source: source, account: account, network: network,
                allowedAssets: StellarEngineSupport.allowedAssets
            )
            let amount = request.sendAll ? try Self.sendAllAmount(asset, account: account, network: network) : request.amount
            if asset.isNative {
                return try StellarPlanner.planSendNative(
                    amount: amount, to: request.destination, memo: memo, destination: destination, context: context
                )
            }
            return try StellarPlanner.planSendAsset(
                asset, amount: amount, to: request.destination, memo: memo, destination: destination, context: context
            )
        } catch {
            throw StellarEngineSupport.translate(error)
        }
    }

    /// "Enviar tudo" com o estado lido agora, nao com o maximo que a tela mostrou antes.
    static func sendAllAmount(_ asset: StellarAsset, account: StellarAccountState, network: StellarNetworkState) throws -> BigUInt {
        if asset.isNative {
            guard let fee = StellarEngineSupport.feePerOperation(network) else { throw StellarPlanError.feeAboveCeiling }
            return account.spendable(baseReserve: network.baseReserve).subtractingReportingUnderflow(fee) ?? BigUInt()
        }
        return account.trustline(for: asset)?.available ?? BigUInt()
    }

    // MARK: Transmissao

    func broadcast(_ signed: [SignedTransaction], chain: Chain) async throws -> String {
        try requireChain(chain)
        guard signed.count == 1, let transaction = signed.first else {
            throw SendEngineError.message(NetworkFailureText.inconsistent)
        }
        return try await StellarEngineSupport.broadcast(transaction, reader: reader)
    }

    /// Final quando os dois provedores dizem o mesmo; na Stellar o ledger fechado ja e
    /// final. Sem resposta, pendente.
    func status(_ id: String, chain: Chain) async -> TransferStatus {
        guard chain == .stellar, let answer = try? await reader.status(hash: id) else { return .pending }
        return ChainTransferStatus.transfer(answer, finalLedger: true)
    }

    private func requireChain(_ chain: Chain) throws {
        guard chain == .stellar else { throw SendEngineError.message(NetworkFailureText.wrongAccount) }
    }
}
