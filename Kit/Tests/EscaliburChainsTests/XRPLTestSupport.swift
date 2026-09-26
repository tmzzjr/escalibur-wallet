import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

/// Apoio dos testes do XRP Ledger: leitura das fixtures oficiais, um codificador de
/// JSON para `XRPLObject` (so para os vetores; a carteira de verdade monta por tipo) e
/// a derivacao de family seed do ripple-keypairs, para assinar com as chaves dos
/// testes do xrpl.js. Nada disto existe no codigo de producao.
enum XRPLFixtures {
    static func json(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/xrpl"))
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A copia de `definitions.json` guardada em Fixtures/xrpl (subconjunto).
    nonisolated(unsafe) static let definitions: [String: Any] = try! json("definitions")

    static var typeCodes: [String: Int] { definitions["TYPES"] as! [String: Int] }

    /// Todos os campos do subconjunto, montados a partir do definitions.json oficial.
    /// Os que a carteira compila vem da tabela dela (e o teste de definicoes confere
    /// que sao iguais); os outros (campos de objetos do ledger usados pelos vetores)
    /// nascem aqui, so para o teste.
    static let fields: [String: XRPLField] = {
        var out = [String: XRPLField]()
        let compiled = Dictionary(uniqueKeysWithValues: XRPLField.all.map { ($0.name, $0) })
        for entry in definitions["FIELDS"] as! [[Any]] {
            let name = entry[0] as! String
            let info = entry[1] as! [String: Any]
            if let field = compiled[name] {
                out[name] = field
                continue
            }
            let code = UInt16(typeCodes[info["type"] as! String]!)
            guard let type = XRPLType(rawValue: code) else { continue }
            out[name] = XRPLField(
                name, type, UInt16(info["nth"] as! Int),
                vl: info["isVLEncoded"] as! Bool, serialized: info["isSerialized"] as! Bool,
                signing: info["isSigningField"] as! Bool
            )
        }
        return out
    }()

    enum EncodeError: Error { case unknownField(String), badValue(String) }

    /// JSON do rippled para `XRPLObject`, com as convencoes do ripple-binary-codec:
    /// UInt64 em hex, Hash e Blob em hex, conta em r..., nomes de tipo por extenso.
    static func object(_ json: [String: Any]) throws -> XRPLObject {
        var object = XRPLObject()
        for (name, raw) in json {
            guard let field = fields[name] else { throw EncodeError.unknownField(name) }
            try object.set(field, value(raw, field: field))
        }
        return object
    }

    static func value(_ raw: Any, field: XRPLField) throws -> XRPLValue {
        func hex(_ any: Any) throws -> [UInt8] {
            guard let text = any as? String, let bytes = Hex.decode(text) else { throw EncodeError.badValue(field.name) }
            return bytes
        }
        func number(_ any: Any) throws -> UInt64 {
            guard let n = any as? NSNumber else { throw EncodeError.badValue(field.name) }
            return n.uint64Value
        }
        switch field.type {
        case .uint8: return .uint8(UInt8(try number(raw)))
        case .uint16:
            if let name = raw as? String {
                let table = field.name == "TransactionType" ? "TRANSACTION_TYPES" : "LEDGER_ENTRY_TYPES"
                guard let code = (definitions[table] as? [String: Int])?[name] else { throw EncodeError.badValue(name) }
                return .uint16(UInt16(code))
            }
            return .uint16(UInt16(try number(raw)))
        case .uint32: return .uint32(UInt32(try number(raw)))
        case .uint64:
            guard let text = raw as? String, let v = UInt64(text, radix: 16) else { throw EncodeError.badValue(field.name) }
            return .uint64(v)
        case .hash128: return .hash128(try hex(raw))
        case .hash160: return .hash160(try hex(raw))
        case .hash256: return .hash256(try hex(raw))
        case .blob: return .blob(try hex(raw))
        case .accountID:
            guard let text = raw as? String, let id = XRPLAddress.accountID(text) else { throw EncodeError.badValue(field.name) }
            return .accountID(id)
        case .amount: return .amount(try XRPLAmount.fromJSON(raw))
        case .stObject:
            return .object(try object(raw as! [String: Any]))
        case .stArray:
            var elements = [XRPLArrayElement]()
            for item in raw as! [[String: Any]] {
                let (name, inner) = item.first!
                guard let innerField = fields[name] else { throw EncodeError.unknownField(name) }
                elements.append(XRPLArrayElement(innerField, try object(inner as! [String: Any])))
            }
            return .array(elements)
        case .pathSet:
            let paths = try (raw as! [[[String: Any]]]).map { path in
                try path.map { step in
                    XRPLPathStep(
                        account: try (step["account"] as? String).map { try #require(XRPLAddress.accountID($0)) },
                        currency: try (step["currency"] as? String).map {
                            $0 == "XRP" ? [UInt8](repeating: 0, count: 20) : try XRPLCurrency(ledgerCode: $0).bytes
                        },
                        issuer: try (step["issuer"] as? String).map { try #require(XRPLAddress.accountID($0)) }
                    )
                }
            }
            return .pathSet(paths)
        }
    }

    static func hex(_ bytes: [UInt8]) -> String { Hex.encode(bytes).uppercased() }
}

/// Chaves de teste.
enum XRPLTestKeys {
    /// Family seed secp256k1 do ripple-keypairs (src/index.ts, deriveScalar e
    /// derivePrivateKey): raiz = SHA512Half(seed ‖ i) ate dar escalar valido; conta =
    /// raiz + SHA512Half(pubRaiz ‖ 0 ‖ i) mod n. So para usar as chaves dos testes do
    /// xrpl.js; a carteira nao importa family seed na v1.
    static func privateKey(familySeed: String) throws -> SecureBytes {
        let payload = try #require(Base58.ripple.decodeCheck(familySeed))
        #expect(payload.count == 17 && payload[0] == 0x21)
        let seed = Array(payload.dropFirst())
        let root = try scalar(seed)
        let rootPublic = try Secp256k1.publicKey(of: root)
        let intermediate = try scalar(rootPublic + UInt32(0).bigEndianByteArray)
        try intermediate.withUnsafeBytes { try Secp256k1.tweakAdd(privateKey: root, tweak: $0) }
        return root
    }

    private static func scalar(_ bytes: [UInt8]) throws -> SecureBytes {
        for i in UInt32(0)...UInt32.max {
            let candidate = secure(Hash.sha512Half(bytes + i.bigEndianByteArray))
            if Secp256k1.isValidPrivateKey(candidate) { return candidate }
        }
        throw Secp256k1.Failure.invalidPrivateKey
    }

    static func secure(_ bytes: [UInt8]) -> SecureBytes {
        let out = SecureBytes(capacity: bytes.count)
        out.replaceAll(with: bytes)
        return out
    }

    static func hex(_ key: SecureBytes) -> String {
        key.withUnsafeBytes { Hex.encode($0).uppercased() }
    }

    /// Chave do teste do xrpl.js (sh1HiK7SwjS1VxFdXi7qeMHRedrYX), usada nos testes de
    /// planejamento para assinar de ponta a ponta.
    static let plannerKey = secure(Array(hex: "B6FE8507D977E46E988A8A94DB3B8B35E404B60F8B11AC5213FA8B5ABC8A8D19")!)

    static func signer(_ key: SecureBytes = plannerKey) throws -> XRPLSigner {
        try XRPLSigner(path: DefaultPaths.path(for: .xrpl), publicKey: Secp256k1.publicKey(of: key))
    }

    /// O que o assinador de EscaliburKeys faz, em miniatura: assina cada pedido.
    static func sign(_ transaction: some SignableTransaction, with key: SecureBytes = plannerKey) throws -> SignedTransaction {
        let signatures = try transaction.signingRequests.map { request in
            #expect(request.expectedPublicKey == (try Secp256k1.publicKey(of: key)))
            return ProducedSignature(bytes: try Secp256k1.signDER(digest: request.payload, privateKey: key))
        }
        return try transaction.assemble(with: signatures)
    }
}
