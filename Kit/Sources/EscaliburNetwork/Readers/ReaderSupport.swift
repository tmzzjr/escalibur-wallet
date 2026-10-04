import EscaliburChains
import EscaliburCore
import Foundation

// O que os leitores de estado tem em comum: transporte, erros, consenso entre
// provedores e o resultado de transmissao e acompanhamento.
//
// Regras que valem para todos (docs/seguranca.md §5.4 a §5.6):
// - Nada que decide seguranca vem de provedor: chainId, contrato, emissor, endereco de
//   destino e allowlist sao compilados ou vem do dono. O provedor so informa estado.
// - Nonce, sequence e seqno: dois provedores. Divergencia vira erro com nome.
// - Resposta estrita: campo faltando e erro, nunca zero. A unica excecao e o JSON
//   protobuf da Tron, que omite campo numerico igual a zero por definicao do formato
//   (proto3), e cada ponto que usa isso diz.
// - Nenhum erro carrega endereco, valor, hash ou texto de resposta: o erro pode ir para
//   a tela e para relatorio, e §5.6 proibe esses dados em qualquer registro.

/// Por que uma leitura ou transmissao falhou.
public enum ReaderError: Error, Equatable, Sendable {
    /// Resposta fora do formato: campo faltando, tipo errado, numero invalido. `field` e
    /// o caminho do campo, nunca o valor.
    case malformed(field: String)
    /// O no respondeu com erro do protocolo. `code` e o codigo curto do no (`actMalformed`,
    /// `-32000`, `CONTRACT_VALIDATE_ERROR`), nunca a mensagem, que pode trazer endereco.
    case providerError(code: String)
    /// Menos provedores responderam do que a leitura exige.
    case notEnoughProviders(needed: Int, got: Int)
    /// Provedores discordam de um dado que entra na transacao.
    case providersDisagree(field: String)
    /// O provedor esta em outra rede (chainId ou network_id diferente do compilado).
    case wrongNetwork
    /// Valor fora da faixa de sanidade compilada (taxa, gas, bloco velho).
    case implausibleValue(field: String)
    /// A resposta nao e da conta ou do objeto perguntado: provedor trocando dado.
    case responseMismatch(field: String)
    /// A conta do dono nao existe na rede (XRP Ledger antes do primeiro recebimento).
    case accountNotFound
    /// A simulacao da chamada reverteu: com o estado de agora a transacao falharia.
    case executionReverted
    /// A rede nao tem esta leitura nesta versao (ex.: historico da BNB Chain, que nao
    /// tem indexador publico sem chave).
    case unsupported(String)
    /// A transacao assinada nao e desta rede, ou o hash devolvido nao e o calculado aqui.
    case broadcastMismatch
    /// Todos os provedores recusaram a transmissao.
    case broadcastRejected(BroadcastRejection, code: String)
    case invalidInput(String)
}

extension ReaderError {
    /// Codigo de erro vindo de provedor, saneado: so letras, digitos, `_` e `-`, ate 40
    /// caracteres. Um provedor malicioso nao consegue por endereco, valor ou link num
    /// erro que pode chegar a tela ou a um relatorio (docs/seguranca.md §5.4 e §5.6).
    static func sanitized(_ code: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let clean = String(code.filter { allowed.contains($0) }.prefix(40))
        return clean.isEmpty ? "error" : clean
    }
}

/// O motivo de uma recusa de transmissao, traduzido do que cada rede diz. A tela fala
/// com o dono por estes casos, sem repetir o texto do no.
public enum BroadcastRejection: String, Sendable, Equatable {
    /// Nonce ou sequence ja usado: outra transacao entrou antes.
    case nonceTooLow
    /// Nonce ou sequence a frente do da conta.
    case nonceTooHigh
    /// A rede ja tem esta transacao. Na transmissao para dois provedores, o segundo
    /// costuma dizer isto, e conta como aceita.
    case alreadyKnown
    case insufficientFunds
    /// Taxa abaixo do minimo aceito agora.
    case underpriced
    /// Validade vencida (LastLedgerSequence, expiration, valid_until).
    case expired
    case invalidSignature
    case wrongNetwork
    case other
}

/// O resultado de uma transmissao aceita.
public struct BroadcastReceipt: Sendable, Equatable {
    public let chainID: String
    /// O id calculado localmente (`SignedTransaction.id`). Nunca o que o provedor devolve:
    /// um provedor que devolvesse outro hash faria a tela acompanhar outra transacao.
    public let id: String
    /// Nomes compilados dos provedores que aceitaram.
    public let acceptedBy: [String]
    /// Resultado provisorio do no, quando a rede informa (XRP Ledger: `engine_result`).
    public let provisionalResult: String?

    public init(chainID: String, id: String, acceptedBy: [String], provisionalResult: String? = nil) {
        self.chainID = chainID
        self.id = id
        self.acceptedBy = acceptedBy
        self.provisionalResult = provisionalResult
    }
}

/// Onde uma transacao enviada esta.
public enum TransactionStatus: Sendable, Equatable {
    /// Nenhum provedor conhece a transacao (ainda nao propagou, ou caiu).
    case notFound
    /// Aceita, sem resultado final. Tambem quando so um provedor viu o final: o
    /// "confirmado" exige dois (docs/seguranca.md §5.5).
    case pending
    /// Resultado final com sucesso. `block` e o numero do bloco (ledger, seqno de
    /// masterchain); `confirmations`, quando a rede tem esse conceito (EVM).
    case confirmed(block: UInt64?, confirmations: UInt64?)
    /// Entrou e falhou (taxa cobrada), ou venceu sem entrar. `reason` e o codigo da
    /// rede (`tecUNFUNDED_PAYMENT`, `REVERT`, `OUT_OF_ENERGY`, `expired`).
    case failed(reason: String)

    public var isFinal: Bool {
        switch self {
        case .confirmed, .failed: return true
        case .notFound, .pending: return false
        }
    }
}

// MARK: Transporte

/// Uma requisicao HTTP de leitor. Existe para os testes trocarem a rede por respostas
/// gravadas sem tocar no `HTTPClient`.
public struct ReaderRequest: Sendable, Hashable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public let method: Method
    public let url: URL
    public let body: Data?
    public let headers: [String: String]
    /// 10 s para RPC; 30 s para indexador de historico, que monta pagina grande
    /// (docs/seguranca.md §5.1).
    public let timeout: TimeInterval

    public init(method: Method, url: URL, body: Data? = nil, headers: [String: String] = [:], timeout: TimeInterval = 10) {
        self.method = method
        self.url = url
        self.body = body
        self.headers = headers
        self.timeout = timeout
    }

    static func post(_ url: URL, _ json: StrictJSON) -> ReaderRequest {
        ReaderRequest(method: .post, url: url, body: json.serialized)
    }

    static func get(_ url: URL, timeout: TimeInterval = 10) -> ReaderRequest {
        ReaderRequest(method: .get, url: url, timeout: timeout)
    }
}

public protocol ReaderTransport: Sendable {
    func send(_ request: ReaderRequest) async throws -> Data
}

extension HTTPClient: ReaderTransport {
    public func send(_ request: ReaderRequest) async throws -> Data {
        switch request.method {
        case .get: return try await get(request.url, headers: request.headers, timeout: request.timeout)
        case .post: return try await post(request.url, json: request.body ?? Data(), headers: request.headers, timeout: request.timeout)
        }
    }
}

extension URL {
    /// Caminho relativo a uma URL base compilada. So acrescenta segmentos; nunca
    /// troca o host.
    func adding(path: String) -> URL {
        path.split(separator: "/").reduce(self) { $0.appendingPathComponent(String($1)) }
    }

    func adding(query: [(String, String)]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.queryItems = (components.queryItems ?? []) + query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url ?? self
    }
}

// MARK: Consenso entre provedores

typealias Provider = ProviderPool.Provider

/// Perguntas a varios provedores, com o circuit breaker do `ProviderPool`.
///
/// Falha de transporte e resposta fora do formato contam contra o provedor (tres
/// seguidas o tiram por 60 s). Erro do protocolo (o no respondeu, mas com erro) nao
/// conta: o provedor esta de pe, a pergunta e que nao tinha resposta.
enum Quorum {
    static func record(_ error: Error, _ provider: Provider, _ pool: ProviderPool) async {
        switch error {
        case is HTTPClient.Failure, ReaderError.malformed, ReaderError.wrongNetwork, ReaderError.responseMismatch:
            await pool.reportFailure(provider)
        default:
            break
        }
    }

    /// O primeiro provedor que responde, na ordem de preferencia.
    static func first<T: Sendable>(
        _ providers: [Provider], pool: ProviderPool, _ operation: @Sendable (Provider) async throws -> T
    ) async throws -> T {
        var lastError: Error = ReaderError.notEnoughProviders(needed: 1, got: 0)
        for provider in providers {
            do {
                let value = try await operation(provider)
                await pool.reportSuccess(provider)
                return value
            } catch {
                await record(error, provider, pool)
                lastError = error
            }
        }
        throw lastError
    }

    /// Respostas de ate `count` provedores diferentes, na ordem de preferencia. A primeira
    /// onda pergunta a `firstWave` provedores em paralelo (padrao: `count`); as seguintes,
    /// a um de cada vez. Provedor que falha e trocado pelo proximo da lista; `until`
    /// encerra antes quando as respostas ja bastam.
    static func gather<T: Sendable>(
        _ providers: [Provider], pool: ProviderPool, count: Int, firstWave: Int? = nil,
        until done: @Sendable ([T]) -> Bool = { _ in false },
        _ operation: @escaping @Sendable (Provider) async throws -> T
    ) async -> (answers: [(provider: Provider, value: T)], lastError: Error?) {
        var answers: [(provider: Provider, value: T)] = []
        var lastError: Error?
        var remaining = providers[...]
        var first = true
        while !remaining.isEmpty {
            let size = first ? (firstWave ?? count) : (firstWave == nil ? max(1, count - answers.count) : 1)
            first = false
            let wave = Array(remaining.prefix(max(1, size)))
            remaining = remaining.dropFirst(wave.count)
            let results = await withTaskGroup(of: (Int, Result<T, Error>).self) { group in
                for (offset, provider) in wave.enumerated() {
                    group.addTask {
                        do { return (offset, .success(try await operation(provider))) } catch { return (offset, .failure(error)) }
                    }
                }
                var collected: [(Int, Result<T, Error>)] = []
                for await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }
            }
            for (offset, result) in results {
                switch result {
                case .success(let value):
                    await pool.reportSuccess(wave[offset])
                    answers.append((wave[offset], value))
                case .failure(let error):
                    await record(error, wave[offset], pool)
                    lastError = error
                }
            }
            if answers.count >= count || done(answers.map(\.value)) { break }
        }
        return (answers, lastError)
    }

    /// Exatamente `count` respostas de provedores diferentes, ou erro.
    static func collect<T: Sendable>(
        _ providers: [Provider], pool: ProviderPool, count: Int, _ operation: @escaping @Sendable (Provider) async throws -> T
    ) async throws -> [(provider: Provider, value: T)] {
        let (answers, lastError) = await gather(providers, pool: pool, count: count, operation)
        guard answers.count >= count else {
            if answers.isEmpty, let lastError { throw lastError }
            throw ReaderError.notEnoughProviders(needed: count, got: answers.count)
        }
        return Array(answers.prefix(count))
    }

    /// Duas respostas iguais de provedores diferentes. Pergunta a dois em paralelo; se
    /// discordarem, pergunta ao proximo, ate acabar a lista.
    static func agree<T: Sendable & Equatable>(
        _ providers: [Provider], pool: ProviderPool, field: String, _ operation: @escaping @Sendable (Provider) async throws -> T
    ) async throws -> T {
        try await agreeing(providers, pool: pool, field: field, operation).value
    }

    /// Como `agree`, e diz quais dois provedores concordaram (a previa da moeda custom
    /// mostra ao dono de onde vieram as casas decimais).
    static func agreeing<T: Sendable & Equatable>(
        _ providers: [Provider], pool: ProviderPool, field: String, _ operation: @escaping @Sendable (Provider) async throws -> T
    ) async throws -> (value: T, providers: [String]) {
        let (answers, lastError) = await gather(providers, pool: pool, count: providers.count, firstWave: 2, until: { values in
            values.enumerated().contains { index, value in values[(index + 1)...].contains(value) }
        }, operation)
        let values = answers.map(\.value)
        for (index, value) in values.enumerated() {
            if let other = values[(index + 1)...].firstIndex(of: value) {
                return (value, [answers[index].provider.name, answers[other].provider.name])
            }
        }
        if answers.isEmpty, let lastError { throw lastError }
        if answers.count < 2 { throw ReaderError.notEnoughProviders(needed: 2, got: answers.count) }
        throw ReaderError.providersDisagree(field: field)
    }
}

// MARK: Transmissao

extension BroadcastRejection {
    /// Classifica a mensagem de erro de um no EVM (geth, erigon, nethermind, reth e os
    /// agregadores de RPC). A mensagem e lida aqui e descartada: ela pode trazer o
    /// endereco e o saldo do dono, e nao sai deste escopo.
    static func evm(message: String) -> BroadcastRejection {
        let text = message.lowercased()
        if text.contains("already known") || text.contains("known transaction") || text.contains("already imported")
            || text.contains("alreadyknown") || text.contains("already exists") {
            return .alreadyKnown
        }
        if text.contains("nonce too low") || text.contains("nonce is too low") || text.contains("old nonce") { return .nonceTooLow }
        if text.contains("nonce too high") || text.contains("nonce gap") { return .nonceTooHigh }
        if text.contains("insufficient funds") || text.contains("insufficient balance") { return .insufficientFunds }
        if text.contains("underpriced") || text.contains("fee too low") || text.contains("less than block base fee")
            || text.contains("max fee per gas less") || text.contains("tip too low") {
            return .underpriced
        }
        if text.contains("invalid sender") || text.contains("invalid signature") { return .invalidSignature }
        if text.contains("chain id") || text.contains("chainid") { return .wrongNetwork }
        return .other
    }
}

/// Junta as respostas de uma transmissao a varios provedores: aceita se pelo menos um
/// aceitou (ou disse que ja conhecia a transacao); se todos recusaram, o motivo do
/// primeiro.
struct BroadcastTally {
    var accepted: [String] = []
    var rejections: [(BroadcastRejection, String)] = []
    var lastError: Error?

    mutating func add(_ result: Result<String, Error>, provider: Provider) {
        switch result {
        case .success:
            accepted.append(provider.name)
        case .failure(ReaderError.broadcastRejected(.alreadyKnown, _)):
            accepted.append(provider.name)
        case .failure(ReaderError.broadcastRejected(let reason, let code)):
            rejections.append((reason, code))
        case .failure(let error):
            lastError = error
        }
    }

    func receipt(chainID: String, id: String, provisional: String? = nil) throws -> BroadcastReceipt {
        if !accepted.isEmpty {
            return BroadcastReceipt(chainID: chainID, id: id, acceptedBy: accepted, provisionalResult: provisional)
        }
        if let (reason, code) = rejections.first { throw ReaderError.broadcastRejected(reason, code: code) }
        throw lastError ?? ReaderError.notEnoughProviders(needed: 1, got: 0)
    }
}

// MARK: Limite de taxa dos provedores sem chave

/// Espaca as requisicoes por host e tenta de novo, uma vez, a que voltar 429.
///
/// Os provedores publicos sem chave limitam por IP: a TronGrid passa a recusar acima de
/// ~2 requisicoes por segundo, a toncenter aceita 1 por segundo (conferido em
/// 25/09/2026). O relogio de cada host e um so para o processo inteiro (`HostPacer`),
/// porque o limite e do aparelho, nao de cada leitor. Um 429 nao processou nada, entao
/// repetir e seguro, inclusive na transmissao (os mesmos bytes, docs/seguranca.md §5.1).
struct PacedTransport: ReaderTransport {
    let base: ReaderTransport
    /// Intervalo minimo entre requisicoes, por host. Host fora da lista nao espera.
    let intervals: [String: TimeInterval]
    let retryDelay: TimeInterval

    init(base: ReaderTransport, intervals: [String: TimeInterval], retryDelay: TimeInterval = 1.5) {
        self.base = base
        self.intervals = intervals
        self.retryDelay = retryDelay
    }

    func send(_ request: ReaderRequest) async throws -> Data {
        let interval = request.url.host.flatMap { intervals[$0] } ?? 0
        do {
            try await HostPacer.shared.wait(host: request.url.host ?? "", interval: interval)
            return try await base.send(request)
        } catch HTTPClient.Failure.status(429) {
            try await HostPacer.shared.wait(host: request.url.host ?? "", interval: interval, backoff: retryDelay)
            return try await base.send(request)
        }
    }
}

/// O proximo horario livre de cada host, compartilhado por todos os leitores.
actor HostPacer {
    static let shared = HostPacer()

    private var nextSlot: [String: Date] = [:]

    /// Espera a vez do host. `backoff` empurra o relogio do host para frente (depois de
    /// um 429), atrasando tambem as outras requisicoes para ele.
    func wait(host: String, interval: TimeInterval, backoff: TimeInterval = 0) async throws {
        guard interval > 0 || backoff > 0 else { return }
        let now = Date()
        var slot = max(now, nextSlot[host] ?? now)
        if backoff > 0 { slot = max(slot, now.addingTimeInterval(backoff)) }
        nextSlot[host] = slot.addingTimeInterval(interval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    /// So para os testes: o proximo horario reservado do host, se algum. Host sem
    /// intervalo nunca reserva, e por isso nunca espera.
    func reservedSlot(host: String) -> Date? { nextSlot[host] }
}
