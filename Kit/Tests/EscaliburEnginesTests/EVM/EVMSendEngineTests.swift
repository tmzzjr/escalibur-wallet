@testable import EscaliburChains
import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburEngines
@testable import EscaliburNetwork

/// O motor de envio EVM contra respostas gravadas da Ethereum (Fixtures/evm, 26/09/2026,
/// conta "Binance 8"), com o `EVMReader` de verdade e um transporte sem rede.
@Suite("Motor EVM: envio")
struct EVMSendEngineTests {
    typealias A = EVMTestAccounts
    typealias F = EVMEthereumFixtures

    static let usdcAsset = TokenRegistry.find(chainID: "ethereum", contract: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")!

    static func engine(_ transport: EVMFixtureTransport, providers: [ProviderPool.Provider] = testProviders("a", "b")) -> EVMSendEngine {
        EVMSendEngine(chain: .ethereum, reader: F.reader(transport, providers: providers))!
    }

    static func request(
        asset: Asset = .native(.ethereum), to destination: EVMAddress = A.binance14, amount: BigUInt = 1_000, sendAll: Bool = false,
        tag: String? = nil, known: [String] = [], account: DerivedAccount = A.binance8(on: .ethereum)
    ) -> SendRequest {
        SendRequest(
            walletID: UUID(), chain: .ethereum, asset: asset, account: account, destination: destination.checksummed, tag: tag,
            amount: amount, sendAll: sendAll, feeLevel: .normal, utxoUsage: nil, knownAddresses: known
        )
    }

    static func message(_ error: Error) -> String? {
        (error as? SendEngineError).flatMap { if case .message(let text) = $0 { return text } else { return nil } }
    }

    // MARK: Plano

    @Test("Envio nativo para carteira comum: plano com o destino conferido e sem simulacao")
    func nativePlan() async throws {
        let transport = try F.transport()
        let plan = try await Self.engine(transport).plan(Self.request())
        #expect(plan.review.kind == .send)
        #expect(plan.review.recipient == A.binance14.checksummed)
        #expect(plan.review.transactionCount == 1)
        let transaction = try #require(plan.transactions.first as? EVMTransaction)
        #expect(transaction.to == A.binance14 && transaction.value == 1_000 && transaction.data.isEmpty)
        #expect(transaction.nonce == 0x5095)
        #expect(transaction.gasLimit == 21_000)
        // Primeiro envio para o endereco: o aviso sai do proprio plano.
        #expect(plan.review.warnings.contains(.firstSendToAddress))
        // Carteira comum: nada de eth_call; tudo por POST, com o chainId de cada provedor
        // conferido antes.
        #expect(transport.calls("eth_call").isEmpty)
        #expect(transport.calls.allSatisfy { $0.request.method == .post })
        #expect(Set(transport.calls("eth_chainId").map(\.host)) == ["a.test", "b.test"])
    }

    @Test("Regressao M1: nonce divergente entre os provedores so passa com a fila local que explica a diferenca")
    func nonceQueue() async throws {
        // O segundo provedor ja viu uma transacao deste aparelho (0x5095) que o primeiro nao viu.
        let transport = try F.transport()
        transport.prepend { call in
            call.host == "b.test" && call.method == "eth_getTransactionCount" ? EVMFixtures.result("\"0x5096\"") : nil
        }
        // Sem a fila: recusa, em vez de apostar no maior.
        await #expect(throws: SendEngineError.self) { _ = try await Self.engine(transport).plan(Self.request()) }
        // Com a fila dizendo que a 0x5095 esta em transito: vale o proximo da fila.
        let queue = PendingNonceQueue(nextNonce: 0x5096, pendingHashes: ["0x" + String(repeating: "ab", count: 32)])
        let request = SendRequest(
            walletID: UUID(), chain: .ethereum, asset: .native(.ethereum), account: A.binance8(on: .ethereum),
            destination: A.binance14.checksummed, tag: nil, amount: 1_000, sendAll: false, feeLevel: .normal, utxoUsage: nil,
            nonceQueue: queue
        )
        let plan = try await Self.engine(transport).plan(request)
        #expect(try #require(plan.transactions.first as? EVMTransaction).nonce == 0x5096)
        // A fila a frente do que ela explica: a transacao dela sumiu, e o motor diz isso.
        let lost = SendRequest(
            walletID: UUID(), chain: .ethereum, asset: .native(.ethereum), account: A.binance8(on: .ethereum),
            destination: A.binance14.checksummed, tag: nil, amount: 1_000, sendAll: false, feeLevel: .normal, utxoUsage: nil,
            nonceQueue: PendingNonceQueue(nextNonce: 0x5099, pendingHashes: [])
        )
        let fresh = try F.transport()
        await #expect(throws: SendEngineError.message(
            "Uma transação enviada deste aparelho não aparece mais na rede. Confira a Atividade antes de enviar outra. Nada foi assinado."
        )) { _ = try await Self.engine(fresh).plan(lost) }
    }

    @Test("USDC: a transferencia exata roda em eth_call, de dois provedores, antes do plano sair")
    func tokenPlanSimulated() async throws {
        let transport = try F.transport()
        let plan = try await Self.engine(transport).plan(Self.request(asset: Self.usdcAsset, amount: 1_000_000))
        let transaction = try #require(plan.transactions.first as? EVMTransaction)
        #expect(transaction.to == F.usdc)
        #expect(transaction.data == ERC20.transfer(to: A.binance14, amount: 1_000_000))
        #expect(plan.review.recipient == A.binance14.checksummed)
        let simulations = transport.calls("eth_call").filter { ($0.firstObject?["data"] as? String)?.hasPrefix(F.transferSelector) == true }
        #expect(Set(simulations.map(\.host)) == ["a.test", "b.test"])
        for call in simulations {
            #expect((call.firstObject?["from"] as? String)?.lowercased() == F.lower(A.binance8))
            #expect((call.firstObject?["to"] as? String)?.lowercased() == F.lower(F.usdc))
            #expect((call.firstObject?["data"] as? String) == Hex.encode(transaction.data, prefix: true))
            #expect(call.firstObject?["value"] == nil)
        }
    }

    @Test("Simulacao que reverte num dos provedores: o plano nao sai")
    func simulationRevertRefuses() async throws {
        let transport = try F.transport()
        let revert = try EVMFixtures.data("eth_call-transfer-usdc-revert")
        transport.prepend { call in
            call.host == "b.test" && call.method == "eth_call" && (call.firstObject?["data"] as? String)?.hasPrefix(F.transferSelector) == true ? revert : nil
        }
        await #expect(throws: SendEngineError.message("A simulação mostra que a rede recusaria esta transação agora. Nada foi assinado.")) {
            _ = try await Self.engine(transport).plan(Self.request(asset: Self.usdcAsset, amount: 1_000_000))
        }
    }

    @Test("Simulacoes com retornos diferentes: o plano nao sai, e nao cai para uma resposta so")
    func simulationDisagreementRefuses() async throws {
        let transport = try F.transport()
        transport.prepend { call in
            call.host == "b.test" && call.method == "eth_call" && (call.firstObject?["data"] as? String)?.hasPrefix(F.transferSelector) == true
                ? EVMFixtures.result("\"0x\"") : nil
        }
        await #expect(throws: SendEngineError.message(EVMEngineMessages.staleProviders)) {
            _ = try await Self.engine(transport).plan(Self.request(asset: Self.usdcAsset, amount: 1_000_000))
        }
    }

    @Test("Token que devolveria false sem reverter: recusa")
    func transferFalseRefuses() async throws {
        let transport = try F.transport()
        let zero = EVMFixtures.result("\"0x" + String(repeating: "0", count: 64) + "\"")
        transport.prepend { call in
            call.method == "eth_call" && (call.firstObject?["data"] as? String)?.hasPrefix(F.transferSelector) == true ? zero : nil
        }
        await #expect(throws: SendEngineError.message("O contrato do token recusaria esta transferência. Nada foi assinado.")) {
            _ = try await Self.engine(transport).plan(Self.request(asset: Self.usdcAsset, amount: 1_000_000))
        }
    }

    @Test("Destino com codigo: o envio nativo e simulado; o contrato que reverte bloqueia")
    func contractDestination() async throws {
        let transport = try F.transport()
        let plan = try await Self.engine(transport).plan(Self.request(to: A.safe))
        #expect(plan.review.warnings.contains(.destinationIsContract))
        let simulated = transport.calls("eth_call").filter { ($0.firstObject?["to"] as? String)?.lowercased() == F.lower(A.safe) }
        #expect(Set(simulated.map(\.host)) == ["a.test", "b.test"])
        #expect(simulated.allSatisfy { $0.firstObject?["value"] as? String == "0x3e8" })

        // O contrato de deposito nao recebe ETH puro. A estimativa gravada e a do Safe; a
        // simulacao e que diz que a transacao falharia.
        let deposit = try F.transport()
        deposit.prepend { call in
            guard call.method == "eth_getCode" || call.method == "eth_estimateGas" else { return nil }
            let target = (call.params.first as? String) ?? (call.firstObject?["to"] as? String)
            guard target?.lowercased() == F.lower(A.depositContract) else { return nil }
            return try EVMFixtures.data(call.method == "eth_getCode" ? "eth_getCode-safe" : "eth_estimateGas-safe")
        }
        await #expect(throws: SendEngineError.message("A simulação mostra que a rede recusaria esta transação agora. Nada foi assinado.")) {
            _ = try await Self.engine(deposit).plan(Self.request(to: A.depositContract))
        }
    }

    @Test("Provedor de outra rede e descartado no caminho do envio; os outros dois bastam")
    func wrongChainProviderDropped() async throws {
        let transport = try F.transport()
        let base = try EVMFixtures.data("eth_chainId-base")
        transport.prepend { call in call.host == "b.test" && call.method == "eth_chainId" ? base : nil }
        let plan = try await Self.engine(transport, providers: testProviders("a", "b", "c")).plan(Self.request(asset: Self.usdcAsset, amount: 1_000_000))
        #expect(plan.review.recipient == A.binance14.checksummed)
        #expect(transport.calls.filter { $0.host == "b.test" }.map(\.method) == ["eth_chainId"])
        let simulations = transport.calls("eth_call").filter { ($0.firstObject?["data"] as? String)?.hasPrefix(F.transferSelector) == true }
        #expect(Set(simulations.map(\.host)) == ["a.test", "c.test"])
    }

    @Test("Enviar tudo do nativo: o maximo e recalculado com o estado do plano")
    func sendAllNative() async throws {
        let transport = try F.transport()
        let engine = Self.engine(transport)
        let spendable = try await engine.spendable(Self.request(sendAll: true))
        let plan = try await engine.plan(Self.request(amount: spendable.amount, sendAll: true))
        let transaction = try #require(plan.transactions.first as? EVMTransaction)
        let balance = BigUInt(hex: "5d168aceb03ac9e256a1")!
        // Tudo menos a taxa maxima: valor + gas x maxFee fecha o saldo.
        #expect(transaction.value + transaction.maxExecutionCost == balance)
        #expect(transaction.value == spendable.amount)
        #expect(spendable.feeNote == "A taxa máxima da rede já está descontada.")
    }

    @Test("Disponivel do token: o saldo do token, com a taxa em ETH conferida a parte")
    func tokenSpendable() async throws {
        let transport = try F.transport()
        let engine = Self.engine(transport)
        let spendable = try await engine.spendable(Self.request(asset: Self.usdcAsset, amount: 0, sendAll: true))
        #expect(spendable.amount == BigUInt(hex: "087a7a94")!)
        #expect(spendable.feeNote == "A taxa da rede é paga à parte, em ETH.")

        // Sem ETH para a taxa, nada sai, e a nota diz por que.
        transport.prepend { call in call.method == "eth_getBalance" ? EVMFixtures.result("\"0x0\"") : nil }
        let empty = try await engine.spendable(Self.request(asset: Self.usdcAsset, amount: 0, sendAll: true))
        #expect(empty.amount == 0)
        #expect(empty.feeNote == "A taxa da rede é paga em ETH, e o saldo de ETH não cobre a taxa agora.")
    }

    @Test("Aviso de endereco parecido com um para onde o dono ja enviou")
    func lookalikeWarning() async throws {
        let transport = try F.transport()
        // Mesmas pontas da Binance 14 (28c6c0...f21d60), meio diferente: o sosia.
        let lookalike = "0x28c6c0" + String(repeating: "7", count: 28) + "f21d60"
        let plan = try await Self.engine(transport).plan(Self.request(known: [lookalike]))
        #expect(plan.review.warnings.contains(.lookalikeAddress(known: lookalike)))
        #expect(plan.review.warnings.contains(.firstSendToAddress))
        // Para quem ja recebeu, sem aviso de primeiro envio.
        let again = try await Self.engine(transport).plan(Self.request(known: [A.binance14.checksummed.lowercased()]))
        #expect(!again.review.warnings.contains(.firstSendToAddress))
    }

    @Test("Pedidos recusados antes de qualquer leitura: tag, conta de outra chave, token fora da lista")
    func refusedRequests() async throws {
        let transport = try F.transport()
        let engine = Self.engine(transport)
        await #expect(throws: SendEngineError.message("A rede Ethereum não usa tag nem memo. Envie só com o endereço.")) {
            _ = try await engine.plan(Self.request(tag: "123"))
        }
        let other = DerivedAccount(chainID: "ethereum", path: A.path, address: A.binance14.checksummed,
                                   publicKey: A.binance8PublicKey, accountXPub: nil)
        await #expect(throws: SendEngineError.message("A conta desta rede não confere com a chave da carteira. Nada foi assinado.")) {
            _ = try await engine.plan(Self.request(account: other))
        }
        let fake = Asset(chainID: "ethereum", kind: .token(contract: "0x58bDC4310db1b19854Ca9066deEd7E3dF4F2Ec9B"), symbol: "USDC",
                         name: "USD Coin", decimals: 6, coingeckoID: nil, isStablecoin: true)
        await #expect(throws: SendEngineError.message("Este ativo não está na lista de tokens verificados da Ethereum.")) {
            _ = try await engine.plan(Self.request(asset: fake, amount: 1))
        }
        #expect(transport.calls.isEmpty)
    }

    @Test("Destinos bloqueados: contrato do token, router da troca e endereco zero")
    func blockedDestinations() async throws {
        let transport = try F.transport()
        let engine = Self.engine(transport)
        let blocked = "Este endereço é um contrato de troca ou de token, não uma carteira. Envio recusado."
        await #expect(throws: SendEngineError.message(blocked)) { _ = try await engine.destination(F.usdc.checksummed, chain: .ethereum) }
        let router = try #require(TradeAllowlist.router(for: .velora, on: .ethereum))
        await #expect(throws: SendEngineError.message(blocked)) { _ = try await engine.destination(router.address.checksummed, chain: .ethereum) }
        await #expect(throws: SendEngineError.message("Este endereço queima tudo o que recebe. Envio recusado.")) {
            _ = try await engine.destination(EVMAddress.zero.checksummed, chain: .ethereum)
        }
        // USDC para o proprio contrato do USDC prende o saldo para sempre; ETH para ele,
        // tambem recusado (contrato de token da lista).
        await #expect(throws: SendEngineError.message(
            "Este endereço é o contrato do próprio token. O que for enviado para ele fica preso para sempre."
        )) {
            _ = try await engine.plan(Self.request(asset: Self.usdcAsset, to: F.usdc, amount: 1))
        }
        await #expect(throws: SendEngineError.message(blocked)) {
            _ = try await engine.plan(Self.request(to: F.usdc, amount: 1))
        }
    }

    @Test("Destino: contrato marcado antes do valor, carteira comum sem nota")
    func destinationInfo() async throws {
        let transport = try F.transport()
        let engine = Self.engine(transport)
        let safe = try await engine.destination(A.safe.checksummed, chain: .ethereum)
        #expect(safe.isContract && safe.note != nil && !safe.requiresTag)
        let wallet = try await engine.destination(A.binance14.checksummed, chain: .ethereum)
        #expect(!wallet.isContract && wallet.note == nil)
        await #expect(throws: SendEngineError.message(
            "Uma letra deste endereço não confere. Ele pode ter sido copiado pela metade ou alterado. Copie de novo, inteiro."
        )) {
            _ = try await engine.destination("0x28C6c06298d514Db089934071355E5743bf21D60", chain: .ethereum)
        }
    }

    // MARK: Transmissao e acompanhamento

    @Test("Transmissao: o id devolvido e o keccak dos bytes, calculado aqui; lote de duas recusa")
    func broadcast() async throws {
        let transport = try F.transport()
        let engine = Self.engine(transport)
        let raw: [UInt8] = [0x02, 0xC1, 0x01]
        let signed = SignedTransaction(chainID: "ethereum", raw: raw, encoded: Hex.encode(raw, prefix: true),
                                       id: Hex.encode(Hash.keccak256(raw), prefix: true))
        let id = try await engine.broadcast([signed], chain: .ethereum)
        #expect(id == Hex.encode(Hash.keccak256(raw), prefix: true))
        #expect(Set(transport.calls("eth_sendRawTransaction").map(\.host)) == ["a.test", "b.test"])

        await #expect(throws: SendEngineError.message(EVMEngineMessages.engine(.batchMismatch, chain: .ethereum))) {
            _ = try await engine.broadcast([signed, signed], chain: .ethereum)
        }
        // Provedor que devolve outro hash nao conta como aceite.
        let lying = try F.transport()
        lying.prepend { call in
            call.method == "eth_sendRawTransaction" ? EVMFixtures.result("\"0x" + String(repeating: "ab", count: 32) + "\"") : nil
        }
        await #expect(throws: SendEngineError.self) { _ = try await Self.engine(lying).broadcast([signed], chain: .ethereum) }
    }

    @Test("Status: recibo igual em dois provedores e confirmado; revertido vira falha com taxa cobrada")
    func status() async throws {
        let hash = "0x16d93ffd559e10c60889377e1279bee7d2ec9de72051185807869fcad7510cfc"
        let status = await Self.engine(try F.transport()).status(hash, chain: .ethereum)
        guard case .confirmed(let detail) = status else { Issue.record("esperava confirmado: \(status)"); return }
        #expect(detail?.hasPrefix("Confirmado na rede") == true)

        let reverted = try F.transport()
        let receipt = String(decoding: try EVMFixtures.data("eth_getTransactionReceipt-binance8"), as: UTF8.self)
            .replacingOccurrences(of: "\"status\":\"0x1\"", with: "\"status\":\"0x0\"")
        reverted.prepend { call in call.method == "eth_getTransactionReceipt" ? Data(receipt.utf8) : nil }
        #expect(await Self.engine(reverted).status(hash, chain: .ethereum)
            == .failed(reason: "A transação entrou na rede, mas o contrato recusou. A taxa da rede foi cobrada."))
        // Hash malformado ou rede errada: pendente, nunca "confirmado".
        #expect(await Self.engine(try F.transport()).status("0x12", chain: .ethereum) == .pending)
        #expect(await Self.engine(try F.transport()).status(hash, chain: .base) == .pending)
    }
}
