import EscaliburChains
import EscaliburCore
import Foundation

// Os quatro clientes de cotacao sem API key. Formatos conferidos ao vivo em 26/09/2026
// (respostas gravadas em Tests/EscaliburChainsTests/Fixtures/trade).
//
// Todos pedem: `amountIn` exato, venda (exact in), a tolerancia do dono, `from` = dono e
// destinatario = dono. Nenhum recebe taxa de integrador (hoje zero). A resposta vira uma
// `TradeProposal` crua; a validacao decide.

// MARK: Velora

/// Velora (ex-ParaSwap), API v6.2: `GET /swap` devolve a rota e a transacao numa
/// chamada so. `version=6.2` e obrigatorio (sem ele cai no v5); `includeContractMethods`
/// restringe a `swapExactAmountIn`, a unica funcao que a carteira decodifica;
/// `partner=escalibur` sem `partnerFeeBps` tira a taxa de 1 bp que a Velora poe no
/// parceiro anonimo (visto ao vivo: `partner: "anon"`, `partnerFee: 0.01`).
public struct VeloraClient: TradeQuoteSource {
    public let provider = TradeProvider.velora
    let client: HTTPClient
    let base: URL

    public init(client: HTTPClient = .shared, base: URL = Endpoints.trade["velora"]!.baseURL) {
        self.client = client
        self.base = base
    }

    public func propose(_ request: TradeQuoteRequest) async throws -> TradeProposal {
        let intent = request.intent
        guard let chainID = intent.chain.evmChainID else { throw TradeProviderError.unsupported(provider) }
        let owner = TradeWire.lower(intent.owner)
        let url = try TradeWire.url(base, "swap", [
            ("srcToken", TradeWire.token(intent.sell, native: TradeWire.eeee)), ("srcDecimals", "\(intent.sell.decimals)"),
            ("destToken", TradeWire.token(intent.buy, native: TradeWire.eeee)), ("destDecimals", "\(intent.buy.decimals)"),
            ("amount", intent.amountIn.decimalString), ("side", "SELL"), ("network", "\(chainID)"), ("version", "6.2"),
            ("includeContractMethods", "swapExactAmountIn"), ("partner", "escalibur"),
            ("userAddress", owner), ("receiver", owner), ("slippage", "\(intent.slippageBps)"),
        ])
        let data: Data
        do {
            data = try await client.get(url, timeout: 10)
        } catch let failure as HTTPClient.Failure {
            if case .status(400) = failure { throw TradeProviderError.noRoute(provider) }
            throw TradeProviderError.http(provider, failure)
        }
        return try Self.parse(data)
    }

    struct Response: Decodable {
        struct PriceRoute: Decodable {
            let destAmount: String
            let tokenTransferProxy: String?
            let gasCost: String?
            let srcUSD: String?
            let destUSD: String?
            let bestRoute: [Route]?
        }
        struct Route: Decodable { let swaps: [Swap] }
        struct Swap: Decodable { let swapExchanges: [Exchange] }
        struct Exchange: Decodable {
            let exchange: String
            let poolAddresses: [String]?
        }
        struct Transaction: Decodable {
            let from: String?
            let to: String
            let value: String
            let data: String
            let chainId: UInt64?
        }
        let priceRoute: PriceRoute
        let txParams: Transaction
    }

    static func parse(_ data: Data) throws -> TradeProposal {
        let p = TradeProvider.velora
        let response = try TradeWire.decode(Response.self, data, p)
        let route = response.priceRoute
        let tx = response.txParams
        var sources = Set<String>()
        for path in route.bestRoute ?? [] {
            for swap in path.swaps {
                for exchange in swap.swapExchanges {
                    sources.insert(exchange.exchange.lowercased())
                    for pool in exchange.poolAddresses ?? [] { sources.insert(pool.lowercased()) }
                }
            }
        }
        return TradeProposal(
            provider: p, chainID: tx.chainId, from: try? TradeWire.address(tx.from, p, "from"),
            to: try TradeWire.address(tx.to, p, "to"), value: try TradeWire.amount(tx.value, p, "value"),
            data: try TradeWire.bytes(tx.data, p, "data"), expectedOut: try TradeWire.amount(route.destAmount, p, "destAmount"),
            spender: try route.tokenTransferProxy.map { try TradeWire.address($0, p, "tokenTransferProxy") },
            gasEstimate: route.gasCost.flatMap(UInt64.init), routeSources: sources.isEmpty ? nil : sources,
            reportedPriceImpactBps: TradeWire.impactBps(inUSD: route.srcUSD, outUSD: route.destUSD)
        )
    }
}

// MARK: KyberSwap

/// KyberSwap Aggregator API: `GET /{rede}/api/v1/routes` e `POST /{rede}/api/v1/route/build`
/// com o `routeSummary` devolvido byte a byte. `x-client-id` identifica o app (sem key).
public struct KyberSwapClient: TradeQuoteSource {
    public let provider = TradeProvider.kyberSwap
    let client: HTTPClient
    let base: URL

    static let slugs: [UInt64: String] = [
        1: "ethereum", 42161: "arbitrum", 8453: "base", 10: "optimism", 137: "polygon", 56: "bsc", 43114: "avalanche",
    ]
    static let headers = ["x-client-id": "escalibur"]

    public init(client: HTTPClient = .shared, base: URL = Endpoints.trade["kyberSwap"]!.baseURL) {
        self.client = client
        self.base = base
    }

    public func propose(_ request: TradeQuoteRequest) async throws -> TradeProposal {
        let intent = request.intent
        guard let chainID = intent.chain.evmChainID, let slug = Self.slugs[chainID] else { throw TradeProviderError.unsupported(provider) }
        let routesURL = try TradeWire.url(base, "\(slug)/api/v1/routes", [
            ("tokenIn", TradeWire.token(intent.sell, native: TradeWire.eeee)),
            ("tokenOut", TradeWire.token(intent.buy, native: TradeWire.eeee)),
            ("amountIn", intent.amountIn.decimalString),
        ])
        do {
            let routes = try await client.get(routesURL, headers: Self.headers, timeout: 10)
            let body = try Self.buildBody(routes: routes, intent: intent)
            let build = try await client.post(base.appendingPathComponent("\(slug)/api/v1/route/build"), json: body, headers: Self.headers, timeout: 10)
            return try Self.parse(routes: routes, build: build)
        } catch let failure as HTTPClient.Failure {
            if case .status(400) = failure { throw TradeProviderError.noRoute(provider) }
            throw TradeProviderError.http(provider, failure)
        }
    }

    /// O corpo do build: o `routeSummary` cru, e os campos da carteira.
    static func buildBody(routes: Data, intent: TradeIntent) throws -> Data {
        let summary: Data
        do {
            summary = try RawJSON.value(routes, path: ["data", "routeSummary"])
        } catch {
            throw TradeProviderError.noRoute(.kyberSwap)
        }
        let owner = TradeWire.lower(intent.owner)
        let tail = #","sender":"\#(owner)","recipient":"\#(owner)","slippageTolerance":\#(intent.slippageBps),"source":"escalibur"}"#
        return Data(#"{"routeSummary":"#.utf8) + summary + Data(tail.utf8)
    }

    struct Routes: Decodable {
        struct Payload: Decodable { let routeSummary: Summary }
        struct Summary: Decodable {
            let route: [[Hop]]?
            let amountInUsd: String?
            let amountOutUsd: String?
        }
        struct Hop: Decodable {
            let pool: String?
            let exchange: String?
        }
        let data: Payload?
    }

    struct Build: Decodable {
        struct Payload: Decodable {
            let amountOut: String
            let gas: String?
            let routerAddress: String
            let data: String
            let transactionValue: String
            let amountInUsd: String?
            let amountOutUsd: String?
        }
        let code: Int?
        let data: Payload?
    }

    static func parse(routes: Data, build: Data) throws -> TradeProposal {
        let p = TradeProvider.kyberSwap
        let summary = try TradeWire.decode(Routes.self, routes, p).data?.routeSummary
        guard let payload = try TradeWire.decode(Build.self, build, p).data else { throw TradeProviderError.noRoute(p) }
        var sources = Set<String>()
        for path in summary?.route ?? [] {
            for hop in path {
                if let pool = hop.pool { sources.insert(pool.lowercased()) }
                if let exchange = hop.exchange { sources.insert(exchange.lowercased()) }
            }
        }
        return TradeProposal(
            provider: p, chainID: nil, from: nil, to: try TradeWire.address(payload.routerAddress, p, "routerAddress"),
            value: try TradeWire.amount(payload.transactionValue, p, "transactionValue"),
            data: try TradeWire.bytes(payload.data, p, "data"), expectedOut: try TradeWire.amount(payload.amountOut, p, "amountOut"),
            spender: nil, gasEstimate: payload.gas.flatMap(UInt64.init), routeSources: sources.isEmpty ? nil : sources,
            reportedPriceImpactBps: TradeWire.impactBps(inUSD: payload.amountInUsd ?? summary?.amountInUsd,
                                                        outUSD: payload.amountOutUsd ?? summary?.amountOutUsd)
        )
    }
}

// MARK: LI.FI

/// LI.FI `GET /v1/quote`, so na mesma rede (`fromChain == toChain`, `allowBridges=none`).
/// Sem key: 200 requisicoes a cada 2 horas por IP (visto ao vivo: `ratelimit-limit`).
/// A LI.FI cobra 0,25% fixos na calldata; a validacao confere o teto.
public struct LiFiClient: TradeQuoteSource {
    public let provider = TradeProvider.lifi
    let client: HTTPClient
    let base: URL

    public init(client: HTTPClient = .shared, base: URL = Endpoints.trade["lifi"]!.baseURL) {
        self.client = client
        self.base = base
    }

    public func propose(_ request: TradeQuoteRequest) async throws -> TradeProposal {
        let intent = request.intent
        guard let chainID = intent.chain.evmChainID else { throw TradeProviderError.unsupported(provider) }
        let owner = TradeWire.lower(intent.owner)
        // Tolerancia como fracao decimal: 50 bps = "0.005".
        let slippage = TradeDecimal(mantissa: BigUInt(intent.slippageBps), scale: 4)
        let url = try TradeWire.url(base, "quote", [
            ("fromChain", "\(chainID)"), ("toChain", "\(chainID)"),
            ("fromToken", TradeWire.token(intent.sell, native: TradeWire.zero)),
            ("toToken", TradeWire.token(intent.buy, native: TradeWire.zero)),
            ("fromAmount", intent.amountIn.decimalString), ("fromAddress", owner), ("toAddress", owner),
            ("slippage", Self.fraction(slippage)), ("integrator", "escalibur"), ("allowBridges", "none"),
        ])
        do {
            return try Self.parse(try await client.get(url, timeout: 10))
        } catch let failure as HTTPClient.Failure {
            if case .status(404) = failure { throw TradeProviderError.noRoute(provider) }
            throw TradeProviderError.http(provider, failure)
        }
    }

    static func fraction(_ value: TradeDecimal) -> String {
        let digits = value.mantissa.decimalString
        let padded = String(repeating: "0", count: max(0, value.scale + 1 - digits.count)) + digits
        let integer = padded.prefix(padded.count - value.scale)
        let fraction = padded.suffix(value.scale)
        return value.scale == 0 ? String(integer) : "\(integer).\(fraction)"
    }

    struct Response: Decodable {
        struct Transaction: Decodable {
            let to: String
            let data: String
            let value: String
            let chainId: UInt64?
            let from: String?
        }
        struct Estimate: Decodable {
            let toAmount: String
            let approvalAddress: String?
            let fromAmountUSD: String?
            let toAmountUSD: String?
            let gasCosts: [Gas]?
        }
        struct Gas: Decodable { let estimate: String? }
        let transactionRequest: Transaction
        let estimate: Estimate
    }

    static func parse(_ data: Data) throws -> TradeProposal {
        let p = TradeProvider.lifi
        let response = try TradeWire.decode(Response.self, data, p)
        let tx = response.transactionRequest
        let estimate = response.estimate
        return TradeProposal(
            provider: p, chainID: tx.chainId, from: try? TradeWire.address(tx.from, p, "from"),
            to: try TradeWire.address(tx.to, p, "to"), value: try TradeWire.amount(tx.value, p, "value"),
            data: try TradeWire.bytes(tx.data, p, "data"), expectedOut: try TradeWire.amount(estimate.toAmount, p, "toAmount"),
            spender: try estimate.approvalAddress.map { try TradeWire.address($0, p, "approvalAddress") },
            gasEstimate: estimate.gasCosts?.first?.estimate.flatMap(UInt64.init),
            // A LI.FI roteia por outros agregadores e nao diz por quais pools: rota opaca.
            routeSources: nil,
            reportedPriceImpactBps: TradeWire.impactBps(inUSD: estimate.fromAmountUSD, outUSD: estimate.toAmountUSD)
        )
    }
}

// MARK: De¹

/// De¹ (ex-OpenOcean), `GET /v4/{chainId}/swap` em `open-api.de1.exchange` (o dominio
/// antigo fica atras de Cloudflare). Quantias com casas (`amountDecimals`,
/// `gasPriceDecimals`). A De¹ poe o minimo 0,1 ponto abaixo da tolerancia pedida (visto
/// ao vivo: 0,5% pedido devolve minimo em 99,4%), entao o cliente pede 0,1 ponto a
/// menos; tolerancia abaixo de 0,15% fica sem De¹ (o minimo da API e 0,05%).
public struct De1Client: TradeQuoteSource {
    public let provider = TradeProvider.de1
    let client: HTTPClient
    let base: URL

    static let hiddenSlippageBps: UInt32 = 10
    static let minimumSlippageBps: UInt32 = 5

    public init(client: HTTPClient = .shared, base: URL = Endpoints.trade["de1"]!.baseURL) {
        self.client = client
        self.base = base
    }

    public func propose(_ request: TradeQuoteRequest) async throws -> TradeProposal {
        let intent = request.intent
        guard let chainID = intent.chain.evmChainID, TradeAllowlist.router(for: .de1, on: intent.chain) != nil else {
            throw TradeProviderError.unsupported(provider)
        }
        guard intent.slippageBps >= Self.hiddenSlippageBps + Self.minimumSlippageBps else { throw TradeProviderError.unsupported(provider) }
        let slippage = TradeDecimal(mantissa: BigUInt(intent.slippageBps - Self.hiddenSlippageBps), scale: 2)
        let url = try TradeWire.url(base, "\(chainID)/swap", [
            ("inTokenAddress", TradeWire.token(intent.sell, native: TradeWire.eeee)),
            ("outTokenAddress", TradeWire.token(intent.buy, native: TradeWire.eeee)),
            ("amountDecimals", intent.amountIn.decimalString),
            ("gasPriceDecimals", (request.gasPriceWei.isZero ? BigUInt(1_000_000_000) : request.gasPriceWei).decimalString),
            ("slippage", LiFiClient.fraction(slippage)), ("account", TradeWire.lower(intent.owner)),
        ])
        do {
            return try Self.parse(try await client.get(url, timeout: 10))
        } catch let failure as HTTPClient.Failure {
            throw TradeProviderError.http(provider, failure)
        }
    }

    /// `estimatedGas` vem como numero no `/swap` e como texto no `/quote`.
    struct FlexibleUInt64: Decodable {
        let value: UInt64?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(UInt64.self) { value = number }
            else if let text = try? container.decode(String.self) { value = UInt64(text) }
            else { value = nil }
        }
    }

    struct Response: Decodable {
        struct Payload: Decodable {
            let to: String
            let data: String
            let value: String
            let outAmount: String
            let estimatedGas: FlexibleUInt64?
            let chainId: UInt64?
            let from: String?
            let price_impact: String?
        }
        let code: Int
        let data: Payload?
    }

    static func parse(_ data: Data) throws -> TradeProposal {
        let p = TradeProvider.de1
        let response = try TradeWire.decode(Response.self, data, p)
        guard response.code == 200, let payload = response.data else { throw TradeProviderError.noRoute(p) }
        return TradeProposal(
            provider: p, chainID: payload.chainId, from: try? TradeWire.address(payload.from, p, "from"),
            to: try TradeWire.address(payload.to, p, "to"), value: try TradeWire.amount(payload.value, p, "value"),
            data: try TradeWire.bytes(payload.data, p, "data"), expectedOut: try TradeWire.amount(payload.outAmount, p, "outAmount"),
            spender: nil, gasEstimate: payload.estimatedGas?.value,
            // O `/swap` nao diz a rota: opaca, nunca divide.
            routeSources: nil, reportedPriceImpactBps: TradeWire.percentText(payload.price_impact)
        )
    }
}
