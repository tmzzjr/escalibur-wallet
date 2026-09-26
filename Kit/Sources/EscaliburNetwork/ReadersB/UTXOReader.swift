import EscaliburChains
import EscaliburCore
import Foundation

/// Leitura de estado, transmissao e historico de Bitcoin, Litecoin e Dogecoin.
///
/// Provedores, na ordem de preferencia (`UTXOReader.providers(for:)`):
/// - Bitcoin: mempool.space, blockstream.info e mempool.emzy.de, todos Esplora.
/// - Litecoin: litecoinspace.org (Esplora), com Blockcypher e Blockchair como segunda
///   e terceira fonte de taxa, rota extra de transmissao e contingencia de leitura.
/// - Dogecoin: Blockcypher e Blockchair.
///
/// O que o leitor confere, e por que:
/// - enderecos saem da xpub **aqui**; o provedor so ve endereco, um por vez;
/// - cada moeda vem com a transacao anterior inteira, e `UTXOPreviousOutput.verify`
///   prova o valor pelo txid; a saida tem de pagar o script da chave derivada;
/// - taxa de pelo menos duas fontes que nao discordem mais de 3x, cada nivel pelo menor
///   de duas ou pela mediana de tres (`UTXOFeeConsensus`), sob o teto compilado;
/// - transmissao dos mesmos bytes em todos os provedores, com o txid calculado local.
public struct UTXOReader: Sendable {
    public let chain: Chain
    let pool: ProviderPool
    let transport: ChainReaderTransport

    /// Teto de enderecos varridos por cadeia (recebimento ou troco). Uma conta real
    /// nao chega perto; um provedor que diz "usado" para tudo nao prende o app.
    public static let maxAddressesPerBranch: UInt32 = 2_000
    /// Diferenca maxima de altura entre dois provedores (propagacao de bloco).
    static let tipTolerance: UInt32 = 3
    /// Requisicoes simultaneas por leitura.
    static let parallelism = 4

    public init(chain: Chain, transport: ChainReaderTransport = HTTPReaderTransport(), providers: [ProviderPool.Provider]? = nil) throws {
        guard chain.family == .utxo else { throw ChainReaderError.unsupportedAccount }
        self.chain = chain
        self.transport = transport
        self.pool = ProviderPool(providers ?? Self.providers(for: chain))
    }

    public static func providers(for chain: Chain) -> [ProviderPool.Provider] {
        switch chain.id {
        case Chain.dogecoin.id: return Endpoints.dogecoin
        case Chain.litecoin.id: return (Endpoints.esplora["litecoin"] ?? []) + Endpoints.litecoinExtra
        default: return Endpoints.esplora[chain.id] ?? []
        }
    }

    // MARK: Provedores

    private func client(_ provider: ProviderPool.Provider) -> UTXOProviderClient {
        UTXOProviderClient(provider: provider, transport: transport)
    }

    /// Tenta os provedores em ordem ate um responder.
    ///
    /// `spread` gira a ordem entre os provedores Esplora do topo da lista: cada um ve
    /// so parte dos enderecos da conta, em vez de um so ver todos. Nao substitui no
    /// proprio, mas corta o que cada provedor consegue ligar sozinho (§1.6).
    private func withProvider<T: Sendable>(
        spread: Int? = nil, _ operation: @Sendable (UTXOProviderClient) async throws -> T
    ) async throws -> T {
        var providers = await pool.available()
        if let spread {
            let leading = providers.prefix { if case .esplora = UTXOBackend.of($0) { return true } else { return false } }.count
            if leading > 1 {
                let shift = spread % leading
                providers = Array(providers[shift..<leading] + providers[..<shift] + providers[leading...])
            }
        }
        var lastError: Error = HTTPClient.Failure.offline
        for provider in providers {
            do {
                let value = try await operation(client(provider))
                await pool.reportSuccess(provider)
                return value
            } catch {
                await pool.reportFailure(provider)
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: Descoberta

    /// Varre recebimento (cadeia 0) e troco (cadeia 1) ate `gapLimit` enderecos
    /// seguidos sem historico em cada uma (BIP-44). Deriva localmente e consulta um
    /// endereco por vez; a xpub nunca sai do aparelho.
    ///
    /// `knownUsed`: caminhos que o app ja sabe usados (varreduras anteriores). Historico
    /// nao some, entao nao sao consultados de novo.
    public func discover(_ account: UTXOAccount, gapLimit: Int = 20, knownUsed: Set<DerivationPath> = []) async throws -> UTXODiscovery {
        guard account.chain == chain else { throw ChainReaderError.unsupportedAccount }
        guard (1...100).contains(gapLimit) else { throw ChainReaderError.invalidGapLimit }
        var used: [UTXODerivedAddress] = []
        var scanned: [UTXODerivedAddress] = []
        var firstUnused: [Bool: UTXODerivedAddress] = [:]

        for change in [false, true] {
            var index: UInt32 = 0
            var trailingUnused = 0
            while trailingUnused < gapLimit {
                // Nunca pergunta mais do que falta para fechar o gap.
                let size = min(gapLimit - trailingUnused, Self.parallelism)
                guard index + UInt32(size) <= Self.maxAddressesPerBranch else { throw ChainReaderError.tooManyAddresses }
                let batch = try (0..<size).map { try account.address(change: change, index: index + UInt32($0)) }
                let flags = try await ReaderConcurrency.map(batch, limit: Self.parallelism) { address in
                    if knownUsed.contains(address.path) { return true }
                    return try await self.withProvider(spread: Int(address.index)) { try await $0.transactionCount(address.address) > 0 }
                }
                for (address, isUsed) in zip(batch, flags) {
                    scanned.append(address)
                    if isUsed {
                        used.append(address)
                        trailingUnused = 0
                    } else {
                        trailingUnused += 1
                        if firstUnused[change] == nil { firstUnused[change] = address }
                    }
                }
                index += UInt32(size)
            }
        }
        // O laco so termina com gap cheio, entao as duas cadeias tem um livre.
        guard let nextReceive = firstUnused[false], let nextChange = firstUnused[true] else { throw ChainReaderError.tooManyAddresses }
        return UTXODiscovery(account: account, gapLimit: gapLimit, used: used, scanned: scanned, nextReceive: nextReceive, nextChange: nextChange)
    }

    // MARK: Moedas

    /// As moedas nao gastas dos enderecos, cada uma com a transacao anterior inteira.
    ///
    /// Para cada moeda: baixa `/tx/{txid}/hex`, confere o txid (`UTXOPreviousOutput.verify`),
    /// confere que a saida paga o script da chave derivada localmente e que o valor
    /// anunciado e o da saida. O que nao fecha vai para `rejected`, com o motivo.
    ///
    /// Poeira de desconhecidos (centenas de moedas minusculas mandadas por robos) nao
    /// pode travar o envio: moeda que vale menos que `minimumValue` nao e baixada, e so
    /// as `maxCoins` maiores sao conferidas. As duas ficam em `rejected` com o motivo.
    /// O valor que decide aqui e o anunciado pelo provedor; um provedor que mente para
    /// baixo so tira uma moeda desta leitura, e um que mente para cima cai na conferencia.
    public func coins(
        for addresses: [UTXODerivedAddress], minimumValue: UInt64 = 0, maxCoins: Int = UTXOReader.maxCoinsVerified
    ) async throws -> UTXOCoinReading {
        let tip = try await tipHeight()
        let everything = try await ReaderConcurrency.map(addresses, limit: Self.parallelism) { address in
            (address, try await self.withProvider(spread: Int(address.index)) { try await $0.unspent(address.address) })
        }
        let (listed, skipped) = Self.selectClaims(everything, minimumValue: minimumValue, maxCoins: maxCoins)

        var txids: [UTXOTxID] = []
        var seenTx = Set<UTXOTxID>()
        for (_, claims) in listed {
            for claim in claims where seenTx.insert(claim.outpoint.txid).inserted { txids.append(claim.outpoint.txid) }
        }
        let raws = try await ReaderConcurrency.map(txids, limit: Self.parallelism) { txid in
            (txid, await self.previousTransaction(txid))
        }
        let rawByTx = Dictionary(raws.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })

        var coins: [UTXOCoin] = []
        var rejected: [UTXORejectedCoin] = skipped
        var values: [UTXOOutpoint: UInt64] = [:]
        var seenCoin = Set<UTXOOutpoint>()
        for (address, claims) in listed {
            for claim in claims where seenCoin.insert(claim.outpoint).inserted {
                guard let raw = rawByTx[claim.outpoint.txid] ?? nil else {
                    rejected.append(UTXORejectedCoin(outpoint: claim.outpoint, reason: .previousTransactionUnavailable))
                    continue
                }
                let output: UTXOTxOut
                do {
                    output = try UTXOPreviousOutput.verify(previousTransaction: raw, outpoint: claim.outpoint)
                } catch let error as UTXOPlanError {
                    rejected.append(UTXORejectedCoin(outpoint: claim.outpoint, reason: Self.reason(error)))
                    continue
                }
                guard output.scriptPubKey == address.scriptPubKey else {
                    rejected.append(UTXORejectedCoin(outpoint: claim.outpoint, reason: .notOurScript))
                    continue
                }
                guard output.value == claim.claimedValue else {
                    rejected.append(UTXORejectedCoin(outpoint: claim.outpoint, reason: .claimedValueMismatch))
                    continue
                }
                let confirmations: UInt32 = claim.height.map { tip >= $0 ? tip - $0 + 1 : 1 } ?? 0
                coins.append(UTXOCoin(
                    outpoint: claim.outpoint, previousTransaction: raw, confirmations: confirmations,
                    path: address.path, publicKey: address.publicKey
                ))
                values[claim.outpoint] = output.value
            }
        }
        return UTXOCoinReading(coins: coins, rejected: rejected, tipHeight: tip, values: values)
    }

    /// Teto de moedas conferidas numa leitura. Cada uma custa uma transacao anterior
    /// baixada; 200 cobre qualquer carteira de uso pessoal e ainda termina em segundos.
    public static let maxCoinsVerified = 200

    /// Separa o que vale conferir: acima do minimo, as maiores primeiro, ate o teto.
    static func selectClaims(
        _ listed: [(UTXODerivedAddress, [UTXOUnspentClaim])], minimumValue: UInt64, maxCoins: Int
    ) -> (kept: [(UTXODerivedAddress, [UTXOUnspentClaim])], skipped: [UTXORejectedCoin]) {
        var skipped: [UTXORejectedCoin] = []
        var candidates: [(address: Int, claim: UTXOUnspentClaim)] = []
        for (position, entry) in listed.enumerated() {
            for claim in entry.1 {
                if claim.claimedValue < minimumValue {
                    skipped.append(UTXORejectedCoin(outpoint: claim.outpoint, reason: .uneconomic))
                } else {
                    candidates.append((position, claim))
                }
            }
        }
        candidates.sort { $0.claim.claimedValue > $1.claim.claimedValue }
        for extra in candidates.dropFirst(maxCoins) {
            skipped.append(UTXORejectedCoin(outpoint: extra.claim.outpoint, reason: .overLimit))
        }
        var kept = listed.map { ($0.0, [UTXOUnspentClaim]()) }
        for chosen in candidates.prefix(maxCoins) { kept[chosen.address].1.append(chosen.claim) }
        return (kept, skipped)
    }

    /// A transacao anterior de um provedor cujo txid bate. Se nenhum entregar uma que
    /// bata, devolve a que veio (para a conferencia recusar com o motivo certo).
    private func previousTransaction(_ txid: UTXOTxID) async -> [UInt8]? {
        var fallback: [UInt8]?
        for provider in await pool.available() {
            guard let raw = try? await client(provider).rawTransaction(txid) else {
                await pool.reportFailure(provider)
                continue
            }
            if (try? UTXOTransaction(parsing: raw))?.txid == txid {
                await pool.reportSuccess(provider)
                return raw
            }
            await pool.reportFailure(provider)
            fallback = fallback ?? raw
        }
        return fallback
    }

    static func reason(_ error: UTXOPlanError) -> UTXORejectedCoin.Reason {
        switch error {
        case .previousTransactionMismatch: return .previousTransactionMismatch
        case .outputIndexOutOfRange: return .outputIndexOutOfRange
        default: return .previousTransactionMalformed
        }
    }

    // MARK: Rede

    /// Altura do ultimo bloco. Pergunta a todos; se mais de um responder, tem de
    /// estar a ate 3 blocos um do outro, e vale a menor: nLockTime acima da altura
    /// real deixaria a transacao presa ate la.
    public func tipHeight() async throws -> UInt32 {
        let providers = await pool.available()
        let answers = try await ReaderConcurrency.map(providers, limit: Self.parallelism) { provider in
            try? await self.client(provider).tipHeight()
        }.compactMap { $0 }
        guard let low = answers.min(), let high = answers.max() else { throw HTTPClient.Failure.offline }
        guard high - low <= Self.tipTolerance else { throw ChainReaderError.providersDisagree }
        return low
    }

    /// Taxa em tres niveis pela regra de `UTXOFeeConsensus`, com o piso da rede.
    ///
    /// Fontes: Bitcoin, `/v1/fees/precise` do mempool.space e do emzy e `/fee-estimates`
    /// da Blockstream; Litecoin, `/v1/fees/precise` do litecoinspace, o `high/medium/
    /// low_fee_per_kb` da Blockcypher e o sugerido da Blockchair; Dogecoin, Blockcypher
    /// e Blockchair. Exige duas que nao discordem mais de 3x; com duas, cada nivel e o
    /// menor delas, e com tres ou mais, a mediana. O teto e compilado (`UTXORules`).
    public func feeLevels() async throws -> UTXOFeeLevels {
        let providers = await pool.available()
        let quotes = try await ReaderConcurrency.map(providers, limit: Self.parallelism) { provider in
            try? await self.client(provider).fees()
        }.compactMap { $0 }
        guard quotes.count >= 2 else { throw ChainReaderError.notEnoughSources(needed: 2, got: quotes.count) }
        return try Self.combine(quotes, rules: UTXORules.for(chain))
    }

    static func combine(_ quotes: [UTXOFeeQuote], rules: UTXORules) throws -> UTXOFeeLevels {
        do {
            try UTXOFeeConsensus.check(quotes.map(\.fastest), rules: rules)
        } catch UTXOPlanError.feeEstimatesDisagree {
            throw ChainReaderError.providersDisagree
        }
        // Fonte de numero unico vale o mesmo numero em todos os niveis.
        let levels = quotes.map { $0.levels ?? ($0.fastest, $0.fastest, $0.fastest) }
        let minimum = rules.minimumFeeRate
        let slow = max(UTXOFeeConsensus.level(levels.map(\.slow)) ?? minimum, minimum)
        let normal = max(UTXOFeeConsensus.level(levels.map(\.normal)) ?? slow, slow)
        let fast = max(UTXOFeeConsensus.level(levels.map(\.fast)) ?? normal, normal)
        return UTXOFeeLevels(slow: slow, normal: normal, fast: fast, estimates: quotes.map(\.fastest), sources: quotes.map(\.source))
    }

    /// Moedas, taxas, altura e troco: o que `UTXOPlanner.planSend` pede.
    public func spendState(_ discovery: UTXODiscovery) async throws -> UTXOSpendState {
        guard discovery.account.chain == chain else { throw ChainReaderError.unsupportedAccount }
        // A taxa vem antes: e ela que diz o que e poeira agora (moeda que nao paga a
        // propria entrada na taxa rapida).
        let levels = try await feeLevels()
        let minimum = levels.fast.fee(weight: discovery.account.kind.inputWeight)
        let coins = try await coins(for: discovery.used, minimumValue: minimum)
        return UTXOSpendState(
            network: UTXONetworkState(coins: coins.coins, feeEstimates: levels.estimates, tipHeight: coins.tipHeight),
            change: discovery.changeAddress, fees: levels, rejected: coins.rejected
        )
    }

    // MARK: Transmissao

    /// Transmite os **mesmos bytes** em todos os provedores (pelo menos dois).
    ///
    /// Antes, confere que a transacao assinada fecha: rede certa, hex igual aos bytes,
    /// bytes canonicos e txid calculado deles igual ao `id`. O txid que cada provedor
    /// devolve tem de ser esse; provedor que devolve outro conta como recusa.
    public func broadcast(_ signed: SignedTransaction) async throws -> UTXOBroadcastReceipt {
        guard signed.chainID == chain.id, Hex.encode(signed.raw) == signed.encoded,
              let tx = try? UTXOTransaction(parsing: signed.raw), tx.serialized() == signed.raw,
              tx.txid.hex == signed.id
        else { throw ChainReaderError.signedTransactionInconsistent }
        let providers = pool.providers
        guard providers.count >= 2 else { throw ChainReaderError.notEnoughSources(needed: 2, got: providers.count) }
        let hex = signed.encoded
        let results = try await ReaderConcurrency.map(providers, limit: providers.count) { provider in
            (provider, (try? await self.client(provider).broadcast(hex: hex))?.lowercased() == signed.id)
        }
        var accepted: [String] = []
        var refused: [String] = []
        for (provider, ok) in results {
            if ok {
                accepted.append(provider.name)
                await pool.reportSuccess(provider)
            } else {
                refused.append(provider.name)
            }
        }
        guard !accepted.isEmpty else { throw ChainReaderError.broadcastRejected }
        return UTXOBroadcastReceipt(txid: signed.id, acceptedBy: accepted, rejectedBy: refused)
    }

    /// Onde a transacao esta, na opiniao de dois provedores quando ha dois
    /// (`ChainTransactionStatus.combine`): confirmada so se os dois confirmam.
    public func status(txid: String) async throws -> ChainTransactionStatus {
        guard let id = UTXOTxID(hex: txid.lowercased()) else { throw ChainReaderError.signedTransactionInconsistent }
        let tip = try? await tipHeight()
        var answers: [ChainTransactionStatus] = []
        for provider in await pool.available() where answers.count < 2 {
            if let answer = try? await client(provider).status(id, tip: tip) {
                answers.append(answer)
                await pool.reportSuccess(provider)
            } else {
                await pool.reportFailure(provider)
            }
        }
        guard let first = answers.first else { throw HTTPClient.Failure.offline }
        return answers.count == 2 ? try ChainTransactionStatus.combine(first, answers[1]) : first
    }

    // MARK: Historico

    /// As ultimas transacoes da conta, com o efeito liquido na carteira.
    ///
    /// Consulta o historico de cada endereco usado e junta por txid. No Esplora a
    /// transacao vem inteira, e "nosso" e qualquer script da janela varrida: o efeito
    /// e o que entrou nos nossos scripts menos o que saiu deles. No Blockcypher e no
    /// Blockchair so ha o efeito por endereco, somado.
    ///
    /// Recebimento de ate `protectionThreshold` (1.000 sat no Bitcoin, o dust no
    /// Dogecoin) de quem a carteira nunca pagou sai marcado como poeira.
    /// `knownCounterparties`: enderecos para os quais o dono ja enviou (catalogo).
    public func history(_ discovery: UTXODiscovery, limit: Int = 30, knownCounterparties: Set<String> = []) async throws -> [ChainActivity] {
        guard discovery.account.chain == chain else { throw ChainReaderError.unsupportedAccount }
        let tip = try? await tipHeight()
        let pages = try await ReaderConcurrency.map(discovery.used, limit: Self.parallelism) { address in
            try await self.withProvider(spread: Int(address.index)) { try await $0.history(address.address) }
        }
        let ours = Set(discovery.scanned.map(\.scriptPubKey))
        let threshold = UTXORules.for(chain).protectionThreshold(for: discovery.account.kind, chain: chain)
        return Self.activities(
            pages: pages, ours: ours, chain: chain, tip: tip, threshold: threshold,
            limit: limit, knownCounterparties: knownCounterparties
        )
    }

    static func activities(
        pages: [UTXOHistoryPage], ours: Set<[UInt8]>, chain: Chain, tip: UInt32?, threshold: UInt64,
        limit: Int, knownCounterparties: Set<String>
    ) -> [ChainActivity] {
        var full: [String: EsploraTransaction] = [:]
        var deltas: [String: UTXOAddressDelta] = [:]
        for page in pages {
            switch page {
            case .full(let txs):
                for tx in txs { full[tx.txid] = tx }
            case .deltas(let list):
                for delta in list {
                    let previous = deltas[delta.txid]
                    deltas[delta.txid] = UTXOAddressDelta(
                        txid: delta.txid, height: delta.height ?? previous?.height, date: delta.date ?? previous?.date,
                        received: (previous?.received ?? 0) &+ delta.received, spent: (previous?.spent ?? 0) &+ delta.spent
                    )
                }
            }
        }

        /// O efeito de uma transacao na carteira.
        struct Draft {
            let txid: String
            let height: UInt32?
            let date: Date?
            /// Quanto entrou nos nossos scripts e quanto saiu deles.
            let received: UInt64
            let spent: UInt64
            /// A taxa, so quando todas as entradas sao nossas (foi a carteira que pagou).
            let fee: UInt64?
            /// Alguma saida com valor vai para fora da carteira (Esplora; nil quando nao se sabe).
            let paysOutside: Bool?
            let outsideOutput: String?
            let outsideInput: String?
        }
        var drafts: [Draft] = []
        for tx in full.values {
            guard (try? ReaderDecode.txid(tx.txid, field: "txid")) != nil else { continue }
            let mine: (EsploraTransaction.Output) -> Bool = { output in
                Hex.decode(output.scriptpubkey).map { ours.contains($0) } ?? false
            }
            let prevouts = tx.vin.compactMap(\.prevout)
            let received = tx.vout.filter(mine).reduce(UInt64(0)) { $0 &+ $1.value }
            let spent = prevouts.filter(mine).reduce(UInt64(0)) { $0 &+ $1.value }
            let allInputsOurs = !prevouts.isEmpty && prevouts.count == tx.vin.count && prevouts.allSatisfy(mine)
            let others = tx.vout.filter { !mine($0) }
            drafts.append(Draft(
                txid: tx.txid, height: tx.status.confirmed ? tx.status.blockHeight : nil,
                date: tx.status.blockTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                received: received, spent: spent, fee: allInputsOurs ? tx.fee : nil,
                // Saida de valor zero (OP_RETURN) nao leva nada para fora: so a taxa saiu.
                paysOutside: others.contains { $0.value > 0 },
                outsideOutput: others.filter { $0.value > 0 }.compactMap(\.scriptpubkeyAddress).first,
                outsideInput: prevouts.first { !mine($0) }?.scriptpubkeyAddress
            ))
        }
        for delta in deltas.values where full[delta.txid] == nil {
            drafts.append(Draft(
                txid: delta.txid, height: delta.height, date: delta.date, received: delta.received, spent: delta.spent,
                fee: nil, paysOutside: nil, outsideOutput: nil, outsideInput: nil
            ))
        }

        // Quem a carteira ja pagou deixa de ser desconhecido.
        var known = knownCounterparties
        for draft in drafts where draft.spent > draft.received { if let to = draft.outsideOutput { known.insert(to) } }

        var items: [ChainActivity] = []
        for draft in drafts {
            let status: ChainActivity.Status = draft.height.map { height in
                .confirmed(confirmations: tip.flatMap { $0 >= height ? $0 - height + 1 : nil })
            } ?? .pending
            var kind = ChainActivity.Kind.receive
            var movement: ChainActivity.Movement?
            var suspicion: ChainActivity.Suspicion?
            var counterparty: String?
            var fee: UInt64?
            if draft.spent > draft.received {
                // Efeito liquido negativo. Com a taxa conhecida (todas as entradas nossas),
                // o valor e o que foi para fora e a taxa aparece a parte; sem ela (entradas
                // de terceiros, ou provedor que so da o saldo), o valor e a perda liquida.
                let loss = draft.spent - draft.received
                let outgoing = draft.fee.map { loss > $0 ? loss - $0 : 0 } ?? loss
                fee = draft.fee
                counterparty = draft.outsideOutput
                if draft.paysOutside == false {
                    kind = .selfTransfer
                } else {
                    kind = .send
                    movement = ChainActivity.Movement(asset: .native, amount: BigUInt(outgoing), incoming: false)
                }
            } else if draft.spent > 0, draft.received == draft.spent {
                kind = .selfTransfer
            } else {
                let gain = draft.received - draft.spent
                movement = ChainActivity.Movement(asset: .native, amount: BigUInt(gain), incoming: true)
                counterparty = draft.outsideInput
                if draft.spent == 0, gain <= threshold, !(counterparty.map(known.contains) ?? false) {
                    suspicion = .dust
                }
            }
            items.append(ChainActivity(
                id: draft.txid, chainID: chain.id, transactionHash: draft.txid, kind: kind,
                movements: movement.map { [$0] } ?? [],
                fee: fee.map { BigUInt($0) },
                counterparty: counterparty, date: draft.date, status: status, suspicion: suspicion
            ))
        }
        // Pendentes primeiro, depois do bloco mais novo para o mais velho.
        let heights = Dictionary(drafts.map { ($0.txid, $0.height) }, uniquingKeysWith: { a, _ in a })
        items.sort { a, b in
            let ha = heights[a.id] ?? nil, hb = heights[b.id] ?? nil
            switch (ha, hb) {
            case (nil, nil): return a.id < b.id
            case (nil, _): return true
            case (_, nil): return false
            case (let x?, let y?): return x != y ? x > y : a.id < b.id
            }
        }
        return Array(items.prefix(max(0, limit)))
    }
}
