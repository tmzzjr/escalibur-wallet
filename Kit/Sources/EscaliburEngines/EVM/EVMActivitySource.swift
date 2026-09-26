import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation

/// O historico de uma rede EVM, pelo indexador publico do `EVMReader` (Blockscout; na
/// Avalanche, Routescan).
///
/// O leitor ja tira da pagina o que qualquer um empurra para o historico de qualquer
/// conta: recebimento de valor zero, de token fora da lista e po, e a "saida" que o dono
/// nao assinou (docs/seguranca.md 4.10). Aqui cada item passa de novo pelas mesmas
/// regras, mais a do endereco parecido, e o que casar sai com `suspicious = true` para a
/// tela esconder por padrao.
public struct EVMActivitySource: ActivitySource {
    public let chain: Chain
    let reader: EVMReader

    /// `nil` fora das redes EVM com indexador publico sem chave. A BNB Chain usa
    /// `EVMUnavailableActivitySource`.
    public init?(chain: Chain) {
        self.init(chain: chain, reader: .shared)
    }

    init?(chain: Chain, reader: EVMReader) {
        guard EVMEngineSupport.isSupported(chain), Endpoints.evmHistory[chain.id]?.isEmpty == false else { return nil }
        self.chain = chain
        self.reader = reader
    }

    public func history(chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async throws -> [ActivityEntry] {
        do {
            guard chain.id == self.chain.id else { throw EVMEngineFailure.wrongChain }
            let owner = try EVMEngineSupport.account(account, chain: chain).address
            let page = try await reader.history(chain: chain, address: owner)
            return EVMActivityScreen.entries(page, owner: owner, chain: chain)
        } catch {
            throw EVMEngineMessages.userFacing(error, .history, chain: self.chain)
        }
    }
}

/// Rede EVM sem indexador publico sem chave (BNB Chain: BscScan e Etherscan v2 exigem
/// plano pago para a rede 56). O motor de envio funciona; o historico diz que ainda nao
/// existe, em vez de mostrar uma lista vazia que pareceria "nenhum movimento".
public struct EVMUnavailableActivitySource: ActivitySource {
    public let chain: Chain

    public init(chain: Chain) {
        self.chain = chain
    }

    public func history(chain: Chain, account: DerivedAccount, usage: UTXOUsage?) async throws -> [ActivityEntry] {
        throw SendEngineError.message("O histórico da \(self.chain.name) ainda não está disponível nesta versão.")
    }
}

/// A triagem dos itens da Atividade.
enum EVMActivityScreen {
    static func entries(_ page: ActivityPage, owner: EVMAddress, chain: Chain) -> [ActivityEntry] {
        // O que o dono reconhece de vista: a propria conta e os enderecos para onde ele
        // mesmo enviou valor nesta pagina. O contrato de `ActivitySource` nao traz os
        // contatos nem o registro de envios do app.
        let known = [owner.checksummed] + page.items.filter { $0.direction == .sent && !$0.amount.isZero }.compactMap(\.counterparty)
        return page.items.map { item in
            ActivityEntry(
                id: item.id, chainID: item.chainID, direction: direction(item.direction), asset: item.asset, amount: item.amount,
                counterparty: item.counterparty, date: item.date, status: status(item.status), fee: item.fee, hash: item.hash,
                suspicious: isSuspicious(item, known: known, chain: chain)
            )
        }
    }

    /// So recebimentos sao escondidos. O que o dono assinou (envio, troca, aprovacao)
    /// aparece sempre: esconder isso esconderia um dreno. A saida que o dono nao assinou
    /// ja nao chega aqui (o leitor a conta como suspeita), salvo a transferencia real de
    /// um token da lista por um spender aprovado, que tem de aparecer.
    static func isSuspicious(_ item: ActivityItem, known: [String], chain: Chain) -> Bool {
        guard item.direction == .received else { return false }
        if item.amount.isZero { return true }
        guard isListed(item.asset, chain: chain) else { return true }
        let fromKnown = item.counterparty.map { counterparty in
            known.contains { Address.sameRecipient($0, counterparty, chain: chain) }
        } ?? false
        if !fromKnown, item.amount < dustLimit(item.asset) { return true }
        if let counterparty = item.counterparty, AddressPoisoning.lookalike(counterparty, among: known, chain: chain) != nil {
            return true
        }
        return false
    }

    /// A moeda nativa da rede ou um token da lista curada, com os mesmos dados.
    static func isListed(_ asset: Asset, chain: Chain) -> Bool {
        guard asset.chainID == chain.id else { return false }
        switch asset.kind {
        case .native: return asset == Asset.native(chain)
        case .token(let contract): return TokenRegistry.find(chainID: chain.id, contract: contract) == asset
        case .issued: return false
        }
    }

    /// O mesmo limite de po do leitor (`ActivityRules.dustLimit`, interno ao modulo de
    /// rede): 0,0001 da unidade, ou 0,01 em stablecoin.
    static func dustLimit(_ asset: Asset) -> BigUInt {
        let places = asset.isStablecoin ? max(0, asset.decimals - 2) : max(0, asset.decimals - 4)
        return BigUInt.power(of: 10, places)
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
