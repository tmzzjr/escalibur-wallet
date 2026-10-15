import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// A mensagem do CCTP V2, lida pelo app e comparada com a decodificacao da propria Circle.
@Suite("Ponte: mensagem do CCTP")
struct CCTPMessageTests {
    /// Uma queima real na Base (tx 0x93c16ad0...b41b, 12/10/2026) para o dominio 26, com
    /// encaminhamento, como a Iris devolveu. Os campos esperados sao os do
    /// `decodedMessage` da Iris, nao uma releitura nossa.
    static let real = [UInt8](hex: "00000001000000060000001a5276d28d862f54a9d06b57bd4398b78bd647c015dc0876b3284e05a2fd3e551e00000000000000000000000028b5a0e9c621a5badaa536219b3a228c8168cf5d00000000000000000000000028b5a0e9c621a5badaa536219b3a228c8168cf5d0000000000000000000000000000000000000000000000000000000000000000000003e8000007d000000001000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913000000000000000000000000f5ed4f07cddd8cf29e33ee3b7a0266d5538de91200000000000000000000000000000000000000000000000000000000000052ac000000000000000000000000b3fa262d0fb521cc93be83d87b322b8a23daf3f00000000000000000000000000000000000000000000000000000000000003d940000000000000000000000000000000000000000000000000000000000003d940000000000000000000000000000000000000000000000000000000000000000636374702d666f72776172640000000000000000000000000000000000000000")!

    static let messenger = try! EVMAddress("0x28b5a0e9c621a5badaa536219b3a228c8168cf5d")
    static let baseUSDC = try! EVMAddress("0x833589fcd6edb6e08f4c7c32d4f71b54bda02913")
    static let recipient = try! EVMAddress("0xf5ed4f07cddd8cf29e33ee3b7a0266d5538de912")
    static let sender = try! EVMAddress("0xb3fa262d0fb521cc93be83d87b322b8a23daf3f0")

    static var transfer: CCTPTransfer {
        CCTPTransfer(sourceDomain: 6, destinationDomain: 26, usdc: baseUSDC, owner: sender, recipient: recipient,
                     amount: 21164, maxFee: 15764, finality: CCTPCalldata.fastFinality)
    }

    @Test("Os campos batem com o decodedMessage da Circle")
    func decodesLikeIris() throws {
        let message = try CCTPMessage(Self.real)
        #expect(message.sourceDomain == 6)
        #expect(message.destinationDomain == 26)
        #expect(message.nonce == [UInt8](hex: "5276d28d862f54a9d06b57bd4398b78bd647c015dc0876b3284e05a2fd3e551e")!)
        #expect(try CCTPMessage.evmAddress(message.sender, "sender") == Self.messenger)
        #expect(try CCTPMessage.evmAddress(message.recipient, "recipient") == Self.messenger)
        #expect(message.destinationCaller.allSatisfy { $0 == 0 })
        #expect(message.minFinalityThreshold == 1000)
        #expect(message.finalityThresholdExecuted == 2000)
        #expect(try CCTPMessage.evmAddress(message.burnToken, "burnToken") == Self.baseUSDC)
        #expect(try CCTPMessage.evmAddress(message.mintRecipient, "mintRecipient") == Self.recipient)
        #expect(message.amount == 21164)
        #expect(try CCTPMessage.evmAddress(message.messageSender, "messageSender") == Self.sender)
        #expect(message.maxFee == 15764)
        #expect(message.feeExecuted == 15764)
        #expect(message.expirationBlock == 0)
        #expect(message.hookData == CCTPCalldata.forwardHookData)
        #expect(message.mintedAmount == BigUInt(21164 - 15764))
    }

    @Test("O pedido de encaminhamento e o da documentacao da Circle")
    func forwardHook() {
        #expect(Hex.encode(CCTPCalldata.forwardHookData) == "636374702d666f72776172640000000000000000000000000000000000000000")
    }

    @Test("A mensagem da propria transferencia passa")
    func checkPasses() throws {
        try CCTPMessage(Self.real).check(Self.transfer, sourceMessenger: Self.messenger, destinationMessenger: Self.messenger)
    }

    @Test("Mensagem de outra transferencia e recusada, campo a campo")
    func checkRefuses() throws {
        let message = try CCTPMessage(Self.real)
        let t = Self.transfer
        let other = try EVMAddress("0x1111111111111111111111111111111111111111")
        func refuses(_ transfer: CCTPTransfer, _ expected: CCTPMismatch, source: EVMAddress? = nil) {
            #expect(throws: expected) {
                try message.check(transfer, sourceMessenger: source ?? Self.messenger, destinationMessenger: Self.messenger)
            }
        }
        refuses(CCTPTransfer(sourceDomain: 0, destinationDomain: 26, usdc: t.usdc, owner: t.owner, recipient: t.recipient,
                             amount: t.amount, maxFee: t.maxFee, finality: t.finality), .domain)
        refuses(t, .messenger, source: other)
        refuses(CCTPTransfer(sourceDomain: 6, destinationDomain: 26, usdc: other, owner: t.owner, recipient: t.recipient,
                             amount: t.amount, maxFee: t.maxFee, finality: t.finality), .token)
        refuses(CCTPTransfer(sourceDomain: 6, destinationDomain: 26, usdc: t.usdc, owner: t.owner, recipient: other,
                             amount: t.amount, maxFee: t.maxFee, finality: t.finality), .recipient)
        refuses(CCTPTransfer(sourceDomain: 6, destinationDomain: 26, usdc: t.usdc, owner: other, recipient: t.recipient,
                             amount: t.amount, maxFee: t.maxFee, finality: t.finality), .sender)
        refuses(CCTPTransfer(sourceDomain: 6, destinationDomain: 26, usdc: t.usdc, owner: t.owner, recipient: t.recipient,
                             amount: 21165, maxFee: t.maxFee, finality: t.finality), .amount)
        refuses(CCTPTransfer(sourceDomain: 6, destinationDomain: 26, usdc: t.usdc, owner: t.owner, recipient: t.recipient,
                             amount: t.amount, maxFee: 15000, finality: t.finality), .fee)
    }

    @Test("Bytes trocados ou cortados nao passam")
    func malformed() {
        #expect(throws: CCTPMessage.Problem.tooShort) { try CCTPMessage(Array(Self.real.prefix(300))) }
        var version = Self.real
        version[3] = 2
        #expect(throws: CCTPMessage.Problem.unknownVersion) { try CCTPMessage(version) }
        var body = Self.real
        body[151] = 2
        #expect(throws: CCTPMessage.Problem.unknownBodyVersion) { try CCTPMessage(body) }
        // Um byte nos 12 de cima do destinatario: outro endereco, recusado.
        var dirty = Self.real
        dirty[148 + 36] = 1
        #expect(throws: CCTPMessage.Problem.badAddressWord("mintRecipient")) {
            try CCTPMessage(dirty).check(Self.transfer, sourceMessenger: Self.messenger, destinationMessenger: Self.messenger)
        }
    }

    @Test("A calldata de deposito sai com os campos da transferencia")
    func encodesDeposit() throws {
        let data = try CCTPCalldata.encodeDeposit(Self.transfer)
        #expect(Array(data.prefix(4)) == CCTPCalldata.depositForBurnWithHook.selector)
        let args = try CCTPCalldata.depositForBurnWithHook.decodeCall(data)
        #expect(args[0] == .uint(21164))
        #expect(args[1] == .uint(26))
        #expect(args[2] == .fixedBytes(CCTPMessage.word(Self.recipient)))
        #expect(args[3] == .address(Self.baseUSDC))
        #expect(args[4] == .fixedBytes([UInt8](repeating: 0, count: 32)))
        #expect(args[5] == .uint(15764))
        #expect(args[6] == .uint(1000))
        #expect(args[7] == .bytes(CCTPCalldata.forwardHookData))
    }

    /// O MessageReceived que o MessageTransmitterV2 emite ao cunhar esta mensagem.
    static func received(_ message: CCTPMessage, nonce: [UInt8]? = nil, sourceDomain: UInt32? = nil, sender: [UInt8]? = nil,
                         transmitter: EVMAddress = BridgeAllowlist.messageTransmitter) -> TradeSimulatedLog {
        let data = try! BridgeArrival.messageReceivedData.encodeCall([
            .uint(BigUInt(sourceDomain ?? message.sourceDomain)), .fixedBytes(sender ?? message.sender), .bytes([1, 2, 3]),
        ])
        return TradeSimulatedLog(
            address: transmitter,
            topics: [BridgeArrival.messageReceivedTopic, TradeTestSupport.word(7), nonce ?? message.nonce, TradeTestSupport.word(1000)],
            data: Array(data.dropFirst(4))
        )
    }

    @Test("A cunhagem conta so com o MessageReceived desta mensagem: nonce, origem e remetente")
    func mintBoundToMessage() throws {
        let message = try CCTPMessage(Self.real)
        let transmitter = BridgeAllowlist.messageTransmitter
        #expect(BridgeArrival.cctpMinted([Self.received(message)], message: message, transmitter: transmitter))
        // Uma cunhagem antiga de mesmo valor tem outro nonce.
        let older = [UInt8](repeating: 0xAB, count: 32)
        #expect(!BridgeArrival.cctpMinted([Self.received(message, nonce: older)], message: message, transmitter: transmitter))
        #expect(!BridgeArrival.cctpMinted([Self.received(message, sourceDomain: 3)], message: message, transmitter: transmitter))
        #expect(!BridgeArrival.cctpMinted([Self.received(message, sender: CCTPMessage.word(Self.recipient))], message: message, transmitter: transmitter))
        // O mesmo evento emitido por outro contrato nao vale.
        #expect(!BridgeArrival.cctpMinted([Self.received(message, transmitter: Self.recipient)], message: message, transmitter: transmitter))
        #expect(!BridgeArrival.cctpMinted([], message: message, transmitter: transmitter))
    }
}
