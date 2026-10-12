import EscaliburCore
import Foundation

// A mensagem do CCTP V2 da Circle, lida byte a byte antes de qualquer assinatura de
// resgate.
//
// Fonte: github.com/circlefin/evm-cctp-contracts, src/messages/v2/MessageV2.sol e
// src/messages/v2/BurnMessageV2.sol. O layout e `abi.encodePacked`, sem preenchimento:
//
//   MessageV2: version u32 @0, sourceDomain u32 @4, destinationDomain u32 @8,
//              nonce b32 @12, sender b32 @44, recipient b32 @76, destinationCaller b32 @108,
//              minFinalityThreshold u32 @140, finalityThresholdExecuted u32 @144,
//              messageBody @148
//   BurnMessageV2 (o messageBody): version u32 @0, burnToken b32 @4, mintRecipient b32 @36,
//              amount u256 @68, messageSender b32 @100, maxFee u256 @132,
//              feeExecuted u256 @164, expirationBlock u256 @196, hookData @228
//
// A Iris (a API publica da Circle) devolve a mensagem e a attestation. A attestation e
// conferida pelo contrato de destino, com as chaves da Circle; o app nao confia nela para
// nada. O que o app confere e a propria mensagem: que ela cunha o USDC certo, no valor
// certo, para a conta do dono, na rede certa. Uma Iris comprometida que trocasse a
// mensagem por outra (de outra pessoa, de outro valor) e recusada aqui.

/// A mensagem do CCTP V2 com o corpo de queima, decodificada.
public struct CCTPMessage: Sendable, Equatable {
    public static let version: UInt32 = 1
    public static let burnBodyVersion: UInt32 = 1
    static let headerLength = 148
    static let burnBodyFixedLength = 228

    public let sourceDomain: UInt32
    public let destinationDomain: UInt32
    public let nonce: [UInt8]
    /// O TokenMessengerV2 de origem.
    public let sender: [UInt8]
    /// O TokenMessengerV2 de destino.
    public let recipient: [UInt8]
    public let destinationCaller: [UInt8]
    public let minFinalityThreshold: UInt32
    public let finalityThresholdExecuted: UInt32

    /// O USDC queimado na origem.
    public let burnToken: [UInt8]
    public let mintRecipient: [UInt8]
    public let amount: BigUInt
    /// Quem chamou depositForBurn na origem.
    public let messageSender: [UInt8]
    public let maxFee: BigUInt
    public let feeExecuted: BigUInt
    public let expirationBlock: BigUInt
    public let hookData: [UInt8]

    public enum Problem: Error, Equatable, Sendable {
        case tooShort
        case unknownVersion
        case unknownBodyVersion
        case badAddressWord(String)
    }

    public init(_ bytes: [UInt8]) throws {
        guard bytes.count >= Self.headerLength + Self.burnBodyFixedLength else { throw Problem.tooShort }
        func u32(_ at: Int) -> UInt32 { bytes[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) } }
        func word(_ at: Int) -> [UInt8] { Array(bytes[at..<(at + 32)]) }

        guard u32(0) == Self.version else { throw Problem.unknownVersion }
        sourceDomain = u32(4)
        destinationDomain = u32(8)
        nonce = word(12)
        sender = word(44)
        recipient = word(76)
        destinationCaller = word(108)
        minFinalityThreshold = u32(140)
        finalityThresholdExecuted = u32(144)

        let body = Self.headerLength
        guard u32(body) == Self.burnBodyVersion else { throw Problem.unknownBodyVersion }
        burnToken = word(body + 4)
        mintRecipient = word(body + 36)
        amount = BigUInt(bigEndian: word(body + 68))
        messageSender = word(body + 100)
        maxFee = BigUInt(bigEndian: word(body + 132))
        feeExecuted = BigUInt(bigEndian: word(body + 164))
        expirationBlock = BigUInt(bigEndian: word(body + 196))
        hookData = Array(bytes[(body + Self.burnBodyFixedLength)...])
    }

    /// Um endereco EVM dentro de uma palavra de 32 bytes: 12 zeros e os 20 do endereco.
    /// Qualquer coisa nos 12 de cima e recusada (seria outro endereco em outra rede).
    public static func evmAddress(_ word: [UInt8], _ field: String) throws -> EVMAddress {
        guard word.count == 32, word.prefix(12).allSatisfy({ $0 == 0 }) else { throw Problem.badAddressWord(field) }
        return EVMAddress(uncheckedBytes: Array(word.suffix(20)))
    }

    /// A palavra de 32 bytes de um endereco EVM.
    public static func word(_ address: EVMAddress) -> [UInt8] {
        [UInt8](repeating: 0, count: 12) + address.bytes
    }

    /// O que o dono vai receber no destino: o valor queimado menos a taxa cobrada.
    public var mintedAmount: BigUInt { feeExecuted <= amount ? amount - feeExecuted : 0 }
}
