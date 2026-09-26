import Foundation
@testable import EscaliburChains
import EscaliburCore

/// Apoio dos testes da troca: as respostas reais dos provedores gravadas em
/// Fixtures/trade (ver LEIA-ME.txt ali), a intencao de cada uma e simulacoes sinteticas.
///
/// O dono das fixtures e o endereco da chave de teste da EIP-155 (0x46...46):
/// 0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F. As cotacoes foram pedidas com ele como
/// `from` e destinatario, entao a calldata real pode ser validada e assinada no teste.
enum TradeTestSupport {
    typealias T = EVMTestSupport

    static let owner = T.address("0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F")
    static let stranger = T.address("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
    /// O instante em que as fixtures foram gravadas (26/09/2026 02:50 UTC).
    static let recordedAt = Date(timeIntervalSince1970: 1_790_391_000)

    static let baseUSDC = EVMToken(chain: .base, contract: T.address("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"), symbol: "USDC", decimals: 6)
    static let arbUSDC = EVMToken(chain: .arbitrum, contract: T.address("0xaf88d065e77c8cC2239327C5EDb3A432268e5831"), symbol: "USDC", decimals: 6)
    static let arbUSDT = EVMToken(chain: .arbitrum, contract: T.address("0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9"), symbol: "USDT", decimals: 6)
    static let ethUSDT = EVMToken(chain: .ethereum, contract: T.address("0xdAC17F958D2ee523a2206206994597C13D831ec7"), symbol: "USDT", decimals: 6)

    /// 100 USDC -> ETH na Base.
    static func baseIntent(slippage: UInt32 = 50, amount: BigUInt = 100_000_000) throws -> TradeIntent {
        try TradeIntent(owner: owner, sell: .token(baseUSDC), buy: .native(.base), amountIn: amount, slippageBps: slippage)
    }

    /// 0,04 ETH -> USDC na Arbitrum.
    static func arbIntent() throws -> TradeIntent {
        try TradeIntent(owner: owner, sell: .native(.arbitrum), buy: .token(arbUSDC), amountIn: BigUInt(decimal: "40000000000000000")!, slippageBps: 50)
    }

    /// 100 USDC -> USDT na Arbitrum.
    static func arbStableIntent() throws -> TradeIntent {
        try TradeIntent(owner: owner, sell: .token(arbUSDC), buy: .token(arbUSDT), amountIn: 100_000_000, slippageBps: 50)
    }

    // MARK: Fixtures

    static func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/trade") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: fixtureData(name)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return root
    }

    static func string(_ object: Any?, _ path: String...) -> String? {
        var current = object
        for key in path { current = (current as? [String: Any])?[key] }
        if let text = current as? String { return text }
        if let number = current as? NSNumber { return number.stringValue }
        return nil
    }

    static func amount(_ text: String?) -> BigUInt {
        guard let text else { return 0 }
        return text.hasPrefix("0x") ? BigUInt(hex: text) ?? 0 : BigUInt(decimal: text) ?? 0
    }

    /// A proposta como o cliente de rede a monta, lida da resposta gravada.
    static func proposal(_ provider: TradeProvider, _ name: String) throws -> TradeProposal {
        let root = try json(name)
        switch provider {
        case .velora:
            let tx = root["txParams"]
            let route = root["priceRoute"]
            return TradeProposal(
                provider: .velora, chainID: UInt64(string(tx, "chainId") ?? ""), from: try? EVMAddress(string(tx, "from") ?? ""),
                to: T.address(string(tx, "to")!), value: amount(string(tx, "value")), data: T.bytes(string(tx, "data")!),
                expectedOut: amount(string(route, "destAmount")), spender: try? EVMAddress(string(route, "tokenTransferProxy") ?? ""),
                gasEstimate: UInt64(string(route, "gasCost") ?? ""), routeSources: ["velora-route"], reportedPriceImpactBps: nil
            )
        case .kyberSwap:
            let data = root["data"]
            return TradeProposal(
                provider: .kyberSwap, chainID: nil, from: nil, to: T.address(string(data, "routerAddress")!),
                value: amount(string(data, "transactionValue")), data: T.bytes(string(data, "data")!),
                expectedOut: amount(string(data, "amountOut")), spender: nil, gasEstimate: UInt64(string(data, "gas") ?? ""),
                routeSources: ["kyber-route"], reportedPriceImpactBps: nil
            )
        case .lifi:
            let tx = root["transactionRequest"]
            let estimate = root["estimate"]
            return TradeProposal(
                provider: .lifi, chainID: UInt64(string(tx, "chainId") ?? ""), from: try? EVMAddress(string(tx, "from") ?? ""),
                to: T.address(string(tx, "to")!), value: amount(string(tx, "value")), data: T.bytes(string(tx, "data")!),
                expectedOut: amount(string(estimate, "toAmount")), spender: try? EVMAddress(string(estimate, "approvalAddress") ?? ""),
                gasEstimate: nil, routeSources: nil, reportedPriceImpactBps: nil
            )
        case .de1:
            let data = root["data"]
            return TradeProposal(
                provider: .de1, chainID: UInt64(string(data, "chainId") ?? ""), from: try? EVMAddress(string(data, "from") ?? ""),
                to: T.address(string(data, "to")!), value: amount(string(data, "value")), data: T.bytes(string(data, "data")!),
                expectedOut: amount(string(data, "outAmount")), spender: nil, gasEstimate: UInt64(string(data, "estimatedGas") ?? ""),
                routeSources: nil, reportedPriceImpactBps: nil
            )
        }
    }

    /// Troca a calldata mantendo o resto da proposta.
    static func with(_ proposal: TradeProposal, to: EVMAddress? = nil, value: BigUInt? = nil, data: [UInt8]? = nil,
                     chainID: UInt64?? = nil, spender: EVMAddress?? = nil, expectedOut: BigUInt? = nil,
                     impact: Int?? = nil) -> TradeProposal {
        TradeProposal(
            provider: proposal.provider, chainID: chainID ?? proposal.chainID, from: proposal.from, to: to ?? proposal.to,
            value: value ?? proposal.value, data: data ?? proposal.data, expectedOut: expectedOut ?? proposal.expectedOut,
            spender: spender ?? proposal.spender, gasEstimate: proposal.gasEstimate, routeSources: proposal.routeSources,
            reportedPriceImpactBps: impact ?? proposal.reportedPriceImpactBps
        )
    }

    /// Decodifica, aplica `change` aos argumentos e recodifica com a mesma funcao. E
    /// assim que os testes montam a calldata adulterada: um provedor hostil manda
    /// calldata valida, com um campo trocado.
    static func mutate(_ data: [UInt8], router: TradeRouter, _ change: ([ABIValue]) -> [ABIValue]) throws -> [UInt8] {
        let selector = Array(data.prefix(4))
        guard let function = router.functions.first(where: { $0.selector == selector }) else { throw CocoaError(.featureUnsupported) }
        return try function.encodeCall(change(function.decodeCall(data)))
    }

    /// Troca um item de um array ABI (tupla ou lista) num caminho de indices.
    static func replacing(_ value: ABIValue, at path: [Int], with replacement: ABIValue) -> ABIValue {
        guard let first = path.first else { return replacement }
        switch value {
        case .tuple(var items):
            items[first] = replacing(items[first], at: Array(path.dropFirst()), with: replacement)
            return .tuple(items)
        case .array(var items):
            items[first] = replacing(items[first], at: Array(path.dropFirst()), with: replacement)
            return .array(items)
        default:
            return value
        }
    }

    static func replacing(_ arguments: [ABIValue], at path: [Int], with replacement: ABIValue) -> [ABIValue] {
        var out = arguments
        out[path[0]] = replacing(out[path[0]], at: Array(path.dropFirst()), with: replacement)
        return out
    }

    static func value(_ arguments: [ABIValue], at path: [Int]) -> ABIValue? {
        var current: ABIValue? = arguments[path[0]]
        for index in path.dropFirst() {
            switch current {
            case .tuple(let items)?, .array(let items)?: current = items.indices.contains(index) ? items[index] : nil
            default: return nil
            }
        }
        return current
    }

    // MARK: Estado e simulacao sinteticos

    static let gwei = BigUInt(1_000_000_000)

    static func network(_ chain: Chain, nonce: UInt64 = 7, balance: BigUInt = BigUInt(decimal: "1000000000000000000")!, l1: BigUInt? = nil) -> EVMNetworkState {
        EVMNetworkState(
            chain: chain, pendingNonces: [nonce, nonce], baseFeePerGas: BigUInt(5_000_000),
            priorityFees: EVMPriorityFees(slow: BigUInt(1_000_000), normal: BigUInt(1_000_000), fast: BigUInt(2_000_000)),
            gasEstimate: 21_000, l1DataFee: l1, nativeBalance: balance, destinationHasCode: true
        )
    }

    static func word(_ value: BigUInt) -> [UInt8] { value.bigEndianBytes(padTo: 32)! }
    static func topic(_ address: EVMAddress) -> [UInt8] { [UInt8](repeating: 0, count: 12) + address.bytes }

    static func transferLog(_ token: EVMAddress, from: EVMAddress, to: EVMAddress, _ amount: BigUInt) -> TradeSimulatedLog {
        TradeSimulatedLog(address: token, topics: [TradeSimulationCheck.transferTopic, topic(from), topic(to)], data: word(amount))
    }

    static func approvalLog(_ token: EVMAddress, owner: EVMAddress, spender: EVMAddress, _ amount: BigUInt) -> TradeSimulatedLog {
        TradeSimulatedLog(address: token, topics: [TradeSimulationCheck.approvalTopic, topic(owner), topic(spender)], data: word(amount))
    }

    /// Uma simulacao honesta do plano: approve(s) com o Approval exato, e a troca com o
    /// token saindo do dono e `received` do comprado entrando.
    static func simulation(_ quote: ValidatedTradeQuote, source: String, allowance: BigUInt?, received: BigUInt? = nil,
                           extraSwapLogs: [TradeSimulatedLog] = []) -> TradeSimulation {
        let intent = quote.intent
        let request = TradePlanner.simulationRequest(for: quote, currentAllowance: allowance)
        var calls = [TradeSimulatedCall]()
        for value in request.approvals {
            calls.append(TradeSimulatedCall(success: true, gasUsed: 46_000, logs: [
                approvalLog(intent.sell.contract!, owner: intent.owner, spender: quote.spender, value),
            ]))
        }
        let sellToken = intent.sell.contract ?? TradeConstants.eeeeSentinel
        let buyToken = intent.buy.contract ?? TradeConstants.eeeeSentinel
        let logs = [
            transferLog(sellToken, from: intent.owner, to: quote.to, intent.amountIn),
            transferLog(buyToken, from: quote.to, to: intent.owner, received ?? quote.expectedOut),
        ] + extraSwapLogs
        calls.append(TradeSimulatedCall(success: true, gasUsed: 310_000, logs: logs))
        return TradeSimulation(source: source, calls: calls)
    }

    static func chainState(_ quote: ValidatedTradeQuote, allowance: BigUInt? = 0, balance: BigUInt? = nil,
                           simulations: [TradeSimulation]? = nil, pin: EVMAddress?? = nil, nativeBalance: BigUInt? = nil,
                           l1: BigUInt? = nil, nonce: UInt64 = 7) -> TradeChainState {
        let chain = quote.intent.chain
        var tokenState: EVMTokenState?
        if !quote.intent.sell.isNative {
            tokenState = EVMTokenState(contractHasCode: true, balance: balance ?? quote.intent.amountIn * BigUInt(2), allowance: allowance)
        }
        let sims = simulations ?? [
            simulation(quote, source: "publicnode", allowance: allowance),
            simulation(quote, source: "drpc", allowance: allowance),
        ]
        // OP e Base cobram taxa L1 a parte; o plano recusa sem ela.
        let l1Fee = l1 ?? (EVMFeeProfile.for(chain)?.chargesL1DataFee == true ? BigUInt(10_000_000_000) : nil)
        return TradeChainState(
            network: network(chain, nonce: nonce, balance: nativeBalance ?? BigUInt(decimal: "1000000000000000000")!),
            sellToken: tokenState, routerHasCode: true, routerPin: pin ?? quote.router.pin.expected, simulations: sims,
            approveL1DataFee: l1Fee, swapL1DataFee: l1Fee
        )
    }
}
