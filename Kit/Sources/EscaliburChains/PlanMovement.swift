import EscaliburCore
import Foundation

// O que sai e o que entra num plano, com o ativo pelo mesmo id que a tela usa
// (`Asset.id`). Cada planejador preenche a partir dos valores que ele mesmo gravou na
// transacao, nunca da intencao: e o que o app confere contra o pedido do dono antes de
// revisar e de novo antes de assinar.

extension PlanReview.Movement {
    /// A moeda nativa da rede.
    static func native(_ chain: Chain, _ amount: BigUInt) -> Self {
        Self(assetID: Asset.native(chain).id, amount: amount)
    }

    /// Um token por contrato (EVM, Tron, TON) ou mint (Solana).
    ///
    /// O id e o do ativo da lista curada com esse contrato. No EVM a lista guarda o
    /// endereco com as maiusculas do EIP-55, e a comparacao ignora caixa; nas outras
    /// redes o endereco e sensivel a caixa e a comparacao e exata. Fora da lista, o id
    /// e rede e contrato como vieram, que nenhum ativo da tela tem: a conferencia do
    /// app recusa, que e o certo para token que a carteira nao conhece.
    static func token(_ chain: Chain, contract: String, _ amount: BigUInt) -> Self {
        token(chain, amount, fallback: contract) { listed in
            chain.family == .evm ? listed.lowercased() == contract.lowercased() : listed == contract
        }
    }

    /// Um token da lista reconhecido por uma regra propria da rede (na TON, o mesmo
    /// mestre do jetton escrito em outra forma de endereco).
    static func token(_ chain: Chain, _ amount: BigUInt, fallback: String, matching: (String) -> Bool) -> Self {
        let listed = TokenRegistry.tokens.first { asset in
            guard asset.chainID == chain.id, case .token(let contract) = asset.kind else { return false }
            return matching(contract)
        }
        return Self(assetID: listed?.id ?? "\(chain.id):\(fallback)", amount: amount)
    }

    /// XRP Ledger e Stellar: codigo mais emissor, como `Asset.id` escreve.
    static func issued(_ chain: Chain, code: String, issuer: String, _ amount: BigUInt) -> Self {
        let listed = TokenRegistry.tokens.first { asset in
            guard asset.chainID == chain.id, case .issued(let listedCode, let listedIssuer) = asset.kind else { return false }
            return listedIssuer == issuer && listedCode.uppercased() == code.uppercased()
        }
        return Self(assetID: listed?.id ?? "\(chain.id):\(code):\(issuer)", amount: amount)
    }
}

extension Asset {
    /// O ativo da lista (ou a moeda nativa) com este id. So para texto de revisao
    /// derivado de um movimento ja validado.
    static func listed(id: String) -> Asset? {
        for chain in Chain.all {
            if let asset = TokenRegistry.assets(on: chain).first(where: { $0.id == id }) { return asset }
        }
        return nil
    }
}
