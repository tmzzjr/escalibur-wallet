import EscaliburCore
import Foundation

/// Um endereco da Sui: 32 bytes, escrito "0x" e 64 digitos hexadecimais minusculos.
///
/// Conta Ed25519: BLAKE2b-256 da flag do esquema (0x00) seguida da chave publica de 32
/// bytes (docs.sui.io, "Sui Address": `BLAKE2b-256(flag || pubkey)`). E o mesmo calculo
/// do SDK oficial em TypeScript (`Ed25519PublicKey.toSuiAddress`) e do wallet-core da
/// Trust Wallet (`rust/chains/tw_sui/src/address.rs`).
///
/// Nao ha checksum: uma letra trocada continua sendo um endereco valido de outra pessoa,
/// como na Solana. A defesa e a mesma de la: conferir comeco e fim, e o aviso de endereco
/// parecido.
///
/// O formato "0x" + 64 hex tambem e o da Aptos. Um texto nesse formato pode ser endereco
/// valido nas duas redes, e nada nele diz qual: por isso `Address.guessChain` nao
/// adivinha Sui (nem diz "este endereco e de outra rede") para ele, e a tela de envio
/// precisa pedir a confirmacao da rede, como ja faz nas redes EVM.
public struct SuiAddress: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    /// O endereco de uma chave Ed25519.
    public init(ed25519PublicKey key: [UInt8]) throws {
        guard key.count == 32 else { throw Address.Problem.malformed }
        bytes = Blake2b.hash([SuiSignatureFlag.ed25519] + key, outputLength: 32)
    }

    /// "0x" e os 64 digitos em minusculas: a forma que a carteira mostra, compara e grava.
    public var hex: String { Hex.encode(bytes, prefix: true) }

    public var description: String { hex }

    /// Os enderecos de 0x0 a 0xffff sao do sistema: pacotes do framework (0x1, 0x2, 0x3,
    /// 0xdee9), objetos do sistema (0x5, 0x6, 0x7, 0x8, 0x403) e o endereco zero. Nenhuma
    /// chave gera um deles (o endereco de conta e saida de hash), e o que for mandado
    /// para la nao tem dono que o mova.
    public var isSystem: Bool { bytes.prefix(30).allSatisfy { $0 == 0 } }

    /// Le "0x" + 64 hex, em qualquer caixa. Forma curta ("0x2") e sem o prefixo nao
    /// valem como destino: a carteira so aceita o endereco inteiro, que e o que o dono
    /// confere.
    public static func parse(_ text: String) -> Result<SuiAddress, Address.Problem> {
        guard text.hasPrefix("0x") || text.hasPrefix("0X") else { return .failure(.malformed) }
        guard text.utf8.count == 66, let raw = Hex.decode(text), let address = SuiAddress(bytes: raw) else {
            return .failure(.malformed)
        }
        return .success(address)
    }

    /// Validacao para `Address.validate`: devolve o endereco em minusculas.
    static func validateDestination(_ text: String) -> Result<Address.Destination, Address.Problem> {
        switch parse(text) {
        case .success(let address): return .success(Address.Destination(address: address.hex, tag: nil))
        case .failure(let problem): return .failure(problem)
        }
    }
}

/// A flag de esquema que abre a assinatura serializada e entra no hash do endereco.
enum SuiSignatureFlag {
    static let ed25519: UInt8 = 0x00
}
