import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// As redes EVM da segunda leva (Plasma, X Layer, Linea, Unichain, Sonic e Celo), sem
/// rede: parametros compilados, endereco, lista de tokens e perfil de taxa. Os valores
/// esperados sao os da documentacao oficial de cada rede e dos emissores, conferidos ao
/// vivo em 26/09/2026 (ver os comentarios de Chain.swift e TokenRegistry.swift).
@Suite("Redes EVM da segunda leva")
struct EVMSecondWaveTests {
    typealias T = EVMTestSupport

    struct Expected {
        let chain: Chain
        let id: String
        let chainID: UInt64
        let symbol: String
        let gecko: String
        let explorerTx: String
    }

    static let expected: [Expected] = [
        Expected(chain: .plasma, id: "plasma", chainID: 9745, symbol: "XPL", gecko: "plasma", explorerTx: "https://plasmascan.to/tx/0xab"),
        Expected(chain: .xlayer, id: "xlayer", chainID: 196, symbol: "OKB", gecko: "okb",
                 explorerTx: "https://www.okx.com/web3/explorer/xlayer/tx/0xab"),
        Expected(chain: .linea, id: "linea", chainID: 59144, symbol: "ETH", gecko: "ethereum", explorerTx: "https://lineascan.build/tx/0xab"),
        Expected(chain: .unichain, id: "unichain", chainID: 130, symbol: "ETH", gecko: "ethereum", explorerTx: "https://uniscan.xyz/tx/0xab"),
        Expected(chain: .sonic, id: "sonic", chainID: 146, symbol: "S", gecko: "sonic-3", explorerTx: "https://sonicscan.org/tx/0xab"),
        Expected(chain: .celo, id: "celo", chainID: 42220, symbol: "CELO", gecko: "celo", explorerTx: "https://celoscan.io/tx/0xab"),
    ]

    @Test("Parametros compilados: chainId, moeda nativa, derivacao e explorador", arguments: expected.indices)
    func parameters(index: Int) throws {
        let e = Self.expected[index]
        let chain = e.chain
        #expect(chain.id == e.id)
        #expect(chain.family == .evm && chain.family.curve == .secp256k1)
        #expect(chain.coinType == 60)
        #expect(chain.evmChainID == e.chainID)
        #expect(chain.nativeSymbol == e.symbol)
        #expect(chain.nativeDecimals == 18)
        #expect(chain.coingeckoID == e.gecko)
        #expect(chain.destinationTag == .none)
        #expect(chain.explorerURL(tx: "0xab")?.absoluteString == e.explorerTx)
        #expect(chain.explorerURL(address: "0xcd")?.absoluteString == e.explorerTx.replacingOccurrences(of: "/tx/0xab", with: "/address/0xcd"))
        #expect(chain.typicalConfirmationSeconds >= 2)
        #expect(Chain.find(e.id) == chain)
        #expect(Chain.evmChains.contains(chain))
    }

    @Test("Ids e chainIds unicos entre todas as redes; ordem da interface")
    func uniqueness() {
        #expect(Set(Chain.all.map(\.id)).count == Chain.all.count)
        let chainIDs = Chain.all.compactMap(\.evmChainID)
        #expect(Set(chainIDs).count == chainIDs.count)
        #expect(Chain.evmChains.count == 13)
        #expect(Chain.evmChains.map(\.id) == [
            "ethereum", "base", "arbitrum", "optimism", "polygon", "bnb", "avalanche",
            "plasma", "xlayer", "linea", "unichain", "sonic", "celo",
        ])
    }

    @Test("Endereco: o mesmo da Ethereum, checksum EIP-55 conferido, outra rede reconhecida")
    func addresses() throws {
        let account = try T.account(T.testKey)
        let ethereum = try Address.from(publicKey: account.publicKey, chain: .ethereum)
        let good = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
        let badChecksum = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD"
        for e in Self.expected {
            let chain = e.chain
            #expect(try Address.from(publicKey: account.publicKey, chain: chain) == ethereum)
            #expect(try Address.validate(good, for: chain).get() == Address.Destination(address: good, tag: nil))
            // Tudo minusculo nao carrega checksum: aceito e devolvido com o EIP-55.
            #expect(Address.validate(good.lowercased(), for: chain).map(\.address) == .success(good))
            #expect(Address.validate(badChecksum, for: chain) == .failure(.badChecksum))
            #expect(Address.validate("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeA", for: chain) == .failure(.malformed))
            #expect(Address.validate("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", for: chain) == .failure(.otherNetwork(.bitcoin)))
            #expect(Address.sameRecipient(good, good.lowercased(), chain: chain))
            // EIP-681 com o chainId da rede escolhe a rede certa.
            #expect(try EIP681Request.parse("ethereum:\(good)@\(e.chainID)").chain == chain)
        }
    }

    /// Contratos, simbolo e casas por rede, como compilados. Endereco com caixa mista:
    /// `EVMAddress` recusa checksum errado, entao o teste confere o EIP-55 da fonte.
    static let tokens: [(chain: String, contract: String, symbol: String, gecko: String)] = [
        ("plasma", "0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb", "USDT", "tether"),
        ("plasma", "0x2d661C89D812261039AF9764eceaAee884f5F67F", "USDC", "usd-coin"),
        ("xlayer", "0x779Ded0c9e1022225f8E0630b35a9b54bE713736", "USDT", "tether"),
        ("xlayer", "0xB6CEceAB302E2E4948951eE7843FC24E92933061", "USDC", "usd-coin"),
        ("linea", "0x176211869cA2b568f2A7D4EE941E073a821EE1ff", "USDC", "usd-coin"),
        ("unichain", "0x078D782b760474a361dDA0AF3839290b0EF57AD6", "USDC", "usd-coin"),
        ("unichain", "0x9151434b16b9763660705744891fA906F660EcC5", "USDT", "tether"),
        ("sonic", "0x29219dd400f2Bf60E5a23d13Be72B486D4038894", "USDC", "usd-coin"),
        ("celo", "0xcebA9300f2b948710d2653dD7B07f33A8B32118C", "USDC", "usd-coin"),
        ("celo", "0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e", "USDT", "tether"),
    ]

    @Test("Lista de tokens: USDC e USDT so os dos emissores, com 6 casas e checksum da fonte")
    func registry() throws {
        let secondWave = Set(Self.expected.map(\.id))
        // Os outros tokens destas redes (terceira leva, 27/09/2026) seguem as regras de
        // TokenRegistryTests; aqui ficam o USDC e o USDT, que nao podem ser os da ponte.
        let listed = TokenRegistry.tokens.filter { secondWave.contains($0.chainID) && ["USDC", "USDT"].contains($0.symbol) }
        #expect(listed.count == Self.tokens.count)
        for token in Self.tokens {
            let asset = try #require(TokenRegistry.find(chainID: token.chain, contract: token.contract.lowercased()), "\(token.chain) \(token.symbol)")
            #expect(asset.kind == .token(contract: token.contract))
            #expect(asset.symbol == token.symbol && asset.decimals == 6 && asset.isStablecoin && asset.coingeckoID == token.gecko)
            #expect(try EVMAddress(token.contract).checksummed == token.contract)
            // O mesmo contrato nao vale em outra rede.
            #expect(TokenRegistry.find(chainID: "ethereum", contract: token.contract) == nil)
        }
        // Pontes que o emissor nao reconhece ficam de fora.
        #expect(TokenRegistry.find(chainID: "xlayer", contract: "0x74b7F16337b8972027F6196A17a631aC6dE26d22") == nil)  // USDC.e
        #expect(TokenRegistry.find(chainID: "xlayer", contract: "0x1E4a5963aBFD975d8c9021ce480b42188849D41d") == nil)  // USDT da ponte
        #expect(TokenRegistry.find(chainID: "linea", contract: "0xA219439258ca9da29E9Cc4cE5596924745e12B93") == nil)   // USDT da ponte
        #expect(TokenRegistry.find(chainID: "sonic", contract: "0x6047828dc181963ba44974801FF68e538dA5eaF9") == nil)   // USDT da ponte
        // O CELO como ERC-20 e o proprio saldo nativo: nunca entra como token.
        #expect(TokenRegistry.find(chainID: "celo", contract: "0x471EcE3750Da237f93B8E339c536989b8978a438") == nil)
        for e in Self.expected {
            #expect(TokenRegistry.assets(on: e.chain).first == Asset.native(e.chain))
        }
    }

    @Test("Perfil de taxa de cada rede nova")
    func feeProfiles() throws {
        for e in Self.expected {
            let profile = try #require(EVMFeeProfile.for(e.chain), "\(e.id)")
            #expect(!profile.allowsLegacy && !profile.priorityEqualsMaxFee)
            #expect(profile.maxFeeCeiling > 0 && profile.maxPriorityFee >= profile.minPriorityFee)
        }
        // OP Stack com taxa L1: Unichain cobra; Celo e X Layer tem o oraculo em zero.
        let unichain = try #require(EVMFeeProfile.for(.unichain))
        #expect(unichain.chargesL1DataFee && !unichain.l1DataFeeMayBeZero)
        for chain in [Chain.celo, .xlayer] {
            let profile = try #require(EVMFeeProfile.for(chain))
            #expect(profile.chargesL1DataFee && profile.l1DataFeeMayBeZero, "\(chain.id)")
        }
        for chain in [Chain.plasma, .linea, .sonic] {
            #expect(EVMFeeProfile.for(chain)?.chargesL1DataFee == false, "\(chain.id)")
        }
        // As redes antigas nao aceitam taxa L1 zero.
        #expect(EVMFeeProfile.for(.base)?.l1DataFeeMayBeZero == false)
        #expect(EVMFeeProfile.for(.optimism)?.l1DataFeeMayBeZero == false)
        #expect(EVMFeeProfile.for(.linea)?.minPriorityFee == BigUInt(100_000_000))
    }

    static func state(_ chain: Chain, baseFee: BigUInt, tip: BigUInt, l1: BigUInt?) -> EVMNetworkState {
        EVMNetworkState(
            chain: chain, pendingNonces: [3, 3], baseFeePerGas: baseFee, priorityFees: EVMPriorityFees(slow: tip, normal: tip, fast: tip),
            gasEstimate: 21_000, l1DataFee: l1, nativeBalance: BigUInt.power(of: 10, 18), destinationHasCode: false
        )
    }

    @Test("Taxa: piso da Linea, taxa L1 da Unichain e zero valido na Celo")
    func feeQuotes() throws {
        // Linea: gorjeta de 0,04 gwei sobe para o piso de 0,1 gwei; baseFee de 7 wei.
        let linea = try EVMFeeCalculator.quote(
            chain: .linea, state: Self.state(.linea, baseFee: 7, tip: 40_000_000, l1: nil), speed: .normal, format: .eip1559, plainTransfer: true
        )
        #expect(linea.fee == .eip1559(maxPriorityFeePerGas: 100_000_000, maxFeePerGas: 100_000_014))
        #expect(linea.l1DataFee == 0)
        // Unichain: sem taxa L1 o plano nao sai; com ela, entra no custo.
        #expect(throws: EVMPlanError.missingL1DataFee) {
            try EVMFeeCalculator.quote(chain: .unichain, state: Self.state(.unichain, baseFee: 500_000, tip: 0, l1: nil),
                                       speed: .normal, format: .eip1559, plainTransfer: true)
        }
        let unichain = try EVMFeeCalculator.quote(
            chain: .unichain, state: Self.state(.unichain, baseFee: 500_000, tip: 0, l1: 1_500_000_000), speed: .normal, format: .eip1559,
            plainTransfer: true
        )
        #expect(unichain.l1DataFee == 1_500_000_000)
        #expect(unichain.maxCost == BigUInt(21_000) * BigUInt(1_000_000) + 1_500_000_000)
        // Celo: o oraculo responde zero, e zero e taxa L1 valida.
        let celo = try EVMFeeCalculator.quote(
            chain: .celo, state: Self.state(.celo, baseFee: 200_000_000_000, tip: 1_100_000, l1: 0), speed: .normal, format: .eip1559,
            plainTransfer: true
        )
        #expect(celo.l1DataFee == 0)
        #expect(celo.fee == .eip1559(maxPriorityFeePerGas: 1_100_000, maxFeePerGas: 400_001_100_000))
        // Sonic: baseFee acima do teto de sanidade recusa.
        #expect(throws: EVMPlanError.feeAboveCeiling) {
            try EVMFeeCalculator.quote(chain: .sonic, state: Self.state(.sonic, baseFee: BigUInt(6_000) * BigUInt(1_000_000_000), tip: 1, l1: nil),
                                       speed: .normal, format: .eip1559, plainTransfer: true)
        }
        // Estado de outra rede nao serve.
        #expect(throws: EVMPlanError.chainMismatch) {
            try EVMFeeCalculator.quote(chain: .plasma, state: Self.state(.sonic, baseFee: 7, tip: 1, l1: nil),
                                       speed: .normal, format: .eip1559, plainTransfer: true)
        }
    }

    @Test("Transacao tipo 2 da Plasma: chainId 9745 no comeco da lista RLP")
    func plasmaTransaction() throws {
        let account = try T.account(T.testKey)
        let transaction = try EVMTransaction(
            chain: .plasma, account: account, nonce: 7, fee: .eip1559(maxPriorityFeePerGas: 1, maxFeePerGas: 15),
            gasLimit: 21_000, to: T.address("0x3535353535353535353535353535353535353535"), value: 1_000, data: []
        )
        #expect(transaction.chainID == 9745)
        // Tipo 2, cabecalho de lista curta, e o chainId 9745 = 0x2611 em dois bytes.
        #expect(Array(transaction.signingPayload.prefix(5)) == [0x02, transaction.signingPayload[1], 0x82, 0x26, 0x11])
        #expect(transaction.signingRequests.first?.expectedPublicKey == account.publicKey)
    }
}
