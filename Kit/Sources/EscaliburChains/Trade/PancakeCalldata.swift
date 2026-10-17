import EscaliburCore
import Foundation

// PancakeSwap, SmartRouter.
//
// A calldata nasce aqui (`encode`) e volta pelo decodificador como a de qualquer provedor.
// So passam as formas que este arquivo monta: um `multicall` com prazo e uma troca dentro,
// e, quando sai a moeda nativa, o `unwrapWETH9` para o dono logo depois.
//
// Fonte: o codigo verificado do SmartRouter (Sourcify, BNB 0x13f4...8Dd4, "SmartRouter",
// match exato): contracts/base/MulticallExtended.sol, V3SwapRouter.sol, V2SwapRouter.sol,
// libraries/Constants.sol e v3-periphery PeripheryPayments.sol.
//
//   multicall(uint256 deadline, bytes[] data)            (confere o prazo)
//   exactInputSingle((address tokenIn, address tokenOut, uint24 fee, address recipient,
//                     uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96))
//   exactInput((bytes path, address recipient, uint256 amountIn, uint256 amountOutMinimum))
//   swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to)
//   unwrapWETH9(uint256 amountMinimum, address recipient)
//   ADDRESS_THIS = address(2); CONTRACT_BALANCE = 0 (amountIn 0 troca o saldo do router).
//
// O que o router garante, lido do fonte: a v3 confere `amountOutMinimum` no fim do caminho; a
// v2 confere o aumento de saldo do destinatario contra `amountOutMin` (vale para token com
// taxa na transferencia); `unwrapWETH9` confere `amountMinimum` antes de mandar a moeda
// nativa. A moeda nativa vendida vai como `msg.value`, e o router embrulha so o que paga.

public enum PancakeCalldata {
    static let multicall = try! ABIFunction("multicall(uint256,bytes[])")  // 5ae401dc
    static let exactInputSingle = try! ABIFunction("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))")  // 04e45aaf
    static let exactInput = try! ABIFunction("exactInput((bytes,address,uint256,uint256))")  // b858183f
    static let swapV2 = try! ABIFunction("swapExactTokensForTokens(uint256,uint256,address[],address)")  // 472b43f3
    static let unwrapWETH9 = try! ABIFunction("unwrapWETH9(uint256,address)")  // 49404b7c

    static let functions = [multicall]
    static let maxHops = 2

    // MARK: Montagem

    public static func encode(
        route: PancakeRoute, intent: TradeIntent, minimumOut: BigUInt, deadline: UInt64, deployment: PancakeDeployment
    ) throws -> (data: [UInt8], value: BigUInt) {
        let owner = intent.owner
        let amount = intent.amountIn
        let recipient = intent.buy.isNative ? UniswapCalldata.addressThis : owner
        let swap: [UInt8]
        switch route {
        case .v3(let tokens, let fees) where fees.count == 1:
            swap = try exactInputSingle.encodeCall([.tuple([
                .address(tokens[0]), .address(tokens[1]), .uint(BigUInt(fees[0])), .address(recipient), .uint(amount), .uint(minimumOut), .uint(0),
            ])])
        case .v3(let tokens, let fees):
            swap = try exactInput.encodeCall([.tuple([
                .bytes(UniswapCalldata.v3Path(tokens: tokens, fees: fees)), .address(recipient), .uint(amount), .uint(minimumOut),
            ])])
        case .v2(let tokens):
            swap = try swapV2.encodeCall([.uint(amount), .uint(minimumOut), .array(tokens.map { .address($0) }), .address(recipient)])
        }
        var calls = [swap]
        if intent.buy.isNative { calls.append(try unwrapWETH9.encodeCall([.uint(minimumOut), .address(owner)])) }
        let data = try multicall.encodeCall([.uint(BigUInt(deadline)), .array(calls.map { .bytes($0) })])
        return (data, intent.sell.isNative ? amount : BigUInt())
    }

    // MARK: Decodificacao

    static func decode(function: ABIFunction, arguments: [ABIValue], context: TradeDecodeContext) throws -> DecodedSwap {
        guard function == multicall, arguments.count == 2 else { throw TradeRefusal.selectorNotAllowed(function.selector) }
        guard let deadline = try ABIRead.uint(arguments[0], "deadline").uint64 else { throw TradeRefusal.malformed("deadline") }
        let calls = try ABIRead.array(arguments[1], "data").map { try ABIRead.bytes($0, "data") }
        guard let deployment = PancakeDeployment.all[context.router.chainID], deployment.router == context.router.address else {
            throw TradeRefusal.providerNotOnChain(.pancakeswap)
        }
        guard calls.count == 1 || calls.count == 2 else { throw TradeRefusal.malformed("multicall") }
        let owner = context.intent.owner

        let swap = try decodeSwap(calls[0], deployment: deployment)
        guard !swap.amountIn.isZero else { throw TradeRefusal.malformed("amountIn") }
        let nativeIn = !context.value.isZero
        if nativeIn, swap.tokens[0] != deployment.wrappedNative { throw TradeRefusal.malformed("tokenIn") }

        let buyToken: EVMAddress
        let guaranteed: BigUInt
        if calls.count == 2 {
            // Moeda nativa para o dono: a troca deixa o embrulhado no router, que desembrulha
            // e manda, conferindo o minimo de novo.
            let unwrap = try strictCall(unwrapWETH9, calls[1], "unwrapWETH9")
            let minimum = try ABIRead.uint(unwrap[0], "amountMinimum")
            let to = try ABIRead.address(unwrap[1], "recipient")
            guard swap.recipient == UniswapCalldata.addressThis, swap.tokens.last == deployment.wrappedNative else {
                throw TradeRefusal.malformed("unwrapWETH9")
            }
            guard to == owner else { throw TradeRefusal.recipientMismatch(to) }
            guard minimum == swap.minOut else { throw TradeRefusal.malformed("amountMinimum") }
            buyToken = .zero
            guaranteed = minimum
        } else {
            guard swap.recipient == owner else { throw TradeRefusal.recipientMismatch(swap.recipient) }
            buyToken = swap.tokens[swap.tokens.count - 1]
            guaranteed = swap.minOut
        }
        guard !guaranteed.isZero else { throw TradeRefusal.zeroMinimumOut }

        return DecodedSwap(
            provider: .pancakeswap, function: function.signature,
            sellToken: nativeIn ? .zero : swap.tokens[0], buyToken: buyToken, amountIn: swap.amountIn,
            minOutField: swap.minOut, guaranteedOut: guaranteed, recipient: owner,
            integratorFee: .none, providerFeeAmount: 0, outputCap: nil, deadline: deadline
        )
    }

    struct Swap {
        let tokens: [EVMAddress]
        let recipient: EVMAddress
        let amountIn: BigUInt
        let minOut: BigUInt
    }

    static func decodeSwap(_ call: [UInt8], deployment: PancakeDeployment) throws -> Swap {
        guard call.count >= 4 else { throw TradeRefusal.malformed("data") }
        let selector = Array(call.prefix(4))
        let swap: Swap
        switch selector {
        case exactInputSingle.selector:
            let fields = try ABIRead.tuple(try strictCall(exactInputSingle, call, "exactInputSingle").first, "params", count: 7)
            guard let fee = try ABIRead.uint(fields[2], "fee").uint64, PancakeV3Fee.all.contains(UInt32(fee)) else { throw TradeRefusal.malformed("fee") }
            guard try ABIRead.uint(fields[6], "sqrtPriceLimitX96").isZero else { throw TradeRefusal.malformed("sqrtPriceLimitX96") }
            swap = Swap(tokens: [try ABIRead.address(fields[0], "tokenIn"), try ABIRead.address(fields[1], "tokenOut")],
                        recipient: try ABIRead.address(fields[3], "recipient"),
                        amountIn: try ABIRead.uint(fields[4], "amountIn"), minOut: try ABIRead.uint(fields[5], "amountOutMinimum"))
        case exactInput.selector:
            let fields = try ABIRead.tuple(try strictCall(exactInput, call, "exactInput").first, "params", count: 4)
            let (tokens, fees) = try UniswapCalldata.parseV3Path(try ABIRead.bytes(fields[0], "path"))
            guard fees.count <= maxHops, fees.allSatisfy(PancakeV3Fee.all.contains) else { throw TradeRefusal.malformed("path") }
            swap = Swap(tokens: tokens, recipient: try ABIRead.address(fields[1], "recipient"),
                        amountIn: try ABIRead.uint(fields[2], "amountIn"), minOut: try ABIRead.uint(fields[3], "amountOutMinimum"))
        case swapV2.selector:
            guard deployment.v2Factory != nil else { throw TradeRefusal.malformed("v2") }
            let values = try strictCall(swapV2, call, "swapExactTokensForTokens")
            let tokens = try ABIRead.array(values[2], "path").map { try ABIRead.address($0, "path") }
            guard (2...(maxHops + 1)).contains(tokens.count) else { throw TradeRefusal.malformed("path") }
            swap = Swap(tokens: tokens, recipient: try ABIRead.address(values[3], "to"),
                        amountIn: try ABIRead.uint(values[0], "amountIn"), minOut: try ABIRead.uint(values[1], "amountOutMin"))
        default:
            throw TradeRefusal.malformed("troca 0x" + Hex.encode(selector))
        }
        guard Set(swap.tokens).count == swap.tokens.count, !swap.tokens.contains(where: \.isZero) else { throw TradeRefusal.malformed("path") }
        for bridge in swap.tokens.dropFirst().dropLast() where !deployment.bases.contains(bridge) {
            throw TradeRefusal.malformed("ponte " + bridge.checksummed)
        }
        return swap
    }

    /// A chamada interna, decodificada sem sobra.
    static func strictCall(_ function: ABIFunction, _ call: [UInt8], _ field: String) throws -> [ABIValue] {
        do {
            return try function.decodeCall(call)
        } catch {
            throw TradeRefusal.malformed(field)
        }
    }
}
