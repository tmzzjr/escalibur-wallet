import EscaliburCore
import Foundation

/// ERC-20: a calldata das chamadas que a carteira faz e a leitura das respostas.
///
/// As funcoes de leitura (`balanceOf`, `allowance`, `decimals`) viram `eth_call` na
/// camada de rede; a resposta volta para ca e e decodificada com o mesmo rigor da
/// calldata, porque um provedor que devolve lixo no preenchimento esta com defeito ou
/// mentindo, e nos dois casos o numero nao deve ir para a tela.
public enum ERC20 {
    // Assinaturas conferidas contra o texto da EIP-20. Os seletores sao os 4 primeiros
    // bytes do keccak de cada uma, e os testes conferem contra os valores conhecidos.
    public static let transferFunction = try! ABIFunction("transfer(address,uint256)")        // a9059cbb
    public static let approveFunction = try! ABIFunction("approve(address,uint256)")          // 095ea7b3
    public static let balanceOfFunction = try! ABIFunction("balanceOf(address)")              // 70a08231
    public static let allowanceFunction = try! ABIFunction("allowance(address,address)")      // dd62ed3e
    public static let decimalsFunction = try! ABIFunction("decimals()")                       // 313ce567

    // MARK: Calldata

    public static func transfer(to recipient: EVMAddress, amount: BigUInt) -> [UInt8] {
        // Nao lanca: os dois tipos sao fixos e os valores sempre cabem.
        (try? transferFunction.encodeCall([.address(recipient), .uint(amount)])) ?? []
    }

    /// Aprovacao de valor exato. A carteira nunca oferece infinito como padrao
    /// (docs/seguranca.md 4.4).
    public static func approve(spender: EVMAddress, amount: BigUInt) -> [UInt8] {
        (try? approveFunction.encodeCall([.address(spender), .uint(amount)])) ?? []
    }

    public static func balanceOf(owner: EVMAddress) -> [UInt8] {
        (try? balanceOfFunction.encodeCall([.address(owner)])) ?? []
    }

    public static func allowance(owner: EVMAddress, spender: EVMAddress) -> [UInt8] {
        (try? allowanceFunction.encodeCall([.address(owner), .address(spender)])) ?? []
    }

    public static func decimals() -> [UInt8] {
        decimalsFunction.selector
    }

    // MARK: Respostas

    /// Resposta de `balanceOf` ou `allowance`: um `uint256`, exatamente 32 bytes.
    public static func decodeUInt256(_ returnData: [UInt8]) throws -> BigUInt {
        guard case .uint(let value)? = try ABI.decode([.uint256], from: returnData).first else {
            throw ABIError.typeMismatch(expected: "uint256")
        }
        return value
    }

    /// Resposta de `decimals`: `uint8`. Tokens antigos declaram `uint256` (o MKR, por
    /// exemplo), e a codificacao e a mesma enquanto o valor cabe em 8 bits; acima
    /// disso, recusa.
    public static func decodeDecimals(_ returnData: [UInt8]) throws -> UInt8 {
        guard case .uint(let value)? = try ABI.decode([.uint(8)], from: returnData).first,
              let small = value.uint64, small <= 255
        else { throw ABIError.outOfRange(type: "uint8") }
        return UInt8(small)
    }
}

/// Um token ERC-20 numa rede. Vem da lista curada por (rede, contrato); a carteira
/// nao aceita token definido por resposta de provedor.
public struct EVMToken: Sendable, Hashable {
    public let chain: Chain
    public let contract: EVMAddress
    public let symbol: String
    public let decimals: UInt8

    public init(chain: Chain, contract: EVMAddress, symbol: String, decimals: UInt8) {
        self.chain = chain
        self.contract = contract
        self.symbol = symbol
        self.decimals = decimals
    }
}
