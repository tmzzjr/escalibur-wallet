import EscaliburChains
import EscaliburCore
import Foundation

/// Um item do historico, neutro entre redes (Bitcoin, Litecoin, Dogecoin, Stellar).
///
/// So para exibir. Nada daqui volta para uma transacao: valores e contrapartes vem
/// do provedor e nao foram conferidos contra a cadeia. Em especial:
/// - `counterparty` nunca vira destino sugerido nem entra na lista de enderecos
///   conhecidos do planejamento. Envenenamento de endereco (§4.10) funciona
///   justamente mandando poeira de um endereco parecido para entrar no historico;
/// - item `suspicious` fica escondido por padrao, e a tela nao oferece "copiar
///   endereco" a partir dele.
public struct ChainActivity: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        /// Saiu da carteira para outra conta.
        case send
        /// Entrou na carteira vindo de outra conta.
        case receive
        /// Entre enderecos da propria carteira (UTXO) ou pagamento para si mesmo.
        case selfTransfer
        /// Stellar: path payment de um ativo para outro na propria conta.
        case swap
        /// Stellar: oferta da conta executada no livro (`/trades`).
        case trade
        /// Stellar: `create_account`, criando esta conta ou uma de fora.
        case createAccount
        /// Stellar: oferta criada, alterada ou cancelada.
        case offer
        /// Stellar: linha de confianca aberta, alterada ou removida.
        case trustline
        /// Stellar: `account_merge`.
        case accountMerge
        /// Stellar: saldo reivindicavel criado ou reivindicado.
        case claimableBalance
        case other
    }

    /// Um ativo como o historico mostra. Nativo, ou codigo mais emissor (Stellar).
    /// O emissor inteiro faz parte da identidade: "USDC" de outro emissor e outro ativo.
    public enum AssetRef: Sendable, Hashable {
        case native
        case issued(code: String, issuer: String)
    }

    public struct Movement: Sendable, Hashable {
        public let asset: AssetRef
        /// Na menor unidade da rede (satoshi, koinu, stroop).
        public let amount: BigUInt
        /// `true` entrou na carteira; `false` saiu.
        public let incoming: Bool

        public init(asset: AssetRef, amount: BigUInt, incoming: Bool) {
            self.asset = asset
            self.amount = amount
            self.incoming = incoming
        }
    }

    public enum Status: Sendable, Hashable {
        /// Na mempool. No UTXO, "pendente" nao e pagamento: full-RBF e padrao.
        case pending
        /// Em bloco. `confirmations` nil quando a rede tem finalidade imediata (Stellar)
        /// ou o provedor nao informou.
        case confirmed(confirmations: UInt32?)
        case failed
    }

    public enum Suspicion: String, Sendable, Hashable {
        /// Valor irrisorio vindo de quem a carteira nunca pagou: poeira de rastreio,
        /// envenenamento de endereco, ou moeda com inscricao que nao se deve gastar.
        case dust
        /// Ativo fora da lista curada (Stellar): o golpe classico do "token gratis".
        case unlistedAsset
        /// Saldo reivindicavel enviado por desconhecido: o canal de spam da Stellar.
        case unsolicitedClaimable
    }

    /// Unico por item: txid no UTXO, id da operacao ou do trade na Stellar.
    public let id: String
    public let chainID: String
    /// O que o explorador de blocos entende. nil num trade da Stellar executado contra
    /// oferta da conta: ele acontece na transacao de outra pessoa, e a `/trades` da
    /// Horizon nao diz qual.
    public let transactionHash: String?
    public let kind: Kind
    public let movements: [Movement]
    /// Taxa paga pela carteira, quando foi ela que pagou e o provedor informou.
    public let fee: BigUInt?
    /// Para exibir, e so. Ver o comentario do tipo.
    public let counterparty: String?
    public let date: Date?
    public let status: Status
    public let suspicion: Suspicion?

    public var suspicious: Bool { suspicion != nil }

    public init(
        id: String, chainID: String, transactionHash: String?, kind: Kind, movements: [Movement],
        fee: BigUInt?, counterparty: String?, date: Date?, status: Status, suspicion: Suspicion?
    ) {
        self.id = id
        self.chainID = chainID
        self.transactionHash = transactionHash
        self.kind = kind
        self.movements = movements
        self.fee = fee
        self.counterparty = counterparty
        self.date = date
        self.status = status
        self.suspicion = suspicion
    }
}

/// Onde uma transacao transmitida esta.
public enum ChainTransactionStatus: Sendable, Equatable {
    /// Nenhum provedor consultado conhece a transacao (ainda, ou nunca).
    case notFound
    /// Na mempool.
    case pending
    /// Em bloco (UTXO) ou em ledger fechado (Stellar). `confirmations` e nil na
    /// Stellar, onde o ledger fechado ja e final.
    case confirmed(height: UInt32, confirmations: UInt32?)
    /// Stellar: entrou no ledger e falhou (a taxa foi cobrada, nada mais aconteceu).
    case failed(height: UInt32)

    /// Junta as respostas de dois provedores, do lado de quem menos promete.
    ///
    /// Confirmado so quando os dois dizem confirmado, no mesmo bloco (recebimento
    /// "confirmado" por um provedor so e golpe comum em negociacao P2P, §5.5). Vista
    /// por um e desconhecida pelo outro vira pendente: acabou de ser transmitida.
    /// Dois estados finais diferentes (confirmada num, falha no outro, ou blocos
    /// diferentes) nao se resolvem aqui: e erro.
    static func combine(_ a: ChainTransactionStatus, _ b: ChainTransactionStatus) throws -> ChainTransactionStatus {
        switch (a, b) {
        case (.confirmed(let ha, let ca), .confirmed(let hb, let cb)):
            guard ha == hb else { throw ChainReaderError.providersDisagree }
            switch (ca, cb) {
            case (let x?, let y?): return .confirmed(height: ha, confirmations: min(x, y))
            default: return .confirmed(height: ha, confirmations: ca ?? cb)
            }
        case (.failed(let ha), .failed(let hb)):
            guard ha == hb else { throw ChainReaderError.providersDisagree }
            return a
        case (.confirmed, .failed), (.failed, .confirmed):
            throw ChainReaderError.providersDisagree
        case (.notFound, .notFound):
            return .notFound
        default:
            return .pending
        }
    }
}
