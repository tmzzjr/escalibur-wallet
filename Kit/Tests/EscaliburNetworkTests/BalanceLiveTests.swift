import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra os nos reais. So com ESCALIBUR_REDE=1.
@Suite("Saldos ao vivo", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"))
struct BalanceLiveTests {
    let service = BalanceService()

    @Test("Ethereum: nativo e tokens da lista")
    func ethereum() async throws {
        let balance = try await service.balance(chain: .ethereum, addresses: ["0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"])
        #expect(balance.holdings.first?.asset.kind == .native)
        #expect(!(balance.holdings.first?.amount.isZero ?? true))
    }

    @Test("Bitcoin pelo Esplora")
    func bitcoin() async throws {
        // Endereco do bloco genesis: recebe pequenas doacoes ate hoje.
        let balance = try await service.balance(chain: .bitcoin, addresses: ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"])
        #expect(!(balance.holdings.first?.amount.isZero ?? true))
    }

    @Test("XRP Ledger: conta existente e conta inexistente")
    func xrpl() async throws {
        let rich = try await service.balance(chain: .xrpl, addresses: ["rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"])
        #expect(rich.accountExists)
        let empty = try await service.balance(chain: .xrpl, addresses: ["rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3"])
        #expect(empty.accountExists == false || empty.holdings.count == 1)
    }

    @Test("Stellar, Solana, Tron")
    func others() async throws {
        let stellar = try await service.balance(chain: .stellar, addresses: ["GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6"])
        #expect(stellar.chainID == "stellar")
        let solana = try await service.balance(chain: .solana, addresses: ["HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"])
        #expect(solana.holdings.first?.asset.symbol == "SOL")
        let tron = try await service.balance(chain: .tron, addresses: ["TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH"])
        #expect(tron.holdings.first?.asset.symbol == "TRX")
    }
}

/// A lista curada de tokens confere com a propria cadeia: cada contrato EVM responde
/// `decimals()` igual ao compilado, em dois nos diferentes.
@Suite("Lista de tokens contra a cadeia", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_REDE"] == "1"))
struct TokenRegistryLiveTests {
    @Test("decimals() de cada ERC-20 bate com a lista, em dois nos")
    func evmDecimals() async throws {
        for token in TokenRegistry.tokens {
            guard let chain = token.chain, chain.family == .evm, case .token(let contract) = token.kind else { continue }
            let providers = Array((Endpoints.evm[chain.id] ?? []).prefix(2))
            var answers: [Int] = []
            for provider in providers {
                let call: JSONValue = .object(["to": .string(contract), "data": .string("0x313ce567")])
                if let hex = try? await JSONRPC.call(provider.baseURL, method: "eth_call", params: [call, .string("latest")], as: String.self),
                   let value = BigUInt(hex: hex)?.uint64 {
                    answers.append(Int(value))
                }
            }
            #expect(!answers.isEmpty, "\(chain.id) \(token.symbol): nenhum no respondeu")
            for answer in answers {
                #expect(answer == token.decimals, "\(chain.id) \(token.symbol) \(contract): cadeia diz \(answer), lista diz \(token.decimals)")
            }
        }
    }
}
