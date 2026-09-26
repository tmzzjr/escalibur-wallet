import EscaliburChains
import EscaliburCore
import Foundation

/// A chamada que vai ser assinada, do jeito que o leitor precisa dela: para estimar o
/// gas da chamada exata e para saber de quem e o `eth_getCode` que o plano confere.
public enum EVMReadIntent: Sendable, Equatable {
    /// Envio nativo: `eth_getCode` do destino.
    case native(to: EVMAddress, amount: BigUInt)
    /// `transfer` de ERC-20: `eth_getCode` do destinatario do token (nao do contrato).
    case token(EVMToken, to: EVMAddress, amount: BigUInt)
    /// `approve`: `eth_getCode` do spender. No USDT da Ethereum com allowance atual
    /// diferente de zero, a estimativa sai de allowance zero por state override, porque
    /// estimar direto reverte (o plano manda `approve(0)` antes).
    case approve(EVMToken, spender: EVMAddress, amount: EVMApprovalAmount)
    /// `approve(spender, 0)`.
    case revoke(EVMToken, spender: EVMAddress)
}

/// Por onde a transacao assinada sai.
public enum EVMBroadcastRoute: Sendable, Equatable {
    /// Os RPCs publicos da rede, dois deles, com os mesmos bytes.
    case publicMempool
    /// So Ethereum: Flashbots Protect e MEV Blocker, direto aos construtores de bloco.
    /// Para troca, onde o mempool publico expoe a ordem a sanduiche.
    case mevProtected
}

/// Leitura de estado, transmissao e historico das redes EVM.
///
/// Cada provedor tem o `eth_chainId` conferido contra `Chain.evmChainID` (compilado) na
/// primeira chamada da sessao; o que divergir fica fora ate o app reiniciar. Um RPC de
/// outra rede daria nonce, saldo e taxa de outra rede, e a transacao assinada com o
/// chainId certo seria recusada na melhor hipotese.
public actor EVMReader {
    public static let shared = EVMReader()

    let transport: ReaderTransport
    let rpcProviders: [String: [Provider]]
    let historyProviders: [String: [Provider]]
    let privateRelays: [Provider]

    private var pools: [String: ProviderPool] = [:]
    private var chainIDChecks: [String: Task<Bool, Error>] = [:]
    private var wrongNetwork: Set<String> = []

    public init(
        transport: ReaderTransport = HTTPClient.shared,
        rpc: [String: [ProviderPool.Provider]] = Endpoints.evm.merging(Endpoints.evmContingency) { $0 + $1 },
        history: [String: [ProviderPool.Provider]] = Endpoints.evmHistory,
        privateRelays: [ProviderPool.Provider] = Endpoints.ethereumPrivateRelays
    ) {
        self.transport = transport
        self.rpcProviders = rpc
        self.historyProviders = history
        self.privateRelays = privateRelays
    }

    // MARK: Tetos e constantes

    /// Teto de sanidade da taxa L1 (OP e Base): 0,01 ETH por transacao. Hoje sao
    /// milionesimos de ETH; acima disso o oraculo esta errado ou o provedor mente, e a
    /// conferencia de saldo com esse numero nao significaria nada.
    static let maxL1DataFee = BigUInt(10_000_000_000_000_000)

    /// GasPriceOracle das redes OP Stack (predeploy, mesmo endereco em OP e Base).
    /// Fonte: specs.optimism.io, "Predeploys", GasPriceOracle
    /// `0x420000000000000000000000000000000000000F`; docs/blockchain.md §2.2.
    static let gasPriceOracle = EVMAddress(bytesUnchecked: [UInt8](hex: "420000000000000000000000000000000000000f")!)
    static let l1FeeUpperBound = try! ABIFunction("getL1FeeUpperBound(uint256)")  // f1c7a58b

    /// Slot do mapping `allowed` dos tokens que exigem `approve(0)` antes (state override
    /// da estimativa). USDT da Ethereum (TetherToken): `allowed` e o slot 5 (Ownable e
    /// Pausable no 0, _totalSupply no 1, balances, basisPointsRate e maximumFee de 2 a 4),
    /// conferido ao vivo em 25/09/2026 com `eth_getStorageAt` contra `allowance()` de
    /// aprovacoes reais (ver EVMReaderLiveTests).
    static let allowanceSlots: [(chainID: UInt64, contract: String, slot: UInt64)] = [
        (1, "dac17f958d2ee523a2206206994597c13d831ec7", 5),
    ]

    /// Quantos blocos atras as leituras que precisam de dois provedores concordando sao
    /// fixadas (saldo, codigo, `balanceOf`, `allowance`). Em `latest` dois provedores um
    /// bloco defasados discordam de saldo de conta movimentada; no mesmo bloco, nao. Uns
    /// 10 segundos em cada rede.
    static func pinLag(_ chain: Chain) -> UInt64 {
        switch chain.evmChainID {
        case 1: return 1
        case 42161: return 40
        case 56: return 12
        default: return 5
        }
    }

    // MARK: Estado para o plano

    /// Tudo que `EVMPlanner` precisa para montar o plano de `intent`.
    ///
    /// - nonce `pending` de dois provedores (o plano exige que concordem, ou que a fila
    ///   local do app explique a diferenca); `localNextNonce` vem dessa fila.
    /// - baseFee do proximo bloco e gorjetas p25/p50/p75 de `eth_feeHistory(10)`, a
    ///   maior baseFee entre dois provedores.
    /// - `eth_estimateGas` da chamada exata; `eth_getCode` do destino certo e saldo
    ///   nativo, com dois provedores concordando no mesmo bloco.
    /// - OP e Base: `getL1FeeUpperBound` no GasPriceOracle, o maior de dois provedores.
    public func networkState(
        chain: Chain, account: EVMAddress, intent: EVMReadIntent, localNextNonce: UInt64? = nil
    ) async throws -> EVMNetworkState {
        guard let profile = EVMFeeProfile.for(chain) else { throw ReaderError.invalidInput("rede nao EVM") }
        try Self.check(intent, chain: chain)
        let (pool, providers) = try await eligible(chain)
        let call = try await plannedCall(intent, chain: chain, account: account, pool: pool, providers: providers)
        let pin = try await pinnedBlock(chain, pool: pool, providers: providers)

        async let nonces = pendingNonces(chain, account: account, pool: pool, providers: providers)
        async let fees = feeReadings(chain, pool: pool, providers: providers)
        async let gas = estimateGas(chain, from: account, call: call, pool: pool, providers: providers)
        async let code = hasCode(chain, call.codeTarget, block: pin, pool: pool, providers: providers)
        async let balance = nativeBalance(chain, account, block: pin, pool: pool, providers: providers)
        let l1: BigUInt? = profile.chargesL1DataFee
            ? try await l1DataFee(chain, call: call, pool: pool, providers: providers)
            : nil

        let (baseFee, tips) = try await fees
        return EVMNetworkState(
            chain: chain, pendingNonces: try await nonces, localNextNonce: localNextNonce,
            baseFeePerGas: baseFee, priorityFees: tips, gasEstimate: try await gas, l1DataFee: l1,
            nativeBalance: try await balance, destinationHasCode: try await code
        )
    }

    /// Estado do token para os planos ERC-20: codigo do contrato, `balanceOf(dono)` e,
    /// com `spender`, `allowance(dono, spender)`. Tudo com dois provedores concordando.
    public func tokenState(token: EVMToken, owner: EVMAddress, spender: EVMAddress? = nil) async throws -> EVMTokenState {
        guard token.chain.family == .evm else { throw ReaderError.invalidInput("rede nao EVM") }
        let chain = token.chain
        let (pool, providers) = try await eligible(chain)
        let pin = try await pinnedBlock(chain, pool: pool, providers: providers)
        async let code = hasCode(chain, token.contract, block: pin, pool: pool, providers: providers)
        async let balance = callUInt256(chain, token.contract, ERC20.balanceOf(owner: owner), block: pin, field: "balanceOf", pool: pool, providers: providers)
        var allowance: BigUInt?
        if let spender {
            allowance = try await callUInt256(
                chain, token.contract, ERC20.allowance(owner: owner, spender: spender), block: pin, field: "allowance",
                pool: pool, providers: providers
            )
        }
        return EVMTokenState(contractHasCode: try await code, balance: try await balance, allowance: allowance)
    }

    /// `eth_getCode` de um endereco, com dois provedores concordando no bloco fixado. O
    /// motor de envio diz ao dono, antes do valor, que o destino e contrato (ou conta com
    /// delegacao EIP-7702), e nao uma carteira comum.
    public func hasCode(chain: Chain, address: EVMAddress) async throws -> Bool {
        let (pool, providers) = try await eligible(chain)
        let pin = try await pinnedBlock(chain, pool: pool, providers: providers)
        return try await hasCode(chain, address, block: pin, pool: pool, providers: providers)
    }

    /// O que um provedor respondeu ao `eth_call` da transacao exata.
    enum CallOutcome: Sendable, Equatable {
        case returned([UInt8])
        case reverted
    }

    /// Executa a transacao exata que vai ser assinada (`from`, `to`, `value`, `data`) com
    /// `eth_call`, no bloco fixado, em dois provedores diferentes. Devolve os dados de
    /// retorno so se os dois executaram sem reverter e devolveram o mesmo.
    ///
    /// Revert conta como resposta, nao como falha do provedor: se um dos dois reverte, a
    /// transacao falharia com o estado de agora, e o erro e `executionReverted`. Retornos
    /// diferentes sao `providersDisagree`. Nenhum dos dois casos cai para uma resposta so.
    public func simulateCall(chain: Chain, from: EVMAddress, to: EVMAddress, value: BigUInt, data: [UInt8]) async throws -> [UInt8] {
        let (pool, providers) = try await eligible(chain)
        let pin = try await pinnedBlock(chain, pool: pool, providers: providers)
        var object: [String: StrictJSON] = [
            "from": .string(from.checksummed), "to": .string(to.checksummed), "data": .string(Hex.encode(data, prefix: true)),
        ]
        if !value.isZero { object["value"] = .string(value.hexString) }
        let params: [StrictJSON] = [.object(object), .string(pin)]
        let transport = self.transport
        let answers = try await Quorum.collect(providers, pool: pool, count: 2) { provider -> CallOutcome in
            try await self.verify(provider, chain: chain)
            do {
                return .returned(try await Self.call(transport, provider.baseURL, "eth_call", params).hexData("eth_call"))
            } catch ReaderError.executionReverted {
                return .reverted
            }
        }
        let outcomes = answers.map(\.value)
        guard !outcomes.contains(.reverted) else { throw ReaderError.executionReverted }
        guard case .returned(let returned) = outcomes[0], outcomes.allSatisfy({ $0 == outcomes[0] }) else {
            throw ReaderError.providersDisagree(field: "eth_call")
        }
        return returned
    }

    // MARK: Transmissao e acompanhamento

    /// Transmite os mesmos bytes assinados a dois provedores. Aceita se pelo menos um
    /// aceitou; o id e sempre o calculado localmente.
    public func broadcast(_ signed: SignedTransaction, chain: Chain, route: EVMBroadcastRoute = .publicMempool) async throws -> BroadcastReceipt {
        guard chain.family == .evm, signed.chainID == chain.id else { throw ReaderError.broadcastMismatch }
        // O que sai e exatamente `raw`, e o id e o keccak dele: um `encoded` que nao fosse
        // os mesmos bytes transmitiria outra coisa.
        guard Hex.decode(signed.encoded) == signed.raw, signed.encoded.hasPrefix("0x"),
              Hex.encode(Hash.keccak256(signed.raw), prefix: true) == signed.id.lowercased()
        else { throw ReaderError.broadcastMismatch }

        let targets: [Provider]
        let pool: ProviderPool
        switch route {
        case .publicMempool:
            let eligible = try await eligible(chain)
            pool = eligible.pool
            targets = Array(eligible.providers.prefix(2))
        case .mevProtected:
            guard chain.evmChainID == 1 else { throw ReaderError.invalidInput("protecao de MEV so na Ethereum") }
            pool = self.pool("ethereum-relays", privateRelays)
            targets = await pool.available()
        }
        let transport = self.transport
        let id = signed.id.lowercased()
        var tally = BroadcastTally()
        await withTaskGroup(of: (Provider, Result<String, Error>).self) { group in
            for provider in targets {
                group.addTask {
                    do {
                        try await self.verify(provider, chain: chain)
                        let result = try await Self.call(transport, provider.baseURL, "eth_sendRawTransaction", [.string(signed.encoded)])
                        guard try result.string("result").lowercased() == id else { throw ReaderError.broadcastMismatch }
                        return (provider, .success(id))
                    } catch {
                        return (provider, .failure(error))
                    }
                }
            }
            for await (provider, result) in group {
                tally.add(result, provider: provider)
                if case .failure(let error) = result { await Quorum.record(error, provider, pool) }
            }
        }
        return try tally.receipt(chainID: chain.id, id: signed.id)
    }

    /// `eth_getTransactionReceipt` em dois provedores. Confirmado (ou falho) so quando
    /// os dois tem o recibo no mesmo bloco; com um so, pendente.
    public func status(of hash: String, chain: Chain) async throws -> TransactionStatus {
        guard let bytes = Hex.decode(hash), bytes.count == 32, hash.hasPrefix("0x") else { throw ReaderError.invalidInput("hash") }
        let (pool, providers) = try await eligible(chain)
        let transport = self.transport
        // Nem todo RPC guarda indice de transacoes (a Cloudflare devolve `null` para
        // recibos antigos): com um recibo e um `null`, pergunta ao proximo.
        let (answers, lastError) = await Quorum.gather(providers, pool: pool, count: providers.count, firstWave: 2, until: { values in
            let found: [Receipt] = values.compactMap { $0 }
            return Self.agreeingReceipt(found) != nil || (values.count >= 2 && found.isEmpty)
        }) { (provider: Provider) async throws -> Receipt? in
            try await self.verify(provider, chain: chain)
            return try Self.parseReceipt(try await Self.call(transport, provider.baseURL, "eth_getTransactionReceipt", [.string(hash)]))
        }
        guard answers.count >= 2 else {
            if answers.isEmpty, let lastError { throw lastError }
            throw ReaderError.notEnoughProviders(needed: 2, got: answers.count)
        }
        let found: [Receipt] = answers.compactMap { $0.value }
        if let receipt = Self.agreeingReceipt(found) {
            guard receipt.success else { return .failed(reason: "reverted") }
            let head = try await Quorum.first(providers, pool: pool) { provider in
                try await Self.call(transport, provider.baseURL, "eth_blockNumber", []).quantity("eth_blockNumber")
            }
            let confirmations = head >= BigUInt(receipt.block) ? (head - BigUInt(receipt.block)).uint64.map { $0 + 1 } : 0
            return .confirmed(block: receipt.block, confirmations: confirmations)
        }
        if !found.isEmpty { return .pending }
        let known = try await Quorum.first(providers, pool: pool) { provider in
            try await Self.call(transport, provider.baseURL, "eth_getTransactionByHash", [.string(hash)])
        }
        return known.isNull ? .notFound : .pending
    }

    // MARK: Historico

    /// Os ultimos movimentos da conta na rede, pelo indexador publico (Blockscout; na
    /// Avalanche, Routescan). O endereco vai no caminho do GET: esses indexadores nao
    /// tem consulta por POST (docs/seguranca.md §5.3; o relay proprio resolve).
    public func history(chain: Chain, address: EVMAddress) async throws -> ActivityPage {
        guard chain.family == .evm else { throw ReaderError.invalidInput("rede nao EVM") }
        guard let providers = historyProviders[chain.id], !providers.isEmpty else {
            throw ReaderError.unsupported("historico sem indexador publico nesta rede")
        }
        let pool = self.pool("history-" + chain.id, providers)
        let transport = self.transport
        let available = await pool.available()
        return try await Quorum.first(available, pool: pool) { provider in
            // As transacoes sao obrigatorias. As transferencias de token, se o indexador nao
            // entregar (o Blockscout da Polygon passa de 30 s em conta muito movimentada),
            // a pagina sai marcada como parcial: os envios do dono continuam aparecendo
            // pelas transacoes.
            if provider.name == "routescan" {
                let base = provider.baseURL
                let common = [("module", "account"), ("address", address.checksummed), ("page", "1"), ("offset", "50"), ("sort", "desc")]
                let txs = try StrictJSON.parse(try await transport.send(.get(base.adding(query: common + [("action", "txlist")]), timeout: 30)))
                let tokens = try? StrictJSON.parse(try await transport.send(.get(base.adding(query: common + [("action", "tokentx")]), timeout: 30)))
                return try Self.parseEtherscanHistory(
                    chain: chain, owner: address, transactions: txs,
                    tokenTransfers: tokens ?? .object(["status": .string("1"), "result": .array([])]), complete: tokens != nil
                )
            }
            let path = "addresses/" + address.checksummed
            let txs = try StrictJSON.parse(try await transport.send(.get(provider.baseURL.adding(path: path + "/transactions"), timeout: 30)))
            let tokens = try? StrictJSON.parse(try await transport.send(
                .get(provider.baseURL.adding(path: path + "/token-transfers").adding(query: [("type", "ERC-20")]), timeout: 30)
            ))
            return try Self.parseBlockscoutHistory(
                chain: chain, owner: address, transactions: txs, tokenTransfers: tokens ?? .object(["items": .array([])]), complete: tokens != nil
            )
        }
    }

    // MARK: Provedores

    private func pool(_ key: String, _ providers: [Provider]) -> ProviderPool {
        if let existing = pools[key] { return existing }
        let created = ProviderPool(providers)
        pools[key] = created
        return created
    }

    /// Os RPCs da rede que nao divergiram no chainId nesta sessao, na ordem de preferencia.
    private func eligible(_ chain: Chain) async throws -> (pool: ProviderPool, providers: [Provider]) {
        guard chain.family == .evm, chain.evmChainID != nil, let list = rpcProviders[chain.id], !list.isEmpty else {
            throw ReaderError.invalidInput("rede sem RPC")
        }
        let pool = self.pool(chain.id, list)
        let providers = await pool.available().filter { !wrongNetwork.contains(chain.id + "|" + $0.name) }
        guard !providers.isEmpty else { throw ReaderError.wrongNetwork }
        return (pool, providers)
    }

    /// `eth_chainId` do provedor contra o compilado, uma vez por sessao. Falha de
    /// transporte nao conta como conferido: tenta de novo na proxima.
    func verify(_ provider: Provider, chain: Chain) async throws {
        let key = chain.id + "|" + provider.name
        guard !wrongNetwork.contains(key) else { throw ReaderError.wrongNetwork }
        let task: Task<Bool, Error>
        if let existing = chainIDChecks[key] {
            task = existing
        } else {
            let transport = self.transport
            let expected = BigUInt(chain.evmChainID ?? 0)
            task = Task { try await Self.call(transport, provider.baseURL, "eth_chainId", []).quantity("eth_chainId") == expected }
            chainIDChecks[key] = task
        }
        let matches: Bool
        do {
            matches = try await task.value
        } catch {
            chainIDChecks[key] = nil
            throw error
        }
        guard matches else {
            wrongNetwork.insert(key)
            throw ReaderError.wrongNetwork
        }
    }

    // MARK: Leituras

    struct PlannedCall: Sendable {
        let to: EVMAddress
        let value: BigUInt
        let data: [UInt8]
        let codeTarget: EVMAddress
        let stateOverride: StrictJSON?
    }

    static func check(_ intent: EVMReadIntent, chain: Chain) throws {
        switch intent {
        case .native: return
        case .token(let token, _, _), .approve(let token, _, _), .revoke(let token, _):
            guard token.chain.id == chain.id else { throw ReaderError.invalidInput("token de outra rede") }
        }
    }

    private func plannedCall(
        _ intent: EVMReadIntent, chain: Chain, account: EVMAddress, pool: ProviderPool, providers: [Provider]
    ) async throws -> PlannedCall {
        switch intent {
        case .native(let to, let amount):
            return PlannedCall(to: to, value: amount, data: [], codeTarget: to, stateOverride: nil)
        case .token(let token, let to, let amount):
            return PlannedCall(to: token.contract, value: 0, data: ERC20.transfer(to: to, amount: amount), codeTarget: to, stateOverride: nil)
        case .revoke(let token, let spender):
            return PlannedCall(to: token.contract, value: 0, data: ERC20.approve(spender: spender, amount: 0), codeTarget: spender, stateOverride: nil)
        case .approve(let token, let spender, let amount):
            let value: BigUInt
            switch amount {
            case .exact(let exact): value = exact
            case .unlimited: value = .uint256Max
            }
            var override: StrictJSON?
            if EVMPlanner.requiresZeroFirstApproval(token) {
                let current = try await callUInt256(
                    chain, token.contract, ERC20.allowance(owner: account, spender: spender), block: "latest", field: "allowance",
                    pool: pool, providers: providers
                )
                if !current.isZero {
                    override = try Self.zeroAllowanceOverride(token: token, owner: account, spender: spender)
                }
            }
            return PlannedCall(to: token.contract, value: 0, data: ERC20.approve(spender: spender, amount: value), codeTarget: spender, stateOverride: override)
        }
    }

    /// State override que zera `allowed[dono][spender]` so para a estimativa:
    /// `keccak256(spender . keccak256(dono . slot))`.
    static func zeroAllowanceOverride(token: EVMToken, owner: EVMAddress, spender: EVMAddress) throws -> StrictJSON {
        let contract = Hex.encode(token.contract.bytes)
        guard let entry = allowanceSlots.first(where: { $0.chainID == token.chain.evmChainID && $0.contract == contract }) else {
            throw ReaderError.unsupported("token sem slot de allowance conhecido")
        }
        let slotWord = BigUInt(entry.slot).bigEndianBytes(padTo: 32) ?? []
        let inner = Hash.keccak256([UInt8](repeating: 0, count: 12) + owner.bytes + slotWord)
        let key = Hash.keccak256([UInt8](repeating: 0, count: 12) + spender.bytes + inner)
        return .object([
            token.contract.checksummed: .object([
                "stateDiff": .object([Hex.encode(key, prefix: true): .string(Hex.encode([UInt8](repeating: 0, count: 32), prefix: true))]),
            ]),
        ])
    }

    /// Um bloco recente e fixo para as leituras que dois provedores precisam confirmar.
    private func pinnedBlock(_ chain: Chain, pool: ProviderPool, providers: [Provider]) async throws -> String {
        let transport = self.transport
        let head = try await Quorum.first(providers, pool: pool) { provider in
            try await self.verify(provider, chain: chain)
            return try await Self.call(transport, provider.baseURL, "eth_blockNumber", []).quantity("eth_blockNumber")
        }
        let lag = BigUInt(Self.pinLag(chain))
        guard head > lag else { throw ReaderError.implausibleValue(field: "eth_blockNumber") }
        return (head - lag).hexString
    }

    private func pendingNonces(_ chain: Chain, account: EVMAddress, pool: ProviderPool, providers: [Provider]) async throws -> [UInt64] {
        let transport = self.transport
        return try await Quorum.collect(providers, pool: pool, count: 2) { provider in
            try await self.verify(provider, chain: chain)
            let result = try await Self.call(transport, provider.baseURL, "eth_getTransactionCount", [.string(account.checksummed), .string("pending")])
            guard let nonce = try result.quantity("eth_getTransactionCount").uint64 else {
                throw ReaderError.implausibleValue(field: "eth_getTransactionCount")
            }
            return nonce
        }.map(\.value)
    }

    private func feeReadings(_ chain: Chain, pool: ProviderPool, providers: [Provider]) async throws -> (BigUInt, EVMPriorityFees) {
        let transport = self.transport
        let (answers, lastError) = await Quorum.gather(providers, pool: pool, count: 2) { provider in
            try await self.verify(provider, chain: chain)
            let result = try await Self.call(
                transport, provider.baseURL, "eth_feeHistory",
                [.string("0xa"), .string("latest"), .array([.int(25), .int(50), .int(75)])]
            )
            return try Self.parseFeeHistory(result)
        }
        guard !answers.isEmpty else { throw lastError ?? ReaderError.notEnoughProviders(needed: 1, got: 0) }
        let values = answers.map(\.value)
        let baseFee = values.map(\.baseFee).max() ?? 0
        let tips = EVMPriorityFees(
            slow: values.map(\.tips.slow).max() ?? 0,
            normal: values.map(\.tips.normal).max() ?? 0,
            fast: values.map(\.tips.fast).max() ?? 0
        )
        return (baseFee, tips)
    }

    private func estimateGas(_ chain: Chain, from: EVMAddress, call: PlannedCall, pool: ProviderPool, providers: [Provider]) async throws -> UInt64 {
        let transport = self.transport
        var object: [String: StrictJSON] = [
            "from": .string(from.checksummed), "to": .string(call.to.checksummed),
            "data": .string(Hex.encode(call.data, prefix: true)),
        ]
        if !call.value.isZero { object["value"] = .string(call.value.hexString) }
        var params: [StrictJSON] = [.object(object)]
        if let override = call.stateOverride { params += [.string("latest"), override] }
        let frozen = params
        return try await Quorum.first(providers, pool: pool) { provider in
            try await self.verify(provider, chain: chain)
            let result = try await Self.call(transport, provider.baseURL, "eth_estimateGas", frozen)
            guard let gas = try result.quantity("eth_estimateGas").uint64, gas >= 21_000, gas <= EVMTransaction.maxGasLimit else {
                throw ReaderError.implausibleValue(field: "eth_estimateGas")
            }
            return gas
        }
    }

    private func hasCode(_ chain: Chain, _ address: EVMAddress, block: String, pool: ProviderPool, providers: [Provider]) async throws -> Bool {
        let transport = self.transport
        return try await Quorum.agree(providers, pool: pool, field: "eth_getCode") { provider in
            try await self.verify(provider, chain: chain)
            let code = try await Self.call(transport, provider.baseURL, "eth_getCode", [.string(address.checksummed), .string(block)])
                .hexData("eth_getCode")
            return !code.isEmpty
        }
    }

    private func nativeBalance(_ chain: Chain, _ address: EVMAddress, block: String, pool: ProviderPool, providers: [Provider]) async throws -> BigUInt {
        let transport = self.transport
        return try await Quorum.agree(providers, pool: pool, field: "eth_getBalance") { provider in
            try await self.verify(provider, chain: chain)
            return try await Self.call(transport, provider.baseURL, "eth_getBalance", [.string(address.checksummed), .string(block)])
                .quantity("eth_getBalance")
        }
    }

    private func callUInt256(
        _ chain: Chain, _ contract: EVMAddress, _ data: [UInt8], block: String, field: String, pool: ProviderPool, providers: [Provider]
    ) async throws -> BigUInt {
        let transport = self.transport
        let request: StrictJSON = .object(["to": .string(contract.checksummed), "data": .string(Hex.encode(data, prefix: true))])
        return try await Quorum.agree(providers, pool: pool, field: field) { provider in
            try await self.verify(provider, chain: chain)
            let returned = try await Self.call(transport, provider.baseURL, "eth_call", [request, .string(block)]).hexData(field)
            do { return try ERC20.decodeUInt256(returned) } catch { throw ReaderError.malformed(field: field) }
        }
    }

    /// Taxa L1 das redes OP Stack: `getL1FeeUpperBound(tamanho)`, com o tamanho maximo
    /// que a transacao sem assinatura pode ter (o oraculo soma a assinatura). O maior de
    /// dois provedores, com teto de sanidade.
    private func l1DataFee(_ chain: Chain, call: PlannedCall, pool: ProviderPool, providers: [Provider]) async throws -> BigUInt {
        let size = Self.unsignedSizeUpperBound(dataCount: call.data.count)
        let data = try Self.l1FeeUpperBound.encodeCall([.uint(BigUInt(size))])
        let request: StrictJSON = .object(["to": .string(Self.gasPriceOracle.checksummed), "data": .string(Hex.encode(data, prefix: true))])
        let transport = self.transport
        let (answers, lastError) = await Quorum.gather(providers, pool: pool, count: 2) { provider in
            try await self.verify(provider, chain: chain)
            let returned = try await Self.call(transport, provider.baseURL, "eth_call", [request, .string("latest")]).hexData("getL1FeeUpperBound")
            do { return try ERC20.decodeUInt256(returned) } catch { throw ReaderError.malformed(field: "getL1FeeUpperBound") }
        }
        guard let fee = answers.map(\.value).max() else { throw lastError ?? ReaderError.notEnoughProviders(needed: 1, got: 0) }
        guard !fee.isZero, fee <= Self.maxL1DataFee else { throw ReaderError.implausibleValue(field: "getL1FeeUpperBound") }
        return fee
    }

    /// Tamanho maximo do RLP de um tipo 2 sem assinatura: prefixo de tipo e de lista,
    /// chainId, nonce, gorjeta, maxFee, gas, to, value, data e access list vazia, cada
    /// inteiro no maior tamanho que o RLP permite.
    static func unsignedSizeUpperBound(dataCount: Int) -> Int {
        let dataPrefix = dataCount < 56 ? 1 : (dataCount < 256 ? 2 : 3)
        return 1 + 3 + 9 + 9 + 33 + 33 + 9 + 21 + 33 + dataPrefix + dataCount + 1
    }

    // MARK: JSON-RPC

    /// Uma chamada JSON-RPC. Erro do no vira `ReaderError` sem a mensagem (que pode trazer
    /// endereco e saldo); na transmissao, a mensagem so e classificada.
    static func call(_ transport: ReaderTransport, _ url: URL, _ method: String, _ params: [StrictJSON]) async throws -> StrictJSON {
        let body: StrictJSON = .object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string(method), "params": .array(params),
        ])
        let json = try StrictJSON.parse(try await transport.send(.post(url, body)))
        if let error = json.optionalField("error") {
            let code = (try? error.field("code", "error").int64("error.code")).map(String.init) ?? "rpc"
            let message = (try? error.field("message", "error").string("error.message")) ?? ""
            // Cota esgotada ou limite de taxa do plano gratuito: e o provedor que esta
            // indisponivel, nao a pergunta que nao tem resposta. Conta como falha de
            // transporte, e o circuit breaker o tira por um minuto.
            if Self.isRateLimit(code: code, message: message) { throw HTTPClient.Failure.status(429) }
            if method == "eth_sendRawTransaction" {
                throw ReaderError.broadcastRejected(BroadcastRejection.evm(message: message), code: ReaderError.sanitized(code))
            }
            if code == "3" || message.lowercased().contains("revert") { throw ReaderError.executionReverted }
            throw ReaderError.providerError(code: ReaderError.sanitized(code))
        }
        guard let result = json.objectValue?["result"] else { throw ReaderError.malformed(field: method + ".result") }
        return result
    }

    /// -32005 e "limit exceeded" na EIP-1474; os agregadores gratuitos usam outros
    /// codigos com a mesma ideia no texto ("usage limit", "free plan", "rate limit").
    static func isRateLimit(code: String, message: String) -> Bool {
        if code == "-32005" { return true }
        let text = message.lowercased()
        return ["rate limit", "usage limit", "request limit", "too many requests", "free plan", "quota", "upgrade to paid"]
            .contains { text.contains($0) }
    }

    // MARK: Parse

    /// `eth_feeHistory`: a baseFee do proximo bloco (o ultimo item de `baseFeePerGas`,
    /// que a especificacao diz ser o bloco seguinte ao mais novo) e, por percentil, a
    /// mediana das gorjetas dos 10 blocos.
    static func parseFeeHistory(_ result: StrictJSON) throws -> (baseFee: BigUInt, tips: EVMPriorityFees) {
        let baseFees = try result.field("baseFeePerGas", "eth_feeHistory").array("eth_feeHistory.baseFeePerGas")
        guard let next = baseFees.last else { throw ReaderError.malformed(field: "eth_feeHistory.baseFeePerGas") }
        let baseFee = try next.quantity("eth_feeHistory.baseFeePerGas")
        let rewards = try result.field("reward", "eth_feeHistory").array("eth_feeHistory.reward")
        var columns: [[BigUInt]] = [[], [], []]
        for block in rewards {
            let row = try block.array("eth_feeHistory.reward")
            guard row.count == 3 else { throw ReaderError.malformed(field: "eth_feeHistory.reward") }
            for index in 0..<3 { columns[index].append(try row[index].quantity("eth_feeHistory.reward")) }
        }
        func median(_ values: [BigUInt]) -> BigUInt {
            guard !values.isEmpty else { return 0 }
            return values.sorted()[(values.count - 1) / 2]
        }
        return (baseFee, EVMPriorityFees(slow: median(columns[0]), normal: median(columns[1]), fast: median(columns[2])))
    }

    struct Receipt: Sendable, Equatable {
        let block: UInt64
        let blockHash: String
        let success: Bool
    }

    /// Dois recibos iguais (mesmo bloco, mesmo hash de bloco, mesmo status).
    static func agreeingReceipt(_ receipts: [Receipt]) -> Receipt? {
        for (index, receipt) in receipts.enumerated() where receipts[(index + 1)...].contains(receipt) {
            return receipt
        }
        return nil
    }

    /// Recibo ou `nil` (ainda sem bloco).
    static func parseReceipt(_ result: StrictJSON) throws -> Receipt? {
        if result.isNull { return nil }
        let status = try result.field("status", "receipt").quantity("receipt.status")
        guard status <= 1 else { throw ReaderError.malformed(field: "receipt.status") }
        guard let block = try result.field("blockNumber", "receipt").quantity("receipt.blockNumber").uint64 else {
            throw ReaderError.malformed(field: "receipt.blockNumber")
        }
        let blockHash = try result.field("blockHash", "receipt").hexData("receipt.blockHash")
        guard blockHash.count == 32 else { throw ReaderError.malformed(field: "receipt.blockHash") }
        return Receipt(block: block, blockHash: Hex.encode(blockHash), success: status == 1)
    }

    static func address(_ json: StrictJSON, _ path: String) throws -> EVMAddress {
        do { return try EVMAddress(try json.string(path)) } catch { throw ReaderError.malformed(field: path) }
    }

    /// Um movimento de uma transacao, antes de virar item: nativo ou token, com o sinal
    /// em relacao ao dono.
    struct Movement {
        let key: String
        let asset: Asset?
        let amount: BigUInt
        let outgoing: Bool
        let incoming: Bool
        let counterparty: EVMAddress?
    }

    struct TransactionRow {
        let hash: String
        let date: Date
        let status: ActivityItem.Status
        let from: EVMAddress
        let to: EVMAddress?
        let value: BigUInt
        let fee: BigUInt?
    }

    struct TokenRow {
        let hash: String
        let index: String
        let date: Date
        let from: EVMAddress
        let to: EVMAddress
        let contract: EVMAddress
        let amount: BigUInt
    }

    /// Blockscout v2: `/addresses/{a}/transactions` e `/token-transfers?type=ERC-20`.
    static func parseBlockscoutHistory(
        chain: Chain, owner: EVMAddress, transactions: StrictJSON, tokenTransfers: StrictJSON, complete: Bool = true
    ) throws -> ActivityPage {
        var rows: [TransactionRow] = []
        for (offset, item) in try transactions.field("items", "transactions").array("transactions.items").enumerated() {
            let path = "transactions.items[\(offset)]"
            let hash = try item.field("hash", path).string(path + ".hash")
            let statusText = item.optionalField("status").flatMap { try? $0.string(path + ".status") }
            let status: ActivityItem.Status = statusText == "ok" ? .confirmed : (statusText == "error" ? .failed : .pending)
            let date = try isoDate(try item.field("timestamp", path).string(path + ".timestamp"), path + ".timestamp")
            let from = try address(try item.field("from", path).field("hash", path + ".from"), path + ".from.hash")
            let to = try item.optionalField("to").map { try address(try $0.field("hash", path + ".to"), path + ".to.hash") }
            let value = try item.field("value", path).decimalString(path + ".value")
            let fee = try item.optionalField("fee").map { try $0.field("value", path + ".fee").decimalString(path + ".fee.value") }
            rows.append(TransactionRow(hash: hash, date: date, status: status, from: from, to: to, value: value, fee: fee))
        }
        var tokens: [TokenRow] = []
        for (offset, item) in try tokenTransfers.field("items", "tokenTransfers").array("tokenTransfers.items").enumerated() {
            let path = "tokenTransfers.items[\(offset)]"
            tokens.append(TokenRow(
                hash: try item.field("transaction_hash", path).string(path + ".transaction_hash"),
                index: try item.field("log_index", path).uint64(path + ".log_index").description,
                date: try isoDate(try item.field("timestamp", path).string(path + ".timestamp"), path + ".timestamp"),
                from: try address(try item.field("from", path).field("hash", path + ".from"), path + ".from.hash"),
                to: try address(try item.field("to", path).field("hash", path + ".to"), path + ".to.hash"),
                contract: try address(try item.field("token", path).field("address_hash", path + ".token"), path + ".token.address_hash"),
                amount: try item.field("total", path).field("value", path + ".total").decimalString(path + ".total.value")
            ))
        }
        return assemble(chain: chain, owner: owner, rows: rows, tokens: tokens, complete: complete)
    }

    /// Formato Etherscan (Routescan na Avalanche): `txlist` e `tokentx`.
    static func parseEtherscanHistory(
        chain: Chain, owner: EVMAddress, transactions: StrictJSON, tokenTransfers: StrictJSON, complete: Bool = true
    ) throws -> ActivityPage {
        func results(_ json: StrictJSON, _ path: String) throws -> [StrictJSON] {
            let status = try json.field("status", path).string(path + ".status")
            let result = try json.field("result", path)
            // "0" com lista vazia e "nenhuma transacao"; "0" com texto e erro.
            if status != "1" {
                if case .array(let items) = result, items.isEmpty { return [] }
                throw ReaderError.providerError(code: ReaderError.sanitized("etherscan-" + status))
            }
            return try result.array(path + ".result")
        }
        var rows: [TransactionRow] = []
        for (offset, item) in try results(transactions, "txlist").enumerated() {
            let path = "txlist.result[\(offset)]"
            let failed = try item.field("isError", path).string(path + ".isError") == "1"
            let gasUsed = try item.field("gasUsed", path).decimalString(path + ".gasUsed")
            let gasPrice = try item.field("gasPrice", path).decimalString(path + ".gasPrice")
            let toText = try item.field("to", path).string(path + ".to")
            rows.append(TransactionRow(
                hash: try item.field("hash", path).string(path + ".hash"),
                date: try unixDate(try item.field("timeStamp", path).decimalString(path + ".timeStamp"), path + ".timeStamp"),
                status: failed ? .failed : .confirmed,
                from: try address(try item.field("from", path), path + ".from"),
                to: toText.isEmpty ? nil : try address(.string(toText), path + ".to"),
                value: try item.field("value", path).decimalString(path + ".value"),
                fee: gasUsed * gasPrice
            ))
        }
        var tokens: [TokenRow] = []
        for (offset, item) in try results(tokenTransfers, "tokentx").enumerated() {
            let path = "tokentx.result[\(offset)]"
            // O Routescan nao manda `logIndex`; a posicao na lista separa duas transferencias
            // da mesma transacao.
            let index = try item.optionalField("logIndex")?.string(path + ".logIndex") ?? "t\(offset)"
            tokens.append(TokenRow(
                hash: try item.field("hash", path).string(path + ".hash"),
                index: index,
                date: try unixDate(try item.field("timeStamp", path).decimalString(path + ".timeStamp"), path + ".timeStamp"),
                from: try address(try item.field("from", path), path + ".from"),
                to: try address(try item.field("to", path), path + ".to"),
                contract: try address(try item.field("contractAddress", path), path + ".contractAddress"),
                amount: try item.field("value", path).decimalString(path + ".value")
            ))
        }
        return assemble(chain: chain, owner: owner, rows: rows, tokens: tokens, complete: complete)
    }

    /// Junta transacoes e transferencias de token por hash e aplica as regras de
    /// `ActivityRules`: saiu um ativo e entrou outro na mesma transacao do dono, troca;
    /// recebimento de valor zero, de token fora da lista ou po, suspeito.
    static func assemble(chain: Chain, owner: EVMAddress, rows: [TransactionRow], tokens: [TokenRow], complete: Bool = true) -> ActivityPage {
        let native = Asset.native(chain)
        var suspicious = SuspiciousSummary()
        var items: [ActivityItem] = []
        let rowsByHash = Dictionary(rows.map { ($0.hash.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let tokensByHash = Dictionary(grouping: tokens, by: { $0.hash.lowercased() })
        var hashes = rows.map { $0.hash.lowercased() }
        for hash in tokensByHash.keys where rowsByHash[hash] == nil { hashes.append(hash) }
        var seen = Set<String>()

        for hash in hashes where seen.insert(hash).inserted {
            let row = rowsByHash[hash]
            let sentByOwner = row?.from == owner
            let date = row?.date ?? tokensByHash[hash]?.first?.date ?? .distantPast
            let status = row?.status ?? .confirmed
            let fee = sentByOwner ? row?.fee : nil
            let explorer = chain.explorerURL(tx: row?.hash ?? tokensByHash[hash]?.first?.hash ?? hash)
            let displayHash = row?.hash ?? tokensByHash[hash]?.first?.hash ?? hash

            var movements: [Movement] = []
            if let row, !row.value.isZero, row.from == owner || row.to == owner {
                let outgoing = row.from == owner
                let incoming = row.to == owner
                movements.append(Movement(
                    key: "native", asset: native, amount: row.value, outgoing: outgoing, incoming: incoming,
                    counterparty: outgoing ? row.to : row.from
                ))
            }
            for token in tokensByHash[hash] ?? [] where token.from == owner || token.to == owner {
                let asset = TokenRegistry.find(chainID: chain.id, contract: token.contract.checksummed)
                let outgoing = token.from == owner
                let incoming = token.to == owner
                movements.append(Movement(
                    key: token.index, asset: asset, amount: token.amount, outgoing: outgoing, incoming: incoming,
                    counterparty: outgoing ? token.to : token.from
                ))
            }

            // Recebimentos passam pelo filtro. "Saida" que o dono nao assinou tambem: um
            // contrato qualquer emite `Transfer(dono, sosia, x)` sem permissao nenhuma, e
            // um `transferFrom` de valor zero do token real passa sem allowance
            // (docs/seguranca.md §4.10). Saida real do token real, por um spender
            // aprovado, continua aparecendo.
            var shown: [Movement] = []
            for movement in movements {
                if movement.incoming, !movement.outgoing,
                   let suspicion = ActivityRules.judgeIncoming(asset: movement.asset, amount: movement.amount) {
                    ActivityRules.count(suspicion, in: &suspicious)
                    continue
                }
                if movement.outgoing, !movement.incoming, !sentByOwner {
                    if movement.asset == nil { suspicious.unknownAsset += 1; continue }
                    if movement.amount.isZero { suspicious.zeroValue += 1; continue }
                }
                // Envio do dono de token fora da lista: nao ha ativo curado para mostrar.
                if movement.asset == nil { continue }
                shown.append(movement)
            }

            let outs = shown.filter { $0.outgoing && !$0.incoming }
            let ins = shown.filter { $0.incoming && !$0.outgoing }
            if sentByOwner, let out = outs.first, let into = ins.first, out.asset != into.asset, let outAsset = out.asset, let inAsset = into.asset {
                items.append(ActivityItem(
                    id: "\(chain.id):\(hash):swap", chainID: chain.id, direction: .swap, asset: outAsset, amount: out.amount,
                    receivedAsset: inAsset, receivedAmount: into.amount, counterparty: nil, date: date, status: status,
                    fee: fee, hash: displayHash, explorerURL: explorer
                ))
                continue
            }
            for movement in shown {
                guard let asset = movement.asset else { continue }
                let direction: ActivityItem.Direction = movement.outgoing && movement.incoming ? .other : (movement.outgoing ? .sent : .received)
                items.append(ActivityItem(
                    id: "\(chain.id):\(hash):\(movement.key)", chainID: chain.id, direction: direction, asset: asset,
                    amount: movement.amount, counterparty: movement.counterparty?.checksummed, date: date, status: status,
                    fee: movement.outgoing ? fee : nil, hash: displayHash, explorerURL: explorer
                ))
            }
            // Chamada do dono sem movimento de valor: aprovacao, revogacao, interacao.
            if shown.isEmpty, sentByOwner, let row {
                items.append(ActivityItem(
                    id: "\(chain.id):\(hash):call", chainID: chain.id, direction: .other, asset: native, amount: 0,
                    counterparty: row.to?.checksummed, date: date, status: status, fee: fee, hash: displayHash, explorerURL: explorer
                ))
            } else if movements.isEmpty, let row, row.to == owner, row.from != owner {
                // Chamada de terceiro para a conta, sem valor: o formato do envenenamento.
                suspicious.zeroValue += 1
            }
        }
        return ActivityRules.page(chainID: chain.id, items: items, suspicious: suspicious, complete: complete)
    }

    static func isoDate(_ text: String, _ path: String) throws -> Date {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = plain.date(from: text) else { throw ReaderError.malformed(field: path) }
        return date
    }

    static func unixDate(_ seconds: BigUInt, _ path: String) throws -> Date {
        guard let value = seconds.uint64, value < 10_000_000_000 else { throw ReaderError.malformed(field: path) }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }
}

extension EVMAddress {
    /// So para constantes compiladas deste arquivo, sempre com 20 bytes.
    init(bytesUnchecked bytes: [UInt8]) {
        self = EVMAddress(bytes: bytes)!
    }
}
