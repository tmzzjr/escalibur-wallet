import EscaliburChains
import EscaliburCore
import Foundation
import Testing

/// Leitura das fixtures em Fixtures/solana. Cada vetor carrega a URL de origem
/// (fixada no commit) ou a transacao da rede principal de onde saiu.
enum SolanaFixtures {
    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/solana"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    static func key(_ text: String) throws -> SolanaPublicKey { try SolanaPublicKey(base58: text) }
    static func hex(_ text: String) throws -> [UInt8] { try #require(Hex.decode(text)) }

    // MARK: reference-vectors.json

    struct Reference: Decodable {
        let shortvec: ShortVec
        let curve: Curve
        let createProgramAddress: [PDA]
        let findProgramAddress: [PDA]
        let associatedTokenAddress: [ATA]
        let web3LegacyTransfer: Web3Transfer
        let sdkSampleTransaction: SDKSample
        let kitCodecMessage: KitMessage
        let web3AccountOrdering: Ordering
        let web3DuplicateAccounts: Duplicates
    }

    struct ShortVec: Decodable {
        let source: String
        let encode: [[Either]]
        let reject: [String]
    }

    /// `[valor, "hex"]` no JSON.
    enum Either: Decodable {
        case int(Int)
        case text(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .int(i) } else { self = .text(try c.decode(String.self)) }
        }
        var int: Int? { if case .int(let v) = self { return v } else { return nil } }
        var text: String? { if case .text(let v) = self { return v } else { return nil } }
    }

    struct Curve: Decodable {
        let source: String
        let onCurveBytes: [String]
        let offCurveBytes: [String]
        let onCurveAddresses: [String]
        let offCurveAddresses: [String]
    }

    struct PDA: Decodable {
        let source: String
        let program: String
        let seeds: [String]
        let expected: String
        let bump: UInt8?
    }

    struct ATA: Decodable {
        let source: String
        let owner: String
        let mint: String
        let program: String
        let allowOwnerOffCurve: Bool
        let expected: String
    }

    struct Web3Transfer: Decodable {
        enum CodingKeys: String, CodingKey {
            case source, recipient, recentBlockhash, lamports, signedBase64
            case senderHex = "senderSeed"
        }
        let source: String
        /// Os 32 bytes que o teste do web3.js passa a `Keypair.fromSeed`, em hex.
        let senderHex: String
        let recipient: String
        let recentBlockhash: String
        let lamports: UInt64
        let signedBase64: String
    }

    struct SDKSample: Decodable {
        let source: String
        let keypair: String
        let to: String
        let programId: String
        let data: String
        let serialized: String
    }

    struct KitMessage: Decodable {
        struct Instruction: Decodable {
            let programIndex: UInt8
            let accounts: [UInt8]
            let data: String
        }
        struct Lookup: Decodable {
            let table: String
            let writable: [UInt8]
            let readonly: [UInt8]
        }
        let source: String
        let sourceLegacy: String
        let header: [UInt8]
        let staticAccounts: [String]
        let lifetimeToken: String
        let instructions: [Instruction]
        let lookups: [Lookup]
        let expectedV0: String
        let expectedV0NoLookups: String
        let expectedLegacy: String
    }

    struct Ordering: Decodable {
        let source: String
        let payer: String
        let writableSigners: [String]
        let readonlySigners: [String]
        let writable: [String]
        let readonly: [String]
        let programId: String
    }

    struct Duplicates: Decodable {
        let source: String
        let payer: String
        let account2: String
        let account3: String
        let account4: String
        let programId: String
        let account5: String
    }

    // MARK: curve-oracle.json

    struct Oracle: Decodable {
        struct Case: Decodable {
            let note: String?
            let hex: String
            let onCurve: Bool
        }
        let cases: [Case]
    }

    // MARK: mainnet-transactions.json

    struct Mainnet: Decodable {
        struct Transaction: Decodable {
            struct Loaded: Decodable {
                let writable: [String]
                let readonly: [String]
            }
            let name: String
            let signature: String
            let base64: String
            let loadedAddresses: Loaded?
        }
        struct Table: Decodable {
            let length: Int
            let entries: [String: String]
        }
        let transactions: [Transaction]
        let lookupTables: [String: Table]

        func transaction(_ name: String) throws -> Transaction {
            try #require(transactions.first { $0.name == name })
        }

        /// A tabela com as entradas usadas nos lugares certos e chaves de
        /// preenchimento nos outros indices (que nenhuma consulta alcanca).
        func tables() throws -> [SolanaAddressLookupTable] {
            try lookupTables.map { address, table in
                var addresses = [SolanaPublicKey]()
                for index in 0..<table.length {
                    if let entry = table.entries[String(index)] {
                        addresses.append(try SolanaFixtures.key(entry))
                    } else {
                        var filler = [UInt8](repeating: 0xEE, count: 32)
                        filler[0] = UInt8(index & 0xFF)
                        filler[1] = UInt8(index >> 8)
                        addresses.append(try SolanaPublicKey(bytes: filler))
                    }
                }
                return SolanaAddressLookupTable(address: try SolanaFixtures.key(address), addresses: addresses)
            }
        }
    }
}
