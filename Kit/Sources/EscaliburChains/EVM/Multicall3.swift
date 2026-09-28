import EscaliburCore
import Foundation

/// Multicall3: varias leituras num `eth_call` so.
///
/// Serve para o saldo da tela: com a lista curada crescendo, um `eth_call` de
/// `balanceOf` por token e por rede estouraria o limite de taxa dos RPCs gratuitos a
/// cada atualizacao. Com o Multicall3, a leitura de todos os tokens de uma rede sai em
/// uma chamada (ate `maxCallsPerBatch` por lote).
///
/// So leitura: `aggregate3` com `allowFailure` ligado em cada chamada, e nenhum valor
/// enviado. Nada que decide dinheiro passa por aqui; o saldo que entra num plano de
/// envio continua vindo de `balanceOf` direto, em dois provedores concordando.
///
/// Contrato: `0xcA11bde05977b3631167028862bE2a173976CA11`, o mesmo em todas as redes
/// (implantacao deterministica, github.com/mds1/multicall3). Conferido em 27/09/2026 com
/// `eth_getCode` em dois RPCs de cada rede de `deployedChainIDs`: 3.808 bytes, o mesmo
/// codigo executavel em todas; na Linea so os 32 bytes do hash de metadados do solc
/// (o trailer CBOR, que nao executa) sao outros. O teste ao vivo refaz a conferencia.
public enum Multicall3 {
    public static let address = EVMAddress(uncheckedBytes: [UInt8](hex: "ca11bde05977b3631167028862be2a173976ca11")!)

    /// Redes (chainId) onde o contrato foi conferido. Rede EVM fora daqui le token por
    /// token.
    public static let deployedChainIDs: Set<UInt64> = [
        1, 8453, 42161, 10, 137, 56, 43114, 9745, 196, 59144, 130, 146, 42220,
    ]

    /// Teto de chamadas por `eth_call`. Cem `balanceOf` gastam bem menos de 2 milhoes de
    /// gas, longe do teto de `eth_call` dos RPCs publicos, e a resposta fica em ~16 KB.
    public static let maxCallsPerBatch = 100

    static let aggregate3Function = try! ABIFunction("aggregate3((address,bool,bytes)[])")  // 82ad56cb
    static let resultTypes: [ABIType] = [.array(.tuple([.bool, .bytes]))]

    public static func isDeployed(on chain: Chain) -> Bool {
        chain.family == .evm && chain.evmChainID.map(deployedChainIDs.contains) == true
    }

    /// Uma chamada do lote: contrato e calldata.
    public struct Call: Sendable, Hashable {
        public let target: EVMAddress
        public let data: [UInt8]

        public init(target: EVMAddress, data: [UInt8]) {
            self.target = target
            self.data = data
        }
    }

    /// Calldata de `aggregate3(calls)`, com `allowFailure` em todas: um token que
    /// reverte nao derruba a leitura dos outros.
    public static func aggregate3(_ calls: [Call]) throws -> [UInt8] {
        try aggregate3Function.encodeCall([
            .array(calls.map { .tuple([.address($0.target), .bool(true), .bytes($0.data)]) }),
        ])
    }

    /// O retorno de `aggregate3`, na ordem das chamadas: os bytes devolvidos por cada
    /// uma, ou `nil` para a que falhou. Decodificacao estrita; resposta com numero de
    /// resultados diferente do de chamadas e recusada inteira.
    public static func decodeAggregate3(_ returnData: [UInt8], expected count: Int) throws -> [[UInt8]?] {
        guard case .array(let items)? = try ABI.decode(resultTypes, from: returnData).first, items.count == count else {
            throw ABIError.wrongLength(type: "(bool,bytes)[]")
        }
        return try items.map { item in
            guard case .tuple(let fields) = item, fields.count == 2, case .bool(let success) = fields[0], case .bytes(let data) = fields[1] else {
                throw ABIError.typeMismatch(expected: "(bool,bytes)")
            }
            return success ? data : nil
        }
    }

    /// `balanceOf(dono)` de cada token, em lotes de ate `maxCallsPerBatch`.
    public static func balanceBatches(owner: EVMAddress, tokens: [EVMAddress]) -> [[Call]] {
        let calls = tokens.map { Call(target: $0, data: ERC20.balanceOf(owner: owner)) }
        return stride(from: 0, to: calls.count, by: maxCallsPerBatch).map { Array(calls[$0..<min($0 + maxCallsPerBatch, calls.count)]) }
    }

    /// Os saldos de um lote: `uint256` exato de cada chamada que deu certo, ou `nil`
    /// (reverteu, ou devolveu outra coisa que nao 32 bytes).
    public static func decodeBalances(_ returnData: [UInt8], expected count: Int) throws -> [BigUInt?] {
        try decodeAggregate3(returnData, expected: count).map { data in
            guard let data, data.count == 32 else { return nil }
            return try? ERC20.decodeUInt256(data)
        }
    }
}
