import EscaliburCore
import Foundation

// O que uma calldata de troca faz, depois de decodificada.
//
// Cada provedor tem o seu decodificador (VeloraCalldata, KyberCalldata, LiFiCalldata,
// De1Calldata), escrito a partir do fonte verificado do router. Todos devolvem o mesmo
// resumo, e e o resumo que a validacao confere contra a intencao e que a tela mostra.
// A regra e a de docs/seguranca.md 4.3: **sem decodificador, sem assinatura.**

/// O resumo de uma calldata de troca.
public struct DecodedSwap: Sendable, Equatable {
    public let provider: TradeProvider
    /// A assinatura canonica da funcao chamada.
    public let function: String
    /// Os tokens como o router os escreve (com a sentinela do provedor para o nativo).
    public let sellToken: EVMAddress
    public let buyToken: EVMAddress
    public let amountIn: BigUInt
    /// O `minOut` como esta escrito na calldata.
    public let minOutField: BigUInt
    /// O minimo que chega ao destinatario, pelo codigo do router: o `minOut` menos o que
    /// o router ainda tira depois de conferir (a poeira de 1 wei da Augustus, a taxa de
    /// parceiro cobrada depois da conferencia). E este numero que ranqueia e que a tela
    /// chama de "no minimo".
    public let guaranteedOut: BigUInt
    public let recipient: EVMAddress
    /// A taxa de integrador que a calldata paga. Tem de ser a compilada.
    public let integratorFee: TradeFeeTerms
    /// A taxa do proprio provedor escrita na calldata, em unidades do token vendido
    /// (LI.FI: o `forwardERC20Fees`/`forwardNativeFees` do FeeForwarder).
    public let providerFeeAmount: BigUInt
    /// O maximo que o router entrega, se ele corta a sobra (Velora sem parceiro: a
    /// sobra acima de `quotedAmount` fica com a Velora).
    public let outputCap: BigUInt?
    /// Prazo na calldata, em segundos Unix, quando o router tem um.
    public let deadline: UInt64?
}

/// O que o decodificador precisa saber da intencao.
struct TradeDecodeContext: Sendable {
    let intent: TradeIntent
    let router: TradeRouter
    let fee: TradeFeeTerms
    let value: BigUInt
}

/// Leitura dos valores ABI com erro explicito. Um valor com a forma errada ja teria
/// sido recusado pelo decodificador estrito; isto so evita `!` no caminho da assinatura.
enum ABIRead {
    static func address(_ value: ABIValue?, _ field: String) throws -> EVMAddress {
        guard let address = value?.addressValue else { throw TradeRefusal.malformed(field) }
        return address
    }

    static func uint(_ value: ABIValue?, _ field: String) throws -> BigUInt {
        guard let number = value?.uintValue else { throw TradeRefusal.malformed(field) }
        return number
    }

    static func bytes(_ value: ABIValue?, _ field: String) throws -> [UInt8] {
        guard let raw = value?.bytesValue else { throw TradeRefusal.malformed(field) }
        return raw
    }

    static func bool(_ value: ABIValue?, _ field: String) throws -> Bool {
        guard let flag = value?.boolValue else { throw TradeRefusal.malformed(field) }
        return flag
    }

    static func tuple(_ value: ABIValue?, _ field: String, count: Int) throws -> [ABIValue] {
        guard let items = value?.tupleValue, items.count == count else { throw TradeRefusal.malformed(field) }
        return items
    }

    static func array(_ value: ABIValue?, _ field: String) throws -> [ABIValue] {
        guard let items = value?.arrayValue else { throw TradeRefusal.malformed(field) }
        return items
    }

    /// Flags pequenas (Kyber, De¹): cabem em 64 bits, ou a calldata tem bit que ninguem
    /// definiu.
    static func flags(_ value: ABIValue?, _ field: String) throws -> UInt64 {
        guard let small = try uint(value, field).uint64 else { throw TradeRefusal.malformed(field) }
        return small
    }
}

extension TradeRouter {
    /// A funcao aceita para este seletor.
    func function(for selector: [UInt8]) -> ABIFunction? {
        functions.first { $0.selector == selector }
    }

    /// O decodificador do provedor, para a guarda de chamada.
    func decode(function: ABIFunction, arguments: [ABIValue], context: TradeDecodeContext) throws -> DecodedSwap {
        switch provider {
        case .velora: return try VeloraCalldata.decode(function: function, arguments: arguments, context: context)
        case .kyberSwap: return try KyberCalldata.decode(function: function, arguments: arguments, context: context)
        case .lifi: return try LiFiCalldata.decode(function: function, arguments: arguments, context: context)
        case .de1: return try De1Calldata.decode(function: function, arguments: arguments, context: context)
        }
    }

    /// Como este provedor escreve a moeda nativa.
    var nativeSentinel: EVMAddress {
        provider == .lifi ? .zero : TradeConstants.eeeeSentinel
    }
}
