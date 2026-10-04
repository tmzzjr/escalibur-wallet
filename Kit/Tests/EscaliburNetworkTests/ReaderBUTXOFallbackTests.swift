import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contingencia de Litecoin e Dogecoin: Blockbook e Bitcore, e o banco de quem corta por
/// IP. Respostas gravadas em 04/10/2026 (FixturesB/LEIA-ME.txt). Sem rede.
@Suite("ReaderB UTXO: Blockbook, Bitcore e limite por IP")
struct ReaderBUTXOFallbackTests {
    typealias T = ReaderBTest

    static let blockbook = T.provider("atomic", "https://bb.test/api/v2")
    static let bitcore = T.provider("bitcore", "https://bc.test/api/DOGE/mainnet")
    static let blockcypher = T.provider("blockcypher", "https://cy.test/v1/doge/main")
    static let blockchair = T.provider("blockchair", "https://ch.test/dogecoin")

    /// Endereco com seis moedas; a primeira veio de uma transacao assinada pela propria
    /// chave dele, gravada com o hex.
    static let coinAddress = "DDrRHGaBYqLULgbphrRxzw8LwM1iasW4Mx"
    static let coinPublicKey = "03f176840d250f67afc1f9de7c461de2adf681e533cadb26dea58b37939ff5adf0"
    static let coinTxid = "4f71c71caa8c51b3cc6cb235d31e3c4266eba87b86db4a12767b8ffe566f0324"
    static let historyAddress = "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC"

    static func dogeTransport() throws -> ReaderBFakeTransport {
        let transport = ReaderBFakeTransport()
        transport.on("bb.test/api/v2", data: try T.fixture("blockbook-doge-status.json"))
        transport.on("bb.test/api/v2/address/\(coinAddress)", data: try T.fixture("blockbook-doge-address.json"))
        transport.on("bb.test/api/v2/utxo/\(coinAddress)", data: try T.fixture("blockbook-doge-utxo.json"))
        transport.on("bb.test/api/v2/tx/\(coinTxid)", data: try T.fixture("blockbook-doge-tx.json"))
        transport.on("bb.test/api/v2/address/\(historyAddress)", data: try T.fixture("blockbook-doge-txs.json"))
        transport.on("bc.test/api/DOGE/mainnet/block/tip", data: try T.fixture("bitcore-doge-tip.json"))
        transport.on("bc.test/api/DOGE/mainnet/address/\(coinAddress)", data: try T.fixture("bitcore-doge-coins.json"))
        transport.on("bc.test/api/DOGE/mainnet/address/\(coinAddress)/balance", data: try T.fixture("bitcore-doge-balance.json"))
        transport.on("bc.test/api/DOGE/mainnet/address/\(historyAddress)", data: try T.fixture("bitcore-doge-count.json"))
        transport.on("bc.test/api/DOGE/mainnet/address/\(historyAddress)/txs", data: try T.fixture("bitcore-doge-txs.json"))
        transport.on("bc.test/api/DOGE/mainnet/tx/\(coinTxid)", data: try T.fixture("bitcore-doge-tx.json"))
        for blocks in [2, 6, 12] {
            transport.on("bb.test/api/v2/estimatefee/\(blocks)", data: try T.fixture("blockbook-doge-estimatefee-\(blocks).json"))
            transport.on("bc.test/api/DOGE/mainnet/fee/\(blocks)", data: try T.fixture("bitcore-doge-fee-\(blocks).json"))
        }
        transport.on("cy.test/v1/doge/main", data: try T.fixture("blockcypher-doge-chain.json"))
        transport.on("ch.test/dogecoin/stats", data: try T.fixture("blockchair-doge-stats.json"))
        return transport
    }

    static func coinOwner() throws -> UTXODerivedAddress {
        try T.derived(publicKeyHex: coinPublicKey, chain: .dogecoin, kind: .p2pkh)
    }

    // MARK: Blockbook

    @Test("Blockbook: moeda conferida pelo hex e pelo script, saldo, uso e altura")
    func blockbookCoins() async throws {
        let owner = try Self.coinOwner()
        #expect(owner.address == Self.coinAddress)
        let reader = try UTXOReader(chain: .dogecoin, transport: try Self.dogeTransport(), providers: [Self.blockbook])
        let reading = try await reader.coins(for: [owner])
        let coin = try #require(reading.coins.first)
        #expect(reading.coins.count == 1)
        #expect(coin.outpoint.txid.hex == Self.coinTxid && coin.outpoint.vout == 1)
        #expect(reading.values[coin.outpoint] == 265_671_502_904)
        // Bloco 6.401.300, topo 6.401.440.
        #expect(coin.confirmations == 141)
        // As outras cinco nao tem transacao gravada: ficam de fora, com o motivo.
        #expect(reading.rejected.count == 5)
        #expect(reading.rejected.allSatisfy { $0.reason == .previousTransactionUnavailable })

        #expect(try await reader.balance(addresses: [Self.coinAddress]) == 904_735_473_505)
        #expect(try await reader.isUsed(Self.coinAddress))
        #expect(try await reader.tipHeight() == 6_401_440)
    }

    @Test("Blockbook: historico com a transacao inteira, taxa e contraparte")
    func blockbookHistory() async throws {
        let account = try T.abandonAccount(chain: .dogecoin, kind: .p2pkh)
        let first = try account.address(change: false, index: 0)
        let script = try UTXOScript.scriptPubKey(for: Self.historyAddress, chain: .dogecoin)
        let recorded = UTXODerivedAddress(
            address: Self.historyAddress, path: first.path, publicKey: first.publicKey, scriptPubKey: script, isChange: false, index: 0
        )
        let discovery = UTXODiscovery(account: account, gapLimit: 20, used: [recorded], scanned: [recorded], nextReceive: first, nextChange: first)
        let reader = try UTXOReader(chain: .dogecoin, transport: try Self.dogeTransport(), providers: [Self.blockbook, Self.bitcore])
        let items = try await reader.history(discovery, limit: 50)
        #expect(items.count == 13)
        let byID = Dictionary(uniqueKeysWithValues: items.map { (String($0.id.prefix(8)), $0) })
        // Envio: o que saiu para fora, com a taxa a parte (a entrada era toda nossa).
        let send = try #require(byID["8a9fad93"])
        #expect(send.kind == .send && send.fee == 2_146_740_000)
        #expect(send.movements == [.init(asset: .native, amount: 212_527_260_000, incoming: false)])
        #expect(send.counterparty == "DECHBYNqQqvBS9iWCaVt2cTCEPqHjVWauS")
        let receive = try #require(byID["d1e3b968"])
        #expect(receive.kind == .receive && receive.movements.first?.amount == 214_674_000_000)
        #expect(receive.counterparty == "D8uQyPPsiQ3tKRaCDiu2ucPKdvaFHdvzgD")
        #expect(receive.date == Date(timeIntervalSince1970: 1_773_086_056))
    }

    // MARK: Bitcore

    @Test("Bitcore: lista moedas, e o hex que prova cada uma vem de outro provedor")
    func bitcoreCoins() async throws {
        let transport = try Self.dogeTransport()
        let reader = try UTXOReader(chain: .dogecoin, transport: transport, providers: [Self.bitcore, Self.blockbook])
        let reading = try await reader.coins(for: [try Self.coinOwner()])
        #expect(reading.coins.count == 1 && reading.coins.first?.outpoint.txid.hex == Self.coinTxid)
        #expect(reading.rejected.count == 5)
        // O Bitcore nunca e perguntado pela transacao crua: ele nao a tem.
        #expect(!transport.requests.contains { $0.url.host == "bc.test" && $0.url.path.contains("/tx/") })
        #expect(try await reader.balance(addresses: [Self.coinAddress]) == 904_735_473_505)
    }

    @Test("Bitcore: historico pelo efeito no endereco, sem data")
    func bitcoreHistory() async throws {
        let account = try T.abandonAccount(chain: .dogecoin, kind: .p2pkh)
        let first = try account.address(change: false, index: 0)
        let recorded = UTXODerivedAddress(
            address: Self.historyAddress, path: first.path, publicKey: first.publicKey, scriptPubKey: first.scriptPubKey, isChange: false, index: 0
        )
        let discovery = UTXODiscovery(account: account, gapLimit: 20, used: [recorded], scanned: [recorded], nextReceive: first, nextChange: first)
        let reader = try UTXOReader(chain: .dogecoin, transport: try Self.dogeTransport(), providers: [Self.bitcore])
        let items = try await reader.history(discovery, limit: 50)
        let byID = Dictionary(uniqueKeysWithValues: items.map { (String($0.id.prefix(8)), $0) })
        #expect(byID["8a9fad93"]?.kind == .send)
        #expect(byID["8a9fad93"]?.movements.first?.amount == 214_674_000_000)
        #expect(byID["d1e3b968"]?.kind == .receive && byID["d1e3b968"]?.date == nil)
        #expect(try await reader.isUsed(Self.historyAddress))
    }

    // MARK: Taxa

    @Test("Dogecoin: taxa do no no Blockbook e no Bitcore; Blockcypher e Blockchair nem sao perguntados")
    func dogeFees() async throws {
        let transport = try Self.dogeTransport()
        let reader = try UTXOReader(
            chain: .dogecoin, transport: transport, providers: [Self.blockbook, Self.bitcore, Self.blockcypher, Self.blockchair]
        )
        let fees = try await reader.feeLevels()
        // 0,50648143 DOGE/kB nos dois; 0,01002434 em 6 e 12 blocos.
        #expect(fees.estimates == [UTXOFeeRate(satPerKvB: 50_648_143), UTXOFeeRate(satPerKvB: 50_648_143)])
        #expect(fees.fast == UTXOFeeRate(satPerKvB: 50_648_143))
        #expect(fees.normal == UTXOFeeRate(satPerKvB: 1_002_434) && fees.slow == UTXOFeeRate(satPerKvB: 1_002_434))
        #expect(fees.sources == ["atomic", "bitcore"])
        #expect(!transport.requests.contains { ["cy.test", "ch.test"].contains($0.url.host ?? "") })
    }

    @Test("Litecoin: com o litecoinspace fora do ar, Blockbook, Bitcore e Blockcypher dao a mediana")
    func litecoinFeesWithoutEsplora() async throws {
        let transport = ReaderBFakeTransport()
        transport.on("ltc-space.test/api/v1/fees/precise") { _, _ in throw HTTPClient.Failure.timeout }
        transport.on("ltc-space.test/api/v1/fees/recommended") { _, _ in throw HTTPClient.Failure.timeout }
        for blocks in [2, 6, 12] {
            transport.on("ltc-bb.test/api/v2/estimatefee/\(blocks)", data: try T.fixture("blockbook-ltc-estimatefee-\(blocks).json"))
            transport.on("ltc-bc.test/api/LTC/mainnet/fee/\(blocks)", data: try T.fixture("bitcore-ltc-fee-\(blocks).json"))
        }
        transport.on("ltc-cy.test/v1/ltc/main", data: try T.fixture("blockcypher-ltc-chain.json"))
        let space = T.provider("litecoinspace", "https://ltc-space.test/api")
        let providers = [
            T.provider("atomic", "https://ltc-bb.test/api/v2"), space,
            T.provider("bitcore", "https://ltc-bc.test/api/LTC/mainnet"), T.provider("blockcypher", "https://ltc-cy.test/v1/ltc/main"),
            T.provider("blockchair", "https://ltc-ch.test/litecoin"),
        ]
        let reader = try UTXOReader(chain: .litecoin, transport: transport, providers: providers)
        let fees = try await reader.feeLevels()
        #expect(fees.sources == ["atomic", "bitcore", "blockcypher"])
        // 997 e 1.000 sat/kvB do no, 12.095 da Blockcypher: a mediana e 1.000 (1 sat/vB).
        #expect(fees.fast == UTXOFeeRate(satPerKvB: 1_000))
        #expect(!transport.requests.contains { $0.url.host == "ltc-ch.test" })
    }

    // MARK: Limite por IP

    @Test("429 e 430 tiram o provedor por minutos; a leitura segue nos outros e nao volta a ele")
    func rateLimitBench() async throws {
        let transport = try Self.dogeTransport()
        transport.onPrefix("cy.test/") { _, _ in throw HTTPClient.Failure.status(429) }
        transport.onPrefix("ch.test/") { _, _ in throw HTTPClient.Failure.status(430) }
        // Ordem invertida de proposito: os que cortam por IP na frente.
        let reader = try UTXOReader(
            chain: .dogecoin, transport: transport, providers: [Self.blockcypher, Self.blockchair, Self.blockbook, Self.bitcore]
        )
        let before = Date()
        #expect(try await reader.balance(addresses: [Self.coinAddress]) == 904_735_473_505)
        let after = Date()
        let cypherUntil = try #require(await reader.pool.benched(Self.blockcypher))
        let chairUntil = try #require(await reader.pool.benched(Self.blockchair))
        // A janela e a do relogio da leitura, qualquer que seja a carga da maquina.
        #expect(cypherUntil >= before.addingTimeInterval(300) && cypherUntil <= after.addingTimeInterval(300))
        #expect(chairUntil >= before.addingTimeInterval(900) && chairUntil <= after.addingTimeInterval(900))

        // Ja no banco: a proxima leitura vai direto aos outros, sem nova recusa.
        let asked = transport.requests.count
        #expect(try await reader.isUnused(Self.coinAddress) == false)
        let next = transport.requests.dropFirst(asked)
        #expect(!next.contains { ["cy.test", "ch.test"].contains($0.url.host ?? "") })
        #expect(next.count == 2)
    }

    @Test("Provedor que nao serve a operacao nao perde ponto no banco")
    func unsupportedIsNotFailure() async throws {
        let transport = try Self.dogeTransport()
        let reader = try UTXOReader(chain: .dogecoin, transport: transport, providers: [Self.bitcore, Self.blockbook])
        for _ in 0..<4 { _ = try await reader.coins(for: [try Self.coinOwner()]) }
        #expect(await reader.pool.benched(Self.bitcore) == nil)
        #expect(await reader.pool.available().map(\.name).contains("bitcore"))
    }

    // MARK: Transmissao e acompanhamento

    @Test("Transmissao: Blockbook em texto, Bitcore em JSON, os mesmos bytes")
    func broadcast() async throws {
        let hex = try T.text("esplora-tx-hex.txt")
        let signed = SignedTransaction(chainID: Chain.dogecoin.id, raw: try #require(Hex.decode(hex)), encoded: hex, id: T.fundedTxid)
        let transport = ReaderBFakeTransport()
        transport.on("bb.test/api/v2/sendtx", data: Data("{\"result\":\"\(T.fundedTxid)\"}".utf8))
        transport.on("bc.test/api/DOGE/mainnet/tx/send", data: Data("{\"txid\":\"\(T.fundedTxid)\"}".utf8))
        let reader = try UTXOReader(chain: .dogecoin, transport: transport, providers: [Self.blockbook, Self.bitcore])
        let receipt = try await reader.broadcast(signed)
        #expect(Set(receipt.acceptedBy) == ["atomic", "bitcore"])
        let bodies = Dictionary(transport.requests.map { ($0.url.host ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        #expect(bodies["bb.test"]?.body == Data(hex.utf8) && bodies["bb.test"]?.contentType == "text/plain")
        let json = try JSONDecoder().decode([String: String].self, from: try #require(bodies["bc.test"]?.body))
        #expect(json == ["rawTx": hex])
    }

    @Test("Status: Blockbook e Bitcore confirmam no mesmo bloco; 400 e 404 sao nao encontrada")
    func status() async throws {
        let transport = try Self.dogeTransport()
        let reader = try UTXOReader(chain: .dogecoin, transport: transport, providers: [Self.blockbook, Self.bitcore])
        #expect(try await reader.status(txid: Self.coinTxid) == .confirmed(height: 6_401_300, confirmations: 141))
        transport.on("bb.test/api/v2/tx/\(Self.coinTxid)", status: 400)
        transport.on("bc.test/api/DOGE/mainnet/tx/\(Self.coinTxid)", status: 404)
        #expect(try await reader.status(txid: Self.coinTxid) == .notFound)
    }

    @Test("Formatos: valor em texto do Blockbook, com sinal, e taxa em moeda por kB do Bitcore")
    func parsing() throws {
        #expect(try UTXOProviderClient.signedSats("-6471", field: "x") == -6_471)
        #expect(throws: ChainReaderError.malformedResponse(field: "x")) { try UTXOProviderClient.sats("1.5", field: "x") }
        #expect(try UTXOProviderClient.rate(coinPerKvB: 0.00001) == UTXOFeeRate(satPerKvB: 1_000))
        #expect(throws: ChainReaderError.malformedResponse(field: "feerate")) { try UTXOProviderClient.rate(coinPerKvB: -1) }
    }
}
