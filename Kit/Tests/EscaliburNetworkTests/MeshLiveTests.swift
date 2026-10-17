import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// USDT para a Tron pela Legacy Mesh da Tether, contra os contratos e os nos reais. So com
/// ESCALIBUR_REDE=1. Le a cotacao no proprio UsdtOFT em duas fontes, valida, le o estado,
/// simula em dois RPCs e monta o plano; e confere uma entrega real na Tron pelo `guid`.
/// **Nao assina e nao transmite nada.** O saldo existe so dentro do `eth_simulateV1`.
@Suite("Ponte para a Tron ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct MeshLiveTests {
    /// A chave do saldo do dono no token, para gravar por cima dentro do `eth_call`: o mapa
    /// num slot simples (o USDT da Ethereum usa o 2) ou no armazenamento com nome da
    /// OpenZeppelin 5 (ERC-7201, "openzeppelin.storage.ERC20"), o do USDT0.
    static func balanceKey(_ token: EVMAddress, owner: EVMAddress, chain: Chain, reader: TradeStateReader) async throws -> [UInt8]? {
        let provider = await reader.readProviders(chain)[0]
        let probe = BigUInt(123_456_789)
        let namespaced = BigUInt(hex: "52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00")!
        for base in (0..<64).map({ BigUInt($0) }) + [namespaced] {
            let key = Hash.keccak256([UInt8](repeating: 0, count: 12) + owner.bytes + (base.bigEndianBytes(padTo: 32) ?? []))
            let override: JSONValue = .object(["0x" + Hex.encode(token.bytes): .object(["stateDiff": .object([
                Hex.encode(key, prefix: true): .string(Hex.encode(probe.bigEndianBytes(padTo: 32)!, prefix: true)),
            ])])])
            let text = try await reader.rpc(provider, chain: chain, "eth_call", [
                .object(["to": .string("0x" + Hex.encode(token.bytes)), "data": .string(Hex.encode(ERC20.balanceOf(owner: owner), prefix: true))]),
                .string("latest"), override,
            ], as: String.self)
            if BigUInt(hex: text) == probe { return key }
        }
        return nil
    }

    @Test("USDT para a Tron: cotacao no contrato da Tether em duas fontes, validador, simulacao em dois RPCs e plano",
          arguments: ["ethereum", "arbitrum"])
    func meshPlan(from: String) async throws {
        let account = try TradeLiveTests.account()
        let chain = try #require(Chain.find(from))
        // A conta Tron que recebe: qualquer uma serve para simular.
        let recipient = try #require(TronAddress(account20: account.address.bytes))
        let amount = BigUInt(1_000_000_000)  // 1.000 USDT
        let intent = try BridgeIntent(owner: account.address, asset: .usdt, from: chain, to: .tron, amount: amount, tronRecipient: recipient)
        let reader = TradeStateReader()
        let read = try await reader.readMesh(intent: intent)
        Live.note("\(from): Tether \(read.feeBps) bps, chega \(read.received), liquidez \(read.maxAmount), mensagem \(read.nativeFee) wei")
        #expect(read.feeBps <= BigUInt(USDT0Mesh.feeCapBps) && read.tronPeer == USDT0Mesh.tronPeerWord)
        let price = try? await MarketService().quotes(ids: ["ethereum"], currency: "usd")["ethereum"]?.price
        let quote = try BridgeValidator.mesh(intent, quote: read, nativeUSDPrice: price.flatMap { TradeDecimal(String(format: "%.2f", $0)) })
        #expect(quote.minimumReceived == read.received && quote.value > read.nativeFee)

        let token = try #require(intent.sell.contract)
        let key = try #require(try await Self.balanceKey(token, owner: account.address, chain: chain, reader: reader), "chave do saldo do USDT")
        let overrides: JSONValue = .object([
            "0x" + Hex.encode(account.address.bytes): .object(["balance": .string(BridgeLiveTests.ten.hexString)]),
            "0x" + Hex.encode(token.bytes): .object(["stateDiff": .object([
                Hex.encode(key, prefix: true): .string(Hex.encode(amount.bigEndianBytes(padTo: 32)!, prefix: true)),
            ])]),
        ])
        let state = try await reader.readBridge(for: quote, localNextNonce: nil, stateOverrides: overrides)
        do {
            let plan = try BridgePlanner.planDeposit(walletID: UUID(), account: account, quote: quote, state: BridgeLiveTests.funded(state, amount: amount))
            #expect(plan.transactions.count == 2, "approve exato e envio")
            let send = try #require(plan.transactions.last as? EVMTransaction)
            #expect(send.to == quote.to && send.data == quote.data && send.value == quote.value)
            #expect(plan.review.beneficiary == recipient.base58)
            let sell = try #require(BridgeAsset.usdt.asset(on: intent.from))
            let receive = try #require(BridgeAsset.usdt.asset(on: intent.to))
            try PlanIntentCheck.bridge(plan.review, sell: sell, amount: amount, from: chain, receive: receive,
                                       minimumOut: quote.minimumReceived, to: .tron, owner: recipient.base58)
        } catch {
            let reverts = state.simulations.flatMap { simulation in simulation.calls.compactMap { $0.error } }
            Issue.record("\(from) -> Tron: \(error) \(reverts)")
        }
    }

    @Test("Entrega real na Tron: achada pelo guid, lida em dois provedores e conferida campo a campo")
    func realDelivery() async throws {
        // Uma entrega da Ethereum para a Tron vista em 17/10/2026 (bloco 87.196.554).
        let guid = [UInt8](hex: "98a393e6f0e2e9cf0ad5246b4c1f05a3d398afb8242bc23fb170dfaa3c1227b6")!
        let recipient = try #require(TronAddress(account20: [UInt8](hex: "03343ee91f76117d4380b71aac0629a39c3f8a0e")!))
        let delivery = try #require(try await TronReader().meshDelivery(oft: USDT0Mesh.tronOFT, guid: guid,
                                                                         since: Date(timeIntervalSince1970: 1_792_262_652 - 60)))
        #expect(delivery.txID == "3b9dda72df04daa9ef3d3024097b77d965ec95ec1536510d60a13a987af28a02")
        let source = try #require(USDT0Mesh.sources[1])
        let transfer = MeshTransfer(sourceChainID: 1, oft: source.oft, owner: TradeTestAccounts.stranger, recipient: recipient,
                                    amount: 1_439_779, minimumReceived: 1_439_347, nativeFee: 1)
        #expect(BridgeArrival.meshDelivered(delivery.logs, transfer: transfer, guid: guid, sourceEID: 30101) == 1_439_347)
        // Outra conta, ou outra origem: nao e esta entrega.
        let other = MeshTransfer(sourceChainID: 1, oft: source.oft, owner: TradeTestAccounts.stranger,
                                 recipient: USDT0Mesh.tronOFT, amount: 1_439_779, minimumReceived: 1_439_347, nativeFee: 1)
        #expect(BridgeArrival.meshDelivered(delivery.logs, transfer: other, guid: guid, sourceEID: 30101) == nil)
        #expect(BridgeArrival.meshDelivered(delivery.logs, transfer: transfer, guid: guid, sourceEID: 30110) == nil)
    }
}

enum TradeTestAccounts {
    static let stranger = try! EVMAddress("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
}
