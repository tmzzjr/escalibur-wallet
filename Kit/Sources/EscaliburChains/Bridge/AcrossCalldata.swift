import EscaliburCore
import Foundation

// A ponte pelo Across, para o que nao e USDC (ETH, USDT, WBTC): o dono deposita no
// SpokePool da origem, um relayer entrega do proprio bolso no destino em segundos, e o
// Across reembolsa o relayer depois. Se ninguem entregar ate o `fillDeadline`, o deposito
// volta para o dono na origem. O risco do dono fica no tempo entre o deposito e a
// entrega, e no proprio SpokePool.
//
// Fonte: github.com/across-protocol/contracts, contracts/spoke-pools/SpokePool.sol:
//
//   deposit(bytes32 depositor, bytes32 recipient, bytes32 inputToken, bytes32 outputToken,
//           uint256 inputAmount, uint256 outputAmount, uint256 destinationChainId,
//           bytes32 exclusiveRelayer, uint32 quoteTimestamp, uint32 fillDeadline,
//           uint32 exclusivityParameter, bytes message)
//
// O que o contrato garante, lido do fonte (`_depositV3`): `quoteTimestamp` dentro da
// janela do contrato, `fillDeadline` ate `agora + fillDeadlineBuffer`, `msg.value` igual a
// `inputAmount` quando entra nativo (ele embrulha) e zero nos outros casos, e o token
// puxado do `msg.sender`. Na entrega, saida em WETH para conta comum chega como ETH
// (`_unwrapwrappedNativeTokenTo`).
//
// O app monta a calldata sozinho. A API do Across so sugere o `outputAmount` (o valor
// menos a taxa do relayer), o relayer exclusivo e o prazo. O app confere: destinatario e
// depositante sao o dono, `message` vazio (nenhuma chamada no destino), tokens da lista
// compilada para aquela rota, taxa ate o teto.

public enum AcrossCalldata {
    public static let deposit = try! ABIFunction(
        "deposit(bytes32,bytes32,bytes32,bytes32,uint256,uint256,uint256,bytes32,uint32,uint32,uint32,bytes)"
    )

    public static func encode(_ transfer: AcrossTransfer) throws -> [UInt8] {
        try deposit.encodeCall([
            .fixedBytes(CCTPMessage.word(transfer.owner)),
            .fixedBytes(CCTPMessage.word(transfer.recipient)),
            .fixedBytes(CCTPMessage.word(transfer.inputToken)),
            .fixedBytes(CCTPMessage.word(transfer.outputToken)),
            .uint(transfer.inputAmount),
            .uint(transfer.outputAmount),
            .uint(BigUInt(transfer.destinationChainID)),
            .fixedBytes(CCTPMessage.word(transfer.exclusiveRelayer ?? EVMAddress(uncheckedBytes: [UInt8](repeating: 0, count: 20)))),
            .uint(BigUInt(transfer.quoteTimestamp)),
            .uint(BigUInt(transfer.fillDeadline)),
            .uint(BigUInt(transfer.exclusivityDeadline)),
            .bytes([]),
        ])
    }
}

/// Um deposito no Across, como o app o pediu.
public struct AcrossTransfer: Sendable, Equatable {
    public let originChainID: UInt64
    public let destinationChainID: UInt64
    public let owner: EVMAddress
    public let recipient: EVMAddress
    /// Na origem: o token, ou o WETH quando sai ETH nativo (com `value` igual ao valor).
    public let inputToken: EVMAddress
    /// No destino: o mesmo ativo, na versao da lista compilada.
    public let outputToken: EVMAddress
    public let inputAmount: BigUInt
    /// O que o relayer tem de entregar. O contrato de destino so aceita a entrega desse
    /// valor exato para o `recipient`.
    public let outputAmount: BigUInt
    public let exclusiveRelayer: EVMAddress?
    public let quoteTimestamp: UInt32
    public let fillDeadline: UInt32
    /// Segundos Unix absolutos (acima do teto de periodo do contrato, entao lidos como
    /// prazo e nao como intervalo), ou zero sem exclusividade.
    public let exclusivityDeadline: UInt32
    /// ETH nativo: o deposito leva `value` igual ao valor.
    public let nativeInput: Bool

    public init(
        originChainID: UInt64, destinationChainID: UInt64, owner: EVMAddress, recipient: EVMAddress, inputToken: EVMAddress,
        outputToken: EVMAddress, inputAmount: BigUInt, outputAmount: BigUInt, exclusiveRelayer: EVMAddress?,
        quoteTimestamp: UInt32, fillDeadline: UInt32, exclusivityDeadline: UInt32, nativeInput: Bool
    ) {
        self.originChainID = originChainID
        self.destinationChainID = destinationChainID
        self.owner = owner
        self.recipient = recipient
        self.inputToken = inputToken
        self.outputToken = outputToken
        self.inputAmount = inputAmount
        self.outputAmount = outputAmount
        self.exclusiveRelayer = exclusiveRelayer
        self.quoteTimestamp = quoteTimestamp
        self.fillDeadline = fillDeadline
        self.exclusivityDeadline = exclusivityDeadline
        self.nativeInput = nativeInput
    }

    public var value: BigUInt { nativeInput ? inputAmount : 0 }
}
