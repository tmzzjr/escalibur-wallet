import EscaliburCore
import Foundation

/// Os tipos de script de saida que a carteira sabe pagar.
public enum UTXOScriptType: String, Sendable, CaseIterable, Codable {
    case p2pkh
    case p2sh
    case p2wpkh
    case p2wsh
    case p2tr

    /// Bytes do scriptPubKey: `76a914{20}88ac`, `a914{20}87`, `0014{20}`,
    /// `0020{32}`, `5120{32}`.
    public var scriptLength: Int {
        switch self {
        case .p2pkh: return 25
        case .p2sh: return 23
        case .p2wpkh: return 22
        case .p2wsh, .p2tr: return 34
        }
    }

    /// Tamanho da saida serializada: valor (8), comprimento (1) e script.
    public var outputSize: Int { 8 + 1 + scriptLength }

    public var isWitnessProgram: Bool {
        switch self {
        case .p2wpkh, .p2wsh, .p2tr: return true
        case .p2pkh, .p2sh: return false
        }
    }
}

/// As entradas que a carteira sabe assinar, uma por esquema de derivacao.
///
/// Taproot (BIP-86) fica de fora nesta versao: o gasto por key-path pede o sighash
/// do BIP-341 e a chave ajustada, que o assinador ainda nao faz.
public enum UTXOInputKind: String, Sendable, CaseIterable, Codable {
    /// BIP-84, `m/84'/c'/a'/x/i`. Padrao da carteira no Bitcoin e no Litecoin.
    case p2wpkh
    /// BIP-49, `m/49'/c'/a'/x/i`. So para carteira importada.
    case p2shP2wpkh
    /// BIP-44, `m/44'/c'/a'/x/i`. Padrao no Dogecoin; importacao nos outros.
    case p2pkh

    /// O `purpose` do caminho que corresponde a este tipo.
    public var purpose: UInt32 {
        switch self {
        case .p2wpkh: return 84
        case .p2shP2wpkh: return 49
        case .p2pkh: return 44
        }
    }

    public init?(purpose: UInt32) {
        guard let kind = Self.allCases.first(where: { $0.purpose == purpose }) else { return nil }
        self = kind
    }

    public var isSegwit: Bool { self != .p2pkh }

    /// O tipo da saida que este esquema recebe (e do troco que volta para ele).
    public var outputType: UTXOScriptType {
        switch self {
        case .p2wpkh: return .p2wpkh
        case .p2shP2wpkh: return .p2sh
        case .p2pkh: return .p2pkh
        }
    }

    /// O scriptPubKey que uma chave publica comprimida gera neste esquema.
    public func scriptPubKey(publicKey: [UInt8]) -> [UInt8] {
        let hash = Hash.hash160(publicKey)
        switch self {
        case .p2wpkh: return UTXOScript.p2wpkh(hash)
        case .p2shP2wpkh: return UTXOScript.p2sh(Hash.hash160(UTXOScript.p2wpkh(hash)))
        case .p2pkh: return UTXOScript.p2pkh(hash)
        }
    }

    /// Peso da entrada ja assinada, no pior caso de assinatura: DER de 71 bytes
    /// (R com 33, S low-S com 32) mais o byte de sighash. O assinador nao faz
    /// "grinding" de R, entao 72 e o teto real, e a taxa nunca fica abaixo da escolhida.
    ///
    /// Outpoint (36) + sequence (4) entram sempre; o resto depende do tipo:
    /// - P2WPKH: scriptSig vazio (1 byte) e witness `02 48 <sig> 21 <pub>` (108 WU).
    ///   (41 * 4 + 108) = 272 WU = 68 vB.
    /// - P2SH-P2WPKH: scriptSig `17 16 0014{20}` (24 bytes) e a mesma witness.
    ///   (64 * 4 + 108) = 364 WU = 91 vB.
    /// - P2PKH: scriptSig `6b 48 <sig> 21 <pub>` (107 bytes e 1 de tamanho), sem witness.
    ///   148 * 4 = 592 WU = 148 vB.
    public var inputWeight: Int { nonWitnessSize * 4 + witnessSize }

    /// Bytes da entrada fora da witness: outpoint, scriptSig com o seu tamanho, sequence.
    public var nonWitnessSize: Int {
        switch self {
        case .p2wpkh: return 36 + 1 + 4
        case .p2shP2wpkh: return 36 + 1 + 23 + 4
        case .p2pkh: return 36 + 1 + (1 + UTXOSigning.maxSignatureLength + 1 + 33) + 4
        }
    }

    /// Bytes de witness: contagem, assinatura e chave, cada uma com o seu tamanho.
    public var witnessSize: Int {
        isSegwit ? 1 + 1 + UTXOSigning.maxSignatureLength + 1 + 33 : 0
    }
}

/// Construcao e leitura de scriptPubKey.
public enum UTXOScript {
    public static func p2pkh(_ hash: [UInt8]) -> [UInt8] { [0x76, 0xA9, 0x14] + hash + [0x88, 0xAC] }
    public static func p2sh(_ hash: [UInt8]) -> [UInt8] { [0xA9, 0x14] + hash + [0x87] }
    public static func p2wpkh(_ hash: [UInt8]) -> [UInt8] { [0x00, 0x14] + hash }
    public static func p2wsh(_ hash: [UInt8]) -> [UInt8] { [0x00, 0x20] + hash }
    public static func p2tr(_ key: [UInt8]) -> [UInt8] { [0x51, 0x20] + key }

    /// Reconhece um scriptPubKey padrao e devolve tipo e programa (hash ou chave).
    public static func classify(_ script: [UInt8]) -> (type: UTXOScriptType, program: [UInt8])? {
        switch script.count {
        case 25 where script[0] == 0x76 && script[1] == 0xA9 && script[2] == 0x14 && script[23] == 0x88 && script[24] == 0xAC:
            return (.p2pkh, Array(script[3..<23]))
        case 23 where script[0] == 0xA9 && script[1] == 0x14 && script[22] == 0x87:
            return (.p2sh, Array(script[2..<22]))
        case 22 where script[0] == 0x00 && script[1] == 0x14:
            return (.p2wpkh, Array(script[2...]))
        case 34 where script[0] == 0x00 && script[1] == 0x20:
            return (.p2wsh, Array(script[2...]))
        case 34 where script[0] == 0x51 && script[1] == 0x20:
            return (.p2tr, Array(script[2...]))
        default:
            return nil
        }
    }

    /// O scriptPubKey de um endereco, depois de validar o endereco para a rede.
    ///
    /// Passa pela mesma validacao de `Address.validate` (checksum, HRP, versao,
    /// tamanho do programa) e so entao monta o script. Versao de witness 2 ou mais
    /// e recusada: o dinheiro iria para um script que ainda nao tem regra de gasto.
    public static func scriptPubKey(for address: String, chain: Chain) throws -> [UInt8] {
        guard chain.family == .utxo else { throw Address.Problem.otherNetwork(chain) }
        let destination: Address.Destination
        switch Address.validate(address, for: chain) {
        case .success(let d): destination = d
        case .failure(let problem): throw problem
        }
        let params = UTXOParams.for(chain)
        if let hrp = params.bech32HRP, destination.address.hasPrefix(hrp + "1") {
            guard let decoded = Bech32.segwitDecode(hrp: hrp, address: destination.address) else { throw Address.Problem.badChecksum }
            switch (decoded.version, decoded.program.count) {
            case (0, 20): return p2wpkh(decoded.program)
            case (0, 32): return p2wsh(decoded.program)
            case (1, 32): return p2tr(decoded.program)
            default: throw Address.Problem.unsupportedType
            }
        }
        guard let payload = Base58.bitcoin.decodeCheck(destination.address), payload.count == 21 else {
            throw Address.Problem.malformed
        }
        let hash = Array(payload.dropFirst())
        if payload[0] == params.p2pkhVersion { return p2pkh(hash) }
        if payload[0] == params.p2shVersion || params.extraP2SHVersions.contains(payload[0]) { return p2sh(hash) }
        throw Address.Problem.malformed
    }

    /// O endereco de um scriptPubKey padrao. No Litecoin, P2SH sai sempre na forma
    /// nova (M...), para nunca parecer um endereco de Bitcoin.
    public static func address(for script: [UInt8], chain: Chain) -> String? {
        guard chain.family == .utxo, let (type, program) = classify(script) else { return nil }
        let params = UTXOParams.for(chain)
        switch type {
        case .p2pkh: return Base58.bitcoin.encodeCheck([params.p2pkhVersion] + program)
        case .p2sh: return Base58.bitcoin.encodeCheck([params.p2shVersion] + program)
        case .p2wpkh, .p2wsh:
            guard let hrp = params.bech32HRP else { return nil }
            return Bech32.segwitEncode(hrp: hrp, version: 0, program: program)
        case .p2tr:
            guard let hrp = params.bech32HRP else { return nil }
            return Bech32.segwitEncode(hrp: hrp, version: 1, program: program)
        }
    }

    /// Empurra dados na pilha com o opcode minimo (BIP-62).
    static func push(_ data: [UInt8]) -> [UInt8] {
        switch data.count {
        case 0..<0x4C: return [UInt8(data.count)] + data
        case 0x4C...0xFF: return [0x4C, UInt8(data.count)] + data
        default: return [0x4D] + UInt16(data.count).littleEndianByteArray + data
        }
    }
}

// MARK: Dust

public extension UTXOParams {
    /// Menor valor de saida que o no repassa, por tipo de script.
    ///
    /// Bitcoin e Litecoin: a regra do `GetDustThreshold` do Core, com dustrelayfee
    /// de 3 sat/vB: (tamanho da saida + custo de gasta-la) x 3. Da 546 (P2PKH),
    /// 540 (P2SH), 294 (P2WPKH) e 330 (P2WSH, P2TR). Os valores de P2PKH e P2WPKH
    /// vem de `UTXOParams`, os outros da mesma formula.
    ///
    /// Dogecoin: limite fixo por saida, qualquer que seja o script (0,01 DOGE no
    /// Dogecoin Core 1.14). [P]
    func dustThreshold(for type: UTXOScriptType, chain: Chain) -> UInt64 {
        if chain.id == Chain.dogecoin.id { return dustP2PKH }
        switch type {
        case .p2pkh: return dustP2PKH
        case .p2wpkh: return dustP2WPKH
        case .p2sh, .p2wsh, .p2tr:
            let spend = type.isWitnessProgram ? 32 + 4 + 1 + 107 / 4 + 4 : 32 + 4 + 1 + 107 + 4
            return UInt64(type.outputSize + spend) * UTXORules.dustRelayFeePerVByte
        }
    }
}
