import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Os leitores contra os provedores reais. So com ESCALIBUR_REDE=1.
///
/// Leem estado publico de enderecos conhecidos e levam esse estado ate o
/// `SigningPlan`. Nada e assinado nem transmitido: os planos usam chaves publicas de
/// terceiros, e a chave privada nem existe aqui.
@Suite("ReaderB ao vivo", .enabled(if: ReaderBTest.live), .serialized)
struct ReaderBLiveTests {
    typealias T = ReaderBTest

    // MARK: Bitcoin

    @Test("Bitcoin: a xpub publica do BIP-84 acha os enderecos com historico, sem sair do aparelho")
    func bitcoinDiscovery() async throws {
        let reader = try UTXOReader(chain: .bitcoin)
        let account = try T.abandonAccount()
        let found = try await reader.discover(account)
        // bc1qcr8te4kr... (indice 0) recebe e gasta desde 2019: tem historico.
        #expect(found.usedReceiveIndices.contains(0))
        #expect(!found.usedReceiveIndices.contains(found.nextReceive.index))
        #expect(!found.usedChangeIndices.contains(found.nextChange.index))
        #expect(found.changeAddress.path.components[3] == 1)

        let reading = try await reader.coins(for: found.used)
        #expect(reading.rejected.isEmpty)
        let history = try await reader.history(found)
        #expect(!history.isEmpty && history.count <= 30)
        #expect(history.allSatisfy { $0.transactionHash?.count == 64 })
        // A conta e publica: qualquer um manda poeira e os robos varrem. Ha de ter
        // recebimento pequeno marcado.
        #expect(history.contains { $0.suspicion == .dust } || history.allSatisfy { $0.kind != .receive })
    }

    @Test("Bitcoin: moeda real ate o SigningPlan (sem assinar, sem transmitir)")
    func bitcoinPlan() async throws {
        let reader = try UTXOReader(chain: .bitcoin)
        let (address, reading) = try await Self.spendable(
            reader: reader, chain: .bitcoin, esplora: "https://mempool.space/api",
            known: [(T.fundedAddress, T.fundedPublicKey), ("bc1qm9dpm35mmfy2gnuvlx3zaew8psc9frr8vu7eyl", "035f1b24f3891854ac7ab57b762fe4d15bec6032b0ff7bd370ae0ecc926f856d7b")]
        )
        let fees = try await reader.feeLevels()
        #expect(fees.estimates.count >= 2)
        #expect(fees.slow <= fees.normal && fees.normal <= fees.fast)
        #expect(reading.tipHeight > 900_000)
        try Self.plan(chain: .bitcoin, address: address, reading: reading, fees: fees, to: T.abandonReceive0)
        #expect(try await reader.status(txid: reading.coins[0].outpoint.txid.hex).isConfirmed)
    }

    // MARK: Litecoin

    @Test("Litecoin: taxa de duas fontes, moeda real ate o SigningPlan")
    func litecoinPlan() async throws {
        let reader = try UTXOReader(chain: .litecoin)
        let fees = try await reader.feeLevels()
        #expect(fees.estimates.count >= 2)
        let (address, reading) = try await Self.spendable(
            reader: reader, chain: .litecoin, esplora: "https://litecoinspace.org/api",
            known: [
                ("ltc1qd0gvlz0axrkjlr6asm4qfxap9fvjhrz3sng48n", "0257eb4cc2b5f74b38079257eda7212f908638af170069c2ffc48be9d9b2ec431e"),
                ("ltc1qqwr6agnv0wn2h00j33aay4gurkdezmjvgduud5", "037c1f43455972a7b3884acf838b0d438fd0f3fe98236efa4619ef0ef1c49cf89d"),
            ]
        )
        #expect(reading.tipHeight > 3_000_000)
        let destination = try T.abandonAccount(chain: .litecoin).address(change: false, index: 0).address
        try Self.plan(chain: .litecoin, address: address, reading: reading, fees: fees, to: destination)
    }

    // MARK: Dogecoin

    @Test("Dogecoin: altura, historico e status pela Blockcypher; taxa com a Blockchair")
    func dogecoin() async throws {
        let reader = try UTXOReader(chain: .dogecoin)
        #expect(try await reader.tipHeight() > 6_000_000)

        let account = try T.abandonAccount(chain: .dogecoin, kind: .p2pkh)
        let first = try account.address(change: false, index: 0)
        let recorded = UTXODerivedAddress(
            address: "DBus3bamQjgJULBJtYXpEzDWQRwF5iwxgC", path: first.path, publicKey: first.publicKey,
            scriptPubKey: first.scriptPubKey, isChange: false, index: 0
        )
        let discovery = UTXODiscovery(account: account, gapLimit: 20, used: [recorded], scanned: [recorded], nextReceive: first, nextChange: first)
        let history = try await reader.history(discovery)
        #expect(history.contains { $0.id == "8a9fad9305b739ee3353dfab8d6312478643b5089d204e4a575d6a6e3bea6cc5" && $0.kind == .send })
        #expect(try await reader.status(txid: "8a9fad9305b739ee3353dfab8d6312478643b5089d204e4a575d6a6e3bea6cc5").isConfirmed)

        // Sem chave de API a Blockchair bloqueia o IP por um tempo (HTTP 430); ai sobra
        // uma fonte de taxa, e o leitor recusa em vez de planejar com uma so.
        do {
            let fees = try await reader.feeLevels()
            #expect(fees.estimates.count >= 2 && fees.slow >= UTXORules.for(.dogecoin).minimumFeeRate)
        } catch ChainReaderError.notEnoughSources(needed: 2, got: let got) {
            #expect(got == 1)
        }
    }

    // MARK: Stellar

    static let circleIssuer = "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"
    static let memoRequired = "GDQP2KPQGKIHYJGXNUIYOMHARUARCA7DJT5FO2FFOOKY3B2WSQHG4W37"
    static let missing = "GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6"

    @Test("Stellar: estado real da conta (SDF e LOBSTR concordando) ate o SigningPlan")
    func stellarPlan() async throws {
        let reader = StellarReader()
        let owner = try #require(StellarAccountID(address: Self.circleIssuer))
        let account = try #require(try await Self.retrying { try await reader.ownerAccount(owner) })
        #expect(account.sequence > 0 && account.balance > 10_000_000)
        let network = try await reader.networkState()
        #expect(network.baseReserve == 5_000_000 && network.baseFee == 100)

        let memoDestination = try await reader.destination(Self.memoRequired)
        #expect(memoDestination.exists && memoDestination.memoRequired)
        #expect(try await reader.destination(Self.missing) == .missing)

        let context = StellarPlanContext(
            walletID: UUID(), source: try StellarSource(path: DefaultPaths.path(for: .stellar), publicKey: owner.publicKey),
            account: account, network: network, allowedAssets: []
        )
        // Destino com memo obrigatorio: sem memo, recusa; com memo, plano.
        #expect(throws: StellarPlanError.self) {
            try StellarPlanner.planSendNative(amount: 10_000_000, to: Self.memoRequired, destination: memoDestination, context: context)
        }
        let plan = try StellarPlanner.planSendNative(
            amount: 10_000_000, to: Self.memoRequired, memo: try StellarMemo.fromID("12345"),
            destination: memoDestination, context: context
        )
        #expect(plan.transactions.first?.signingRequests.first?.expectedPublicKey == owner.publicKey)
        // Destino inexistente: CreateAccount, com o aviso de ativacao.
        let create = try StellarPlanner.planSendNative(amount: 10_000_000, to: Self.missing, destination: .missing, context: context)
        #expect(create.review.warnings.contains { if case .activatesAccount = $0 { return true } else { return false } })
    }

    @Test("Stellar: cotacao, ofertas, historico e status")
    func stellarReads() async throws {
        let reader = StellarReader()
        let usdc = try StellarAsset(code: "USDC", issuer: Self.circleIssuer)
        let quote = try #require(try await reader.quoteStrictSend(send: .native, amount: 1_000_000_000, receive: usdc))
        #expect(quote.receiveAmount > 0 && quote.path.count <= 5)

        let busy = try #require(StellarAccountID(address: "GA5XIGA5C7QTPTWXQHY6MCJRMTRZDOSHR6EFIBNDQTCQHG262N4GGKTM"))
        let history = try await reader.history(busy, listedAssets: [usdc])
        #expect(!history.isEmpty && history.count <= 30)

        let maker = try #require(StellarAccountID(address: "GB3FQB7JYQ37PVYL3DE7ZWYMQCDXZFQBLA23HHJOYA3MIOHCSLT3BCYY"))
        for offer in try await reader.offers(maker) { #expect(offer.id > 0 && offer.priceDenominator > 0) }

        if let hash = history.compactMap(\.transactionHash).first {
            #expect(try await Self.retrying { try await reader.status(hash: hash) }.isConfirmed)
        }
    }

    // MARK: Apoio

    /// Uma moeda confirmada e gastavel num endereco com chave publica conhecida: das
    /// conhecidas, ou procurada no ultimo bloco (entrada P2WPKH de endereco reusado).
    static func spendable(
        reader: UTXOReader, chain: Chain, esplora: String, known: [(String, String)]
    ) async throws -> (UTXODerivedAddress, UTXOCoinReading) {
        var candidates = known
        if let found = try? await searchTip(esplora: esplora) { candidates += found }
        let floor = UTXORules.for(chain).protectionThreshold(for: .p2wpkh, chain: chain)
        for (address, key) in candidates {
            guard let derived = try? T.derived(publicKeyHex: key, chain: chain, index: 0), derived.address == address,
                  let reading = try? await reader.coins(for: [derived]), reading.rejected.isEmpty
            else { continue }
            let usable = reading.coins.filter { $0.confirmations > 0 && (reading.values[$0.outpoint] ?? 0) > floor * 20 }
            if !usable.isEmpty {
                return (derived, UTXOCoinReading(coins: usable, rejected: [], tipHeight: reading.tipHeight, values: reading.values))
            }
        }
        throw ChainReaderError.notEnoughSources(needed: 1, got: 0)
    }

    /// Entradas P2WPKH do ultimo bloco: a witness traz a chave publica.
    static func searchTip(esplora: String) async throws -> [(String, String)] {
        let client = HTTPClient.shared
        let hash = String(decoding: try await client.get(URL(string: "\(esplora)/blocks/tip/hash")!), as: UTF8.self)
        let data = try await client.get(URL(string: "\(esplora)/block/\(hash)/txs/0")!)
        let txs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var found: [(String, String)] = []
        for tx in txs {
            for input in tx["vin"] as? [[String: Any]] ?? [] {
                guard let prevout = input["prevout"] as? [String: Any], prevout["scriptpubkey_type"] as? String == "v0_p2wpkh",
                      let address = prevout["scriptpubkey_address"] as? String,
                      let witness = input["witness"] as? [String], witness.count == 2, witness[1].count == 66
                else { continue }
                found.append((address, witness[1]))
            }
        }
        return Array(found.prefix(12))
    }

    /// `.all` para `destination` com as moedas lidas: sem troco, entao sem xpub.
    static func plan(chain: Chain, address: UTXODerivedAddress, reading: UTXOCoinReading, fees: UTXOFeeLevels, to destination: String) throws {
        let state = UTXONetworkState(coins: reading.coins, feeEstimates: fees.estimates, tipHeight: reading.tipHeight)
        let plan = try UTXOPlanner.planSend(
            walletID: UUID(), chain: chain,
            intent: UTXOSendIntent(destination: try Address.validate(destination, for: chain).get(), amount: .all, feeRate: fees.normal, change: nil),
            network: state
        )
        let requests = try #require(plan.transactions.first).signingRequests
        #expect(requests.count == reading.coins.count)
        #expect(requests.allSatisfy { $0.expectedPublicKey == address.publicKey && $0.path == address.path })
        #expect(plan.review.lines.contains { $0.value == destination })
    }

    /// Consenso que falha por um ledger de diferenca entre as duas Horizon: tenta de novo.
    static func retrying<R: Sendable>(_ body: @Sendable () async throws -> R) async throws -> R {
        do {
            return try await body()
        } catch ChainReaderError.providersDisagree {
            try await Task.sleep(nanoseconds: 6_000_000_000)
            return try await body()
        }
    }
}

extension ChainTransactionStatus {
    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }
}
