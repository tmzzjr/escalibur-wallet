@testable import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// O motor UTXO contra respostas gravadas (Fixtures/utxo), sem rede.
///
/// A conta e a da frase "abandon" x11 + "about" (vetor publico): o recebimento 0 tem
/// historico real, e o troco 0 tambem. A moeda gasta nos planos e a saida 0 da transacao
/// real 3cf90b5e... (289.339 sat para o recebimento 0); na rede ela ja foi gasta, entao a
/// lista de moedas nao gastas e montada aqui, apontando para a transacao gravada.
@Suite("Motor UTXO com respostas gravadas")
struct UTXOEngineTests {
    static let receive0 = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"
    static let change0 = "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el"
    static let coinTxid = "3cf90b5e9f1f4af0c43117c3698636286e90153361f6868e91364b1a8cb279f5"
    static let statusTxid = "fd4b2c20cea81c2319f460114d2303b2dc3494524cc07cde015eebb38033cdcd"
    /// Destino dos envios: o exemplo P2WPKH do BIP-173.
    static let destination = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"

    static let providers = [
        EngineFixture.provider("mempool", "https://esplora-a.test/api"),
        EngineFixture.provider("blockstream", "https://esplora-b.test/api"),
        EngineFixture.provider("emzy", "https://esplora-c.test/api"),
    ]

    /// Tres Esplora que respondem com as gravacoes. `broadcastTxid` diz o que cada host
    /// devolve na transmissao.
    static func network(
        history: Data? = nil, broadcastTxid: @escaping @Sendable (_ host: String, _ hex: String) -> String = { _, hex in
            (try? UTXOTransaction(hex: hex).txid.hex) ?? ""
        }
    ) throws -> FakeHTTP {
        let fake = FakeHTTP()
        let used = try EngineFixture.data("utxo", "esplora-address-usado.json")
        let changeUsed = try EngineFixture.data("utxo", "esplora-address-troco0.json")
        let emptyTemplate = try EngineFixture.text("utxo", "esplora-address-vazio.json")
        let emptyAddress = "bc1q4h7w2n6jnvs4fc7rvxa78a75rkcxx4cha6sptp"
        let hex = try EngineFixture.data("utxo", "esplora-tx-hex-moeda.txt")
        let tip = try EngineFixture.data("utxo", "esplora-tip-height.txt")
        let txs = try history ?? EngineFixture.data("utxo", "esplora-txs.json")
        let statusA = try EngineFixture.data("utxo", "esplora-tx-status-mempool.json")
        let statusB = try EngineFixture.data("utxo", "esplora-tx-status-blockstream.json")
        let precise = try EngineFixture.data("utxo", "esplora-fees-precise.json")
        let estimates = try EngineFixture.data("utxo", "esplora-fee-estimates.json")
        let recommended = try EngineFixture.data("utxo", "emzy-fees-recommended.json")
        // A moeda como o Esplora lista moeda nao gasta, apontando para a transacao gravada.
        let unspent = Data("""
        [{"txid":"\(coinTxid)","vout":0,"value":289339,"status":{"confirmed":true,"block_height":910679,"block_time":1754574394}}]
        """.utf8)

        for host in ["esplora-a.test", "esplora-b.test", "esplora-c.test"] {
            fake.onPrefix(host + "/api/") { url, body in
                let parts = url.path.split(separator: "/").map(String.init).dropFirst()  // tira "api"
                switch (parts.first, parts.count) {
                case ("address", 2):
                    let address = parts[parts.startIndex + 1]
                    if address == receive0 { return used }
                    if address == change0 { return changeUsed }
                    return Data(emptyTemplate.replacingOccurrences(of: emptyAddress, with: address).utf8)
                case ("address", 3):
                    let address = parts[parts.startIndex + 1]
                    if parts.last == "utxo" { return address == receive0 ? unspent : Data("[]".utf8) }
                    return address == receive0 ? txs : Data("[]".utf8)
                case ("tx", 1):
                    guard let body else { throw HTTPClient.Failure.status(400) }
                    return Data(broadcastTxid(host, String(decoding: body, as: UTF8.self)).utf8)
                case ("tx", 3) where parts.last == "hex":
                    return hex
                case ("tx", 3) where parts.last == "status":
                    return host == "esplora-b.test" ? statusB : statusA
                case ("blocks", 3):
                    return tip
                default:
                    break
                }
                switch (host, url.path) {
                case ("esplora-a.test", "/api/v1/fees/precise"): return precise
                case ("esplora-b.test", "/api/fee-estimates"): return estimates
                case ("esplora-c.test", "/api/v1/fees/recommended"): return recommended
                default: throw HTTPClient.Failure.status(404)
                }
            }
        }
        return fake
    }

    static func engine(_ fake: FakeHTTP) throws -> UTXOSendEngine {
        UTXOSendEngine(chain: .bitcoin, reader: try UTXOReader(chain: .bitcoin, transport: fake, providers: providers))
    }

    static func request(
        amount: BigUInt = 100_000, sendAll: Bool = false, fee: FeeLevel = .normal, usage: UTXOUsage? = nil, tag: String? = nil,
        account: DerivedAccount = TestAccounts.bitcoin
    ) -> SendRequest {
        SendRequest(
            walletID: UUID(), chain: .bitcoin, asset: .native(.bitcoin), account: account, destination: destination, tag: tag,
            amount: amount, sendAll: sendAll, feeLevel: fee, utxoUsage: usage
        )
    }

    static func account() throws -> UTXOAccount {
        try UTXOEngineSupport.account(TestAccounts.bitcoin, chain: .bitcoin)
    }

    // MARK: Plano

    @Test("Valor exato: plano do planejador, destino na revisao e troco no proximo indice livre da xpub")
    func exactPlanWithChange() async throws {
        let fake = try Self.network()
        let engine = try Self.engine(fake)
        let plan = try await engine.plan(Self.request())

        #expect(plan.review.kind == .send)
        #expect(plan.review.recipient == Self.destination)
        #expect(plan.review.recipientTag == nil)
        let transaction = try #require(plan.transactions.first as? UTXOSignableTransaction)
        let summary = try #require(transaction.summary)
        #expect(summary.amount == 100_000)
        // O troco 0 tem historico real: o troco vai para o indice 1, derivado da xpub.
        let expectedChange = try Self.account().address(change: true, index: 1)
        #expect(summary.changeAddress == expectedChange.address)
        #expect(transaction.unsigned.outputs.contains { $0.scriptPubKey == expectedChange.scriptPubKey })
        #expect(summary.change.map { $0 + summary.amount + summary.fee } == 289_339)
        #expect(transaction.signingRequests.map(\.expectedPublicKey) == [TestAccounts.bitcoin.publicKey])

        // Depois de transmitir: troco e recebimento achados pela varredura passam a contar.
        #expect(engine.usage(after: plan, current: nil) == UTXOUsage(receiveUsed: 1, changeUsed: 2))
        #expect(engine.usage(after: plan, current: UTXOUsage(receiveUsed: 4, changeUsed: 9)) == nil)
    }

    @Test("Regressao B6: o troco so vai para endereco que dois provedores veem sem historico")
    func changeOnTwoProviders() async throws {
        // A varredura pergunta pelo troco 1 a um provedor so (o segundo da lista, pela
        // rotacao) e acha livre; o primeiro ve historico nele.
        let fake = try Self.network()
        let change1 = try Self.account().address(change: true, index: 1).address
        let used = try EngineFixture.data("utxo", "esplora-address-troco0.json")
        let usedText = String(decoding: used, as: UTF8.self).replacingOccurrences(of: Self.change0, with: change1)
        fake.on("esplora-a.test/api/address/\(change1)", data: Data(usedText.utf8))
        let engine = try Self.engine(fake)
        let plan = try await engine.plan(Self.request())
        let summary = try #require(UTXOEngineSupport.summary(plan))
        #expect(summary.changeAddress == (try Self.account().address(change: true, index: 2).address))
        #expect(engine.usage(after: plan, current: nil)?.changeUsed == 3)
    }

    @Test("A xpub nunca vai para a rede: so enderecos, um por consulta")
    func xpubNeverLeaves() async throws {
        let fake = try Self.network()
        _ = try await Self.engine(fake).plan(Self.request())
        let xpub = try #require(TestAccounts.bitcoin.accountXPub)
        let secrets = [Hex.encode(xpub.publicKey), Hex.encode(xpub.chainCode)]
        for request in fake.requests {
            let text = request.url.absoluteString + (request.body.map { String(decoding: $0, as: UTF8.self) } ?? "")
            #expect(!secrets.contains { text.lowercased().contains($0) })
        }
        let addressQueries = fake.requests.filter { $0.url.path.contains("/address/") }
        #expect(!addressQueries.isEmpty)
        #expect(addressQueries.allSatisfy { $0.url.path.split(separator: "/").count <= 4 })
    }

    @Test("O contador do app vale quando esta a frente da varredura, e os indices dele nao sao consultados de novo")
    func localUsageAhead() async throws {
        let fake = try Self.network()
        let engine = try Self.engine(fake)
        let plan = try await engine.plan(Self.request(usage: UTXOUsage(receiveUsed: 3, changeUsed: 5)))
        let summary = try #require(UTXOEngineSupport.summary(plan))
        #expect(summary.changeAddress == (try Self.account().address(change: true, index: 5).address))
        #expect(engine.usage(after: plan, current: UTXOUsage(receiveUsed: 3, changeUsed: 5)) == UTXOUsage(receiveUsed: 3, changeUsed: 6))

        let account = try Self.account()
        let skipped = try (0..<3).map { try account.address(change: false, index: UInt32($0)).address }
        let asked = fake.requests.filter { $0.url.path.split(separator: "/").count == 3 }.map { String($0.url.path.split(separator: "/")[2]) }
        #expect(!skipped.contains { asked.contains($0) })
    }

    @Test("Enviar tudo: o maximo e o valor do plano de enviar tudo, sem troco, com a taxa escolhida")
    func sendAllMatchesSpendable() async throws {
        let engine = try Self.engine(try Self.network())
        let spendable = try await engine.spendable(Self.request(amount: 0, sendAll: true))
        let plan = try await engine.plan(Self.request(amount: spendable.amount, sendAll: true))
        let summary = try #require(UTXOEngineSupport.summary(plan))
        #expect(summary.amount == spendable.amount)
        #expect(summary.change == nil && summary.sendsAll)
        #expect(plan.review.recipient == Self.destination)
        #expect(spendable.feeNote?.contains("sat/vB") == true)
        #expect(spendable.reserveNote == nil)
        // Sem troco, so a varredura conta.
        #expect(engine.usage(after: plan, current: nil) == UTXOUsage(receiveUsed: 1, changeUsed: 1))
    }

    @Test("Os tres niveis de taxa saem dos niveis do leitor, na ordem")
    func feeLevels() async throws {
        let engine = try Self.engine(try Self.network())
        var rates: [UTXOFeeRate] = []
        for level in FeeLevel.allCases {
            let plan = try await engine.plan(Self.request(fee: level))
            rates.append(try #require(UTXOEngineSupport.summary(plan)).feeRate)
        }
        let fees = try await UTXOReader(chain: .bitcoin, transport: try Self.network(), providers: Self.providers).feeLevels()
        #expect(rates == [fees.slow, fees.normal, fees.fast])
        #expect(rates[0] <= rates[1] && rates[1] <= rates[2])
    }

    @Test("Pedido que nao serve: tag, token, conta sem xpub, xpub que nao gera o endereco")
    func refusals() async throws {
        let engine = try Self.engine(try Self.network())
        await #expect(throws: SendEngineError.message("A rede Bitcoin não usa tag nem memo. Tire a tag para enviar.")) {
            _ = try await engine.plan(Self.request(tag: "123"))
        }
        let bare = DerivedAccount(
            chainID: "bitcoin", path: TestAccounts.bitcoin.path, address: TestAccounts.bitcoin.address,
            publicKey: TestAccounts.bitcoin.publicKey, accountXPub: nil
        )
        await #expect(throws: SendEngineError.self) { _ = try await engine.plan(Self.request(account: bare)) }
        let other = DerivedAccount(
            chainID: "bitcoin", path: TestAccounts.bitcoin.path, address: Self.destination,
            publicKey: TestAccounts.bitcoin.publicKey, accountXPub: TestAccounts.bitcoin.accountXPub
        )
        await #expect(throws: SendEngineError.message("A chave pública guardada não gera o endereço desta conta. Por segurança, nada foi montado.")) {
            _ = try await engine.plan(Self.request(account: other))
        }
        await #expect(throws: SendEngineError.message("Saldo insuficiente para este valor mais a taxa da rede.")) {
            _ = try await engine.plan(Self.request(amount: 300_000))
        }
    }

    // MARK: Transmissao e acompanhamento

    /// Uma transacao assinada de verdade: a propria transacao gravada da moeda.
    static func signed() throws -> SignedTransaction {
        let hex = try EngineFixture.text("utxo", "esplora-tx-hex-moeda.txt")
        let transaction = try UTXOTransaction(hex: hex)
        return SignedTransaction(chainID: "bitcoin", raw: transaction.serialized(), encoded: hex, id: transaction.txid.hex)
    }

    @Test("Transmissao: o id devolvido e o calculado dos bytes, mesmo com um provedor devolvendo outro")
    func broadcastLocalTxid() async throws {
        let signed = try Self.signed()
        let fake = try Self.network(broadcastTxid: { host, hex in
            host == "esplora-a.test" ? String(repeating: "ab", count: 32) : ((try? UTXOTransaction(hex: hex).txid.hex) ?? "")
        })
        let id = try await Self.engine(fake).broadcast([signed], chain: .bitcoin)
        #expect(id == Self.coinTxid)
        // Os mesmos bytes nos tres.
        let bodies = fake.requests.filter { $0.url.path.hasSuffix("/api/tx") }.compactMap(\.body)
        #expect(bodies.count == 3 && Set(bodies).count == 1)
    }

    @Test("Transmissao recusada: bytes que nao dao o id, e provedores que so devolvem outro id")
    func broadcastRefusals() async throws {
        let signed = try Self.signed()
        let wrongID = SignedTransaction(chainID: "bitcoin", raw: signed.raw, encoded: signed.encoded, id: String(repeating: "cd", count: 32))
        let fake = try Self.network()
        await #expect(throws: SendEngineError.message(NetworkFailureText.inconsistent)) {
            _ = try await Self.engine(fake).broadcast([wrongID], chain: .bitcoin)
        }
        #expect(fake.requests.isEmpty)

        let liar = try Self.network(broadcastTxid: { _, _ in String(repeating: "ab", count: 32) })
        await #expect(throws: SendEngineError.message(NetworkFailureText.refused)) {
            _ = try await Self.engine(liar).broadcast([signed], chain: .bitcoin)
        }
    }

    @Test("Acompanhamento: confirmado so com os dois provedores, e dito em confirmacoes e bloco")
    func status() async throws {
        let engine = try Self.engine(try Self.network())
        let status = await engine.status(Self.statusTxid, chain: .bitcoin)
        guard case .confirmed(let detail) = status else { Issue.record("esperava confirmada"); return }
        #expect(detail?.contains("no bloco 956.025") == true)
        #expect(detail?.contains("confirmações") == true)
        #expect(await engine.status("xyz", chain: .bitcoin) == .pending)
    }

    // MARK: Atividade

    @Test("Atividade: poeira de desconhecido e endereco parecido com um da carteira ficam suspeitos")
    func activity() async throws {
        // O remetente real do recebimento de 14.584 sat (bbdb8f9d...) e trocado por um
        // texto com o comeco e o fim do recebimento 0 da carteira: o golpe do endereco
        // parecido. O checksum nao importa para a comparacao.
        let lookalike = "bc1qcr8tq0a9xk6ztn8hdklnq5gfsxy2wcrcw5306fyu"
        let history = try EngineFixture.data(
            "utxo", "esplora-txs.json", replacing: [("bc1qt08krp2nue576wvfavyql3fp3zva4yf6e20r85", lookalike)]
        )
        let source = UTXOActivitySource(
            chain: .bitcoin, reader: try UTXOReader(chain: .bitcoin, transport: try Self.network(history: history), providers: Self.providers)
        )
        let entries = try await source.history(chain: .bitcoin, account: TestAccounts.bitcoin, usage: nil)
        #expect(entries.count == 8)
        #expect(entries.allSatisfy { $0.id.hasPrefix("bitcoin:") && $0.hash.count == 64 && $0.chainID == "bitcoin" })

        func entry(_ prefix: String) throws -> ActivityEntry { try #require(entries.first { $0.hash.hasPrefix(prefix) }) }
        // 1.000 e 670 sat de quem a carteira nunca pagou: poeira.
        #expect(try entry("f5a6d77a").suspicious && entry("f5a6d77a").direction == .received)
        #expect(try entry("db40e263").suspicious)
        // 26.309 sat de um remetente comum: aparece.
        #expect(try !entry("d874a550").suspicious && entry("d874a550").amount == 26_309)
        // 14.584 sat do endereco parecido: escondido.
        #expect(try entry("bbdb8f9d").suspicious && entry("bbdb8f9d").counterparty == lookalike)
        // O que a carteira fez aparece sempre (aqui, moedas queimadas em taxa).
        #expect(try !entry("fd4b2c20").suspicious && entry("fd4b2c20").direction == .other)
    }
}

/// Dogecoin: sem segwit, conta BIP-44 (P2PKH), provedores Blockcypher e Blockchair.
@Suite("Motor UTXO no Dogecoin com respostas gravadas")
struct DogecoinEngineTests {
    static let receive0 = "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC"
    static let coinTxid = "d1e3b968a736cf5289af27fe510ea3b5ba086b52dbeba9f927fd0f8658b399ca"
    static let destination = "DM14Px1dMV2VmdoeE5RekqL3L7cSJMg8b4"

    static let providers = [
        EngineFixture.provider("blockcypher", "https://cypher.test/v1/doge/main"),
        EngineFixture.provider("blockchair", "https://chair.test/dogecoin"),
    ]

    static func network() throws -> FakeHTTP {
        let fake = FakeHTTP()
        let chain = try EngineFixture.data("utxo", "blockcypher-doge-chain.json")
        let used = try EngineFixture.data("utxo", "blockcypher-doge-address-usado.json")
        let emptyTemplate = try EngineFixture.text("utxo", "blockcypher-doge-address-vazio.json")
        let transaction = try EngineFixture.data("utxo", "blockcypher-doge-tx-moeda.json")
        let stats = try EngineFixture.data("utxo", "blockchair-doge-stats.json")
        // A moeda como a Blockcypher lista moeda nao gasta, apontando para a transacao
        // gravada (na rede ela ja foi gasta).
        let unspent = Data("""
        {"address":"\(receive0)","final_n_tx":13,"txrefs":[{"tx_hash":"\(coinTxid)","block_height":6116929,"tx_input_n":-1,"tx_output_n":0,"value":214674000000,"confirmed":"2026-03-09T19:54:16Z"}]}
        """.utf8)
        fake.on("cypher.test/v1/doge/main", data: chain)
        fake.on("chair.test/dogecoin/stats", data: stats)
        fake.onPrefix("cypher.test/v1/doge/main/addrs/") { url, _ in
            let address = url.lastPathComponent
            if url.query?.contains("unspentOnly=true") == true {
                return address == receive0 ? unspent : Data(emptyTemplate.replacingOccurrences(of: destination, with: address).utf8)
            }
            return address == receive0 ? used : Data(emptyTemplate.replacingOccurrences(of: destination, with: address).utf8)
        }
        fake.on("cypher.test/v1/doge/main/txs/\(coinTxid)", data: transaction)
        // A segunda opiniao sobre o troco: a Blockchair, montada aqui sem historico.
        fake.onPrefix("chair.test/dogecoin/dashboards/address/") { url, _ in
            let address = url.lastPathComponent
            return Data(#"{"data":{"\#(address)":{"address":{"transaction_count":0},"transactions":[],"utxo":[]}}}"#.utf8)
        }
        return fake
    }

    @Test("Plano P2PKH legado: taxa por kB, troco na cadeia interna, versao 1, sem witness")
    func legacyPlan() async throws {
        let engine = UTXOSendEngine(chain: .dogecoin, reader: try UTXOReader(chain: .dogecoin, transport: try Self.network(), providers: Self.providers))
        let request = SendRequest(
            walletID: UUID(), chain: .dogecoin, asset: .native(.dogecoin), account: TestAccounts.dogecoin, destination: Self.destination,
            tag: nil, amount: 10_000_000_000, sendAll: false, feeLevel: .normal, utxoUsage: nil
        )
        let plan = try await engine.plan(request)
        #expect(plan.review.recipient == Self.destination)
        let transaction = try #require(plan.transactions.first as? UTXOSignableTransaction)
        #expect(transaction.unsigned.version == 1)
        #expect(transaction.spends.map(\.kind) == [.p2pkh])
        #expect(transaction.unsigned.inputs.allSatisfy { $0.witness.isEmpty })
        let summary = try #require(transaction.summary)
        #expect(summary.feeRate == UTXOFeeRate(satPerKvB: 57_237_765))
        let account = try UTXOEngineSupport.account(TestAccounts.dogecoin, chain: .dogecoin)
        #expect(account.kind == .p2pkh)
        #expect(summary.changeAddress == (try account.address(change: true, index: 0).address))

        let spendable = try await engine.spendable(request)
        #expect(spendable.feeNote?.contains("DOGE/kB") == true)
    }
}
