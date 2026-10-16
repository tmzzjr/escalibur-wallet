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
    /// caracteres iguais numa ponta saem uma vez em um milhao de pares, em hexadecimal.
    static let singleEnd = 5
    /// Na Cardano, o comeco do corpo e a credencial de pagamento inteira (28 bytes, 44
    /// caracteres de bech32): com ela igual, os dois enderecos sao da mesma chave de
    /// pagamento, com outra parte de stake, e nao um sosia gerado.
    static let cardanoPaymentCharacters = 44

    /// O primeiro endereco de `known` parecido com `address`, se houver.
    public static func lookalike(_ address: String, among known: [String], chain: Chain) -> String? {
        let target = body(address, chain: chain)
        guard target.count >= 16 else { return nil }
        let targetAccount = Address.canonicalRecipient(address, chain: chain)
        return known.first { other in
            let candidate = body(other, chain: chain)
            guard candidate.count >= 16, candidate != target else { return false }
            if let targetAccount, Address.canonicalRecipient(other, chain: chain) == targetAccount { return false }
            // Na Stellar, o endereco M e a conta base G dele (ou dois M da mesma base) sao
            // a mesma conta com ids diferentes, nao um sosia.
            if chain.family == .stellar, let a = StellarMuxedAccount(address: other.trimmingCharacters(in: .whitespacesAndNewlines))?.account,
               let b = StellarMuxedAccount(address: address.trimmingCharacters(in: .whitespacesAndNewlines))?.account, a == b {
                return false
            }
            let head = commonPrefix(candidate, target)
            let tail = commonPrefix(String(candidate.reversed()), String(target.reversed()))
            if chain.family == .cardano, head >= cardanoPaymentCharacters { return false }
            if head >= minimumPrefix && tail >= minimumSuffix && head + tail >= minimumTotal { return true }
            return singleEndApplies(chain, candidate, target) && max(head, tail) >= singleEnd
        }
    }

    /// Conta com nome na NEAR ("alguem.near") termina igual por desenho: a ponta so vale
    /// entre contas implicitas, de 64 caracteres hexadecimais.
    static func singleEndApplies(_ chain: Chain, _ a: String, _ b: String) -> Bool {
        guard chain.family == .near else { return true }
        return a.count == 64 && b.count == 64
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
        let target = body(shown, chain: chain)
        let candidate = body(other, chain: chain)
        guard target.count >= length, target != candidate else { return nil }
        let fixed = shown.count - target.count
        let first = fixed + commonPrefix(target, candidate)
        let start = min(first, shown.count - length)
        return Segment(start: max(start, fixed), length: length)
    }

    /// O endereco sem o prefixo que a rede impoe, em minusculas.
    static func body(_ address: String, chain: Chain) -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch chain.family {
        case .evm:
            if text.hasPrefix("0x") { text.removeFirst(2) }
        case .utxo:
            if let hrp = UTXOParams.for(chain).bech32HRP, text.hasPrefix(hrp + "1") {
                text.removeFirst(hrp.count + 2)  // hrp, separador e versao (q, p)
            } else if !text.isEmpty {
                text.removeFirst()  // caractere de versao do base58
            }
        case .tron, .xrpl, .stellar:
            if !text.isEmpty { text.removeFirst() }
        case .ton:
            if text.hasPrefix("0:") { text.removeFirst(2) } else if text.count > 2 { text.removeFirst(2) }
        case .solana:
            break
        case .sui, .aptos:
            if text.hasPrefix("0x") { text.removeFirst(2) }
        case .cardano:
            // "addr1" e o caractere do cabecalho (tipo de endereco), que o atacante copia
            // de graca, como o hrp e a versao do bech32 no Bitcoin.
            if text.hasPrefix("addr1"), text.count > 6 { text.removeFirst(6) }
        case .polkadot:
            // O prefixo de rede 0 faz todo endereco da Polkadot comecar com 1.
            if !text.isEmpty { text.removeFirst() }
        case .near:
            // Conta implicita sem prefixo; nome inteiro, que o dono escolhe letra a letra.
            break
        }
        return text
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
}
