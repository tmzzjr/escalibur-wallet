import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

@Suite("EVM: ABI")
struct EVMABITests {
    typealias T = EVMTestSupport

    static func words(_ lines: [String]) -> [UInt8] { lines.flatMap { T.bytes($0) } }

    // MARK: Exemplos da especificacao
    //
    // docs.soliditylang.org, abi-spec (ethereum/solidity, docs/abi-spec.rst), secoes
    // "Examples" e "Use of Dynamic Types". Cada exemplo codifica e decodifica de volta.

    @Test("Especificacao: baz(uint32,bool)")
    func baz() throws {
        let function = try ABIFunction("baz(uint32,bool)")
        #expect(function.selector.hex == "cdcd77c0")
        let calldata = try function.encodeCall([.uint(69), .bool(true)])
        #expect(Hex.encode(calldata, prefix: true) == "0xcdcd77c000000000000000000000000000000000000000000000000000000000000000450000000000000000000000000000000000000000000000000000000000000001")
        #expect(try function.decodeCall(calldata) == [.uint(69), .bool(true)])
    }

    @Test("Especificacao: bar(bytes3[2])")
    func bar() throws {
        let function = try ABIFunction("bar(bytes3[2])")
        #expect(function.selector.hex == "fce353f6")
        let arguments: [ABIValue] = [.array([.fixedBytes(Array("abc".utf8)), .fixedBytes(Array("def".utf8))])]
        let calldata = try function.encodeCall(arguments)
        #expect(Hex.encode(calldata, prefix: true) == "0xfce353f661626300000000000000000000000000000000000000000000000000000000006465660000000000000000000000000000000000000000000000000000000000")
        #expect(try function.decodeCall(calldata) == arguments)
    }

    @Test("Especificacao: sam(bytes,bool,uint[]), com uint canonizado para uint256")
    func sam() throws {
        let function = try ABIFunction("sam(bytes,bool,uint[])")
        #expect(function.signature == "sam(bytes,bool,uint256[])")
        #expect(function.selector.hex == "a5643bf2")
        let arguments: [ABIValue] = [.bytes(Array("dave".utf8)), .bool(true), .array([.uint(1), .uint(2), .uint(3)])]
        let calldata = try function.encodeCall(arguments)
        #expect(Hex.encode(calldata, prefix: true) == "0xa5643bf20000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000464617665000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000003")
        #expect(try function.decodeCall(calldata) == arguments)
    }

    @Test("Especificacao: f(uint256,uint32[],bytes10,bytes)")
    func f() throws {
        let function = try ABIFunction("f(uint256,uint32[],bytes10,bytes)")
        #expect(function.selector.hex == "8be65246")
        let arguments: [ABIValue] = [
            .uint(0x123), .array([.uint(0x456), .uint(0x789)]),
            .fixedBytes(Array("1234567890".utf8)), .bytes(Array("Hello, world!".utf8)),
        ]
        let expected = [0x8b, 0xe6, 0x52, 0x46] + Self.words([
            "0000000000000000000000000000000000000000000000000000000000000123",
            "0000000000000000000000000000000000000000000000000000000000000080",
            "3132333435363738393000000000000000000000000000000000000000000000",
            "00000000000000000000000000000000000000000000000000000000000000e0",
            "0000000000000000000000000000000000000000000000000000000000000002",
            "0000000000000000000000000000000000000000000000000000000000000456",
            "0000000000000000000000000000000000000000000000000000000000000789",
            "000000000000000000000000000000000000000000000000000000000000000d",
            "48656c6c6f2c20776f726c642100000000000000000000000000000000000000",
        ])
        #expect(try function.encodeCall(arguments) == expected)
        #expect(try function.decodeCall(expected) == arguments)
    }

    @Test("Especificacao: g(uint256[][],string[]), dinamicos aninhados")
    func g() throws {
        let function = try ABIFunction("g(uint256[][],string[])")
        #expect(function.selector.hex == "2289b18c")
        let arguments: [ABIValue] = [
            .array([.array([.uint(1), .uint(2)]), .array([.uint(3)])]),
            .array([.string("one"), .string("two"), .string("three")]),
        ]
        let expected = [0x22, 0x89, 0xb1, 0x8c] + Self.words([
            "0000000000000000000000000000000000000000000000000000000000000040",
            "0000000000000000000000000000000000000000000000000000000000000140",
            "0000000000000000000000000000000000000000000000000000000000000002",
            "0000000000000000000000000000000000000000000000000000000000000040",
            "00000000000000000000000000000000000000000000000000000000000000a0",
            "0000000000000000000000000000000000000000000000000000000000000002",
            "0000000000000000000000000000000000000000000000000000000000000001",
            "0000000000000000000000000000000000000000000000000000000000000002",
            "0000000000000000000000000000000000000000000000000000000000000001",
            "0000000000000000000000000000000000000000000000000000000000000003",
            "0000000000000000000000000000000000000000000000000000000000000003",
            "0000000000000000000000000000000000000000000000000000000000000060",
            "00000000000000000000000000000000000000000000000000000000000000a0",
            "00000000000000000000000000000000000000000000000000000000000000e0",
            "0000000000000000000000000000000000000000000000000000000000000003",
            "6f6e650000000000000000000000000000000000000000000000000000000000",
            "0000000000000000000000000000000000000000000000000000000000000003",
            "74776f0000000000000000000000000000000000000000000000000000000000",
            "0000000000000000000000000000000000000000000000000000000000000005",
            "7468726565000000000000000000000000000000000000000000000000000000",
        ])
        #expect(try function.encodeCall(arguments) == expected)
        #expect(try function.decodeCall(expected) == arguments)
    }

    // MARK: Vetores do solc via ethers

    /// ethers-io/ethers.js, testcases/abi.json.gz: para cada tipo aleatorio, um
    /// contrato compilado pelo solc 0.8.13 devolve o valor, e `encoded` e o retorno
    /// cru (abi.encode do valor). Subconjunto de 300 em Fixtures/evm/ethers-abi.json,
    /// com tuplas aninhadas, arrays fixos e dinamicos, int negativo, bytes<N>, string
    /// UTF-8. Conferido nos dois sentidos: decodificar da o valor, codificar da os bytes.
    @Test("300 codificacoes do solc: decodifica, compara o valor e recodifica igual")
    func ethersABIVectors() throws {
        let vectors = try T.vectors("ethers-abi")
        #expect(vectors.count == 300)
        for vector in vectors {
            let name = vector["name"] as! String
            let type = try ABIType(vector["type"] as! String)
            let encoded = T.bytes(vector["encoded"] as! String)
            let expected = try Self.value(vector["verbose"] as! [String: Any], as: type)
            let decoded = try ABI.decode([type], from: encoded)
            #expect(decoded == [expected], "\(name) decodificado")
            #expect(try ABI.encode([expected], types: [type]) == encoded, "\(name) codificado")
        }
    }

    /// O valor "verbose" do ethers como `ABIValue`, guiado pelo tipo.
    static func value(_ verbose: [String: Any], as type: ABIType) throws -> ABIValue {
        let kind = verbose["type"] as! String
        let raw = verbose["value"]
        switch (type, kind) {
        case (.address, "address"):
            return .address(try EVMAddress(raw as! String))
        case (.bool, "boolean"):
            return .bool(raw as! Bool)
        case (.uint, "number"):
            return .uint(BigUInt(decimal: raw as! String)!)
        case (.int, "number"):
            return .int(ABISignedInteger(decimal: raw as! String)!)
        case (.fixedBytes, "hexstring"):
            return .fixedBytes(T.bytes(raw as! String))
        case (.bytes, "hexstring"):
            return .bytes(T.bytes(raw as! String))
        case (.string, "string"):
            return .string(raw as! String)
        case (.array(let element), "array"), (.fixedArray(let element, _), "array"):
            return .array(try (raw as! [[String: Any]]).map { try value($0, as: element) })
        case (.tuple(let components), "object"):
            let items = raw as! [[String: Any]]
            return .tuple(try zip(items, components).map { try value($0, as: $1) })
        default:
            Issue.record("forma inesperada: \(type) \(kind)")
            return .bool(false)
        }
    }

    // MARK: Rigor do decodificador

    static let transferCall: [UInt8] = ERC20.transfer(to: T.address("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"), amount: 1_000_000)

    @Test("Preenchimento sujo e recusado em address, uint, int, bool e bytes<N>")
    func dirtyPadding() throws {
        // address com bit alto
        var data = Array(Self.transferCall.dropFirst(4))
        data[0] = 0x01
        #expect(throws: ABIError.dirtyPadding) { try ABI.decode([.address, .uint256], from: data) }

        // uint8 com valor 256
        let uint8 = T.bytes("0000000000000000000000000000000000000000000000000000000000000100")
        #expect(throws: ABIError.dirtyPadding) { try ABI.decode([.uint(8)], from: uint8) }
        #expect(try ABI.decode([.uint(16)], from: uint8) == [.uint(256)])

        // int8: -1 so com extensao de sinal completa
        let minusOne = [UInt8](repeating: 0xFF, count: 32)
        #expect(try ABI.decode([.int(8)], from: minusOne) == [.int(ABISignedInteger(-1))])
        var brokenSign = minusOne
        brokenSign[0] = 0x7F
        #expect(throws: ABIError.dirtyPadding) { try ABI.decode([.int(8)], from: brokenSign) }
        let positiveOverflow = T.bytes("0000000000000000000000000000000000000000000000000000000000000080")
        #expect(throws: ABIError.dirtyPadding) { try ABI.decode([.int(8)], from: positiveOverflow) }

        // bool 2
        let two = T.bytes("0000000000000000000000000000000000000000000000000000000000000002")
        #expect(throws: ABIError.invalidBool) { try ABI.decode([.bool], from: two) }

        // bytes3 com lixo depois dos 3 bytes
        let bytes3 = T.bytes("6162630000000000000000000000000000000000000000000000000000000001")
        #expect(throws: ABIError.dirtyPadding) { try ABI.decode([.fixedBytes(3)], from: bytes3) }

        // bytes dinamico com lixo no preenchimento do rabo
        var dynamic = try ABI.encode([.bytes(Array("dave".utf8))], types: [.bytes])
        dynamic[dynamic.count - 1] = 0x01
        #expect(throws: ABIError.dirtyPadding) { try ABI.decode([.bytes], from: dynamic) }
    }

    @Test("Offset fora do buffer, para tras, com lacuna ou sobreposto e recusado")
    func offsets() throws {
        let valid = try ABI.encode([.string("one"), .string("two")], types: [.string, .string])
        #expect(try ABI.decode([.string, .string], from: valid) == [.string("one"), .string("two")])

        func with(_ word: Int, _ value: UInt64) -> [UInt8] {
            var data = valid
            let bytes = BigUInt(value).bigEndianBytes(padTo: 32)!
            data.replaceSubrange((word * 32)..<(word * 32 + 32), with: bytes)
            return data
        }
        // Fora do buffer.
        #expect(throws: ABIError.lengthOutOfBounds) { try ABI.decode([.string, .string], from: with(0, 0x10000)) }
        // Enorme (bits altos).
        var huge = valid
        huge[0] = 0x80
        #expect(throws: ABIError.lengthOutOfBounds) { try ABI.decode([.string, .string], from: huge) }
        // Os dois apontando para o mesmo dado (sobreposicao).
        #expect(throws: ABIError.nonCanonicalOffset) { try ABI.decode([.string, .string], from: with(1, 0x40)) }
        // Apontando para dentro da cabeca.
        #expect(throws: ABIError.nonCanonicalOffset) { try ABI.decode([.string, .string], from: with(0, 0x20)) }
        // Nao alinhado.
        #expect(throws: ABIError.nonCanonicalOffset) { try ABI.decode([.string, .string], from: with(0, 0x41)) }
        // Com lacuna: o segundo pula 32 bytes (e o buffer cresce para caber).
        var gap = with(1, 0xa0)
        gap.insert(contentsOf: [UInt8](repeating: 0, count: 32), at: 0x80)
        #expect(throws: ABIError.nonCanonicalOffset) { try ABI.decode([.string, .string], from: gap) }
    }

    @Test("Comprimento maior que o buffer, bytes sobrando e truncamento")
    func lengths() throws {
        var data = try ABI.encode([.bytes(Array("dave".utf8))], types: [.bytes])
        // Comprimento 33 com um so bloco de dados.
        data.replaceSubrange(32..<64, with: BigUInt(33).bigEndianBytes(padTo: 32)!)
        #expect(throws: ABIError.lengthOutOfBounds) { try ABI.decode([.bytes], from: data) }

        // Array que declara 2^20 elementos em 96 bytes: recusa antes de alocar.
        var array = try ABI.encode([.array([.uint(1)])], types: [.array(.uint256)])
        array.replaceSubrange(32..<64, with: BigUInt(1 << 20).bigEndianBytes(padTo: 32)!)
        #expect(throws: ABIError.lengthOutOfBounds) { try ABI.decode([.array(.uint256)], from: array) }

        let transfer = Array(Self.transferCall.dropFirst(4))
        #expect(throws: ABIError.trailingBytes(1)) { try ABI.decode([.address, .uint256], from: transfer + [0]) }
        #expect(throws: ABIError.truncated) { try ABI.decode([.address, .uint256], from: Array(transfer.dropLast())) }
        let prefix = try ABI.decodePrefix([.address, .uint256], from: transfer + [0xde, 0xad])
        #expect(prefix.trailing == [0xde, 0xad])
        #expect(prefix.values.count == 2)
    }

    @Test("UTF-8 invalido em string e recusado")
    func invalidUTF8() throws {
        var data = try ABI.encode([.string("ab")], types: [.string])
        data[64] = 0xC3
        data[65] = 0x28
        #expect(throws: ABIError.invalidUTF8) { try ABI.decode([.string], from: data) }
        // Forma longa de "/" (C0 AF) tambem.
        data[64] = 0xC0
        data[65] = 0xAF
        #expect(throws: ABIError.invalidUTF8) { try ABI.decode([.string], from: data) }
        // Emoji e acento passam.
        let text = "Moo é🚀"
        #expect(try ABI.decode([.string], from: ABI.encode([.string(text)], types: [.string])) == [.string(text)])
    }

    @Test("Codificador recusa valor fora do tipo")
    func encoderRefuses() {
        #expect(throws: ABIError.outOfRange(type: "uint8")) { try ABI.encode([.uint(256)], types: [.uint(8)]) }
        #expect(throws: ABIError.outOfRange(type: "int8")) { try ABI.encode([.int(ABISignedInteger(128))], types: [.int(8)]) }
        #expect(throws: ABIError.outOfRange(type: "int8")) { try ABI.encode([.int(ABISignedInteger(-129))], types: [.int(8)]) }
        #expect(throws: ABIError.wrongLength(type: "bytes3")) { try ABI.encode([.fixedBytes([1, 2])], types: [.fixedBytes(3)]) }
        #expect(throws: ABIError.wrongLength(type: "uint256[2]")) { try ABI.encode([.array([.uint(1)])], types: [.fixedArray(.uint256, 2)]) }
        #expect(throws: ABIError.typeMismatch(expected: "address")) { try ABI.encode([.uint(1)], types: [.address]) }
        #expect(throws: ABIError.invalidType("uint7")) { try ABI.encode([.uint(1)], types: [.uint(7)]) }
    }

    @Test("Texto de tipo: canonico, sinonimos e recusas")
    func typeParser() throws {
        #expect(try ABIType("uint").description == "uint256")
        #expect(try ABIType("(address,(uint,bytes32)[2])[]").description == "(address,(uint256,bytes32)[2])[]")
        #expect(try ABIType("bytes32[2][]") == .array(.fixedArray(.fixedBytes(32), 2)))
        for invalid in ["uint7", "uint264", "uint08", "bytes0", "bytes33", "()", "(uint256", "uint256[0]", "uint256[01]",
                        "tuple", "fixed128x18", "address payable", "(uint256,)", "Uint256", "uint256[]x", "function"] {
            #expect(throws: ABIError.self, "\(invalid)") { try ABIType(invalid) }
        }
        let deep = String(repeating: "(", count: 40) + "uint256" + String(repeating: ")", count: 40)
        #expect(throws: ABIError.self) { try ABIType(deep) }
        #expect(throws: ABIError.self) { try ABIFunction("transfer (address,uint256)") }
        #expect(throws: ABIError.self) { try ABIFunction("1transfer(address)") }
        #expect(try ABIFunction("noArgs()").encodeCall([]) == ABIFunction("noArgs()").selector)
    }

    @Test("int<N> no limite, em complemento de dois")
    func signedBoundaries() throws {
        let min256 = ABISignedInteger(magnitude: BigUInt(1).shiftedLeft(by: 255), negative: true)
        let encoded = try ABI.encode([.int(min256)], types: [.int(256)])
        #expect(encoded.hex == "8000000000000000000000000000000000000000000000000000000000000000")
        #expect(try ABI.decode([.int(256)], from: encoded) == [.int(min256)])
        #expect(try ABI.encode([.int(ABISignedInteger(-128))], types: [.int(8)]).hex == "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff80")
        #expect(ABISignedInteger(decimal: "-0") == ABISignedInteger(0))
    }

    // MARK: ERC-20

    /// Seletores conhecidos (EIP-20 e 4byte.directory), conferidos contra o keccak
    /// da assinatura calculado aqui.
    @Test("ERC-20: seletores, calldata e respostas")
    func erc20() throws {
        #expect(ERC20.transferFunction.selector.hex == "a9059cbb")
        #expect(ERC20.approveFunction.selector.hex == "095ea7b3")
        #expect(ERC20.balanceOfFunction.selector.hex == "70a08231")
        #expect(ERC20.allowanceFunction.selector.hex == "dd62ed3e")
        #expect(ERC20.decimalsFunction.selector.hex == "313ce567")
        #expect(ERC20.decimals().hex == "313ce567")

        let owner = T.address("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
        let spender = T.address("0x111111125421cA6dc452d289314280a0f8842A65")
        #expect(ERC20.transfer(to: owner, amount: 1_000_000).hex ==
            "a9059cbb0000000000000000000000005aaeb6053f3e94c9b9a09f33669435e7ef1beaed00000000000000000000000000000000000000000000000000000000000f4240")
        #expect(ERC20.approve(spender: spender, amount: 0).hex ==
            "095ea7b3000000000000000000000000111111125421ca6dc452d289314280a0f8842a650000000000000000000000000000000000000000000000000000000000000000")
        #expect(ERC20.balanceOf(owner: owner).hex == "70a082310000000000000000000000005aaeb6053f3e94c9b9a09f33669435e7ef1beaed")
        #expect(ERC20.allowance(owner: owner, spender: spender).hex ==
            "dd62ed3e0000000000000000000000005aaeb6053f3e94c9b9a09f33669435e7ef1beaed000000000000000000000000111111125421ca6dc452d289314280a0f8842a65")

        #expect(try ERC20.decodeUInt256(T.bytes("00000000000000000000000000000000000000000000000000000000000f4240")) == 1_000_000)
        #expect(try ERC20.decodeUInt256([UInt8](repeating: 0xFF, count: 32)) == .uint256Max)
        #expect(throws: ABIError.truncated) { try ERC20.decodeUInt256([]) }
        #expect(throws: ABIError.trailingBytes(32)) { try ERC20.decodeUInt256([UInt8](repeating: 0, count: 64)) }
        #expect(try ERC20.decodeDecimals(T.bytes("0000000000000000000000000000000000000000000000000000000000000006")) == 6)
        #expect(throws: ABIError.dirtyPadding) {
            try ERC20.decodeDecimals(T.bytes("0000000000000000000000000000000000000000000000000000000000000100"))
        }
    }
}
