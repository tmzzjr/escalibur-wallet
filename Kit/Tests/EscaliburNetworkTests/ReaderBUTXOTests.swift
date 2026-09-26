import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Leitores UTXO contra respostas gravadas (FixturesB/LEIA-ME.txt). Sem rede.
@Suite("ReaderB UTXO: respostas gravadas")
struct ReaderBUTXOTests {
    typealias T = ReaderBTest

    // MARK: Derivacao e descoberta

    @Test("Enderecos saem da xpub localmente: vetores do BIP-84")
    func derivation() throws {
        let account = try T.abandonAccount()
        #expect(try account.address(change: false, index: 0).address == T.abandonReceive0)
        #expect(try account.address(change: true, index: 0).address == T.abandonChange0)
        #expect(try account.address(change: true, index: 3).path.description == "m/84'/0'/0'/1/3")
        // Dogecoin so tem P2PKH; conta segwit de DOGE e recusada.
        #expect(throws: ChainReaderError.unsupportedAccount) { try T.abandonAccount(chain: .dogecoin, kind: .p2wpkh) }
        #expect(try T.abandonAccount(chain: .dogecoin, kind: .p2pkh).address(change: false, index: 0).address.hasPrefix("D"))
        #expect(try T.abandonAccount(chain: .litecoin).address(change: false, index: 0).address.hasPrefix("ltc1q"))
    }

    /// Enderecos usados: recebimento 0, 1 e 5; troco 0.
    static func discoveryTransport(account: UTXOAccount) throws -> ReaderBFakeTransport {
        let used = Set(try [(false, 0), (false, 1), (false, 5), (true, 0)].map { try account.address(change: $0.0, index: UInt32($0.1)).address })
        let template = String(decoding: try T.fixture("esplora-address.json"), as: UTF8.self)
        let transport = ReaderBFakeTransport()
        for host in ["esplora-a.test", "esplora-b.test", "esplora-c.test"] {
            transport.onPrefix("\(host)/api/address/") { url, _ in
                let address = url.lastPathComponent
                let count = used.contains(address) ? "3" : "0"
                return Data(template
                    .replacingOccurrences(of: T.abandonReceive0, with: address)
                    .replacingOccurrences(of: "\"tx_count\":176", with: "\"tx_count\":\(count)")
                    .utf8)
            }
        }
        return transport
    }

    @Test("Gap limit 20 em cada cadeia, um endereco por consulta, nunca a xpub")
    func discovery() async throws {
        let account = try T.abandonAccount()
        let transport = try Self.discoveryTransport(account: account)
        let reader = try UTXOReader(chain: .bitcoin, transport: transport, providers: T.esploraProviders)
        let found = try await reader.discover(account)

        #expect(found.usedReceiveIndices == [0, 1, 5])
        #expect(found.usedChangeIndices == [0])
        #expect(found.nextReceive.index == 2 && !found.nextReceive.isChange)
        #expect(found.nextChange.index == 1 && found.nextChange.isChange)
        // 0...25 no recebimento (20 livres depois do 5), 0...20 no troco.
        #expect(found.scanned.count == 26 + 21)
        #expect(transport.requests.count == 47)

        // Privacidade: cada consulta leva um endereco so; a xpub (nem em hex) nunca sai.
        let keyHex = Hex.encode(account.accountKey.publicKey)
        let chainCodeHex = Hex.encode(account.accountKey.chainCode)
        for request in transport.requests {
            let text = request.url.absoluteString
            #expect(!text.contains("zpub") && !text.contains("xpub") && !text.contains(keyHex) && !text.contains(chainCodeHex))
            #expect(request.url.pathComponents.filter { $0.hasPrefix("bc1") }.count == 1)
        }
        let asked = transport.requests.map(\.url.lastPathComponent)
        #expect(Set(asked).count == asked.count, "cada endereco consultado uma vez")
        // Os enderecos se espalham entre os provedores: nenhum ve a conta inteira.
        #expect(Set(transport.requests.compactMap(\.url.host)).count == 3)

        // O troco que o planejamento confere: caminho da cadeia 1, chave da xpub.
        let change = found.changeAddress
        #expect(change.path.description == "m/84'/0'/0'/1/1")
        #expect(change.publicKey == (try account.accountKey.derive([1, 1]).publicKey))
    }

    @Test("Caminhos ja sabidos usados nao sao consultados de novo")
    func discoveryKnownUsed() async throws {
        let account = try T.abandonAccount()
        let transport = try Self.discoveryTransport(account: account)
        let reader = try UTXOReader(chain: .bitcoin, transport: transport, providers: T.esploraProviders)
        let known: Set<DerivationPath> = [try account.address(change: false, index: 0).path, try account.address(change: false, index: 1).path]
        let found = try await reader.discover(account, knownUsed: known)
        #expect(found.usedReceiveIndices == [0, 1, 5])
        #expect(transport.requests.count == 45)
    }

    @Test("Resposta sobre outro endereco e recusada")
    func discoveryMismatch() async throws {
        let account = try T.abandonAccount()
        let transport = ReaderBFakeTransport()
        transport.onPrefix("esplora-a.test/api/address/") { _, _ in try T.fixture("esplora-address.json") }
        let reader = try UTXOReader(chain: .bitcoin, transport: transport, providers: [T.esploraProviders[0]])
        // O primeiro endereco e justamente o da fixture; o segundo nao.
        await #expect(throws: ChainReaderError.mismatchedResponse) { try await reader.discover(account, gapLimit: 3) }
    }

    // MARK: Moedas

    static func coinTransport(utxo: Data? = nil, hex: String? = nil) throws -> ReaderBFakeTransport {
        let transport = ReaderBFakeTransport()
        transport.on("esplora-a.test/api/blocks/tip/height", text: try T.text("esplora-tip-height.txt"))
        transport.on("esplora-a.test/api/address/\(T.fundedAddress)/utxo", data: try utxo ?? T.fixture("esplora-utxo.json"))
        transport.on("esplora-a.test/api/tx/\(T.fundedTxid)/hex", text: try hex ?? T.text("esplora-tx-hex.txt"))
        return transport
    }

    @Test("Moeda com a transacao anterior inteira, conferida pelo txid e pelo script")
    func coins() async throws {
        let address = try T.derived(publicKeyHex: T.fundedPublicKey)
        #expect(address.address == T.fundedAddress)
        let reader = try UTXOReader(chain: .bitcoin, transport: try Self.coinTransport(), providers: [T.esploraProviders[0]])
        let reading = try await reader.coins(for: [address])
        #expect(reading.rejected.isEmpty)
        #expect(reading.coins.count == 1)
        let coin = try #require(reading.coins.first)
        #expect(coin.outpoint.txid.hex == T.fundedTxid && coin.outpoint.vout == 1)
        #expect(coin.path == address.path && coin.publicKey == address.publicKey)
        // Bloco 968.627, topo 968.650.
        #expect(coin.confirmations == 24)
        #expect(reading.values[coin.outpoint] == 98_089)
        #expect(reading.confirmedTotal == 98_089 && reading.pendingTotal == 0)
        #expect(try UTXOPreviousOutput.verify(previousTransaction: coin.previousTransaction, outpoint: coin.outpoint).value == 98_089)
    }

    @Test("O que nao confere e descartado, com o motivo")
    func coinsRejected() async throws {
        let address = try T.derived(publicKeyHex: T.fundedPublicKey)
        let hex = try T.text("esplora-tx-hex.txt")

        func reason(utxo: Data? = nil, hex: String? = nil, address: UTXODerivedAddress = address, dropHex: Bool = false) async throws -> UTXORejectedCoin.Reason? {
            let transport = try Self.coinTransport(utxo: utxo, hex: hex)
            if dropHex { transport.on("esplora-a.test/api/tx/\(T.fundedTxid)/hex", status: 404) }
            let reader = try UTXOReader(chain: .bitcoin, transport: transport, providers: [T.esploraProviders[0]])
            let reading = try await reader.coins(for: [address])
            #expect(reading.coins.isEmpty)
            return reading.rejected.first?.reason
        }

        // Valor adulterado dentro da transacao: o txid deixa de bater.
        let tampered = hex.replacingOccurrences(of: "297f010000000000", with: "297f010000000001")
        #expect(tampered != hex)
        #expect(try await reason(hex: tampered) == .previousTransactionMismatch)
        #expect(try await reason(hex: String(hex.dropLast(10))) == .previousTransactionMalformed)
        #expect(try await reason(dropHex: true) == .previousTransactionUnavailable)
        // O provedor anuncia um valor que nao e o da saida.
        #expect(try await reason(utxo: try T.fixture("esplora-utxo.json", replacing: [("\"value\":98089", "\"value\":98090")])) == .claimedValueMismatch)
        #expect(try await reason(utxo: try T.fixture("esplora-utxo.json", replacing: [("\"vout\":1", "\"vout\":9")])) == .outputIndexOutOfRange)
        // Saida paga outro script: a chave derivada nao e a desse endereco.
        let other = try T.abandonAccount().address(change: false, index: 0)
        let impostor = UTXODerivedAddress(
            address: T.fundedAddress, path: other.path, publicKey: other.publicKey,
            scriptPubKey: other.scriptPubKey, isChange: false, index: 0
        )
        #expect(try await reason(address: impostor) == .notOurScript)
    }

    @Test("Resposta sem campo obrigatorio e recusada inteira")
    func strictUTXO() async throws {
        let address = try T.derived(publicKeyHex: T.fundedPublicKey)
        let broken = try T.fixture("esplora-utxo.json", replacing: [("\"value\":98089", "\"valor\":98089")])
        let reader = try UTXOReader(chain: .bitcoin, transport: try Self.coinTransport(utxo: broken), providers: [T.esploraProviders[0]])
        await #expect(throws: ChainReaderError.malformedResponse(field: "0.value")) { try await reader.coins(for: [address]) }

        let unconfirmedWithoutHeight = try T.fixture("esplora-utxo.json", replacing: [("\"block_height\":968627,", "")])
        let second = try UTXOReader(chain: .bitcoin, transport: try Self.coinTransport(utxo: unconfirmedWithoutHeight), providers: [T.esploraProviders[0]])
        await #expect(throws: ChainReaderError.self) { try await second.coins(for: [address]) }
    }

    // MARK: Taxa

    static func feeTransport() throws -> ReaderBFakeTransport {
        let transport = ReaderBFakeTransport()
        transport.on("esplora-a.test/api/v1/fees/precise", data: try T.fixture("esplora-fees-precise.json"))
        transport.on("esplora-b.test/api/fee-estimates", data: try T.fixture("esplora-fee-estimates.json"))
        return transport
    }

    @Test("Bitcoin: mediana de mempool.space e Blockstream, piso de 1 sat/vB")
    func feesBitcoin() async throws {
        let reader = try UTXOReader(chain: .bitcoin, transport: try Self.feeTransport(), providers: T.esploraProviders)
        let fees = try await reader.feeLevels()
        // mempool: 1 / 0,619 / 0,341; blockstream (1, 3, 6 blocos): 3,303 / 2,112 / 2,003.
        #expect(fees.sources == ["mempool", "blockstream"])
        #expect(fees.estimates == [UTXOFeeRate(satPerKvB: 1_000), UTXOFeeRate(satPerKvB: 3_303)])
        #expect(fees.slow == UTXOFeeRate(satPerKvB: 1_172))
        #expect(fees.normal == UTXOFeeRate(satPerKvB: 1_366))
        #expect(fees.fast == UTXOFeeRate(satPerKvB: 2_152))
    }

    @Test("Uma fonte so nao basta: o teto do planejamento pede duas")
    func feesNeedTwo() async throws {
        let transport = ReaderBFakeTransport()
        transport.on("esplora-a.test/api/v1/fees/recommended", data: try T.fixture("esplora-fees-precise.json"))
        let reader = try UTXOReader(chain: .bitcoin, transport: transport, providers: T.esploraProviders)
        await #expect(throws: ChainReaderError.notEnoughSources(needed: 2, got: 1)) { try await reader.feeLevels() }
    }

    @Test("Litecoin: litecoinspace e Blockcypher; Dogecoin: Blockcypher e Blockchair")
    func feesLitecoinDogecoin() async throws {
        let ltc = ReaderBFakeTransport()
        ltc.on("ltc-a.test/api/v1/fees/precise", data: try T.fixture("litecoinspace-fees-precise.json"))
        ltc.on("ltc-b.test/v1/ltc/main", data: try T.fixture("blockcypher-ltc-chain.json"))
        let ltcReader = try UTXOReader(chain: .litecoin, transport: ltc, providers: [
            T.provider("litecoinspace", "https://ltc-a.test/api"), T.provider("blockcypher", "https://ltc-b.test/v1/ltc/main"),
            T.provider("blockchair", "https://ltc-c.test/litecoin"),
        ])
        let ltcFees = try await ltcReader.feeLevels()
        #expect(ltcFees.estimates == [UTXOFeeRate(satPerKvB: 1_500), UTXOFeeRate(satPerKvB: 12_095)])
        #expect(ltcFees.slow == UTXOFeeRate(satPerKvB: 3_923))
        #expect(ltcFees.normal == UTXOFeeRate(satPerKvB: 5_305))
        #expect(ltcFees.fast == UTXOFeeRate(satPerKvB: 6_798))

        let doge = ReaderBFakeTransport()
        doge.on("doge-a.test/v1/doge/main", data: try T.fixture("blockcypher-doge-chain.json"))
        doge.on("doge-b.test/dogecoin/stats", data: try T.fixture("blockchair-doge-stats.json"))
        let dogeReader = try UTXOReader(chain: .dogecoin, transport: doge, providers: [
            T.provider("blockcypher", "https://doge-a.test/v1/doge/main"), T.provider("blockchair", "https://doge-b.test/dogecoin"),
        ])
        let dogeFees = try await dogeReader.feeLevels()
        // Blockchair so da um numero (500.000 koinu/byte): entra no teto, nao nos niveis.
        #expect(dogeFees.estimates == [UTXOFeeRate(satPerKvB: 198_329_878), UTXOFeeRate(satPerKvB: 500_000_000)])
        #expect(dogeFees.slow == UTXOFeeRate(satPerKvB: 13_854_085))
        #expect(dogeFees.normal == UTXOFeeRate(satPerKvB: 60_447_023))
        #expect(dogeFees.fast == UTXOFeeRate(satPerKvB: 198_329_878))
        // As duas gravacoes sao de momentos diferentes: 215 blocos de distancia e demais.
        await #expect(throws: ChainReaderError.providersDisagree) { try await dogeReader.tipHeight() }
        doge.on("doge-b.test/dogecoin/stats", data: try T.fixture("blockchair-doge-stats.json", replacing: [("\"best_block_height\": 6389965", "\"best_block_height\": 6389752")]))
        #expect(try await dogeReader.tipHeight() == 6_389_750)
    }

    @Test("Altura: dois provedores longe demais um do outro e recusa; perto, vale a menor")
    func tipHeight() async throws {
        let transport = ReaderBFakeTransport()
        transport.on("esplora-a.test/api/blocks/tip/height", text: "968650")
        transport.on("esplora-b.test/api/blocks/tip/height", text: "968649\n")
        let reader = try UTXOReader(chain: .bitcoin, transport: transport, providers: T.esploraProviders)
        #expect(try await reader.tipHeight() == 968_649)
        transport.on("esplora-c.test/api/blocks/tip/height", text: "969650")
        await #expect(throws: ChainReaderError.providersDisagree) { try await reader.tipHeight() }
        transport.on("esplora-c.test/api/blocks/tip/height", text: "96865O")
        #expect(try await reader.tipHeight() == 968_649)
    }

    // MARK: Do estado ao plano

    @Test("Estado gravado ate o SigningPlan: moeda conferida, taxas de duas fontes, altura")
    func planFromRecordedState() async throws {
        let address = try T.derived(publicKeyHex: T.fundedPublicKey)
        let transport = try Self.coinTransport()
        for (key, name) in [("esplora-a.test/api/v1/fees/precise", "esplora-fees-precise.json"), ("esplora-b.test/api/fee-estimates", "esplora-fee-estimates.json")] {
            transport.on(key, data: try T.fixture(name))
        }
        let reader = try UTXOReader(chain: .bitcoin, transport: transport, providers: T.esploraProviders)
        let reading = try await reader.coins(for: [address])
        let fees = try await reader.feeLevels()
        let state = UTXONetworkState(coins: reading.coins, feeEstimates: fees.estimates, tipHeight: reading.tipHeight)

        let destination = try Address.validate(T.abandonReceive0, for: .bitcoin).get()
        let plan = try UTXOPlanner.planSend(
            walletID: UUID(), chain: .bitcoin,
            intent: UTXOSendIntent(destination: destination, amount: .all, feeRate: fees.normal, change: nil),
            network: state
        )
        #expect(plan.transactions.count == 1)
        let request = try #require(plan.transactions.first?.signingRequests.first)
        #expect(request.expectedPublicKey == address.publicKey)
        #expect(request.path == address.path)
        #expect(plan.review.lines.contains { $0.value == T.abandonReceive0 })
    }

    // MARK: Transmissao e acompanhamento

    static func signed(chain: Chain = .bitcoin) throws -> SignedTransaction {
        let hex = try T.text("esplora-tx-hex.txt")
        return SignedTransaction(chainID: chain.id, raw: try #require(Hex.decode(hex)), encoded: hex, id: T.fundedTxid)
    }

    @Test("Os mesmos bytes em todos os provedores; txid devolvido tem de ser o local")
    func broadcast() async throws {
        let signed = try Self.signed()
        let transport = ReaderBFakeTransport()
        transport.on("esplora-a.test/api/tx", text: T.fundedTxid)
        transport.on("esplora-b.test/api/tx", text: T.fundedTxid.uppercased() + "\n")
        transport.on("esplora-c.test/api/tx", text: String(repeating: "ab", count: 32))
        let reader = try UTXOReader(chain: .bitcoin, transport: transport, providers: T.esploraProviders)
        let receipt = try await reader.broadcast(signed)
        #expect(receipt.txid == T.fundedTxid)
        #expect(Set(receipt.acceptedBy) == ["mempool", "blockstream"])
        #expect(receipt.rejectedBy == ["emzy"])
        #expect(transport.requests.count == 3)
        for request in transport.requests {
            #expect(request.body == Data(signed.encoded.utf8))
            #expect(request.contentType == "text/plain")
        }
    }

    @Test("Transacao que nao fecha consigo mesma nao sai do aparelho")
    func broadcastRefusesInconsistent() async throws {
        let good = try Self.signed()
        let transport = ReaderBFakeTransport()
        let reader = try UTXOReader(chain: .bitcoin, transport: transport, providers: T.esploraProviders)
        let wrongID = SignedTransaction(chainID: "bitcoin", raw: good.raw, encoded: good.encoded, id: String(repeating: "0", count: 64))
        let wrongChain = SignedTransaction(chainID: "litecoin", raw: good.raw, encoded: good.encoded, id: good.id)
        let wrongHex = SignedTransaction(chainID: "bitcoin", raw: good.raw, encoded: String(good.encoded.dropLast(2)) + "01", id: good.id)
        for signed in [wrongID, wrongChain, wrongHex] {
            await #expect(throws: ChainReaderError.signedTransactionInconsistent) { try await reader.broadcast(signed) }
        }
        #expect(transport.requests.isEmpty)
        // Nenhum provedor aceitou.
        await #expect(throws: ChainReaderError.broadcastRejected) { try await reader.broadcast(good) }
    }

    @Test("Dogecoin: Blockcypher em JSON, Blockchair em formulario, mesmos bytes")
    func broadcastDogecoinFormats() async throws {
        let signed = try Self.signed(chain: .dogecoin)
        let transport = ReaderBFakeTransport()
        transport.on("doge-a.test/v1/doge/main/txs/push", data: Data("{\"tx\":{\"hash\":\"\(T.fundedTxid)\"}}".utf8))
        transport.on("doge-b.test/dogecoin/push/transaction", data: Data("{\"data\":{\"transaction_hash\":\"\(T.fundedTxid)\"}}".utf8))
        let reader = try UTXOReader(chain: .dogecoin, transport: transport, providers: [
            T.provider("blockcypher", "https://doge-a.test/v1/doge/main"), T.provider("blockchair", "https://doge-b.test/dogecoin"),
        ])
        let receipt = try await reader.broadcast(signed)
        #expect(Set(receipt.acceptedBy) == ["blockcypher", "blockchair"])
        let bodies = Dictionary(uniqueKeysWithValues: transport.requests.map { ($0.url.host ?? "", $0) })
        let json = try JSONDecoder().decode([String: String].self, from: try #require(bodies["doge-a.test"]?.body))
        #expect(json == ["tx": signed.encoded])
        #expect(bodies["doge-b.test"]?.body == Data("data=\(signed.encoded)".utf8))
        #expect(bodies["doge-b.test"]?.contentType == "application/x-www-form-urlencoded")
    }

    @Test("Status: confirmada so quando dois provedores confirmam")
    func status() async throws {
        let transport = ReaderBFakeTransport()
        for host in ["esplora-a.test", "esplora-b.test"] {
            transport.on("\(host)/api/blocks/tip/height", text: try T.text("esplora-tip-height.txt"))
            transport.on("\(host)/api/tx/\(T.fundedTxid)/status", data: try T.fixture("esplora-tx-status.json"))
        }
        let reader = try UTXOReader(chain: .bitcoin, transport: transport, providers: Array(T.esploraProviders.prefix(2)))
        #expect(try await reader.status(txid: T.fundedTxid) == .confirmed(height: 956_025, confirmations: 12_626))
        transport.on("esplora-b.test/api/tx/\(T.fundedTxid)/status", status: 404)
        #expect(try await reader.status(txid: T.fundedTxid) == .pending)
        transport.on("esplora-a.test/api/tx/\(T.fundedTxid)/status", status: 404)
        #expect(try await reader.status(txid: T.fundedTxid) == .notFound)
        transport.on("esplora-a.test/api/tx/\(T.fundedTxid)/status", data: try T.fixture("esplora-tx-status.json", replacing: [("956025", "956026")]))
        transport.on("esplora-b.test/api/tx/\(T.fundedTxid)/status", data: try T.fixture("esplora-tx-status.json"))
        await #expect(throws: ChainReaderError.providersDisagree) { try await reader.status(txid: T.fundedTxid) }
    }

    // MARK: Historico

    static func abandonDiscovery() throws -> UTXODiscovery {
        let account = try T.abandonAccount()
        let receive = try (0..<3).map { try account.address(change: false, index: $0) }
        let change = try account.address(change: true, index: 0)
        return UTXODiscovery(account: account, gapLimit: 20, used: [receive[0]], scanned: receive + [change], nextReceive: receive[1], nextChange: change)
    }

    @Test("Esplora: efeito liquido na carteira, taxa so quando a carteira pagou, poeira marcada")
    func historyEsplora() async throws {
        let transport = ReaderBFakeTransport()
        transport.on("esplora-a.test/api/blocks/tip/height", text: try T.text("esplora-tip-height.txt"))
        transport.on("esplora-a.test/api/address/\(T.abandonReceive0)/txs", data: try T.fixture("esplora-txs.json"))
        let reader = try UTXOReader(chain: .bitcoin, transport: transport, providers: [T.esploraProviders[0]])
        let items = try await reader.history(try Self.abandonDiscovery(), knownCounterparties: ["bc1q923wsupdm5xm0ctaahcc7ljfuf2v4ashu8nsem"])
        #expect(items.count == 6)
        let byID = Dictionary(uniqueKeysWithValues: items.map { (String($0.id.prefix(8)), $0) })

        // So OP_RETURN de valor zero: nada saiu alem da taxa.
        let burn = try #require(byID["fd4b2c20"])
        #expect(burn.kind == .selfTransfer && burn.movements.isEmpty && burn.fee == 1_000)
        // 1.000 sat de desconhecido: poeira.
        let dust = try #require(byID["f5a6d77a"])
        #expect(dust.kind == .receive && dust.movements == [.init(asset: .native, amount: 1_000, incoming: true)])
        #expect(dust.suspicion == .dust && dust.counterparty == "bc1q4hl33ar4c7lpry6ynu8a7v8duu0rz6wumwny3m")
        // Mesmo valor pequeno, de quem o dono conhece: nao e suspeito.
        #expect(byID["db40e263"]?.suspicion == nil)
        // Entrada de terceiro junto com a nossa: sem taxa atribuida, vale a perda liquida.
        let mixed = try #require(byID["e98b09d8"])
        #expect(mixed.kind == .send && mixed.fee == nil && mixed.movements.first?.amount == 670)
        let received = try #require(byID["bbdb8f9d"])
        #expect(received.kind == .receive && received.suspicion == nil && received.movements.first?.amount == 14_584)
        // Mais novo primeiro, com confirmacoes contadas do topo.
        let confirmations = items.map { item -> UInt32 in
            if case .confirmed(let count?) = item.status { return count }
            return 0
        }
        #expect(confirmations == confirmations.sorted())
        #expect(burn.status == .confirmed(confirmations: 968_650 - 956_025 + 1))
        #expect(try await reader.history(try Self.abandonDiscovery(), limit: 2).count == 2)
    }

    @Test("Blockcypher: efeito por endereco somado por transacao")
    func historyBlockcypher() async throws {
        let account = try T.abandonAccount(chain: .dogecoin, kind: .p2pkh)
        let first = try account.address(change: false, index: 0)
        // O endereco da fixture no lugar do derivado: o historico por delta so usa o texto.
        let recorded = UTXODerivedAddress(
            address: "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC", path: first.path, publicKey: first.publicKey,
            scriptPubKey: first.scriptPubKey, isChange: false, index: 0
        )
        let discovery = UTXODiscovery(account: account, gapLimit: 20, used: [recorded], scanned: [recorded], nextReceive: first, nextChange: first)
        let transport = ReaderBFakeTransport()
        transport.on("doge-a.test/v1/doge/main", data: try T.fixture("blockcypher-doge-chain.json"))
        transport.on("doge-a.test/v1/doge/main/addrs/DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC", data: try T.fixture("blockcypher-doge-address.json"))
        let reader = try UTXOReader(chain: .dogecoin, transport: transport, providers: [T.provider("blockcypher", "https://doge-a.test/v1/doge/main")])
        let items = try await reader.history(discovery)
        let byID = Dictionary(uniqueKeysWithValues: items.map { (String($0.id.prefix(8)), $0) })
        #expect(byID["8a9fad93"]?.kind == .send)
        #expect(byID["8a9fad93"]?.movements.first?.amount == 214_674_000_000)
        #expect(byID["d1e3b968"]?.kind == .receive)
        #expect(byID["d1e3b968"]?.suspicion == nil)
        #expect(items.allSatisfy { if case .confirmed = $0.status { return true } else { return false } })
    }

    // MARK: Pecas

    @Test("Valores decimais sem ponto flutuante, e formulario com base64 codificado")
    func units() throws {
        #expect(try DecimalUnits.parse("154.0697710", decimals: 7, field: "") == 1_540_697_710)
        #expect(try DecimalUnits.parse("7", decimals: 7, field: "") == 70_000_000)
        #expect(throws: ChainReaderError.self) { try DecimalUnits.parse("1.23456789", decimals: 7, field: "") }
        #expect(throws: ChainReaderError.self) { try DecimalUnits.parse("-1.0", decimals: 7, field: "") }
        #expect(throws: ChainReaderError.self) { try DecimalUnits.parse("1e5", decimals: 7, field: "") }
        #expect(throws: ChainReaderError.self) { try DecimalUnits.parse("1.", decimals: 7, field: "") }
        #expect(DecimalUnits.format(1_000_000_000, decimals: 7) == "100.0000000")
        #expect(DecimalUnits.format(1, decimals: 7) == "0.0000001")
        #expect(ReaderURL.formBody([("tx", "AA+/b=")]) == Data("tx=AA%2B%2Fb%3D".utf8))
        // sat/vB do JSON para sat/kvB: para cima, sem o ruido do ponto flutuante.
        #expect(try UTXOProviderClient.rate(satPerVByte: 3.303) == UTXOFeeRate(satPerKvB: 3_303))
        #expect(try UTXOProviderClient.rate(satPerVByte: 0.619) == UTXOFeeRate(satPerKvB: 619))
        #expect(try UTXOProviderClient.rate(satPerVByte: 2.1109999999999998) == UTXOFeeRate(satPerKvB: 2_111))
        #expect(try UTXOProviderClient.rate(satPerVByte: 0.3411) == UTXOFeeRate(satPerKvB: 342))
        #expect(try UTXOProviderClient.rate(satPerVByte: 0.0001) == UTXOFeeRate(satPerKvB: 1))
        #expect(throws: ChainReaderError.self) { try UTXOProviderClient.rate(satPerVByte: -1) }
        #expect(throws: ChainReaderError.self) { try UTXOProviderClient.rate(satPerVByte: .nan) }
    }
}
