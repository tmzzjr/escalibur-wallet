import EscaliburCore
import Foundation

// Uniswap, Universal Router 2.0.
//
// A calldata nasce aqui (`encode`), a partir da rota que a rede cotou nos contratos da
// Uniswap, e volta pelo decodificador como a de qualquer provedor. So passam as quatro
// formas que este arquivo monta, com o dono recebendo, pools sem hook e pontes da lista.
//
// Fonte: o codigo verificado do Universal Router 2.0 (Sourcify, Ethereum
// 0x66a9...a8af: contracts/base/Dispatcher.sol, libraries/Commands.sol e
// lib/v4-periphery/src: V4Router.sol, interfaces/IV4Router.sol, libraries/Actions.sol,
// CalldataDecoder.sol, PathKey.sol, ActionConstants.sol).
//
//   execute(bytes commands, bytes[] inputs, uint256 deadline)   (confere o prazo)
//   V3_SWAP_EXACT_IN 0x00: (address recipient, uint256 amountIn, uint256 amountOutMin,
//                           bytes path, bool payerIsUser)
//   WRAP_ETH 0x0b: (address recipient, uint256 amount)
//   UNWRAP_WETH 0x0c: (address recipient, uint256 amountMin)
//   V4_SWAP 0x10: (bytes actions, bytes[] params)
//     SWAP_EXACT_IN_SINGLE 0x06: ExactInputSingleParams(PoolKey poolKey, bool zeroForOne,
//                                uint128 amountIn, uint128 amountOutMinimum, bytes hookData)
//     SWAP_EXACT_IN 0x07: ExactInputParams(address currencyIn, PathKey[] path,
//                         uint128 amountIn, uint128 amountOutMinimum)
//     SETTLE_ALL 0x0c: (address currency, uint256 maxAmount)
//     TAKE_ALL 0x0f: (address currency, uint256 minAmount)
//   PoolKey(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)
//   PathKey(address intermediateCurrency, uint24 fee, int24 tickSpacing, address hooks, bytes hookData)
//   ADDRESS_THIS = address(2): o proprio router.
//
// O que o router garante, lido do fonte: a v3 confere `amountOutMin` no fim do caminho;
// `UNWRAP_WETH` confere `amountMin` antes de mandar a moeda nativa; na v4, a troca confere
// `amountOutMinimum`, `SETTLE_ALL` recusa pagar mais que `maxAmount` e `TAKE_ALL` recusa
// entregar menos que `minAmount`, sempre a `msgSender()`, que e quem assinou. O token
// vendido sai do dono pelo Permit2 (`payerIsUser`, ou o `SETTLE_ALL` da v4); a moeda
// nativa vai como `msg.value`.

public enum UniswapCalldata {
    static let execute = try! ABIFunction("execute(bytes,bytes[],uint256)")  // 3593564c
    static let functions = [execute]

    enum Command {
        static let v3SwapExactIn: UInt8 = 0x00
        static let wrapETH: UInt8 = 0x0b
        static let unwrapWETH: UInt8 = 0x0c
        static let v4Swap: UInt8 = 0x10
    }

    enum Action {
        static let swapExactInSingle: UInt8 = 0x06
        static let swapExactIn: UInt8 = 0x07
        static let settleAll: UInt8 = 0x0c
        static let takeAll: UInt8 = 0x0f
    }

    /// `ActionConstants.ADDRESS_THIS`: o proprio router guarda o valor entre dois comandos.
    static let addressThis = EVMAddress(uncheckedBytes: [UInt8](repeating: 0, count: 19) + [2])

    static let v3SwapTypes: [ABIType] = [.address, .uint(256), .uint(256), .bytes, .bool]
    static let pairTypes: [ABIType] = [.address, .uint(256)]
    static let v4SwapTypes: [ABIType] = [.bytes, .array(.bytes)]
    static let poolKeyComponents: [ABIType] = [.address, .address, .uint(24), .int(24), .address]
    static let poolKeyType = ABIType.tuple(poolKeyComponents)
    static let exactInSingleType = ABIType.tuple([poolKeyType, .bool, .uint(128), .uint(128), .bytes])
    static let pathKeyType = ABIType.tuple([.address, .uint(24), .int(24), .address, .bytes])
    static let exactInType = ABIType.tuple([.address, .array(pathKeyType), .uint(128), .uint(128)])

    /// No maximo duas etapas: e o que a busca monta.
    static let maxHops = 2

    // MARK: Pecas

    /// O PoolKey sem hook, com as moedas em ordem.
    static func poolKey(_ a: EVMAddress, _ b: EVMAddress, _ tier: UniswapV4Tier) -> ABIValue {
        let (currency0, currency1) = UniswapPool.sorted(a, b)
        return .tuple([.address(currency0), .address(currency1), .uint(BigUInt(tier.fee)), .int(ABISignedInteger(tier.tickSpacing)), .address(.zero)])
    }

    /// Na v4, `zeroForOne` e vender a moeda de endereco menor.
    static func zeroForOne(_ input: EVMAddress, _ output: EVMAddress) -> Bool {
        input.bytes.lexicographicallyPrecedes(output.bytes)
    }

    static func pathKeys(currencies: [EVMAddress], tiers: [UniswapV4Tier]) -> ABIValue {
        .array(tiers.indices.map { index in
            .tuple([.address(currencies[index + 1]), .uint(BigUInt(tiers[index].fee)), .int(ABISignedInteger(tiers[index].tickSpacing)),
                    .address(.zero), .bytes([])])
        })
    }

    /// O caminho da v3: token, taxa em 3 bytes, token, ...
    static func v3Path(tokens: [EVMAddress], fees: [UInt32]) -> [UInt8] {
        var out = tokens[0].bytes
        for (fee, token) in zip(fees, tokens.dropFirst()) {
            out += [UInt8(fee >> 16 & 0xff), UInt8(fee >> 8 & 0xff), UInt8(fee & 0xff)] + token.bytes
        }
        return out
    }

    static func parseV3Path(_ path: [UInt8]) throws -> (tokens: [EVMAddress], fees: [UInt32]) {
        guard path.count >= 43, (path.count - 20) % 23 == 0 else { throw TradeRefusal.malformed("path") }
        var tokens = [EVMAddress(uncheckedBytes: Array(path[0..<20]))]
        var fees = [UInt32]()
        var cursor = 20
        while cursor < path.count {
            fees.append(UInt32(path[cursor]) << 16 | UInt32(path[cursor + 1]) << 8 | UInt32(path[cursor + 2]))
            tokens.append(EVMAddress(uncheckedBytes: Array(path[cursor + 3..<cursor + 23])))
            cursor += 23
        }
        return (tokens, fees)
    }

    // MARK: Montagem

    /// A calldata de `execute` e o `msg.value`, para a rota cotada. O minimo e o do app,
    /// calculado da estimativa com a tolerancia do dono; o prazo, ate 20 minutos.
    public static func encode(
        route: UniswapRoute, intent: TradeIntent, minimumOut: BigUInt, deadline: UInt64, deployment: UniswapDeployment
    ) throws -> (data: [UInt8], value: BigUInt) {
        let owner = intent.owner
        let amount = intent.amountIn
        let value = intent.sell.isNative ? amount : BigUInt()
        var commands = [UInt8]()
        var inputs = [[UInt8]]()
        switch route {
        case .v3(let tokens, let fees):
            let path = v3Path(tokens: tokens, fees: fees)
            if intent.sell.isNative {
                commands.append(Command.wrapETH)
                inputs.append(try ABI.encode([.address(addressThis), .uint(amount)], types: pairTypes))
            }
            let recipient = intent.buy.isNative ? addressThis : owner
            commands.append(Command.v3SwapExactIn)
            inputs.append(try ABI.encode([.address(recipient), .uint(amount), .uint(minimumOut), .bytes(path), .bool(!intent.sell.isNative)],
                                         types: v3SwapTypes))
            if intent.buy.isNative {
                commands.append(Command.unwrapWETH)
                inputs.append(try ABI.encode([.address(owner), .uint(minimumOut)], types: pairTypes))
            }
        case .v4(let currencies, let tiers):
            guard let input = currencies.first, let output = currencies.last else { throw TradeRefusal.malformed("rota") }
            let swap: [UInt8]
            let action: UInt8
            if tiers.count == 1 {
                action = Action.swapExactInSingle
                swap = try ABI.encode([.tuple([poolKey(input, output, tiers[0]), .bool(zeroForOne(input, output)), .uint(amount), .uint(minimumOut), .bytes([])])],
                                      types: [exactInSingleType])
            } else {
                action = Action.swapExactIn
                swap = try ABI.encode([.tuple([.address(input), pathKeys(currencies: currencies, tiers: tiers), .uint(amount), .uint(minimumOut)])],
                                      types: [exactInType])
            }
            let settle = try ABI.encode([.address(input), .uint(amount)], types: pairTypes)
            let take = try ABI.encode([.address(output), .uint(minimumOut)], types: pairTypes)
            commands.append(Command.v4Swap)
            inputs.append(try ABI.encode([.bytes([action, Action.settleAll, Action.takeAll]), .array([.bytes(swap), .bytes(settle), .bytes(take)])],
                                         types: v4SwapTypes))
        }
        let data = try execute.encodeCall([.bytes(commands), .array(inputs.map { .bytes($0) }), .uint(BigUInt(deadline))])
        return (data, value)
    }

    // MARK: Decodificacao

    static func decode(function: ABIFunction, arguments: [ABIValue], context: TradeDecodeContext) throws -> DecodedSwap {
        guard function == execute, arguments.count == 3 else { throw TradeRefusal.selectorNotAllowed(function.selector) }
        let commands = try ABIRead.bytes(arguments[0], "commands")
        let inputs = try ABIRead.array(arguments[1], "inputs").map { try ABIRead.bytes($0, "inputs") }
        guard let deadline = try ABIRead.uint(arguments[2], "deadline").uint64 else { throw TradeRefusal.malformed("deadline") }
        guard commands.count == inputs.count else { throw TradeRefusal.malformed("commands") }
        guard let deployment = UniswapDeployment.all[context.router.chainID], deployment.router == context.router.address else {
            throw TradeRefusal.providerNotOnChain(.uniswap)
        }
        let owner = context.intent.owner

        let swap: (sell: EVMAddress, buy: EVMAddress, amountIn: BigUInt, guaranteed: BigUInt, minField: BigUInt)
        switch commands {
        case [Command.v3SwapExactIn]:
            // Token por token: o dono paga pelo Permit2 e recebe direto.
            let v3 = try decodeV3(inputs[0], deployment: deployment)
            guard v3.payerIsUser else { throw TradeRefusal.malformed("payerIsUser") }
            guard v3.recipient == owner else { throw TradeRefusal.recipientMismatch(v3.recipient) }
            swap = (v3.tokens[0], v3.tokens[v3.tokens.count - 1], v3.amountIn, v3.minOut, v3.minOut)
        case [Command.wrapETH, Command.v3SwapExactIn]:
            // Nativo por token: o router embrulha o `msg.value` e paga o pool com ele.
            let wrap = try decodePair(inputs[0], "WRAP_ETH")
            let v3 = try decodeV3(inputs[1], deployment: deployment)
            guard wrap.address == addressThis, wrap.amount == context.value, wrap.amount == v3.amountIn else {
                throw TradeRefusal.malformed("WRAP_ETH")
            }
            guard !v3.payerIsUser, v3.tokens[0] == deployment.wrappedNative else { throw TradeRefusal.malformed("payerIsUser") }
            guard v3.recipient == owner else { throw TradeRefusal.recipientMismatch(v3.recipient) }
            swap = (.zero, v3.tokens[v3.tokens.count - 1], v3.amountIn, v3.minOut, v3.minOut)
        case [Command.v3SwapExactIn, Command.unwrapWETH]:
            // Token por nativo: o embrulhado fica no router, que desembrulha para o dono
            // conferindo o minimo de novo.
            let v3 = try decodeV3(inputs[0], deployment: deployment)
            let unwrap = try decodePair(inputs[1], "UNWRAP_WETH")
            guard v3.payerIsUser, v3.recipient == addressThis, v3.tokens[v3.tokens.count - 1] == deployment.wrappedNative else {
                throw TradeRefusal.malformed("V3_SWAP_EXACT_IN")
            }
            guard unwrap.address == owner else { throw TradeRefusal.recipientMismatch(unwrap.address) }
            guard unwrap.amount == v3.minOut else { throw TradeRefusal.malformed("UNWRAP_WETH") }
            swap = (v3.tokens[0], .zero, v3.amountIn, unwrap.amount, v3.minOut)
        case [Command.v4Swap]:
            let v4 = try decodeV4(inputs[0], deployment: deployment)
            swap = (v4.input, v4.output, v4.amountIn, v4.minOut, v4.minOut)
        default:
            throw TradeRefusal.malformed("commands 0x" + Hex.encode(commands))
        }
        guard !swap.amountIn.isZero else { throw TradeRefusal.malformed("amountIn") }
        guard !swap.guaranteed.isZero else { throw TradeRefusal.zeroMinimumOut }

        return DecodedSwap(
            provider: .uniswap, function: function.signature,
            sellToken: swap.sell, buyToken: swap.buy, amountIn: swap.amountIn,
            minOutField: swap.minField, guaranteedOut: swap.guaranteed,
            // Na v3 o destino e o que esta escrito (conferido acima); na v4, o `TAKE_ALL`
            // paga a `msgSender()`, que e a conta que assina, e o plano assina com o dono.
            recipient: owner,
            integratorFee: .none, providerFeeAmount: 0, outputCap: nil, deadline: deadline
        )
    }

    static func decodePair(_ input: [UInt8], _ field: String) throws -> (address: EVMAddress, amount: BigUInt) {
        let values = try strict(pairTypes, input, field)
        return (try ABIRead.address(values[0], field), try ABIRead.uint(values[1], field))
    }

    static func decodeV3(_ input: [UInt8], deployment: UniswapDeployment) throws
        -> (recipient: EVMAddress, amountIn: BigUInt, minOut: BigUInt, tokens: [EVMAddress], payerIsUser: Bool) {
        let values = try strict(v3SwapTypes, input, "V3_SWAP_EXACT_IN")
        let recipient = try ABIRead.address(values[0], "recipient")
        let amountIn = try ABIRead.uint(values[1], "amountIn")
        let minOut = try ABIRead.uint(values[2], "amountOutMin")
        let (tokens, fees) = try parseV3Path(try ABIRead.bytes(values[3], "path"))
        let payerIsUser = try ABIRead.bool(values[4], "payerIsUser")
        guard fees.count <= maxHops, fees.allSatisfy(UniswapV3Fee.all.contains) else { throw TradeRefusal.malformed("path") }
        guard Set(tokens).count == tokens.count, !tokens.contains(where: \.isZero) else { throw TradeRefusal.malformed("path") }
        // A ponte de duas etapas so pode ser o embrulhado ou uma stablecoin da lista.
        for bridge in tokens.dropFirst().dropLast() where !deployment.v3Bases.contains(bridge) {
            throw TradeRefusal.malformed("ponte " + bridge.checksummed)
        }
        // Os valores especiais do router (saldo do contrato) nunca entram.
        guard amountIn < BigUInt(1).shiftedLeft(by: 255) else { throw TradeRefusal.malformed("amountIn") }
        return (recipient, amountIn, minOut, tokens, payerIsUser)
    }

    static func decodeV4(_ input: [UInt8], deployment: UniswapDeployment) throws
        -> (input: EVMAddress, output: EVMAddress, amountIn: BigUInt, minOut: BigUInt) {
        let values = try strict(v4SwapTypes, input, "V4_SWAP")
        let actions = try ABIRead.bytes(values[0], "actions")
        let params = try ABIRead.array(values[1], "params").map { try ABIRead.bytes($0, "params") }
        guard params.count == 3, actions.count == 3, actions[1] == Action.settleAll, actions[2] == Action.takeAll else {
            throw TradeRefusal.malformed("actions 0x" + Hex.encode(actions))
        }

        var currencies: [EVMAddress]
        let amountIn: BigUInt
        let minOut: BigUInt
        switch actions[0] {
        case Action.swapExactInSingle:
            let fields = try ABIRead.tuple(try strict([exactInSingleType], params[0], "SWAP_EXACT_IN_SINGLE").first, "params", count: 5)
            let key = try poolKeyFields(fields[0])
            let zeroForOne = try ABIRead.bool(fields[1], "zeroForOne")
            amountIn = try ABIRead.uint(fields[2], "amountIn")
            minOut = try ABIRead.uint(fields[3], "amountOutMinimum")
            guard try ABIRead.bytes(fields[4], "hookData").isEmpty else { throw TradeRefusal.malformed("hookData") }
            currencies = zeroForOne ? [key.currency0, key.currency1] : [key.currency1, key.currency0]
        case Action.swapExactIn:
            let fields = try ABIRead.tuple(try strict([exactInType], params[0], "SWAP_EXACT_IN").first, "params", count: 4)
            currencies = [try ABIRead.address(fields[0], "currencyIn")]
            let path = try ABIRead.array(fields[1], "path")
            guard path.count == maxHops else { throw TradeRefusal.malformed("path") }
            for item in path {
                let hop = try ABIRead.tuple(item, "path", count: 5)
                let next = try ABIRead.address(hop[0], "intermediateCurrency")
                let tier = try tierFields(fee: hop[1], tickSpacing: hop[2])
                guard try ABIRead.address(hop[3], "hooks").isZero else { throw TradeRefusal.malformed("hooks") }
                guard try ABIRead.bytes(hop[4], "hookData").isEmpty else { throw TradeRefusal.malformed("hookData") }
                guard UniswapV4Tier.all.contains(tier) else { throw TradeRefusal.malformed("fee") }
                currencies.append(next)
            }
            amountIn = try ABIRead.uint(fields[2], "amountIn")
            minOut = try ABIRead.uint(fields[3], "amountOutMinimum")
            for bridge in currencies.dropFirst().dropLast() where !deployment.v4Bases.contains(bridge) {
                throw TradeRefusal.malformed("ponte " + bridge.checksummed)
            }
        default:
            throw TradeRefusal.malformed("actions 0x" + Hex.encode(actions))
        }
        guard Set(currencies).count == currencies.count, let input = currencies.first, let output = currencies.last else {
            throw TradeRefusal.malformed("path")
        }

        // Paga no maximo o valor vendido, na moeda vendida; recebe no minimo o minimo, na
        // moeda comprada.
        let settle = try decodePair(params[1], "SETTLE_ALL")
        let take = try decodePair(params[2], "TAKE_ALL")
        guard settle.address == input, settle.amount == amountIn else { throw TradeRefusal.malformed("SETTLE_ALL") }
        guard take.address == output, take.amount == minOut else { throw TradeRefusal.malformed("TAKE_ALL") }
        return (input, output, amountIn, minOut)
    }

    static func poolKeyFields(_ value: ABIValue) throws -> (currency0: EVMAddress, currency1: EVMAddress) {
        let fields = try ABIRead.tuple(value, "poolKey", count: 5)
        let currency0 = try ABIRead.address(fields[0], "currency0")
        let currency1 = try ABIRead.address(fields[1], "currency1")
        let tier = try tierFields(fee: fields[2], tickSpacing: fields[3])
        guard currency0.bytes.lexicographicallyPrecedes(currency1.bytes) else { throw TradeRefusal.malformed("poolKey") }
        guard UniswapV4Tier.all.contains(tier) else { throw TradeRefusal.malformed("fee") }
        guard try ABIRead.address(fields[4], "hooks").isZero else { throw TradeRefusal.malformed("hooks") }
        return (currency0, currency1)
    }

    static func tierFields(fee: ABIValue, tickSpacing: ABIValue) throws -> UniswapV4Tier {
        guard let fee = try ABIRead.uint(fee, "fee").uint64, fee <= UInt64(UInt32.max),
              case .int(let spacing) = tickSpacing, !spacing.isNegative, let raw = spacing.magnitude.uint64, raw <= UInt64(Int32.max)
        else { throw TradeRefusal.malformed("fee") }
        return UniswapV4Tier(fee: UInt32(fee), tickSpacing: Int32(raw))
    }

    /// Decodificacao estrita: o mesmo que a montagem escreveria, sem sobra no fim.
    static func strict(_ types: [ABIType], _ data: [UInt8], _ field: String) throws -> [ABIValue] {
        let values: [ABIValue]
        do {
            values = try ABI.decode(types, from: data)
        } catch {
            throw TradeRefusal.malformed(field)
        }
        guard values.count == types.count else { throw TradeRefusal.malformed(field) }
        return values
    }
}
