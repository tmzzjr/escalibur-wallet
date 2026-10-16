import Foundation

/// Deteccao de envenenamento de endereco.
///
/// O golpe: o atacante gera um endereco com o comeco e o fim iguais aos de um que o
/// dono ja usou e manda um valor minusculo, para o endereco falso aparecer no
/// historico. Quem copia de la, conferindo so as pontas, paga o atacante.
///
/// A comparacao ignora o prefixo fixo de cada rede (o atacante nao precisa gerar
/// "0x" nem "bc1q", entao eles nao contam como coincidencia) e olha as pontas do
/// resto. Duas formas da mesma conta (caixa do EIP-55, amigavel e crua da TON) nao
/// sao parecidas: sao a mesma.
public enum AddressPoisoning {
    /// Coincidencias de ponta que um atacante consegue gerar em minutos. Acima disso
    /// o custo cresce 16 a 58 vezes por caractere.
    static let minimumPrefix = 3
    static let minimumSuffix = 3
    static let minimumTotal = 7
    /// Uma ponta so, longa: quem confere so o comeco ou so o fim cai em 2+6, 2+8 ou 0+10,
    /// que as duas pontas juntas deixavam passar (auditoria 4, C7-07). Ao acaso, cinco
    /// caracteres iguais numa ponta saem uma vez em um milhao de pares, em hexadecimal
    /// (16^5 = 2^20).
    static let singleEnd = 5
    /// A mesma ponta so, com 32 simbolos ou mais (bech32, base58, base32 da Stellar,
    /// base64 da TON): quatro caracteres ja sao os mesmos 20 bits (32^4 = 2^20). O sosia que
    /// casa so os 4 do fim, os que a tela mostra, custa o mesmo milhao de tentativas que
    /// os 5 do hexadecimal, e passava sem aviso (revisao dos enderecos parecidos, B-5).
    static let singleEndWide = 4
    /// Na Cardano, o comeco do corpo e a credencial de pagamento inteira (28 bytes, 44
    /// caracteres de bech32): com ela igual, os dois enderecos sao da mesma chave de
    /// pagamento, com outra parte de stake, e nao um sosia gerado.
    static let cardanoPaymentCharacters = 44
    /// Na Cardano, a credencial de stake de um endereco e publica: o atacante poe a de um
    /// endereco que o dono usou no seu, com o pagamento dele, e a segunda metade dos dois
    /// fica igual de graca. Com o stake igual e o pagamento diferente, tres caracteres
    /// iguais no fim (o checksum) ja marcam (B-5).
    static let cardanoSameStakeSuffix = 3

    /// Menos que isso depois do prefixo da rede nao e endereco gerado (nome curto da NEAR).
    /// O tamanho conta o registro do nome da NEAR: tirar o ".near" do corpo nao deixa de
    /// comparar um nome que ja era comparado.
    static let minimumLength = 16

    /// O primeiro endereco de `known` parecido com `address`, se houver.
    public static func lookalike(_ address: String, among known: [String], chain: Chain) -> String? {
        guard let target = Compared(address, chain: chain) else { return nil }
        let targetAccount = Address.canonicalRecipient(address, chain: chain)
        return known.first { other in
            guard let compared = Compared(other, chain: chain), compared.text != target.text else { return false }
            if let targetAccount, Address.canonicalRecipient(other, chain: chain) == targetAccount { return false }
            // Na Stellar, o endereco M e a conta base G dele (ou dois M da mesma base) sao
            // a mesma conta com ids diferentes, nao um sosia. O ID trocado entre dois M e
            // outra conferencia (`sameAccountOtherID`).
            if chain.family == .stellar, let a = StellarMuxedAccount(address: other.trimmingCharacters(in: .whitespacesAndNewlines))?.account,
               let b = StellarMuxedAccount(address: address.trimmingCharacters(in: .whitespacesAndNewlines))?.account, a == b {
                return false
            }
            let candidate = compared.body
            let head = commonPrefix(candidate, target.body)
            let tail = commonPrefix(String(candidate.reversed()), String(target.body.reversed()))
            if chain.family == .cardano {
                if head >= cardanoPaymentCharacters { return false }
                if tail >= cardanoSameStakeSuffix, cardanoSameStakeOtherPayment(address, other) { return true }
            }
            if head >= minimumPrefix && tail >= minimumSuffix && head + tail >= minimumTotal { return true }
            guard let single = singleEndLength(chain, candidate, target.body) else { return false }
            return max(head, tail) >= single
        }
    }

    /// Um endereco como a comparacao le, em minusculas: `text`, tudo depois do prefixo da
    /// rede, diz se dois sao o mesmo; `body`, tambem sem o sufixo de nome da NEAR, e de
    /// onde saem as pontas. O mesmo nome sob ".near" e sob ".tg" tem o corpo igual e o
    /// texto diferente: sao contas diferentes, e as duas pontas iguais o marcam.
    private struct Compared {
        let text: String
        let body: String

        init?(_ address: String, chain: Chain) {
            text = AddressPoisoning.afterPrefix(address, chain: chain)
            guard text.count >= AddressPoisoning.minimumLength else { return nil }
            body = AddressPoisoning.body(address, chain: chain)
        }
    }

    /// Quantos caracteres iguais numa ponta so ja fazem o par parecido, ou `nil` quando a
    /// regra da ponta so nao vale. Quatro com 32 simbolos ou mais, cinco em hexadecimal:
    /// os dois sao 20 bits, e ao acaso saem perto de duas vezes em um milhao de pares
    /// (as taxas medidas por rede estao no teste).
    static func singleEndLength(_ chain: Chain, _ a: String, _ b: String) -> Int? {
        switch chain.family {
        case .evm, .sui, .aptos:
            return singleEnd
        case .near:
            // Conta com nome e escolhida letra a letra, e nomes com o mesmo comeco ou o
            // mesmo fim sao comuns ("alex...", "...-wallet"): a ponta so vale entre contas
            // implicitas, 64 caracteres hexadecimais. Pelo tamanho so, um nome de 64 letras
            // tambem entrava (revisao dos enderecos parecidos, B-9).
            return isHex64(a) && isHex64(b) ? singleEnd : nil
        case .ton:
            // A grafia crua ("0:" e 64 hex) e hexadecimal; a amigavel, base64.
            return isHex64(a) && isHex64(b) ? singleEnd : singleEndWide
        case .utxo, .tron, .xrpl, .stellar, .solana, .cardano, .polkadot:
            return singleEndWide
        }
    }

    /// 64 caracteres hexadecimais (o corpo ja vem em minusculas).
    static func isHex64(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Dois enderecos base da Cardano com a mesma credencial de stake e pagamentos
    /// diferentes.
    static func cardanoSameStakeOtherPayment(_ a: String, _ b: String) -> Bool {
        guard case .success(let first) = CardanoAddress.parse(a), case .success(let second) = CardanoAddress.parse(b),
              let stake = first.stakeHash, stake == second.stakeHash
        else { return false }
        return first.paymentHash != second.paymentHash
    }

    // MARK: Mesma conta, outro ID (Stellar)

    /// O endereco M conhecido com a mesma conta base de `address` e outro ID, quando
    /// `address` e um M e nenhum conhecido e ele mesmo (revisao dos enderecos parecidos,
    /// B-6).
    ///
    /// `lookalike` deixa de fora, de proposito, dois M da mesma base: sao a mesma conta, e
    /// nao um sosia gerado. So que numa corretora o ID e o que diz de qual cliente e o
    /// deposito. Um programa que troca o endereco copiado pode decodificar o M, trocar so
    /// o ID pelo de uma conta do atacante na mesma corretora e codificar de novo: o
    /// endereco continua valido, da mesma conta, e passava por todas as conferencias.
    ///
    /// So M contra M: o G da conta (ou o historico da rede, que da a conta base) nao diz
    /// qual ID o dono usou, e nao tem o que comparar.
    public static func sameAccountOtherID(_ address: String, among known: [String], chain: Chain) -> String? {
        guard chain.family == .stellar, let target = muxedAccount(address), target.isMuxed else { return nil }
        let muxed: [(text: String, account: StellarMuxedAccount)] = known.compactMap { text in
            guard let account = muxedAccount(text), account.isMuxed else { return nil }
            return (text, account)
        }
        // O mesmo M ja usado: e o destino de sempre.
        if muxed.contains(where: { $0.account == target }) { return nil }
        return muxed.first { $0.account.account == target.account }?.text
    }

    /// O trecho do endereco M depois da chave: o ID e o checksum, o que muda quando so o
    /// ID muda. A versao e a chave ocupam 33 bytes, 264 bits; o caractere 52 ainda leva os
    /// 4 ultimos bits da chave (e o bit mais alto do ID), e do 53 em diante e so ID e
    /// checksum.
    public static func muxedIDSegment(_ address: String) -> Segment? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account = muxedAccount(text), account.isMuxed, text.count > muxedIDStart else { return nil }
        return Segment(start: muxedIDStart, length: text.count - muxedIDStart)
    }

    static let muxedIDStart = (1 + 32) * 8 / 5 + 1

    static func muxedAccount(_ address: String) -> StellarMuxedAccount? {
        StellarMuxedAccount(address: address.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Um trecho do endereco, em posicoes de caractere do texto como ele e mostrado.
    public struct Segment: Equatable, Sendable {
        public let start: Int
        public let length: Int

        /// O trecho dentro de `address`.
        public func text(in address: String) -> String {
            String(address.dropFirst(start).prefix(length))
        }
    }

    /// Os `length` caracteres do meio do endereco: o que o dono le e digita quando nao ha
    /// com o que comparar (historico da rede ilegivel, auditoria 3, B1).
    public static func middleSegment(_ address: String, length: Int = 6) -> Segment? {
        let count = address.count
        guard count >= length + 4 else { return nil }
        return Segment(start: (count - length) / 2, length: length)
    }

    /// Onde `address` comeca a diferir de `other`: os `length` caracteres a partir da
    /// primeira diferenca depois do prefixo da rede. E o trecho que o desafio pede:
    /// as pontas o atacante copia, o meio ele nao consegue (auditoria 2, M2).
    public static func differingSegment(_ address: String, from other: String, chain: Chain, length: Int = 6) -> Segment? {
        let shown = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = afterPrefix(shown, chain: chain)
        let candidate = afterPrefix(other, chain: chain)
        guard target.count >= length, target != candidate else { return nil }
        let fixed = shown.count - target.count
        let first = fixed + commonPrefix(target, candidate)
        let start = min(first, shown.count - length)
        return Segment(start: max(start, fixed), length: length)
    }

    /// O endereco sem o prefixo que a rede impoe (e, na NEAR, sem o registro do nome), em
    /// minusculas.
    static func body(_ address: String, chain: Chain) -> String {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return bodySegment(text, chain: chain).text(in: text).lowercased()
    }

    /// Tudo depois do prefixo que a rede impoe, em minusculas, com o registro do nome da
    /// NEAR: e por ele que se sabe se dois enderecos sao o mesmo texto.
    static func afterPrefix(_ address: String, chain: Chain) -> String {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.dropFirst(bodySegment(text, chain: chain).start)).lowercased()
    }

    /// Onde fica o corpo do endereco, no texto como ele e mostrado (sem espaco nas pontas):
    /// tudo depois do prefixo que a rede impoe e, na NEAR, antes do registro do nome. A
    /// tela abrevia por aqui (`Fmt.address`), para os 6 do comeco serem do corpo, e nao o
    /// "addr1q" que todo endereco tem.
    public static func bodySegment(_ address: String, chain: Chain) -> Segment {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let count = text.count
        let start: Int
        switch chain.family {
        case .evm, .sui, .aptos:
            start = text.hasPrefix("0x") ? 2 : 0
        case .utxo:
            if let hrp = UTXOParams.for(chain).bech32HRP, text.hasPrefix(hrp + "1") {
                start = min(hrp.count + 2, count)  // hrp, separador e versao (q, p)
            } else {
                start = min(1, count)  // caractere de versao do base58
            }
        case .tron, .xrpl, .stellar:
            start = min(1, count)
        case .ton:
            start = text.hasPrefix("0:") || count > 2 ? 2 : 0
        case .solana:
            start = 0
        case .cardano:
            // "addr1" e o caractere do cabecalho (tipo de endereco), que o atacante copia
            // de graca, como o hrp e a versao do bech32 no Bitcoin.
            start = text.hasPrefix("addr1") && count > 6 ? 6 : 0
        case .polkadot:
            // O prefixo de rede 0 faz todo endereco da Polkadot comecar com 1.
            start = min(1, count)
        case .near:
            // Conta implicita sem prefixo; nome inteiro, que o dono escolhe letra a letra,
            // menos o registro do fim (".near", ".tg"): ele e igual por desenho, e contado
            // como ponta fazia "alexis-exchange.near" parecido com "alexander-wallet.near"
            // (B-9).
            if let suffix = NEARAccountID.registrySuffixes.first(where: { text.hasSuffix($0) && count > $0.count }) {
                return Segment(start: 0, length: count - suffix.count)
            }
            start = 0
        }
        return Segment(start: start, length: count - start)
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
}
