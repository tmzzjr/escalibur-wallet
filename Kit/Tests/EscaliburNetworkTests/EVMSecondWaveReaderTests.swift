import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Provedores e leitor das redes EVM da segunda leva (Plasma, X Layer, Linea, Unichain,
/// Sonic e Celo), sem rede.
@Suite("Leitor EVM: redes da segunda leva")
struct EVMSecondWaveReaderTests {
    static let owner = try! EVMAddress("0xF977814e90dA44bFA03b6295A0616a897441aceC")
    static let destination = try! EVMAddress("0x28C6c06298d514Db089934071355E5743bf21d60")
    static let chains: [Chain] = [.plasma, .xlayer, .linea, .unichain, .sonic, .celo]

    @Test("Unichain: o RPC oficial fica por ultimo (nonce pending instavel)")
    func unichainOrder() {
        #expect(Endpoints.evm["unichain"]?.map(\.name) == ["publicnode", "drpc", "unichain"])
    }

    @Test("RPCs: tres por rede, de operadores diferentes, todos https", arguments: chains)
    func rpcLists(chain: Chain) throws {
        let list = try #require(Endpoints.evm[chain.id])
        #expect(list.count >= 3)
        #expect(Set(list.map(\.name)).count == list.count)
        #expect(Set(list.compactMap(\.baseURL.host)).count == list.count)
        #expect(list.allSatisfy { $0.baseURL.scheme == "https" })
        // Os dois primeiros formam o consenso: nunca da mesma empresa.
        #expect(list[0].name != list[1].name)
    }

    @Test("Historico: indexador sem chave onde existe; X Layer e Sonic sem, como a BNB Chain")
    func history() {
        #expect(Endpoints.evmHistory["plasma"]?.map(\.name) == ["routescan"])
        #expect(Endpoints.evmHistory["plasma"]?.first?.baseURL.absoluteString
            == "https://api.routescan.io/v2/network/mainnet/evm/9745/etherscan/api")
        for id in ["linea", "unichain", "celo"] {
            #expect(Endpoints.evmHistory[id]?.map(\.name) == ["blockscout"], "\(id)")
            #expect(Endpoints.evmHistory[id]?.first?.baseURL.path == "/api/v2", "\(id)")
        }
        #expect(Endpoints.evmHistory["xlayer"] == nil)
        #expect(Endpoints.evmHistory["sonic"] == nil)
    }

    @Test("Simulacao da troca: duas fontes ou mais onde ha troca; nenhuma na X Layer e na Celo")
    func tradeSimulation() {
        for id in ["plasma", "linea", "unichain"] {
            #expect((Endpoints.tradeSimulation[id]?.count ?? 0) == 2, "\(id)")
        }
        #expect(Endpoints.tradeSimulation["sonic"]?.count == 3)
        #expect(Endpoints.tradeSimulation["xlayer"] == nil)
        #expect(Endpoints.tradeSimulation["celo"] == nil)
        // Toda fonte de simulacao tambem e um RPC da rede ja listado.
        for (id, sims) in Endpoints.tradeSimulation where Self.chains.map(\.id).contains(id) {
            let reads = Set((Endpoints.evm[id] ?? []).map(\.baseURL))
            #expect(sims.allSatisfy { reads.contains($0.baseURL) }, "\(id)")
        }
    }

    @Test("KyberSwap: trecho de rede so onde o router esta na allowlist")
    func kyberSlugs() {
        #expect(KyberSwapClient.slugs[9745] == "plasma")
        #expect(KyberSwapClient.slugs[59144] == "linea")
        #expect(KyberSwapClient.slugs[130] == "unichain")
        #expect(KyberSwapClient.slugs[146] == "sonic")
        #expect(KyberSwapClient.slugs[196] == nil)
        #expect(KyberSwapClient.slugs[42220] == nil)
        for (chainID, _) in KyberSwapClient.slugs {
            let chain = Chain.evmChains.first { $0.evmChainID == chainID }
            #expect(chain.flatMap { TradeAllowlist.router(for: .kyberSwap, on: $0) } != nil, "\(chainID)")
        }
    }

    @Test("Bloco fixado: uns 10 segundos atras da ponta em cada rede")
    func pinLag() {
        #expect(EVMReader.pinLag(.plasma) == 10)
        #expect(EVMReader.pinLag(.xlayer) == 10)
        #expect(EVMReader.pinLag(.unichain) == 10)
        #expect(EVMReader.pinLag(.celo) == 10)
        #expect(EVMReader.pinLag(.sonic) == 6)
        #expect(EVMReader.pinLag(.linea) == 2)
    }

    static func transport(chainID: String, l1Fee: String) throws -> FixtureTransport {
        let recorded: [String: Data] = [
            "eth_chainId": rpcResult("\"\(chainID)\""),
            "eth_blockNumber": try ReaderFixtures.data("evm", "eth_blockNumber-ethereum"),
            "eth_getTransactionCount": try ReaderFixtures.data("evm", "eth_getTransactionCount-binance8"),
            "eth_feeHistory": try ReaderFixtures.data("evm", "eth_feeHistory-ethereum"),
            "eth_estimateGas": try ReaderFixtures.data("evm", "eth_estimateGas-nativo"),
            "eth_getCode": try ReaderFixtures.data("evm", "eth_getCode-eoa"),
            "eth_getBalance": try ReaderFixtures.data("evm", "eth_getBalance-binance8"),
            "eth_call": rpcResult("\"\(l1Fee)\""),
        ]
        return FixtureTransport([{ _, body in FixtureTransport.method(body).flatMap { recorded[$0] } }])
    }

    static func reader(_ transport: FixtureTransport, chain: Chain) -> EVMReader {
        EVMReader(transport: transport, rpc: [chain.id: testProviders("a", "b")], history: [:], privateRelays: [])
    }

    static let zero = "0x" + String(repeating: "0", count: 64)
    static let someFee = "0x" + String(repeating: "0", count: 56) + "58f10260"

    @Test("Taxa L1: zero vale na Celo e na X Layer (oraculo em zero), e e recusado na Unichain")
    func l1FeeZero() async throws {
        for (chain, hex) in [(Chain.celo, "0xa4ec"), (.xlayer, "0xc4")] {
            let state = try await Self.reader(try Self.transport(chainID: hex, l1Fee: Self.zero), chain: chain)
                .networkState(chain: chain, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
            #expect(state.l1DataFee == 0, "\(chain.id)")
        }
        await #expect(throws: ReaderError.implausibleValue(field: "getL1FeeUpperBound")) {
            _ = try await Self.reader(try Self.transport(chainID: "0x82", l1Fee: Self.zero), chain: .unichain)
                .networkState(chain: .unichain, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        }
        let unichain = try await Self.reader(try Self.transport(chainID: "0x82", l1Fee: Self.someFee), chain: .unichain)
            .networkState(chain: .unichain, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        #expect(unichain.l1DataFee == BigUInt(0x58f1_0260))
        // Plasma, Linea e Sonic nao tem taxa L1: nem perguntam ao oraculo.
        let plasma = try await Self.reader(try Self.transport(chainID: "0x2611", l1Fee: Self.someFee), chain: .plasma)
            .networkState(chain: .plasma, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        #expect(plasma.l1DataFee == nil)
    }

    @Test("RPC que responde o chainId de outra rede e descartado na rede nova")
    func wrongChainID() async throws {
        // Um RPC da Base (8453) configurado como Plasma.
        let reader = EVMReader(transport: try Self.transport(chainID: "0x2105", l1Fee: Self.zero), rpc: ["plasma": testProviders("a")],
                               history: [:], privateRelays: [])
        await #expect(throws: ReaderError.wrongNetwork) {
            _ = try await reader.networkState(chain: .plasma, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        }
    }

    @Test("Celo: transferencia do contrato do CELO vale como CELO nativo, sem contar duas vezes")
    func celoNativeToken() throws {
        let celoToken = try EVMAddress("0x471EcE3750Da237f93B8E339c536989b8978a438")
        let stranger = try EVMAddress("0x2652742DE21ED9a6c37e73b0E3a51b239A6D1008")
        let exchange = try EVMAddress("0x1111111111111111111111111111111111111111")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let one = BigUInt.power(of: 10, 18)
        let rows = [
            // Envio nativo direto do dono: a transacao e o evento do contrato sao o mesmo movimento.
            EVMReader.TransactionRow(hash: "0x01", date: now, status: .confirmed, from: Self.owner, to: stranger, value: one, fee: 10),
        ]
        let tokens = [
            EVMReader.TokenRow(hash: "0x01", index: "0", date: now, from: Self.owner, to: stranger, contract: celoToken, amount: one),
            // 5 CELO pagos por contrato de terceiro (saque de corretora): so o evento mostra.
            EVMReader.TokenRow(hash: "0x02", index: "3", date: now, from: exchange, to: Self.owner, contract: celoToken,
                               amount: one * BigUInt(5)),
        ]
        let page = EVMReader.assemble(chain: .celo, owner: Self.owner, rows: rows, tokens: tokens)
        let sent = page.items.filter { $0.direction == .sent }
        #expect(sent.count == 1)
        #expect(sent.first?.asset == Asset.native(.celo) && sent.first?.amount == one)
        let received = try #require(page.items.first { $0.direction == .received })
        #expect(received.asset == Asset.native(.celo))
        #expect(received.amount == one * BigUInt(5))
        #expect(page.suspiciousCount == 0)
        // Na Base o mesmo contrato seria token fora da lista: suspeito.
        let base = EVMReader.assemble(chain: .base, owner: Self.owner, rows: [], tokens: [tokens[1]])
        #expect(base.items.isEmpty && base.suspicious.unknownAsset == 1)
    }

    @Test("Blockscout da Celo: indice de log negativo (transferencia de CELO sintetizada) nao derruba a pagina")
    func celoNegativeLogIndex() throws {
        let tokens = try StrictJSON.parse(Data("""
        {"items":[{"transaction_hash":"0x210d92a2b6000000000000000000000000000000000000000000000000000000","log_index":-1180000,
        "timestamp":"2026-09-20T10:00:00.000000Z","from":{"hash":"0x1111111111111111111111111111111111111111"},
        "to":{"hash":"0xF977814e90dA44bFA03b6295A0616a897441aceC"},
        "token":{"address_hash":"0x471EcE3750Da237f93B8E339c536989b8978a438"},"total":{"value":"243251000000000000"}}]}
        """.utf8))
        let page = try EVMReader.parseBlockscoutHistory(chain: .celo, owner: Self.owner, transactions: .object(["items": .array([])]),
                                                        tokenTransfers: tokens)
        let item = try #require(page.items.first)
        #expect(item.direction == .received && item.asset == Asset.native(.celo))
        #expect(item.amount == BigUInt(decimal: "243251000000000000")!)
        #expect(item.id.hasSuffix(":-1180000"))
    }

    @Test("X Layer e Sonic: sem indexador, erro com motivo")
    func noIndexer() async throws {
        let reader = EVMReader(transport: try Self.transport(chainID: "0xc4", l1Fee: Self.zero))
        for chain in [Chain.xlayer, .sonic] {
            await #expect(throws: ReaderError.unsupported("historico sem indexador publico nesta rede")) {
                _ = try await reader.history(chain: chain, address: Self.owner)
            }
        }
    }
}
