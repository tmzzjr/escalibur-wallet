import EscaliburCore
import Foundation

/// Jettons (TEP-74), por ora so o USDT da Tether na TON.
///
/// Cada dono tem uma carteira jetton propria, um contrato separado que guarda o saldo
/// dele. Enviar USDT e mandar uma mensagem interna para a SUA carteira jetton com o
/// corpo `transfer`; ela debita e manda para a carteira jetton do destino.
public enum TONJetton {
    /// Contrato mestre do USDT na TON. Fonte: Tether (metadado em
    /// `https://tether.to/usdt-ton.json`, referenciado pelo proprio contrato) e
    /// `jetton/masters` do toncenter, conferido em 25/09/2026:
    /// `EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs`.
    public static let usdtMaster = TONAddress(
        workchain: 0,
        hash: Hex.decode("b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe") ?? []
    )
    public static let usdtDecimals = 6
    public static let usdtSymbol = "USDT"

    /// Hash do codigo da carteira jetton do USDT: ton-blockchain/stablecoin-contract,
    /// `build/JettonWallet.compiled.json`. E o mesmo hash que o mestre devolve em
    /// `get_jetton_data` como celula de biblioteca (conferido em 25/09/2026).
    static let usdtWalletCodeHash: [UInt8] = Hex.decode("8f452d7a4dfd74066b682365177259ed05734435be76b5fd4bd5d8af2b7c3d68") ?? []

    /// A conta e uma carteira jetton do USDT? O codigo dela, como a rede informa em
    /// `code_hash`, e a celula de biblioteca (ou, se algum provedor resolver a
    /// biblioteca, o proprio codigo).
    public static func isUSDTJettonWallet(codeHash: [UInt8]?) -> Bool {
        guard let codeHash else { return false }
        if codeHash == usdtWalletCodeHash { return true }
        return (try? TONCell.library(codeHash: usdtWalletCodeHash).hash) == codeHash
    }

    /// op `transfer` do TEP-74.
    public static let transferOp: UInt32 = 0x0F8A_7EA5

    /// TON que acompanha a mensagem para a carteira jetton pagar o gas dela e o da
    /// carteira jetton do destino. O que sobra volta ao dono (`response_destination`).
    /// 0,05 TON e o valor do Tonkeeper (`JettonEncoder.jettonTransferAmount`).
    public static let attachedTON: BigUInt = 50_000_000

    /// TON encaminhado ao destino junto do aviso `transfer_notification`. Um nanoton
    /// basta para o aviso existir, e e o aviso que leva o comentario: exchange que
    /// identifica deposito pelo comentario precisa dele. Valor do Tonkeeper.
    public static let forwardTON: BigUInt = 1

    /// O endereco da carteira jetton de USDT de um dono, calculado aqui a partir do
    /// codigo publicado (o mesmo calculo do contrato: `calculate_user_jetton_wallet_address`
    /// em stablecoin-contract `contracts/jetton-utils.fc`).
    ///
    /// Serve para conferir o que a rede diz: se o provedor devolvesse outra carteira
    /// jetton, os 0,05 TON anexados iriam para um contrato de terceiro.
    public static func usdtWallet(owner: TONAddress) throws -> TONAddress {
        var data = TONCellBuilder()
        try data.storeUInt(0, bits: 4)            // status
        try data.storeCoins(0)                    // balance
        try data.storeAddress(owner)
        try data.storeAddress(usdtMaster)
        let stateInit = try TONWallet.stateInit(code: TONCell.library(codeHash: usdtWalletCodeHash), data: data.build())
        return TONAddress(workchain: 0, stateInit: stateInit)
    }

    /// Corpo `transfer` (TEP-74):
    /// `transfer#0f8a7ea5 query_id:uint64 amount:(VarUInteger 16) destination:MsgAddress
    ///  response_destination:MsgAddress custom_payload:(Maybe ^Cell)
    ///  forward_ton_amount:(VarUInteger 16) forward_payload:(Either Cell ^Cell)`.
    ///
    /// O comentario vai em `forward_payload` por referencia (bit 1 + ^Cell), como o
    /// Tonkeeper faz; a carteira jetton do USDT exige que nada venha depois dele
    /// (`check_either_forward_payload`). Sem comentario, o bit 0 e payload vazio.
    public static func transferBody(
        queryID: UInt64, amount: BigUInt, destination: TONAddress, responseDestination: TONAddress,
        forwardTON: BigUInt, comment: String?
    ) throws -> TONCell {
        var b = TONCellBuilder()
        try b.storeUInt(UInt64(transferOp), bits: 32)
        try b.storeUInt(queryID, bits: 64)
        try b.storeCoins(amount)
        try b.storeAddress(destination)
        try b.storeAddress(responseDestination)
        try b.storeBit(false)                     // custom_payload: nenhum
        try b.storeCoins(forwardTON)
        if let comment {
            try b.storeBit(true)
            try b.storeRef(TONComment.cell(comment))
        } else {
            try b.storeBit(false)
        }
        return b.build()
    }
}
