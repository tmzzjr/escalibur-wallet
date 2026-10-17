import EscaliburChains
import EscaliburCore
import Foundation

// O estado publico que o plano de ponte precisa, nas duas redes (docs/seguranca.md 4.12),
// pelas mesmas regras da troca: cada RPC com o chainId conferido, cada leitura em duas
// fontes concordando, saldo e allowance pelo menor, simulacao em duas fontes distintas.

extension TradeStateReader {
    /// Uma palavra de 32 bytes de `eth_call`, igual em duas fontes.
    func agreedWord(chain: Chain, to: EVMAddress, data: [UInt8], what: String) async throws -> [UInt8] {
        let answers = try await collect(readProviders(chain), count: 2, what: what) { provider in
            try await self.rpc(provider, chain: chain, "eth_call",
                               [.object(["to": Self.address(to), "data": Self.data(data)]), .string("latest")], as: String.self).lowercased()
        }
        guard Set(answers.map(\.1)).count == 1, let text = answers.first?.1,
              let bytes = Hex.decode(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text), bytes.count == 32
        else { throw TradeStateError.sourcesDisagree(what) }
        return bytes
    }

    /// Tudo o que `BridgePlanner.planDeposit` precisa para esta cotacao.
    public func readBridge(for quote: ValidatedBridgeQuote, localNextNonce: UInt64? = nil) async throws -> BridgeChainState {
        try await readBridge(for: quote, localNextNonce: localNextNonce, stateOverrides: nil)
    }

    /// `stateOverrides` so existe para os testes ao vivo darem saldo a conta de teste
    /// dentro da simulacao; o app nunca passa.
    func readBridge(for quote: ValidatedBridgeQuote, localNextNonce: UInt64?, stateOverrides: JSONValue?) async throws -> BridgeChainState {
        // Rota, chamada e pedido dizendo a mesma coisa, antes de ler qualquer estado.
        guard quote.callMatchesRoute else { throw BridgeRefusal.unsupportedRoute }
        let intent = quote.intent
        let from = intent.from.chain
        let to = intent.to.chain
        let slot = TradeRouterPin.eip1967ImplementationSlot

        async let network = network(chain: from, owner: intent.owner, localNextNonce: localNextNonce)
        // Codigo na conta do dono no destino so existe na EVM; na Tron quem recebe e a conta
        // Tron da carteira, conferida pelo motor (`TronReader.ownerControl`).
        let destinationIsEVM = to.family == .evm
        async let ownerCode = destinationIsEVM ? hasCode(chain: to, intent.owner) : false
        var implementations = [EVMAddress]()
        for pin in BridgePlanner.pins(for: quote) {
            guard let found = try await self.pin(chain: pin.chain, router: pin.proxy, query: .storage(slot: slot)) else {
                throw TradeStateError.badResponse("pin")
            }
            implementations.append(found)
        }

        var domain: UInt32?
        var localToken: EVMAddress?
        var blacklisted: Bool?
        if case .cctp = quote.call {
            let domainWord = try await agreedWord(chain: to, to: BridgeAllowlist.messageTransmitter,
                                                  data: BridgePlanner.localDomainFunction.selector, what: "dominio")
            domain = BigUInt(bigEndian: domainWord).uint64.flatMap { UInt32(exactly: $0) }
            let tokenWord = try await agreedWord(chain: to, to: BridgeAllowlist.tokenMinter,
                                                 data: BridgePlanner.localTokenQuery(intent), what: "token local")
            localToken = tokenWord.prefix(12).allSatisfy { $0 == 0 } ? EVMAddress(bytes: Array(tokenWord.suffix(20))) : nil
            let listWord = try await agreedWord(chain: to, to: intent.to.usdc, data: BridgePlanner.blacklistQuery(intent.owner), what: "bloqueio")
            blacklisted = BigUInt(bigEndian: listWord).isZero ? false : true
        }

        var tokenState: EVMTokenState?
        if let token = intent.sell.contract, let spender = quote.spender {
            tokenState = try await self.token(chain: from, token: token, owner: intent.owner, spender: spender)
        }
        let request = BridgePlanner.simulationRequest(for: quote, currentAllowance: tokenState?.allowance)
        async let simulations = simulate(chain: from, calls: request.calls, stateOverrides: stateOverrides)
        let approveData = ERC20.approve(spender: quote.spender ?? .zero, amount: intent.amount)
        async let approveL1 = l1DataFee(chain: from, calldataSize: approveData.count)
        async let depositL1 = l1DataFee(chain: from, calldataSize: quote.data.count)
        var approveL1Gas: UInt64 = 0
        var depositL1Gas: UInt64 = 0
        if from.evmChainID == 42161 {
            if let token = intent.sell.contract { approveL1Gas = try await arbitrumL1Gas(chain: from, to: token, data: approveData) }
            depositL1Gas = try await arbitrumL1Gas(chain: from, to: quote.to, data: quote.data)
        }
        // Legacy Mesh: o UsdtOFT lido de novo agora, com o minimo assinado.
        var mesh: MeshQuote?
        if case .mesh(let transfer) = quote.call {
            mesh = try await readMesh(intent: intent, minimum: transfer.minimumReceived)
        }
        return BridgeChainState(
            network: try await network, token: tokenState, implementations: implementations, destinationDomain: domain,
            destinationLocalToken: localToken, destinationBlacklisted: blacklisted, ownerHasCodeAtDestination: try await ownerCode,
            simulations: try await simulations, approveL1DataFee: try await approveL1, depositL1DataFee: try await depositL1,
            approveL1Gas: approveL1Gas, depositL1Gas: depositL1Gas, mesh: mesh
        )
    }
}
