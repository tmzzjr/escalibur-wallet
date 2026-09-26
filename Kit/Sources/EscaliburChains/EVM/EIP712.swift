import EscaliburCore
import Foundation

// EIP-712: hash de dados estruturados e tipados.
//
//   digest = keccak256(0x19 0x01 || domainSeparator || hashStruct(message))
//   hashStruct(s) = keccak256(typeHash(s) || encodeData(s))
//   typeHash = keccak256(encodeType), com as dependencias em ordem alfabetica
//
// Assinatura EIP-712 de terceiro e o vetor preferido de dreno: um "Permit" assinado
// fora da cadeia entrega o saldo sem transacao nenhuma do dono. Por isso a carteira
// separa duas coisas: o hash generico (este arquivo inteiro, testado contra o exemplo
// "Mail" da EIP e os vetores do ethers) e a **mensagem tipada validada**, que e o
// unico tipo assinavel e so nasce se dominio, rede, contrato verificador e estrutura
// estiverem numa allowlist que quem chama fornece (docs/seguranca.md 4.1 e 4.4).

public enum EIP712Error: Error, Equatable, Sendable {
    case invalidJSON
    case invalidTypeName(String)
    case invalidFieldName(String)
    case duplicateField(String)
    case unknownType(String)
    case invalidDomain(String)
    case primaryTypeNotFound(String)
    case missingField(String)
    case unexpectedField(String)
    /// O valor nao tem a forma do tipo do campo.
    case invalidValue(field: String, type: String)
    case wrongArrayLength(String)
    case tooDeep
    // Validacao para assinar
    case missingChainID
    case chainMismatch
    case missingVerifyingContract
    /// Permit, Permit2 e parentes: a v1 nao assina (docs/seguranca.md 4.4).
    case permitForbidden
    case notAllowlisted
}

/// Um valor de mensagem tipada, na forma do JSON do `eth_signTypedData_v4`.
public indirect enum EIP712Value: Hashable, Sendable {
    case string(String)
    /// Numero inteiro, guardado como o texto literal para nao perder precisao.
    case number(String)
    case bool(Bool)
    case array([EIP712Value])
    case object([String: EIP712Value])

    init(json: EVMJSON) throws {
        switch json {
        case .string(let text): self = .string(text)
        case .bool(let flag): self = .bool(flag)
        case .number(let literal):
            // So inteiro: `1.5` ou `1e18` num campo uint seria arredondado por
            // alguem, e a carteira nao escolhe como.
            guard EIP712Value.isIntegerLiteral(literal) else { throw EIP712Error.invalidJSON }
            self = .number(literal)
        case .array(let items): self = .array(try items.map(EIP712Value.init(json:)))
        case .object(let members): self = .object(try members.mapValues(EIP712Value.init(json:)))
        case .null: throw EIP712Error.invalidJSON
        }
    }

    static func isIntegerLiteral(_ text: String) -> Bool {
        let body = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        guard let first = body.first, body.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return false }
        return first != "0" || body.count == 1
    }
}

/// Tipo de um campo, ja resolvido.
indirect enum EIP712FieldType: Equatable, Sendable {
    /// address, bool, uint<N>, int<N>, bytes<N>: codificados como na ABI.
    case atomic(ABIType)
    case bytes
    case string
    case structure(String)
    case array(EIP712FieldType, fixedLength: Int?)
}

struct EIP712ResolvedField: Equatable, Sendable {
    let name: String
    let type: EIP712FieldType
}

public struct EIP712TypedData: Sendable, Equatable {
    public struct Field: Sendable, Hashable {
        public let name: String
        public let type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    public static let domainTypeName = "EIP712Domain"

    /// Os campos que um dominio pode ter, na ordem canonica da EIP.
    static let domainFields: [Field] = [
        Field(name: "name", type: "string"),
        Field(name: "version", type: "string"),
        Field(name: "chainId", type: "uint256"),
        Field(name: "verifyingContract", type: "address"),
        Field(name: "salt", type: "bytes32"),
    ]

    static let maxDepth = 64
    /// Tetos para tipos que chegam de fora. Os maiores tipos reais (Seaport, CoW)
    /// ficam muito abaixo; os tetos so impedem que um JSON montado para isso faca a
    /// carteira gastar tempo ou pilha.
    static let maxTypes = 64
    static let maxFieldsPerType = 128
    static let maxArrayNesting = 16

    /// Todos os tipos, incluindo `EIP712Domain`.
    public let types: [String: [Field]]
    public let primaryType: String
    public let domain: [String: EIP712Value]
    public let message: [String: EIP712Value]
    /// Os campos com o tipo ja resolvido, e o typeHash de cada struct, calculados uma
    /// vez na criacao.
    let resolved: [String: [EIP712ResolvedField]]
    let typeHashes: [String: [UInt8]]

    /// `types` pode trazer `EIP712Domain` ou nao; sem ele, o tipo do dominio sai das
    /// chaves presentes, na ordem canonica.
    public init(types: [String: [Field]], primaryType: String, domain: [String: EIP712Value], message: [String: EIP712Value]) throws {
        var all = types
        if let declared = types[Self.domainTypeName] {
            // O dominio declarado precisa ser um subconjunto dos cinco campos da EIP,
            // com os tipos da EIP, na ordem da EIP. Campo extra no dominio mudaria o
            // separador sem aparecer em nenhuma conferencia.
            var canonical = Self.domainFields.makeIterator()
            for field in declared {
                var matched = false
                while let next = canonical.next() {
                    if next == field { matched = true; break }
                }
                guard matched else { throw EIP712Error.invalidDomain(field.name) }
            }
        } else {
            all[Self.domainTypeName] = Self.domainFields.filter { domain[$0.name] != nil }
        }
        let domainNames = Set(all[Self.domainTypeName]!.map(\.name))
        for key in domain.keys where !domainNames.contains(key) { throw EIP712Error.invalidDomain(key) }

        guard all.count <= Self.maxTypes else { throw EIP712Error.tooDeep }
        var resolved = [String: [EIP712ResolvedField]]()
        for (name, fields) in all {
            // Nome de struct nao pode ser nome de tipo da ABI (nem `uint`): o mesmo
            // texto teria duas leituras.
            guard ABIFunction.isIdentifier(name), ABITypeParser.base(name) == nil else { throw EIP712Error.invalidTypeName(name) }
            guard fields.count <= Self.maxFieldsPerType else { throw EIP712Error.tooDeep }
            var seen = Set<String>()
            resolved[name] = try fields.map { field in
                guard ABIFunction.isIdentifier(field.name) else { throw EIP712Error.invalidFieldName(field.name) }
                guard seen.insert(field.name).inserted else { throw EIP712Error.duplicateField(field.name) }
                return EIP712ResolvedField(name: field.name, type: try Self.resolve(field.type, in: all))
            }
        }
        guard primaryType != Self.domainTypeName, all[primaryType] != nil else { throw EIP712Error.primaryTypeNotFound(primaryType) }

        var hashes = [String: [UInt8]]()
        for name in all.keys {
            hashes[name] = Hash.keccak256(Array(Self.encodeType(name, types: all, resolved: resolved).utf8))
        }

        self.types = all
        self.primaryType = primaryType
        self.domain = domain
        self.message = message
        self.resolved = resolved
        self.typeHashes = hashes
        // Codificar uma vez aqui garante que dominio e mensagem batem com os tipos:
        // um objeto que nao codifica nunca chega a existir.
        _ = try domainSeparator()
        _ = try hashStruct(primaryType, message)
    }

    /// Le o JSON do `eth_signTypedData_v4`: `{types, primaryType, domain, message}`.
    public init(json text: String) throws {
        guard case .object(let root) = try? EVMJSON.parse(text),
              case .object(let rawTypes)? = root["types"],
              case .string(let primary)? = root["primaryType"],
              case .object(let rawDomain)? = root["domain"],
              case .object(let rawMessage)? = root["message"],
              root.count == 4
        else { throw EIP712Error.invalidJSON }
        var types = [String: [Field]]()
        for (name, value) in rawTypes {
            guard case .array(let items) = value else { throw EIP712Error.invalidJSON }
            types[name] = try items.map { item in
                guard case .object(let member) = item, member.count == 2,
                      case .string(let fieldName)? = member["name"],
                      case .string(let fieldType)? = member["type"]
                else { throw EIP712Error.invalidJSON }
                return Field(name: fieldName, type: fieldType)
            }
        }
        try self.init(
            types: types, primaryType: primary,
            domain: try rawDomain.mapValues(EIP712Value.init(json:)),
            message: try rawMessage.mapValues(EIP712Value.init(json:))
        )
    }

    // MARK: Tipos

    /// Tipo atomico com o nome canonico exato. `uint` sem largura nao vale aqui: o
    /// texto do tipo entra no typeHash como esta escrito, e o contrato usa `uint256`.
    static func atomicType(_ name: String) -> ABIType? {
        guard let type = ABITypeParser.base(name), type.description == name else { return nil }
        switch type {
        case .address, .bool, .uint, .int, .fixedBytes: return type
        default: return nil
        }
    }

    static func resolve(_ text: String, in types: [String: [Field]], nesting: Int = 0) throws -> EIP712FieldType {
        guard nesting <= maxArrayNesting else { throw EIP712Error.tooDeep }
        // Sufixos de array da direita para a esquerda: o ultimo e o mais externo.
        if text.hasSuffix("]"), let open = text.lastIndex(of: "[") {
            let inner = try resolve(String(text[..<open]), in: types, nesting: nesting + 1)
            let digits = text[text.index(after: open)..<text.index(before: text.endIndex)]
            if digits.isEmpty { return .array(inner, fixedLength: nil) }
            guard digits.first != "0", digits.count <= 7, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let count = Int(digits), count >= 1
            else { throw EIP712Error.unknownType(text) }
            return .array(inner, fixedLength: count)
        }
        if text == "bytes" { return .bytes }
        if text == "string" { return .string }
        if let atomic = atomicType(text) { return .atomic(atomic) }
        if types[text] != nil, text != domainTypeName { return .structure(text) }
        throw EIP712Error.unknownType(text)
    }

    /// Nome do struct na base do tipo (`Person[]` da `Person`), se for struct.
    static func structBase(_ type: EIP712FieldType) -> String? {
        switch type {
        case .structure(let name): return name
        case .array(let inner, _): return structBase(inner)
        default: return nil
        }
    }

    /// `Mail(Person from,Person to,string contents)Person(string name,address wallet)`:
    /// o tipo principal primeiro, depois as dependencias em ordem alfabetica.
    public func encodeType(_ name: String) throws -> String {
        guard types[name] != nil else { throw EIP712Error.unknownType(name) }
        return Self.encodeType(name, types: types, resolved: resolved)
    }

    static func encodeType(_ name: String, types: [String: [Field]], resolved: [String: [EIP712ResolvedField]]) -> String {
        var found = [String]()
        var pending = [name]
        while let current = pending.popLast() {
            guard !found.contains(current) else { continue }
            found.append(current)
            for field in resolved[current] ?? [] {
                if let base = structBase(field.type), !found.contains(base) { pending.append(base) }
            }
        }
        let ordered = [name] + found.filter { $0 != name }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        return ordered.map { type in
            type + "(" + (types[type] ?? []).map { "\($0.type) \($0.name)" }.joined(separator: ",") + ")"
        }.joined()
    }

    public func typeHash(_ name: String) throws -> [UInt8] {
        guard let hash = typeHashes[name] else { throw EIP712Error.unknownType(name) }
        return hash
    }

    // MARK: Dados

    /// `typeHash || campo1 || campo2 ...`, cada campo em 32 bytes.
    public func encodeData(_ name: String, _ value: [String: EIP712Value]) throws -> [UInt8] {
        try encodeData(name, value, depth: 0)
    }

    func encodeData(_ name: String, _ value: [String: EIP712Value], depth: Int) throws -> [UInt8] {
        guard depth <= Self.maxDepth else { throw EIP712Error.tooDeep }
        guard let fields = resolved[name] else { throw EIP712Error.unknownType(name) }
        // Campo a mais nao entra no hash, mas apareceria na tela: recusar.
        let names = Set(fields.map(\.name))
        for key in value.keys where !names.contains(key) { throw EIP712Error.unexpectedField(key) }
        var out = try typeHash(name)
        for field in fields {
            guard let item = value[field.name] else { throw EIP712Error.missingField(field.name) }
            out += try encodeField(field.type, item, field: field.name, depth: depth)
        }
        return out
    }

    public func hashStruct(_ name: String, _ value: [String: EIP712Value]) throws -> [UInt8] {
        Hash.keccak256(try encodeData(name, value))
    }

    func encodeField(_ type: EIP712FieldType, _ value: EIP712Value, field: String, depth: Int) throws -> [UInt8] {
        guard depth <= Self.maxDepth else { throw EIP712Error.tooDeep }
        func invalid() -> EIP712Error { .invalidValue(field: field, type: Self.describe(type)) }
        switch type {
        case .structure(let name):
            guard case .object(let members) = value else { throw invalid() }
            return Hash.keccak256(try encodeData(name, members, depth: depth + 1))
        case .string:
            guard case .string(let text) = value else { throw invalid() }
            return Hash.keccak256(Array(text.utf8))
        case .bytes:
            guard case .string(let text) = value, let raw = Self.hexBytes(text) else { throw invalid() }
            return Hash.keccak256(raw)
        case .array(let inner, let fixedLength):
            guard case .array(let items) = value else { throw invalid() }
            if let fixedLength, items.count != fixedLength { throw EIP712Error.wrongArrayLength(field) }
            var joined = [UInt8]()
            for item in items { joined += try encodeField(inner, item, field: field, depth: depth + 1) }
            return Hash.keccak256(joined)
        case .atomic(let abiType):
            let abiValue = try Self.abiValue(value, as: abiType, field: field)
            do {
                return try ABI.encode(abiValue, as: abiType)
            } catch {
                throw invalid()
            }
        }
    }

    static func describe(_ type: EIP712FieldType) -> String {
        switch type {
        case .atomic(let abi): return abi.description
        case .bytes: return "bytes"
        case .string: return "string"
        case .structure(let name): return name
        case .array(let inner, let length): return describe(inner) + "[" + (length.map(String.init) ?? "") + "]"
        }
    }

    /// Converte o valor do JSON para o valor ABI do tipo atomico, sem adivinhar:
    /// numero como inteiro literal, texto decimal ou `0x` hex; endereco com checksum
    /// conferido; bytes<N> com exatamente N bytes.
    static func abiValue(_ value: EIP712Value, as type: ABIType, field: String) throws -> ABIValue {
        let invalid = EIP712Error.invalidValue(field: field, type: type.description)
        switch (type, value) {
        case (.address, .string(let text)):
            guard let address = try? EVMAddress(text) else { throw invalid }
            return .address(address)
        case (.bool, .bool(let flag)):
            return .bool(flag)
        case (.uint, .number(let text)), (.uint, .string(let text)):
            guard let number = unsignedInteger(text) else { throw invalid }
            return .uint(number)
        case (.int, .number(let text)), (.int, .string(let text)):
            if isDecimal(text), let signed = ABISignedInteger(decimal: text) { return .int(signed) }
            guard let magnitude = unsignedInteger(text) else { throw invalid }
            return .int(ABISignedInteger(magnitude: magnitude, negative: false))
        case (.fixedBytes(let size), .string(let text)):
            guard let raw = hexBytes(text), raw.count == size else { throw invalid }
            return .fixedBytes(raw)
        default:
            throw invalid
        }
    }

    static func isDecimal(_ text: String) -> Bool {
        EIP712Value.isIntegerLiteral(text)
    }

    static func unsignedInteger(_ text: String) -> BigUInt? {
        if text.hasPrefix("0x") {
            let body = text.dropFirst(2)
            guard !body.isEmpty, body.allSatisfy(\.isHexDigit) else { return nil }
            return BigUInt(hex: text)
        }
        guard isDecimal(text), !text.hasPrefix("-") else { return nil }
        return BigUInt(decimal: text)
    }

    /// `0x` seguido de pares de digitos hex. Sem o `0x` nao e aceito: texto comum
    /// que por acaso so tem digitos hex viraria bytes diferentes do que o dApp quis.
    static func hexBytes(_ text: String) -> [UInt8]? {
        guard text.hasPrefix("0x") else { return nil }
        return Hex.decode(text)
    }

    // MARK: Hash final

    public func domainSeparator() throws -> [UInt8] {
        try hashStruct(Self.domainTypeName, domain)
    }

    /// keccak256(0x19 0x01 || domainSeparator || hashStruct(message)).
    public func signingDigest() throws -> [UInt8] {
        Hash.keccak256([0x19, 0x01] + (try domainSeparator()) + (try hashStruct(primaryType, message)))
    }

    // MARK: Leitura do dominio

    public var domainName: String? {
        if case .string(let text)? = domain["name"] { return text }
        return nil
    }

    public var domainVersion: String? {
        if case .string(let text)? = domain["version"] { return text }
        return nil
    }

    public var domainChainID: BigUInt? {
        switch domain["chainId"] {
        case .number(let text)?, .string(let text)?: return Self.unsignedInteger(text)
        default: return nil
        }
    }

    public var domainVerifyingContract: EVMAddress? {
        if case .string(let text)? = domain["verifyingContract"] { return try? EVMAddress(text) }
        return nil
    }
}

// MARK: Mensagem validada

/// Uma entrada da allowlist de mensagens tipadas: a rede, o contrato verificador, o
/// tipo principal e a estrutura exata dele. As allowlists concretas (CoW, UniswapX)
/// vivem na camada de troca, compiladas.
public struct EIP712Rule: Sendable {
    public let chain: Chain
    public let verifyingContract: EVMAddress
    public let primaryType: String
    /// O `encodeType(primaryType)` inteiro, com as dependencias. Fixa a estrutura:
    /// um "Order" com um campo a mais ou a menos nao e o "Order" conhecido.
    public let encodedType: String
    /// Se preenchidos, o `name` e a `version` do dominio precisam ser estes.
    public let domainName: String?
    public let domainVersion: String?
    /// Confere o conteudo contra a intencao: destinatario igual ao dono, valores
    /// iguais aos da tela, prazo curto. Lanca para recusar.
    public let checkMessage: @Sendable (_ message: [String: EIP712Value], _ owner: EVMAddress) throws -> Void

    public init(
        chain: Chain, verifyingContract: EVMAddress, primaryType: String, encodedType: String,
        domainName: String?, domainVersion: String?,
        checkMessage: @escaping @Sendable (_ message: [String: EIP712Value], _ owner: EVMAddress) throws -> Void
    ) {
        self.chain = chain
        self.verifyingContract = verifyingContract
        self.primaryType = primaryType
        self.encodedType = encodedType
        self.domainName = domainName
        self.domainVersion = domainVersion
        self.checkMessage = checkMessage
    }
}

/// A unica forma assinavel de dado tipado: so existe se passou pela allowlist.
public struct EIP712ValidatedMessage: SignableTransaction {
    /// O Permit2 da Uniswap, mesmo endereco em todas as redes. A v1 nao assina nada
    /// dele (docs/seguranca.md 4.4); liberar exige mudar esta constante e o teste.
    public static let permit2 = EVMAddress(uncheckedBytes: [UInt8](hex: "000000000022d473030f116ddee9f6b43ac78ba3")!)

    /// Tipos principais de permissao fora da cadeia: EIP-2612, DAI e Permit2.
    public static let forbiddenPrimaryTypes: Set<String> = [
        "Permit", "PermitSingle", "PermitBatch", "PermitTransferFrom", "PermitBatchTransferFrom",
        "PermitWitnessTransferFrom", "PermitBatchWitnessTransferFrom",
    ]

    public let chain: Chain
    public let account: EVMAccount
    public let typedData: EIP712TypedData
    public let digest: [UInt8]

    public init(_ typedData: EIP712TypedData, chain: Chain, account: EVMAccount, allowlist: [EIP712Rule]) throws {
        guard chain.family == .evm, let chainID = chain.evmChainID else { throw EVMTransactionError.notEVMChain }
        // A proibicao vem antes da allowlist: nem uma allowlist mal escrita libera permit.
        guard !Self.forbiddenPrimaryTypes.contains(typedData.primaryType) else { throw EIP712Error.permitForbidden }
        guard let verifying = typedData.domainVerifyingContract else { throw EIP712Error.missingVerifyingContract }
        guard verifying != Self.permit2 else { throw EIP712Error.permitForbidden }
        guard let domainChain = typedData.domainChainID else { throw EIP712Error.missingChainID }
        guard domainChain == BigUInt(chainID) else { throw EIP712Error.chainMismatch }

        let encodedType = try typedData.encodeType(typedData.primaryType)
        guard let rule = allowlist.first(where: { rule in
            rule.chain.id == chain.id
                && rule.verifyingContract == verifying
                && rule.primaryType == typedData.primaryType
                && rule.encodedType == encodedType
                && (rule.domainName == nil || rule.domainName == typedData.domainName)
                && (rule.domainVersion == nil || rule.domainVersion == typedData.domainVersion)
        }) else { throw EIP712Error.notAllowlisted }
        try rule.checkMessage(typedData.message, account.address)

        self.chain = chain
        self.account = account
        self.typedData = typedData
        self.digest = try typedData.signingDigest()
    }

    public var signingRequests: [SigningRequest] {
        [SigningRequest(path: account.path, curve: .secp256k1, scheme: .ecdsaRecoverable, payload: digest, expectedPublicKey: account.publicKey)]
    }

    /// `r || s || v` com v = 27 + id de recuperacao, o formato que o
    /// `eth_signTypedData_v4` devolve. O id e o proprio digesto.
    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == 1 else { throw SigningError.wrongSignatureCount }
        let (r, s, recoveryID) = try EVMSignature.check(signatures[0], digest: digest, publicKey: account.publicKey)
        let raw = r + s + [27 + recoveryID]
        return SignedTransaction(chainID: chain.id, raw: raw, encoded: Hex.encode(raw, prefix: true), id: Hex.encode(digest, prefix: true))
    }
}
