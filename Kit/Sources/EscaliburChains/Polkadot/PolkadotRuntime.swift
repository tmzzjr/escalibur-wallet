import EscaliburCore
import Foundation

/// A rede onde o DOT mora, compilada.
///
/// Desde a migracao de 4/11/2025 (Asset Hub Migration) os saldos de DOT, as contas e as
/// transferencias ficam na Polkadot Asset Hub, a parachain de sistema; a relay chain
/// guarda so o residuo (emissao total de cerca de 238 mil DOT na relay contra 1,7 bilhao
/// na Asset Hub, lidas em 28/09/2026). E na Asset Hub que a Trust Wallet, a Nova e o
/// Subscan mostram o saldo de DOT. A carteira le e envia DOT so ali; os tokens da Asset
/// Hub (USDT, USDC), staking e as outras parachains ficam fora da v1.
///
/// Nada aqui vem de provedor: hash de genese, nome e versao de transacao do runtime,
/// indices da chamada e deposito existencial sao literais, conferidos contra a rede a
/// cada plano. Um provedor que respondesse de outra rede (Kusama, testnet, a relay) ou
/// de um runtime que mudou a codificacao das chamadas faz o plano ser recusado.
public enum PolkadotRuntime {
    /// Hash do bloco 0 da Polkadot Asset Hub (`chain_getBlockHash(0)`), o mesmo do
    /// wallet-core (`test_statemint_encode_transaction_*`) e do registro da Nova.
    public static let genesisHash: [UInt8] = [UInt8](hex: "68d56f15f85d3136970ec16946040bc1752654e906147f7e43e9d539d7c3de2f")!
    /// `specName` do runtime da Polkadot Asset Hub.
    public static let specName = "statemint"
    /// `transactionVersion` do runtime lido em 28/09/2026 (spec 2005000). Ele sobe quando
    /// muda a codificacao ou o indice de alguma chamada; outra versao e recusa ate o app
    /// ser conferido de novo contra os metadados.
    public static let transactionVersion: UInt32 = 15
    /// `Balances` e o pallet 10 e `transfer_keep_alive` a chamada 3 (metadados v16 da spec
    /// 2005000; o `api.tx.balances.transferKeepAlive.callIndex` do polkadot-js da [10, 3]).
    public static let balancesPallet: UInt8 = 10
    public static let transferKeepAliveCall: UInt8 = 3
    /// `Balances.ExistentialDeposit` da Asset Hub: 0,01 DOT (100.000.000 planck, constante
    /// dos metadados em 28/09/2026). Conta com menos que isso deixa de existir, e um envio
    /// para conta vazia abaixo disso e recusado pela rede.
    public static let existentialDeposit = BigUInt(100_000_000)
    /// A transacao vale 256 blocos a partir do bloco de referencia. Com blocos de cerca de
    /// 2,2 s na Asset Hub (1.529 blocos em 3.408 s, medido em 28/09/2026), sao uns 9
    /// minutos: sobra o tempo da revisao e da transmissao, e uma transacao perdida nao
    /// entra horas depois.
    public static let eraPeriod: UInt64 = 256
    /// Teto da taxa lida da rede: 0,1 DOT. Uma transferencia custa cerca de 0,0009 DOT
    /// (`TransactionPaymentApi_query_info` em seis provedores, 28/09/2026); cem vezes isso
    /// e provedor errado ou mentindo.
    public static let feeCeiling = BigUInt(1_000_000_000)

    // Extensoes da transacao (`transactionExtensionsByVersion[0]` dos metadados v16, as
    // que valem para a extrinsic v4 assinada), na ordem: AuthorizeCall,
    // CheckNonZeroSender, CheckSpecVersion, CheckTxVersion, CheckGenesis, CheckMortality,
    // CheckNonce, CheckWeight, ChargeAssetTxPayment, PrevalidateAttests,
    // CheckMetadataHash, EthSetOrigin, StorageWeightReclaim. So cinco levam bytes:
    // - na transacao: era, nonce compacto, gorjeta compacta, `asset_id` (None: a taxa sai
    //   em DOT) e o modo do CheckMetadataHash (0, desligado);
    // - so no que se assina: spec_version e transaction_version (u32), hash de genese,
    //   hash do bloco da era e o hash dos metadados (None, porque o modo e desligado).
    // O mesmo layout do vetor transmitido da Kusama Asset Hub no wallet-core
    // (`test_sign_transfer_kusama_asset_hub`) e do polkadot-js com os metadados de hoje.
    // Um runtime com outra extensao que leve bytes na transacao nao decodifica a
    // estimativa de taxa, e o plano para ali.

    /// Versao da extrinsic assinada: 4, com o bit de assinada (0x80).
    static let signedExtrinsicVersion: UInt8 = 0x84
    /// `MultiAddress::Id`.
    static let multiAddressID: UInt8 = 0x00
    /// `MultiSignature::Ed25519`.
    static let ed25519Signature: UInt8 = 0x00
    /// `CheckMetadataHash`: modo desligado; o que se assina leva `None` (0x00).
    static let metadataHashDisabled: UInt8 = 0x00
    /// `ChargeAssetTxPayment.asset_id`: None, a taxa sai em DOT.
    static let feeInNativeAsset: UInt8 = 0x00
    /// O que se assina acima disso vai pelo BLAKE2b-256 dele (`SignedPayload`).
    static let payloadHashThreshold = 256
}
