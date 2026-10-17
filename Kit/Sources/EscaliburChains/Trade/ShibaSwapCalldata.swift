import EscaliburCore
import Foundation

// ShibaSwap, UniswapV2Router02.
//
// A calldata nasce aqui (`encode`) e volta pelo decodificador como a de qualquer provedor.
// So passam as tres formas que este arquivo monta, uma por lado da moeda nativa, todas na
// variante que mede o que chegou:
//
//   swapExactETHForTokensSupportingFeeOnTransferTokens(uint256 amountOutMin, address[] path,
//       address to, uint256 deadline)                                          (b6f9de95)
//   swapExactTokensForETHSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin,
//       address[] path, address to, uint256 deadline)                          (791ac947)
//   swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin,
//       address[] path, address to, uint256 deadline)                          (5c11d795)
//
// O que o router garante, lido do fonte verificado: `ensure(deadline)` recusa depois do
// prazo; para token, o aumento do saldo de `to` no ultimo token tem de ser pelo menos
// `amountOutMin`; para a moeda nativa, o WETH que sobrou no router e conferido contra
// `amountOutMin`, desembrulhado e mandado a `to`. A moeda nativa vendida vai como
// `msg.value`, e o caminho tem de comecar no WETH (o router confere, e aqui tambem).

public enum ShibaSwapCalldata {
    static let swapETHForTokens = try! ABIFunction(
        "swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[],address,uint256)")
    static let swapTokensForETH = try! ABIFunction(
        "swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)")
    static let swapTokensForTokens = try! ABIFunction(
        "swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)")

    static let functions = [swapETHForTokens, swapTokensForETH, swapTokensForTokens]
    static let maxHops = 2

    // MARK: Montagem

    public static func encode(
        path: [EVMAddress], intent: TradeIntent, minimumOut: BigUInt, deadline: UInt64
    ) throws -> (data: [UInt8], value: BigUInt) {
        let route = ABIValue.array(path.map { .address($0) })
        let to = ABIValue.address(intent.owner)
        let limit = ABIValue.uint(BigUInt(deadline))
        if intent.sell.isNative {
            return (try swapETHForTokens.encodeCall([.uint(minimumOut), route, to, limit]), intent.amountIn)
        }
        let function = intent.buy.isNative ? swapTokensForETH : swapTokensForTokens
        return (try function.encodeCall([.uint(intent.amountIn), .uint(minimumOut), route, to, limit]), BigUInt())
    }

    // MARK: Decodificacao

    static func decode(function: ABIFunction, arguments: [ABIValue], context: TradeDecodeContext) throws -> DecodedSwap {
        guard functions.contains(function) else { throw TradeRefusal.selectorNotAllowed(function.selector) }
        guard let deployment = ShibaSwapDeployment.all[context.router.chainID], deployment.router == context.router.address else {
            throw TradeRefusal.providerNotOnChain(.shibaswap)
        }
        let nativeIn = function == swapETHForTokens
        let fields = nativeIn ? arguments : Array(arguments.dropFirst())
        guard fields.count == 4 else { throw TradeRefusal.malformed("argumentos") }
        let amountIn = nativeIn ? context.value : try ABIRead.uint(arguments[0], "amountIn")
        let minOut = try ABIRead.uint(fields[0], "amountOutMin")
        let path = try ABIRead.array(fields[1], "path").map { try ABIRead.address($0, "path") }
        let to = try ABIRead.address(fields[2], "to")
        guard let deadline = try ABIRead.uint(fields[3], "deadline").uint64 else { throw TradeRefusal.malformed("deadline") }

        guard !amountIn.isZero else { throw TradeRefusal.malformed("amountIn") }
        guard (2...(maxHops + 1)).contains(path.count), Set(path).count == path.count, !path.contains(where: \.isZero) else {
            throw TradeRefusal.malformed("path")
        }
        for bridge in path.dropFirst().dropLast() where !deployment.bases.contains(bridge) {
            throw TradeRefusal.malformed("ponte " + bridge.checksummed)
        }
        let nativeOut = function == swapTokensForETH
        if nativeIn, path[0] != deployment.wrappedNative { throw TradeRefusal.malformed("path") }
        if nativeOut, path[path.count - 1] != deployment.wrappedNative { throw TradeRefusal.malformed("path") }
        guard to == context.intent.owner else { throw TradeRefusal.recipientMismatch(to) }
        guard !minOut.isZero else { throw TradeRefusal.zeroMinimumOut }

        return DecodedSwap(
            provider: .shibaswap, function: function.signature,
            sellToken: nativeIn ? .zero : path[0], buyToken: nativeOut ? .zero : path[path.count - 1], amountIn: amountIn,
            minOutField: minOut, guaranteedOut: minOut, recipient: to,
            integratorFee: .none, providerFeeAmount: 0, outputCap: nil, deadline: deadline
        )
    }
}
