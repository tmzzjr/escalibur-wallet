import EscaliburChains
import EscaliburCore
import Foundation

// Leitura pura das respostas de conta da Solana: o que existe num endereco, conta
// de token, mint e extensoes Token-2022, tabela de enderecos. Sem rede aqui, para
// que cada regra seja testada com respostas gravadas.

/// O mint de um token, como a cadeia o descreve.
public struct SolanaMintInfo: Sendable, Equatable {
    public let mint: SolanaPublicKey
    public let program: SolanaTokenProgram
    public let decimals: UInt8
    /// As extensoes que mudam o que uma transferencia faz (ver `SolanaMintExtension`).
    public let extensions: [SolanaMintExtension]
    /// Todos os nomes de extensao que o no listou, inclusive os so de exibicao.
    public let extensionNames: [String]

    /// Tamanho da conta de token (ATA) deste mint, para o rent: 165 bytes no Token;
    /// no Token-2022, 165 + 1 (tipo) + as extensoes de conta que o mint exige
    /// (ImmutableOwner sempre no ATA, TransferFeeAmount, NonTransferableAccount,
    /// TransferHookAccount, PausableAccount), cada uma com 4 bytes de cabecalho TLV.
    public var tokenAccountSize: Int {
        guard program == .token2022 else { return 165 }
        var size = 165 + 1 + 4  // tipo de conta + ImmutableOwner
        for name in extensionNames {
            switch name {
            case "transferFeeConfig": size += 4 + 8
            case "nonTransferable": size += 4
            case "transferHook": size += 4 + 1
            case "pausableConfig": size += 4
            default: break
            }
        }
        return size
    }
}

public enum SolanaAccountParseError: Error, Equatable, Sendable {
    case notAMint(owner: String)
    case notATokenAccount
    case tokenAccountMismatch
    case notALookupTable
    case lookupTableDeactivated
    case malformed
}

public enum SolanaAccountParser {
    /// O programa das tabelas de enderecos (solana-sdk, `address_lookup_table::program::ID`).
    public static let lookupTableProgram = "AddressLookupTab1e1111111111111111111111111"
    static let systemProgram = SolanaProgramID.system.base58

    // MARK: Destino

    /// O que existe no endereco digitado, a partir de `getAccountInfo` com `jsonParsed`.
    static func destination(_ account: RPCAccount?, address: SolanaPublicKey) throws -> SolanaDestinationAccount {
        guard let account else { return .nonexistent }
        let owner = try key(account.owner)
        if owner == SolanaProgramID.system, !account.executable {
            // Conta de sistema com dados (conta de nonce, 80 bytes) nao e carteira.
            let hasData: Bool
            switch account.data {
            case .encoded(let bytes): hasData = !bytes.isEmpty
            case .parsed: hasData = true
            }
            if !hasData && (account.space ?? 0) == 0 { return .system(lamports: BigUInt(account.lamports)) }
            return .programOwned(owner: owner)
        }
        if let program = SolanaTokenProgram(programID: owner), !account.executable,
           let state = try? tokenAccount(account, address: address, program: program) {
            return .tokenAccount(state)
        }
        return .programOwned(owner: owner)
    }

    /// Conta de token a partir do `jsonParsed` (`parsed.type == "account"`).
    static func tokenAccount(_ account: RPCAccount, address: SolanaPublicKey, program: SolanaTokenProgram? = nil) throws -> SolanaTokenAccountState {
        let owner = try key(account.owner)
        guard let tokenProgram = SolanaTokenProgram(programID: owner), program == nil || program == tokenProgram,
              let parsed = account.data.parsed, parsed["type"]?.stringValue == "account", let info = parsed["info"],
              let mint = info["mint"]?.stringValue, let holder = info["owner"]?.stringValue,
              let amountText = info["tokenAmount"]?["amount"]?.stringValue, let amount = BigUInt(decimal: amountText),
              let state = info["state"]?.stringValue
        else { throw SolanaAccountParseError.notATokenAccount }
        return SolanaTokenAccountState(
            address: address, program: tokenProgram, mint: try key(mint), owner: try key(holder), amount: amount,
            isFrozen: state == "frozen"
        )
    }

    // MARK: Mint

    private struct MintResponse: Decodable {
        struct Value: Decodable {
            let owner: String
            let data: MintData
        }
        struct MintData: Decodable {
            let parsed: Parsed
        }
        struct Parsed: Decodable {
            let type: String
            let info: Info
        }
        struct Info: Decodable {
            let decimals: UInt8?
            let extensions: [Extension]?
        }
    }

    /// Uma extensao do mint. O estado da taxa de transferencia e lido tipado (u64
    /// exato); o resto so pelo que precisa.
    private struct Extension: Decodable {
        struct Fee: Decodable {
            let epoch: UInt64
            let maximumFee: UInt64
            let transferFeeBasisPoints: UInt16
        }
        struct FeeConfig: Decodable {
            let newerTransferFee: Fee
            let olderTransferFee: Fee
        }
        let name: String
        let fee: FeeConfig?
        let state: JSONValue?

        enum CodingKeys: String, CodingKey { case name = "extension", state }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            state = try container.decodeIfPresent(JSONValue.self, forKey: .state)
            fee = name == "transferFeeConfig" ? try container.decodeIfPresent(FeeConfig.self, forKey: .state) : nil
        }
    }

    /// Extensoes so de exibicao ou que nao mudam uma transferencia comum.
    static let harmlessExtensions: Set<String> = [
        "mintCloseAuthority", "metadataPointer", "tokenMetadata", "groupPointer", "groupMemberPointer", "tokenGroup",
        "tokenGroupMember", "interestBearingConfig", "scaledUiAmountConfig", "confidentialTransferMint",
        "confidentialTransferFeeConfig", "immutableOwner",
    ]

    /// O mint a partir da resposta crua de `getAccountInfo` com `jsonParsed`.
    public static func mint(fromResponse data: Data, address: SolanaPublicKey) throws -> SolanaMintInfo {
        let result = try SolanaRPC.decode(data, method: "getAccountInfo", as: MintResponseEnvelope.self)
        guard let value = result.value else { throw SolanaAccountParseError.notAMint(owner: "") }
        guard let program = SolanaTokenProgram(programID: try key(value.owner)), value.data.parsed.type == "mint",
              let decimals = value.data.parsed.info.decimals
        else { throw SolanaAccountParseError.notAMint(owner: value.owner) }
        var extensions = [SolanaMintExtension]()
        var names = [String]()
        for ext in value.data.parsed.info.extensions ?? [] {
            names.append(ext.name)
            switch ext.name {
            case "transferFeeConfig":
                // A taxa vigente depende da epoca; sem ler a epoca, a carteira usa a
                // maior das duas (a revisao mostra o pior caso).
                guard let config = ext.fee else { extensions.append(.unknown(ext.name)); continue }
                let worst = [config.newerTransferFee, config.olderTransferFee].max { $0.transferFeeBasisPoints < $1.transferFeeBasisPoints }!
                let maximum = max(config.newerTransferFee.maximumFee, config.olderTransferFee.maximumFee)
                if worst.transferFeeBasisPoints > 0 {
                    extensions.append(.transferFee(basisPoints: worst.transferFeeBasisPoints, maximumFee: BigUInt(maximum)))
                }
            case "permanentDelegate":
                // Delegado nulo (OptionalNonZeroPubkey zerado) nao da poder a ninguem.
                if let delegate = ext.state?["delegate"]?.stringValue, !delegate.isEmpty { extensions.append(.permanentDelegate) }
            case "transferHook":
                if let program = ext.state?["programId"]?.stringValue, !program.isEmpty { extensions.append(.transferHook) }
            case "nonTransferable":
                extensions.append(.nonTransferable)
            case "defaultAccountState":
                if ext.state?["accountState"]?.stringValue == "frozen" { extensions.append(.defaultAccountStateFrozen) }
            case "pausableConfig":
                if ext.state?["paused"]?.boolValue == true { extensions.append(.paused) }
            default:
                if !harmlessExtensions.contains(ext.name) { extensions.append(.unknown(ext.name)) }
            }
        }
        return SolanaMintInfo(mint: address, program: program, decimals: decimals, extensions: extensions, extensionNames: names)
    }

    private typealias MintResponseEnvelope = RPCContextualOptional<MintResponse.Value>

    // MARK: Tabela de enderecos

    /// Uma tabela de enderecos a partir de `getAccountInfo` com `base64`. Layout
    /// (`address_lookup_table::state`): u32 tipo (1 = tabela), u64 slot de
    /// desativacao (u64::MAX = ativa), u64 ultimo slot estendido, u8 indice, Option
    /// autoridade (1 + 32), u16 de preenchimento: 56 bytes; depois os enderecos.
    static func lookupTable(_ account: RPCAccount?, address: SolanaPublicKey) throws -> SolanaAddressLookupTable {
        guard let account, account.owner == lookupTableProgram, let bytes = account.data.bytes else { throw SolanaAccountParseError.notALookupTable }
        return try lookupTable(bytes: bytes, address: address)
    }

    public static func lookupTable(bytes: [UInt8], address: SolanaPublicKey) throws -> SolanaAddressLookupTable {
        guard bytes.count >= 56, (bytes.count - 56) % 32 == 0 else { throw SolanaAccountParseError.malformed }
        guard bytes[0..<4] == [1, 0, 0, 0] else { throw SolanaAccountParseError.notALookupTable }
        // Tabela desativada deixa de valer em breve (e pode ser fechada): recusada.
        guard bytes[4..<12].allSatisfy({ $0 == 0xFF }) else { throw SolanaAccountParseError.lookupTableDeactivated }
        var addresses = [SolanaPublicKey]()
        var offset = 56
        while offset < bytes.count {
            addresses.append(try SolanaPublicKey(bytes: Array(bytes[offset..<offset + 32])))
            offset += 32
        }
        return SolanaAddressLookupTable(address: address, addresses: addresses)
    }

    /// Duas leituras da mesma tabela concordam se forem iguais ou se uma for
    /// prefixo da outra (a tabela so cresce; entre as duas leituras alguem pode ter
    /// estendido). Vale o trecho comum. Divergencia em qualquer posicao: nil.
    public static func agree(_ a: SolanaAddressLookupTable, _ b: SolanaAddressLookupTable) -> SolanaAddressLookupTable? {
        guard a.address == b.address else { return nil }
        let common = min(a.addresses.count, b.addresses.count)
        guard a.addresses.prefix(common) == b.addresses.prefix(common) else { return nil }
        return SolanaAddressLookupTable(address: a.address, addresses: Array(a.addresses.prefix(common)))
    }

    // MARK: Prioridade

    /// Percentil (50 a 75) das taxas de prioridade recentes, em micro-lamports por CU.
    public static func priorityFee(_ fees: [UInt64], percentile: Int) -> UInt64 {
        guard !fees.isEmpty else { return 0 }
        let p = min(max(percentile, 50), 75)
        let sorted = fees.sorted()
        let rank = (p * sorted.count + 99) / 100  // teto(p * n / 100), 1-based
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    static func key(_ text: String) throws -> SolanaPublicKey {
        do { return try SolanaPublicKey(base58: text) } catch { throw SolanaAccountParseError.malformed }
    }
}
