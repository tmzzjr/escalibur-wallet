import EscaliburCore
import Foundation

// De¹ (ex-OpenOcean), OpenOceanExchange atras do proxy 0x6352...4e64.
//
// Fonte: a implementacao verificada de cada rede (Sourcify "OpenOceanExchange", solc
// 0.8.9, arquivo OpenOceanExchange.sol; Blockscout na Polygon). A implementacao fica
// fixada em TradeAllowlist e e conferida no slot EIP-1967 antes de assinar.
//
//   swap(address caller, SwapDescription desc, CallDescription[] calls)
//   simpleSwap(address caller, SimpleSwapDescription desc, CallDescription[] calls)
//   SwapDescription(srcToken, dstToken, srcReceiver, dstReceiver, amount,
//                   minReturnAmount, guaranteedAmount, flags, referrer, permit)
//   SimpleSwapDescription: a mesma sem `guaranteedAmount`.
//
// O que o router garante, lido do fonte: com SHOULD_CLAIM (0x02) puxa `amount` do dono
// para `srcReceiver`; exige msg.value == amount se vende nativo; chama
// `caller.makeCalls(calls)` e reverte se o saldo de `dstToken` do `dstReceiver` nao
// subir pelo menos `minReturnAmount`. PARTIAL_FILL (0x01) troca essa conferencia por
// uma proporcional e e recusado.
//
// A taxa de integrador da De¹ (`referrer`/`referrerFee`) e cobrada dentro das `calls`,
// que sao opacas: a carteira nao consegue conferir o valor. Por isso, com taxa ligada, a
// De¹ sai da disputa (TradeRefusal.integratorFeeNotVerifiable); hoje, sem taxa, exige
// `referrer` zero.

enum De1Calldata {
    static let callDescription = "(uint256,uint256,uint256,bytes)"
    static let swap = try! ABIFunction(
        "swap(address,(address,address,address,address,uint256,uint256,uint256,uint256,address,bytes),\(callDescription)[])"
    )  // 90411a32
    static let simpleSwap = try! ABIFunction(
        "simpleSwap(address,(address,address,address,address,uint256,uint256,uint256,address,bytes),\(callDescription)[])"
    )  // 0a9704d5

    static let functions = [swap, simpleSwap]

    static let partialFill: UInt64 = 0x01
    static let shouldClaim: UInt64 = 0x02

    static func decode(function: ABIFunction, arguments: [ABIValue], context: TradeDecodeContext) throws -> DecodedSwap {
        guard functions.contains(function), arguments.count == 3 else { throw TradeRefusal.selectorNotAllowed(function.selector) }
        guard context.fee.isNone else { throw TradeRefusal.integratorFeeNotVerifiable(.de1) }
        let simple = function == simpleSwap
        let caller = try ABIRead.address(arguments[0], "caller")
        let desc = try ABIRead.tuple(arguments[1], "desc", count: simple ? 9 : 10)
        let calls = try ABIRead.array(arguments[2], "calls")

        let srcToken = try ABIRead.address(desc[0], "srcToken")
        let dstToken = try ABIRead.address(desc[1], "dstToken")
        let srcReceiver = try ABIRead.address(desc[2], "srcReceiver")
        let dstReceiver = try ABIRead.address(desc[3], "dstReceiver")
        let amount = try ABIRead.uint(desc[4], "amount")
        let minReturn = try ABIRead.uint(desc[5], "minReturnAmount")
        let flags = try ABIRead.flags(desc[simple ? 6 : 7], "flags")
        let referrer = try ABIRead.address(desc[simple ? 7 : 8], "referrer")
        let permit = try ABIRead.bytes(desc[simple ? 8 : 9], "permit")

        guard permit.isEmpty else { throw TradeRefusal.malformed("permit") }
        guard referrer.isZero else { throw TradeRefusal.integratorFeeMismatch }
        guard !caller.isZero, caller != context.intent.owner, caller != context.router.address else {
            throw TradeRefusal.malformed("caller")
        }
        guard !calls.isEmpty else { throw TradeRefusal.malformed("calls") }
        guard dstReceiver == context.intent.owner else { throw TradeRefusal.recipientMismatch(dstReceiver) }
        guard !minReturn.isZero else { throw TradeRefusal.zeroMinimumOut }

        if srcToken == TradeConstants.eeeeSentinel {
            // Nativo: o contrato recusa SHOULD_CLAIM com ETH e manda o msg.value inteiro
            // ao caller.
            guard flags == 0 else { throw TradeRefusal.malformed("flags 0x" + String(flags, radix: 16)) }
        } else {
            // Token: tem de ser puxado (SHOULD_CLAIM) e entregue ao caller, que executa
            // as calls, ou direto ao primeiro contrato que as calls chamam (a API faz isso
            // com pool no estilo Uniswap V2, visto ao vivo na Arbitrum). Qualquer outro
            // recebedor mandaria o token a um terceiro que a rota nem toca.
            guard flags == shouldClaim else { throw TradeRefusal.malformed("flags 0x" + String(flags, radix: 16)) }
            let targets = try calls.map { call -> EVMAddress in
                let fields = try ABIRead.tuple(call, "call", count: 4)
                guard let word = try ABIRead.uint(fields[0], "target").bigEndianBytes(padTo: 32) else { throw TradeRefusal.malformed("target") }
                return EVMAddress(uncheckedBytes: Array(word.suffix(20)))
            }
            guard !srcReceiver.isZero, srcReceiver != context.intent.owner, srcReceiver != context.router.address,
                  srcReceiver == caller || targets.contains(srcReceiver)
            else { throw TradeRefusal.malformed("srcReceiver") }
        }

        return DecodedSwap(
            provider: .de1, function: function.signature,
            sellToken: srcToken, buyToken: dstToken, amountIn: amount,
            minOutField: minReturn, guaranteedOut: minReturn, recipient: dstReceiver,
            integratorFee: .none, providerFeeAmount: 0, outputCap: nil, deadline: nil
        )
    }
}
