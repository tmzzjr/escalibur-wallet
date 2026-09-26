import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

// Os servicos de rede que o motor de troca usa, cada um atras de um protocolo com as
// mesmas assinaturas do tipo real de EscaliburNetwork. Em producao sao os tipos reais;
// nos testes, respostas gravadas. Nenhum deles ve chave, assina ou decide seguranca: o
// que eles devolvem passa pela validacao de EscaliburChains antes de virar plano.

/// O estado da cadeia que a troca e a ordem limite leem (`TradeStateReader`): nonce de
/// duas fontes, baseFee, saldos e allowance (o menor de duas), codigo e pin do router, e
/// a simulacao `eth_simulateV1` em duas fontes.
protocol EVMTradeChainReading: Sendable {
    func network(chain: Chain, owner: EVMAddress, localNextNonce: UInt64?, gasEstimate: UInt64, l1DataFee: BigUInt?,
                 destinationHasCode: Bool) async throws -> EVMNetworkState
    func l1DataFee(chain: Chain, calldataSize: Int) async throws -> BigUInt?
    func token(chain: Chain, token: EVMAddress, owner: EVMAddress, spender: EVMAddress) async throws -> EVMTokenState
    func read(for quote: ValidatedTradeQuote, localNextNonce: UInt64?) async throws -> TradeChainState
    func readCoW(intent: CoWLimitOrderIntent, openOrdersSellTotal: BigUInt, localNextNonce: UInt64?) async throws -> CoWChainState
    func readCancellation(chain: Chain, owner: EVMAddress, uid: [UInt8], localNextNonce: UInt64?) async throws -> EVMNetworkState
}

extension TradeStateReader: EVMTradeChainReading {}

/// A API da CoW (`CoWClient`): registro do appData, envio da ordem assinada (com o UID
/// conferido), soma das ordens abertas e cancelamento fora da cadeia.
protocol EVMCoWService: Sendable {
    func registerAppData(_ appData: CoWAppData, chain: Chain) async throws
    func submit(_ plan: CoWLimitOrderPlan, signature: SignedTransaction) async throws -> [UInt8]
    func openSellTotal(owner: EVMAddress, sellToken: EVMAddress, chain: Chain) async throws -> BigUInt
    func openOrders(owner: EVMAddress, chain: Chain, now: Date) async throws -> [CoWOrderStatus]
    func cancel(uids: [[UInt8]], chain: Chain, owner: EVMAddress, signature: SignedTransaction) async throws
}

extension CoWClient: EVMCoWService {}

/// Precos em dolar, como texto decimal, por id do CoinGecko. Servem para comparar
/// provedores (gas convertido para o token comprado) e para a checagem de sanidade contra
/// o oraculo. Nunca entram no minimo garantido, que e decodificado da calldata. O mesmo
/// oraculo das outras redes (Support/MarketReference.swift).
typealias EVMPriceOracle = TradePriceOracle
typealias EVMMarketPriceOracle = MarketPriceOracle

/// Quanto esperar pela confirmacao da autorizacao antes de enviar a ordem limite a CoW
/// (a CoW recusa ordem sem allowance).
struct EVMConfirmationPolicy: Sendable {
    let interval: Duration
    let attempts: Int

    /// Ate cerca de cinco minutos, perguntando a cada 3 segundos.
    static let standard = EVMConfirmationPolicy(interval: .seconds(3), attempts: 100)
}

/// As ordens limite planejadas e ainda nao enviadas, pelo id do `SigningPlan`.
///
/// O contrato do motor devolve so o `SigningPlan`, e o envio a CoW precisa da ordem, do
/// UID e do appData que o planejador calculou junto. Guarda so dado publico, na memoria,
/// e cada entrada sai no envio ou vence em 10 minutos.
actor EVMPendingLimitOrders {
    static let shared = EVMPendingLimitOrders()
    static let lifetime: TimeInterval = 10 * 60

    private var plans: [UUID: (plan: CoWLimitOrderPlan, storedAt: Date)] = [:]

    func store(_ plan: CoWLimitOrderPlan, now: Date = .now) {
        plans = plans.filter { now.timeIntervalSince($0.value.storedAt) < Self.lifetime }
        plans[plan.signingPlan.id] = (plan, now)
    }

    /// Tira a ordem do registro: um plano e enviado uma vez so.
    func take(_ id: UUID, now: Date = .now) -> CoWLimitOrderPlan? {
        guard let entry = plans.removeValue(forKey: id), now.timeIntervalSince(entry.storedAt) < Self.lifetime else { return nil }
        return entry.plan
    }
}

/// Tudo o que o motor de troca usa da rede, junto. `live` e compartilhado pelo app
/// inteiro: o agregador guarda o circuit breaker e o cache de 10 s, e os leitores guardam
/// o `eth_chainId` ja conferido de cada provedor.
struct EVMTradeServices: Sendable {
    let aggregator: TradeAggregator
    let chainState: any EVMTradeChainReading
    let reader: EVMReader
    let cow: any EVMCoWService
    let prices: any EVMPriceOracle
    let pendingOrders: EVMPendingLimitOrders
    let confirmation: EVMConfirmationPolicy

    static let live = EVMTradeServices(
        aggregator: TradeAggregator(), chainState: TradeStateReader(), reader: .shared, cow: CoWClient(),
        prices: EVMMarketPriceOracle(service: .shared), pendingOrders: .shared, confirmation: .standard
    )
}
