import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// A Atividade da Tron: o historico da TronGrid pelo `TronReader`, com cada item
/// julgado contra envenenamento de endereco antes de chegar a tela.
struct TronActivitySource: ActivitySource {
    let reader: TronReader

    init(reader: TronReader = .shared) {
        self.reader = reader
    }

    func history(chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async throws -> [ActivityEntry] {
        guard chain.id == Chain.tron.id else { throw SendEngineError.unsupported(chain) }
        guard account.chainID == Chain.tron.id, let owner = TronAddress(base58: account.address) else {
            throw SendEngineError.message(TronEngineText.keyMismatch)
        }
        let page: ActivityPage
        do {
            page = try await reader.history(address: owner)
        } catch {
            throw SendEngineError.message(TronEngineText.historyFailure)
        }
        return TronActivityScreen.entries(page.items, owner: owner.base58)
    }
}

/// O julgamento de cada item do historico (docs/seguranca.md §4.10). O leitor ja deixa
/// de fora o recebimento de valor zero, o po abaixo do limite e o token fora da lista;
/// o que ele entrega passa de novo por aqui, com as regras que so fecham olhando a
/// pagina inteira.
///
/// O golpe classico da Tron: `transferFrom(dono, sosia, 0)` no contrato do USDT. Qualquer
/// um pode chamar, o contrato aceita valor zero sem autorizacao, e o evento `Transfer`
/// sai com `from` igual ao dono. No historico da TronGrid isso aparece como um ENVIO de
/// 0 USDT para um endereco parecido com o de um destino verdadeiro, pronto para ser
/// copiado. A transacao nao foi assinada pelo dono, e o leitor so poe taxa num envio
/// que esta na lista de transacoes da propria conta: envio de zero sem taxa e falso.
enum TronActivityScreen {
    static func entries(_ items: [ActivityItem], owner: String) -> [ActivityEntry] {
        let trusted = trustedCounterparties(items, owner: owner)
        return items.map { item in
            ActivityEntry(
                id: item.id, chainID: item.chainID, direction: direction(item.direction), asset: item.asset,
                amount: item.amount, counterparty: item.counterparty, date: item.date, status: status(item.status),
                fee: item.fee, hash: item.hash, suspicious: isSuspicious(item, trusted: trusted)
            )
        }
    }

    /// A propria conta e quem recebeu valor dela numa transacao que ela assinou (o leitor
    /// so poe taxa no que a conta assinou). E contra estes que o sosia e medido.
    static func trustedCounterparties(_ items: [ActivityItem], owner: String) -> [String] {
        var trusted = [owner]
        for item in items where item.direction == .sent && item.fee != nil && !item.amount.isZero {
            if let counterparty = item.counterparty, !trusted.contains(counterparty) { trusted.append(counterparty) }
        }
        return trusted
    }

    static func isSuspicious(_ item: ActivityItem, trusted: [String]) -> Bool {
        switch item.direction {
        case .sent:
            // Valor que saiu da conta aparece sempre: esconder isso esconderia um dreno.
            // Envio de zero sem taxa e o `transferFrom` falso descrito acima.
            return item.amount.isZero && item.fee == nil
        case .received:
            if item.amount.isZero || !isListed(item.asset) { return true }
            guard let counterparty = item.counterparty else { return false }
            if trusted.contains(counterparty) { return false }
            if item.amount <= dustLimit(item.asset) { return true }
            return AddressPoisoning.lookalike(counterparty, among: trusted, chain: .tron) != nil
        case .swap, .other:
            // Acao da propria conta (aprovacao, stake, chamada de contrato): foi ela que assinou.
            return false
        }
    }

    /// TRX, ou um token da lista compilada com o mesmo contrato.
    static func isListed(_ asset: Asset) -> Bool {
        switch asset.kind {
        case .native: return asset.chainID == Chain.tron.id
        case .token(let contract): return TokenRegistry.find(chainID: Chain.tron.id, contract: contract) == asset
        case .issued: return false
        }
    }

    /// Po, inclusive: ate 0,0001 da unidade, ou 0,01 num stablecoin. O leitor usa o
    /// mesmo numero, mas esconde so o que fica abaixo dele; o golpe manda exatamente o
    /// limite (visto ao vivo na TON em 26/09/2026), e aqui ele tambem conta.
    static func dustLimit(_ asset: Asset) -> BigUInt {
        BigUInt.power(of: 10, max(0, asset.decimals - (asset.isStablecoin ? 2 : 4)))
    }

    static func direction(_ direction: ActivityItem.Direction) -> ActivityEntry.Direction {
        switch direction {
        case .sent: return .sent
        case .received: return .received
        case .swap: return .swap
        case .other: return .other
        }
    }

    static func status(_ status: ActivityItem.Status) -> ActivityEntry.Status {
        switch status {
        case .pending: return .pending(nil)
        case .confirmed: return .confirmed
        case .failed: return .failed(nil)
        }
    }
}
