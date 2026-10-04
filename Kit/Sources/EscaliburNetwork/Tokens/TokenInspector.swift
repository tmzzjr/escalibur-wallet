import EscaliburChains
import EscaliburCore
import Foundation

/// O que a rede diz de uma moeda que o dono quer adicionar, para a previa.
public struct TokenFacts: Sendable, Equatable {
    /// A moeda custom pronta para guardar (nome e simbolo ja limpos).
    public let asset: Asset
    /// Os dois provedores que concordaram nas casas decimais (ou que confirmaram que o
    /// ativo existe, no XRP Ledger e na Stellar, onde as casas nao sao do token).
    public let sources: [String]
    /// XRP Ledger e Stellar: de onde vem as casas que a carteira usa.
    public let decimalsNote: String?
    /// Motivos de suspeita no nome e no simbolo (`TokenSafety`), sem contar saldo.
    public let reasons: [TokenSafety.Reason]
    /// Outras coisas que o dono deve saber antes de salvar (taxa do emissor na Solana,
    /// lista negra da tonapi).
    public let notes: [String]
}

/// Por que a leitura da moeda nao deu certo. A mensagem ja vem em portugues.
public enum TokenInspectionError: LocalizedError, Equatable, Sendable {
    /// O endereco nao tem contrato de token (conta comum, contrato sem `decimals`).
    case notAToken
    /// As fontes responderam coisas diferentes para as casas decimais.
    case providersDisagree
    /// Menos de duas fontes responderam.
    case notEnoughSources
    /// XRP Ledger e Stellar: o emissor nao existe, ou nao tem esta moeda em circulacao.
    case unknownAsset
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .notAToken: return "Este endereço não é de um token nesta rede. Confira a rede escolhida e o endereço inteiro."
        case .providersDisagree: return "As fontes da rede responderam casas decimais diferentes. Por segurança, a moeda não foi adicionada."
        case .notEnoughSources: return "Não foi possível confirmar em duas fontes da rede agora. Tente de novo em instantes."
        case .unknownAsset: return "Este emissor não tem esta moeda em circulação. Confira o código e o emissor."
        case .unsupported: return "Esta rede ainda não aceita moeda custom."
        }
    }
}

/// Le uma moeda na propria rede antes de ela virar moeda custom: nome, simbolo e casas
/// decimais, com dois provedores concordando nas casas (o valor digitado num envio e
/// lido nessa escala, e um provedor sozinho poderia mentir).
public actor TokenInspector {
    public static let shared = TokenInspector()

    let transport: ReaderTransport
    let evm: EVMReader
    let solana: [ProviderPool.Provider]
    let tron: [ProviderPool.Provider]
    let tonapi: URL
    let toncenter: URL
    let xrpl: [ProviderPool.Provider]
    let stellar: [ProviderPool.Provider]
    private var pools: [String: ProviderPool] = [:]

    public init() {
        self.init(transport: HTTPClient.shared, evm: .shared)
    }

    init(
        transport: ReaderTransport, evm: EVMReader, solana: [ProviderPool.Provider] = Endpoints.solana,
        tron: [ProviderPool.Provider] = Endpoints.tron + Endpoints.tronContingency,
        tonapi: URL = Endpoints.ton[0].baseURL, toncenter: URL = Endpoints.ton[1].baseURL,
        xrpl: [ProviderPool.Provider] = Endpoints.xrpl, stellar: [ProviderPool.Provider] = Endpoints.stellar
    ) {
        self.transport = transport
        self.evm = evm
        self.solana = solana
        self.tron = tron
        self.tonapi = tonapi
        self.toncenter = toncenter
        self.xrpl = xrpl
        self.stellar = stellar
    }

    private func pool(_ key: String, _ providers: [ProviderPool.Provider]) -> ProviderPool {
        if let existing = pools[key] { return existing }
        let created = ProviderPool(providers)
        pools[key] = created
        return created
    }

    public func inspect(chain: Chain, kind: Asset.Kind) async throws -> TokenFacts {
        do {
            switch (chain.family, kind) {
            case (.evm, .token(let contract)): return try await evmFacts(chain, contract)
            case (.solana, .token(let mint)): return try await solanaFacts(mint)
            case (.tron, .token(let contract)): return try await tronFacts(contract)
            case (.ton, .token(let master)): return try await tonFacts(master)
            case (.xrpl, .issued(let code, let issuer)): return try await xrplFacts(code: code, issuer: issuer)
            case (.stellar, .issued(let code, let issuer)): return try await stellarFacts(code: code, issuer: issuer)
            default: throw TokenInspectionError.unsupported
            }
        } catch let error as TokenInspectionError {
            throw error
        } catch ReaderError.providersDisagree {
            throw TokenInspectionError.providersDisagree
        } catch ReaderError.notEnoughProviders {
            throw TokenInspectionError.notEnoughSources
        } catch ReaderError.unsupported, ReaderError.executionReverted, ReaderError.malformed, ReaderError.providerError {
            throw TokenInspectionError.notAToken
        } catch {
            throw TokenInspectionError.notEnoughSources
        }
    }

    static func facts(
        _ chain: Chain, _ kind: Asset.Kind, symbol: String, name: String, decimals: Int, sources: [String],
        decimalsNote: String? = nil, notes: [String] = [], flagged: Bool = false
    ) -> TokenFacts {
        let reasons = TokenSafety.reasons(
            symbol: symbol, name: name, chainID: chain.id, kind: kind, amount: BigUInt(), decimals: decimals, unsolicited: false,
            flaggedBySource: flagged
        )
        return TokenFacts(
            asset: CustomToken.asset(chain: chain, kind: kind, symbol: symbol, name: name, decimals: decimals),
            sources: sources, decimalsNote: decimalsNote, reasons: reasons, notes: notes
        )
    }

    // MARK: EVM

    private func evmFacts(_ chain: Chain, _ contract: String) async throws -> TokenFacts {
        guard let address = try? EVMAddress(contract) else { throw TokenInspectionError.notAToken }
        let read = try await evm.tokenFacts(chain: chain, contract: address)
        return Self.facts(chain, .token(contract: address.checksummed), symbol: read.symbol, name: read.name, decimals: read.decimals, sources: read.sources)
    }

    // MARK: Solana

    /// O mint lido em dois provedores, que tem de concordar no programa e nas casas.
    /// Nome e simbolo: a extensao de metadados do Token-2022 ou a conta da Metaplex.
    private func solanaFacts(_ text: String) async throws -> TokenFacts {
        guard let mint = try? SolanaPublicKey(base58: text) else { throw TokenInspectionError.notAToken }
        let pool = pool("solana", solana)
        let transport = self.transport
        let readings = try await Quorum.collect(await pool.available(), pool: pool, count: 2) { provider in
            let body: StrictJSON = .object([
                "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("getAccountInfo"),
                "params": .array([.string(mint.base58), .object(["encoding": .string("jsonParsed"), "commitment": .string("confirmed")])]),
            ])
            let data = try await transport.send(.post(provider.baseURL, body))
            let info: SolanaMintInfo
            do { info = try SolanaAccountParser.mint(fromResponse: data, address: mint) } catch { throw ReaderError.unsupported("nao e mint") }
            return (info: info, embedded: Self.token2022Metadata(try StrictJSON.parse(data)))
        }
        let first = readings[0].value, second = readings[1].value
        guard first.info.decimals == second.info.decimals, first.info.program == second.info.program else {
            throw TokenInspectionError.providersDisagree
        }
        var names = first.embedded
        if names == nil, let pda = SolanaMetaplex.metadataAddress(mint: mint) {
            names = try? await Quorum.first(await pool.available(), pool: pool) { provider in
                let result = try await EVMReader.call(transport, provider.baseURL, "getAccountInfo", [
                    .string(pda.base58), .object(["encoding": .string("base64"), "commitment": .string("confirmed")]),
                ])
                guard let value = result.optionalField("value"), let data = try value.field("data", "value").array("data").first?.string("data"),
                      let bytes = Data(base64Encoded: data), let parsed = SolanaMetaplex.parse([UInt8](bytes)), parsed.mint == mint
                else { throw ReaderError.malformed(field: "metadata") }
                return (parsed.name, parsed.symbol)
            }
        }
        var notes: [String] = []
        for ext in first.info.extensions {
            switch ext {
            case .transferFee(let basisPoints, _):
                notes.append("O emissor cobra \(Double(basisPoints) / 100)% de cada transferência deste token (Token-2022).")
            case .permanentDelegate:
                notes.append("O emissor pode mover ou queimar este token em qualquer conta, inclusive na sua.")
            case .transferHook:
                notes.append("Cada transferência chama um programa do emissor. A Escalibur não envia token com esse gancho.")
            case .nonTransferable:
                notes.append("Este token não pode ser transferido.")
            case .defaultAccountStateFrozen:
                notes.append("Contas novas deste token nascem congeladas pelo emissor.")
            case .paused:
                notes.append("O emissor pausou este token.")
            case .unknown:
                notes.append("O token tem extensões do Token-2022 que a carteira não conhece.")
            }
        }
        return Self.facts(
            .solana, .token(contract: mint.base58), symbol: names?.symbol ?? "", name: names?.name ?? "",
            decimals: Int(first.info.decimals), sources: readings.map(\.provider.name), notes: notes
        )
    }

    /// A extensao `tokenMetadata` do mint no Token-2022, na resposta `jsonParsed`.
    static func token2022Metadata(_ json: StrictJSON) -> (name: String, symbol: String)? {
        guard let info = try? json.field("result", "r").field("value", "r").field("data", "r").field("parsed", "r").field("info", "r"),
              let extensions = try? info.field("extensions", "info").array("extensions")
        else { return nil }
        for ext in extensions where (try? ext.field("extension", "e").string("extension")) == "tokenMetadata" {
            guard let state = try? ext.field("state", "e") else { continue }
            let name = (try? state.field("name", "s").string("name")) ?? ""
            let symbol = (try? state.field("symbol", "s").string("symbol")) ?? ""
            return (name, symbol)
        }
        return nil
    }

    // MARK: Tron

    /// `decimals()` em dois nos concordando; `symbol()` e `name()` no primeiro que
    /// responder.
    private func tronFacts(_ contract: String) async throws -> TokenFacts {
        guard TronAddress(base58: contract) != nil else { throw TokenInspectionError.notAToken }
        let pool = pool("tron", tron)
        let transport = self.transport
        let providers = await pool.available()
        @Sendable func constant(_ provider: ProviderPool.Provider, _ selector: String) async throws -> [UInt8] {
            let json = try await TronReader.post(transport, provider, "wallet/triggerconstantcontract", [
                "owner_address": .string(contract), "contract_address": .string(contract),
                "function_selector": .string(selector), "visible": .bool(true),
            ])
            return try TronReader.parseConstantCall(json, field: selector).word
        }
        let (value, sources) = try await Quorum.agreeing(providers, pool: pool, field: "decimals") { provider in
            let word = try await constant(provider, "decimals()")
            guard word.count == 32 else { throw ReaderError.malformed(field: "decimals") }
            return BigUInt(bigEndian: word)
        }
        guard let decimals = value.uint64, decimals <= 36 else { throw TokenInspectionError.notAToken }
        let symbol = try? await Quorum.first(providers, pool: pool) { provider in
            guard let text = CustomToken.decodeABIText(try await constant(provider, "symbol()")) else { throw ReaderError.malformed(field: "symbol") }
            return text
        }
        let name = try? await Quorum.first(providers, pool: pool) { provider in
            guard let text = CustomToken.decodeABIText(try await constant(provider, "name()")) else { throw ReaderError.malformed(field: "name") }
            return text
        }
        return Self.facts(.tron, .token(contract: contract), symbol: symbol ?? "", name: name ?? "", decimals: Int(decimals), sources: sources)
    }

    // MARK: TON

    /// O mestre do jetton na tonapi e na toncenter (v3): as casas tem de bater. Sem
    /// casas declaradas, o padrao do TEP-64 e 9.
    private func tonFacts(_ master: String) async throws -> TokenFacts {
        guard case .success(let parsed) = TONAddress.parse(master) else { throw TokenInspectionError.notAToken }
        let raw = parsed.address.raw
        async let fromTonapi = try? StrictJSON.parse(await transport.send(.get(tonapi.adding(path: "jettons/\(raw)"))))
        async let fromToncenter = try? StrictJSON.parse(await transport.send(.get(toncenter.adding(path: "jetton/masters").adding(query: [("address", raw)]))))
        let a = await fromTonapi, b = await fromToncenter
        let first = a.flatMap(Self.tonapiJetton)
        let second = b.flatMap(Self.toncenterJetton)
        guard let first, let second else {
            if a == nil, b == nil { throw TokenInspectionError.notEnoughSources }
            if first == nil, second == nil { throw TokenInspectionError.notAToken }
            throw TokenInspectionError.notEnoughSources
        }
        guard first.decimals == second.decimals else { throw TokenInspectionError.providersDisagree }
        var notes: [String] = []
        if first.verification == "blacklist" { notes.append("A tonapi marca este jetton como golpe.") }
        return Self.facts(
            .ton, .token(contract: parsed.address.friendly(bounceable: true)), symbol: first.symbol, name: first.name,
            decimals: first.decimals, sources: ["tonapi", "toncenter"], notes: notes, flagged: first.verification == "blacklist"
        )
    }

    static func tonapiJetton(_ json: StrictJSON) -> (name: String, symbol: String, decimals: Int, verification: String?)? {
        guard let metadata = try? json.field("metadata", "jetton") else { return nil }
        let decimals = (try? metadata.field("decimals", "metadata").integer("decimals")).flatMap(\.uint64) ?? 9
        guard decimals <= 36 else { return nil }
        return (
            (try? metadata.field("name", "metadata").string("name")) ?? "",
            (try? metadata.field("symbol", "metadata").string("symbol")) ?? "",
            Int(decimals),
            try? json.field("verification", "jetton").string("verification")
        )
    }

    static func toncenterJetton(_ json: StrictJSON) -> (decimals: Int, Void)? {
        guard let master = try? json.field("jetton_masters", "masters").array("jetton_masters").first else { return nil }
        let content = master.optionalField("jetton_content")
        let decimals = (content?.optionalField("decimals")).flatMap { try? $0.integer("decimals") }.flatMap(\.uint64) ?? 9
        guard decimals <= 36 else { return nil }
        return (Int(decimals), ())
    }

    // MARK: XRP Ledger

    /// O emissor existe em dois servidores, e o `gateway_balances` dele tem a moeda em
    /// circulacao. O ledger nao guarda casas por token.
    private func xrplFacts(code: String, issuer: String) async throws -> TokenFacts {
        let pool = pool("xrpl", xrpl)
        let transport = self.transport
        let readings = try await Quorum.collect(await pool.available(), pool: pool, count: 2) { provider in
            let info = try await XRPLReader.call(transport, provider.baseURL, "account_info", [
                "account": .string(issuer), "ledger_index": .string("validated"),
            ])
            if let error = info.optionalField("error") {
                if (try? error.string("error")) == "actNotFound" { return false }
                throw ReaderError.providerError(code: "account_info")
            }
            return true
        }
        guard readings.allSatisfy(\.value) else { throw TokenInspectionError.unknownAsset }
        let issued = try await Quorum.first(await pool.available(), pool: pool) { provider in
            let result = try await XRPLReader.call(transport, provider.baseURL, "gateway_balances", [
                "account": .string(issuer), "ledger_index": .string("validated"), "strict": .bool(true),
            ])
            let obligations = result.optionalField("obligations")?.objectValue ?? [:]
            return obligations.keys.contains { $0.uppercased() == code.uppercased() }
        }
        guard issued else { throw TokenInspectionError.unknownAsset }
        let symbol = CustomToken.xrplSymbol(code)
        return Self.facts(
            .xrpl, .issued(code: code, issuer: issuer), symbol: symbol, name: symbol, decimals: BalanceService.xrplDisplayDecimals,
            sources: readings.map(\.provider.name),
            decimalsNote: "No XRP Ledger o token não tem casas decimais fixas. A carteira mostra até \(BalanceService.xrplDisplayDecimals) casas."
        )
    }

    // MARK: Stellar

    /// O ativo em duas Horizons (`/assets`). Todo ativo da Stellar tem 7 casas.
    private func stellarFacts(code: String, issuer: String) async throws -> TokenFacts {
        let pool = pool("stellar", stellar)
        let transport = self.transport
        let readings = try await Quorum.collect(await pool.available(), pool: pool, count: 2) { provider in
            let url = provider.baseURL.adding(path: "assets").adding(query: [("asset_code", code), ("asset_issuer", issuer)])
            let json = try StrictJSON.parse(try await transport.send(.get(url)))
            let records = try json.field("_embedded", "assets").field("records", "assets").array("records")
            return records.contains { record in
                (try? record.field("asset_code", "r").string("asset_code")) == code && (try? record.field("asset_issuer", "r").string("asset_issuer")) == issuer
            }
        }
        guard readings.allSatisfy(\.value) else { throw TokenInspectionError.unknownAsset }
        return Self.facts(
            .stellar, .issued(code: code, issuer: issuer), symbol: code, name: code, decimals: 7, sources: readings.map(\.provider.name),
            decimalsNote: "Na Stellar todo ativo tem 7 casas decimais, pela própria rede."
        )
    }
}
