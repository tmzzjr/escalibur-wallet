import EscaliburCore
import Foundation

/// Um token TRC-20 que a carteira conhece. O contrato e literal compilado: nunca vem de
/// resposta de rede, porque um contrato trocado e um "USDT" falso com saldo de verdade
/// na tela.
public struct TRC20Token: Sendable, Equatable {
    public let symbol: String
    public let name: String
    public let contract: TronAddress
    public let decimals: Int
}

/// A ABI das duas chamadas TRC-20 que a carteira faz: `transfer` e `balanceOf`.
///
/// A ABI e a do Solidity, igual a da EVM: seletor de 4 bytes e argumentos em palavras
/// de 32 bytes. O endereco entra com os 20 bytes da conta, **sem o 0x41**, completado
/// com zeros a esquerda.
///
/// Ha carteiras que poem o endereco de 21 bytes na palavra, com o 0x41 no byte alto (a
/// transacao 94bd6f1f... das fixtures). O USDT le so os 20 bytes baixos e aceitou, mas
/// um contrato com decodificacao ABI estrita (solc 0.8) reverte e a energy queima do
/// mesmo jeito. A carteira produz sempre a forma limpa e, ao conferir calldata, recusa
/// a suja: quem confere nao adivinha qual dos dois enderecos o contrato vai ler.
public enum TRC20 {
    /// keccak256("transfer(address,uint256)")[0..<4]. O teste recalcula.
    public static let transferSelector: [UInt8] = [0xA9, 0x05, 0x9C, 0xBB]
    /// keccak256("balanceOf(address)")[0..<4]. O teste recalcula.
    public static let balanceOfSelector: [UInt8] = [0x70, 0xA0, 0x82, 0x31]

    /// Tether USD na Tron: TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t, 6 casas.
    /// Fontes, conferidas em 25/09/2026: https://tether.to/en/supported-protocols/,
    /// `/wallet/getcontract` na mainnet (name "TetherToken"), docs/seguranca.md §4.8 e
    /// o `contract_address` das transferencias em Fixtures/tron/transacoes-mainnet.json.
    /// O teste confere o base58.
    public static let usdt = TRC20Token(
        symbol: "USDT",
        name: "Tether USD",
        contract: TronAddress(bytes: [
            0x41, 0xA6, 0x14, 0xF8, 0x03, 0xB6, 0xFD, 0x78, 0x09, 0x86, 0xA4,
            0x2C, 0x78, 0xEC, 0x9C, 0x7F, 0x77, 0xE6, 0xDE, 0xD1, 0x3C,
        ])!,
        decimals: 6
    )

    public enum Failure: Error, Equatable, Sendable {
        case amountTooLarge
    }

    /// A palavra de 32 bytes de um endereco: 12 zeros e os 20 bytes da conta.
    public static func addressWord(_ address: TronAddress) -> [UInt8] {
        [UInt8](repeating: 0, count: 12) + address.account20
    }

    /// `transfer(address,uint256)`: 68 bytes.
    public static func transferCalldata(to: TronAddress, amount: BigUInt) throws -> [UInt8] {
        guard let word = amount.bigEndianBytes(padTo: 32) else { throw Failure.amountTooLarge }
        return transferSelector + addressWord(to) + word
    }

    /// `balanceOf(address)`: 36 bytes, para `/wallet/triggerconstantcontract` com `data`.
    /// Com `function_selector: "balanceOf(address)"`, o `parameter` e so
    /// `addressWord(owner)` em hex.
    public static func balanceOfCalldata(owner: TronAddress) -> [UInt8] {
        balanceOfSelector + addressWord(owner)
    }

    /// Decodifica uma calldata de `transfer`, estrita: exatamente 68 bytes, seletor
    /// certo e os 12 bytes altos da palavra do endereco zerados. Serve para conferir o
    /// que se vai assinar, e o que uma transacao recebida diz ter feito.
    public static func decodeTransfer(_ data: [UInt8]) -> (to: TronAddress, amount: BigUInt)? {
        guard data.count == 68, Array(data.prefix(4)) == transferSelector else { return nil }
        let word = Array(data[4..<36])
        guard word.prefix(12).allSatisfy({ $0 == 0 }), let to = TronAddress(account20: Array(word.suffix(20))) else { return nil }
        return (to, BigUInt(bigEndian: data[36..<68]))
    }

    /// Le um uint256 devolvido por `triggerconstantcontract` (`constant_result[0]`),
    /// como o resultado de `balanceOf`. Exige exatamente 32 bytes.
    public static func decodeUint256(_ word: [UInt8]) -> BigUInt? {
        guard word.count == 32 else { return nil }
        return BigUInt(bigEndian: word)
    }
}
