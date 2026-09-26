import EscaliburCore
import Foundation

// Ordens limite pela CoW Protocol: sem API key, assinatura EIP-712, ordem nativa com
// execucao parcial (docs/blockchain.md 3.4, docs/seguranca.md 4.5).
//
// A ordem nasce aqui, localmente, a partir do preco-alvo que o dono digitou: o
// `buyAmount` e calculado pela carteira, nunca vem da API. Dominio, tipo e digesto sao
// compilados e calculados aqui; a API so recebe a ordem assinada.
//
// Fontes, conferidas em 25/09/2026:
// - cowprotocol/contracts, src/contracts/libraries/GPv2Order.sol: TYPE_HASH
//   0xd5a25ba2...e489 (o keccak do tipo abaixo, conferido no teste), KIND_SELL,
//   BALANCE_ERC20, UID de 56 bytes = digesto || dono || validTo;
// - src/contracts/mixins/GPv2Signing.sol: assinatura eip712 = 65 bytes r || s || v, com
//   `ecrecover(digest, v, r, s)`, entao v e 27 ou 28 (o que `EIP712ValidatedMessage`
//   ja monta);
// - src/contracts/GPv2Settlement.sol: `invalidateOrder(bytes orderUid)` exige
//   msg.sender == dono do UID;
// - cowprotocol/services, crates/model/src/order.rs: cancelamento fora da cadeia
//   assina `OrderCancellations(bytes[] orderUids)` (TYPE_HASH 0x4c89efb9...);
// - `domainSeparator()` do GPv2Settlement lido nas 6 redes bate com o dominio local;
//   `vaultRelayer()` devolve 0xC92E...0110 em todas;
// - api.cow.fi responde em mainnet, arbitrum_one, base, polygon, avalanche e bnb, e da
//   404 em optimism.
//
// Segunda leva, 26/09/2026: api.cow.fi responde em `plasma` e `linea` (e da 404 em
// unichain, sonic, celo e xlayer). Nas duas, `domainSeparator()` do GPv2Settlement,
// lido em dois RPCs, bate com o dominio local da rede, e `vaultRelayer()` devolve o
// mesmo 0xC92E...0110; o GPv2Settlement tem codigo verificado (Sourcify na Linea,
// correspondencia exata no Plasmascan na Plasma).

public enum CoWProtocol {
    /// GPv2Settlement, mesmo endereco em todas as redes (Sourcify "GPv2Settlement").
    public static let settlement = TradeAllowlist.address("9008d19f58aabd9ed0d60971565aa8510560ab41")
    /// GPv2VaultRelayer: quem recebe o approve exato do token vendido.
    public static let vaultRelayer = TradeAllowlist.address("c92e8bdf79f0507f65a392b0ab4667716bfe0110")
    public static let domainName = "Gnosis Protocol"
    public static let domainVersion = "v2"
    /// `buyToken` para comprar a moeda nativa (BUY_ETH_ADDRESS do GPv2Transfer).
    public static let buyNativeToken = TradeConstants.eeeeSentinel

    public static let orderEncodedType =
        "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
    public static let cancellationsEncodedType = "OrderCancellations(bytes[] orderUids)"

    /// Validade aceita: de 1 hora a 30 dias.
    public static let minValidity: TimeInterval = 60 * 60
    public static let maxValidity: TimeInterval = 30 * 24 * 60 * 60
    public static let defaultValidity: TimeInterval = 7 * 24 * 60 * 60
    public static let uidLength = 56

    static let networks: [UInt64: String] = [
        1: "mainnet", 42161: "arbitrum_one", 8453: "base", 137: "polygon", 43114: "avalanche", 56: "bnb",
        9745: "plasma", 59144: "linea",
    ]

    /// O token embrulhado da moeda nativa de cada rede. ETH nativo nao entra em ordem
    /// assinada (a ordem gasta allowance ERC-20): vender nativo e embrulhar antes.
    /// `symbol()` e `decimals()` conferidos em dois RPCs; WETH da Ethereum, Arbitrum e
    /// Base tambem estao na TokenRegistry. Plasma e Linea (26/09/2026): o mesmo endereco
    /// em cow-sdk (packages/config/src/constants/wrappedTokens.ts) e, na Plasma, em
    /// docs.plasma.org ("Plasma Contracts", WXPL9); codigo verificado (Plasmascan e
    /// Sourcify "WETH9").
    static let wrapped: [UInt64: (String, String)] = [
        1: ("c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", "WETH"),
        42161: ("82af49447d8a07e3bd95bd0d56f35241523fbab1", "WETH"),
        8453: ("4200000000000000000000000000000000000006", "WETH"),
        137: ("0d500b1d8e8ef31e21c99d1db9a6444d3adf1270", "WPOL"),
        43114: ("b31f66aa3c1e785363f0875a1b74e27b85fd66c7", "WAVAX"),
        56: ("bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c", "WBNB"),
        9745: ("6100e367285b01f48d07953803a2d8dca5d19873", "WXPL"),
        59144: ("e5d7c2a44ffddf6b295a15c148167daaaf5cf34f", "WETH"),
    ]

    static let depositFunction = try! ABIFunction("deposit()")                    // d0e30db0
    static let invalidateOrderFunction = try! ABIFunction("invalidateOrder(bytes)")  // 15337bc0

    public static func supports(_ chain: Chain) -> Bool {
        guard chain.family == .evm, let id = chain.evmChainID else { return false }
        return networks[id] != nil
    }

    /// O trecho de rede na URL da API (`api.cow.fi/<rede>/api/v1`).
    public static func apiNetwork(for chain: Chain) -> String? {
        chain.evmChainID.flatMap { networks[$0] }
    }

    public static func wrappedNative(on chain: Chain) -> EVMToken? {
        guard let id = chain.evmChainID, let (hex, symbol) = wrapped[id] else { return nil }
        return EVMToken(chain: chain, contract: TradeAllowlist.address(hex), symbol: symbol, decimals: 18)
    }

    /// O dono escrito no UID (bytes 32 a 52).
    public static func owner(ofUID uid: [UInt8]) -> EVMAddress? {
        guard uid.count == uidLength else { return nil }
        return EVMAddress(uncheckedBytes: Array(uid[32..<52]))
    }

    /// O `validTo` escrito no UID (ultimos 4 bytes).
    public static func validTo(ofUID uid: [UInt8]) -> UInt32? {
        guard uid.count == uidLength else { return nil }
        return uid.suffix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// O `appData` da ordem: um documento JSON cujo keccak entra na ordem. Montado aqui, sem
/// hooks (hook executa chamada arbitraria na liquidacao) e sem partnerFee (a CoW nao
/// paga taxa de parceiro em ordem limite, e a taxa da Escalibur e zero).
public struct CoWAppData: Sendable, Equatable {
    public let json: String
    public let hash: [UInt8]

    public init(json: String) {
        self.json = json
        self.hash = Hash.keccak256(Array(json.utf8))
    }

    /// Schema v1.6.0 do cowprotocol/app-data. O backend aceitou este documento ao vivo
    /// (PUT /api/v1/app_data/0xc4bc...6eb6 devolveu 201 em 25/09/2026).
    public static let limitOrder = CoWAppData(
        json: #"{"appCode":"Escalibur","metadata":{"orderClass":{"orderClass":"limit"}},"version":"1.6.0"}"#
    )

    public var hashHex: String { Hex.encode(hash, prefix: true) }
}

/// O preco-alvo: quanto do token comprado o dono quer por uma unidade inteira do
/// vendido, como ele digitou ("3000", "3000,50").
public struct CoWLimitPrice: Sendable, Equatable {
    public let buyPerSell: TradeDecimal

    public init?(_ text: String) {
        guard let value = TradeDecimal(text), !value.isZero else { return nil }
        buyPerSell = value
    }

    /// `ceil(sellAmount * preco)`, nas unidades de cada token. Para cima: a ordem nunca
    /// aceita menos que o preco digitado.
    public func buyAmount(sellAmount: BigUInt, sellDecimals: Int, buyDecimals: Int) -> BigUInt {
        let numerator = sellAmount * buyPerSell.mantissa * BigUInt.power(of: 10, buyDecimals)
        let denominator = BigUInt.power(of: 10, buyPerSell.scale + sellDecimals)
        return (numerator + denominator - 1) / denominator
    }
}

/// Uma ordem da CoW, com os campos do GPv2Order.Data. So ordens de venda, com saldo
/// ERC-20 dos dois lados e `feeAmount` zero (a CoW cobra no preco, nao num campo).
public struct CoWOrder: Sendable, Equatable {
    public let chain: Chain
    public let sellToken: EVMAddress
    public let buyToken: EVMAddress
    public let receiver: EVMAddress
    public let sellAmount: BigUInt
    public let buyAmount: BigUInt
    public let validTo: UInt32
    public let appData: [UInt8]
    public let partiallyFillable: Bool
    public let feeAmount: BigUInt = 0
    public let kind = "sell"
    public let sellTokenBalance = "erc20"
    public let buyTokenBalance = "erc20"

    public init(chain: Chain, sellToken: EVMAddress, buyToken: EVMAddress, receiver: EVMAddress, sellAmount: BigUInt,
                buyAmount: BigUInt, validTo: UInt32, appData: [UInt8], partiallyFillable: Bool) {
        self.chain = chain
        self.sellToken = sellToken
        self.buyToken = buyToken
        self.receiver = receiver
        self.sellAmount = sellAmount
        self.buyAmount = buyAmount
        self.validTo = validTo
        self.appData = appData
        self.partiallyFillable = partiallyFillable
    }

    static let orderFields: [EIP712TypedData.Field] = [
        .init(name: "sellToken", type: "address"),
        .init(name: "buyToken", type: "address"),
        .init(name: "receiver", type: "address"),
        .init(name: "sellAmount", type: "uint256"),
        .init(name: "buyAmount", type: "uint256"),
        .init(name: "validTo", type: "uint32"),
        .init(name: "appData", type: "bytes32"),
        .init(name: "feeAmount", type: "uint256"),
        .init(name: "kind", type: "string"),
        .init(name: "partiallyFillable", type: "bool"),
        .init(name: "sellTokenBalance", type: "string"),
        .init(name: "buyTokenBalance", type: "string"),
    ]

    static func domain(_ chain: Chain) -> [String: EIP712Value] {
        [
            "name": .string(CoWProtocol.domainName),
            "version": .string(CoWProtocol.domainVersion),
            "chainId": .number(String(chain.evmChainID ?? 0)),
            "verifyingContract": .string(CoWProtocol.settlement.checksummed),
        ]
    }

    /// Os dados tipados, montados aqui: dominio e tipo compilados.
    public func typedData() throws -> EIP712TypedData {
        try EIP712TypedData(
            types: ["Order": Self.orderFields], primaryType: "Order", domain: Self.domain(chain),
            message: [
                "sellToken": .string(sellToken.checksummed),
                "buyToken": .string(buyToken.checksummed),
                "receiver": .string(receiver.checksummed),
                "sellAmount": .string(sellAmount.decimalString),
                "buyAmount": .string(buyAmount.decimalString),
                "validTo": .number(String(validTo)),
                "appData": .string(Hex.encode(appData, prefix: true)),
                "feeAmount": .string(feeAmount.decimalString),
                "kind": .string(kind),
                "partiallyFillable": .bool(partiallyFillable),
                "sellTokenBalance": .string(sellTokenBalance),
                "buyTokenBalance": .string(buyTokenBalance),
            ]
        )
    }

    /// O digesto EIP-712 que o dono assina: keccak(0x1901 || dominio || hashStruct).
    public func digest() throws -> [UInt8] {
        try typedData().signingDigest()
    }

    /// O UID: digesto || dono || validTo, 56 bytes (GPv2Order.packOrderUidParams).
    public func uid(owner: EVMAddress) throws -> [UInt8] {
        try digest() + owner.bytes + withUnsafeBytes(of: validTo.bigEndian) { Array($0) }
    }
}
