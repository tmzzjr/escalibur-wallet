import EscaliburChains
import EscaliburCore
import Foundation

/// Cliente da Jupiter Swap API v2, sem chave.
///
/// So busca: a cotacao (`/quote`) e as instrucoes (`/build`). Nunca pede nem aceita
/// transacao pronta (`/swap`, `/order`): quem monta a mensagem e o app, e quem
/// decide se ela pode ser assinada e `SolanaSwapPlanner` (docs/seguranca.md §4.6).
///
/// O `/build` recebe o endereco do dono na query (`taker`): e o formato da API.
/// Quando o relay existir, ele recebe o endereco no corpo e monta a query do lado
/// dele, para nao gravar endereco em log de caminho (docs/seguranca.md §5.3).
public actor JupiterClient {
    public static let shared = JupiterClient()

    /// Sem chave a Jupiter aceita 30 requisicoes por minuto por IP: uma a cada 2 s.
    static let minimumInterval: TimeInterval = 2
    /// Cotacao: 15 s (docs/seguranca.md §5.1).
    static let timeout: TimeInterval = 15

    let client: HTTPClient
    let base: URL
    private var nextAllowed = Date.distantPast

    public init(client: HTTPClient = .shared, base: URL = Endpoints.jupiterSwap) {
        self.client = client
        self.base = base
    }

    /// Cotacao de entrada exata, sem taxa de plataforma (a da Escalibur e compilada: zero).
    public func quote(inputMint: SolanaPublicKey, outputMint: SolanaPublicKey, amount: UInt64, slippageBps: UInt16) async throws -> SolanaSwapQuote {
        let data = try await get("quote", query(inputMint: inputMint, outputMint: outputMint, amount: amount, slippageBps: slippageBps))
        return try SolanaSwapQuote.decodeJupiter(data)
    }

    /// As instrucoes da troca para `taker`. `maxAccounts` menor encolhe a rota
    /// quando a transacao nao coube em 1232 bytes.
    public func build(
        inputMint: SolanaPublicKey, outputMint: SolanaPublicKey, amount: UInt64, slippageBps: UInt16, taker: SolanaPublicKey, maxAccounts: Int? = nil
    ) async throws -> SolanaSwapProposal {
        var items = query(inputMint: inputMint, outputMint: outputMint, amount: amount, slippageBps: slippageBps)
        items.append(URLQueryItem(name: "taker", value: taker.base58))
        items.append(URLQueryItem(name: "wrapAndUnwrapSol", value: "true"))
        if let maxAccounts { items.append(URLQueryItem(name: "maxAccounts", value: String(max(8, min(64, maxAccounts))))) }
        return try SolanaSwapProposal.decodeJupiterBuild(try await get("build", items))
    }

    func query(inputMint: SolanaPublicKey, outputMint: SolanaPublicKey, amount: UInt64, slippageBps: UInt16) -> [URLQueryItem] {
        [
            URLQueryItem(name: "inputMint", value: inputMint.base58),
            URLQueryItem(name: "outputMint", value: outputMint.base58),
            URLQueryItem(name: "amount", value: String(amount)),
            URLQueryItem(name: "slippageBps", value: String(slippageBps)),
            URLQueryItem(name: "swapMode", value: "ExactIn"),
            URLQueryItem(name: "platformFeeBps", value: String(SolanaSwapPlanner.escaliburFeeBps)),
        ]
    }

    private func get(_ path: String, _ items: [URLQueryItem]) async throws -> Data {
        // Espaca as chamadas para ficar dentro do limite sem chave. A vaga e
        // reservada antes de dormir: o ator e reentrante durante o `sleep`, e duas
        // chamadas simultaneas nao podem pegar a mesma vaga.
        let now = Date()
        let start = max(now, nextAllowed)
        nextAllowed = start.addingTimeInterval(Self.minimumInterval)
        let wait = start.timeIntervalSince(now)
        if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw HTTPClient.Failure.invalidResponse
        }
        components.queryItems = items
        guard let url = components.url else { throw HTTPClient.Failure.invalidResponse }
        return try await client.get(url, timeout: Self.timeout)
    }
}
