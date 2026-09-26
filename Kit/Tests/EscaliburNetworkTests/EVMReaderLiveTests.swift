import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra os RPCs e indexadores reais, so com ESCALIBUR_REDE=1. Le o estado de uma conta
/// publica com saldo nas sete redes e chama o planejador ate o `SigningPlan`, sem assinar
/// e sem transmitir nada.
///
/// A conta e a "Binance 8" (0xF977814e90dA44bFA03b6295A0616a897441aceC), carteira quente
/// de exchange com saldo nativo nas sete redes e sem codigo. A chave publica foi
/// recuperada (ecrecover) da assinatura da transacao
/// 0x16d93ffd559e10c60889377e1279bee7d2ec9de72051185807869fcad7510cfc na Ethereum, em
/// 25/09/2026, e o teste confere que ela da o endereco.
@Suite("Leitor EVM ao vivo", .enabled(if: Live.enabled), .serialized)
struct EVMReaderLiveTests {
    static let publicKey = [UInt8](hex: "02607495e42d9fd036496ae938284f66fa67c12ab13a75213cbc33ec751164eb4b")!
    static let path = DerivationPath("m/44'/60'/0'/0/0")!
    /// Destino sem codigo nas sete redes (conferido com `eth_getCode` em 25/09/2026): a
    /// "Binance 14". As contas das chaves privadas triviais (1, 2, 3...) nao servem: todas
    /// tem delegacao EIP-7702 para um contrato de dreno.
    static let destination = try! EVMAddress("0x28C6c06298d514Db089934071355E5743bf21d60")

    let reader = EVMReader()

    func account() throws -> EVMAccount {
        let account = try EVMAccount(path: Self.path, publicKey: Self.publicKey)
        #expect(account.address.checksummed == "0xF977814e90dA44bFA03b6295A0616a897441aceC")
        return account
    }

    @Test("Envio nativo planejado nas sete redes com o estado real", arguments: Chain.evmChains)
    func nativePlan(chain: Chain) async throws {
        let account = try account()
        let amount = BigUInt(1_000)
        let state = try await reader.networkState(chain: chain, account: account.address, intent: .native(to: Self.destination, amount: amount))
        #expect(state.chain.id == chain.id)
        #expect(state.pendingNonces.count >= 2)
        #expect(state.gasEstimate >= 21_000)
        #expect(!state.nativeBalance.isZero)
        #expect(state.destinationHasCode == false)
        if EVMFeeProfile.for(chain)?.chargesL1DataFee == true {
            #expect(state.l1DataFee != nil)
        } else {
            #expect(state.l1DataFee == nil)
        }
        let plan = try EVMPlanner.planNativeSend(
            walletID: UUID(), account: account, chain: chain, to: Self.destination, amount: amount, state: state,
            format: chain.evmChainID == 56 ? .legacy : .eip1559
        )
        #expect(plan.transactions.count == 1)
        #expect(plan.chain.id == chain.id)
        Live.note("\(chain.id): nonces \(state.pendingNonces), baseFee \(state.baseFeePerGas), gas \(state.gasEstimate), l1 \(state.l1DataFee?.description ?? "-")")
    }

    @Test("Envio de token da lista planejado com saldo real", arguments: Chain.evmChains)
    func tokenPlan(chain: Chain) async throws {
        let account = try account()
        var planned = false
        for asset in TokenRegistry.assets(on: chain) {
            guard case .token(let contract) = asset.kind else { continue }
            let token = EVMToken(chain: chain, contract: try EVMAddress(contract), symbol: asset.symbol, decimals: UInt8(asset.decimals))
            let tokenState = try await reader.tokenState(token: token, owner: account.address)
            #expect(tokenState.contractHasCode)
            guard !tokenState.balance.isZero else { continue }
            let state = try await reader.networkState(chain: chain, account: account.address, intent: .token(token, to: Self.destination, amount: 1))
            let plan = try EVMPlanner.planTokenSend(
                walletID: UUID(), account: account, token: token, to: Self.destination, amount: 1, state: state, tokenState: tokenState,
                format: chain.evmChainID == 56 ? .legacy : .eip1559
            )
            #expect(plan.transactions.count == 1)
            Live.note("\(chain.id): \(asset.symbol) planejado, gas \(state.gasEstimate)")
            planned = true
            break
        }
        Live.note("\(chain.id): token planejado = \(planned)")
    }

    /// O USDT da Ethereum com allowance atual diferente de zero: a estimativa do approve
    /// so passa com o state override que zera o slot 5 (`allowed`). Um par dono/spender
    /// com allowance viva vem dos eventos `Approval` recentes.
    @Test("USDT: slot 5 do allowance e estimativa de approve com state override")
    func usdtApproveOverride() async throws {
        let url = Endpoints.evm["ethereum"]![0].baseURL
        let usdt = "0xdAC17F958D2ee523a2206206994597C13D831ec7"
        let head = try await JSONRPC.call(url, method: "eth_blockNumber", params: [], as: String.self)
        let latest = try #require(BigUInt(hex: head)?.uint64)
        let logs = try await JSONRPC.call(url, method: "eth_getLogs", params: [.object([
            "address": .string(usdt), "fromBlock": .string("0x" + String(latest - 300, radix: 16)), "toBlock": .string("latest"),
            "topics": .array([.string("0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925")]),
        ])], as: [JSONValue].self)
        let token = EVMToken(chain: .ethereum, contract: try EVMAddress(usdt), symbol: "USDT", decimals: 6)
        // Mais recentes primeiro: aprovacao exata costuma ser consumida logo depois.
        for log in logs.reversed().prefix(80) {
            guard let topics = log["topics"]?.arrayValue, topics.count == 3,
                  let ownerWord = topics[1].stringValue.flatMap(Hex.decode), let spenderWord = topics[2].stringValue.flatMap(Hex.decode),
                  let owner = EVMAddress(bytes: Array(ownerWord.suffix(20))), let spender = EVMAddress(bytes: Array(spenderWord.suffix(20)))
            else { continue }
            let tokenState = try await reader.tokenState(token: token, owner: owner, spender: spender)
            guard let allowance = tokenState.allowance, !allowance.isZero else { continue }
            // O slot calculado pelo leitor guarda exatamente a allowance lida por `allowance()`.
            let override = try EVMReader.zeroAllowanceOverride(token: token, owner: owner, spender: spender)
            guard case .object(let outer) = override, case .object(let inner)? = outer[token.contract.checksummed],
                  case .object(let diff)? = inner["stateDiff"], let key = diff.keys.first
            else { Issue.record("override sem formato"); return }
            // Slot e allowance() lidos no mesmo bloco: a allowance de um spender ativo muda
            // entre blocos, e o que se confere aqui e so o calculo do slot.
            let block = try await JSONRPC.call(url, method: "eth_blockNumber", params: [], as: String.self)
            let stored = try await JSONRPC.call(url, method: "eth_getStorageAt", params: [.string(usdt), .string(key), .string(block)], as: String.self)
            let calldata = "0xdd62ed3e" + Hex.encode([UInt8](repeating: 0, count: 12) + owner.bytes) + Hex.encode([UInt8](repeating: 0, count: 12) + spender.bytes)
            let atBlock = try await JSONRPC.call(url, method: "eth_call", params: [.object(["to": .string(usdt), "data": .string(calldata)]), .string(block)], as: String.self)
            #expect(BigUInt(hex: stored) == BigUInt(hex: atBlock))
            let state = try await reader.networkState(chain: .ethereum, account: owner, intent: .approve(token, spender: spender, amount: .exact(allowance + 1)))
            #expect(state.gasEstimate > 21_000)
            Live.note("USDT approve com override: gas \(state.gasEstimate)")
            return
        }
        Issue.record("nenhuma aprovacao viva de USDT nos ultimos 300 blocos")
    }

    @Test("Provedor de outra rede e descartado pelo eth_chainId")
    func wrongChainProviderIsDropped() async throws {
        // Um RPC da Base configurado como Ethereum: o chainId 8453 nao e o 1 compilado.
        let base = Endpoints.evm["base"]![0]
        let reader = EVMReader(rpc: ["ethereum": [base]])
        await #expect(throws: ReaderError.wrongNetwork) {
            _ = try await reader.networkState(chain: .ethereum, account: Self.destination, intent: .native(to: Self.destination, amount: 1))
        }
    }

    @Test("Recibo de transacao conhecida: confirmada nos dois provedores")
    func knownReceipt() async throws {
        let status = try await reader.status(of: "0x16d93ffd559e10c60889377e1279bee7d2ec9de72051185807869fcad7510cfc", chain: .ethereum)
        guard case .confirmed(let block, let confirmations) = status else { Issue.record("status \(status)"); return }
        #expect(block != nil)
        #expect((confirmations ?? 0) > 1)
    }

    @Test("Historico pelos indexadores publicos", arguments: [Chain.ethereum, .base, .optimism, .arbitrum, .polygon, .avalanche])
    func history(chain: Chain) async throws {
        let page = try await reader.history(chain: chain, address: try account().address)
        #expect(page.items.count <= ActivityRules.pageSize)
        #expect(page.items.allSatisfy { $0.chainID == chain.id })
        Live.note("\(chain.id): \(page.items.count) itens, \(page.suspiciousCount) suspeitos, completo \(page.isComplete)")
    }

    @Test("BNB Chain sem indexador publico: historico indisponivel, com motivo")
    func bnbHistoryUnsupported() async throws {
        await #expect(throws: ReaderError.self) {
            _ = try await reader.history(chain: .bnb, address: Self.destination)
        }
    }
}
