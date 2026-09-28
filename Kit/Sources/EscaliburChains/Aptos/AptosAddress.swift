import EscaliburCore
import Foundation

/// Um endereco da Aptos: 32 bytes, escrito "0x" e 64 digitos hexadecimais minusculos.
///
/// Conta Ed25519 de chave unica (a da Petra e da Trust Wallet): SHA3-256 da chave publica
/// de 32 bytes seguida do byte do esquema, 0x00 (aptos.dev, "Accounts", `auth_key =
/// sha3-256(pubkey_A | 0x00)`; o endereco e a chave de autenticacao original). E o calculo
/// do SDK oficial em TypeScript (`Ed25519PublicKey.authKey`, `SigningScheme.Ed25519`) e do
/// wallet-core (`rust/chains/tw_aptos/src/address.rs`). SHA3-256 do FIPS 202, nao o
/// Keccak-256 da Ethereum: com o outro hash sairia outro endereco, valido e de ninguem.
///
/// Nao ha checksum: uma letra trocada continua sendo um endereco valido de outra pessoa. A
/// defesa e a mesma da Sui e da Solana: conferir comeco e fim, e o aviso de endereco
/// parecido.
///
/// O formato "0x" + 64 hex tambem e o da Sui. Nada no texto diz de qual das duas ele e:
/// `Address.guessChain` nao adivinha nenhuma das duas, e a tela de envio pede a
/// confirmacao da rede, como nas redes EVM.
///
/// A chave de autenticacao pode ser trocada na rede (`rotate_authentication_key`); a conta
/// continua no mesmo endereco, e a chave da frase deixa de assinar por ela. O planejador
/// confere a chave de autenticacao lida da rede antes de montar.
public struct AptosAddress: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    /// O endereco (e a chave de autenticacao original) de uma chave Ed25519.
    public init(ed25519PublicKey key: [UInt8]) throws {
        guard key.count == 32 else { throw Address.Problem.malformed }
        bytes = Hash.sha3_256(key + [AptosAuthenticationScheme.ed25519])
    }

    /// "0x" e os 64 digitos em minusculas (forma LONGA do AIP-40): a que a carteira mostra,
    /// compara e grava.
    public var hex: String { Hex.encode(bytes, prefix: true) }

    public var description: String { hex }

    /// Enderecos especiais do AIP-40, de 0x0 a 0xf: os unicos que podem ser escritos na
    /// forma curta ("0x1").
    public var isSpecial: Bool { bytes.prefix(31).allSatisfy { $0 == 0 } && bytes[31] < 0x10 }

    /// Endereco reservado do sistema: framework (0x1, 0x3, 0x4), metadados do APT (0xa) e
    /// o resto da faixa baixa. Nenhuma chave gera um deles (o endereco de conta e saida de
    /// hash), e o que for mandado para la nao tem dono que o mova.
    public var isSystem: Bool { bytes.prefix(30).allSatisfy { $0 == 0 } }

    /// Le um endereco pelas regras estritas do AIP-40: "0x" e 64 digitos (forma longa), em
    /// qualquer caixa; ou, so para os especiais de 0x0 a 0xf, "0x" e um digito. Endereco
    /// com zeros a esquerda cortados ("0x" e 63 digitos) e sem o "0x" nao valem: um texto
    /// curto demais pode ser um endereco copiado pela metade, e 64 digitos sem o "0x" e o
    /// formato da conta implicita da NEAR.
    public static func parse(_ text: String) -> Result<AptosAddress, Address.Problem> {
        guard text.hasPrefix("0x") || text.hasPrefix("0X") else { return .failure(.malformed) }
        let digits = text.dropFirst(2)
        guard digits.allSatisfy(\.isHexDigit) else { return .failure(.malformed) }
        if digits.count == 1, let value = UInt8(digits, radix: 16) {
            return .success(AptosAddress(bytes: [UInt8](repeating: 0, count: 31) + [value])!)  // swiftlint:disable:this force_unwrapping
        }
        guard digits.count == 64, let raw = Hex.decode(String(digits)), let address = AptosAddress(bytes: raw) else {
            return .failure(.malformed)
        }
        return .success(address)
    }

    /// Validacao para `Address.validate`: devolve a forma longa em minusculas.
    static func validateDestination(_ text: String) -> Result<Address.Destination, Address.Problem> {
        switch parse(text) {
        case .success(let address): return .success(Address.Destination(address: address.hex, tag: nil))
        case .failure(let problem): return .failure(problem)
        }
    }

    /// A loja primaria de APT de uma conta: o objeto onde o saldo fica desde a migracao do
    /// APT para fungible asset (AIP-63). E o endereco de objeto derivado do dono e dos
    /// metadados do APT (0xa): SHA3-256(dono || 0xa em 32 bytes || 0xFC), o esquema de
    /// objeto derivado de `object::create_user_derived_object_address`. Conferido contra
    /// os eventos `Withdraw` e `Deposit` de transferencias reais da rede principal.
    public var primaryAPTStore: AptosAddress {
        AptosAddress(bytes: Hash.sha3_256(bytes + AptosAddress.aptMetadata.bytes + [0xFC]))!  // swiftlint:disable:this force_unwrapping
    }

    /// Os metadados do APT como fungible asset (o objeto 0xa).
    public static let aptMetadata = AptosAddress(bytes: [UInt8](repeating: 0, count: 31) + [0x0A])!  // swiftlint:disable:this force_unwrapping
    /// O pacote do framework (0x1), dono de `aptos_account::transfer`.
    public static let framework = AptosAddress(bytes: [UInt8](repeating: 0, count: 31) + [0x01])!  // swiftlint:disable:this force_unwrapping
}

/// O byte do esquema que fecha o hash da chave de autenticacao e abre o autenticador da
/// transacao (`TransactionAuthenticator::Ed25519` e a variante 0).
enum AptosAuthenticationScheme {
    static let ed25519: UInt8 = 0x00
}
