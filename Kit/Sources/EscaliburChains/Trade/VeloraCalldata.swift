import EscaliburCore
import Foundation

// Velora (ex-ParaSwap), Augustus V6.2.
//
// Fonte: o codigo verificado no Sourcify (AugustusV6, solc 0.8.22, match nas 7 redes),
// arquivos src/routers/swapExactAmountIn/GenericSwapExactAmountIn.sol,
// src/AugustusV6Types.sol e src/fees/AugustusFees.sol.
//
// A v1 aceita so `swapExactAmountIn` (o cliente pede `includeContractMethods=
// swapExactAmountIn`). As variantes diretas (UniswapV2/V3, Curve, Balancer, RFQ) tem
// estruturas proprias e ficam fora ate terem decodificador e teste.
//
//   swapExactAmountIn(address executor, GenericData swapData, uint256 partnerAndFee,
//                     bytes permit, bytes executorData)
//   GenericData(srcToken, destToken, fromAmount, toAmount, quotedAmount, metadata,
//               beneficiary)
//
// O que o router garante, lido do fonte:
// - transfere `fromAmount` do dono para o `executor` (ou exige msg.value == fromAmount
//   se vende nativo), chama o executor, e reverte se o saldo de `destToken` do router
//   ficar abaixo de `toAmount`;
// - **depois** dessa conferencia, processa taxa: com parceiro e fee > 0, tira a taxa do
//   recebido (o dono pode ficar abaixo de `toAmount`); sem parceiro, a sobra acima de
//   `quotedAmount` vai para a Velora; e sempre deixa 1 wei de poeira no router.
// Por isso o garantido e `toAmount - 1` sem taxa, e `toAmount - taxa - 1` com taxa, e
// `quotedAmount >= toAmount` e exigido: com `quotedAmount` menor, a "sobra" comeria o
// minimo.
//
// O `executor` e o `executorData` sao opacos. Isso so e aceitavel porque o router
// confere o minimo na propria conta antes de pagar o `beneficiary`.

enum VeloraCalldata {
    static let swapExactAmountIn = try! ABIFunction(
        "swapExactAmountIn(address,(address,address,uint256,uint256,uint256,bytes32,address),uint256,bytes,bytes)"
    )  // e3ead59e

    static let functions = [swapExactAmountIn]

    // AugustusFees.sol: `partner := shr(96, partnerAndFee)`, `feeData := and(partnerAndFee,
    // 0xFFFFFFFFFFFFFFFFFFFFFFFF)`. Nos 12 bytes baixos, as flags ficam nos bits 90 a 95
    // (o primeiro byte) e a taxa nos 14 bits baixos (FEE_PERCENT_IN_BASIS_POINTS_MASK).
    static let isUserSurplus: UInt8 = 1 << 2     // bit 90
    static let isDirectTransfer: UInt8 = 1 << 3  // bit 91
    static let isCapSurplus: UInt8 = 1 << 4      // bit 92
    static let isSkipBlacklist: UInt8 = 1 << 5   // bit 93
    static let isReferral: UInt8 = 1 << 6        // bit 94
    static let isTakeSurplus: UInt8 = 1 << 7     // bit 95
    /// MAX_FEE_PERCENT da Augustus: acima disso o contrato corta em 2%.
    static let maxFeeBps: UInt32 = 200

    struct PartnerAndFee: Equatable {
        let partner: EVMAddress
        let flags: UInt8
        let feeBps: UInt32
        /// Bits entre as flags e a taxa, que o contrato ignora e a carteira exige zero.
        let dirty: Bool
    }

    static func parsePartnerAndFee(_ word: BigUInt) -> PartnerAndFee? {
        guard let bytes = word.bigEndianBytes(padTo: 32) else { return nil }
        let partner = EVMAddress(uncheckedBytes: Array(bytes[0..<20]))
        let feeData = Array(bytes[20..<32])
        let flags = feeData[0]
        let fee = UInt32(feeData[10] & 0x3F) << 8 | UInt32(feeData[11])
        let dirty = (flags & 0b11) != 0 || feeData[1...9].contains { $0 != 0 } || (feeData[10] & 0xC0) != 0
        return PartnerAndFee(partner: partner, flags: flags, feeBps: fee, dirty: dirty)
    }

    static func decode(function: ABIFunction, arguments: [ABIValue], context: TradeDecodeContext) throws -> DecodedSwap {
        guard function == swapExactAmountIn, arguments.count == 5 else { throw TradeRefusal.selectorNotAllowed(function.selector) }
        let executor = try ABIRead.address(arguments[0], "executor")
        let data = try ABIRead.tuple(arguments[1], "swapData", count: 7)
        let partnerAndFee = try ABIRead.uint(arguments[2], "partnerAndFee")
        let permit = try ABIRead.bytes(arguments[3], "permit")
        let executorData = try ABIRead.bytes(arguments[4], "executorData")

        let srcToken = try ABIRead.address(data[0], "srcToken")
        let destToken = try ABIRead.address(data[1], "destToken")
        let fromAmount = try ABIRead.uint(data[2], "fromAmount")
        let toAmount = try ABIRead.uint(data[3], "toAmount")
        let quotedAmount = try ABIRead.uint(data[4], "quotedAmount")
        let beneficiary = try ABIRead.address(data[6], "beneficiary")

        // Permit (EIP-2612) ou Permit2 dentro da troca: a v1 nao assina permissao fora
        // da cadeia, e o router usaria a assinatura para puxar o token.
        guard permit.isEmpty else { throw TradeRefusal.malformed("permit") }
        guard !executor.isZero, executor != context.intent.owner, executor != context.router.address else {
            throw TradeRefusal.malformed("executor")
        }
        guard !executorData.isEmpty else { throw TradeRefusal.malformed("executorData") }
        // Beneficiario zero vira msg.sender no contrato. Aceitar so o dono escrito por
        // extenso deixa a tela e a calldata dizendo a mesma coisa.
        guard beneficiary == context.intent.owner else { throw TradeRefusal.recipientMismatch(beneficiary) }
        guard !toAmount.isZero else { throw TradeRefusal.zeroMinimumOut }
        guard quotedAmount >= toAmount else { throw TradeRefusal.malformed("quotedAmount abaixo de toAmount") }

        guard let fees = parsePartnerAndFee(partnerAndFee), !fees.dirty else { throw TradeRefusal.malformed("partnerAndFee") }
        let guaranteed: BigUInt
        let integratorFee: TradeFeeTerms
        if fees.partner.isZero {
            // Sem parceiro, a taxa e ignorada pelo contrato; a carteira exige zero para
            // a calldata nao carregar um numero que a tela nao mostra. So a flag que
            // limita a sobra da Velora a 1% e aceita.
            guard context.fee.isNone else { throw TradeRefusal.integratorFeeMismatch }
            guard fees.feeBps == 0, fees.flags & ~isCapSurplus == 0 else { throw TradeRefusal.integratorFeeMismatch }
            integratorFee = .none
            guaranteed = toAmount - 1
        } else {
            guard let recipient = context.fee.recipient, recipient == fees.partner,
                  fees.feeBps == context.fee.bps, fees.feeBps > 0, fees.feeBps <= maxFeeBps
            else { throw TradeRefusal.integratorFeeMismatch }
            // Referral, takeSurplus e skipBlacklist mudam para onde vai a sobra ou
            // desligam a lista de tokens bloqueados: fora.
            guard fees.flags & ~(isCapSurplus | isDirectTransfer) == 0 else { throw TradeRefusal.integratorFeeMismatch }
            integratorFee = TradeFeeTerms(recipient: recipient, bps: fees.feeBps)
            // A taxa sai depois da conferencia do minimo, sobre no maximo o recebido.
            let fee = (toAmount * BigUInt(fees.feeBps) + TradeConstants.basisPoints - 1) / TradeConstants.basisPoints
            guard let net = toAmount.subtractingReportingUnderflow(fee + 1), !net.isZero else { throw TradeRefusal.zeroMinimumOut }
            guaranteed = net
        }

        return DecodedSwap(
            provider: .velora, function: function.signature,
            sellToken: srcToken, buyToken: destToken, amountIn: fromAmount,
            minOutField: toAmount, guaranteedOut: guaranteed, recipient: beneficiary,
            integratorFee: integratorFee, providerFeeAmount: 0,
            // Sem parceiro e sem o limite de 1%, a sobra inteira acima da cotacao fica com
            // a Velora: o dono nunca recebe mais que `quotedAmount`.
            outputCap: fees.partner.isZero && fees.flags & isCapSurplus == 0 ? quotedAmount : nil, deadline: nil
        )
    }
}
