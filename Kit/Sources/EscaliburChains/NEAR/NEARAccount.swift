import EscaliburCore
import Foundation

/// Uma conta NEAR: implicita (a chave publica Ed25519 em 64 hex minusculos) ou com nome
/// (`alice.near`, `bob.tg`, `app_1.alice.near`).
///
/// Regras da rede (crate `near-account-id`, `validation.rs`, conferido em 28/09/2026):
/// de 2 a 64 caracteres, so `a-z`, `0-9`, `-`, `_` e `.`, sem separador no comeco, no fim
/// ou dois seguidos. Maiuscula nao existe numa conta NEAR: o texto com maiuscula e
/// recusado, nunca corrigido, porque o que sai tem de ser o que o dono viu.
///
/// Tipos pelo formato (`AccountIdRef::get_account_type`), e o que a carteira faz:
/// - implicita NEAR, 64 hex: aceita. Pode ainda nao existir; a primeira transferencia a
///   cria, e a rede cobra por isso;
/// - com nome: aceita, e o envio so segue se a conta existir na rede, lida em dois
///   provedores (docs/redes/near.md);
/// - implicita Ethereum (`0x` e 40 hex): recusada. O texto e um endereco EVM, e a tela
///   diz isso; uma conta assim na NEAR e controlada por outra chave e outro contrato;
/// - deterministica (`0s` e 40 hex) e universal (`0u` e 52 base32): recusadas, tipo que
///   a carteira ainda nao envia. As taxas delas seguem outra regra;
/// - `system`: a conta da propria rede, que ninguem controla.
public struct NEARAccountID: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        case implicit
        case named
    }

    public let text: String
    public let kind: Kind

    public static let minLength = 2
    public static let maxLength = 64

    /// A conta implicita de uma chave Ed25519: os 32 bytes em hex minusculo.
    public init?(implicitPublicKey key: [UInt8]) {
        guard key.count == 32 else { return nil }
        text = Hex.encode(key)
        kind = .implicit
    }

    init(checked text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    public var description: String { text }

    /// A chave publica da conta implicita.
    public var implicitPublicKey: [UInt8]? {
        kind == .implicit ? Hex.decode(text) : nil
    }

    // MARK: Leitura

    public static func parse(_ raw: String) -> Result<NEARAccountID, Address.Problem> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard isValidSyntax(text) else { return .failure(.malformed) }
        if isHex(text, count: 64) { return .success(NEARAccountID(checked: text, kind: .implicit)) }
        // Implicita Ethereum: `Address.validate` troca por "este endereco e da rede
        // Ethereum", porque o texto e um endereco EVM valido.
        if text.count == 42, text.hasPrefix("0x"), isHex(String(text.dropFirst(2)), count: 40) { return .failure(.malformed) }
        if text.count == 42, text.hasPrefix("0s"), isHex(String(text.dropFirst(2)), count: 40) { return .failure(.unsupportedType) }
        if isUniversal(text) || text == "system" { return .failure(.unsupportedType) }
        return .success(NEARAccountID(checked: text, kind: .named))
    }

    /// A gramatica `^(([a-z\d]+[-_])*[a-z\d]+\.)*([a-z\d]+[-_])*[a-z\d]+$` e o tamanho.
    static func isValidSyntax(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (minLength...maxLength).contains(bytes.count) else { return false }
        var lastWasSeparator = true
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                lastWasSeparator = false
            case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."):
                if lastWasSeparator { return false }
                lastWasSeparator = true
            default:
                return false
            }
        }
        return !lastWasSeparator
    }

    static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// `0u` e 52 caracteres do base32 de Crockford (protocolo 87, contas universais).
    static func isUniversal(_ text: String) -> Bool {
        let alphabet = Set("0123456789abcdefghjkmnpqrstvwxyz".utf8)
        return text.utf8.count == 54 && text.hasPrefix("0u") && text.utf8.dropFirst(2).allSatisfy { alphabet.contains($0) }
    }

    // MARK: Para Address

    /// Um endereco bech32 (Bitcoin, Litecoin) ou Cardano so tem minusculas e digitos, e
    /// passa pela gramatica como nome NEAR. Quando o texto e endereco valido de outra rede,
    /// com checksum, a tela diz de qual; um nome NEAR que colidisse com um checksum desses
    /// e acaso de 1 em 2^30.
    static func validateDestination(_ text: String) -> Result<Address.Destination, Address.Problem> {
        switch parse(text) {
        case .success(let account):
            if account.kind == .named, let other = Address.guessChain(account.text), other.id != Chain.near.id {
                return .failure(.otherNetwork(other))
            }
            return .success(Address.Destination(address: account.text, tag: nil))
        case .failure(let problem): return .failure(problem)
        }
    }

    /// Para `Address.guessChain`: so as contas com nome sob `.near` e `.tg`, os dois
    /// registros de nome da rede. Um nome solto ("binance") casa com a gramatica mas nao
    /// diz de que rede e. A conta implicita tambem fica sem palpite: 64 hex sem prefixo e
    /// tambem um endereco da Sui ou da Aptos sem o 0x, e dizer "e da NEAR" na tela da Sui
    /// seria chute.
    static func isNEAR(_ text: String) -> Bool {
        guard case .success(let account) = parse(text), account.kind == .named else { return false }
        return account.text.hasSuffix(".near") || account.text.hasSuffix(".tg")
    }
}
