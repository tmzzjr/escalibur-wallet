import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// O que os motores de Bitcoin, Litecoin e Dogecoin tem em comum: a conta a partir da
/// conta derivada, os enderecos ja usados, o troco, a taxa escolhida e as frases de erro.
enum UTXOEngineSupport {
    /// Gap limit do BIP-44, o mesmo das outras carteiras.
    static let gapLimit = 20

    // MARK: Conta

    /// A conta UTXO da conta derivada: esquema pelo `purpose` do caminho (84 no Bitcoin e
    /// no Litecoin, 44 no Dogecoin, que nao tem segwit), numero da conta e a xpub guardada.
    ///
    /// Confere que a xpub gera o endereco da propria conta derivada. Uma xpub trocada ou
    /// corrompida nos metadados faria o troco ir para enderecos que a seed nao assina.
    static func account(_ derived: DerivedAccount, chain: Chain) throws -> UTXOAccount {
        let h = DerivationPath.hardenedOffset
        let c = derived.path.components
        guard derived.chainID == chain.id, c.count == 5, c[0] >= h, c[1] == chain.coinType | h, c[2] >= h, c[3] <= 1, c[4] < h,
              let kind = UTXOInputKind(purpose: c[0] - h)
        else { throw SendEngineError.message(NetworkFailureText.wrongAccount) }
        guard let xpub = derived.accountXPub else {
            throw SendEngineError.message("Falta a chave pública desta conta nos dados da carteira. Nada foi montado.")
        }
        let account: UTXOAccount
        do {
            account = try UTXOAccount(chain: chain, kind: kind, account: c[2] - h, accountKey: xpub)
        } catch {
            throw SendEngineError.message(NetworkFailureText.wrongAccount)
        }
        guard (try? account.address(change: c[3] == 1, index: c[4]).address) == derived.address else {
            throw SendEngineError.message("A chave pública guardada não gera o endereço desta conta. Por segurança, nada foi montado.")
        }
        return account
    }

    /// Os caminhos que o app ja registrou como usados (`UTXOUsage`: quantos indices de
    /// recebimento e de troco ja sairam). A varredura nao pergunta de novo por eles.
    static func knownUsed(_ usage: UTXOUsage?, account: UTXOAccount) -> Set<DerivationPath> {
        guard let usage else { return [] }
        var paths = Set<DerivationPath>()
        for (branch, count) in [(UInt32(0), usage.receiveUsed), (UInt32(1), usage.changeUsed)] {
            let limit = min(UInt32(clamping: max(0, count)), UTXOReader.maxAddressesPerBranch)
            for index in 0..<limit { paths.insert(account.path.appending(branch).appending(index)) }
        }
        return paths
    }

    /// Quantos indices a varredura achou usados em cada cadeia (o maior usado mais um).
    static func discoveredUsage(_ discovery: UTXODiscovery) -> UTXOUsage {
        UTXOUsage(
            receiveUsed: discovery.usedReceiveIndices.max().map { Int($0) + 1 } ?? 0,
            changeUsed: discovery.usedChangeIndices.max().map { Int($0) + 1 } ?? 0
        )
    }

    static func merged(_ a: UTXOUsage, _ b: UTXOUsage) -> UTXOUsage {
        UTXOUsage(receiveUsed: max(a.receiveUsed, b.receiveUsed), changeUsed: max(a.changeUsed, b.changeUsed))
    }

    /// O indice do troco: o proximo que o app registrou, ou o primeiro livre que a
    /// varredura achou, o que for maior, pulando qualquer um que a varredura viu usado.
    /// O maior dos dois cobre a transacao anterior que o provedor ainda nao indexou.
    static func changeIndex(usage: UTXOUsage?, discovery: UTXODiscovery) throws -> UInt32 {
        let used = Set(discovery.usedChangeIndices)
        var index = max(UInt32(clamping: max(0, usage?.changeUsed ?? 0)), discovery.nextChange.index)
        while used.contains(index) { index += 1 }
        guard index < UTXOReader.maxAddressesPerBranch else { throw SendEngineError.message(NetworkFailureText.scanLimit) }
        return index
    }

    static func changeAddress(_ account: UTXOAccount, index: UInt32) throws -> UTXOChangeAddress {
        let derived = try account.address(change: true, index: index)
        return UTXOChangeAddress(address: derived.address, path: derived.path, publicKey: derived.publicKey, accountKey: account.accountKey)
    }

    // MARK: Taxa

    static func rate(_ level: FeeLevel, in fees: UTXOFeeLevels) -> UTXOFeeRate {
        switch level {
        case .slow: return fees.slow
        case .normal: return fees.normal
        case .fast: return fees.fast
        }
    }

    /// "1,069 sat/vB"; no Dogecoin, que conta por kB, "0,01 DOGE/kB".
    static func rateText(_ rate: UTXOFeeRate, chain: Chain) -> String {
        if chain.id == Chain.dogecoin.id {
            return "\(EngineFormat.decimal(BigUInt(rate.satPerKvB), decimals: 8)) DOGE/kB"
        }
        return "\(EngineFormat.decimal(BigUInt(rate.satPerKvB), decimals: 3)) sat/vB"
    }

    static func summary(_ plan: SigningPlan) -> UTXOSendSummary? {
        guard plan.transactions.count == 1, let transaction = plan.transactions.first as? UTXOSignableTransaction else { return nil }
        return transaction.summary
    }

    // MARK: Transmissao

    /// O txid calculado aqui dos bytes assinados: a transacao tem de ser da rede, estar
    /// na forma canonica e dizer de si o mesmo id que carrega.
    static func localTxid(_ signed: SignedTransaction, chain: Chain) throws -> String {
        guard signed.chainID == chain.id, let transaction = try? UTXOTransaction(parsing: signed.raw),
              transaction.serialized() == signed.raw, transaction.txid.hex == signed.id.lowercased()
        else { throw SendEngineError.message(NetworkFailureText.inconsistent) }
        return transaction.txid.hex
    }

    // MARK: Erros

    static func text(_ error: UTXOPlanError, chain: Chain) -> String {
        switch error {
        case .wrongFamily:
            return NetworkFailureText.wrongAccount
        case .invalidDestination(let problem):
            return destinationText(problem, chain: chain)
        case .amountZero:
            return "O valor precisa ser maior que zero."
        case .amountAboveMaximum:
            return "O valor passa do máximo que a rede \(chain.name) aceita."
        case .amountBelowDust:
            return "O valor fica abaixo do mínimo que a rede repassa, depois da taxa. Envie um valor maior."
        case .insufficientFunds:
            return "Saldo insuficiente para este valor mais a taxa da rede."
        case .noSpendableCoins:
            return "Nenhuma moeda confirmada cobre a taxa da rede agora. Moedas pequenas ou ainda sem confirmação ficam de fora."
        case .duplicateCoin, .previousTransactionMalformed, .previousTransactionMismatch, .outputIndexOutOfRange, .coinNotOurs,
             .unsupportedCoinType, .coinValueOutOfRange, .balanceOutOfRange, .badDerivationPath, .mixedAccounts, .coinControlUnknown:
            return "Uma das moedas lidas não confere com a transação que a criou. Por segurança, nada foi montado."
        case .needTwoFeeEstimates:
            return NetworkFailureText.fewSources
        case .feeRateBelowMinimum:
            return "A taxa escolhida fica abaixo do mínimo da rede."
        case .feeRateAboveCeiling:
            return "A taxa escolhida passa do teto da carteira, que é o dobro da maior estimativa da rede."
        case .feeAboveAbsoluteCap:
            return "A taxa deste envio passaria do teto absoluto da carteira. Nada foi montado."
        case .changeRequired, .changeNotOurs, .changeAccountNotSpent:
            return "O endereço de troco não confere com a chave da carteira. Por segurança, nada foi montado."
        case .invalidTipHeight:
            return NetworkFailureText.malformed
        case .transactionTooLarge:
            return "Este envio junta moedas demais para uma transação só. Envie um valor menor."
        case .internalCheckFailed:
            return "A conferência final da transação não fechou. Nada foi montado."
        }
    }

    static func destinationText(_ problem: Address.Problem, chain: Chain) -> String {
        switch problem {
        case .empty, .malformed: return "Este não é um endereço da rede \(chain.name)."
        case .otherNetwork(let other): return "Este endereço é da rede \(other.name), não da rede \(chain.name)."
        case .badChecksum: return "Um caractere deste endereço não confere. Copie de novo, inteiro."
        case .unsupportedType: return "Este tipo de endereço ainda não recebe envios desta carteira."
        }
    }

    /// Qualquer erro do caminho de envio, na frase da tela.
    static func translate(_ error: Error, chain: Chain) -> Error {
        if let planError = error as? UTXOPlanError { return SendEngineError.message(text(planError, chain: chain)) }
        return NetworkFailureText.error(error)
    }
}
