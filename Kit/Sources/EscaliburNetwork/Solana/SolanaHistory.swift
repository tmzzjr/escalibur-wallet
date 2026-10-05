import EscaliburChains
import EscaliburCore
import Foundation

// Historico da conta: o efeito liquido de cada transacao sobre o dono.
//
// O valor vem de `preBalances`/`postBalances` e de `pre/postTokenBalances` (o que a
// cadeia registrou), nunca do texto das instrucoes; as instrucoes so servem para
// achar a contraparte. SOL embrulhado conta como SOL. A taxa aparece separada e so
// quando o dono pagou.
//
// Suspeitas (docs/seguranca.md §4.10), escondidas por padrao na tela:
//   - token fora da lista curada: mint falso com nome de token conhecido e a isca
//     mais comum;
//   - poeira vinda de desconhecido: envenenamento de endereco (um lamport de um
//     endereco parecido com o de quem o dono costuma pagar, para ele copiar do
//     historico);
//   - saldo do dono que diminui numa transacao que o dono nao assinou (delegado ou
//     registro falsificado).

/// Uma linha do historico.
public struct SolanaActivity: Sendable, Equatable, Identifiable {
    public enum Direction: String, Sendable, Equatable {
        case incoming, outgoing, swap
        /// Sem movimento de ativo alem da taxa (falhou, criou conta, interagiu com programa).
        case other
    }

    public enum Status: Sendable, Equatable {
        case confirmed
        case finalized
        case failed(String)
    }

    public enum Suspicion: Sendable, Equatable {
        case unknownToken(mint: String)
        case dustFromUnknown
        case spentWithoutSigning
    }

    /// O ativo de uma mudanca: SOL ou token da lista (com o `Asset` compilado), ou
    /// token fora da lista, que so tem o mint e as casas (nome e simbolo vindos da
    /// rede nunca sao exibidos: e exatamente o que o golpista escolhe).
    public enum ActivityAsset: Sendable, Equatable {
        case listed(Asset)
        case unlisted(mint: String, decimals: Int)

        public var decimals: Int {
            switch self {
            case .listed(let asset): return asset.decimals
            case .unlisted(_, let decimals): return decimals
            }
        }

        /// O mint, para token; nil para SOL.
        public var mint: String? {
            switch self {
            case .listed(let asset):
                if case .token(let contract) = asset.kind { return contract }
                return nil
            case .unlisted(let mint, _): return mint
            }
        }

        public var isNative: Bool {
            if case .listed(let asset) = self { return asset.kind == .native }
            return false
        }
    }

    /// Um ativo que mudou de saldo.
    public struct Change: Sendable, Equatable {
        public let asset: ActivityAsset
        public let amount: BigUInt
        public let isIncoming: Bool
    }

    /// A assinatura da transacao.
    public let id: String
    public let direction: Direction
    /// O ativo principal: o que entrou (recebimento), o que saiu (envio, troca).
    public let asset: ActivityAsset
    public let amount: BigUInt
    /// Quem mandou ou recebeu. nil em troca e quando nao da para saber.
    public let counterparty: String?
    public let date: Date?
    public let slot: UInt64
    public let status: Status
    /// Taxa paga pelo dono, em lamports (zero quando outro pagou).
    public let fee: BigUInt
    /// Todas as mudancas de saldo do dono, inclusive tokens fora da lista.
    public let changes: [Change]
    public let suspicions: [Suspicion]

    public var isSuspicious: Bool { !suspicions.isEmpty }
}

public enum SolanaActivityParser {
    /// Recebimento de SOL abaixo disto, de desconhecido, e poeira (0,001 SOL).
    public static let solDustLamports: UInt64 = 1_000_000
    /// Token da lista abaixo de 0,01 unidade, de desconhecido, e poeira.
    static func tokenDust(decimals: Int) -> BigUInt { decimals >= 2 ? BigUInt.power(of: 10, decimals - 2) : BigUInt(1) }

    /// Le a resposta crua de `getTransaction` (jsonParsed). nil quando o no nao
    /// conhece a transacao ou ela nao afeta o dono.
    public static func activity(
        transactionResponse data: Data, owner: SolanaPublicKey, confirmationStatus: String? = nil, knownAddresses: Set<String> = []
    ) throws -> SolanaActivity? {
        guard let tx = try SolanaRPC.decodeOptional(data, method: "getTransaction", as: RPCTransaction.self) else { return nil }
        return activity(tx, owner: owner, confirmationStatus: confirmationStatus, knownAddresses: knownAddresses)
    }

    static func activity(_ tx: RPCTransaction, owner: SolanaPublicKey, confirmationStatus: String?, knownAddresses: Set<String>) -> SolanaActivity? {
        guard let meta = tx.meta, let signature = tx.transaction.signatures.first else { return nil }
        let me = owner.base58
        let keys = tx.transaction.message.accountKeys.map(\.pubkey)
        let ownerIndex = keys.firstIndex(of: me)
        let ownerSigned = tx.transaction.message.accountKeys.contains { $0.pubkey == me && $0.signer }
        let feePaid: UInt64 = keys.first == me ? meta.fee : 0

        // SOL: saldo do dono, sem a taxa, mais o SOL embrulhado.
        var sol = SignedAmount()
        if let index = ownerIndex, index < meta.preBalances.count, index < meta.postBalances.count {
            sol = SignedAmount(meta.postBalances[index]) - SignedAmount(meta.preBalances[index]) + SignedAmount(feePaid)
        }
        // Tokens do dono, somados por mint.
        var pre = [String: BigUInt]()
        var post = [String: BigUInt]()
        var decimals = [String: Int]()
        var accountOwner = [String: String]()
        var accountMint = [String: String]()
        for (balances, isPost) in [(meta.preTokenBalances ?? [], false), (meta.postTokenBalances ?? [], true)] {
            for balance in balances {
                guard balance.accountIndex < keys.count else { continue }
                let account = keys[balance.accountIndex]
                if let holder = balance.owner { accountOwner[account] = holder }
                accountMint[account] = balance.mint
                guard balance.owner == me, let amount = BigUInt(decimal: balance.uiTokenAmount.amount) else { continue }
                decimals[balance.mint] = balance.uiTokenAmount.decimals
                if isPost { post[balance.mint, default: BigUInt()] = post[balance.mint, default: BigUInt()] + amount }
                else { pre[balance.mint, default: BigUInt()] = pre[balance.mint, default: BigUInt()] + amount }
            }
        }
        var changes = [SolanaActivity.Change]()
        let wrapped = SolanaWrappedSOL.mint.base58
        for mint in Set(pre.keys).union(post.keys).sorted() {
            let delta = SignedAmount(post[mint] ?? BigUInt()) - SignedAmount(pre[mint] ?? BigUInt())
            if mint == wrapped { sol = sol + delta; continue }
            guard !delta.isZero else { continue }
            changes.append(.init(asset: asset(mint: mint, decimals: decimals[mint] ?? 0), amount: delta.magnitude, isIncoming: !delta.negative))
        }
        if !sol.isZero {
            changes.insert(.init(asset: .listed(.native(.solana)), amount: sol.magnitude, isIncoming: !sol.negative), at: 0)
        }
        // Transacao de outros que so cita o dono, sem efeito: ruido, fora do historico.
        if changes.isEmpty, feePaid == 0, !ownerSigned { return nil }

        let incoming = changes.filter(\.isIncoming)
        let outgoing = changes.filter { !$0.isIncoming }
        let direction: SolanaActivity.Direction
        let primary: SolanaActivity.Change?
        switch (incoming.isEmpty, outgoing.isEmpty) {
        case (false, true): direction = .incoming; primary = preferred(incoming)
        case (true, false): direction = .outgoing; primary = preferred(outgoing)
        case (false, false): direction = .swap; primary = preferred(outgoing)
        case (true, true): direction = .other; primary = nil
        }

        let transfers = parsedTransfers(tx, accountOwner: accountOwner, accountMint: accountMint)
        var counterparty: String?
        if let primary, direction != .swap {
            counterparty = Self.counterparty(for: primary, owner: me, transfers: transfers)
        }

        var suspicions = [SolanaActivity.Suspicion]()
        for change in changes {
            if case .unlisted(let mint, _) = change.asset { suspicions.append(.unknownToken(mint: mint)) }
        }
        if direction == .incoming, let primary, !(counterparty.map(knownAddresses.contains) ?? false) {
            let dust = primary.asset.isNative ? BigUInt(solDustLamports) : tokenDust(decimals: primary.asset.decimals)
            if primary.amount < dust { suspicions.append(.dustFromUnknown) }
        }
        if !outgoing.isEmpty, !ownerSigned { suspicions.append(.spentWithoutSigning) }

        let status: SolanaActivity.Status
        if let error = meta.err, !error.isNull { status = .failed(error.compactText) }
        else { status = confirmationStatus == "finalized" ? .finalized : .confirmed }

        return SolanaActivity(
            id: signature, direction: direction, asset: primary?.asset ?? .listed(.native(.solana)), amount: primary?.amount ?? BigUInt(),
            counterparty: counterparty, date: tx.blockTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }, slot: tx.slot,
            status: status, fee: BigUInt(feePaid), changes: changes, suspicions: suspicions
        )
    }

    /// Token da lista antes de SOL (quem envia token paga rent em SOL; o principal e
    /// o token), e token fora da lista por ultimo.
    static func preferred(_ changes: [SolanaActivity.Change]) -> SolanaActivity.Change? {
        func rank(_ change: SolanaActivity.Change) -> Int {
            switch change.asset {
            case .listed(let asset): return asset.kind == .native ? 1 : 0
            case .unlisted: return 2
            }
        }
        return changes.min { rank($0) < rank($1) }
    }

    static func asset(mint: String, decimals: Int) -> SolanaActivity.ActivityAsset {
        // Da lista so se as casas baterem: mesmo mint com outras casas e dado errado.
        if let curated = TokenRegistry.find(chainID: Chain.solana.id, contract: mint), curated.decimals == decimals { return .listed(curated) }
        return .unlisted(mint: mint, decimals: decimals)
    }

    /// Uma transferencia lida das instrucoes (de primeiro nivel e internas).
    struct Transfer {
        /// Carteira de origem e de destino (conta de token ja traduzida para o dono).
        let from: String?
        let to: String?
        /// nil para SOL; o mint para token.
        let mint: String?
    }

    static func parsedTransfers(_ tx: RPCTransaction, accountOwner: [String: String], accountMint: [String: String]) -> [Transfer] {
        var all = tx.transaction.message.instructions
        for inner in tx.meta?.innerInstructions ?? [] { all += inner.instructions }
        var transfers = [Transfer]()
        for ix in all {
            guard let parsed = ix.parsed, let type = parsed["type"]?.stringValue, let info = parsed["info"] else { continue }
            switch (ix.program, type) {
            case ("system", "transfer"), ("system", "transferWithSeed"):
                transfers.append(Transfer(from: info["source"]?.stringValue, to: info["destination"]?.stringValue, mint: nil))
            case ("spl-token", "transfer"), ("spl-token", "transferChecked"), ("spl-token-2022", "transfer"), ("spl-token-2022", "transferChecked"):
                guard let source = info["source"]?.stringValue, let destination = info["destination"]?.stringValue else { continue }
                let authority = info["authority"]?.stringValue ?? info["multisigAuthority"]?.stringValue
                transfers.append(Transfer(
                    from: accountOwner[source] ?? authority, to: accountOwner[destination] ?? destination,
                    mint: info["mint"]?.stringValue ?? accountMint[source] ?? accountMint[destination]
                ))
            default:
                continue
            }
        }
        return transfers
    }

    static func counterparty(for change: SolanaActivity.Change, owner: String, transfers: [Transfer]) -> String? {
        let mint = change.asset.mint
        let relevant = transfers.filter { $0.mint == mint }
        if change.isIncoming {
            return relevant.first { $0.to == owner && $0.from != owner && $0.from != nil }?.from
        }
        return relevant.first { $0.from == owner && $0.to != owner && $0.to != nil }?.to
    }
}

/// Inteiro com sinal sobre `BigUInt`, so para somar saldos antes e depois.
struct SignedAmount: Equatable {
    var magnitude = BigUInt()
    var negative = false

    init() {}
    init(_ value: UInt64) { magnitude = BigUInt(value) }
    init(_ value: BigUInt) { magnitude = value }

    var isZero: Bool { magnitude.isZero }

    static func + (a: SignedAmount, b: SignedAmount) -> SignedAmount {
        var result = SignedAmount()
        if a.negative == b.negative {
            result.magnitude = a.magnitude + b.magnitude
            result.negative = a.negative
        } else if a.magnitude >= b.magnitude {
            result.magnitude = a.magnitude - b.magnitude
            result.negative = a.negative
        } else {
            result.magnitude = b.magnitude - a.magnitude
            result.negative = b.negative
        }
        if result.magnitude.isZero { result.negative = false }
        return result
    }

    static prefix func - (a: SignedAmount) -> SignedAmount {
        var result = a
        result.negative = a.magnitude.isZero ? false : !a.negative
        return result
    }

    static func - (a: SignedAmount, b: SignedAmount) -> SignedAmount { a + (-b) }
}

/// `getTransaction` com `jsonParsed`, so o que o historico usa.
struct RPCTransaction: Decodable, Sendable {
    struct Meta: Decodable, Sendable {
        let err: JSONValue?
        let fee: UInt64
        let preBalances: [UInt64]
        let postBalances: [UInt64]
        let preTokenBalances: [TokenBalance]?
        let postTokenBalances: [TokenBalance]?
        let innerInstructions: [Inner]?
    }

    struct TokenBalance: Decodable, Sendable {
        struct Amount: Decodable, Sendable {
            let amount: String
            let decimals: Int
        }
        let accountIndex: Int
        let mint: String
        let owner: String?
        let uiTokenAmount: Amount
    }

    struct Inner: Decodable, Sendable {
        let index: Int
        let instructions: [Instruction]
    }

    struct Instruction: Decodable, Sendable {
        let programId: String
        let program: String?
        /// Objeto `{type, info}` nos programas que o no sabe ler; texto no Memo.
        let parsed: JSONValue?
    }

    struct AccountKey: Decodable, Sendable {
        let pubkey: String
        let signer: Bool
        let writable: Bool
    }

    struct Message: Decodable, Sendable {
        let accountKeys: [AccountKey]
        let instructions: [Instruction]
    }

    struct Transaction: Decodable, Sendable {
        let signatures: [String]
        let message: Message
    }

    let slot: UInt64
    let blockTime: Int64?
    let meta: Meta?
    let transaction: Transaction
}

// MARK: Leitura

/// O historico recente de uma conta.
public actor SolanaHistoryReader {
    /// Com os provedores que guardam historico (`Endpoints.solanaHistory`), nunca o
    /// pool geral de saldo.
    public static let shared = SolanaHistoryReader(reader: SolanaNetworkReader(providers: Endpoints.solanaHistory))

    let reader: SolanaNetworkReader
    /// Quantas transacoes buscar em paralelo (os RPCs publicos limitam por IP).
    static let concurrency = 4

    public init(reader: SolanaNetworkReader = .shared) {
        self.reader = reader
    }

    /// O ATA do dono em cada mint da lista (programa Token classico: todos os mints da
    /// lista sao dele, e o teste da lista confere).
    static func listedTokenAccounts(owner: SolanaPublicKey) -> [SolanaPublicKey] {
        TokenRegistry.assets(on: .solana).compactMap { token in
            guard case .token(let contract) = token.kind, let mint = try? SolanaPublicKey(base58: contract) else { return nil }
            return try? SolanaAssociatedToken.address(owner: owner, mint: mint, tokenProgram: .token)
        }
    }

    /// Das contas pedidas, as que existem, em lotes de 100 (o teto da
    /// `getMultipleAccounts`). Lote que falha nao entra: o historico da carteira sai do
    /// mesmo jeito, sem os recebimentos daqueles tokens.
    static func existingAccounts(_ accounts: [SolanaPublicKey], reader: SolanaNetworkReader) async -> [SolanaPublicKey] {
        var existing = [SolanaPublicKey]()
        for start in stride(from: 0, to: accounts.count, by: 100) {
            let chunk = Array(accounts[start..<min(start + 100, accounts.count)])
            guard let snapshots = try? await reader.snapshots(chunk) else { continue }
            existing += snapshots.filter(\.exists).map(\.address)
        }
        return existing
    }

    /// As ultimas `limit` transacoes do dono. Recebimento de token da lista nao cita
    /// a carteira, so o ATA dela: por isso as assinaturas vem da carteira e dos ATAs
    /// dos tokens da lista, juntas por slot. `knownAddresses` (contatos, as proprias
    /// contas) tira a marca de poeira de quem o dono conhece.
    ///
    /// So os ATAs que existem entram: uma `getMultipleAccounts` diz quais, e a lista
    /// curada pode crescer sem que cada token some uma `getSignaturesForAddress` a cada
    /// abertura do historico. ATA fechado sai da busca; o fechamento e os envios foram
    /// assinados pelo dono e aparecem pelas assinaturas da propria carteira.
    public func recentActivity(owner: SolanaPublicKey, limit: Int = 30, before: String? = nil, knownAddresses: Set<String> = []) async throws -> [SolanaActivity] {
        var addresses = [owner]
        addresses += await Self.existingAccounts(Self.listedTokenAccounts(owner: owner), reader: reader)
        var config: [String: JSONValue] = ["limit": .number(Double(limit)), "commitment": .string("confirmed")]
        if let before { config["before"] = .string(before) }
        var infos = [String: RPCSignatureInfo]()
        for (index, address) in addresses.enumerated() {
            do {
                let list: [RPCSignatureInfo] = try await reader.call("getSignaturesForAddress", [.string(address.base58), .object(config)])
                for info in list { infos[info.signature] = info }
            } catch where index > 0 {
                continue  // ATA de token: melhor mostrar o resto do que nada
            }
        }
        let selected = infos.values.sorted { ($0.slot, $0.signature) > ($1.slot, $1.signature) }.prefix(limit)

        var transactions = [(RPCSignatureInfo, RPCTransaction)]()
        let reader = self.reader
        for chunk in Array(selected).chunked(Self.concurrency) {
            let fetched = await withTaskGroup(of: (RPCSignatureInfo, RPCTransaction?).self) { group in
                for info in chunk {
                    group.addTask {
                        let tx: RPCTransaction? = try? await reader.callOptionalTransaction(info.signature)
                        return (info, tx)
                    }
                }
                var all = [(RPCSignatureInfo, RPCTransaction?)]()
                for await item in group { all.append(item) }
                return all
            }
            for case let (info, tx?) in fetched { transactions.append((info, tx)) }
        }
        // Havia transacoes e nenhuma veio: o provedor cortou. Lista vazia aqui diria
        // "nenhum movimento"; o erro faz a tela dizer que nao leu e tentar de novo.
        if !selected.isEmpty, transactions.isEmpty { throw HTTPClient.Failure.offline }
        transactions.sort { ($0.0.slot, $0.0.signature) > ($1.0.slot, $1.0.signature) }
        return Self.activities(transactions, owner: owner, knownAddresses: knownAddresses)
    }

    /// Duas passadas: quem recebeu envio do dono passa a ser conhecido.
    static func activities(_ transactions: [(RPCSignatureInfo, RPCTransaction)], owner: SolanaPublicKey, knownAddresses: Set<String>) -> [SolanaActivity] {
        func parse(_ known: Set<String>) -> [SolanaActivity] {
            transactions.compactMap { SolanaActivityParser.activity($0.1, owner: owner, confirmationStatus: $0.0.confirmationStatus, knownAddresses: known) }
        }
        let first = parse(knownAddresses)
        let paid = Set(first.filter { $0.direction == .outgoing && !$0.isSuspicious }.compactMap(\.counterparty))
        return paid.isEmpty ? first : parse(knownAddresses.union(paid))
    }
}

extension SolanaNetworkReader {
    func callOptionalTransaction(_ signature: String) async throws -> RPCTransaction? {
        let client = self.client
        let params: [JSONValue] = [
            .string(signature),
            .object(["encoding": .string("jsonParsed"), "maxSupportedTransactionVersion": .number(0), "commitment": .string("confirmed")]),
        ]
        return try await pool.first { provider in
            try await SolanaRPC.callOptional(provider.baseURL, "getTransaction", params, as: RPCTransaction.self, client: client)
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: Swift.max(1, size)).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
