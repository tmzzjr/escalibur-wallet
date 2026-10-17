import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Leitor EVM contra respostas gravadas (Fixtures/leitores/evm), sem rede. As respostas
/// sao de 25/09/2026, da conta "Binance 8" na Ethereum e na Base.
@Suite("Leitor EVM com respostas gravadas")
struct EVMReaderTests {
    static let owner = try! EVMAddress("0xF977814e90dA44bFA03b6295A0616a897441aceC")
    static let destination = try! EVMAddress("0x28C6c06298d514Db089934071355E5743bf21d60")

    /// Regras que respondem cada metodo com a resposta gravada; `overrides` troca a
    /// resposta de um metodo num host.
    static func transport(chainID: String = "eth_chainId-ethereum", overrides: [String: [String: Data]] = [:]) throws -> FixtureTransport {
        let recorded: [String: Data] = [
            "eth_chainId": try ReaderFixtures.data("evm", chainID),
            "eth_blockNumber": try ReaderFixtures.data("evm", "eth_blockNumber-ethereum"),
            "eth_getTransactionCount": try ReaderFixtures.data("evm", "eth_getTransactionCount-binance8"),
            "eth_feeHistory": try ReaderFixtures.data("evm", "eth_feeHistory-ethereum"),
            "eth_estimateGas": try ReaderFixtures.data("evm", "eth_estimateGas-nativo"),
            "eth_getCode": try ReaderFixtures.data("evm", "eth_getCode-eoa"),
            "eth_getBalance": try ReaderFixtures.data("evm", "eth_getBalance-binance8"),
            "eth_call": try ReaderFixtures.data("evm", "balanceOf-usdt-binance8"),
            "eth_getTransactionReceipt": try ReaderFixtures.data("evm", "eth_getTransactionReceipt-binance8"),
        ]
        return FixtureTransport([{ request, body in
            guard let method = FixtureTransport.method(body) else { return nil }
            if let host = request.url.host, let special = overrides[host]?[method] { return special }
            return recorded[method]
        }])
    }

    static func reader(_ transport: FixtureTransport, providers: [String] = ["a", "b"], chain: String = "ethereum") -> EVMReader {
        let list = providers.map { ProviderPool.Provider(name: $0, baseURL: URL(string: "https://\($0).test")!) }
        return EVMReader(transport: transport, rpc: [chain: list], history: [:], privateRelays: testProviders("relay1", "relay2"))
    }

    @Test("feeHistory: baseFee do proximo bloco e mediana das gorjetas por percentil")
    func feeHistory() throws {
        let result = try ReaderFixtures.json("evm", "eth_feeHistory-ethereum").field("result", "$")
        let (baseFee, tips) = try EVMReader.parseFeeHistory(result)
        #expect(baseFee == BigUInt(58_761_766))
        #expect(tips == EVMPriorityFees(slow: 173, normal: 4_200_540, fast: 100_000_000))
        let polygon = try ReaderFixtures.json("evm", "eth_feeHistory-polygon").field("result", "$")
        let (polygonBase, polygonTips) = try EVMReader.parseFeeHistory(polygon)
        #expect(polygonBase == BigUInt(224_269_697_215))
        #expect(polygonTips.normal == BigUInt(275_568_000_000))
    }

    @Test("Estado do envio nativo montado das respostas gravadas e aceito pelo planejador")
    func nativeState() async throws {
        let transport = try Self.transport()
        let reader = Self.reader(transport)
        let state = try await reader.networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1_000))
        #expect(state.pendingNonces == [20_629, 20_629])
        #expect(state.baseFeePerGas == BigUInt(58_761_766))
        #expect(state.gasEstimate == 21_000)
        #expect(state.nativeBalance == BigUInt(decimal: "439595913402087593105057")!)
        #expect(state.destinationHasCode == false)
        #expect(state.l1DataFee == nil)
        // Endereco so no corpo do POST: nenhuma URL o carrega.
        let text = Self.owner.checksummed.lowercased().dropFirst(2)
        #expect(transport.requests.allSatisfy { !$0.url.absoluteString.lowercased().contains(text) })
        #expect(transport.requests.allSatisfy { $0.method == .post })

        let account = try EVMAccount(path: DerivationPath("m/44'/60'/0'/0/0")!, publicKey: EVMReaderLiveTests.publicKey)
        let plan = try EVMPlanner.planNativeSend(walletID: UUID(), account: account, chain: .ethereum, to: Self.destination, amount: 1_000, state: state)
        #expect(plan.transactions.count == 1)
    }

    @Test("Regressao B1: baseFee e gorjetas pela mediana de dois provedores; gas pela menor estimativa")
    func twoSourceFees() async throws {
        // O segundo provedor infla: baseFee 10x, gorjetas 10x e o gas 5x.
        let inflated = rpcResult("""
        {"oldestBlock":"0x1","baseFeePerGas":["0x1","\(BigUInt(587_617_660).hexString)"],"gasUsedRatio":[0.5],
         "reward":[["\(BigUInt(1_730).hexString)","\(BigUInt(42_005_400).hexString)","\(BigUInt(1_000_000_000).hexString)"]]}
        """)
        let transport = try Self.transport(overrides: ["b.test": ["eth_feeHistory": inflated, "eth_estimateGas": rpcResult("\"0x19a28\"")]])
        let state = try await Self.reader(transport).networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        // A media das duas, nunca a maior: o exagero de um provedor entra pela metade, e o
        // teto do perfil limita o resto.
        #expect(state.baseFeePerGas == BigUInt(323_189_713))
        #expect(state.priorityFees.normal == BigUInt(23_102_970))
        #expect(state.gasEstimate == 21_000)
        // Um provedor so de taxa nao basta.
        let failing = try Self.transport(overrides: ["b.test": ["eth_feeHistory": rpcResult("null")]])
        await #expect(throws: (any Error).self) {
            _ = try await Self.reader(failing).networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        }
        #expect(EVMReader.median([1, 2, 3]) == 2 && EVMReader.median([2, 5]) == 4 && EVMReader.median([]) == 0)
    }

    @Test("Saldo e codigo lidos num bloco fixo, alguns blocos atras da ponta")
    func pinnedBlock() async throws {
        let transport = try Self.transport()
        _ = try await Self.reader(transport).networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        let pinned = transport.requests.compactMap { request -> String? in
            let body = request.body.flatMap { try? StrictJSON.parse($0) }
            guard FixtureTransport.method(body) == "eth_getBalance" else { return nil }
            return try? FixtureTransport.params(body)[1].string("block")
        }
        // 0x18da4d3 (ponta gravada) - 1 na Ethereum.
        #expect(!pinned.isEmpty)
        #expect(pinned.allSatisfy { $0 == "0x18da4d2" })
    }

    @Test("Regressao B2: o bloco fixado sai da menor ponta de dois provedores; pontas longe demais recusam")
    func pinnedBlockFromTwoHeads() async throws {
        func pinned(_ transport: FixtureTransport) -> Set<String> {
            Set(transport.requests.compactMap { request -> String? in
                let body = request.body.flatMap { try? StrictJSON.parse($0) }
                guard FixtureTransport.method(body) == "eth_getBalance" else { return nil }
                return try? FixtureTransport.params(body)[1].string("block")
            })
        }
        // "b" dois blocos atras da ponta gravada (0x18da4d3): vale a dele, menos 1.
        let behind = try Self.transport(overrides: ["b.test": ["eth_blockNumber": rpcResult("\"0x18da4d1\"")]])
        _ = try await Self.reader(behind).networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        #expect(pinned(behind) == ["0x18da4d0"])
        #expect(behind.requests.filter { FixtureTransport.method($0.body.flatMap { try? StrictJSON.parse($0) }) == "eth_blockNumber" }.count == 2)

        // Um provedor que diz uma ponta de mil blocos atras (ou a frente) fixaria as leituras
        // num estado velho: recusa, nas leituras do envio e nas do token.
        for head in ["\"0x18da0eb\"", "\"0x18da8bb\""] {
            let far = try Self.transport(overrides: ["b.test": ["eth_blockNumber": rpcResult(head)]])
            await #expect(throws: ReaderError.providersDisagree(field: "eth_blockNumber")) {
                _ = try await Self.reader(far).networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
            }
            let token = EVMToken(chain: .ethereum, contract: try EVMAddress("0xdAC17F958D2ee523a2206206994597C13D831ec7"), symbol: "USDT", decimals: 6)
            await #expect(throws: ReaderError.providersDisagree(field: "eth_blockNumber")) {
                _ = try await Self.reader(far).tokenState(token: token, owner: Self.owner)
            }
        }

        // A folga e o triplo do recuo do pin: 3 blocos na Ethereum, 120 na Arbitrum.
        #expect(EVMReader.maxHeadGap(.ethereum) == 3 && EVMReader.maxHeadGap(.arbitrum) == 120)
        #expect(try EVMReader.pin(heads: [100, 103], chain: .ethereum) == 99)
        #expect(throws: ReaderError.providersDisagree(field: "eth_blockNumber")) { try EVMReader.pin(heads: [100, 104], chain: .ethereum) }
        #expect(throws: ReaderError.notEnoughProviders(needed: 2, got: 1)) { try EVMReader.pin(heads: [100], chain: .ethereum) }
    }

    @Test("Provedor com chainId de outra rede e descartado; os outros dois bastam")
    func wrongChainProviderDropped() async throws {
        let base = try ReaderFixtures.data("evm", "eth_chainId-base")
        let transport = try Self.transport(overrides: ["b.test": ["eth_chainId": base]])
        let reader = Self.reader(transport, providers: ["a", "b", "c"])
        let state = try await reader.networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        #expect(state.pendingNonces.count == 2)
        // Depois de divergir, o provedor "b" so recebeu o eth_chainId.
        let toB = transport.requests.filter { $0.url.host == "b.test" }.compactMap { FixtureTransport.method($0.body.flatMap { try? StrictJSON.parse($0) }) }
        #expect(toB == ["eth_chainId"])
    }

    @Test("Com um so provedor na rede certa, o nonce nao fecha: erro, nao chute")
    func singleNonceSourceFails() async throws {
        let base = try ReaderFixtures.data("evm", "eth_chainId-base")
        let transport = try Self.transport(overrides: ["b.test": ["eth_chainId": base]])
        await #expect(throws: ReaderError.notEnoughProviders(needed: 2, got: 1)) {
            _ = try await Self.reader(transport).networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        }
    }

    @Test("Nonces diferentes chegam os dois ao plano, que decide")
    func disagreeingNonces() async throws {
        let other = rpcResult("\"0x509f\"")
        let transport = try Self.transport(overrides: ["b.test": ["eth_getTransactionCount": other]])
        let state = try await Self.reader(transport).networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        #expect(Set(state.pendingNonces) == [20_629, 20_639])
        let account = try EVMAccount(path: DerivationPath("m/44'/60'/0'/0/0")!, publicKey: EVMReaderLiveTests.publicKey)
        #expect(throws: EVMPlanError.nonceSourcesDisagree) {
            _ = try EVMPlanner.planNativeSend(walletID: UUID(), account: account, chain: .ethereum, to: Self.destination, amount: 1, state: state)
        }
    }

    @Test("Saldo diferente nos dois provedores, e sem terceiro: erro de consenso")
    func balanceDisagreement() async throws {
        let transport = try Self.transport(overrides: ["b.test": ["eth_getBalance": rpcResult("\"0x1\"")]])
        await #expect(throws: ReaderError.providersDisagree(field: "eth_getBalance")) {
            _ = try await Self.reader(transport).networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        }
    }

    @Test("Resposta sem `result` e erro de formato, nunca zero")
    func missingResultIsMalformed() async throws {
        let empty = Data("{\"jsonrpc\":\"2.0\",\"id\":1}".utf8)
        let transport = try Self.transport(overrides: ["a.test": ["eth_getBalance": empty], "b.test": ["eth_getBalance": empty]])
        await #expect(throws: ReaderError.malformed(field: "eth_getBalance.result")) {
            _ = try await Self.reader(transport).networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        }
    }

    @Test("Destino com delegacao EIP-7702 conta como codigo")
    func delegatedDestinationHasCode() async throws {
        let code = try ReaderFixtures.data("evm", "eth_getCode-delegacao7702")
        let transport = try Self.transport(overrides: ["a.test": ["eth_getCode": code], "b.test": ["eth_getCode": code]])
        let state = try await Self.reader(transport).networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        #expect(state.destinationHasCode)
    }

    @Test("Base: taxa L1 do GasPriceOracle, com teto de sanidade")
    func l1DataFee() async throws {
        let base = try ReaderFixtures.data("evm", "eth_chainId-base")
        let oracle = try ReaderFixtures.data("evm", "getL1FeeUpperBound-base")
        let transport = try Self.transport(chainID: "eth_chainId-base", overrides: ["a.test": ["eth_call": oracle, "eth_chainId": base], "b.test": ["eth_call": oracle, "eth_chainId": base]])
        let state = try await Self.reader(transport, chain: "base").networkState(chain: .base, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        #expect(state.l1DataFee == BigUInt(696_569_626))
        // O pedido vai para o predeploy compilado, com o seletor de getL1FeeUpperBound(uint256).
        let call = transport.requests.compactMap { request -> StrictJSON? in
            let body = request.body.flatMap { try? StrictJSON.parse($0) }
            return FixtureTransport.method(body) == "eth_call" ? FixtureTransport.params(body).first : nil
        }.first
        #expect(try call?.field("to", "call").string("to") == "0x420000000000000000000000000000000000000F")
        #expect(try call?.field("data", "call").string("data").hasPrefix("0xf1c7a58b") == true)

        let absurd = rpcResult("\"0x00000000000000000000000000000000000000000000000000470de4df820000\"")  // 0,02 ETH
        let bad = try Self.transport(chainID: "eth_chainId-base", overrides: ["a.test": ["eth_call": absurd], "b.test": ["eth_call": absurd]])
        await #expect(throws: ReaderError.implausibleValue(field: "getL1FeeUpperBound")) {
            _ = try await Self.reader(bad, chain: "base").networkState(chain: .base, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        }
    }

    @Test("Estado do token: codigo, balanceOf e allowance com dois provedores")
    func tokenState() async throws {
        let token = EVMToken(chain: .ethereum, contract: try EVMAddress("0xdAC17F958D2ee523a2206206994597C13D831ec7"), symbol: "USDT", decimals: 6)
        let code = try ReaderFixtures.data("evm", "eth_getCode-delegacao7702")
        let transport = try Self.transport(overrides: ["a.test": ["eth_getCode": code], "b.test": ["eth_getCode": code]])
        let state = try await Self.reader(transport).tokenState(token: token, owner: Self.owner, spender: Self.destination)
        #expect(state.contractHasCode)
        #expect(state.balance == BigUInt(16_000_000_000_000_000))
        #expect(state.allowance == BigUInt(16_000_000_000_000_000))
    }

    @Test("State override do USDT: chave do slot 5 do mapping allowed")
    func usdtOverrideKey() throws {
        let token = EVMToken(chain: .ethereum, contract: try EVMAddress("0xdAC17F958D2ee523a2206206994597C13D831ec7"), symbol: "USDT", decimals: 6)
        let override = try EVMReader.zeroAllowanceOverride(token: token, owner: Self.owner, spender: Self.destination)
        let slot = BigUInt(5).bigEndianBytes(padTo: 32)!
        let expected = Hash.keccak256([UInt8](repeating: 0, count: 12) + Self.destination.bytes
            + Hash.keccak256([UInt8](repeating: 0, count: 12) + Self.owner.bytes + slot))
        guard case .object(let outer) = override, case .object(let inner)? = outer[token.contract.checksummed],
              case .object(let diff)? = inner["stateDiff"] else { Issue.record("formato"); return }
        #expect(diff.keys.first == Hex.encode(expected, prefix: true))
        // Outro token nao tem slot conhecido: recusa em vez de adivinhar.
        let usdc = EVMToken(chain: .ethereum, contract: try EVMAddress("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"), symbol: "USDC", decimals: 6)
        #expect(throws: ReaderError.self) { _ = try EVMReader.zeroAllowanceOverride(token: usdc, owner: Self.owner, spender: Self.destination) }
    }

    @Test("gasLimit acima do teto da EIP-7825 e recusado")
    func gasEstimateCeiling() async throws {
        let huge = rpcResult("\"0x2000000\"")
        let transport = try Self.transport(overrides: ["a.test": ["eth_estimateGas": huge], "b.test": ["eth_estimateGas": huge]])
        await #expect(throws: ReaderError.implausibleValue(field: "eth_estimateGas")) {
            _ = try await Self.reader(transport).networkState(chain: .ethereum, account: Self.owner, intent: .native(to: Self.destination, amount: 1))
        }
    }

    // MARK: Leituras do motor de envio

    @Test("eth_call da transacao exata: dois provedores, no bloco fixado, com from e value")
    func simulateCall() async throws {
        let transport = try Self.transport()
        let data = ERC20.transfer(to: Self.destination, amount: 1)
        let returned = try await Self.reader(transport).simulateCall(chain: .ethereum, from: Self.owner, to: Self.destination, value: 5, data: data)
        #expect(returned.count == 32)
        let calls = transport.requests.filter { FixtureTransport.method($0.body.flatMap { try? StrictJSON.parse($0) }) == "eth_call" }
        #expect(Set(calls.map(\.url.host)) == ["a.test", "b.test"])
        for request in calls {
            let params = FixtureTransport.params(request.body.flatMap { try? StrictJSON.parse($0) })
            #expect(try params[0].field("from", "call").string("from") == Self.owner.checksummed)
            #expect(try params[0].field("value", "call").string("value") == "0x5")
            #expect(try params[0].field("data", "call").string("data") == Hex.encode(data, prefix: true))
            #expect(try params[1].string("block") == "0x18da4d2")
        }
    }

    @Test("eth_call da transacao exata: revert em um provedor ou retornos diferentes recusam, sem cair para um so")
    func simulateCallRefusals() async throws {
        let data = ERC20.transfer(to: Self.destination, amount: 1)
        let revert = rpcError(code: 3, message: "execution reverted")
        let reverting = try Self.transport(overrides: ["b.test": ["eth_call": revert]])
        await #expect(throws: ReaderError.executionReverted) {
            _ = try await Self.reader(reverting, providers: ["a", "b", "c"])
                .simulateCall(chain: .ethereum, from: Self.owner, to: Self.destination, value: 0, data: data)
        }
        let other = try Self.transport(overrides: ["b.test": ["eth_call": rpcResult("\"0x\"")]])
        await #expect(throws: ReaderError.providersDisagree(field: "eth_call")) {
            _ = try await Self.reader(other, providers: ["a", "b", "c"])
                .simulateCall(chain: .ethereum, from: Self.owner, to: Self.destination, value: 0, data: data)
        }
        // Provedor fora do ar nao conta: o terceiro completa as duas respostas.
        let down = try Self.transport(overrides: ["b.test": ["eth_call": Data("<html>".utf8)]])
        let returned = try await Self.reader(down, providers: ["a", "b", "c"])
            .simulateCall(chain: .ethereum, from: Self.owner, to: Self.destination, value: 0, data: data)
        #expect(returned.count == 32)
    }

    @Test("Codigo do destino com dois provedores concordando")
    func hasCode() async throws {
        #expect(try await Self.reader(try Self.transport()).hasCode(chain: .ethereum, address: Self.destination) == false)
        let code = try ReaderFixtures.data("evm", "eth_getCode-delegacao7702")
        let delegated = try Self.transport(overrides: ["a.test": ["eth_getCode": code], "b.test": ["eth_getCode": code]])
        #expect(try await Self.reader(delegated).hasCode(chain: .ethereum, address: Self.destination))
        let split = try Self.transport(overrides: ["b.test": ["eth_getCode": code]])
        await #expect(throws: ReaderError.providersDisagree(field: "eth_getCode")) {
            _ = try await Self.reader(split).hasCode(chain: .ethereum, address: Self.destination)
        }
    }

    // MARK: Transmissao e acompanhamento

    static func signed(_ raw: [UInt8] = [0x02, 0xC0]) -> SignedTransaction {
        SignedTransaction(chainID: "ethereum", raw: raw, encoded: Hex.encode(raw, prefix: true), id: Hex.encode(Hash.keccak256(raw), prefix: true))
    }

    /// Os `eth_sendRawTransaction` que chegaram ao transporte. A transmissao volta no
    /// primeiro que aceita e o outro segue sozinho: espera ele chegar.
    static func sentRaw(_ transport: FixtureTransport, expecting count: Int) async throws -> [String] {
        func read() -> [String] {
            transport.requests.compactMap { request -> String? in
                let body = request.body.flatMap { try? StrictJSON.parse($0) }
                guard FixtureTransport.method(body) == "eth_sendRawTransaction" else { return nil }
                return try? FixtureTransport.params(body)[0].string("raw")
            }
        }
        for _ in 0..<200 where read().count < count { try await Task.sleep(for: .milliseconds(10)) }
        return read()
    }

    @Test("Transmissao: mesmos bytes a dois provedores, o id e o calculado aqui, e volta no primeiro que aceita")
    func broadcast() async throws {
        let signed = Self.signed()
        let accepted = rpcResult("\"\(signed.id)\"")
        let known = rpcError(code: -32000, message: "already known")
        let transport = try Self.transport(overrides: ["a.test": ["eth_sendRawTransaction": accepted], "b.test": ["eth_sendRawTransaction": known]])
        let receipt = try await Self.reader(transport).broadcast(signed, chain: .ethereum)
        #expect(receipt.id == signed.id)
        #expect(!receipt.acceptedBy.isEmpty && Set(receipt.acceptedBy).isSubset(of: ["a", "b"]))
        #expect(try await Self.sentRaw(transport, expecting: 2) == [signed.encoded, signed.encoded])
    }

    @Test("Transmissao: provedor que devolve outro hash nao conta; todos recusando da o motivo")
    func broadcastRejections() async throws {
        let signed = Self.signed()
        let wrongHash = rpcResult("\"0x\(String(repeating: "ab", count: 32))\"")
        let low = rpcError(code: -32000, message: "nonce too low: next nonce 5, tx nonce 4")
        let transport = try Self.transport(overrides: ["a.test": ["eth_sendRawTransaction": wrongHash], "b.test": ["eth_sendRawTransaction": low]])
        await #expect(throws: ReaderError.broadcastRejected(.nonceTooLow, code: "-32000")) {
            _ = try await Self.reader(transport).broadcast(signed, chain: .ethereum)
        }
        let recorded = try ReaderFixtures.data("evm", "eth_sendRawTransaction-erro")
        let both = try Self.transport(overrides: ["a.test": ["eth_sendRawTransaction": recorded], "b.test": ["eth_sendRawTransaction": recorded]])
        await #expect(throws: ReaderError.broadcastRejected(.other, code: "-32600")) {
            _ = try await Self.reader(both).broadcast(signed, chain: .ethereum)
        }
    }

    @Test("Transmissao recusa bytes que nao batem com o id, e rede errada")
    func broadcastIntegrity() async throws {
        let transport = try Self.transport()
        let reader = Self.reader(transport)
        let good = Self.signed()
        let tampered = SignedTransaction(chainID: "ethereum", raw: good.raw, encoded: "0x02c1", id: good.id)
        await #expect(throws: ReaderError.broadcastMismatch) { _ = try await reader.broadcast(tampered, chain: .ethereum) }
        let otherChain = SignedTransaction(chainID: "base", raw: good.raw, encoded: good.encoded, id: good.id)
        await #expect(throws: ReaderError.broadcastMismatch) { _ = try await reader.broadcast(otherChain, chain: .ethereum) }
        await #expect(throws: ReaderError.invalidInput("protecao de MEV so na Ethereum")) {
            _ = try await Self.reader(transport, chain: "base").broadcast(
                SignedTransaction(chainID: "base", raw: good.raw, encoded: good.encoded, id: good.id), chain: .base, route: .mevProtected
            )
        }
        #expect(transport.requests.allSatisfy { FixtureTransport.method($0.body.flatMap { try? StrictJSON.parse($0) }) != "eth_sendRawTransaction" })
    }

    @Test("Protecao de MEV: vai aos relays privados, nao aos RPCs publicos")
    func mevRoute() async throws {
        let signed = Self.signed()
        let accepted = rpcResult("\"\(signed.id)\"")
        let transport = try Self.transport(overrides: ["relay1.test": ["eth_sendRawTransaction": accepted], "relay2.test": ["eth_sendRawTransaction": accepted]])
        let receipt = try await Self.reader(transport).broadcast(signed, chain: .ethereum, route: .mevProtected)
        #expect(!receipt.acceptedBy.isEmpty && Set(receipt.acceptedBy).isSubset(of: ["relay1", "relay2"]))
        _ = try await Self.sentRaw(transport, expecting: 2)
        let sentTo = transport.requests.filter { FixtureTransport.method($0.body.flatMap { try? StrictJSON.parse($0) }) == "eth_sendRawTransaction" }.map(\.url.host)
        #expect(Set(sentTo) == ["relay1.test", "relay2.test"])
    }

    @Test("Recibo gravado: confirmado com dois provedores; um `null` pergunta ao terceiro")
    func receiptStatus() async throws {
        let hash = "0x16d93ffd559e10c60889377e1279bee7d2ec9de72051185807869fcad7510cfc"
        let confirmed = try await Self.reader(try Self.transport()).status(of: hash, chain: .ethereum)
        // Bloco 0x18d8cd2 = 26.053.842; ponta gravada 0x18da4d3 = 26.059.987.
        #expect(confirmed == .confirmed(block: 26_053_842, confirmations: 6_146))

        let null = try ReaderFixtures.data("evm", "eth_getTransactionReceipt-cloudflare-null")
        let third = try Self.transport(overrides: ["b.test": ["eth_getTransactionReceipt": null]])
        let viaThird = try await Self.reader(third, providers: ["a", "b", "c"]).status(of: hash, chain: .ethereum)
        #expect(viaThird == .confirmed(block: 26_053_842, confirmations: 6_146))

        let onlyOne = try Self.transport(overrides: ["b.test": ["eth_getTransactionReceipt": null]])
        #expect(try await Self.reader(onlyOne).status(of: hash, chain: .ethereum) == .pending)

        let failed = try ReaderFixtures.json("evm", "eth_getTransactionReceipt-binance8").field("result", "$")
        guard case .object(var fields) = failed else { return }
        fields["status"] = .string("0x0")
        #expect(try EVMReader.parseReceipt(.object(fields))?.success == false)
    }

    // MARK: Historico

    @Test("Blockscout: po do sosia e token falso escondidos, envios do dono aparecem")
    func blockscoutHistory() throws {
        let page = try EVMReader.parseBlockscoutHistory(
            chain: .base, owner: Self.owner,
            transactions: ReaderFixtures.json("evm", "blockscout-transactions-base"),
            tokenTransfers: ReaderFixtures.json("evm", "blockscout-token-transfers-base")
        )
        // Nada de token fora da lista chega a tela: "EṬH", "IUK", "C", "OPG". O MORPHO
        // entrou na lista em 27/09/2026: o recebimento real dele aparece.
        #expect(page.items.allSatisfy { $0.asset.kind == .native || TokenRegistry.tokens.contains($0.asset) })
        #expect(page.suspicious.unknownAsset == 7)
        // 0,0000423 ETH do sosia 0x2652742D...1008 e 100 wei: po, escondido.
        #expect(page.suspicious.dust == 2)
        #expect(page.items.filter { $0.direction == .received }.map(\.asset.symbol) == ["MORPHO"])
        // As chamadas do dono (sem valor nativo) aparecem como "outro", com a taxa.
        let calls = page.items.filter { $0.direction == .other }
        #expect(calls.count == 4)
        #expect(calls.allSatisfy { $0.fee != nil && $0.status == .confirmed })
        #expect(page.items.allSatisfy { $0.explorerURL?.host == "basescan.org" })
    }

    @Test("Montagem: troca, falsificacao de saida e recebimento valido")
    func assembleRules() throws {
        let usdc = try EVMAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")
        let fake = try EVMAddress("0x58bDC4310db1b19854Ca9066deEd7E3dF4F2Ec9B")
        let stranger = try EVMAddress("0x2652742DE21ED9a6c37e73b0E3a51b239A6D1008")
        let router = try EVMAddress("0x6fF5693b99212Da76ad316178A184AB56D299b43")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let rows = [
            // Troca do dono: sai 0,01 ETH, entra 30 USDC.
            EVMReader.TransactionRow(hash: "0xaa", date: now, status: .confirmed, from: Self.owner, to: router, value: BigUInt(10_000_000_000_000_000), fee: 1_000),
        ]
        let tokens = [
            EVMReader.TokenRow(hash: "0xaa", index: "1", date: now, from: router, to: Self.owner, contract: usdc, amount: 30_000_000),
            // `Transfer(dono, sosia)` emitido por contrato falso numa transacao de terceiro.
            EVMReader.TokenRow(hash: "0xbb", index: "7", date: now, from: Self.owner, to: stranger, contract: fake, amount: 5_000_000),
            // `transferFrom(dono, sosia, 0)` do USDC real, de terceiro: passa sem allowance.
            EVMReader.TokenRow(hash: "0xcc", index: "3", date: now, from: Self.owner, to: stranger, contract: usdc, amount: 0),
            // Recebimento valido de 12 USDC.
            EVMReader.TokenRow(hash: "0xdd", index: "2", date: now.addingTimeInterval(-60), from: stranger, to: Self.owner, contract: usdc, amount: 12_000_000),
            // USDC de 0,001: po.
            EVMReader.TokenRow(hash: "0xee", index: "4", date: now, from: stranger, to: Self.owner, contract: usdc, amount: 1_000),
        ]
        let page = EVMReader.assemble(chain: .base, owner: Self.owner, rows: rows, tokens: tokens)
        let swap = try #require(page.items.first { $0.direction == .swap })
        #expect(swap.asset.kind == .native)
        #expect(swap.amount == BigUInt(10_000_000_000_000_000))
        #expect(swap.receivedAsset?.symbol == "USDC")
        #expect(swap.receivedAmount == 30_000_000)
        #expect(swap.fee == 1_000)
        let received = page.items.filter { $0.direction == .received }
        #expect(received.count == 1)
        #expect(received.first?.amount == 12_000_000)
        #expect(received.first?.fee == nil)
        #expect(!page.items.contains { $0.direction == .sent })
        #expect(page.suspicious.unknownAsset == 1)
        #expect(page.suspicious.zeroValue == 1)
        #expect(page.suspicious.dust == 1)
    }

    @Test("Routescan (Avalanche): formato Etherscan lido e tokens da lista separados")
    func routescanHistory() throws {
        let page = try EVMReader.parseEtherscanHistory(
            chain: .avalanche, owner: Self.owner,
            transactions: ReaderFixtures.json("evm", "routescan-txlist-avalanche"),
            tokenTransfers: ReaderFixtures.json("evm", "routescan-tokentx-avalanche")
        )
        #expect(page.items.allSatisfy { $0.chainID == "avalanche" })
        #expect(page.items.allSatisfy { $0.asset.kind == .native || TokenRegistry.tokens.contains($0.asset) })
        #expect(page.items.count + page.suspiciousCount > 0)
    }

    /// Responde a Alchemy pelas gravacoes de 15/10/2026 (Ethereum e Base) e 16/10/2026
    /// (BNB Chain): uma por categoria e lado, o lote de recibos (um corpo que e lista) e,
    /// na BNB, o lote do nonce e do codigo da recuperacao. `tokens: false` faz as
    /// consultas de token falharem.
    private func alchemyTransport(_ chain: String, receipts: Bool = true, tokens: Bool = true) -> FixtureTransport {
        FixtureTransport([{ request, body in
            if case .array(let calls)? = body, calls.contains(where: { FixtureTransport.method($0) == "eth_getCode" }) {
                return try ReaderFixtures.data("evm", "alchemy-deteccao-\(chain)")
            }
            if case .array? = body { return receipts ? try ReaderFixtures.data("evm", "alchemy-recibos-\(chain)") : nil }
            guard FixtureTransport.method(body) == "alchemy_getAssetTransfers",
                  case .object(let query)? = FixtureTransport.params(body).first,
                  case .array(let categories)? = query["category"], categories.count == 1, case .string(let category) = categories[0]
            else { return nil }
            if category == "erc20", !tokens { throw HTTPClient.Failure.status(503) }
            let side = query["fromAddress"] != nil ? "from" : "to"
            return try ReaderFixtures.data("evm", "alchemy-\(category)-\(side)-\(chain)")
        }])
    }

    /// As categorias pedidas a `alchemy_getAssetTransfers`, na ordem em que sairam.
    private func askedCategories(_ transport: FixtureTransport) -> [String] {
        transport.requests.compactMap { request -> String? in
            let body = request.body.flatMap { try? StrictJSON.parse($0) }
            guard case .object(let query)? = FixtureTransport.params(body).first, case .array(let categories)? = query["category"],
                  case .string(let category)? = categories.first
            else { return nil }
            return category
        }
    }

    @Test("Alchemy (Ethereum): uma consulta por categoria e lado, endereco so no corpo, taxa pelos recibos")
    func alchemyHistory() async throws {
        let owner = try EVMAddress("0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        let transport = alchemyTransport("ethereum")
        let provider = ProviderPool.Provider(name: "alchemy", baseURL: URL(string: "https://alchemy.test/v2/chave")!)
        let reader = EVMReader(transport: transport, rpc: [:], history: ["ethereum": [provider]], privateRelays: [])
        let page = try await reader.history(chain: .ethereum, address: owner)

        // Envio e recebimento nativos, token de e para, internas e o lote de recibos.
        #expect(transport.requests.count == 6)
        #expect(transport.requests.allSatisfy { !$0.url.absoluteString.lowercased().contains(owner.checksummed.lowercased()) })
        #expect(page.isComplete)
        #expect(page.items.allSatisfy { $0.chainID == "ethereum" })
        #expect(page.items.allSatisfy { $0.asset.kind == .native || TokenRegistry.tokens.contains($0.asset) })
        #expect(page.items.allSatisfy { $0.status == .confirmed })
        // As "saidas" falsas de token e os recebimentos de token desconhecido ficam fora.
        #expect(page.suspicious.unknownAsset > 0)
        #expect(page.items.contains { $0.direction == .sent && $0.fee != nil })
        #expect(!page.items.contains { $0.direction == .received && $0.fee != nil })
    }

    @Test("Alchemy (Base): sem a categoria interna, e a taxa soma a da L1")
    func alchemyHistoryBase() async throws {
        let owner = try EVMAddress("0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        let transport = alchemyTransport("base")
        let provider = ProviderPool.Provider(name: "alchemy", baseURL: URL(string: "https://alchemy.test/v2/chave")!)
        let reader = EVMReader(transport: transport, rpc: [:], history: ["base": [provider]], privateRelays: [])
        let page = try await reader.history(chain: .base, address: owner)
        #expect(transport.requests.count == 5)
        #expect(page.items.allSatisfy { $0.chainID == "base" })

        let receipts = try ReaderFixtures.json("evm", "alchemy-recibos-base")
        let fees = EVMReader.parseReceiptFees(receipts)
        let first = try receipts.array("r")[0].field("result", "r")
        let used = try first.field("gasUsed", "r").quantity("r")
        let price = try first.field("effectiveGasPrice", "r").quantity("r")
        let l1 = try first.field("l1Fee", "r").quantity("r")
        #expect(l1 > 0)
        #expect(fees[try first.field("transactionHash", "r").string("r").lowercased()] == used * price + l1)
    }

    @Test("Alchemy: o valor vem do rawContract em hex, nunca do numero arredondado")
    func alchemyExactAmounts() throws {
        let owner = try EVMAddress("0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        let received = try ReaderFixtures.json("evm", "alchemy-external-to-ethereum").field("result", "result")
        let page = try EVMReader.parseAlchemyHistory(chain: .ethereum, owner: owner, transactions: [received], tokenTransfers: [])
        let rawValues = Set(try received.field("transfers", "t").array("t").map {
            try $0.field("rawContract", "t").field("value", "t").quantity("t")
        })
        #expect(page.items.contains { $0.direction == .received && $0.asset.kind == .native })
        for item in page.items where item.direction == .received && item.asset.kind == .native {
            #expect(rawValues.contains(item.amount))
        }
    }

    @Test("Alchemy: sem os tokens a pagina e parcial, e sem os recibos os envios saem sem taxa")
    func alchemyPartial() async throws {
        let owner = try EVMAddress("0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        let page = try EVMReader.parseAlchemyHistory(
            chain: .ethereum, owner: owner,
            transactions: [
                try ReaderFixtures.json("evm", "alchemy-external-from-ethereum").field("result", "result"),
                try ReaderFixtures.json("evm", "alchemy-external-to-ethereum").field("result", "result"),
            ],
            tokenTransfers: [], complete: false
        )
        #expect(!page.isComplete)
        #expect(!page.items.isEmpty)

        let transport = alchemyTransport("ethereum", receipts: false)
        let provider = ProviderPool.Provider(name: "alchemy", baseURL: URL(string: "https://alchemy.test/v2/chave")!)
        let reader = EVMReader(transport: transport, rpc: [:], history: ["ethereum": [provider]], privateRelays: [])
        let withoutFees = try await reader.history(chain: .ethereum, address: owner)
        #expect(!withoutFees.items.isEmpty)
        #expect(withoutFees.items.allSatisfy { $0.fee == nil })
    }

    @Test("Alchemy (BNB Chain): sem a categoria interna, endereco so no corpo, taxa pelos recibos sem L1")
    func alchemyHistoryBNB() async throws {
        #expect(Endpoints.evmHistory["bnb"]?.map(\.name) == ["alchemy"])
        #expect(Endpoints.evmHistory["bnb"]?.first?.baseURL.host == "bnb-mainnet.g.alchemy.com")
        #expect(Endpoints.evmHistory["bnb"]?.first?.baseURL.path == Endpoints.alchemy["base"]?.path)

        let owner = try EVMAddress("0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        let transport = alchemyTransport("bnb")
        let provider = ProviderPool.Provider(name: "alchemy", baseURL: URL(string: "https://alchemy.test/v2/chave")!)
        let reader = EVMReader(transport: transport, rpc: [:], history: ["bnb": [provider]], privateRelays: [])
        let page = try await reader.history(chain: .bnb, address: owner)

        // Envio e recebimento nativos, token de e para, o lote de recibos e o lote do nonce
        // e do codigo. A categoria interna nem e pedida: na BNB a Alchemy recusa o pedido
        // inteiro (-32602). A conta de teste do BIP-39 tem delegacao EIP-7702 na BNB (o
        // codigo `0xef0100...`): a recuperacao das falhas e do BNB mandado por contrato
        // para ali, sem busca e sem saldo.
        #expect(transport.requests.count == 6)
        #expect(!transport.requests.contains { request in
            let body = request.body.flatMap { try? StrictJSON.parse($0) }
            return ["eth_blockNumber", "eth_getBlockByNumber"].contains(FixtureTransport.method(body) ?? "")
        })
        #expect(askedCategories(transport).sorted() == ["erc20", "erc20", "external", "external"])
        #expect(transport.requests.allSatisfy { !$0.url.absoluteString.lowercased().contains(owner.checksummed.lowercased()) })
        #expect(page.isComplete)
        #expect(!page.items.isEmpty)
        #expect(page.items.allSatisfy { $0.chainID == "bnb" })
        #expect(page.items.allSatisfy { $0.asset.kind == .native || TokenRegistry.tokens.contains($0.asset) })
        // A Alchemy so lista o que se moveu: nada sai como falha.
        #expect(page.items.allSatisfy { $0.status == .confirmed })
        // As "saidas" falsas de token e os recebimentos de token desconhecido ficam fora.
        #expect(page.suspicious.unknownAsset > 0)

        // Na BNB a taxa e `gasUsed` vezes `effectiveGasPrice`, sem taxa de L1.
        let receipts = try ReaderFixtures.json("evm", "alchemy-recibos-bnb")
        #expect(try receipts.array("r").allSatisfy { try $0.field("result", "r").optionalField("l1Fee") == nil })
        let fees = EVMReader.parseReceiptFees(receipts)
        let paid = page.items.filter { $0.fee != nil }
        #expect(!paid.isEmpty)
        #expect(paid.allSatisfy { $0.fee == fees[$0.hash.lowercased()] })
        #expect(!page.items.contains { $0.direction == .received && $0.fee != nil })
    }

    @Test("Alchemy (BNB Chain): sem os tokens, a pagina sai marcada como parcial, com as transacoes do dono")
    func alchemyPartialBNB() async throws {
        let owner = try EVMAddress("0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        let transport = alchemyTransport("bnb", tokens: false)
        let provider = ProviderPool.Provider(name: "alchemy", baseURL: URL(string: "https://alchemy.test/v2/chave")!)
        let reader = EVMReader(transport: transport, rpc: [:], history: ["bnb": [provider]], privateRelays: [])
        let page = try await reader.history(chain: .bnb, address: owner)
        #expect(!page.isComplete)
        #expect(!page.items.isEmpty)
        #expect(page.items.allSatisfy { $0.asset.kind == .native })
    }
}
