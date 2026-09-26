import EscaliburCore
import Foundation

/// Endereco TON: workchain e o hash de 32 bytes do state init do contrato.
///
/// Na TON o endereco nao sai da chave publica, sai do contrato da carteira: codigo
/// mais dados iniciais (que contem a chave). A mesma chave tem um endereco para cada
/// versao de contrato, e por isso a versao faz parte do que a carteira grava.
///
/// Duas grafias:
/// - raw: `0:<64 hex>`, sem checksum e sem flag.
/// - amigavel: 36 bytes em base64 (48 caracteres): flag, workchain, hash e
///   CRC16-XModem big-endian. A flag diz se a mensagem deve voltar quando o destino
///   falhar (`EQ...` bounceable, `UQ...` nao bounceable) e se o endereco e da testnet.
///
/// Referencia: docs.ton.org, "Smart contract addresses" e ton-core `src/address/Address.ts`.
public struct TONAddress: Hashable, Sendable, CustomStringConvertible {
    public let workchain: Int8
    public let hash: [UInt8]

    /// Workchain principal (basechain). A carteira so deriva endereco aqui.
    public static let basechain: Int8 = 0
    /// Masterchain: aceito como destino, porque existe, mas nenhuma carteira mora la.
    public static let masterchain: Int8 = -1

    static let bounceableTag: UInt8 = 0x11
    static let nonBounceableTag: UInt8 = 0x51
    static let testnetFlag: UInt8 = 0x80

    /// So o codigo deste modulo constroi endereco a partir de bytes soltos, sempre
    /// com 32 bytes: um hash de outro tamanho e erro de programa, nunca de entrada.
    init(workchain: Int8, hash: [UInt8]) {
        precondition(hash.count == 32, "hash de endereco TON tem 32 bytes")
        self.workchain = workchain
        self.hash = hash
    }

    /// O endereco de um contrato: `workchain:hash(state init)`.
    public init(workchain: Int8 = basechain, stateInit: TONCell) {
        self.init(workchain: workchain, hash: stateInit.hash)
    }

    /// `0:<hex>`, em minusculas.
    public var raw: String { "\(workchain):\(Hex.encode(hash))" }

    public var description: String { raw }

    /// Grafia amigavel. A carteira mostra o proprio endereco como nao bounceable
    /// (`UQ...`), que e o que a documentacao da TON pede para carteiras: quem copia
    /// para enviar a uma carteira ainda nao ativada nao ve o dinheiro voltar.
    public func friendly(bounceable: Bool, testnet: Bool = false, urlSafe: Bool = true) -> String {
        var tag = bounceable ? Self.bounceableTag : Self.nonBounceableTag
        if testnet { tag |= Self.testnetFlag }
        var body: [UInt8] = [tag, UInt8(bitPattern: workchain)] + hash
        let crc = CRC16.xmodem(body)
        body += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        let text = Data(body).base64EncodedString()
        guard urlSafe else { return text }
        return text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    // MARK: Leitura

    /// Um endereco lido de texto, com o que a grafia dizia.
    public struct Parsed: Equatable, Sendable {
        public let address: TONAddress
        /// `nil` na grafia raw, que nao carrega flag.
        public let bounceable: Bool?
        public let testnet: Bool

        public var isFriendly: Bool { bounceable != nil }
    }

    /// Le raw ou amigavel (base64 padrao ou url-safe). Nao decide nada sobre testnet:
    /// quem valida destino e `validate`.
    public static func parse(_ raw: String) -> Result<Parsed, Address.Problem> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if text.contains(":") { return parseRaw(text) }
        return parseFriendly(text)
    }

    static func parseRaw(_ text: String) -> Result<Parsed, Address.Problem> {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 64 else { return .failure(.malformed) }
        let workchain: Int8
        switch parts[0] {
        case "0": workchain = basechain
        case "-1": workchain = masterchain
        default:
            // Outro inteiro e workchain que a rede nao tem; outra coisa e lixo.
            return Int32(parts[0]) == nil ? .failure(.malformed) : .failure(.unsupportedType)
        }
        guard let hash = Hex.decode(String(parts[1])), hash.count == 32 else { return .failure(.malformed) }
        return .success(Parsed(address: TONAddress(workchain: workchain, hash: hash), bounceable: nil, testnet: false))
    }

    static func parseFriendly(_ text: String) -> Result<Parsed, Address.Problem> {
        guard text.count == 48 else { return .failure(.malformed) }
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/-_")
        guard text.allSatisfy({ alphabet.contains($0) }) else { return .failure(.malformed) }
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: standard), data.count == 36 else { return .failure(.malformed) }
        let bytes = Array(data)
        let crc = CRC16.xmodem(Array(bytes[0..<34]))
        guard bytes[34] == UInt8(crc >> 8), bytes[35] == UInt8(crc & 0xFF) else { return .failure(.badChecksum) }
        let tag = bytes[0] & ~testnetFlag
        guard tag == bounceableTag || tag == nonBounceableTag else { return .failure(.malformed) }
        let workchain = Int8(bitPattern: bytes[1])
        guard workchain == basechain || workchain == masterchain else { return .failure(.unsupportedType) }
        return .success(Parsed(
            address: TONAddress(workchain: workchain, hash: Array(bytes[2..<34])),
            bounceable: tag == bounceableTag,
            testnet: bytes[0] & testnetFlag != 0
        ))
    }

    // MARK: O que Address.swift chama

    /// O endereco da carteira padrao da Escalibur para a chave: contrato V4R2,
    /// workchain 0, grafia nao bounceable da rede principal (`UQ...`), igual ao que
    /// Trust Wallet e Ledger Live mostram para a mesma chave.
    public static func walletAddress(publicKey: [UInt8]) throws -> String {
        try TONWallet(publicKey: publicKey, version: .default).address.friendly(bounceable: false)
    }

    /// Valida destino digitado ou colado. Aceita raw e amigavel; recusa endereco de
    /// testnet (`.unsupportedType`), porque um envio na rede principal para um
    /// endereco marcado como testnet quase sempre e engano de quem copiou.
    ///
    /// O endereco devolvido mantem a grafia do dono (normalizada para url-safe), porque
    /// a flag bounceable dela decide como a mensagem sai.
    static func validate(_ text: String) -> Result<Address.Destination, Address.Problem> {
        switch parse(text) {
        case .failure(let problem):
            return .failure(problem)
        case .success(let parsed):
            guard !parsed.testnet else { return .failure(.unsupportedType) }
            guard let bounceable = parsed.bounceable else {
                return .success(Address.Destination(address: parsed.address.raw, tag: nil))
            }
            return .success(Address.Destination(address: parsed.address.friendly(bounceable: bounceable), tag: nil))
        }
    }
}
