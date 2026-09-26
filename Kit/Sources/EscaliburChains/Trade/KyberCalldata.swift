import EscaliburCore
import Foundation

// KyberSwap, MetaAggregationRouterV2.
//
// Fonte: o codigo verificado no Sourcify (MetaAggregationRouterV2, contracts/
// MetaAggregationRouterV2.sol, match nas 7 redes).
//
//   swap(SwapExecutionParams execution)
//   SwapExecutionParams(callTarget, approveTarget, targetData, desc, clientData)
//   SwapDescriptionV2(srcToken, dstToken, srcReceivers[], srcAmounts[], feeReceivers[],
//                     feeAmounts[], dstReceiver, amount, minReturnAmount, flags, permit)
//
// O que o router garante, lido do fonte: transfere `srcAmounts[i]` do dono para
// `srcReceivers[i]` (soma <= amount), chama `callTarget.callBytes(targetData)`, e confere
// o aumento de saldo de `dstReceiver` contra `minReturnAmount` (com a taxa de destino ja
// tirada, se houver). `callTarget` e `targetData` sao opacos pela mesma razao da Velora.
//
// Flags (constantes do contrato): PARTIAL_FILL 0x01, REQUIRES_EXTRA_ETH 0x02,
// SHOULD_CLAIM 0x04, BURN_FROM_MSG_SENDER 0x08, BURN_FROM_TX_ORIGIN 0x10, SIMPLE_SWAP
// 0x20, FEE_ON_DST 0x40, FEE_IN_BPS 0x80, APPROVE_FUND 0x100. A API ao vivo sempre manda
// 0x200, bit que o router nao le (nenhum `_flagsChecked` usa 0x200); ele e aceito. As
// outras sao recusadas: execucao parcial devolve menos que o minimo, ETH extra fica no
// executor, modo simples e aprovacao ao `approveTarget` sao caminhos que a carteira nao
// decodifica.

enum KyberCalldata {
    static let swap = try! ABIFunction(
        "swap((address,address,bytes,(address,address,address[],uint256[],address[],uint256[],address,uint256,uint256,uint256,bytes),bytes))"
    )  // e21fd0e9

    static let functions = [swap]

    static let partialFill: UInt64 = 0x01
    static let feeOnDestination: UInt64 = 0x40
    static let feeInBps: UInt64 = 0x80
    /// Marcador da API, ignorado pelo contrato.
    static let apiMarker: UInt64 = 0x200

    static func decode(function: ABIFunction, arguments: [ABIValue], context: TradeDecodeContext) throws -> DecodedSwap {
        guard function == swap, arguments.count == 1 else { throw TradeRefusal.selectorNotAllowed(function.selector) }
        let execution = try ABIRead.tuple(arguments[0], "execution", count: 5)
        let callTarget = try ABIRead.address(execution[0], "callTarget")
        let approveTarget = try ABIRead.address(execution[1], "approveTarget")
        let targetData = try ABIRead.bytes(execution[2], "targetData")
        let desc = try ABIRead.tuple(execution[3], "desc", count: 11)

        let srcToken = try ABIRead.address(desc[0], "srcToken")
        let dstToken = try ABIRead.address(desc[1], "dstToken")
        let srcReceivers = try ABIRead.array(desc[2], "srcReceivers").map { try ABIRead.address($0, "srcReceivers") }
        let srcAmounts = try ABIRead.array(desc[3], "srcAmounts").map { try ABIRead.uint($0, "srcAmounts") }
        let feeReceivers = try ABIRead.array(desc[4], "feeReceivers").map { try ABIRead.address($0, "feeReceivers") }
        let feeAmounts = try ABIRead.array(desc[5], "feeAmounts").map { try ABIRead.uint($0, "feeAmounts") }
        let dstReceiver = try ABIRead.address(desc[6], "dstReceiver")
        let amount = try ABIRead.uint(desc[7], "amount")
        let minReturn = try ABIRead.uint(desc[8], "minReturnAmount")
        let flags = try ABIRead.flags(desc[9], "flags")
        let permit = try ABIRead.bytes(desc[10], "permit")

        guard permit.isEmpty else { throw TradeRefusal.malformed("permit") }
        guard !callTarget.isZero, callTarget != context.intent.owner, callTarget != context.router.address else {
            throw TradeRefusal.malformed("callTarget")
        }
        // `approveTarget` so e usado com APPROVE_FUND, que e recusado; mesmo assim tem de
        // vir zero para a calldata nao carregar um spender que a tela nao mostra.
        guard approveTarget.isZero else { throw TradeRefusal.malformed("approveTarget") }
        guard !targetData.isEmpty else { throw TradeRefusal.malformed("targetData") }
        guard dstReceiver == context.intent.owner else { throw TradeRefusal.recipientMismatch(dstReceiver) }
        guard !minReturn.isZero else { throw TradeRefusal.zeroMinimumOut }

        // Quem recebe o token vendido: a soma tem de ser o valor inteiro, e nenhum
        // recebedor pode ser o proprio dono (seria uma volta sem troca).
        guard srcReceivers.count == srcAmounts.count else { throw TradeRefusal.malformed("srcReceivers") }
        if srcToken == TradeConstants.eeeeSentinel {
            // Nativo vai inteiro como msg.value ao callTarget; nao ha transferFrom.
            guard srcReceivers.isEmpty else { throw TradeRefusal.malformed("srcReceivers com nativo") }
        } else {
            guard !srcReceivers.isEmpty, !srcReceivers.contains(where: { $0.isZero || $0 == context.intent.owner }) else {
                throw TradeRefusal.malformed("srcReceivers")
            }
            let total = srcAmounts.reduce(BigUInt(), +)
            guard total == amount else { throw TradeRefusal.malformed("soma de srcAmounts") }
        }

        // Taxa de integrador: listas vazias hoje. Com taxa ligada, um recebedor so (o da
        // empresa), em bps, cobrada no token comprado (que e da lista curada).
        let integratorFee: TradeFeeTerms
        var allowedFlags = apiMarker
        if context.fee.isNone {
            guard feeReceivers.isEmpty, feeAmounts.isEmpty else { throw TradeRefusal.integratorFeeMismatch }
            integratorFee = .none
        } else {
            guard let recipient = context.fee.recipient, feeReceivers == [recipient], feeAmounts == [BigUInt(context.fee.bps)],
                  flags & feeInBps != 0, flags & feeOnDestination != 0
            else { throw TradeRefusal.integratorFeeMismatch }
            integratorFee = context.fee
            allowedFlags |= feeInBps | feeOnDestination
        }
        guard flags & ~allowedFlags == 0 else { throw TradeRefusal.malformed("flags 0x" + String(flags, radix: 16)) }

        return DecodedSwap(
            provider: .kyberSwap, function: function.signature,
            sellToken: srcToken, buyToken: dstToken, amountIn: amount,
            minOutField: minReturn, guaranteedOut: minReturn, recipient: dstReceiver,
            integratorFee: integratorFee, providerFeeAmount: 0, outputCap: nil, deadline: nil
        )
    }
}
