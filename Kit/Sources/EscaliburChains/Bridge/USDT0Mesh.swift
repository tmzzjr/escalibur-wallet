import EscaliburCore
import Foundation

// USDT para a Tron pela Legacy Mesh do USDT0, a ponte da propria Tether (pedido do dono,
// 17/10/2026).
//
// Fonte: docs.usdt0.to (overview/the-legacy-mesh e technical-documentation/deployments, a
// lista em /api/deployments) e o codigo verificado no Sourcify ("UsdtOFT", solc 0.8.22, match
// exato no codigo de criacao e no de execucao, na Ethereum e na Arbitrum): contracts/UsdtOFT.sol
// e lz-evm-oapp-v2 (IOFT.sol, OAppOptionsType3.sol).
//
//   send((uint32 dstEid, bytes32 to, uint256 amountLD, uint256 minAmountLD, bytes extraOptions,
//         bytes composeMsg, bytes oftCmd), (uint256 nativeFee, uint256 lzTokenFee),
//        address refundAddress)                                                    (c7c7f5b3)
//
// O que o contrato faz, lido do fonte: tira a taxa (`feeBps`) do valor, reverte se o que chega
// fica abaixo de `minAmountLD`, puxa `amountLD` do USDT do remetente (o approve exato), confere
// que a Tron tem liquidez (`credits[dstEid]`) e manda a mensagem pela LayerZero, pagando a taxa
// de mensagem com o `msg.value` (o EndpointV2 devolve a sobra a `refundAddress`). Na Tron, o
// UsdtOFT par entrega o que chega, em USDT da Tron, ao endereco dos 20 bytes baixos de `to`.
//
// Conferido na cadeia em 17/10/2026, em dois RPCs de cada rede (e em duas fontes na Tron):
// codigo igual nas fontes (16.575 bytes), sem proxy (slot EIP-1967 zerado); `token()` o USDT do
// emissor (Ethereum) e o USDT0 (Arbitrum); `feeBps()` 3; `TRON_EID()` 30420; `endpoint()` o
// EndpointV2 da LayerZero; `peers(30420)` o UsdtOFT da Tron; na Tron, `token()` o USDT
// TR7NH...Lj6t e `peers` de volta para os dois; `quoteOFT`/`quoteSend` respondendo (100 USDT
// chegam 99,97; taxa de mensagem 0,0047 ETH, na Ethereum e na Arbitrum).
//
// O que a carteira exige: destino Tron (30420) e mais nenhum; `to` = a conta Tron da propria
// carteira; `extraOptions`, `composeMsg` e `oftCmd` vazios (nenhuma chamada no destino);
// `minAmountLD` = o que o contrato disse que chega, com a taxa de agora (taxa maior depois disso
// reverte a transacao, nao tira do dono); `refundAddress` = o dono; nada de lzToken.

public enum USDT0Mesh {
    /// A Tron na LayerZero.
    public static let tronEID: UInt32 = 30420
    /// O UsdtOFT da Tron (TFG4wBaDQ8sHWWP1ACeSGnoNR6RRzevLPt): o par que entrega.
    public static let tronOFT = TronAddress(base58: "TFG4wBaDQ8sHWWP1ACeSGnoNR6RRzevLPt")!
    /// O USDT da Tron (TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t), o que chega.
    public static let tronUSDT = TronAddress(base58: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t")!

    /// A taxa da Tether que a carteira aceita: ate 0,1% (hoje 0,03%). Acima, a ponte para ate
    /// a proxima versao do app, em vez de seguir o que o dono do contrato decidir.
    public static let feeCapBps = 10
    /// A taxa de mensagem da LayerZero que a carteira aceita pagar: ate 0,02 ETH (vista 0,0047).
    public static let nativeFeeCap = BigUInt(20_000_000_000_000_000)
    /// Folga sobre a taxa de mensagem cotada, para ela subir um pouco ate a transacao entrar. A
    /// sobra volta ao dono pelo EndpointV2, na mesma transacao.
    public static let nativeFeeMarginBps = 1_000

    /// O UsdtOFT de uma rede de origem.
    public struct Source: Sendable, Equatable {
        public let chainID: UInt64
        public let eid: UInt32
        public let oft: EVMAddress
        /// O USDT que o UsdtOFT puxa nesta rede (`token()`).
        public let usdt: EVMAddress
    }

    static func address(_ hex: String) -> EVMAddress { EVMAddress(uncheckedBytes: [UInt8](hex: hex)!) }

    public static let sources: [UInt64: Source] = [
        1: Source(chainID: 1, eid: 30101, oft: address("1F748c76dE468e9D11bd340fA9D5CBADf315dFB0"),
                  usdt: address("dAC17F958D2ee523a2206206994597C13D831ec7")),
        42161: Source(chainID: 42161, eid: 30110, oft: address("77652D5aba086137b595875263FC200182919B92"),
                      usdt: address("Fd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9")),
    ]

    public static func source(_ chain: Chain) -> Source? {
        chain.evmChainID.flatMap { sources[$0] }
    }

    /// `to` da mensagem: os 20 bytes da conta Tron, a esquerda com zeros.
    public static func recipientWord(_ recipient: TronAddress) -> [UInt8] {
        [UInt8](repeating: 0, count: 12) + recipient.account20
    }

    /// O `peers(30420)` que o UsdtOFT de origem tem de devolver: o UsdtOFT da Tron.
    public static var tronPeerWord: [UInt8] { recipientWord(tronOFT) }

    // MARK: Calldata

    static let sendParamType = "(uint32,bytes32,uint256,uint256,bytes,bytes,bytes)"
    public static let sendFunction = try! ABIFunction("send(\(sendParamType),(uint256,uint256),address)")  // c7c7f5b3
    public static let quoteOFTFunction = try! ABIFunction("quoteOFT(\(sendParamType))")                   // 0d35b415
    public static let quoteSendFunction = try! ABIFunction("quoteSend(\(sendParamType),bool)")            // 3b6f743b
    public static let peersFunction = try! ABIFunction("peers(uint32)")
    public static let feeBpsFunction = try! ABIFunction("feeBps()")
    public static let tokenFunction = try! ABIFunction("token()")

    static func sendParam(recipient: TronAddress, amount: BigUInt, minimum: BigUInt) -> ABIValue {
        .tuple([.uint(BigUInt(tronEID)), .fixedBytes(recipientWord(recipient)), .uint(amount), .uint(minimum), .bytes([]), .bytes([]), .bytes([])])
    }

    /// `quoteOFT`: quanto chega e o limite da liquidez na Tron.
    public static func quoteOFTCall(recipient: TronAddress, amount: BigUInt) throws -> [UInt8] {
        try quoteOFTFunction.encodeCall([sendParam(recipient: recipient, amount: amount, minimum: 0)])
    }

    /// `quoteSend`: a taxa de mensagem, para o envio com este minimo.
    public static func quoteSendCall(recipient: TronAddress, amount: BigUInt, minimum: BigUInt) throws -> [UInt8] {
        try quoteSendFunction.encodeCall([sendParam(recipient: recipient, amount: amount, minimum: minimum), .bool(false)])
    }

    /// O que `quoteOFT` devolve: (OFTLimit(min, max), OFTFeeDetail[], OFTReceipt(enviado, recebido)).
    public static func parseQuoteOFT(_ data: [UInt8]) throws -> (maxAmount: BigUInt, sent: BigUInt, received: BigUInt) {
        guard data.count >= 160 else { throw BridgeRefusal.quoteMismatch("quoteOFT") }
        func word(_ index: Int) -> BigUInt { BigUInt(bigEndian: Array(data[(index * 32)..<(index * 32 + 32)])) }
        return (word(1), word(3), word(4))
    }

    /// O que `quoteSend` devolve: MessagingFee(nativeFee, lzTokenFee).
    public static func parseQuoteSend(_ data: [UInt8]) throws -> (nativeFee: BigUInt, lzTokenFee: BigUInt) {
        guard data.count == 64 else { throw BridgeRefusal.quoteMismatch("quoteSend") }
        return (BigUInt(bigEndian: Array(data[0..<32])), BigUInt(bigEndian: Array(data[32..<64])))
    }

    /// `OFTSent(bytes32 indexed guid, uint32 dstEid, address indexed fromAddress, uint256 amountSentLD,
    /// uint256 amountReceivedLD)`.
    public static let oftSentTopic = Hash.keccak256(Array("OFTSent(bytes32,uint32,address,uint256,uint256)".utf8))
}

/// O que a rede leu do UsdtOFT de origem para um envio, em duas fontes concordando (a taxa
/// de mensagem, a maior das duas: a sobra volta ao dono).
public struct MeshQuote: Sendable, Equatable {
    /// `token()`: o USDT que o contrato puxa.
    public let token: EVMAddress
    /// `peers(30420)`: quem entrega na Tron.
    public let tronPeer: [UInt8]
    /// `feeBps()`: a taxa da Tether, em bps.
    public let feeBps: BigUInt
    /// `quoteOFT`: a liquidez da Tron (o maximo que chega), o que sai e o que chega.
    public let maxAmount: BigUInt
    public let sent: BigUInt
    public let received: BigUInt
    /// `quoteSend`: a taxa de mensagem da LayerZero, na moeda nativa, e em lzToken (tem de ser zero).
    public let nativeFee: BigUInt
    public let lzTokenFee: BigUInt

    public init(token: EVMAddress, tronPeer: [UInt8], feeBps: BigUInt, maxAmount: BigUInt, sent: BigUInt, received: BigUInt,
                nativeFee: BigUInt, lzTokenFee: BigUInt) {
        self.token = token
        self.tronPeer = tronPeer
        self.feeBps = feeBps
        self.maxAmount = maxAmount
        self.sent = sent
        self.received = received
        self.nativeFee = nativeFee
        self.lzTokenFee = lzTokenFee
    }
}

/// O envio pela Legacy Mesh, como o app monta e o dono assina.
public struct MeshTransfer: Sendable, Equatable {
    public let sourceChainID: UInt64
    public let oft: EVMAddress
    public let owner: EVMAddress
    /// A conta Tron da propria carteira.
    public let recipient: TronAddress
    public let amount: BigUInt
    /// O que chega, no minimo: o que o contrato cotou com a taxa de agora.
    public let minimumReceived: BigUInt
    /// A taxa de mensagem da LayerZero, com a folga, em wei da origem. Vai como `msg.value`.
    public let nativeFee: BigUInt

    public init(sourceChainID: UInt64, oft: EVMAddress, owner: EVMAddress, recipient: TronAddress, amount: BigUInt,
                minimumReceived: BigUInt, nativeFee: BigUInt) {
        self.sourceChainID = sourceChainID
        self.oft = oft
        self.owner = owner
        self.recipient = recipient
        self.amount = amount
        self.minimumReceived = minimumReceived
        self.nativeFee = nativeFee
    }

    public var value: BigUInt { nativeFee }
}

public enum MeshCalldata {
    /// `send` com o destino Tron, o dono recebendo o troco da taxa, e nada no destino alem da
    /// entrega.
    public static func encode(_ transfer: MeshTransfer) throws -> [UInt8] {
        try USDT0Mesh.sendFunction.encodeCall([
            USDT0Mesh.sendParam(recipient: transfer.recipient, amount: transfer.amount, minimum: transfer.minimumReceived),
            .tuple([.uint(transfer.nativeFee), .uint(0)]),
            .address(transfer.owner),
        ])
    }

    /// A calldata lida de volta: tem de ser exatamente um envio para a Tron, sem opcoes nem
    /// chamada, com o troco para o dono. Devolve o que ela pede.
    public static func decode(_ data: [UInt8], owner: EVMAddress) throws
        -> (recipient: TronAddress, amount: BigUInt, minimum: BigUInt, nativeFee: BigUInt) {
        let values: [ABIValue]
        do { values = try USDT0Mesh.sendFunction.decodeCall(data) } catch { throw BridgeRefusal.quoteMismatch("calldata") }
        guard values.count == 3, let param = values[0].tupleValue, param.count == 7, let fee = values[1].tupleValue, fee.count == 2,
              let refund = values[2].addressValue
        else { throw BridgeRefusal.quoteMismatch("calldata") }
        guard param[0] == .uint(BigUInt(USDT0Mesh.tronEID)), case .fixedBytes(let word) = param[1], word.count == 32,
              word.prefix(12).allSatisfy({ $0 == 0 }), let recipient = TronAddress(account20: Array(word.suffix(20))),
              let amount = param[2].uintValue, let minimum = param[3].uintValue,
              param[4] == .bytes([]), param[5] == .bytes([]), param[6] == .bytes([]),
              let nativeFee = fee[0].uintValue, fee[1] == .uint(0), refund == owner
        else { throw BridgeRefusal.quoteMismatch("envio") }
        return (recipient, amount, minimum, nativeFee)
    }
}
