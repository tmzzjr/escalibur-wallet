import EscaliburCore
import Foundation

/// O que a carteira acha de um token que nao esta na lista conferida.
///
/// Token fora da lista aparece, porque e da conta do dono, mas o nome e o simbolo vieram
/// de quem criou o contrato, e qualquer um cria token com qualquer nome. O golpe mais
/// comum que chega sozinho numa carteira e o token-isca: nome com um site ("claim at
/// www..."), simbolo igual ao do USDT com outro contrato, ou poeira mandada sem ninguem
/// pedir para o endereco aparecer no historico. Esses ficam atras de "Mostrar
/// suspeitos". A conferencia e local, sem rede: so texto, saldo e o que a fonte disse.
public enum TokenSafety {
    public enum Reason: String, Codable, Sendable, Hashable, CaseIterable {
        /// Nome ou simbolo com endereco de site, @ de rede social ou "://".
        case link
        /// Palavra de isca: claim, visit, reward, airdrop, bonus, voucher e parecidas.
        case bait
        /// Simbolo que, depois de desfazer letras parecidas, e o de uma stablecoin, de
        /// uma moeda nativa ou de um token da lista nesta rede, com outro contrato.
        case imitation
        /// Menos de um milesimo de unidade, chegado sem pedir (rede onde qualquer um
        /// manda token para qualquer endereco).
        case dust
        /// A propria fonte marcou como golpe (lista negra da tonapi, reputacao do
        /// Blockscout).
        case flaggedBySource
        /// Caractere invisivel ou de direcao de texto no nome ou no simbolo.
        case hiddenCharacters
    }

    /// Os motivos para esconder o token. Vazio: aparece em "Outros tokens", ainda
    /// marcado como nao verificado.
    ///
    /// `unsolicited`: na rede, um token pode chegar sem o dono pedir (EVM, Solana, Tron,
    /// TON). No XRP Ledger e na Stellar so chega com linha de confianca aberta pelo dono.
    public static func reasons(
        symbol: String, name: String, chainID: String, kind: Asset.Kind, amount: BigUInt, decimals: Int,
        unsolicited: Bool, flaggedBySource: Bool = false
    ) -> [Reason] {
        var out: [Reason] = []
        let texts = [symbol, name]
        if texts.contains(where: hasHiddenCharacters) { out.append(.hiddenCharacters) }
        if texts.contains(where: hasLink) { out.append(.link) }
        if texts.contains(where: hasBait) { out.append(.bait) }
        if imitates(symbol: symbol, chainID: chainID, kind: kind) { out.append(.imitation) }
        if unsolicited, isDust(amount, decimals: decimals) { out.append(.dust) }
        if flaggedBySource { out.append(.flaggedBySource) }
        return out
    }

    /// Redes em que um token chega sem o dono pedir.
    public static func arrivesUnsolicited(_ chain: Chain) -> Bool {
        switch chain.family {
        case .evm, .solana, .tron, .ton, .sui, .aptos, .cardano: return true
        case .xrpl, .stellar, .utxo, .polkadot, .near: return false
        }
    }

    // MARK: Regras

    /// Sites, arrobas e esquemas de URL. "USDC.e" e "BUSD.e" (pontes conhecidas) nao
    /// casam: o dominio pede pelo menos duas letras depois do ponto.
    static func hasLink(_ text: String) -> Bool {
        let lower = fold(text).lowercased()
        if lower.contains("://") || lower.contains("www") || lower.contains("t.me/") || lower.contains("@") { return true }
        return lower.range(of: #"[a-z0-9-]{2,}\.[a-z]{2,}(\b|/)"#, options: .regularExpression) != nil
    }

    static let baitWords = [
        "claim", "visit", "reward", "airdrop", "voucher", "bonus", "gift", "giveaway", "redeem", "eligible", "unlock",
        "access", "distribution", "free", "winner", "prize", "swap your", "bridge for", "swap for",
        "resgate", "resgatar", "recompensa", "brinde", "ganhe", "premio", "prêmio",
    ]

    static func hasBait(_ text: String) -> Bool {
        let lower = fold(text).lowercased()
        if baitWords.contains(where: { lower.contains($0) }) { return true }
        // Emoji e simbolos graficos (✅, 🎁, 💵) sao marca registrada da isca.
        return text.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .otherSymbol && !["₮"].contains(Character(scalar))
        }
    }

    static func hasHiddenCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { invisible.contains($0) || ($0.properties.generalCategory == .format) }
    }

    static let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{200E}\u{200F}")

    /// Menos de 0,001 unidade, e mais que zero.
    static func isDust(_ amount: BigUInt, decimals: Int) -> Bool {
        guard !amount.isZero, decimals >= 3, decimals <= 36 else { return false }
        return amount * BigUInt(1000) < BigUInt.power(of: 10, decimals)
    }

    /// Simbolos que nenhum token fora da lista pode usar: os das stablecoins da lista
    /// (USDT, USDC, DAI...), os das moedas nativas (ETH, SOL, TRX...) e os dos tokens da
    /// lista na mesma rede.
    static func imitates(symbol: String, chainID: String, kind: Asset.Kind) -> Bool {
        let key = normalizedSymbol(symbol)
        guard !key.isEmpty, TokenRegistry.listed(chainID: chainID, kind: kind) == nil else { return false }
        return protectedSymbols(chainID: chainID).contains(key)
    }

    static func protectedSymbols(chainID: String) -> Set<String> {
        var out = Set(TokenRegistry.tokens.filter(\.isStablecoin).map { normalizedSymbol($0.symbol) })
        out.formUnion(Chain.all.map { normalizedSymbol($0.nativeSymbol) })
        out.formUnion(TokenRegistry.tokens.filter { $0.chainID == chainID }.map { normalizedSymbol($0.symbol) })
        out.formUnion(["USDT", "USDC", "BTC", "ETH", "WETH", "WBTC"])
        return out
    }

    /// O simbolo como ele se le: forma de compatibilidade do Unicode (letra de largura
    /// cheia e negrito matematico viram letra comum), cirilico e grego parecidos com
    /// latino trocados pelo latino, so letras e digitos, em maiuscula. "UЅDС" (S e C
    /// cirilicos), "$USDC" e "ＵＳＤＴ" viram "USDC" e "USDT".
    public static func normalizedSymbol(_ symbol: String) -> String {
        String(fold(symbol).uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    static func fold(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
        var out = String.UnicodeScalarView()
        for scalar in compatible.unicodeScalars {
            if let latin = lookalikes[scalar] { out.append(contentsOf: latin.unicodeScalars) } else { out.append(scalar) }
        }
        return String(out)
    }

    /// Letras de outros alfabetos que, numa fonte comum, sao identicas a uma latina.
    static let lookalikes: [Unicode.Scalar: String] = {
        let pairs: [(String, String)] = [
            // Cirilico
            ("А", "A"), ("В", "B"), ("С", "C"), ("Е", "E"), ("Н", "H"), ("І", "I"), ("Ј", "J"), ("К", "K"), ("М", "M"),
            ("О", "O"), ("Р", "P"), ("Ѕ", "S"), ("Т", "T"), ("Х", "X"), ("У", "Y"), ("Ү", "Y"), ("Ԁ", "D"), ("Ԛ", "Q"), ("Ԝ", "W"),
            ("а", "a"), ("с", "c"), ("е", "e"), ("о", "o"), ("р", "p"), ("х", "x"), ("у", "y"), ("ѕ", "s"), ("і", "i"),
            ("ј", "j"), ("һ", "h"), ("ԁ", "d"), ("ԛ", "q"), ("ԝ", "w"), ("ɡ", "g"),
            // Grego
            ("Α", "A"), ("Β", "B"), ("Ε", "E"), ("Ζ", "Z"), ("Η", "H"), ("Ι", "I"), ("Κ", "K"), ("Μ", "M"), ("Ν", "N"),
            ("Ο", "O"), ("Ρ", "P"), ("Τ", "T"), ("Υ", "Y"), ("Χ", "X"), ("ο", "o"), ("ν", "v"), ("ι", "i"),
            // Moedas e sinais que imitam letra
            ("₮", "T"), ("Ꭲ", "T"), ("Ꮪ", "S"), ("Ꮯ", "C"), ("Ꭰ", "D"), ("Ɗ", "D"), ("Ѕ", "S"),
        ]
        var map: [Unicode.Scalar: String] = [:]
        for (from, to) in pairs { if let scalar = from.unicodeScalars.first { map[scalar] = to } }
        return map
    }()

    // MARK: Texto que vem de fora

    /// Nome ou simbolo vindo da rede ou de um indexador, pronto para a tela: sem
    /// controle, sem caractere invisivel, sem quebra de linha, espacos juntados e
    /// cortado no limite. O texto original nao vai para a tela.
    public static func clean(_ text: String, limit: Int) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if invisible.contains(scalar) || scalar.properties.generalCategory == .format { continue }
            // Quebra de linha e controle viram espaco: o nome nunca ocupa duas linhas.
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                kept.append(" ")
            } else {
                kept.append(scalar)
            }
        }
        let joined = String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(joined.prefix(limit))
    }

    public static let symbolLimit = 16
    public static let nameLimit = 40
}
