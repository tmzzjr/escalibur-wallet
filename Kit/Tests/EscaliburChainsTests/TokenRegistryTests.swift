import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

/// As regras da lista curada, sem rede: vale para os tokens de hoje e para qualquer um
/// que entrar depois. O que a cadeia diz de cada contrato (simbolo, casas, mint) e
/// conferido ao vivo em EscaliburNetworkTests/BalanceLiveTests.swift.
@Suite("Lista curada de tokens")
struct TokenRegistryTests {
    static let tokens = TokenRegistry.tokens

    @Test("Id unico, e contrato unico por rede sem olhar a caixa")
    func uniqueIDs() {
        #expect(Set(Self.tokens.map(\.id)).count == Self.tokens.count)
        for chain in Chain.all {
            let keys: [String] = Self.tokens.filter { $0.chainID == chain.id }.map { token in
                switch token.kind {
                case .native: return "native"
                case .token(let contract): return contract.lowercased()
                case .issued(let code, let issuer): return code.uppercased() + ":" + issuer
                }
            }
            #expect(Set(keys).count == keys.count, "\(chain.id): contrato repetido")
        }
    }

    @Test("Nenhum simbolo repetido numa rede, nem igual ao da moeda nativa")
    func noSymbolCollision() {
        for chain in Chain.all {
            let symbols = TokenRegistry.assets(on: chain).map { $0.symbol.uppercased() }
            #expect(Set(symbols).count == symbols.count, "\(chain.id): \(symbols)")
        }
    }

    @Test("Contrato no formato da familia da rede, com o checksum da fonte")
    func contractFormat() throws {
        for token in Self.tokens {
            let chain = try #require(token.chain, "\(token.id): rede desconhecida")
            switch (chain.family, token.kind) {
            case (.evm, .token(let contract)):
                // Caixa mista da fonte: o EIP-55 tem de bater (EVMAddress recusa o errado).
                let address = try EVMAddress(contract)
                #expect(address.checksummed == contract, "\(token.id): checksum")
            case (.solana, .token(let mint)):
                let key = try SolanaPublicKey(base58: mint)
                #expect(key.base58 == mint, "\(token.id)")
            case (.tron, .token(let contract)):
                #expect(TronAddress(base58: contract)?.base58 == contract, "\(token.id)")
            case (.ton, .token(let master)):
                guard case .success = TONAddress.parse(master) else { Issue.record("\(token.id): mestre invalido"); continue }
            case (.xrpl, .issued(let code, let issuer)):
                #expect(XRPLAddress.accountID(issuer) != nil, "\(token.id): emissor")
                #expect((try? XRPLCurrency(code: code)) != nil, "\(token.id): codigo")
            case (.stellar, .issued(let code, let issuer)):
                #expect((try? StellarAsset(code: code, issuer: issuer)) != nil, "\(token.id)")
            default:
                Issue.record("\(token.id): tipo de ativo que a familia \(chain.family) nao tem")
            }
        }
    }

    @Test("Casas decimais possiveis na rede")
    func decimals() throws {
        for token in Self.tokens {
            let chain = try #require(token.chain)
            let range: ClosedRange<Int>
            switch chain.family {
            case .evm, .tron: range = 0...18
            case .solana, .ton: range = 0...9
            case .stellar: range = 7...7
            case .xrpl: range = 0...15
            case .utxo: range = 0...0
            // Coin<T> da Sui: `decimals` e u8 no CoinMetadata.
            case .sui: range = 0...18
            }
            #expect(range.contains(token.decimals), "\(token.id): \(token.decimals) casas")
        }
    }

    @Test("Todo token tem id do CoinGecko e logo embarcado")
    func coingeckoAndLogo() throws {
        let logos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/EscaliburWallet/Resources/Assets.xcassets/Logos")
        for token in Self.tokens {
            let gecko = try #require(token.coingeckoID, "\(token.id): sem id do CoinGecko")
            #expect(!gecko.isEmpty && gecko == gecko.lowercased() && !gecko.contains(" "), "\(token.id)")
            let set = logos.appendingPathComponent("logo-\(gecko).imageset")
            let contents = try Data(contentsOf: set.appendingPathComponent("Contents.json"))
            let json = try #require(try JSONSerialization.jsonObject(with: contents) as? [String: Any])
            let images = try #require(json["images"] as? [[String: Any]])
            let file = try #require(images.first?["filename"] as? String, "\(gecko): Contents.json sem arquivo")
            let bytes = [UInt8](try Data(contentsOf: set.appendingPathComponent(file)).prefix(4))
            #expect(bytes == [0x89, 0x50, 0x4E, 0x47] || bytes.starts(with: [0xFF, 0xD8, 0xFF]), "\(gecko): logo nao e PNG nem JPEG")
        }
    }

    @Test("Nome e simbolo sem travessao, sem controle e de tamanho de tela")
    func displayText() {
        for token in Self.tokens {
            for text in [token.symbol, token.name] {
                #expect(!text.isEmpty && text.count <= 40, "\(token.id)")
                #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"), "\(token.id): travessao")
                #expect(text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }, "\(token.id)")
            }
            #expect(token.symbol.count <= 8, "\(token.id): simbolo longo")
        }
    }

    /// Os motores da Tron e da TON so enviam USDT, e o historico dessas redes so reconhece
    /// o USDT: outro token la chegaria e ficaria preso na interface.
    @Test("Tron e TON: so o USDT")
    func tronAndTonOnlyUSDT() {
        for chain in [Chain.tron, .ton] {
            let listed = Self.tokens.filter { $0.chainID == chain.id }
            #expect(listed.map(\.symbol) == ["USDT"], "\(chain.id)")
        }
    }

    /// A tela de troca comeca comprando o primeiro stablecoin da rede: continua sendo o
    /// USDC ou o USDT do emissor, e nao um que entrou depois.
    @Test("O primeiro stablecoin de cada rede EVM e o USDC ou o USDT")
    func firstStablecoin() throws {
        for chain in Chain.evmChains {
            let first = try #require(Self.tokens.first { $0.chainID == chain.id && $0.isStablecoin }, "\(chain.id)")
            #expect(["USDC", "USDT"].contains(first.symbol), "\(chain.id): \(first.symbol)")
        }
    }

    /// `isStablecoin` faz a troca usar a paridade de 1 dolar sem perguntar ao oraculo:
    /// so moeda atrelada ao dolar entra (o EURC, em euro, nao).
    @Test("Stablecoin da lista e de dolar")
    func stablecoinsAreDollar() {
        for token in Self.tokens where token.isStablecoin {
            #expect(token.symbol.uppercased().contains("USD") || token.symbol == "DAI", "\(token.id): \(token.symbol)")
        }
        #expect(!Self.tokens.contains { $0.symbol == "EURC" && $0.isStablecoin })
    }

    @Test("Multicall3 conferido em toda rede EVM, com o mesmo endereco")
    func multicallEverywhere() {
        #expect(Multicall3.address.checksummed == "0xcA11bde05977b3631167028862bE2a173976CA11")
        for chain in Chain.evmChains {
            #expect(Multicall3.isDeployed(on: chain), "\(chain.id)")
        }
        #expect(!Multicall3.isDeployed(on: .solana))
    }

    @Test("Multicall3: seletor, lotes de ate 100 e decodificacao estrita")
    func multicallEncoding() throws {
        #expect(Hex.encode(Multicall3.aggregate3Function.selector) == "82ad56cb")
        let owner = try EVMAddress("0x28C6c06298d514Db089934071355E5743bf21d60")
        let tokens = (0..<250).map { i in EVMAddress(bytes: [UInt8](repeating: 0, count: 19) + [UInt8(i % 256)])! }
        let batches = Multicall3.balanceBatches(owner: owner, tokens: tokens)
        #expect(batches.map(\.count) == [100, 100, 50])
        #expect(batches.joined().map(\.target) == tokens)

        // Tres resultados: saldo, reverteu, e retorno que nao e uint256.
        let encoded = try ABI.encode(
            [.array([
                .tuple([.bool(true), .bytes(BigUInt(12345).bigEndianBytes(padTo: 32)!)]),
                .tuple([.bool(false), .bytes([])]),
                .tuple([.bool(true), .bytes([1, 2, 3])]),
            ])],
            types: Multicall3.resultTypes
        )
        #expect(try Multicall3.decodeBalances(encoded, expected: 3) == [BigUInt(12345), nil, nil])
        #expect(throws: (any Error).self) { try Multicall3.decodeBalances(encoded, expected: 2) }
        #expect(throws: (any Error).self) { try Multicall3.decodeBalances(encoded + [0], expected: 3) }
        #expect(throws: (any Error).self) { try Multicall3.decodeBalances([UInt8](repeating: 0xFF, count: 64), expected: 1) }
    }
}
