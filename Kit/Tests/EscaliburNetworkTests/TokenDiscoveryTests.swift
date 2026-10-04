import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Tudo o que a conta tem, sem rede: o indexador EVM (Blockscout e Routescan) com o saldo
/// relido no Multicall3, a lista `trc20` da TronGrid com nome e casas lidos do contrato, os
/// jettons da tonapi, as contas de token da Solana com a Metaplex, os saldos da Stellar, a
/// leitura da moeda custom antes de salvar e o preco por contrato. Respostas gravadas em
/// Fixtures/leitores/tokens (04/10/2026, conta publica de teste do BIP-39 e contas publicas
/// de emissor; ver LEIA-ME.txt).
@Suite("Tokens fora da lista: descoberta, moeda custom e preco por contrato")
struct TokenDiscoveryTests {
    static let owner = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
    static let custom = Asset(
        chainID: "base", kind: .token(contract: "0x58bDC4310db1b19854Ca9066deEd7E3dF4F2Ec9B"), symbol: "ABC", name: "Abc",
        decimals: 6, coingeckoID: nil, isStablecoin: false, origin: .custom
    )
    static let openAI = "0xd77cD3531c306204069684F48Af23F1213FE0165"
    static let xau = "0x3C3689f93A9869D1176Ccd187f93AD196EaF103E"
    static let decimalsSelector: [UInt8] = [0x31, 0x3c, 0xe5, 0x67]

    static func data(_ name: String) throws -> Data { try ReaderFixtures.data("tokens", name) }

    // MARK: EVM

    /// Base: o Blockscout diz quais contratos a conta tem; saldo e casas vem do Multicall3.
    static func baseTransport(indexer: Bool = true) -> FixtureTransport {
        FixtureTransport([{ request, body in
            if request.url.host == "idx.test" {
                guard indexer else { throw HTTPClient.Failure.status(503) }
                #expect(request.url.path.hasSuffix("/addresses/\(Self.owner)/tokens"))
                return try Self.data("blockscout-tokens-base")
            }
            switch FixtureTransport.method(body) {
            case "eth_getBalance": return rpcResult("\"0x0\"")
            case "eth_call":
                let calls = try BalanceBatchTests.calls(body)
                let items: [(Bool, [UInt8])] = calls.map { call in
                    let target = call.target.checksummed
                    if Array(call.data.prefix(4)) == Self.decimalsSelector {
                        // O indexador diz 18 para o OpenAI; a rede diz 6, e vale a rede.
                        return (true, BalanceBatchTests.word(target == Self.openAI ? 6 : 18))
                    }
                    if target == Self.custom.contractForTests { return (true, BalanceBatchTests.word(7_000_000)) }
                    if target == Self.xau { return (true, BalanceBatchTests.word(0)) }
                    if target == Self.openAI { return (true, BalanceBatchTests.word(4_000_000)) }
                    if TokenRegistry.find(chainID: "base", contract: target) != nil { return (true, BalanceBatchTests.word(0)) }
                    return (true, BalanceBatchTests.word(1_000_000_000_000_000_000))
                }
                return rpcResult("\"\(try BalanceBatchTests.aggregate3Result(items))\"")
            default: return nil
            }
        }])
    }

    static func service(_ transport: FixtureTransport) -> BalanceService {
        BalanceService(
            client: .shared, transport: transport, evm: ["base": testProviders("rpc-a")], xrpl: [],
            tokenIndex: ["base": ProviderPool.Provider(name: "blockscout", baseURL: URL(string: "https://idx.test/api/v2")!)]
        )
    }

    @Test("Base: os 17 tokens do indexador, com saldo e casas relidos na rede, a moeda custom e o filtro de golpe")
    func evmDiscovery() async throws {
        let transport = Self.baseTransport()
        let balance = try await Self.service(transport).balance(chain: .base, addresses: [Self.owner], custom: [Self.custom])
        // A moeda custom entra no saldo como qualquer outra, marcada.
        let custom = try #require(balance.holdings.first { $0.asset == Self.custom })
        #expect(custom.amount == BigUInt(7_000_000) && custom.asset.isCustom)
        let unlisted = try #require(balance.unlisted)
        // XAU tem saldo zero na rede (o indexador dizia 9): fica fora.
        #expect(unlisted.count == 16)
        #expect(!unlisted.contains { $0.asset.id == "base:\(Self.xau)" })
        // OpenAI: saldo e casas da rede, nao do indexador.
        let openAI = try #require(unlisted.first { $0.asset.id == "base:\(Self.openAI)" })
        #expect(openAI.amount == BigUInt(4_000_000) && openAI.asset.decimals == 6 && !openAI.isSuspicious)
        #expect(openAI.asset.origin == .discovered && openAI.asset.coingeckoID == nil)
        // Os que nao levantam suspeita vem primeiro; os de golpe ficam marcados.
        #expect(unlisted.prefix(2).allSatisfy { !$0.isSuspicious })
        #expect(unlisted.filter(\.isSuspicious).count == 14)
        let fakeUSDC = try #require(unlisted.first { $0.asset.id == "base:0xe6758D2203A62C16960c55E97b43fA0Cfed93b1A" })
        #expect(fakeUSDC.reasons.contains(.link) && fakeUSDC.reasons.contains(.bait))
        #expect(balance.unknownTokenCount == 16)
        // Uma leitura de saldo nativo, o indexador, um lote de saldos e um de casas.
        #expect(transport.requests.count == 4)
    }

    @Test("Indexador fora do ar: a lista e a moeda custom continuam")
    func evmIndexerDown() async throws {
        let balance = try await Self.service(Self.baseTransport(indexer: false)).balance(chain: .base, addresses: [Self.owner], custom: [Self.custom])
        #expect(balance.holdings.contains { $0.asset == Self.custom })
        #expect(balance.unlisted == [])
    }

    @Test("Blockscout: pagina seguinte pelos parametros que a propria resposta da")
    func blockscoutPaging() async throws {
        let first = """
        {"items":[{"token":{"address_hash":"0x58bDC4310db1b19854Ca9066deEd7E3dF4F2Ec9B","name":"A","symbol":"A","decimals":"6","type":"ERC-20","reputation":"ok"},"value":"1"}],
         "next_page_params":{"fiat_value":null,"id":1234,"items_count":50,"value":"1"}}
        """
        let second = """
        {"items":[{"token":{"address_hash":"0x1111111111111111111111111111111111111111","name":null,"symbol":null,"decimals":null,"type":"ERC-20","reputation":"scam"},"value":"2"},
                  {"token":{"address_hash":"0x2222222222222222222222222222222222222222","name":"NFT","symbol":"N","decimals":null,"type":"ERC-721"},"value":"1"}],
         "next_page_params":null}
        """
        let transport = FixtureTransport([{ request, _ in
            let query = request.url.query ?? ""
            return Data((query.contains("id=1234") ? second : first).utf8)
        }])
        let provider = ProviderPool.Provider(name: "blockscout", baseURL: URL(string: "https://idx.test/api/v2")!)
        let tokens = try await TokenIndex.fetch(provider, owner: try EVMAddress(Self.owner), transport: transport)
        #expect(tokens.count == 2)
        #expect(tokens[1].flagged && tokens[1].decimals == nil && tokens[1].symbol.isEmpty)
        #expect(transport.requests.count == 2)
        let query = transport.requests[1].url.query ?? ""
        #expect(query.contains("type=ERC-20") && query.contains("items_count=50") && !query.contains("fiat_value"))
    }

    @Test("Routescan (Avalanche): os ERC-20 da conta; BUSD.e de poeira fica suspeito")
    func routescan() throws {
        let tokens = try TokenIndex.parseRoutescan(StrictJSON.parse(Self.data("routescan-erc20-holdings-avalanche")))
        #expect(tokens.count == 2)
        let busd = try #require(tokens.first { $0.symbol == "BUSD.e" })
        let holding = UnlistedHolding.make(
            chain: .avalanche, kind: .token(contract: busd.contract.checksummed), symbol: busd.symbol, name: busd.name,
            decimals: busd.decimals ?? 0, amount: BigUInt(500_000_000)
        )
        #expect(holding.reasons == [.dust])
    }

    // MARK: Tron

    @Test("Tron: USDT da lista, e os outros TRC-20 com nome, simbolo e casas lidos do contrato")
    func tron() async throws {
        let transport = FixtureTransport([{ request, body in
            if request.url.host == "trongrid.test" { return try Self.data("trongrid-account-abandon") }
            guard request.url.path.hasSuffix("wallet/triggerconstantcontract"), case .object(let fields)? = body,
                  case .string("TQGaH1PigTUJsSbCootv52Hi92Gx2Hbmw8")? = fields["contract_address"],
                  case .string(let selector)? = fields["function_selector"]
            else { throw HTTPClient.Failure.status(500) }
            return try Self.data("tron-constant-\(selector.replacingOccurrences(of: "()", with: ""))-kyc")
        }])
        let service = BalanceService(client: .shared, transport: transport, evm: [:], xrpl: [], tron: testProviders("trongrid"))
        let balance = try await service.balance(chain: .tron, addresses: ["TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH"])
        #expect(balance.holdings.contains { $0.asset.symbol == "USDT" && $0.asset.isVerified && $0.amount == BigUInt(8_235_005_783) })
        let unlisted = try #require(balance.unlisted)
        #expect(unlisted.count == 5)
        let kyc = try #require(unlisted.first { $0.asset.id == "tron:TQGaH1PigTUJsSbCootv52Hi92Gx2Hbmw8" })
        #expect(kyc.asset.symbol == "KYC" && kyc.asset.name == "KYC Public Welfare Token" && kyc.asset.decimals == 6)
        #expect(kyc.amount == BigUInt(1_000_000) && !kyc.isSuspicious)
    }

    // MARK: TON

    @Test("TON: jettons da tonapi; lista negra da propria tonapi vira suspeito; moeda custom casa pelo mestre")
    func tonJettons() throws {
        let json = try StrictJSON.parse(Self.data("tonapi-jettons"))
        let plain = BalanceService.tonJettons(json)
        #expect(plain.holdings.isEmpty)
        #expect(plain.unlisted.count == 8)
        #expect(plain.unlisted.filter { $0.reasons.contains(.flaggedBySource) }.count == 2)
        // O mestre cru da tonapi vira a forma amigavel, a mesma da moeda custom.
        let first = try #require(plain.unlisted.first { !$0.isSuspicious })
        let custom = Asset(chainID: "ton", kind: first.asset.kind, symbol: first.asset.symbol, name: first.asset.name,
                           decimals: first.asset.decimals, coingeckoID: nil, isStablecoin: false, origin: .custom)
        let withCustom = BalanceService.tonJettons(json, custom: [custom])
        #expect(withCustom.holdings.map(\.asset) == [custom])
        #expect(withCustom.unlisted.count == 7)
    }

    // MARK: Stellar

    @Test("Stellar: XLM, a moeda custom e o resto em outros tokens, todos com 7 casas")
    func stellar() {
        let aqua = Asset(chainID: "stellar", kind: .issued(code: "AQUA", issuer: "GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA"),
                         symbol: "AQUA", name: "AQUA", decimals: 7, coingeckoID: nil, isStablecoin: false, origin: .custom)
        let json = try! StrictJSON.parse(Data("""
        {"balances":[
          {"balance":"12.5000000","asset_type":"credit_alphanum4","asset_code":"AQUA","asset_issuer":"GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA"},
          {"balance":"3.0000000","asset_type":"credit_alphanum4","asset_code":"SHX","asset_issuer":"GDSTRSHXHGJ7ZIVRBXEYE5Q74XUVCUSEKEBR7UCHEUUEK72N7I7KJ6JH"},
          {"balance":"0.0000000","asset_type":"credit_alphanum4","asset_code":"ZERO","asset_issuer":"GDSTRSHXHGJ7ZIVRBXEYE5Q74XUVCUSEKEBR7UCHEUUEK72N7I7KJ6JH"},
          {"balance":"1.5000000","asset_type":"native"}
        ]}
        """.utf8))
        let read = BalanceService.stellarBalances(json, custom: [aqua])
        #expect(read.holdings.first?.asset == .native(.stellar))
        #expect(read.holdings.contains(Holding(asset: aqua, amount: BigUInt(125_000_000))))
        #expect(read.unlisted.map(\.asset.symbol) == ["SHX"])
        #expect(read.unlisted.first?.reasons.isEmpty == true)
    }

    // MARK: Solana

    @Test("Solana: USDC da lista, a moeda custom e o BONK com nome e simbolo da Metaplex")
    func solana() async throws {
        let bonk = "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263"
        let usdc = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        let mine = "7GCihgDB8fe6KNjn2MYtkzZcRjQy3t9GHdC8uHYmW2hr"
        let custom = Asset(chainID: "solana", kind: .token(contract: mine), symbol: "MINE", name: "Mine", decimals: 6, coingeckoID: nil,
                           isStablecoin: false, origin: .custom)
        @Sendable func account(_ mint: String, _ amount: String, _ decimals: Int) -> String {
            #"{"pubkey":"x","account":{"data":{"parsed":{"info":{"mint":"\#(mint)","owner":"o","tokenAmount":{"amount":"\#(amount)","decimals":\#(decimals),"uiAmountString":"0"}},"type":"account"},"program":"spl-token","space":165}}}"#
        }
        let metaplex = try Self.data("solana-getMultipleAccounts-metaplex-bonk")
        let transport = FixtureTransport([{ _, body in
            switch FixtureTransport.method(body) {
            case "getBalance": return rpcResult(#"{"context":{"slot":1},"value":5000}"#)
            case "getTokenAccountsByOwner":
                guard case .object(let filter)? = FixtureTransport.params(body).dropFirst().first,
                      case .string(let program)? = filter["programId"]
                else { return nil }
                if program == SolanaTokenProgram.token2022.programID.base58 { return rpcResult(#"{"context":{"slot":1},"value":[]}"#) }
                return rpcResult(#"{"context":{"slot":1},"value":[\#(account(bonk, "123450000", 5)),\#(account(usdc, "2000000", 6)),\#(account(mine, "3000000", 6)),\#(account(bonk, "0", 5))]}"#)
            case "getMultipleAccounts": return metaplex
            default: return nil
            }
        }])
        let service = BalanceService(client: .shared, transport: transport, evm: [:], xrpl: [], solana: testProviders("sol-a"))
        let balance = try await service.balance(chain: .solana, addresses: ["HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"], custom: [custom])
        #expect(balance.holdings.first == Holding(asset: .native(.solana), amount: BigUInt(5000)))
        #expect(balance.holdings.contains { $0.asset.symbol == "USDC" && $0.asset.isVerified })
        #expect(balance.holdings.contains(Holding(asset: custom, amount: BigUInt(3_000_000))))
        let unlisted = try #require(balance.unlisted)
        #expect(unlisted.count == 1)
        #expect(unlisted[0].asset.symbol == "Bonk" && unlisted[0].asset.name == "Bonk" && unlisted[0].asset.decimals == 5)
        #expect(unlisted[0].amount == BigUInt(123_450_000) && !unlisted[0].isSuspicious)
    }

    @Test("Metaplex: o endereco derivado e a leitura da conta gravada")
    func metaplex() throws {
        let mint = try SolanaPublicKey(base58: "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263")
        #expect(SolanaMetaplex.metadataAddress(mint: mint)?.base58 == "FDZZbyY9XGpL3CNKUZxLk3wFTTQYL3TkDiDzqxrizcPN")
        let json = try StrictJSON.parse(Self.data("solana-getMultipleAccounts-metaplex-bonk"))
        let encoded = try json.field("result", "r").field("value", "r").array("v")[0].field("data", "d").array("d")[0].string("d")
        let bytes = try #require(Data(base64Encoded: encoded))
        let parsed = try #require(SolanaMetaplex.parse([UInt8](bytes)))
        #expect(parsed.mint == mint && parsed.name == "Bonk" && parsed.symbol == "Bonk")
        #expect(SolanaMetaplex.parse([4] + [UInt8](repeating: 0, count: 10)) == nil)
    }

    // MARK: Moeda custom

    static func inspector(_ transport: FixtureTransport) -> TokenInspector {
        TokenInspector(
            transport: transport, evm: EVMReader(transport: transport, rpc: [:], history: [:], privateRelays: []),
            solana: testProviders("sol-a", "sol-b"), tron: testProviders("tron-a", "tron-b"),
            tonapi: URL(string: "https://tonapi.test/v2")!, toncenter: URL(string: "https://toncenter.test/api/v3")!,
            xrpl: testProviders("xrpl-a", "xrpl-b"), stellar: testProviders("horizon-a", "horizon-b")
        )
    }

    @Test("TON: tonapi e toncenter concordam nas casas do NOT; se discordam, nada e salvo")
    func inspectTON() async throws {
        let toncenter = LockedData(try Self.data("toncenter-jetton-masters-not"))
        let transport = FixtureTransport([{ request, _ in
            if request.url.host == "tonapi.test" { return try Self.data("tonapi-jetton-not") }
            if request.url.host == "toncenter.test" { return toncenter.value }
            return nil
        }])
        let kind = Asset.Kind.token(contract: "EQAvlWFDxGF2lXm67y4yzC17wYKD9A0guwPkMs1gOsM__NOT")
        let facts = try await Self.inspector(transport).inspect(chain: .ton, kind: kind)
        #expect(facts.asset.symbol == "NOT" && facts.asset.name == "Notcoin" && facts.asset.decimals == 9)
        #expect(facts.asset.isCustom && facts.sources == ["tonapi", "toncenter"] && facts.reasons.isEmpty)
        // O endereco vai cru para as duas fontes.
        #expect(transport.requests.allSatisfy { $0.url.absoluteString.contains("2f956143c461769579baef2e32cc2d7bc18283f40d20bb03e432cd603ac33ffc") })
        toncenter.value = Data(String(decoding: toncenter.value, as: UTF8.self).replacingOccurrences(of: "\"decimals\": \"9\"", with: "\"decimals\": \"6\"").utf8)
        await #expect(throws: TokenInspectionError.providersDisagree) {
            _ = try await Self.inspector(transport).inspect(chain: .ton, kind: kind)
        }
    }

    @Test("XRP Ledger: o emissor existe em dois servidores e tem a moeda em circulacao")
    func inspectXRPL() async throws {
        let transport = FixtureTransport([{ _, body in
            switch FixtureTransport.method(body) {
            case "account_info": return try Self.data("xrpl-account_info-solo")
            case "gateway_balances": return try Self.data("xrpl-gateway_balances-solo")
            default: return nil
            }
        }])
        let solo = Asset.Kind.issued(code: "534F4C4F00000000000000000000000000000000", issuer: "rsoLo2S1kiGeCcn6hCUXVrCpGMWLrRrLZz")
        let facts = try await Self.inspector(transport).inspect(chain: .xrpl, kind: solo)
        #expect(facts.asset.symbol == "SOLO" && facts.asset.decimals == 6 && facts.sources == ["xrpl-a", "xrpl-b"])
        #expect(facts.decimalsNote?.isEmpty == false)
        await #expect(throws: TokenInspectionError.unknownAsset) {
            _ = try await Self.inspector(transport).inspect(chain: .xrpl, kind: .issued(code: "USD", issuer: "rsoLo2S1kiGeCcn6hCUXVrCpGMWLrRrLZz"))
        }
    }

    @Test("Stellar: o ativo nas duas Horizons; sem registro, recusado")
    func inspectStellar() async throws {
        let aqua = Asset.Kind.issued(code: "AQUA", issuer: "GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA")
        let found = FixtureTransport([{ _, _ in try Self.data("horizon-assets-aqua") }])
        let facts = try await Self.inspector(found).inspect(chain: .stellar, kind: aqua)
        #expect(facts.asset.symbol == "AQUA" && facts.asset.decimals == 7 && facts.sources == ["horizon-a", "horizon-b"])
        let empty = FixtureTransport([{ _, _ in Data(#"{"_embedded":{"records":[]}}"#.utf8) }])
        await #expect(throws: TokenInspectionError.unknownAsset) { _ = try await Self.inspector(empty).inspect(chain: .stellar, kind: aqua) }
    }

    @Test("Solana: o mint em dois provedores e o nome da Metaplex")
    func inspectSolana() async throws {
        let mint = try Self.data("solana-getAccountInfo-mint-bonk")
        let metaplex = try StrictJSON.parse(Self.data("solana-getMultipleAccounts-metaplex-bonk"))
        let account = try metaplex.field("result", "r").field("value", "r").array("v")[0]
        let pda = rpcResult(#"{"context":{"slot":1},"value":\#(String(decoding: account.serialized, as: UTF8.self))}"#)
        let transport = FixtureTransport([{ _, body in
            guard FixtureTransport.method(body) == "getAccountInfo", case .object(let options)? = FixtureTransport.params(body).last else { return nil }
            return options["encoding"] == .string("base64") ? pda : mint
        }])
        let facts = try await Self.inspector(transport).inspect(chain: .solana, kind: .token(contract: "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263"))
        #expect(facts.asset.symbol == "Bonk" && facts.asset.decimals == 5 && facts.sources == ["sol-a", "sol-b"] && facts.notes.isEmpty)
    }

    @Test("Tron: decimals() em dois nos; simbolo e nome do contrato")
    func inspectTron() async throws {
        let transport = FixtureTransport([{ _, body in
            guard case .object(let fields)? = body, case .string(let selector)? = fields["function_selector"] else { return nil }
            return try Self.data("tron-constant-\(selector.replacingOccurrences(of: "()", with: ""))-kyc")
        }])
        let facts = try await Self.inspector(transport).inspect(chain: .tron, kind: .token(contract: "TQGaH1PigTUJsSbCootv52Hi92Gx2Hbmw8"))
        #expect(facts.asset.symbol == "KYC" && facts.asset.decimals == 6 && facts.sources == ["tron-a", "tron-b"])
    }

    // MARK: Preco por contrato

    @Test("Preco por contrato: CoinGecko, cache, contrato sem preco e a reserva do CoinPaprika")
    func tokenPrices() async throws {
        let arb = Asset(chainID: "arbitrum", kind: .token(contract: "0x912CE59144191C1204E64559FE8253a0e49E6548"), symbol: "ARB", name: "Arbitrum",
                        decimals: 18, coingeckoID: nil, isStablecoin: false, origin: .discovered)
        let unknown = Asset(chainID: "arbitrum", kind: .token(contract: "0x1111111111111111111111111111111111111111"), symbol: "X", name: "X",
                            decimals: 18, coingeckoID: nil, isStablecoin: false, origin: .discovered)
        let geckoDown = LockedFlag()
        let transport = FixtureTransport([{ request, _ in
            let url = request.url.absoluteString
            if request.url.host == "api.coingecko.com" {
                if geckoDown.value { throw HTTPClient.Failure.status(429) }
                #expect(url.contains("simple/token_price/arbitrum-one"))
                return url.contains("0x912CE59144191C1204E64559FE8253a0e49E6548") ? try Self.data("coingecko-token_price-arb") : Data("{}".utf8)
            }
            if url.contains("contracts/arb-arbitrum") {
                return Data(#"[{"address":"0x912ce59144191c1204e64559fe8253a0e49e6548","type":"Other","id":"arb-arbitrum","active":true}]"#.utf8)
            }
            if url.contains("tickers/arb-arbitrum") {
                return Data(#"{"id":"arb-arbitrum","name":"Arbitrum","symbol":"ARB","quotes":{"BRL":{"price":1.05,"percent_change_24h":2.0}}}"#.utf8)
            }
            return nil
        }])
        let clock = LockedClock()
        let market = MarketService(transport: transport, now: { clock.now })
        let first = await market.tokenQuotes([arb, unknown], currency: "brl")
        #expect(first[arb.id]?.price == 1.062 && first[unknown.id] == nil)
        #expect(transport.requests.count == 2)
        // Dentro da validade: nada novo, nem para o contrato sem preco.
        _ = await market.tokenQuotes([arb, unknown], currency: "brl")
        #expect(transport.requests.count == 2)
        // Vencido e com o CoinGecko em 429: a reserva por contrato.
        clock.advance(MarketService.tokenMissLifetime + 1)
        geckoDown.value = true
        let reserve = await market.tokenQuotes([arb], currency: "brl")
        #expect(reserve[arb.id]?.price == 1.05)
    }
}

extension Asset {
    var contractForTests: String? {
        if case .token(let contract) = kind { return contract }
        return nil
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data
    init(_ data: Data) { self.data = data }
    var value: Data {
        get { lock.withLock { data } }
        set { lock.withLock { data = newValue } }
    }
}
