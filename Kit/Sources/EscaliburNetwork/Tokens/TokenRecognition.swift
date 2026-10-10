import EscaliburChains
import EscaliburCore
import Foundation

/// Um token fora da lista que o CoinGecko lista com o contrato exato. Reconhecido nao e
/// verificado: so reorganiza a tela (sai de "Outros tokens", com nome, simbolo e logo do
/// CoinGecko) e nao destrava nenhuma acao. Troca e aprovacao continuam so na lista
/// curada, e o envio continua mostrando o contrato inteiro.
public struct TokenIdentity: Codable, Sendable, Hashable {
    public let assetID: String
    public let chainID: String
    /// A plataforma no CoinGecko ("ethereum", "binance-smart-chain").
    public let platform: String
    /// O contrato na forma canonica da rede (minusculo so na EVM).
    public let contract: String
    public let coingeckoID: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public let image: URL?
    public let checkedAt: Date
}

/// As regras do reconhecimento, da revisao de seguranca de 10/10/2026:
///   - o contrato listado pelo CoinGecko naquela plataforma e o mesmo, na forma canonica;
///   - as casas decimais listadas sao as da rede;
///   - sem pre-listagem e sem aviso publico do CoinGecko sobre o token;
///   - nome e simbolo do CoinGecko, limpos, passam pelo TokenSafety (link, isca,
///     caractere escondido, imitacao);
///   - id do CoinGecko ou simbolo igual ao de um token da lista, de uma moeda nativa ou
///     de um simbolo protegido: fica em "Outros tokens". O USDT da Aptos tem o id
///     `tether`, e reconhecido ele cairia dentro da linha do USDT conferido.
/// O reconhecimento vale 7 dias; um "nao listado" do CoinGecko derruba na hora, e falha
/// de rede mantem o que havia, sem nunca promover.
public enum TokenRecognitionRules {
    public static let lifetime: TimeInterval = 7 * 86_400

    static func canonical(_ contract: String, chainID: String) -> String {
        Chain.find(chainID)?.family == .evm ? contract.lowercased() : contract
    }

    public static func identity(
        asset: Asset, platform: String, id: String?, symbol: String?, name: String?, listedContract: String?, listedDecimals: Int?,
        previewListing: Bool?, publicNotice: String?, image: URL?, now: Date
    ) -> TokenIdentity? {
        guard case .token(let contract) = asset.kind,
              let id, !id.isEmpty, id.count <= 120,
              let listedContract, canonical(listedContract, chainID: asset.chainID) == canonical(contract, chainID: asset.chainID),
              listedDecimals == asset.decimals,
              previewListing != true,
              (publicNotice ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let cleanSymbol = TokenSafety.clean((symbol ?? "").uppercased(), limit: TokenSafety.symbolLimit)
        let cleanName = TokenSafety.clean(name ?? "", limit: TokenSafety.nameLimit)
        guard !cleanSymbol.isEmpty, !cleanName.isEmpty, !collides(id: id, symbol: cleanSymbol),
              TokenSafety.reasons(
                  symbol: cleanSymbol, name: cleanName, chainID: asset.chainID, kind: asset.kind, amount: BigUInt(1),
                  decimals: asset.decimals, unsolicited: false
              ).isEmpty
        else { return nil }
        return TokenIdentity(
            assetID: asset.id, chainID: asset.chainID, platform: platform, contract: canonical(contract, chainID: asset.chainID),
            coingeckoID: id, name: cleanName, symbol: cleanSymbol, decimals: asset.decimals,
            image: image.flatMap { ImageLoader.isAllowed($0) ? $0 : nil }, checkedAt: now
        )
    }

    /// O id ou o simbolo colide com o que a lista curada ou as moedas nativas ja usam.
    static func collides(id: String, symbol: String) -> Bool {
        let curatedIDs = Set(TokenRegistry.tokens.compactMap(\.coingeckoID) + Chain.all.map(\.coingeckoID))
        if curatedIDs.contains(id) { return true }
        var protected = Set(TokenRegistry.tokens.map { TokenSafety.normalizedSymbol($0.symbol) })
        protected.formUnion(Chain.all.map { TokenSafety.normalizedSymbol($0.nativeSymbol) })
        protected.formUnion(["USDT", "USDC", "BTC", "ETH", "WETH", "WBTC"])
        return protected.contains(TokenSafety.normalizedSymbol(symbol))
    }

    /// O reconhecimento guardado ainda vale para este ativo: mesmo id, rede, contrato e
    /// casas, e dentro dos 7 dias.
    public static func isValid(_ identity: TokenIdentity, for asset: Asset, now: Date = .now) -> Bool {
        guard case .token(let contract) = asset.kind else { return false }
        return identity.assetID == asset.id && identity.chainID == asset.chainID
            && identity.contract == canonical(contract, chainID: asset.chainID) && identity.decimals == asset.decimals
            && now.timeIntervalSince(identity.checkedAt) < lifetime && now >= identity.checkedAt
    }
}
