import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// A ponte contra a Circle, o Across e os nos reais. So com ESCALIBUR_REDE=1. Cota de
/// verdade, valida, le o estado nas duas redes (implementacoes fixadas, dominio, token
/// local, bloqueio, codigo no destino), simula em duas fontes e monta o plano.
/// **Nao assina e nao transmite nada.**
///
/// A conta e a dos testes de troca ao vivo, nova e sem codigo em rede nenhuma. O saldo
/// existe so dentro do `eth_simulateV1` (stateOverrides).
@Suite("Ponte ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"), .serialized)
struct BridgeLiveTests {
    static let ten = BigUInt(decimal: "10000000000000000000")!

    static func overrides(owner: EVMAddress, usdc: EVMAddress?, amount: BigUInt) -> JSONValue {
        var object: [String: JSONValue] = ["0x" + Hex.encode(owner.bytes): .object(["balance": .string(ten.hexString)])]
        if let usdc {
            // FiatToken v2.2: `balanceAndBlacklistStates` no slot 9.
            let key = Hash.keccak256([UInt8](repeating: 0, count: 12) + owner.bytes + (BigUInt(9).bigEndianBytes(padTo: 32) ?? []))
            object["0x" + Hex.encode(usdc.bytes)] = .object(["stateDiff": .object([
                Hex.encode(key, prefix: true): .string(Hex.encode(amount.bigEndianBytes(padTo: 32)!, prefix: true)),
            ])])
        }
        return .object(object)
    }

    /// O estado lido de verdade, com o saldo que so existe na simulacao.
    static func funded(_ state: BridgeChainState, amount: BigUInt) -> BridgeChainState {
        let network = state.network
        let rich = EVMNetworkState(
            chain: network.chain, pendingNonces: network.pendingNonces, baseFeePerGas: network.baseFeePerGas,
            priorityFees: network.priorityFees, gasEstimate: 21_000, nativeBalance: ten, destinationHasCode: true
        )
        let token = state.token.map { EVMTokenState(contractHasCode: $0.contractHasCode, balance: amount, allowance: $0.allowance) }
        return BridgeChainState(
            network: rich, token: token, implementations: state.implementations, destinationDomain: state.destinationDomain,
            destinationLocalToken: state.destinationLocalToken, destinationBlacklisted: state.destinationBlacklisted,
            ownerHasCodeAtDestination: state.ownerHasCodeAtDestination, simulations: state.simulations,
            approveL1DataFee: state.approveL1DataFee, depositL1DataFee: state.depositL1DataFee,
            approveL1Gas: state.approveL1Gas, depositL1Gas: state.depositL1Gas, mesh: state.mesh
        )
    }

    static func check(_ plan: SigningPlan, _ quote: ValidatedBridgeQuote) throws {
        let intent = quote.intent
        let sell = try #require(intent.asset.asset(on: intent.from))
        let receive = try #require(intent.asset.asset(on: intent.to))
        try PlanIntentCheck.bridge(plan.review, sell: sell, amount: intent.amount, from: intent.from.chain, receive: receive,
                                   minimumOut: quote.minimumReceived, to: intent.to.chain, owner: intent.owner.checksummed)
        let deposit = plan.transactions.last as! EVMTransaction
        #expect(deposit.to == quote.to && deposit.data == quote.data && deposit.value == quote.value)
        #expect(plan.review.lines.contains { $0.label == "Endereço que recebe" && $0.value == intent.owner.checksummed })
    }

    @Test("USDC pelo CCTP, rapido e padrao, nas duas direcoes",
          arguments: [("base", "arbitrum", true), ("arbitrum", "optimism", false), ("polygon", "linea", false), ("unichain", "sonic", false),
                      ("plasma", "base", false)])
    func cctp(from: String, to: String, fast: Bool) async throws {
        let account = try TradeLiveTests.account()
        let amount = BigUInt(100_000_000)
        let intent = try BridgeIntent(owner: account.address, asset: .usdc, from: Chain.find(from)!, to: Chain.find(to)!, amount: amount)
        let iris = CircleIrisClient()
        let fees = try await iris.fees(sourceDomain: intent.from.cctp!.domain, destinationDomain: intent.to.cctp!.domain)
        let allowance = try await iris.fastAllowance()
        let quote = try BridgeValidator.cctp(intent, route: fast ? .cctpFast : .cctpStandard, fees: fees, fastAllowance: allowance)
        let reader = TradeStateReader()
        let state = try await reader.readBridge(for: quote, localNextNonce: nil,
                                                stateOverrides: Self.overrides(owner: account.address, usdc: intent.from.usdc, amount: amount))
        #expect(state.destinationDomain == intent.to.cctp!.domain)
        #expect(state.destinationLocalToken == intent.to.usdc)
        #expect(state.destinationBlacklisted == false)
        #expect(!state.ownerHasCodeAtDestination)
        do {
            let plan = try BridgePlanner.planDeposit(walletID: UUID(), account: account, quote: quote, state: Self.funded(state, amount: amount))
            #expect(plan.transactions.count == 2)
            try Self.check(plan, quote)
        } catch {
            Issue.record("\(from) -> \(to): \(error) \(state.simulations.flatMap { $0.calls.compactMap(\.error) })")
        }
    }

    @Test("ETH pelo Across, Base para Arbitrum, Optimism para Ethereum e Linea para Unichain",
          arguments: [("base", "arbitrum"), ("optimism", "ethereum"), ("linea", "unichain")])
    func acrossETH(from: String, to: String) async throws {
        let account = try TradeLiveTests.account()
        let amount = BigUInt(decimal: "50000000000000000")!
        let intent = try BridgeIntent(owner: account.address, asset: .eth, from: Chain.find(from)!, to: Chain.find(to)!, amount: amount)
        let across = try await AcrossClient().quote(
            inputToken: intent.from.across!.wrappedNative, outputToken: intent.to.across!.wrappedNative,
            originChainID: intent.from.chain.evmChainID!, destinationChainID: intent.to.chain.evmChainID!, amount: amount
        )
        let price = try? await MarketService().quotes(ids: ["ethereum"], currency: "usd")["ethereum"]?.price
        let quote = try BridgeValidator.across(intent, quote: across, usdPrice: price.flatMap { TradeDecimal(String(format: "%.2f", $0)) })
        let reader = TradeStateReader()
        let state = try await reader.readBridge(for: quote, localNextNonce: nil,
                                                stateOverrides: Self.overrides(owner: account.address, usdc: nil, amount: amount))
        #expect(state.implementations.count == 2)
        do {
            let plan = try BridgePlanner.planDeposit(walletID: UUID(), account: account, quote: quote, state: Self.funded(state, amount: amount))
            #expect(plan.transactions.count == 1)
            try Self.check(plan, quote)
        } catch {
            Issue.record("\(from) -> \(to): \(error) \(state.simulations.flatMap { $0.calls.compactMap(\.error) })")
        }
    }

    @Test("BNB pelo Across: cotacao real, validador, simulacao em dois RPCs e plano, da Base para a BNB",
          arguments: [("usdc", "100000000"), ("eth", "50000000000000000")])
    func acrossToBNB(asset: String, amount: String) async throws {
        let account = try TradeLiveTests.account()
        let value = BigUInt(decimal: amount)!
        let moved = BridgeAsset(rawValue: asset)!
        let intent = try BridgeIntent(owner: account.address, asset: moved, from: .base, to: .bnb, amount: value)
        #expect(!BridgeAsset.usesCCTP(moved, from: intent.from, to: intent.to))
        let across = try await AcrossClient().quote(
            inputToken: moved.contract(on: intent.from) ?? intent.from.across!.wrappedNative,
            outputToken: moved.contract(on: intent.to) ?? intent.to.across!.wrappedNative,
            originChainID: 8453, destinationChainID: 56, amount: value
        )
        let price = try? await MarketService().quotes(ids: ["ethereum"], currency: "usd")["ethereum"]?.price
        let quote = try BridgeValidator.across(intent, quote: across, usdPrice: price.flatMap { TradeDecimal(String(format: "%.2f", $0)) })
        // O que chega tem as 18 casas da BNB: na unidade da origem, menos do que saiu.
        #expect(BridgeAsset.rescale(quote.minimumReceived, from: moved.decimals(on: intent.to), to: moved.decimals(on: intent.from)) < value)
        let reader = TradeStateReader()
        let state = try await reader.readBridge(for: quote, localNextNonce: nil,
                                                stateOverrides: Self.overrides(owner: account.address, usdc: moved == .usdc ? intent.from.usdc : nil, amount: value))
        // Os dois SpokePools e, no USDC, a implementacao do USDC da Binance.
        #expect(state.implementations.count == (moved == .usdc ? 3 : 2))
        do {
            let plan = try BridgePlanner.planDeposit(walletID: UUID(), account: account, quote: quote, state: Self.funded(state, amount: value))
            try Self.check(plan, quote)
        } catch {
            Issue.record("base -> bnb \(asset): \(error) \(state.simulations.flatMap { $0.calls.compactMap(\.error) })")
        }
    }

    /// O slot do mapa de saldos de um token: o primeiro em que `balanceOf` devolve o valor
    /// gravado por cima, dentro do `eth_call`.
    static func balanceSlot(_ token: EVMAddress, owner: EVMAddress, chain: Chain, reader: TradeStateReader) async throws -> Int? {
        let provider = await reader.readProviders(chain)[0]
        let probe = BigUInt(123_456_789)
        // Ate 64: os tokens atualizaveis da OpenZeppelin guardam o mapa depois das lacunas (51).
        for slot in 0..<64 {
            let key = Hash.keccak256([UInt8](repeating: 0, count: 12) + owner.bytes + (BigUInt(slot).bigEndianBytes(padTo: 32) ?? []))
            let override: JSONValue = .object(["0x" + Hex.encode(token.bytes): .object(["stateDiff": .object([
                Hex.encode(key, prefix: true): .string(Hex.encode(probe.bigEndianBytes(padTo: 32)!, prefix: true)),
            ])])])
            let text = try await reader.rpc(provider, chain: chain, "eth_call", [
                .object(["to": .string("0x" + Hex.encode(token.bytes)), "data": .string(Hex.encode(ERC20.balanceOf(owner: owner), prefix: true))]),
                .string("latest"), override,
            ], as: String.self)
            if BigUInt(hex: text) == probe { return slot }
        }
        return nil
    }

    @Test("WBTC pelo Across: cotacao real, validador, simulacao em dois RPCs e plano",
          arguments: [("ethereum", "arbitrum"), ("polygon", "optimism"), ("arbitrum", "ethereum")])
    func acrossWBTC(from: String, to: String) async throws {
        let account = try TradeLiveTests.account()
        let origin = try #require(BridgeAllowlist.chain(Chain.find(from)!))
        let destination = try #require(BridgeAllowlist.chain(Chain.find(to)!))
        let value = BigUInt(200_000)  // 0,002 WBTC
        let intent = try BridgeIntent(owner: account.address, asset: .wbtc, from: origin.chain, to: destination.chain, amount: value)
        let input = try #require(BridgeAsset.wbtc.contract(on: origin))
        let across = try await AcrossClient().quote(
            inputToken: input, outputToken: try #require(BridgeAsset.wbtc.contract(on: destination)),
            originChainID: origin.chain.evmChainID!, destinationChainID: destination.chain.evmChainID!, amount: value
        )
        let price = try? await MarketService().quotes(ids: ["wrapped-bitcoin"], currency: "usd")["wrapped-bitcoin"]?.price
        let quote = try BridgeValidator.across(intent, quote: across, usdPrice: price.flatMap { TradeDecimal(String(format: "%.2f", $0)) })
        #expect(quote.minimumReceived < value && quote.minimumReceived > value * BigUInt(95) / BigUInt(100))
        let reader = TradeStateReader()
        let slot = try #require(try await Self.balanceSlot(input, owner: account.address, chain: origin.chain, reader: reader), "slot do saldo do WBTC")
        let key = Hash.keccak256([UInt8](repeating: 0, count: 12) + account.address.bytes + (BigUInt(slot).bigEndianBytes(padTo: 32) ?? []))
        let overrides: JSONValue = .object([
            "0x" + Hex.encode(account.address.bytes): .object(["balance": .string(Self.ten.hexString)]),
            "0x" + Hex.encode(input.bytes): .object(["stateDiff": .object([
                Hex.encode(key, prefix: true): .string(Hex.encode(value.bigEndianBytes(padTo: 32)!, prefix: true)),
            ])]),
        ])
        let state = try await reader.readBridge(for: quote, localNextNonce: nil, stateOverrides: overrides)
        do {
            let plan = try BridgePlanner.planDeposit(walletID: UUID(), account: account, quote: quote, state: Self.funded(state, amount: value))
            try Self.check(plan, quote)
            #expect(plan.transactions.count == 2)
        } catch {
            let reverts = state.simulations.flatMap { simulation in simulation.calls.compactMap { $0.error } }
            Issue.record("\(from) -> \(to) WBTC: \(error) \(reverts)")
        }
    }

    @Test("Da BNB de volta: o validador aceita a cotacao real de USDC, USDT e ETH da BNB para a Base",
          arguments: [("usdc", "100000000000000000000"), ("usdt", "100000000000000000000"), ("eth", "50000000000000000")])
    func acrossFromBNB(asset: String, amount: String) async throws {
        let account = try TradeLiveTests.account()
        let value = BigUInt(decimal: amount)!
        let moved = BridgeAsset(rawValue: asset)!
        let to: Chain = moved == .usdt ? .arbitrum : .base
        let intent = try BridgeIntent(owner: account.address, asset: moved, from: .bnb, to: to, amount: value)
        let across = try await AcrossClient().quote(
            inputToken: moved.contract(on: intent.from)!, outputToken: moved.contract(on: intent.to) ?? intent.to.across!.wrappedNative,
            originChainID: 56, destinationChainID: intent.to.chain.evmChainID!, amount: value
        )
        let price = try? await MarketService().quotes(ids: ["ethereum"], currency: "usd")["ethereum"]?.price
        let quote = try BridgeValidator.across(intent, quote: across, usdPrice: price.flatMap { TradeDecimal(String(format: "%.2f", $0)) })
        guard case .across(let transfer) = quote.call else { Issue.record("rota"); return }
        #expect(!transfer.nativeInput && quote.value.isZero && quote.spender == intent.from.across!.spokePool)
        // Approve exato e deposito no SpokePool da BNB, simulados em dois RPCs, com o saldo do
        // token so na simulacao (BEP-20 da Binance: `_balances` no slot 1).
        let token = moved.contract(on: intent.from)!
        let key = Hash.keccak256([UInt8](repeating: 0, count: 12) + account.address.bytes + (BigUInt(1).bigEndianBytes(padTo: 32) ?? []))
        let overrides = JSONValue.object([
            "0x" + Hex.encode(account.address.bytes): .object(["balance": .string(Self.ten.hexString)]),
            "0x" + Hex.encode(token.bytes): .object(["stateDiff": .object([
                Hex.encode(key, prefix: true): .string(Hex.encode(value.bigEndianBytes(padTo: 32)!, prefix: true)),
            ])]),
        ])
        let state = try await TradeStateReader().readBridge(for: quote, localNextNonce: nil, stateOverrides: overrides)
        do {
            let plan = try BridgePlanner.planDeposit(walletID: UUID(), account: account, quote: quote, state: Self.funded(state, amount: value))
            #expect(plan.transactions.count == 2)
            try Self.check(plan, quote)
        } catch {
            Issue.record("bnb -> \(to.id) \(asset): \(error) \(state.simulations.flatMap { $0.calls.compactMap(\.error) })")
        }
    }

    @Test("Os proxies da allowlist ainda tem a implementacao fixada")
    func pins() async throws {
        let reader = TradeStateReader()
        for bridge in BridgeAllowlist.chains {
            var proxies: [(EVMAddress, EVMAddress)] = []
            if let cctp = bridge.cctp {
                proxies += [(BridgeAllowlist.tokenMessenger, cctp.messengerImplementation),
                            (BridgeAllowlist.messageTransmitter, cctp.transmitterImplementation)]
            }
            if let across = bridge.across { proxies.append((across.spokePool, across.implementation)) }
            if let usdc = bridge.usdcImplementation { proxies.append((bridge.usdc, usdc)) }
            for (proxy, expected) in proxies {
                let found = try await reader.pin(chain: bridge.chain, router: proxy, query: .storage(slot: TradeRouterPin.eip1967ImplementationSlot))
                #expect(found == expected, "\(bridge.chain.name) \(proxy.checksummed)")
            }
        }
    }

    @Test("Toda rota do Across que o app oferece existe no Across, com os contratos compilados")
    func acrossRoutesExist() async throws {
        struct Route: Decodable { let originChainId, destinationChainId: UInt64; let originToken, destinationToken: String }
        let data = try await HTTPClient.shared.get(URL(string: "https://app.across.to/api/available-routes")!, timeout: 20)
        let routes = Set(try JSONDecoder().decode([Route].self, from: data).map {
            "\($0.originChainId):\($0.originToken.lowercased())>\($0.destinationChainId):\($0.destinationToken.lowercased())"
        })
        var offered = 0
        for asset in BridgeAsset.allCases {
            for from in BridgeAllowlist.chains {
                for to in BridgeAllowlist.chains where asset.available(from: from, to: to) && !BridgeAsset.usesCCTP(asset, from: from, to: to) {
                    // O ETH nativo entra e sai como o WETH do SpokePool.
                    let input = TradeWire.lower(asset.contract(on: from) ?? from.across!.wrappedNative)
                    let output = TradeWire.lower(asset.contract(on: to) ?? to.across!.wrappedNative)
                    let key = "\(from.chain.evmChainID!):\(input)>\(to.chain.evmChainID!):\(output)"
                    #expect(routes.contains(key), "\(asset.symbol) da \(from.chain.name) para a \(to.chain.name) nao existe no Across")
                    offered += 1
                }
            }
        }
        #expect(offered > 50, "o laco passou pelas rotas")
        // A Plasma e a BNB nao trocam USDC: o Across nao leva USDC na Plasma.
        #expect(!BridgeAsset.usdc.available(from: BridgeAllowlist.bnb, to: BridgeAllowlist.plasma))
        #expect(!BridgeAsset.usdc.available(from: BridgeAllowlist.plasma, to: BridgeAllowlist.bnb))
        #expect(BridgeAsset.usdc.available(from: BridgeAllowlist.plasma, to: BridgeAllowlist.base))
    }

    @Test("Chegada real pelo CCTP: a mensagem bate com a queima e o recibo da entrega tem o USDC")
    func cctpArrival() async throws {
        // Uma queima real na Base para a Arbitrum, com encaminhamento (12/10/2026).
        let sender = try EVMAddress("0xb3fa262d0fb521cc93be83d87b322b8a23daf3f0")
        let recipient = try EVMAddress("0x297a4a6e9b5120a2d0e3ab0c9b50778b38400209")
        let transfer = CCTPTransfer(sourceDomain: 6, destinationDomain: 3, usdc: BridgeAllowlist.base.usdc, owner: sender,
                                    recipient: recipient, amount: 86_205, maxFee: 76_205, finality: CCTPCalldata.fastFinality)
        let attested = try await CircleIrisClient().attested(
            sourceDomain: 6, burnTxHash: "0x2b7307df0fc772cab01306f9375f2f448b982efc8fc24b03bdccabc999572d84")
        let message = try #require(attested.message)
        try message.check(transfer, sourceMessenger: BridgeAllowlist.tokenMessenger, destinationMessenger: BridgeAllowlist.tokenMessenger)
        guard case .complete(let forward) = attested.forward else { Issue.record("sem entrega"); return }
        let reader = EVMReader()
        // A cunhagem e a desta mensagem: o MessageReceived com o nonce dela; outro nonce nao.
        let minted = try #require(try await reader.receiptLogs(chain: .arbitrum, hash: forward))
        #expect(BridgeArrival.cctpMinted(minted.logs, message: message, transmitter: BridgeAllowlist.messageTransmitter))
        let bytes = attested.messageBytes
        let otherNonce = try CCTPMessage(Array(bytes.prefix(12)) + [UInt8](repeating: 0xAB, count: 32) + Array(bytes.dropFirst(44)))
        #expect(!BridgeArrival.cctpMinted(minted.logs, message: otherNonce, transmitter: BridgeAllowlist.messageTransmitter))
        let arrived = try await reader.verifyIncoming(chain: .arbitrum, hash: forward, owner: recipient,
                                                      contract: BridgeAllowlist.arbitrum.usdc, amount: message.mintedAmount)
        guard case .confirmed = arrived else { Issue.record("entrega nao confirmada: \(arrived)"); return }
        // O mesmo recibo nao serve para outro valor.
        let other = try await reader.verifyIncoming(chain: .arbitrum, hash: forward, owner: recipient,
                                                    contract: BridgeAllowlist.arbitrum.usdc, amount: message.mintedAmount + 1)
        #expect(other == .mismatch)
    }

    @Test("Chegada real pelo Across: o FilledRelay do destino bate com o deposito")
    func acrossArrival() async throws {
        // Um deposito real de ETH da Base para a Arbitrum, de uma conta para ela mesma.
        let owner = try EVMAddress("0x411580947c337770994174855f8cbf56936e3062")
        func transfer(output: BigUInt = BigUInt(2_986_913_403_912_798), recipient: EVMAddress? = nil) -> AcrossTransfer {
            AcrossTransfer(originChainID: 8453, destinationChainID: 42161, owner: owner, recipient: recipient ?? owner,
                           inputToken: BridgeAllowlist.base.across!.wrappedNative, outputToken: BridgeAllowlist.arbitrum.across!.wrappedNative,
                           inputAmount: BigUInt(2_992_129_562_251_732), outputAmount: output, exclusiveRelayer: nil,
                           quoteTimestamp: 1_791_765_167, fillDeadline: 1_791_772_367, exclusivityDeadline: 0, nativeInput: true)
        }
        let receipt = try await EVMReader().receiptLogs(
            chain: .arbitrum, hash: "0x29813d5c09bb51f493bda3067aac3bccab77e6eeb0b3eba62a0e8cc104d1841c")
        let logs = try #require(receipt).logs
        let spoke = BridgeAllowlist.arbitrum.across!.spokePool
        // O depositId da entrega real (o do recibo de deposito na origem; aqui, lido da
        // propria entrega, para conferir que o id amarra).
        let fill = try #require(logs.first { $0.address == spoke && $0.topics.first == BridgeArrival.filledRelayTopic })
        let id = BigUInt(bigEndian: fill.topics[2])
        #expect(BridgeArrival.acrossDelivered(logs, transfer: transfer(), destinationSpoke: spoke, depositID: id, destinationWrappedNative: BridgeAllowlist.arbitrum.across!.wrappedNative))
        #expect(!BridgeArrival.acrossDelivered(logs, transfer: transfer(), destinationSpoke: spoke, depositID: id + 1, destinationWrappedNative: BridgeAllowlist.arbitrum.across!.wrappedNative))
        #expect(!BridgeArrival.acrossDelivered(logs, transfer: transfer(output: 1), destinationSpoke: spoke, depositID: id, destinationWrappedNative: BridgeAllowlist.arbitrum.across!.wrappedNative))
        #expect(!BridgeArrival.acrossDelivered(logs, transfer: transfer(), destinationSpoke: BridgeAllowlist.base.across!.spokePool, depositID: id, destinationWrappedNative: BridgeAllowlist.arbitrum.across!.wrappedNative))
    }
}
