import Foundation

/// O endereco de um QR ou de um link de pagamento (BIP-21, EIP-681, "xrpl:",
/// "solana:"), e nada mais: valor, memo e rotulo do link sao ignorados, o dono digita.
///
/// O EIP-681 passa pela leitura estrita do `EIP681Request`: num pedido de token, o
/// endereco logo depois de "ethereum:" e o contrato, e quem recebe vem em `address=`.
/// Cortar o texto no "/" mandava o token para o proprio contrato (auditoria 2, B5).
public enum PaymentLink {
    public struct Reading: Equatable, Sendable {
        public let address: String
        /// A rede que o link pede, quando ele diz (EIP-681 com `@chain_id`).
        public let chainID: String?
    }

    public enum Problem: Error, Equatable, Sendable {
        case tooLong
        /// Pedido `ethereum:` que a leitura estrita recusou (ENS, funcao desconhecida,
        /// rede fora da lista, parametro repetido).
        case invalidEthereumRequest(EIP681Request.Problem)
    }

    public static let maxLength = 512

    public static func read(_ text: String) throws -> Reading {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maxLength else { throw Problem.tooLong }
        if trimmed.lowercased().hasPrefix("ethereum:") {
            let request: EIP681Request
            do { request = try EIP681Request.parse(trimmed) } catch let problem as EIP681Request.Problem {
                throw Problem.invalidEthereumRequest(problem)
            }
            switch request.payment {
            case .native(let recipient, _), .token(_, let recipient, _):
                return Reading(address: recipient.description, chainID: request.chain?.id)
            }
        }
        var body = Substring(trimmed)
        if let colon = body.firstIndex(of: ":"), body[..<colon].allSatisfy({ $0.isLetter }) {
            body = body[body.index(after: colon)...]
        }
        if body.hasPrefix("pay-") { body = body.dropFirst(4) }
        return Reading(address: String(body.prefix { $0 != "?" && $0 != "@" && $0 != "/" }), chainID: nil)
    }
}
