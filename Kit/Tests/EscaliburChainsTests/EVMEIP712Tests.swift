import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

@Suite("EVM: EIP-712")
struct EVMEIP712Tests {
    typealias T = EVMTestSupport

    /// O exemplo "Mail" da EIP-712, no formato do eth_signTypedData_v4 (EIPS/eip-712.md,
    /// secao "eth_signTypedData", e assets/eip-712/Example.js).
    static let mailJSON = """
    {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"Person":[{"name":"name","type":"string"},{"name":"wallet","type":"address"}],"Mail":[{"name":"from","type":"Person"},{"name":"to","type":"Person"},{"name":"contents","type":"string"}]},"primaryType":"Mail","domain":{"name":"Ether Mail","version":"1","chainId":1,"verifyingContract":"0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"},"message":{"from":{"name":"Cow","wallet":"0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},"to":{"name":"Bob","wallet":"0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},"contents":"Hello, Bob!"}}
    """

    /// A chave do exemplo: keccak256("cow").
    static var cowKey: String { Hash.keccak256(Array("cow".utf8)).hex }

    @Test("Exemplo Mail da EIP: encodeType, typeHash, encodeData, separador, digesto e assinatura v = 28")
    func mail() throws {
        let data = try EIP712TypedData(json: Self.mailJSON)
        // Valores do Example.js da EIP.
        #expect(try data.encodeType("Mail") == "Mail(Person from,Person to,string contents)Person(string name,address wallet)")
        #expect(try data.typeHash("Mail").hex == "a0cedeb2dc280ba39b857546d74f5549c3a1d7bdc2dd96bf881f76108e23dac2")
        #expect(try data.encodeData("Mail", data.message).hex == "a0cedeb2dc280ba39b857546d74f5549c3a1d7bdc2dd96bf881f76108e23dac2fc71e5fa27ff56c350aa531bc129ebdf613b772b6604664f5d8dbe21b85eb0c8cd54f074a4af31b4411ff6a60c9719dbd559c221c8ac3492d9d872b041d703d1b5aadf3154a261abdd9086fc627b61efca26ae5702701d05cd2305f7c52a2fc8")
        #expect(try data.hashStruct("Mail", data.message).hex == "c52c0ee5d84264471806290a3f2c4cecfc5490626bf912d01f240d7a274b371e")
        #expect(try data.domainSeparator().hex == "f2cee375fa42b42143804025fc449deafd50cc031ca257e0b194a650a912090f")
        #expect(try data.signingDigest().hex == "be609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2")

        let account = try T.account(Self.cowKey)
        #expect(account.address == T.address("0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"))
        let signature = try T.sign(try data.signingDigest(), key: Self.cowKey)
        #expect(signature.recoveryID == 1)  // v = 28
        #expect(Array(signature.bytes.prefix(32)).hex == "4355c47d63924e8a72e509b65029052eb6c299d53a04e167c5775fd466751c9d")
        #expect(Array(signature.bytes.suffix(32)).hex == "07299936d304c153f6443dfa05f40ff007d72911b6f72307f996231605b91562")
    }

    /// ethers-io/ethers.js, testcases/typed-data.json.gz: 130 mensagens (inclui o
    /// "Mail" e "Boundary values" de int/uint no limite), com arrays fixos e dinamicos,
    /// arrays de arrays, structs aninhados e dominios com qualquer subconjunto dos cinco
    /// campos. Confere encodeData da mensagem e o digesto final.
    @Test("130 mensagens tipadas do ethers: encodeData e digesto")
    func ethersTypedData() throws {
        let vectors = try T.vectors("ethers-typed-data")
        #expect(vectors.count == 130)
        for vector in vectors {
            let name = vector["name"] as! String
            let data = try EIP712TypedData(json: vector["typedData"] as! String)
            #expect(Hex.encode(try data.encodeData(data.primaryType, data.message), prefix: true) == vector["encoded"] as? String, "\(name) encodeData")
            #expect(Hex.encode(try data.signingDigest(), prefix: true) == vector["digest"] as? String, "\(name) digesto")
        }
    }

    static func mail(_ edit: (inout String) -> Void) -> String {
        var text = mailJSON
        edit(&text)
        return text
    }

    @Test("Rigor: campo a mais ou a menos, numero nao inteiro, chave duplicada, tipos invalidos")
    func strictness() throws {
        func refuses(_ text: String, _ comment: Comment) {
            #expect(throws: (any Error).self, comment) { try EIP712TypedData(json: text) }
        }
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: #""contents":"Hello, Bob!""#, with: #""contents":"Hello, Bob!","extra":1"#) }, "campo a mais")
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: #","contents":"Hello, Bob!""#, with: "") }, "campo a menos")
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: #""chainId":1"#, with: #""chainId":1.0"#) }, "numero com fracao")
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: #""chainId":1"#, with: #""chainId":1e0"#) }, "numero com expoente")
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: #""chainId":1"#, with: #""chainId":1,"chainId":2"#) }, "chave duplicada")
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: #""chainId":1"#, with: #""chainId":null"#) }, "null")
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB", with: "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbb") }, "checksum errado")
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: #""type":"Person"},{"name":"to""#, with: #""type":"Persona"},{"name":"to""#) }, "tipo desconhecido")
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: #""name":"Ether Mail","#, with: #""name":"Ether Mail","extra":"x","#) }, "dominio com campo fora da EIP")
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: #"{"name":"name","type":"string"},{"name":"version","type":"string"}"#, with: #"{"name":"version","type":"string"},{"name":"name","type":"string"}"#) }, "dominio fora de ordem")
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: "\"Person\"", with: "\"uint256\"") }, "struct com nome de tipo ABI")
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: #""type":"string"}]},"primaryType""#, with: #""type":"uint"}]},"primaryType""#) }, "uint sem largura")
        refuses(Self.mail { $0 += " x" }, "lixo depois do JSON")
        refuses(Self.mail { $0 = $0.replacingOccurrences(of: #""primaryType":"Mail""#, with: #""primaryType":"EIP712Domain""#) }, "primaryType de dominio")

        // Tipo vindo de fora nao estoura a pilha: aninhamento de array tem teto.
        let deep = "uint8" + String(repeating: "[]", count: 40)
        #expect(throws: EIP712Error.tooDeep) {
            try EIP712TypedData(types: ["Deep": [.init(name: "x", type: deep)]], primaryType: "Deep", domain: [:], message: ["x": .array([])])
        }

        // bytes e bytes<N>: so hex com 0x, e bytes<N> com N bytes exatos.
        let types: [String: [EIP712TypedData.Field]] = ["Blob": [.init(name: "tag", type: "bytes4"), .init(name: "body", type: "bytes"), .init(name: "list", type: "uint8[2]")]]
        func blob(_ tag: String, _ body: String, _ list: [EIP712Value]) throws -> EIP712TypedData {
            try EIP712TypedData(types: types, primaryType: "Blob", domain: ["chainId": .number("1")],
                                message: ["tag": .string(tag), "body": .string(body), "list": .array(list)])
        }
        _ = try blob("0x01020304", "0xdead", [.number("1"), .string("0x02")])
        #expect(throws: (any Error).self) { try blob("0x010203", "0xdead", [.number("1"), .number("2")]) }
        #expect(throws: (any Error).self) { try blob("0x01020304", "dead", [.number("1"), .number("2")]) }
        #expect(throws: (any Error).self) { try blob("0x01020304", "0xdead", [.number("1")]) }
        #expect(throws: (any Error).self) { try blob("0x01020304", "0xdead", [.number("1"), .number("256")]) }
        #expect(throws: (any Error).self) { try blob("0x01020304", "0xdead", [.number("-1"), .number("2")]) }
    }

    // MARK: Mensagem validada

    static let mailContract = T.address("0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC")

    static func mailRule(chain: Chain = .ethereum, contract: EVMAddress = mailContract, name: String? = "Ether Mail",
                         check: @escaping @Sendable ([String: EIP712Value], EVMAddress) throws -> Void = { _, _ in }) -> EIP712Rule {
        EIP712Rule(
            chain: chain, verifyingContract: contract, primaryType: "Mail",
            encodedType: "Mail(Person from,Person to,string contents)Person(string name,address wallet)",
            domainName: name, domainVersion: "1", checkMessage: check
        )
    }

    struct NotOwner: Error {}

    @Test("Mensagem validada: aceita so o que a allowlist descreve, e monta r || s || v")
    func validated() throws {
        let data = try EIP712TypedData(json: Self.mailJSON)
        let account = try T.account(Self.cowKey)
        // O remetente precisa ser o dono: a regra confere o conteudo.
        let ownerIsSender: @Sendable ([String: EIP712Value], EVMAddress) throws -> Void = { message, owner in
            guard case .object(let from)? = message["from"], case .string(let wallet)? = from["wallet"],
                  (try? EVMAddress(wallet)) == owner
            else { throw NotOwner() }
        }
        let message = try EIP712ValidatedMessage(data, chain: .ethereum, account: account, allowlist: [Self.mailRule(check: ownerIsSender)])
        #expect(message.digest.hex == "be609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2")
        #expect(message.signingRequests.first?.payload == message.digest)
        let signed = try message.assemble(with: [T.sign(message.digest, key: Self.cowKey)])
        #expect(signed.encoded == "0x4355c47d63924e8a72e509b65029052eb6c299d53a04e167c5775fd466751c9d07299936d304c153f6443dfa05f40ff007d72911b6f72307f996231605b915621c")

        // Outra conta: a regra recusa.
        let other = try T.account(T.testKey)
        #expect(throws: NotOwner.self) {
            try EIP712ValidatedMessage(data, chain: .ethereum, account: other, allowlist: [Self.mailRule(check: ownerIsSender)])
        }
        // Rede do dominio (1) diferente da rede do plano.
        #expect(throws: EIP712Error.chainMismatch) {
            try EIP712ValidatedMessage(data, chain: .base, account: account, allowlist: [Self.mailRule(chain: .base)])
        }
        // Allowlist vazia, contrato diferente, nome diferente, estrutura diferente.
        #expect(throws: EIP712Error.notAllowlisted) { try EIP712ValidatedMessage(data, chain: .ethereum, account: account, allowlist: []) }
        #expect(throws: EIP712Error.notAllowlisted) {
            try EIP712ValidatedMessage(data, chain: .ethereum, account: account,
                                       allowlist: [Self.mailRule(contract: T.address("0x1111111111111111111111111111111111111111"))])
        }
        #expect(throws: EIP712Error.notAllowlisted) {
            try EIP712ValidatedMessage(data, chain: .ethereum, account: account, allowlist: [Self.mailRule(name: "Other Mail")])
        }
        let reshaped = try EIP712TypedData(json: Self.mail {
            $0 = $0.replacingOccurrences(of: #"{"name":"contents","type":"string"}"#, with: #"{"name":"contents","type":"string"},{"name":"note","type":"string"}"#)
            $0 = $0.replacingOccurrences(of: #""contents":"Hello, Bob!""#, with: #""contents":"Hello, Bob!","note":"x""#)
        })
        #expect(throws: EIP712Error.notAllowlisted) {
            try EIP712ValidatedMessage(reshaped, chain: .ethereum, account: account, allowlist: [Self.mailRule()])
        }
        // Sem chainId ou sem verifyingContract no dominio.
        let noChain = try EIP712TypedData(json: Self.mail {
            $0 = $0.replacingOccurrences(of: #",{"name":"chainId","type":"uint256"}"#, with: "")
            $0 = $0.replacingOccurrences(of: #""chainId":1,"#, with: "")
        })
        #expect(throws: EIP712Error.missingChainID) {
            try EIP712ValidatedMessage(noChain, chain: .ethereum, account: account, allowlist: [Self.mailRule()])
        }
    }

    @Test("Permit, Permit2 e parentes sao recusados mesmo na allowlist")
    func permitForbidden() throws {
        let account = try T.account(T.testKey)
        // EIP-2612, com o dominio do USDC na Ethereum.
        let permit = """
        {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"Permit":[{"name":"owner","type":"address"},{"name":"spender","type":"address"},{"name":"value","type":"uint256"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}]},"primaryType":"Permit","domain":{"name":"USD Coin","version":"2","chainId":1,"verifyingContract":"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"},"message":{"owner":"0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f","spender":"0x111111125421cA6dc452d289314280a0f8842A65","value":"115792089237316195423570985008687907853269984665640564039457584007913129639935","nonce":0,"deadline":"1999999999"}}
        """
        let data = try EIP712TypedData(json: permit)
        let rule = EIP712Rule(
            chain: .ethereum, verifyingContract: T.address("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"), primaryType: "Permit",
            encodedType: try data.encodeType("Permit"), domainName: nil, domainVersion: nil, checkMessage: { _, _ in }
        )
        #expect(throws: EIP712Error.permitForbidden) { try EIP712ValidatedMessage(data, chain: .ethereum, account: account, allowlist: [rule]) }

        // Qualquer tipo com o Permit2 como contrato verificador.
        let viaPermit2 = try EIP712TypedData(json: Self.mail {
            $0 = $0.replacingOccurrences(of: "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC", with: "0x000000000022D473030F116dDEE9F6B43aC78BA3")
        })
        #expect(throws: EIP712Error.permitForbidden) {
            try EIP712ValidatedMessage(viaPermit2, chain: .ethereum, account: account,
                                       allowlist: [Self.mailRule(contract: EIP712ValidatedMessage.permit2)])
        }
    }
}
