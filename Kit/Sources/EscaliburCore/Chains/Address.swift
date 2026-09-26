import Foundation

/// Derivacao e validacao de endereco, por familia de rede.
///
/// Validar endereco e defesa de dinheiro, nao conveniencia: cada funcao aqui confere
/// o checksum da rede e diz **por que** recusou, para a interface poder dizer "este e
/// um endereco Ethereum, para enviar XRP use um que comeca com r" em vez de
/// "endereco invalido".
public enum Address {

    public enum Problem: Error, Equatable, Sendable {
        case empty
        /// O texto e um endereco valido, mas de outra familia de rede.
        case otherNetwork(ChainFamily)
        /// O checksum nao fecha: letra trocada ou endereco truncado.
        case badChecksum
        case malformed
        /// SegWit v1+ ou tipo de script que a carteira ainda nao envia.
        case unsupportedType
    }

    /// Um destino validado. `tag` vem preenchida quando o endereco carrega a tag
    /// junto (X-address do XRP Ledger, conta muxed da Stellar).
    public struct Destination: Equatable, Sendable {
        public let address: String
        public let tag: UInt64?
    }

    // MARK: Derivacao a partir da chave publica

    /// O endereco da chave publica. `publicKey` e a comprimida (33 bytes) nas redes
    /// secp256k1 e a Ed25519 (32 bytes) nas outras.
    public static func from(publicKey: [UInt8], chain: Chain) throws -> String {
        switch chain.family {
        case .utxo:
            let params = UTXOParams.for(chain)
            let hash = Hash.hash160(publicKey)
            if let hrp = params.bech32HRP {
                guard let text = Bech32.segwitEncode(hrp: hrp, version: 0, program: hash) else { throw Problem.malformed }
                return text
            }
            return Base58.bitcoin.encodeCheck([params.p2pkhVersion] + hash)
        case .evm:
            return eip55(try evmAccount(publicKey))
        case .tron:
            return Base58.bitcoin.encodeCheck([0x41] + (try evmAccount(publicKey)))
        case .solana:
            guard publicKey.count == 32 else { throw Problem.malformed }
            return Base58.bitcoin.encode(publicKey)
        case .xrpl:
            guard publicKey.count == 33 else { throw Problem.malformed }
            return Base58.ripple.encodeCheck([0x00] + Hash.hash160(publicKey))
        case .stellar:
            return try StellarKey.accountID(publicKey)
        case .ton:
            return try TONAddress.walletAddress(publicKey: publicKey)
        }
    }

    /// Os 20 bytes da conta EVM (e Tron): keccak da chave expandida sem o prefixo 04.
    static func evmAccount(_ publicKey: [UInt8]) throws -> [UInt8] {
        let expanded = try Secp256k1.reformat(publicKey: publicKey, compressed: false)
        return Array(Hash.keccak256(Array(expanded.dropFirst())).suffix(20))
    }

    /// Checksum EIP-55 por caixa das letras.
    public static func eip55(_ account: [UInt8]) -> String {
        let lower = Hex.encode(account)
        let hash = Hash.keccak256(Array(lower.utf8))
        var out = "0x"
        for (index, c) in lower.enumerated() {
            let nibble = (hash[index / 2] >> (index % 2 == 0 ? 4 : 0)) & 0x0F
            out.append(c.isLetter && nibble >= 8 ? Character(c.uppercased()) : c)
        }
        return out
    }

    // MARK: Validacao

    /// Valida um endereco digitado ou colado para a rede dada.
    public static func validate(_ raw: String, for chain: Chain) -> Result<Destination, Problem> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }

        let result: Result<Destination, Problem>
        switch chain.family {
        case .utxo: result = validateUTXO(text, chain: chain)
        case .evm: result = validateEVM(text)
        case .tron: result = validateTron(text)
        case .solana: result = validateSolana(text)
        case .xrpl: result = XRPLAddress.validate(text)
        case .stellar: result = StellarKey.validateDestination(text)
        case .ton: result = TONAddress.validate(text)
        }
        if case .failure(let problem) = result, problem == .malformed || problem == .badChecksum,
           let other = guessFamily(text), other != chain.family {
            return .failure(.otherNetwork(other))
        }
        return result
    }

    /// Adivinha a familia de um texto que parece endereco. So para a mensagem de
    /// erro: nunca decide para onde o dinheiro vai.
    public static func guessFamily(_ text: String) -> ChainFamily? {
        if case .success = validateEVM(text) { return .evm }
        if case .success = validateTron(text) { return .tron }
        if case .success = XRPLAddress.validate(text) { return .xrpl }
        if case .success = StellarKey.validateDestination(text) { return .stellar }
        for chain in [Chain.bitcoin, .litecoin, .dogecoin] {
            if case .success = validateUTXO(text, chain: chain) { return .utxo }
        }
        if case .success = TONAddress.validate(text) { return .ton }
        if case .success = validateSolana(text) { return .solana }
        return nil
    }

    static func validateEVM(_ text: String) -> Result<Destination, Problem> {
        guard text.hasPrefix("0x") || text.hasPrefix("0X"), text.count == 42,
              let bytes = Hex.decode(text), bytes.count == 20
        else { return .failure(.malformed) }
        let body = text.dropFirst(2)
        let mixed = body.contains { $0.isUppercase } && body.contains { $0.isLowercase }
        let checksummed = eip55(bytes)
        // Caixa mista precisa bater com o EIP-55. Tudo minusculo ou tudo maiusculo
        // nao carrega checksum e e aceito, como em toda carteira.
        if mixed, checksummed != text { return .failure(.badChecksum) }
        return .success(Destination(address: checksummed, tag: nil))
    }

    static func validateTron(_ text: String) -> Result<Destination, Problem> {
        guard text.hasPrefix("T"), text.count == 34 else { return .failure(.malformed) }
        guard let payload = Base58.bitcoin.decodeCheck(text) else { return .failure(.badChecksum) }
        guard payload.count == 21, payload[0] == 0x41 else { return .failure(.malformed) }
        return .success(Destination(address: text, tag: nil))
    }

    static func validateSolana(_ text: String) -> Result<Destination, Problem> {
        guard (32...44).contains(text.count), let bytes = Base58.bitcoin.decode(text), bytes.count == 32 else {
            return .failure(.malformed)
        }
        return .success(Destination(address: text, tag: nil))
    }

    static func validateUTXO(_ text: String, chain: Chain) -> Result<Destination, Problem> {
        let params = UTXOParams.for(chain)
        if let hrp = params.bech32HRP, text.lowercased().hasPrefix(hrp + "1") {
            guard let decoded = Bech32.segwitDecode(hrp: hrp, address: text) else { return .failure(.badChecksum) }
            switch (decoded.version, decoded.program.count) {
            case (0, 20), (0, 32), (1, 32):
                return .success(Destination(address: text.lowercased(), tag: nil))
            default:
                return .failure(.unsupportedType)
            }
        }
        guard let payload = Base58.bitcoin.decodeCheck(text) else {
            return Base58.bitcoin.decode(text) == nil ? .failure(.malformed) : .failure(.badChecksum)
        }
        guard payload.count == 21, params.base58Versions.contains(payload[0]) else { return .failure(.malformed) }
        return .success(Destination(address: text, tag: nil))
    }
}

/// Parametros de endereco das redes UTXO.
public struct UTXOParams: Sendable {
    public let bech32HRP: String?
    public let p2pkhVersion: UInt8
    public let p2shVersion: UInt8
    /// Versoes de P2SH aceitas no envio (o Litecoin tem a antiga 0x05 e a nova 0x32).
    public let extraP2SHVersions: [UInt8]
    /// Menor saida que o no aceita como padrao, em satoshis, por tipo de script.
    public let dustP2WPKH: UInt64
    public let dustP2PKH: UInt64

    var base58Versions: [UInt8] { [p2pkhVersion, p2shVersion] + extraP2SHVersions }

    public static func `for`(_ chain: Chain) -> UTXOParams {
        switch chain.id {
        case "litecoin":
            return UTXOParams(bech32HRP: "ltc", p2pkhVersion: 0x30, p2shVersion: 0x32, extraP2SHVersions: [0x05], dustP2WPKH: 294, dustP2PKH: 546)
        case "dogecoin":
            return UTXOParams(bech32HRP: nil, p2pkhVersion: 0x1E, p2shVersion: 0x16, extraP2SHVersions: [], dustP2WPKH: 1_000_000, dustP2PKH: 1_000_000)
        default:
            return UTXOParams(bech32HRP: "bc", p2pkhVersion: 0x00, p2shVersion: 0x05, extraP2SHVersions: [], dustP2WPKH: 294, dustP2PKH: 546)
        }
    }
}

/// Enderecos do XRP Ledger: classico (r...) e X-address (X...), que carrega a tag.
public enum XRPLAddress {
    public static func accountID(_ address: String) -> [UInt8]? {
        guard address.hasPrefix("r"), let payload = Base58.ripple.decodeCheck(address), payload.count == 21, payload[0] == 0 else {
            return nil
        }
        return Array(payload.dropFirst())
    }

    static func validate(_ text: String) -> Result<Address.Destination, Address.Problem> {
        if text.hasPrefix("r") {
            guard (25...35).contains(text.count) else { return .failure(.malformed) }
            guard accountID(text) != nil else {
                return Base58.ripple.decode(text) == nil ? .failure(.malformed) : .failure(.badChecksum)
            }
            return .success(Address.Destination(address: text, tag: nil))
        }
        if text.hasPrefix("X") {
            // X-address: 0x05 0x44 (rede principal), 20 bytes de conta, flag, tag de
            // 64 bits em little-endian (so os 32 de baixo valem).
            guard let payload = Base58.ripple.decodeCheck(text), payload.count == 31 else { return .failure(.badChecksum) }
            guard payload[0] == 0x05, payload[1] == 0x44 else { return .failure(.malformed) }
            let account = Array(payload[2..<22])
            let flag = payload[22]
            let tagBytes = Array(payload[23..<31])
            let tag = tagBytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
            guard flag <= 1, tag <= UInt64(UInt32.max), flag == 1 || tag == 0 else { return .failure(.malformed) }
            let classic = Base58.ripple.encodeCheck([0x00] + account)
            return .success(Address.Destination(address: classic, tag: flag == 1 ? tag : nil))
        }
        return .failure(.malformed)
    }
}

/// StrKey da Stellar: conta G..., conta muxed M..., semente S... (nunca exibida).
public enum StellarKey {
    static let accountVersion: UInt8 = 6 << 3      // G
    static let muxedVersion: UInt8 = 12 << 3       // M

    public static func accountID(_ publicKey: [UInt8]) throws -> String {
        guard publicKey.count == 32 else { throw Address.Problem.malformed }
        return encode(version: accountVersion, payload: publicKey)
    }

    static func encode(version: UInt8, payload: [UInt8]) -> String {
        let body = [version] + payload
        let crc = CRC16.xmodem(body)
        return Base32.encode(body + [UInt8(crc & 0xFF), UInt8(crc >> 8)])
    }

    public static func decode(_ text: String, version: UInt8) -> [UInt8]? {
        guard let raw = Base32.decode(text), raw.count >= 3, raw[0] == version else { return nil }
        let body = Array(raw.dropLast(2))
        let crc = CRC16.xmodem(body)
        guard raw[raw.count - 2] == UInt8(crc & 0xFF), raw[raw.count - 1] == UInt8(crc >> 8) else { return nil }
        return Array(body.dropFirst())
    }

    public static func publicKey(of account: String) -> [UInt8]? {
        guard let key = decode(account, version: accountVersion), key.count == 32 else { return nil }
        return key
    }

    static func validateDestination(_ text: String) -> Result<Address.Destination, Address.Problem> {
        if text.hasPrefix("G") {
            guard text.count == 56 else { return .failure(.malformed) }
            guard publicKey(of: text) != nil else { return .failure(.badChecksum) }
            return .success(Address.Destination(address: text, tag: nil))
        }
        if text.hasPrefix("M") {
            // Conta muxed: chave de 32 bytes seguida do id de 64 bits em big-endian.
            guard text.count == 69, let raw = decode(text, version: muxedVersion), raw.count == 40 else {
                return .failure(.badChecksum)
            }
            let key = Array(raw.prefix(32))
            let id = raw.suffix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return .success(Address.Destination(address: encode(version: accountVersion, payload: key), tag: id))
        }
        return .failure(.malformed)
    }
}

/// Caminhos de derivacao padrao de cada rede, conta por conta.
public enum DefaultPaths {
    public static func path(for chain: Chain, account: UInt32 = 0) -> DerivationPath {
        let h = DerivationPath.hardened
        switch chain.id {
        case "bitcoin": return DerivationPath(components: [h(84), h(0), h(account), 0, 0])
        case "litecoin": return DerivationPath(components: [h(84), h(2), h(account), 0, 0])
        case "dogecoin": return DerivationPath(components: [h(44), h(3), h(account), 0, 0])
        case "solana": return DerivationPath(components: [h(44), h(501), h(account), h(0)])
        case "xrpl": return DerivationPath(components: [h(44), h(144), h(account), 0, 0])
        case "stellar": return DerivationPath(components: [h(44), h(148), h(account)])
        case "tron": return DerivationPath(components: [h(44), h(195), h(account), 0, 0])
        case "ton": return DerivationPath(components: [h(44), h(607), h(account)])
        default:
            // EVM: todas as redes compartilham a mesma conta, m/44'/60'/0'/0/i.
            return DerivationPath(components: [h(44), h(60), h(0), 0, account])
        }
    }
}
