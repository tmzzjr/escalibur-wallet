import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

@Suite("EVM: endereco EIP-55 e URI EIP-681")
struct EVMAddressAndURITests {
    typealias T = EVMTestSupport

    /// Os vetores da propria EIP-55 (ethereum/ERCs, ERCS/erc-55.md, "Test Cases").
    @Test("EIP-55: vetores da EIP")
    func eip55() throws {
        let vectors = [
            "0x52908400098527886E0F7030069857D2E4169EE7", "0x8617E340B3D01FA5F11F306F4090FD50E238070D",
            "0xde709f2102306220921060314715629080e2fb77", "0x27b1fdb04752bbc536007a920d24acb045561c26",
            "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
            "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB", "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
        ]
        for text in vectors {
            let address = try EVMAddress(text)
            #expect(address.checksummed == text, "\(text)")
            #expect(try EVMAddress(text.lowercased()) == address)
        }
        // Uma letra com a caixa trocada quebra o checksum.
        #expect(throws: Address.Problem.badChecksum) { try EVMAddress("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD") }
        #expect(throws: Address.Problem.malformed) { try EVMAddress("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAe") }
        #expect(throws: Address.Problem.malformed) { try EVMAddress("5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed") }
        // O endereco da chave do exemplo da EIP-155.
        #expect(try T.account(T.testKey).address.checksummed == "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F")
    }

    /// Exemplos do texto da ERC-681 (ethereum/ERCs, ERCS/erc-681.md, "Semantics").
    @Test("EIP-681: exemplos da ERC, com o checksum conferido")
    func eip681Examples() throws {
        // O exemplo da ERC escreve o endereco em caixa mista com o checksum errado
        // (0xfb6916095ca1df60bb79Ce92ce3ea74c37c5d359). A carteira recusa: caixa mista
        // que nao fecha o EIP-55 e endereco adulterado ou digitado errado.
        #expect(throws: EIP681Request.Problem.invalidAddress(.badChecksum)) {
            try EIP681Request.parse("ethereum:0xfb6916095ca1df60bb79Ce92ce3ea74c37c5d359?value=2.014e18")
        }
        let native = try EIP681Request.parse("ethereum:0xfb6916095ca1df60bb79ce92ce3ea74c37c5d359?value=2.014e18")
        #expect(native.chain == nil)
        #expect(native.payment == .native(recipient: T.address("0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"), amount: BigUInt(decimal: "2014000000000000000")!))

        let token = try EIP681Request.parse("ethereum:0x89205a3a3b2a69de6dbf7f01ed13b2108b2c43e7/transfer?address=0x8e23ee67d1332ad560396262c48ffbb01f93d052&uint256=1")
        #expect(token.payment == .token(contract: try EVMAddress("0x89205a3a3b2a69de6dbf7f01ed13b2108b2c43e7"),
                                        recipient: try EVMAddress("0x8e23ee67d1332ad560396262c48ffbb01f93d052"), amount: 1))
    }

    @Test("EIP-681: rede, prefixo pay-, gas descartado")
    func eip681Variants() throws {
        let usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        let to = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
        let request = try EIP681Request.parse("ethereum:pay-\(usdc)@8453/transfer?address=\(to)&uint256=1.5e6&gas=100000")
        #expect(request.chain == .base)
        #expect(request.payment == .token(contract: T.address(usdc), recipient: T.address(to), amount: BigUInt(1_500_000)))
        #expect(try EIP681Request.parse("ethereum:\(to)@137").chain == .polygon)
        #expect(try EIP681Request.parse("ethereum:\(to)").payment == .native(recipient: T.address(to), amount: nil))
        #expect(try EIP681Request.parse("ETHEREUM:\(to)?value=0").payment == .native(recipient: T.address(to), amount: 0))
        #expect(try EIP681Request.parse("ethereum:\(to)?value=1e18&gasPrice=2e10&gasLimit=21000").payment
            == .native(recipient: T.address(to), amount: BigUInt(decimal: "1000000000000000000")!))
    }

    @Test("EIP-681: recusas")
    func eip681Refusals() {
        let to = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
        let cases: [(String, EIP681Request.Problem)] = [
            ("bitcoin:\(to)", .notEthereumURI),
            ("ethereum:vitalik.eth?value=1", .ensNotSupported),
            ("ethereum:\(to)@5", .unsupportedChain("5")),
            ("ethereum:\(to)@01", .invalidChainID),
            ("ethereum:\(to)@", .invalidChainID),
            ("ethereum:\(to)/approve?address=\(to)&uint256=1", .unsupportedFunction("approve")),
            ("ethereum:\(to)?value=1.5", .invalidNumber("1.5")),
            ("ethereum:\(to)?value=1e-3", .invalidNumber("1e-3")),
            ("ethereum:\(to)?value=-1", .invalidNumber("-1")),
            ("ethereum:\(to)?value=+1", .invalidNumber("+1")),
            ("ethereum:\(to)?value=.5e18", .invalidNumber(".5e18")),
            ("ethereum:\(to)?value=1e", .invalidNumber("1e")),
            ("ethereum:\(to)?value=2e78", .invalidNumber("2e78")),
            ("ethereum:\(to)?value=1&value=2", .duplicateParameter("value")),
            ("ethereum:\(to)?amount=1", .unknownParameter("amount")),
            ("ethereum:\(to)?value=", .invalidParameter("value=")),
            ("ethereum:\(to)?value=1%30", .invalidParameter("%")),
            ("ethereum:\(to)/transfer?uint256=1", .missingParameter("address")),
            ("ethereum:\(to)/transfer?address=\(to)&uint256=1&value=1", .valueWithTokenTransfer),
            ("ethereum:\(to)/transfer?address=\(to)&uint256=1&data=0x", .unknownParameter("data")),
            ("ethereum:0x1234", .invalidAddress(.malformed)),
            ("ethereum:\(to)x", .invalidAddress(.malformed)),
        ]
        for (uri, problem) in cases {
            #expect(throws: problem, "\(uri)") { try EIP681Request.parse(uri) }
        }
    }
}
