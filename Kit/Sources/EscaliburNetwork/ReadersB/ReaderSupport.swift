import EscaliburChains
import EscaliburCore
import Foundation

// A base dos leitores de UTXO (Bitcoin, Litecoin, Dogecoin) e Stellar.
//
// Tudo o que um provedor devolve e alegacao. Os leitores daqui:
// - decodificam cada resposta em struct com campos exatos: campo obrigatorio que
//   falta, ou vem com tipo errado, recusa a resposta inteira (nada de "0" por falta);
// - nunca pegam de provedor endereco de destino, chainId, passphrase ou digesto;
// - nunca registram nada: nem endereco, nem valor, nem resposta. Os erros carregam
//   so o nome do campo, nunca o conteudo;
// - consultam endereco por endereco. A xpub nunca sai do aparelho: os enderecos
//   saem dela aqui, e so eles vao para a rede (docs/seguranca.md §5.5).

// MARK: Erros

/// Por que um leitor recusou uma resposta ou uma operacao.
public enum ChainReaderError: Error, Equatable, Sendable {
    /// A resposta nao tem o formato esperado. Carrega so o caminho do campo.
    case malformedResponse(field: String)
    /// A resposta fala de outra coisa (outra conta, outra transacao, outro ativo).
    case mismatchedResponse
    /// Menos fontes independentes do que a regra pede (taxa, transmissao).
    case notEnoughSources(needed: Int, got: Int)
    /// Dois provedores responderam coisas diferentes onde precisavam concordar.
    case providersDisagree
    /// A transacao assinada nao fecha consigo mesma (bytes, codificacao, id), ou e
    /// de outra rede. Nada e transmitido.
    case signedTransactionInconsistent
    /// Nenhum provedor aceitou a transmissao.
    case broadcastRejected
    /// A conta derivada nao serve para esta rede (tipo de script, rede errada).
    case unsupportedAccount
    /// Gap limit fora da faixa aceita.
    case invalidGapLimit
    /// A varredura passou do teto de enderecos por cadeia sem achar o fim.
    case tooManyAddresses
}

// MARK: Transporte

/// O que os leitores precisam da internet: GET e POST com tipo de conteudo.
///
/// Existe para os testes trocarem a rede por respostas gravadas. Em producao e o
/// `HTTPClient` (sessao efemera, sem cache, sem redirecionamento, 4 MB).
public protocol ChainReaderTransport: Sendable {
    func fetch(_ url: URL) async throws -> Data
    func send(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws -> Data
}

/// O transporte de producao, sobre o `HTTPClient`.
public struct HTTPReaderTransport: ChainReaderTransport {
    private let client: HTTPClient

    public init(client: HTTPClient = .shared) {
        self.client = client
    }

    public func fetch(_ url: URL) async throws -> Data {
        try await client.get(url)
    }

    /// O `post` do cliente marca JSON; o cabecalho passado depois substitui o tipo,
    /// que no Esplora e texto (`POST /tx` com o hex) e na Horizon e formulario.
    public func send(_ url: URL, body: Data, contentType: String, timeout: TimeInterval) async throws -> Data {
        try await client.post(url, json: body, headers: ["Content-Type": contentType], timeout: timeout)
    }
}

// MARK: Decodificacao estrita

enum ReaderDecode {
    /// Decodifica com as chaves exatas de cada struct. Sem `convertFromSnakeCase`:
    /// ele tambem reescreve chaves de dicionario, e `config.memo_required` viraria
    /// `config.memoRequired`, sumindo com o aviso de memo obrigatorio (SEP-29).
    static func json<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw ChainReaderError.malformedResponse(field: field(of: error))
        } catch {
            throw ChainReaderError.malformedResponse(field: "")
        }
    }

    /// So o caminho do campo, nunca o valor.
    private static func field(of error: DecodingError) -> String {
        let path: [CodingKey]
        switch error {
        case .keyNotFound(let key, let context): path = context.codingPath + [key]
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): path = context.codingPath
        @unknown default: path = []
        }
        return path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }

    /// Resposta em texto puro (Esplora: altura, hex, txid), sem espacos em volta.
    static func text(_ data: Data, field: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw ChainReaderError.malformedResponse(field: field)
        }
        return text
    }

    /// Inteiro decimal sem sinal, so digitos ASCII.
    static func unsigned(_ text: String, field: String) throws -> UInt64 {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let value = UInt64(text) else {
            throw ChainReaderError.malformedResponse(field: field)
        }
        return value
    }

    /// Hex de transacao: pares de digitos, nada mais.
    static func hexBytes(_ text: String, field: String) throws -> [UInt8] {
        guard text.count % 2 == 0, text.count >= 20, !text.hasPrefix("0x"), let bytes = Hex.decode(text) else {
            throw ChainReaderError.malformedResponse(field: field)
        }
        return bytes
    }

    /// Txid no formato de explorador (64 hex, bytes invertidos).
    static func txid(_ text: String, field: String) throws -> UTXOTxID {
        guard text == text.lowercased(), let id = UTXOTxID(hex: text) else { throw ChainReaderError.malformedResponse(field: field) }
        return id
    }
}

// MARK: Valores em texto decimal

enum DecimalUnits {
    /// "12.3456789" para a menor unidade, com no maximo `decimals` casas. Sem sinal,
    /// sem expoente, sem ponto flutuante no caminho.
    static func parse(_ text: String, decimals: Int, field: String) throws -> BigUInt {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ $0.utf8.allSatisfy { (0x30...0x39).contains($0) } })
        else { throw ChainReaderError.malformedResponse(field: field) }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= decimals, parts.count == 1 || !fraction.isEmpty,
              let value = BigUInt(decimal: String(parts[0]) + fraction + String(repeating: "0", count: decimals - fraction.count))
        else { throw ChainReaderError.malformedResponse(field: field) }
        return value
    }

    /// A menor unidade em texto decimal, como a Horizon recebe (`source_amount`).
    static func format(_ value: BigUInt, decimals: Int) -> String {
        let digits = value.decimalString
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let cut = padded.index(padded.endIndex, offsetBy: -decimals)
        return "\(padded[..<cut]).\(padded[cut...])"
    }
}

// MARK: Concorrencia limitada

enum ReaderConcurrency {
    /// `map` com no maximo `limit` requisicoes ao mesmo tempo, na ordem de entrada.
    /// Poucas em paralelo: provedores publicos limitam por IP (o mempool.space fala
    /// em ~10 por segundo), e rajada grande so troca velocidade por bloqueio.
    static func map<T: Sendable, R: Sendable>(
        _ items: [T], limit: Int, _ transform: @escaping @Sendable (T) async throws -> R
    ) async throws -> [R] {
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        try await withThrowingTaskGroup(of: (Int, R).self) { group in
            while next < min(limit, items.count) {
                let index = next
                group.addTask { (index, try await transform(items[index])) }
                next += 1
            }
            while let (index, value) = try await group.next() {
                results[index] = value
                if next < items.count {
                    let index = next
                    group.addTask { (index, try await transform(items[index])) }
                    next += 1
                }
            }
        }
        return results.map { $0! }
    }
}

// MARK: URL

enum ReaderURL {
    /// Junta caminho e query sem deixar `appendingPathComponent` codificar `?`.
    static func make(_ base: URL, _ path: String, query: [URLQueryItem] = []) throws -> URL {
        let joined = path.isEmpty ? base : base.appendingPathComponent(path)
        guard var components = URLComponents(url: joined, resolvingAgainstBaseURL: false) else {
            throw ChainReaderError.malformedResponse(field: "url")
        }
        if !query.isEmpty {
            components.queryItems = query
            // `+` e valido em query, mas a Horizon (e muito servidor) le como espaco.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw ChainReaderError.malformedResponse(field: "url") }
        return url
    }

    /// Corpo `application/x-www-form-urlencoded`: so letras, digitos e `-._~` passam
    /// crus. O base64 do envelope tem `+`, `/` e `=`, que precisam ir codificados.
    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
