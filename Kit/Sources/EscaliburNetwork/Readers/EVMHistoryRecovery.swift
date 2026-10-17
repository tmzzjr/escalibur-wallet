import EscaliburChains
import EscaliburCore
import Foundation

// O que a Alchemy nao lista no historico da BNB Chain, recuperado com a mesma chave e o
// mesmo host, sem trace.
//
// - O plano gratuito da Alchemy nao tem trace nem debug na BNB: `trace_transaction`,
//   `trace_filter`, `trace_block`, `trace_replayTransaction`, `debug_traceTransaction`,
//   `debug_traceBlockByNumber` e `debug_traceCall` respondem -32600 ("not available on
//   the Free tier"), a categoria `internal` de `alchemy_getAssetTransfers` e recusada e
//   `eth_getTransactionBySenderAndNonce` cai em estado podado (conferido em 16/10/2026).
//   O estado antigo da rede, sim: `eth_getBalance` e `eth_getTransactionCount` num bloco
//   de 60 milhoes de blocos atras respondem.
// - Falhas do dono: o nonce conta toda transacao que ele assinou; a lista da Alchemy, so
//   as que deram certo. A diferenca, dentro da janela que a pagina mostra, e procurada
//   pelo nonce, bloco a bloco por busca binaria, da ponta para tras; o bloco achado diz
//   qual transacao e, e o recibo da o status e a taxa.
// - BNB mandado por contrato numa transacao do dono (a volta de uma troca de token por
//   BNB, o saque de WBNB): o saldo no fim do bloco, menos o do bloco anterior, mais o que
//   se sabe que saiu, menos o que se sabe que entrou. So em bloco com uma transacao do
//   dono que deu certo e com todas as dele conhecidas.
// - Conta com codigo (delegacao EIP-7702) fica de fora: o nonce dela sobe sem transacao
//   do dono (autorizacao), e o saldo mexe sem ela.
// - Tetos por leitura e memoria da sessao. Nada daqui derruba a pagina: resposta que
//   faltar deixa a pagina como a Alchemy entregou, marcada como parcial quando se sabe
//   que ficou transacao do dono sem achar.

/// O que a sessao ja sabe de uma conta: o nonce por bloco (estado antigo nao muda), as
/// transacoes do dono achadas fora da lista e o BNB recuperado de cada envio.
struct AlchemyRecoveryMemo: Sendable {
    var nonces: [UInt64: UInt64] = [:]
    var located: [String: LocatedTransaction] = [:]
    /// Por hash do envio; zero quando a conta do bloco nao deu nada.
    var internals: [String: BigUInt] = [:]
}

/// Uma transacao do dono que a lista da Alchemy nao trouxe, achada pelo nonce.
struct LocatedTransaction: Sendable, Equatable {
    let hash: String
    let block: UInt64
    let date: Date
    let success: Bool
    let to: EVMAddress?
    let value: BigUInt
    let fee: BigUInt
}

/// O que volta para a pagina.
struct AlchemyRecovered: Sendable {
    var rows: [EVMReader.TransactionRow] = []
    var internals: [EVMReader.InternalRow] = []
    /// Sabe-se que ficou transacao do dono na janela sem achar (teto ou resposta que
    /// faltou).
    var incomplete = false

    var isEmpty: Bool { rows.isEmpty && internals.isEmpty && !incomplete }
}

extension EVMReader {
    /// Onde a recuperacao roda. As outras redes da Alchemy tem a mesma lacuna; so a BNB
    /// foi conferida.
    static let alchemyRecoveryChains: Set<String> = ["bnb"]
    /// Tetos por leitura: consultas de nonce da busca, blocos baixados e blocos com a
    /// conta do saldo. Um bloco da BNB inteiro tem de 40 a 240 KB (16/10/2026).
    static let recoveryNonceProbes = 48
    static let recoveryBlocks = 4
    static let recoveryBalanceBlocks = 10
    /// Teto da memoria de nonces por conta.
    static let recoveryNonceMemo = 2048

    /// Um envio do dono que a Alchemy listou.
    struct AlchemySend: Sendable, Equatable {
        let hash: String
        let block: UInt64
        let date: Date
        let to: EVMAddress?
        let value: BigUInt
    }

    // MARK: Leitura das listas

    static func alchemySends(_ json: StrictJSON) throws -> (sends: [AlchemySend], floor: UInt64?) {
        let items = try json.field("transfers", "sent").array("sent.transfers")
        var sends: [AlchemySend] = []
        var seen = Set<String>()
        for (offset, item) in items.enumerated() {
            let path = "sent[\(offset)]"
            let hash = try item.field("hash", path).string(path + ".hash").lowercased()
            guard seen.insert(hash).inserted else { continue }
            let text = try item.field("metadata", path).field("blockTimestamp", path + ".metadata").string(path + ".metadata.blockTimestamp")
            sends.append(AlchemySend(
                hash: hash, block: try block(item.field("blockNum", path), path + ".blockNum"),
                date: try isoDate(text, path + ".metadata.blockTimestamp"),
                to: try item.optionalField("to").map { try address($0, path + ".to") },
                value: try item.field("rawContract", path).field("value", path + ".rawContract").quantity(path + ".rawContract.value")
            ))
        }
        return (sends, try listFloor(json, items: items, "sent"))
    }

    /// O BNB que entrou por transacao de topo, somado por bloco.
    static func alchemyIncoming(_ json: StrictJSON) throws -> (byBlock: [UInt64: BigUInt], floor: UInt64?) {
        let items = try json.field("transfers", "received").array("received.transfers")
        var byBlock: [UInt64: BigUInt] = [:]
        for (offset, item) in items.enumerated() {
            let path = "received[\(offset)]"
            let number = try block(item.field("blockNum", path), path + ".blockNum")
            let value = try item.field("rawContract", path).field("value", path + ".rawContract").quantity(path + ".rawContract.value")
            byBlock[number, default: 0] = byBlock[number, default: 0] + value
        }
        return (byBlock, try listFloor(json, items: items, "received"))
    }

    /// O bloco de cada hash de qualquer lista, para achar onde a pagina comeca. Item fora
    /// do formato fica de fora.
    static func alchemyBlockIndex(_ lists: [StrictJSON]) -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        for list in lists {
            for item in (try? list.field("transfers", "lista").array("lista.transfers")) ?? [] {
                guard let hash = try? item.field("hash", "item").string("item.hash").lowercased(),
                      let number = try? block(item.field("blockNum", "item"), "item.blockNum")
                else { continue }
                out[hash] = min(out[hash] ?? number, number)
            }
        }
        return out
    }

    /// Lista cortada (veio `pageKey`): o bloco do item mais antigo; abaixo dele a lista nao
    /// diz nada. Lista inteira: `nil`.
    static func listFloor(_ json: StrictJSON, items: [StrictJSON], _ path: String) throws -> UInt64? {
        guard json.optionalField("pageKey") != nil else { return nil }
        return try items.enumerated().map { try block($0.element.field("blockNum", path), path + "[\($0.offset)].blockNum") }.min()
    }

    static func block(_ json: StrictJSON, _ path: String) throws -> UInt64 {
        guard let value = try json.quantity(path).uint64, value < 1 << 48 else { throw ReaderError.malformed(field: path) }
        return value
    }

    static func hexBlock(_ number: UInt64) -> String {
        "0x" + String(number, radix: 16)
    }

    // MARK: Lote

    /// Um lote JSON-RPC: cada pedido vai com o `id` da posicao, e a resposta volta por
    /// `id`. Pedido com erro fica de fora; resposta que nao e lista e erro.
    static func batchCall(_ transport: ReaderTransport, _ url: URL, _ calls: [(method: String, params: [StrictJSON])]) async throws -> [Int: StrictJSON] {
        guard !calls.isEmpty else { return [:] }
        let body: StrictJSON = .array(calls.enumerated().map { id, call in
            .object(["jsonrpc": .string("2.0"), "id": .int(id), "method": .string(call.method), "params": .array(call.params)])
        })
        let answers = try StrictJSON.parse(try await transport.send(.post(url, body))).array("lote")
        var out: [Int: StrictJSON] = [:]
        for answer in answers {
            guard let id = (try? answer.field("id", "lote").uint64("lote.id")).flatMap({ Int(exactly: $0) }), id < calls.count,
                  answer.optionalField("error") == nil, let result = answer.objectValue?["result"]
            else { continue }
            out[id] = result
        }
        return out
    }

    // MARK: Bloco

    /// As transacoes do dono num bloco (`eth_getBlockByNumber` com as transacoes
    /// inteiras). So `from` e lido nas dos outros; nas do dono, hash, destino e valor.
    static func parseOwnerTransactions(_ json: StrictJSON, owner: EVMAddress) throws -> (date: Date, transactions: [(hash: String, to: EVMAddress?, value: BigUInt)]) {
        let date = try unixDate(try json.field("timestamp", "bloco").quantity("bloco.timestamp"), "bloco.timestamp")
        var out: [(hash: String, to: EVMAddress?, value: BigUInt)] = []
        for (offset, item) in try json.field("transactions", "bloco").array("bloco.transactions").enumerated() {
            let path = "bloco.transactions[\(offset)]"
            guard try address(item.field("from", path), path + ".from") == owner else { continue }
            out.append((
                hash: try item.field("hash", path).string(path + ".hash").lowercased(),
                to: try item.optionalField("to").map { try address($0, path + ".to") },
                value: try item.field("value", path).quantity(path + ".value")
            ))
        }
        return (date, out)
    }

    // MARK: Recuperacao

    /// As falhas do dono e o BNB que um contrato mandou para ele, na janela que `page`
    /// mostra. `receipts`: o lote de recibos dos envios listados, que ja foi feito.
    func recoverAlchemyHistory(
        chain: Chain, owner: EVMAddress, url: URL, sent: StrictJSON, received: StrictJSON, tokenTransfers: [StrictJSON],
        receipts: [String: ReceiptFacts], page: ActivityPage
    ) async -> AlchemyRecovered {
        guard let sentList = try? Self.alchemySends(sent), let receivedList = try? Self.alchemyIncoming(received) else {
            return AlchemyRecovered()
        }
        let sends = sentList.sends
        let transport = self.transport
        let ownerHex = StrictJSON.string(owner.checksummed)
        let key = chain.id + "|" + owner.checksummed.lowercased()
        var memo = recoveryMemos[key] ?? AlchemyRecoveryMemo()
        if memo.nonces.count > Self.recoveryNonceMemo { memo.nonces = [:] }
        defer { recoveryMemos[key] = memo }

        // A janela: o que a pagina mostra (pagina cheia: do item mais antigo em diante) e
        // o que a lista de envios cobre inteira.
        var window: UInt64 = 0
        if page.items.count >= ActivityRules.pageSize {
            let blocks = Self.alchemyBlockIndex([sent, received] + tokenTransfers)
            window = page.items.compactMap { blocks[$0.hash.lowercased()] }.min() ?? 0
        }
        window = max(window, sentList.floor ?? 0)

        // Conta com codigo fica de fora; o nonce de agora e o de antes da janela, num lote.
        var detection: [(method: String, params: [StrictJSON])] = [
            ("eth_getTransactionCount", [ownerHex, .string("latest")]),
            ("eth_getCode", [ownerHex, .string("latest")]),
        ]
        if window > 0 { detection.append(("eth_getTransactionCount", [ownerHex, .string(Self.hexBlock(window - 1))])) }
        guard let answers = try? await Self.batchCall(transport, url, detection),
              let nowText = answers[0], let now = try? nowText.quantity("nonce").uint64,
              let code = try? answers[1]?.hexData("code"), code.isEmpty
        else { return AlchemyRecovered() }
        let start: UInt64
        if window > 0 {
            guard let probed = try? answers[2]?.quantity("nonce").uint64 else { return AlchemyRecovered() }
            start = probed
        } else {
            start = 0
        }

        // As transacoes do dono conhecidas na janela: as listadas e as ja achadas.
        var known: [String: UInt64] = [:]
        for send in sends where send.block >= window { known[send.hash] = send.block }
        for tx in memo.located.values where tx.block >= window { known[tx.hash] = tx.block }
        guard now >= start, Int(now - start) >= known.count else { return AlchemyRecovered() }

        var recovered = AlchemyRecovered()
        var located = memo.located.filter { $0.value.block >= window }
        // Abaixo deste bloco ainda pode haver transacao do dono sem achar.
        var explained = window
        if Int(now - start) > known.count {
            let search = await Self.locate(
                transport: transport, owner: owner, url: url, window: window, start: start, known: known, memo: &memo
            )
            for tx in search.found { located[tx.hash] = tx }
            explained = search.explainedFrom
            recovered.incomplete = !search.complete
        }

        for tx in located.values.sorted(by: { $0.block > $1.block }) where !tx.success {
            recovered.rows.append(TransactionRow(
                hash: tx.hash, date: tx.date, status: .failed, from: owner, to: tx.to, value: tx.value, fee: tx.fee
            ))
        }

        await balanceBlocks(
            owner: owner, url: url, sends: sends.filter { $0.block >= max(window, explained, receivedList.floor ?? 0) },
            located: Array(located.values), receipts: receipts, incoming: receivedList.byBlock, memo: &memo
        )
        for send in sends where send.block >= window {
            guard let value = memo.internals[send.hash], !value.isZero, let contract = send.to else { continue }
            recovered.internals.append(InternalRow(
                hash: send.hash, index: "saldo", date: send.date, from: contract, to: owner, value: value
            ))
        }
        return recovered
    }

    /// O nonce do dono bloco a bloco, com teto de consultas e o que a sessao ja sabe.
    /// `g(b)` e o nonce no fim do bloco `b` menos as transacoes conhecidas da janela ate
    /// `b`: so sobe onde ha transacao do dono sem achar.
    struct NonceSearch: Sendable {
        let transport: ReaderTransport
        let url: URL
        let owner: StrictJSON
        let window: UInt64
        /// Estado de bloco ate aqui entra na memoria da sessao; o da ponta, nao.
        let settled: UInt64
        var known: [String: UInt64]
        var probesLeft: Int
        var nonces: [UInt64: UInt64]
        var settledNonces: [UInt64: UInt64] = [:]

        mutating func nonce(_ number: UInt64) async throws -> UInt64 {
            if let value = nonces[number] { return value }
            guard probesLeft > 0 else { throw ReaderError.unsupported("teto de consultas") }
            probesLeft -= 1
            let value = try EVMReader.block(
                try await EVMReader.call(transport, url, "eth_getTransactionCount", [owner, .string(EVMReader.hexBlock(number))]),
                "eth_getTransactionCount"
            )
            nonces[number] = value
            if number <= settled { settledNonces[number] = value }
            return value
        }

        mutating func g(_ number: UInt64) async throws -> Int {
            let window = self.window
            let counted = known.values.filter { $0 >= window && $0 <= number }.count
            return Int(try await nonce(number)) - counted
        }
    }

    /// Busca as transacoes do dono que faltam, da ponta para tras. Cada busca acha o menor
    /// bloco com o valor de `g` na ponta; ali estao as que faltam, e o resto da janela
    /// acima fica explicado. `explainedFrom`: dali para cima, toda transacao do dono e
    /// conhecida.
    static func locate(
        transport: ReaderTransport, owner: EVMAddress, url: URL, window: UInt64, start: UInt64, known: [String: UInt64],
        memo: inout AlchemyRecoveryMemo
    ) async -> (found: [LocatedTransaction], explainedFrom: UInt64, complete: Bool) {
        guard let tip = try? await call(transport, url, "eth_blockNumber", []), let latest = try? block(tip, "eth_blockNumber"),
              latest >= window
        else { return ([], UInt64.max, false) }
        var search = NonceSearch(
            transport: transport, url: url, owner: .string(owner.checksummed), window: window,
            settled: latest > 64 ? latest - 64 : 0, known: known, probesLeft: recoveryNonceProbes, nonces: memo.nonces
        )
        var found: [LocatedTransaction] = []
        var blocksLeft = recoveryBlocks
        var high = latest
        var explainedFrom = latest + 1
        var complete = false
        defer { memo.nonces.merge(search.settledNonces) { _, new in new } }
        do {
            var target = try await search.g(high)
            while target > Int(start), blocksLeft > 0 {
                // O menor bloco da janela, ate `high`, em que `g` ja vale `target`.
                var low = window
                var top = high
                while low < top {
                    let mid = low + (top - low) / 2
                    if try await search.g(mid) >= target { top = mid } else { low = mid + 1 }
                }
                let number = low
                let previous = number > window ? try await search.g(number - 1) : Int(start)
                let missing = target - previous
                guard missing > 0 else { break }
                blocksLeft -= 1
                let answer = try await call(transport, url, "eth_getBlockByNumber", [.string(hexBlock(number)), .bool(true)])
                let parsed = try parseOwnerTransactions(answer, owner: owner)
                let unknown = parsed.transactions.filter { search.known[$0.hash] == nil }
                guard unknown.count == missing else { break }
                let receipts = try await batchCall(transport, url, unknown.map { ("eth_getTransactionReceipt", [.string($0.hash)]) })
                var located: [LocatedTransaction] = []
                for (id, tx) in unknown.enumerated() {
                    guard let receipt = receipts[id], let facts = receiptFacts(receipt), let success = facts.success else { break }
                    located.append(LocatedTransaction(
                        hash: tx.hash, block: number, date: parsed.date, success: success, to: tx.to, value: tx.value, fee: facts.fee
                    ))
                }
                guard located.count == unknown.count else { break }
                for tx in located {
                    found.append(tx)
                    search.known[tx.hash] = number
                    if number <= search.settled { memo.located[tx.hash] = tx }
                }
                explainedFrom = number
                target = previous
                if target <= Int(start) || number == window { break }
                high = number - 1
            }
            if target <= Int(start) {
                explainedFrom = window
                complete = true
            }
        } catch {}
        return (found, explainedFrom, complete)
    }

    /// O BNB que um contrato mandou ao dono num envio dele: saldo no fim do bloco, menos o
    /// do fim do anterior, mais as taxas e os valores das transacoes do dono no bloco,
    /// menos o BNB que entrou por transacao de topo. So em bloco com um envio do dono que
    /// deu certo, com a taxa de todas as dele conhecida, e com evento no recibo (envio
    /// para carteira, sem contrato, nao recebe nada de volta).
    func balanceBlocks(
        owner: EVMAddress, url: URL, sends: [AlchemySend], located: [LocatedTransaction], receipts: [String: ReceiptFacts],
        incoming: [UInt64: BigUInt], memo: inout AlchemyRecoveryMemo
    ) async {
        var outgoing: [UInt64: (successes: Int, total: BigUInt, complete: Bool)] = [:]
        for send in sends {
            let fee = receipts[send.hash]?.fee
            var entry = outgoing[send.block] ?? (0, 0, true)
            entry.successes += 1
            entry.total = entry.total + send.value + (fee ?? 0)
            entry.complete = entry.complete && fee != nil
            outgoing[send.block] = entry
        }
        for tx in located where outgoing[tx.block] != nil {
            var entry = outgoing[tx.block]!
            if tx.success { entry.successes += 1 }
            entry.total = entry.total + tx.fee + (tx.success ? tx.value : 0)
            outgoing[tx.block] = entry
        }
        let candidates = sends.filter { send in
            guard memo.internals[send.hash] == nil, send.to != nil, send.block > 0, receipts[send.hash]?.logs != 0,
                  let entry = outgoing[send.block], entry.successes == 1, entry.complete
            else { return false }
            return true
        }.sorted { $0.block > $1.block }.prefix(Self.recoveryBalanceBlocks)
        guard !candidates.isEmpty else { return }

        var heights: [UInt64] = []
        for send in candidates {
            for number in [send.block - 1, send.block] where !heights.contains(number) { heights.append(number) }
        }
        let ownerHex = StrictJSON.string(owner.checksummed)
        guard let answers = try? await Self.batchCall(
            transport, url, heights.map { ("eth_getBalance", [ownerHex, .string(Self.hexBlock($0))]) }
        ) else { return }
        var balances: [UInt64: BigUInt] = [:]
        for (id, number) in heights.enumerated() {
            if let value = try? answers[id]?.quantity("eth_getBalance") { balances[number] = value }
        }
        for send in candidates {
            guard let before = balances[send.block - 1], let after = balances[send.block], let entry = outgoing[send.block] else { continue }
            let arrived = after + entry.total
            let explained = before + (incoming[send.block] ?? 0)
            memo.internals[send.hash] = arrived.subtractingReportingUnderflow(explained) ?? 0
        }
    }
}
