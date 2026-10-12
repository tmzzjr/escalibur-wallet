import EscaliburCore
import Foundation

// A ponte de USDC pelo CCTP V2 da Circle: queima na origem, a Circle atesta, e o mesmo
// USDC nativo e cunhado no destino. Nao ha cofre de ponte nem token embrulhado: quem
// segura USDC ja confia na Circle, e a ponte nao acrescenta outro terceiro.
//
// Fonte: github.com/circlefin/evm-cctp-contracts, src/v2/TokenMessengerV2.sol:
//
//   depositForBurnWithHook(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient,
//       address burnToken, bytes32 destinationCaller, uint256 maxFee,
//       uint32 minFinalityThreshold, bytes hookData)
//
// O app monta a calldata sozinho: a API da Circle so diz a taxa. O resgate no destino
// fica com o Forwarding Service da Circle (o `hookData` abaixo), que envia o
// `receiveMessage` e cobra o gas em USDC dentro do `maxFee`; o dono nao precisa ter gas
// na rede de destino. Se o encaminhamento falhar, o proprio app pode resgatar com
// `receiveMessage(message, attestation)`, depois de conferir a mensagem (CCTPMessage).
//
// `destinationCaller` vai zerado: qualquer um pode enviar o resgate, e isso e o que o
// Forwarding Service exige. Nao abre brecha: o contrato de destino so cunha para o
// `mintRecipient` da mensagem atestada, entao quem enviar so paga o gas pelo dono.

public enum CCTPCalldata {
    public static let depositForBurnWithHook = try! ABIFunction(
        "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)"
    )
    public static let receiveMessage = try! ABIFunction("receiveMessage(bytes,bytes)")

    /// "cctp-forward" em bytes24, versao 0 e tamanho 0: o pedido de encaminhamento da
    /// Circle (developers.circle.com, "Transfer USDC with the Forwarding Service").
    public static let forwardHookData: [UInt8] = Array("cctp-forward".utf8) + [UInt8](repeating: 0, count: 20)

    /// Rapida: a Circle atesta antes da finalidade e cobra a taxa rapida. Padrao: espera
    /// a finalidade da origem e a taxa do protocolo e zero.
    public static let fastFinality: UInt32 = 1000
    public static let standardFinality: UInt32 = 2000

    public static func encodeDeposit(_ transfer: CCTPTransfer) throws -> [UInt8] {
        try depositForBurnWithHook.encodeCall([
            .uint(transfer.amount),
            .uint(BigUInt(transfer.destinationDomain)),
            .fixedBytes(CCTPMessage.word(transfer.recipient)),
            .address(transfer.usdc),
            .fixedBytes([UInt8](repeating: 0, count: 32)),
            .uint(transfer.maxFee),
            .uint(BigUInt(transfer.finality)),
            .bytes(forwardHookData),
        ])
    }

    public static func encodeReceive(message: [UInt8], attestation: [UInt8]) throws -> [UInt8] {
        try receiveMessage.encodeCall([.bytes(message), .bytes(attestation)])
    }
}

/// Uma transferencia de USDC pelo CCTP, como o app a pediu.
public struct CCTPTransfer: Sendable, Equatable {
    public let sourceDomain: UInt32
    public let destinationDomain: UInt32
    /// O USDC nativo da rede de origem.
    public let usdc: EVMAddress
    /// O dono na origem (quem queima) e no destino (quem recebe). Na v1, a mesma conta.
    public let owner: EVMAddress
    public let recipient: EVMAddress
    /// O que sai da carteira. O que chega e isto menos a taxa cobrada, ate `maxFee`.
    public let amount: BigUInt
    public let maxFee: BigUInt
    public let finality: UInt32

    public init(
        sourceDomain: UInt32, destinationDomain: UInt32, usdc: EVMAddress, owner: EVMAddress, recipient: EVMAddress,
        amount: BigUInt, maxFee: BigUInt, finality: UInt32
    ) {
        self.sourceDomain = sourceDomain
        self.destinationDomain = destinationDomain
        self.usdc = usdc
        self.owner = owner
        self.recipient = recipient
        self.amount = amount
        self.maxFee = maxFee
        self.finality = finality
    }

    /// O minimo que chega: tudo menos a taxa maxima.
    public var minimumReceived: BigUInt { maxFee < amount ? amount - maxFee : 0 }
}

/// Por que uma mensagem do CCTP nao serve para resgatar.
public enum CCTPMismatch: Error, Equatable, Sendable {
    case domain
    case messenger
    case token
    case recipient
    case sender
    case amount
    case fee
    case caller
    case hook
}

extension CCTPMessage {
    /// A mensagem e a da transferencia que o dono assinou? Confere cada campo que decide
    /// para onde vai o dinheiro e quanto. Os dois TokenMessengerV2 sao os compilados da
    /// origem e do destino.
    public func check(_ transfer: CCTPTransfer, sourceMessenger: EVMAddress, destinationMessenger: EVMAddress) throws {
        guard sourceDomain == transfer.sourceDomain, destinationDomain == transfer.destinationDomain else { throw CCTPMismatch.domain }
        guard sender == Self.word(sourceMessenger), recipient == Self.word(destinationMessenger) else { throw CCTPMismatch.messenger }
        guard burnToken == Self.word(transfer.usdc) else { throw CCTPMismatch.token }
        guard try Self.evmAddress(mintRecipient, "mintRecipient") == transfer.recipient else { throw CCTPMismatch.recipient }
        guard try Self.evmAddress(messageSender, "messageSender") == transfer.owner else { throw CCTPMismatch.sender }
        guard amount == transfer.amount else { throw CCTPMismatch.amount }
        guard maxFee == transfer.maxFee, feeExecuted <= maxFee else { throw CCTPMismatch.fee }
        guard destinationCaller.allSatisfy({ $0 == 0 }) else { throw CCTPMismatch.caller }
        guard hookData == CCTPCalldata.forwardHookData else { throw CCTPMismatch.hook }
    }
}
