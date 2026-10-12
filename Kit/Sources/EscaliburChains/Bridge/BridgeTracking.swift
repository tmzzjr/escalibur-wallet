import EscaliburCore
import Foundation

// A ponte depois do deposito: o registro que o app guarda e a conferencia da chegada.
//
// O registro guarda a transferencia que o dono assinou, nao o que a API disse. A chegada
// so conta quando o destino mostra, em dois RPCs, a entrega com esses mesmos campos:
// - CCTP: a mensagem atestada pela Circle bate campo a campo com a queima
//   (CCTPMessage.check), e o recibo da entrega tem o Transfer do USDC do destino para o
//   dono, com o valor da mensagem menos a taxa cobrada;
// - Across: o recibo da entrega tem o FilledRelay do SpokePool do destino com o
//   depositante, o destinatario, os tokens e os valores do deposito, sem alteracao.

/// Uma ponte em andamento ou terminada, como o app guarda.
public struct BridgeRecord: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case pending, arrived, refunded, failed }

    public let id: UUID
    public let walletID: UUID
    public let route: BridgeRoute
    public let asset: BridgeAsset
    public let fromChainID: String
    public let toChainID: String
    public let owner: String
    /// Valores inteiros em texto decimal.
    public let amount: String
    public let minimumReceived: String
    /// CCTP: o teto de taxa e a finalidade assinados.
    public let maxFee: String?
    public let finality: UInt32?
    /// Across: o valor que o relayer tem de entregar e os prazos assinados.
    public let outputAmount: String?
    public let quoteTimestamp: UInt32?
    public let fillDeadline: UInt32?
    public let depositTxHash: String
    public let createdAt: Date
    public var state: State
    /// A transacao de entrega no destino (ou de reembolso na origem), conferida.
    public var settledTxHash: String?
    public var receivedAmount: String?

    public init(quote: ValidatedBridgeQuote, walletID: UUID, depositTxHash: String, now: Date = .now) {
        id = UUID()
        self.walletID = walletID
        route = quote.route
        asset = quote.intent.asset
        fromChainID = quote.intent.from.chain.id
        toChainID = quote.intent.to.chain.id
        owner = quote.intent.owner.checksummed
        amount = quote.intent.amount.decimalString
        minimumReceived = quote.minimumReceived.decimalString
        switch quote.call {
        case .cctp(let transfer):
            maxFee = transfer.maxFee.decimalString
            finality = transfer.finality
            outputAmount = nil
            quoteTimestamp = nil
            fillDeadline = nil
        case .across(let transfer):
            maxFee = nil
            finality = nil
            outputAmount = transfer.outputAmount.decimalString
            quoteTimestamp = transfer.quoteTimestamp
            fillDeadline = transfer.fillDeadline
        }
        self.depositTxHash = depositTxHash.lowercased()
        createdAt = now
        state = .pending
    }

    public var from: BridgeChain? { Chain.find(fromChainID).flatMap(BridgeAllowlist.chain) }
    public var to: BridgeChain? { Chain.find(toChainID).flatMap(BridgeAllowlist.chain) }
    public var ownerAddress: EVMAddress? { try? EVMAddress(owner) }

    /// A queima como foi assinada.
    public var cctpTransfer: CCTPTransfer? {
        guard route.isCCTP, let from, let to, let owner = ownerAddress, let amount = BigUInt(decimal: amount),
              let maxFee = maxFee.flatMap(BigUInt.init(decimal:)), let finality
        else { return nil }
        return CCTPTransfer(sourceDomain: from.cctpDomain, destinationDomain: to.cctpDomain, usdc: from.usdc, owner: owner,
                            recipient: owner, amount: amount, maxFee: maxFee, finality: finality)
    }

    /// O deposito como foi assinado.
    public var acrossTransfer: AcrossTransfer? {
        guard route == .across, let from, let to, let owner = ownerAddress, let amount = BigUInt(decimal: amount),
              let output = outputAmount.flatMap(BigUInt.init(decimal:)), let quoteTimestamp, let fillDeadline
        else { return nil }
        return AcrossTransfer(
            originChainID: from.chain.evmChainID ?? 0, destinationChainID: to.chain.evmChainID ?? 0, owner: owner, recipient: owner,
            inputToken: asset.contract(on: from) ?? from.wrappedNative, outputToken: asset.contract(on: to) ?? to.wrappedNative,
            inputAmount: amount, outputAmount: output, exclusiveRelayer: nil, quoteTimestamp: quoteTimestamp, fillDeadline: fillDeadline,
            exclusivityDeadline: 0, nativeInput: asset == .eth
        )
    }
}

public enum BridgeArrival {
    static let filledRelayTopic = Hash.keccak256(Array(
        "FilledRelay(bytes32,bytes32,uint256,uint256,uint256,uint256,uint256,uint32,uint32,bytes32,bytes32,bytes32,bytes32,bytes32,(bytes32,bytes32,uint256,uint8))".utf8))
    static let filledRelayData = try! ABIFunction(
        "e(bytes32,bytes32,uint256,uint256,uint256,uint32,uint32,bytes32,bytes32,bytes32,bytes32,(bytes32,bytes32,uint256,uint8))")

    /// O recibo de entrega tem o FilledRelay deste deposito, sem alteracao de destino nem
    /// de valor? `logs` vem de dois RPCs concordando.
    public static func acrossDelivered(_ logs: [TradeSimulatedLog], transfer: AcrossTransfer, destinationSpoke: EVMAddress) -> Bool {
        let owner = CCTPMessage.word(transfer.owner)
        return logs.contains { log in
            guard log.address == destinationSpoke, log.topics.count == 4, log.topics[0] == filledRelayTopic,
                  BigUInt(bigEndian: log.topics[1]) == BigUInt(transfer.originChainID),
                  let fields = try? filledRelayData.decodeCall(filledRelayData.selector + log.data), fields.count == 12,
                  case .tuple(let info) = fields[11], info.count == 4
            else { return false }
            return fields[0] == .fixedBytes(CCTPMessage.word(transfer.inputToken))
                && fields[1] == .fixedBytes(CCTPMessage.word(transfer.outputToken))
                && fields[2] == .uint(transfer.inputAmount)
                && fields[3] == .uint(transfer.outputAmount)
                && fields[8] == .fixedBytes(owner)
                && fields[9] == .fixedBytes(owner)
                && info[0] == .fixedBytes(owner)
                && info[2] == .uint(transfer.outputAmount)
        }
    }
}
