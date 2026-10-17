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
    /// Legacy Mesh: a conta Tron que recebe (base58) e a taxa de mensagem assinada.
    public let tronRecipient: String?
    public let messageFee: String?
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
        tronRecipient = quote.intent.tronRecipient?.base58
        switch quote.call {
        case .cctp(let transfer):
            maxFee = transfer.maxFee.decimalString
            finality = transfer.finality
            outputAmount = nil
            quoteTimestamp = nil
            fillDeadline = nil
            messageFee = nil
        case .across(let transfer):
            maxFee = nil
            finality = nil
            outputAmount = transfer.outputAmount.decimalString
            quoteTimestamp = transfer.quoteTimestamp
            fillDeadline = transfer.fillDeadline
            messageFee = nil
        case .mesh(let transfer):
            maxFee = nil
            finality = nil
            outputAmount = nil
            quoteTimestamp = nil
            fillDeadline = nil
            messageFee = transfer.nativeFee.decimalString
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
        guard route.isCCTP, let from, let to, let source = from.cctp, let destination = to.cctp, let owner = ownerAddress,
              let amount = BigUInt(decimal: amount), let maxFee = maxFee.flatMap(BigUInt.init(decimal:)), let finality
        else { return nil }
        return CCTPTransfer(sourceDomain: source.domain, destinationDomain: destination.domain, usdc: from.usdc, owner: owner,
                            recipient: owner, amount: amount, maxFee: maxFee, finality: finality)
    }

    /// O envio para a Tron como foi assinado.
    public var meshTransfer: MeshTransfer? {
        guard route == .usdt0, let from, let source = from.mesh, let owner = ownerAddress,
              let recipient = tronRecipient.flatMap(TronAddress.init(base58:)),
              let amount = BigUInt(decimal: amount), let minimum = BigUInt(decimal: minimumReceived),
              let fee = messageFee.flatMap(BigUInt.init(decimal:))
        else { return nil }
        return MeshTransfer(sourceChainID: source.chainID, oft: source.oft, owner: owner, recipient: recipient, amount: amount,
                            minimumReceived: minimum, nativeFee: fee)
    }

    /// O deposito como foi assinado.
    public var acrossTransfer: AcrossTransfer? {
        guard route == .across, let from, let to, let fromAcross = from.across, let toAcross = to.across, let owner = ownerAddress,
              let amount = BigUInt(decimal: amount), let output = outputAmount.flatMap(BigUInt.init(decimal:)), let quoteTimestamp,
              let fillDeadline
        else { return nil }
        return AcrossTransfer(
            originChainID: from.chain.evmChainID ?? 0, destinationChainID: to.chain.evmChainID ?? 0, owner: owner, recipient: owner,
            inputToken: asset.contract(on: from) ?? fromAcross.wrappedNative, outputToken: asset.contract(on: to) ?? toAcross.wrappedNative,
            inputAmount: amount, outputAmount: output, exclusiveRelayer: nil, quoteTimestamp: quoteTimestamp, fillDeadline: fillDeadline,
            exclusivityDeadline: 0, nativeInput: asset.isNativeInput(on: from)
        )
    }
}

public enum BridgeArrival {
    // MARK: Legacy Mesh (Tron)

    /// `OFTReceived(bytes32 indexed guid, uint32 srcEid, address indexed toAddress, uint256 amountReceivedLD)`.
    public static let oftReceivedTopic = Hash.keccak256(Array("OFTReceived(bytes32,uint32,address,uint256)".utf8))

    /// O `guid` da mensagem do envio para a Tron, lido do OFTSent do proprio recibo do envio na
    /// origem (`logs` de dois RPCs concordando), com os campos que o dono assinou. nil: o recibo
    /// nao tem este envio.
    public static func meshGUID(_ logs: [TradeSimulatedLog], transfer: MeshTransfer) -> [UInt8]? {
        for log in logs {
            guard log.address == transfer.oft, log.topics.count == 3, log.topics[0] == USDT0Mesh.oftSentTopic,
                  log.topics[2] == CCTPMessage.word(transfer.owner), log.data.count == 96,
                  BigUInt(bigEndian: Array(log.data[0..<32])) == BigUInt(USDT0Mesh.tronEID),
                  BigUInt(bigEndian: Array(log.data[32..<64])) == transfer.amount,
                  BigUInt(bigEndian: Array(log.data[64..<96])) >= transfer.minimumReceived
            else { continue }
            return log.topics[1]
        }
        return nil
    }

    /// A entrega na Tron: o OFTReceived do UsdtOFT da Tron com este `guid`, para a conta Tron
    /// do dono, vindo da rede de origem, e o Transfer do USDT da Tron do UsdtOFT para a mesma
    /// conta, com o mesmo valor, pelo menos o minimo assinado. Devolve o valor entregue.
    public static func meshDelivered(_ logs: [TradeSimulatedLog], transfer: MeshTransfer, guid: [UInt8], sourceEID: UInt32) -> BigUInt? {
        let oft = EVMAddress(uncheckedBytes: USDT0Mesh.tronOFT.account20)
        let usdt = EVMAddress(uncheckedBytes: USDT0Mesh.tronUSDT.account20)
        let recipient = USDT0Mesh.recipientWord(transfer.recipient)
        var received: BigUInt?
        for log in logs where log.address == oft {
            guard log.topics.count == 3, log.topics[0] == oftReceivedTopic, log.topics[1] == guid else { continue }
            guard log.topics[2] == recipient, log.data.count == 64,
                  BigUInt(bigEndian: Array(log.data[0..<32])) == BigUInt(sourceEID)
            else { return nil }
            received = BigUInt(bigEndian: Array(log.data[32..<64]))
        }
        guard let received, received >= transfer.minimumReceived, received <= transfer.amount else { return nil }
        let paid = logs.contains { log in
            guard log.address == usdt, let paid = TradeSimulationCheck.parseTransfer(log) else { return false }
            return paid.from == oft && USDT0Mesh.recipientWord(TronAddress(account20: paid.to.bytes) ?? USDT0Mesh.tronOFT) == recipient
                && paid.value == received
        }
        return paid ? received : nil
    }

    public static let filledRelayTopic = Hash.keccak256(Array(
        "FilledRelay(bytes32,bytes32,uint256,uint256,uint256,uint256,uint256,uint32,uint32,bytes32,bytes32,bytes32,bytes32,bytes32,(bytes32,bytes32,uint256,uint8))".utf8))
    static let filledRelayData = try! ABIFunction(
        "e(bytes32,bytes32,uint256,uint256,uint256,uint32,uint32,bytes32,bytes32,bytes32,bytes32,(bytes32,bytes32,uint256,uint8))")

    /// O `depositId` que o SpokePool da origem deu a este deposito, lido do FundsDeposited
    /// do proprio recibo do deposito (`logs` de dois RPCs concordando), com os campos que
    /// o app assinou. nil: o recibo nao tem este deposito.
    public static func acrossDepositID(_ logs: [TradeSimulatedLog], transfer: AcrossTransfer, originSpoke: EVMAddress) -> BigUInt? {
        let owner = CCTPMessage.word(transfer.owner)
        let data = BridgeSimulationCheck.fundsDepositedData
        for log in logs {
            guard log.address == originSpoke, log.topics.count == 4, log.topics[0] == BridgeSimulationCheck.fundsDepositedTopic,
                  BigUInt(bigEndian: log.topics[1]) == BigUInt(transfer.destinationChainID), log.topics[3] == owner,
                  let fields = try? data.decodeCall(data.selector + log.data), fields.count == 10,
                  fields[0] == .fixedBytes(CCTPMessage.word(transfer.inputToken)),
                  fields[1] == .fixedBytes(CCTPMessage.word(transfer.outputToken)),
                  fields[2] == .uint(transfer.inputAmount), fields[3] == .uint(transfer.outputAmount),
                  fields[5] == .uint(BigUInt(transfer.fillDeadline)),
                  fields[7] == .fixedBytes(CCTPMessage.word(transfer.recipient))
            else { continue }
            return BigUInt(bigEndian: log.topics[2])
        }
        return nil
    }

    /// O MessageReceived do MessageTransmitterV2 (CCTP V2): caller, nonce e finalidade
    /// indexados; dominio de origem, remetente e corpo nos dados.
    public static let messageReceivedTopic = Hash.keccak256(Array("MessageReceived(address,uint32,bytes32,bytes32,uint32,bytes)".utf8))
    static let messageReceivedData = try! ABIFunction("e(uint32,bytes32,bytes)")

    /// O recibo da cunhagem no destino tem o MessageReceived da mensagem atestada: o mesmo
    /// nonce, o dominio de origem e o TokenMessenger que a enviou. Uma cunhagem antiga de
    /// mesmo valor, devolvida por uma Iris comprometida, nao conta como chegada (pentest de
    /// 14/10/2026: o B4 do Across, no CCTP).
    public static func cctpMinted(_ logs: [TradeSimulatedLog], message: CCTPMessage, transmitter: EVMAddress) -> Bool {
        logs.contains { log in
            guard log.address == transmitter, log.topics.count == 4, log.topics[0] == messageReceivedTopic, log.topics[2] == message.nonce,
                  let fields = try? messageReceivedData.decodeCall(messageReceivedData.selector + log.data), fields.count == 3
            else { return false }
            return fields[0] == .uint(BigUInt(message.sourceDomain)) && fields[1] == .fixedBytes(message.sender)
        }
    }

    /// O reembolso na origem: o recibo tem o Transfer do token de entrada saindo do SpokePool
    /// para o dono, com pelo menos o valor do deposito (o reembolso pode vir junto com
    /// outros). O ETH nativo volta como WETH. So a API dizer "refunded" nao basta (revisao
    /// da ponte BNB, B4).
    public static func acrossRefunded(_ logs: [TradeSimulatedLog], transfer: AcrossTransfer, originSpoke: EVMAddress) -> Bool {
        logs.contains { log in
            log.address == transfer.inputToken
                && TradeSimulationCheck.parseTransfer(log).map {
                    $0.from == originSpoke && $0.to == transfer.owner && $0.value >= transfer.inputAmount
                } == true
        }
    }

    /// O recibo de entrega tem o FilledRelay deste deposito, sem alteracao de destino nem
    /// de valor? `logs` vem de dois RPCs concordando. O `depositId` e o `fillDeadline`
    /// amarram a entrega ao deposito do dono: uma entrega antiga de mesmo valor, devolvida
    /// por uma API comprometida, nao passa (pentest de 14/10/2026, B4).
    public static func acrossDelivered(
        _ logs: [TradeSimulatedLog], transfer: AcrossTransfer, destinationSpoke: EVMAddress, depositID: BigUInt, destinationWrappedNative: EVMAddress
    ) -> Bool {
        // Token que chega como token (nao o WETH que o SpokePool desembrulha): o mesmo recibo
        // tem o Transfer dele para o dono, com o valor cheio. So o FilledRelay deixava "conferido"
        // um token trocado que entregasse menos (revisao da ponte BNB, B2).
        if transfer.outputToken != destinationWrappedNative {
            let paid = logs.contains { log in
                log.address == transfer.outputToken
                    && TradeSimulationCheck.parseTransfer(log).map { $0.to == transfer.recipient && $0.value == transfer.outputAmount } == true
            }
            guard paid else { return false }
        }
        let owner = CCTPMessage.word(transfer.owner)
        return logs.contains { log in
            guard log.address == destinationSpoke, log.topics.count == 4, log.topics[0] == filledRelayTopic,
                  BigUInt(bigEndian: log.topics[1]) == BigUInt(transfer.originChainID),
                  BigUInt(bigEndian: log.topics[2]) == depositID,
                  let fields = try? filledRelayData.decodeCall(filledRelayData.selector + log.data), fields.count == 12,
                  case .tuple(let info) = fields[11], info.count == 4
            else { return false }
            return fields[0] == .fixedBytes(CCTPMessage.word(transfer.inputToken))
                && fields[5] == .uint(BigUInt(transfer.fillDeadline))
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
