import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// A Atividade da TON: os eventos da tonapi pelo `TONReader`, com cada item julgado
/// contra envenenamento de endereco antes de chegar a tela.
struct TONActivitySource: ActivitySource {
    let reader: TONReader

    init(reader: TONReader = .shared) {
        self.reader = reader
    }

    func history(chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async throws -> [ActivityEntry] {
        guard chain.id == Chain.ton.id else { throw SendEngineError.unsupported(chain) }
        guard account.chainID == Chain.ton.id, case .success(let owner) = TONAddress.parse(account.address) else {
            throw SendEngineError.message(TONEngineText.keyMismatch)
        }
        let page: ActivityPage
        do {
            page = try await reader.history(address: owner.address)
        } catch {
            throw SendEngineError.message(TONEngineText.historyFailure)
        }
        return TONActivityScreen.entries(page.items, owner: owner.address)
    }
}

/// O julgamento de cada item do historico (docs/seguranca.md §4.10). O leitor ja deixa
/// de fora o recebimento de valor zero, o po abaixo do limite, o token fora da lista e o
/// que a tonapi marcou como golpe; o que ele entrega passa de novo por aqui.
///
/// O golpe visto ao vivo em 26/09/2026: 0,0001 TON, exatamente o limite de po do
/// leitor, de enderecos cujo fim na grafia amigavel (`...eT0D`, `...gZ5`) copia o fim de
/// destinos verdadeiros do dono. A grafia amigavel termina no CRC do endereco, e e ela
/// que a carteira mostra: a comparacao de sosia e feita nela, e tambem na raw.
enum TONActivityScreen {
    static func entries(_ items: [ActivityItem], owner: TONAddress) -> [ActivityEntry] {
        let trusted = trustedCounterparties(items, owner: owner)
        return items.map { item in
            ActivityEntry(
                id: item.id, chainID: item.chainID, direction: direction(item.direction), asset: item.asset,
                amount: item.amount, counterparty: item.counterparty, date: item.date, status: status(item.status),
                fee: item.fee, hash: item.hash, suspicious: isSuspicious(item, trusted: trusted),
                receivedAsset: item.receivedAsset, receivedAmount: item.receivedAmount
            )
        }
    }

    /// A propria conta e quem recebeu valor dela. Na TON o envio so sai da carteira com a
    /// assinatura do dono: nao existe o envio falso da Tron.
    static func trustedCounterparties(_ items: [ActivityItem], owner: TONAddress) -> [TONAddress] {
        var trusted = [owner]
        for item in items where item.direction == .sent && !item.amount.isZero {
            if let address = parsed(item.counterparty), !trusted.contains(address) { trusted.append(address) }
        }
        return trusted
    }

    static func isSuspicious(_ item: ActivityItem, trusted: [TONAddress]) -> Bool {
        switch item.direction {
        case .sent, .swap, .other:
            // Saiu da carteira do dono, com a assinatura dele: aparece sempre.
            return false
        case .received:
            if item.amount.isZero || !isListed(item.asset) { return true }
            guard let sender = parsed(item.counterparty) else { return false }
            if trusted.contains(sender) { return false }
            if item.amount <= dustLimit(item.asset) { return true }
            return isLookalike(sender, of: trusted)
        }
    }

    /// Sosia em qualquer das tres grafias, comparando grafia com grafia: raw, amigavel
    /// sem bounce (`UQ`, a das carteiras) e amigavel com bounce (`EQ`).
    static func isLookalike(_ address: TONAddress, of trusted: [TONAddress]) -> Bool {
        let spellings: [(TONAddress) -> String] = [
            { $0.raw }, { $0.friendly(bounceable: false) }, { $0.friendly(bounceable: true) },
        ]
        return spellings.contains { spell in
            AddressPoisoning.lookalike(spell(address), among: trusted.map(spell), chain: .ton) != nil
        }
    }

    static func parsed(_ text: String?) -> TONAddress? {
        guard let text, case .success(let parsed) = TONAddress.parse(text) else { return nil }
        return parsed.address
    }

    /// TON, ou um jetton da lista compilada com o mesmo mestre.
    static func isListed(_ asset: Asset) -> Bool {
        switch asset.kind {
        case .native: return asset.chainID == Chain.ton.id
        case .token(let contract): return TokenRegistry.find(chainID: Chain.ton.id, contract: contract) == asset
        case .issued: return false
        }
    }

    /// Po, inclusive: ate 0,0001 da unidade, ou 0,01 num stablecoin. O leitor usa o
    /// mesmo numero, mas esconde so o que fica abaixo dele.
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
