import EscaliburChains
import EscaliburCore
import Foundation

/// Uma conta UTXO da carteira: rede, esquema (BIP-84, 49 ou 44), numero da conta e
/// a xpub dela (`m/purpose'/coin'/account'`).
///
/// A xpub fica aqui, no aparelho. Os enderecos saem dela localmente e so eles vao
/// para a rede, um por um: mandar a xpub a um provedor entregaria a carteira inteira,
/// passado e futuro (docs/seguranca.md §5.5).
public struct UTXOAccount: Sendable, Hashable {
    public let chain: Chain
    public let kind: UTXOInputKind
    /// O `a` de `m/purpose'/coin'/a'`, sem o bit de endurecido.
    public let account: UInt32
    public let accountKey: ExtendedPublicKey

    public init(chain: Chain, kind: UTXOInputKind, account: UInt32, accountKey: ExtendedPublicKey) throws {
        // Dogecoin nao tem segwit: so P2PKH (BIP-44). Nas outras, os tres esquemas.
        guard chain.family == .utxo, account < DerivationPath.hardenedOffset,
              UTXORules.for(chain).segwit || kind == .p2pkh
        else { throw ChainReaderError.unsupportedAccount }
        self.chain = chain
        self.kind = kind
        self.account = account
        self.accountKey = accountKey
    }

    /// `m/purpose'/coin'/account'`.
    public var path: DerivationPath {
        DerivationPath(components: [
            DerivationPath.hardened(kind.purpose), DerivationPath.hardened(chain.coinType), DerivationPath.hardened(account),
        ])
    }

    /// Deriva localmente o endereco da cadeia (0 recebimento, 1 troco) e indice.
    public func address(change: Bool, index: UInt32) throws -> UTXODerivedAddress {
        guard index < DerivationPath.hardenedOffset else { throw ChainReaderError.tooManyAddresses }
        let branch: UInt32 = change ? 1 : 0
        let key = try accountKey.derive([branch, index]).publicKey
        let script = kind.scriptPubKey(publicKey: key)
        guard let address = UTXOScript.address(for: script, chain: chain) else { throw ChainReaderError.unsupportedAccount }
        return UTXODerivedAddress(
            address: address, path: path.appending(branch).appending(index), publicKey: key,
            scriptPubKey: script, isChange: change, index: index
        )
    }
}

/// Um endereco derivado da xpub, com o que prova que e da carteira.
public struct UTXODerivedAddress: Sendable, Hashable {
    public let address: String
    /// `m/purpose'/coin'/account'/cadeia/indice`.
    public let path: DerivationPath
    /// Chave publica comprimida, derivada localmente.
    public let publicKey: [UInt8]
    public let scriptPubKey: [UInt8]
    public let isChange: Bool
    public let index: UInt32

    public init(address: String, path: DerivationPath, publicKey: [UInt8], scriptPubKey: [UInt8], isChange: Bool, index: UInt32) {
        self.address = address
        self.path = path
        self.publicKey = publicKey
        self.scriptPubKey = scriptPubKey
        self.isChange = isChange
        self.index = index
    }
}

/// O resultado da varredura por gap limit.
public struct UTXODiscovery: Sendable {
    public let account: UTXOAccount
    public let gapLimit: Int
    /// Enderecos com historico (confirmado ou na mempool), das duas cadeias.
    public let used: [UTXODerivedAddress]
    /// Todos os enderecos derivados na varredura, usados ou nao. Serve para saber o
    /// que e "nosso" no historico: um recebimento pode chegar num endereco da janela.
    public let scanned: [UTXODerivedAddress]
    /// Primeiro endereco de recebimento sem historico: o que a tela de receber mostra.
    public let nextReceive: UTXODerivedAddress
    /// Primeiro endereco de troco (cadeia 1) sem historico.
    public let nextChange: UTXODerivedAddress

    public var usedReceiveIndices: [UInt32] { used.filter { !$0.isChange }.map(\.index) }
    public var usedChangeIndices: [UInt32] { used.filter(\.isChange).map(\.index) }

    /// O troco no formato que `UTXOPlanner.planSend` confere: endereco, caminho e
    /// chave derivados da xpub, e a propria xpub.
    public var changeAddress: UTXOChangeAddress {
        UTXOChangeAddress(address: nextChange.address, path: nextChange.path, publicKey: nextChange.publicKey, accountKey: account.accountKey)
    }

    public init(
        account: UTXOAccount, gapLimit: Int, used: [UTXODerivedAddress], scanned: [UTXODerivedAddress],
        nextReceive: UTXODerivedAddress, nextChange: UTXODerivedAddress
    ) {
        self.account = account
        self.gapLimit = gapLimit
        self.used = used
        self.scanned = scanned
        self.nextReceive = nextReceive
        self.nextChange = nextChange
    }
}

/// Moedas lidas e conferidas, e as que foram descartadas com o motivo.
public struct UTXOCoinReading: Sendable {
    /// Cada uma com a transacao anterior inteira, conferida por `UTXOPreviousOutput.verify`
    /// e pagando o script da chave derivada localmente.
    public let coins: [UTXOCoin]
    public let rejected: [UTXORejectedCoin]
    /// Altura usada para contar as confirmacoes.
    public let tipHeight: UInt32
    /// Valor de cada moeda, tirado da saida conferida (nunca do que o provedor disse).
    public let values: [UTXOOutpoint: UInt64]

    public init(coins: [UTXOCoin], rejected: [UTXORejectedCoin], tipHeight: UInt32, values: [UTXOOutpoint: UInt64]) {
        self.coins = coins
        self.rejected = rejected
        self.tipHeight = tipHeight
        self.values = values
    }

    public var confirmedTotal: UInt64 { total(confirmed: true) }
    public var pendingTotal: UInt64 { total(confirmed: false) }

    private func total(confirmed: Bool) -> UInt64 {
        coins.filter { ($0.confirmations > 0) == confirmed }.reduce(UInt64(0)) { $0 &+ (values[$1.outpoint] ?? 0) }
    }
}

/// Uma moeda que o provedor listou e que nao passou na conferencia.
public struct UTXORejectedCoin: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        /// Nenhum provedor entregou a transacao anterior.
        case previousTransactionUnavailable
        /// A transacao anterior nao e uma transacao valida.
        case previousTransactionMalformed
        /// O txid da transacao entregue nao e o do outpoint: outra transacao, ou uma
        /// adulterada. O valor dela nao vale nada.
        case previousTransactionMismatch
        case outputIndexOutOfRange
        /// A saida nao paga o script do nosso endereco.
        case notOurScript
        /// O valor que o provedor anunciou nao e o da saida conferida. A moeda pode
        /// existir, mas quem mente o valor nao merece o resto da alegacao.
        case claimedValueMismatch
        /// Vale menos do que custa gasta-la na taxa rapida de agora (poeira). Nao e
        /// conferida nem baixada: o planejador a deixaria de fora de qualquer jeito, e
        /// baixar a transacao anterior de centenas delas travaria o envio.
        case uneconomic
        /// Alem do teto de moedas conferidas numa leitura, que ficam com as maiores.
        case overLimit
    }

    public let outpoint: UTXOOutpoint
    public let reason: Reason

    public init(outpoint: UTXOOutpoint, reason: Reason) {
        self.outpoint = outpoint
        self.reason = reason
    }
}

/// Niveis de taxa para a tela, e as estimativas por fonte para o teto do planejamento.
public struct UTXOFeeLevels: Sendable, Equatable {
    public let slow: UTXOFeeRate
    public let normal: UTXOFeeRate
    public let fast: UTXOFeeRate
    /// A estimativa de maior prioridade de cada fonte, uma por fonte: vai para
    /// `UTXONetworkState.feeEstimates`, que o planejamento confere com `UTXOFeeConsensus`.
    public let estimates: [UTXOFeeRate]
    /// Nomes das fontes que responderam, na mesma ordem de `estimates`.
    public let sources: [String]

    public init(slow: UTXOFeeRate, normal: UTXOFeeRate, fast: UTXOFeeRate, estimates: [UTXOFeeRate], sources: [String]) {
        self.slow = slow
        self.normal = normal
        self.fast = fast
        self.estimates = estimates
        self.sources = sources
    }
}

/// Tudo o que `UTXOPlanner.planSend` precisa alem da intencao do dono.
public struct UTXOSpendState: Sendable {
    public let network: UTXONetworkState
    public let change: UTXOChangeAddress
    public let fees: UTXOFeeLevels
    public let rejected: [UTXORejectedCoin]
}

/// O que aconteceu na transmissao.
public struct UTXOBroadcastReceipt: Sendable, Equatable {
    /// Calculado localmente dos bytes assinados, e conferido com o que cada provedor
    /// devolveu.
    public let txid: String
    public let acceptedBy: [String]
    public let rejectedBy: [String]
}
