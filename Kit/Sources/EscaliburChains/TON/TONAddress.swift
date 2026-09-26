import EscaliburCore
import Foundation

/// Endereco TON. Implementacao completa (celulas, BOC, contrato da carteira) em
/// andamento; ate la, a rede TON fica sem endereco derivado.
public enum TONAddress {
    public static func walletAddress(publicKey: [UInt8]) throws -> String {
        throw Address.Problem.unsupportedType
    }

    static func validate(_ text: String) -> Result<Address.Destination, Address.Problem> {
        .failure(.malformed)
    }
}
