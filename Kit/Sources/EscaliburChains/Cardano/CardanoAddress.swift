import EscaliburCore
import Foundation

/// Enderecos Shelley da Cardano (CIP-19): bech32 com hrp `addr`, um byte de cabecalho
/// (tipo no nibble alto, rede no baixo) e credenciais de 28 bytes, BLAKE2b-224 da chave
/// publica (ou do script).
///
/// A carteira envia para os tres tipos cujo pagamento e uma chave: base com stake de
/// chave (0) ou de script (2) e enterprise (6). O resto e recusado com motivo, porque
/// cada um tem um jeito proprio de dar errado:
/// - pagamento por script (1, 3, 5, 7): ADA mandado para um contrato sem o datum que ele
///   espera pode ficar preso para sempre;
/// - ponteiro (4, 5): a rede deixou de resolver o ponteiro de stake na Conway;
/// - stake (`stake1...`): recebe recompensa, nao pagamento;
/// - rede de teste (`addr_test1...`) e Byron (`Ae2...`, `DdzFf...`): outra rede ou o
///   formato de antes de 2020, que a carteira nao monta.
public struct CardanoAddress: Equatable, Sendable {
    /// Cabecalho mais credenciais, como vao na saida da transacao.
    public let bytes: [UInt8]

    public var type: UInt8 { bytes[0] >> 4 }
    public var networkID: UInt8 { bytes[0] & 0x0F }
    /// O hash da chave (ou do script) que paga, os 28 bytes depois do cabecalho.
    public var paymentHash: [UInt8] { Array(bytes[1..<29]) }
    /// So nos tipos base (0 a 3): a credencial de stake.
    public var stakeHash: [UInt8]? { type <= 3 ? Array(bytes[29..<57]) : nil }
    /// Pagamento por chave (e nao por script): tipos pares ate 6.
    public var paysToKey: Bool { type <= 7 && type % 2 == 0 }

    static let mainnet: UInt8 = 1
    /// Um endereco base tem 103 caracteres; 130 cobre todo tipo Shelley.
    static let maxBech32Length = 130

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Bech32 com hrp `addr`, em minusculas.
    public var bech32: String {
        Bech32.encode(hrp: "addr", data: Bech32.convertBits(bytes, from: 8, to: 5, pad: true) ?? [], variant: .bech32)
    }

    /// BLAKE2b-224 da chave publica Ed25519: a credencial que vai no endereco.
    public static func keyHash(_ publicKey: [UInt8]) -> [UInt8] {
        Blake2b.hash(publicKey, outputLength: 28)
    }

    /// Endereco base da rede principal (tipo 0): chave de pagamento e chave de stake.
    public static func base(paymentKey: [UInt8], stakeKey: [UInt8]) throws -> String {
        guard paymentKey.count == 32, stakeKey.count == 32 else { throw Address.Problem.malformed }
        return CardanoAddress(bytes: [0x00 << 4 | mainnet] + keyHash(paymentKey) + keyHash(stakeKey)).bech32
    }

    /// `Address.from` para a Cardano: as duas chaves publicas juntas, a de pagamento
    /// (m/1852'/1815'/i'/0/0) e a de stake (m/1852'/1815'/i'/2/0), 64 bytes.
    static func base(publicKeys: [UInt8]) throws -> String {
        guard publicKeys.count == 64 else { throw Address.Problem.malformed }
        return try base(paymentKey: Array(publicKeys.prefix(32)), stakeKey: Array(publicKeys.suffix(32)))
    }

    // MARK: Leitura

    /// Le um endereco Shelley da rede principal, de qualquer tipo que a CIP-19 define para
    /// pagamento (0 a 7). Rede de teste, stake e Byron saem como `.unsupportedType`; o que
    /// parece Cardano com o checksum errado, como `.badChecksum`.
    public static func parse(_ raw: String) -> Result<CardanoAddress, Address.Problem> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        let lower = text.lowercased()
        guard let decoded = Bech32.decode(text, maxLength: maxBech32Length) else {
            if ["addr1", "addr_test1", "stake1", "stake_test1"].contains(where: { lower.hasPrefix($0) }) {
                return .failure(.badChecksum)
            }
            return isByron(text) ? .failure(.unsupportedType) : .failure(.malformed)
        }
        guard decoded.variant == .bech32 else { return .failure(.badChecksum) }
        switch decoded.hrp {
        case "addr": break
        case "addr_test", "stake", "stake_test": return .failure(.unsupportedType)
        default: return .failure(.malformed)
        }
        guard let bytes = Bech32.convertBits(decoded.data, from: 5, to: 8, pad: false), let header = bytes.first else {
            return .failure(.malformed)
        }
        let type = header >> 4
        guard header & 0x0F == mainnet else { return .failure(.malformed) }
        switch type {
        case 0...3: guard bytes.count == 57 else { return .failure(.malformed) }
        case 6, 7: guard bytes.count == 29 else { return .failure(.malformed) }
        case 4, 5: guard bytes.count > 29, bytes.count <= 29 + 3 * 10 else { return .failure(.malformed) }
        default: return .failure(.malformed)
        }
        return .success(CardanoAddress(bytes: bytes))
    }

    /// Um destino de envio: pagamento por chave, base ou enterprise, na rede principal.
    static func validateDestination(_ text: String) -> Result<Address.Destination, Address.Problem> {
        switch parse(text) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let address):
            guard address.paysToKey, address.type != 4 else { return .failure(.unsupportedType) }
            return .success(Address.Destination(address: address.bech32, tag: nil))
        }
    }

    /// O texto e um endereco Cardano de algum tipo (inclusive os que a carteira nao usa
    /// como destino). So para dizer "este endereco e da Cardano" quando ele e colado em
    /// outra rede.
    static func isCardano(_ text: String) -> Bool {
        switch parse(text) {
        case .success, .failure(.unsupportedType): return true
        default: return false
        }
    }

    /// Endereco Byron: base58 de uma lista CBOR `[tag 24(bytes), crc32]`. Basta para
    /// reconhecer o formato e recusar; a carteira nunca monta saida para ele.
    static func isByron(_ text: String) -> Bool {
        guard text.count >= 50, text.count <= 130, let bytes = Base58.bitcoin.decode(text), bytes.count > 40 else { return false }
        return bytes[0] == 0x82 && bytes[1] == 0xD8 && bytes[2] == 0x18
    }
}
