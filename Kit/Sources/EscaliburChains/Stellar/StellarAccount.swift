import EscaliburCore
import Foundation

/// Uma conta Stellar como o XDR a chama (`AccountID`): a chave publica Ed25519.
///
/// Nasce so de 32 bytes ou de um `G...` que passou pela StrKey estrita, entao todo
/// valor deste tipo e uma conta valida. Emissor de ativo, destino de `CreateAccount`
/// e dono da transacao passam por aqui.
public struct StellarAccountID: Hashable, Sendable, CustomStringConvertible {
    public let publicKey: [UInt8]

    public init(publicKey: [UInt8]) throws {
        guard publicKey.count == 32 else { throw StellarXDRError.invalidAccount }
        self.publicKey = publicKey
    }

    /// So `G...` canonico. Um `M...` aqui e recusado: quem aceita conta muxed e
    /// `StellarMuxedAccount`, que guarda o id em vez de joga-lo fora.
    public init?(address: String) {
        guard let key = StellarKey.strictAccountKey(address) else { return nil }
        self.publicKey = key
    }

    public var address: String { StellarKey.encode(version: StellarKey.accountVersion, payload: publicKey) }

    public var description: String { address }

    /// `PublicKey` no XDR: tipo `PUBLIC_KEY_TYPE_ED25519` (0) e os 32 bytes.
    func encode(to writer: inout StellarXDRWriter) {
        writer.int32(0)
        writer.fixedOpaque(publicKey)
    }

    static func decode(from reader: inout StellarXDRReader) throws -> StellarAccountID {
        let type = try reader.int32()
        guard type == 0 else { throw StellarXDRError.unknownDiscriminant(field: "PublicKey", value: type) }
        return try StellarAccountID(publicKey: try reader.fixedOpaque(32))
    }
}

/// Origem ou destino de pagamento (`MuxedAccount`): a conta, e opcionalmente o id
/// de 64 bits que uma corretora usa para saber de qual cliente e o deposito.
///
/// **A armadilha de ordem.** Na StrKey `M...` o payload e chave seguida do id; no
/// XDR `med25519` o id vem **antes** da chave. Trocar a ordem gera um destino que
/// decodifica sem erro e aponta para outra conta. Os testes conferem os dois lados
/// com o vetor do SEP-0023 e com um pagamento muxed real da rede principal.
public struct StellarMuxedAccount: Hashable, Sendable, CustomStringConvertible {
    public let account: StellarAccountID
    public let id: UInt64?

    public init(account: StellarAccountID, id: UInt64? = nil) {
        self.account = account
        self.id = id
    }

    /// `G...` ou `M...`, pela StrKey estrita do SEP-0023.
    public init?(address: String) {
        if let key = StellarKey.strictAccountKey(address), let account = try? StellarAccountID(publicKey: key) {
            self.init(account: account)
            return
        }
        guard let (key, id) = StellarKey.strictMuxed(address), let account = try? StellarAccountID(publicKey: key) else {
            return nil
        }
        self.init(account: account, id: id)
    }

    public var isMuxed: Bool { id != nil }

    /// `M...` quando ha id, `G...` quando nao ha.
    public var address: String {
        guard let id else { return account.address }
        return StellarKey.muxedAddress(publicKey: account.publicKey, id: id)
    }

    public var description: String { address }

    static let keyTypeEd25519: Int32 = 0
    static let keyTypeMuxedEd25519: Int32 = 0x100

    func encode(to writer: inout StellarXDRWriter) {
        if let id {
            writer.int32(Self.keyTypeMuxedEd25519)
            writer.uint64(id)          // o id primeiro...
            writer.fixedOpaque(account.publicKey)  // ...e so depois a chave
        } else {
            writer.int32(Self.keyTypeEd25519)
            writer.fixedOpaque(account.publicKey)
        }
    }

    static func decode(from reader: inout StellarXDRReader) throws -> StellarMuxedAccount {
        let type = try reader.int32()
        switch type {
        case keyTypeEd25519:
            return StellarMuxedAccount(account: try StellarAccountID(publicKey: try reader.fixedOpaque(32)))
        case keyTypeMuxedEd25519:
            let id = try reader.uint64()
            let key = try reader.fixedOpaque(32)
            return StellarMuxedAccount(account: try StellarAccountID(publicKey: key), id: id)
        default:
            throw StellarXDRError.unknownDiscriminant(field: "MuxedAccount", value: type)
        }
    }
}

extension StellarKey {
    /// Semente `S...`. Existe aqui so para os testes lerem a chave do vetor SEP-0005:
    /// nenhuma funcao deste modulo decodifica semente.
    static let seedVersion: UInt8 = 18 << 3

    /// `M...` a partir da chave e do id. Na StrKey o id vai **depois** da chave, em
    /// big-endian (SEP-0023, passo 3).
    public static func muxedAddress(publicKey: [UInt8], id: UInt64) -> String {
        precondition(publicKey.count == 32, "chave Ed25519 tem 32 bytes")
        return encode(version: muxedVersion, payload: publicKey + id.bigEndianByteArray)
    }

    /// Chave de um `G...`, exigindo o tamanho exato e a forma canonica.
    ///
    /// O SEP-0023 manda recusar StrKey cujo comprimento seja 1, 3 ou 6 modulo 8 e
    /// cujos bits finais nao usados nao sejam zero. O tamanho exato (56) cobre o
    /// primeiro caso; o `Base32.decode` do Core recusa o segundo; a reconstrucao no
    /// fim fecha qualquer outra grafia alternativa.
    static func strictAccountKey(_ text: String) -> [UInt8]? {
        guard text.utf8.count == 56, text.hasPrefix("G"),
              let key = decode(text, version: accountVersion), key.count == 32,
              encode(version: accountVersion, payload: key) == text
        else { return nil }
        return key
    }

    /// Chave e id de um `M...` (69 caracteres, 40 bytes de payload).
    static func strictMuxed(_ text: String) -> ([UInt8], UInt64)? {
        guard text.utf8.count == 69, text.hasPrefix("M"),
              let raw = decode(text, version: muxedVersion), raw.count == 40,
              encode(version: muxedVersion, payload: raw) == text
        else { return nil }
        let id = raw.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (Array(raw.prefix(32)), id)
    }
}
