import EscaliburCore
import Foundation

// LI.FI, GenericSwapFacetV3 no LiFiDiamond. So trocas na mesma rede; pontes ficam fora
// da v1 (docs/seguranca.md 4.3).
//
// Fonte: github.com/lifinance/contracts, src/Facets/GenericSwapFacetV3.sol e
// src/Periphery/FeeForwarder.sol (2.0.0), com a faceta verificada no Sourcify nas 7 redes.
//
//   swapTokens{Single,Multiple}V3{ERC20ToERC20,ERC20ToNative,NativeToERC20}(
//       bytes32 transactionId, string integrator, string referrer,
//       address receiver, uint256 minAmountOut, SwapData swapData | SwapData[] swapData)
//   SwapData(callTo, approveTo, sendingAssetId, receivingAssetId, fromAmount, callData,
//            requiresDeposit)
//
// O que o diamond garante, lido do fonte: puxa do dono `fromAmount` de cada passo com
// `requiresDeposit` (Single: o unico passo), executa cada `callTo` que esteja na lista
// do proprio diamond, e reverte se o saldo final do ativo recebido ficar abaixo de
// `minAmountOut`; depois transfere tudo ao `receiver`.
//
// O `swapTokensGeneric` da faceta antiga nao esta mais roteado no diamond (conferido
// com `facetAddress` em 25/09/2026) e e recusado.
//
// A taxa da LI.FI (0,25% fixos, "LIFI Fixed Fee") vem como o primeiro passo: uma chamada
// ao FeeForwarder (`forwardERC20Fees(token, [(recebedor, valor)])` ou
// `forwardNativeFees([(recebedor, valor)])`). A carteira decodifica esse passo, soma o
// que ele paga e recusa acima do teto compilado.

enum LiFiCalldata {
    static let swapData = "(address,address,address,address,uint256,bytes,bool)"
    static let head = "bytes32,string,string,address,uint256,"

    static let singleERC20ToERC20 = try! ABIFunction("swapTokensSingleV3ERC20ToERC20(\(head)\(swapData))")      // 4666fc80
    static let singleERC20ToNative = try! ABIFunction("swapTokensSingleV3ERC20ToNative(\(head)\(swapData))")    // 733214a3
    static let singleNativeToERC20 = try! ABIFunction("swapTokensSingleV3NativeToERC20(\(head)\(swapData))")    // af7060fd
    static let multipleERC20ToERC20 = try! ABIFunction("swapTokensMultipleV3ERC20ToERC20(\(head)\(swapData)[])")   // 5fd9ae2e
    static let multipleERC20ToNative = try! ABIFunction("swapTokensMultipleV3ERC20ToNative(\(head)\(swapData)[])") // 2c57e884
    static let multipleNativeToERC20 = try! ABIFunction("swapTokensMultipleV3NativeToERC20(\(head)\(swapData)[])") // 736eac0b

    static let functions = [
        singleERC20ToERC20, singleERC20ToNative, singleNativeToERC20,
        multipleERC20ToERC20, multipleERC20ToNative, multipleNativeToERC20,
    ]

    static let forwardERC20Fees = try! ABIFunction("forwardERC20Fees(address,(address,uint256)[])")  // 332d746b
    static let forwardNativeFees = try! ABIFunction("forwardNativeFees((address,uint256)[])")        // 0e8ae67f

    /// Passos demais sao rota que ninguem consegue revisar; as rotas reais tem 2 ou 3.
    static let maxSteps = 8

    struct Step {
        let callTo: EVMAddress
        let approveTo: EVMAddress
        let sendingAsset: EVMAddress
        let receivingAsset: EVMAddress
        let fromAmount: BigUInt
        let callData: [UInt8]
        let requiresDeposit: Bool
    }

    static func step(_ value: ABIValue) throws -> Step {
        let fields = try ABIRead.tuple(value, "swapData", count: 7)
        return Step(
            callTo: try ABIRead.address(fields[0], "callTo"),
            approveTo: try ABIRead.address(fields[1], "approveTo"),
            sendingAsset: try ABIRead.address(fields[2], "sendingAssetId"),
            receivingAsset: try ABIRead.address(fields[3], "receivingAssetId"),
            fromAmount: try ABIRead.uint(fields[4], "fromAmount"),
            callData: try ABIRead.bytes(fields[5], "callData"),
            requiresDeposit: try ABIRead.bool(fields[6], "requiresDeposit")
        )
    }

    static func decode(function: ABIFunction, arguments: [ABIValue], context: TradeDecodeContext) throws -> DecodedSwap {
        guard arguments.count == 6 else { throw TradeRefusal.malformed("argumentos") }
        let intent = context.intent
        let single = [singleERC20ToERC20, singleERC20ToNative, singleNativeToERC20].contains(function)
        let sellsNative = function == singleNativeToERC20 || function == multipleNativeToERC20
        let buysNative = function == singleERC20ToNative || function == multipleERC20ToNative
        guard functions.contains(function) else { throw TradeRefusal.selectorNotAllowed(function.selector) }
        // A variante tem de ser a da intencao: vender nativo pela funcao de ERC-20 faria
        // o diamond tentar puxar um token que nao existe, e o contrario deixaria o
        // msg.value no diamond.
        guard sellsNative == intent.sell.isNative else { throw TradeRefusal.sellTokenMismatch }
        guard buysNative == intent.buy.isNative else { throw TradeRefusal.buyTokenMismatch }

        let receiver = try ABIRead.address(arguments[3], "receiver")
        let minAmountOut = try ABIRead.uint(arguments[4], "minAmountOut")
        let steps = single ? [try step(arguments[5])] : try ABIRead.array(arguments[5], "swapData").map(step)
        guard receiver == intent.owner else { throw TradeRefusal.recipientMismatch(receiver) }
        guard !minAmountOut.isZero else { throw TradeRefusal.zeroMinimumOut }
        guard !steps.isEmpty, steps.count <= maxSteps, let first = steps.first, let last = steps.last else {
            throw TradeRefusal.malformed("swapData")
        }

        let native = EVMAddress.zero
        let sellAsset = intent.sell.contract ?? native
        let feeForwarder = context.router.feeForwarder
        var providerFee = BigUInt()
        var integratorPaid = BigUInt()
        var deposited = BigUInt()

        for (index, step) in steps.enumerated() {
            guard !step.callTo.isZero, step.callTo != intent.owner, step.callTo != context.router.address,
                  step.callData.count >= 4
            else { throw TradeRefusal.malformed("callTo") }
            // O diamond puxa `fromAmount` de `sendingAssetId` do dono em todo passo com
            // deposito. So o token vendido pode ser puxado: um deposito de outro token
            // gastaria uma aprovacao antiga que o dono esqueceu.
            if step.requiresDeposit, !step.sendingAsset.isZero {
                guard step.sendingAsset == sellAsset else { throw TradeRefusal.malformed("deposito de outro token") }
                deposited = deposited + step.fromAmount
            }
            if step.callTo == feeForwarder {
                // So o primeiro passo pode ser a taxa, e so numa funcao Multiple (no
                // Single o unico passo tem de ser a troca).
                guard index == 0, !single, step.sendingAsset == sellAsset, step.receivingAsset == sellAsset else {
                    throw TradeRefusal.malformed("passo de taxa fora do lugar")
                }
                let (paid, ours) = try feeStep(step, intent: intent, fee: context.fee)
                providerFee = providerFee + paid
                integratorPaid = integratorPaid + ours
            }
        }

        // Quanto o dono entrega: no Single, o `fromAmount` do unico passo (puxado por
        // `_depositAndSwapERC20Single`); no Multiple, a soma dos depositos; no nativo, o
        // msg.value, conferido pela validacao comum.
        let spent: BigUInt
        if intent.sell.isNative {
            guard deposited.isZero, first.sendingAsset == native, first.fromAmount == context.value else {
                throw TradeRefusal.malformed("passo nativo")
            }
            spent = context.value
        } else if single {
            guard first.sendingAsset == sellAsset else { throw TradeRefusal.sellTokenMismatch }
            spent = first.fromAmount
        } else {
            spent = deposited
        }
        guard first.sendingAsset == sellAsset else { throw TradeRefusal.sellTokenMismatch }

        // A taxa da Escalibur, quando ligada, e uma das distribuicoes do FeeForwarder.
        let integratorFee: TradeFeeTerms
        if context.fee.isNone {
            integratorFee = .none
        } else {
            let expected = spent * BigUInt(context.fee.bps) / TradeConstants.basisPoints
            guard !expected.isZero, integratorPaid == expected else { throw TradeRefusal.integratorFeeMismatch }
            integratorFee = context.fee
        }

        return DecodedSwap(
            provider: .lifi, function: function.signature,
            sellToken: first.sendingAsset, buyToken: last.receivingAsset, amountIn: spent,
            minOutField: minAmountOut, guaranteedOut: minAmountOut, recipient: receiver,
            integratorFee: integratorFee, providerFeeAmount: providerFee, outputCap: nil, deadline: nil
        )
    }

    /// O passo de taxa: devolve (taxa da LI.FI, taxa da Escalibur), em unidades do token
    /// vendido.
    static func feeStep(_ step: Step, intent: TradeIntent, fee: TradeFeeTerms) throws -> (BigUInt, BigUInt) {
        let distributions: [ABIValue]
        do {
            if intent.sell.isNative {
                let arguments = try forwardNativeFees.decodeCall(step.callData)
                distributions = try ABIRead.array(arguments.first, "distribuicoes")
            } else {
                let arguments = try forwardERC20Fees.decodeCall(step.callData)
                guard arguments.count == 2, try ABIRead.address(arguments[0], "token") == intent.sell.contract else {
                    throw TradeRefusal.malformed("token da taxa")
                }
                distributions = try ABIRead.array(arguments[1], "distribuicoes")
            }
        } catch let error as ABIError {
            throw TradeRefusal.callRefused(.invalidArguments(error))
        }
        guard !distributions.isEmpty, distributions.count <= 4 else { throw TradeRefusal.malformed("distribuicoes") }
        var providerPaid = BigUInt()
        var ours = BigUInt()
        for item in distributions {
            let pair = try ABIRead.tuple(item, "distribuicao", count: 2)
            let recipient = try ABIRead.address(pair[0], "recebedor")
            let amount = try ABIRead.uint(pair[1], "valor")
            guard !recipient.isZero, recipient != intent.owner else { throw TradeRefusal.malformed("recebedor da taxa") }
            if let ourRecipient = fee.recipient, recipient == ourRecipient {
                ours = ours + amount
            } else {
                providerPaid = providerPaid + amount
            }
        }
        return (providerPaid, ours)
    }
}
