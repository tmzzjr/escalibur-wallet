import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

@Suite("EVM: guarda de chamada")
struct EVMGuardTests {
    typealias T = EVMTestSupport

    static let token = T.address("0xdAC17F958D2ee523a2206206994597C13D831ec7")
    static let router = T.address("0x111111125421cA6dc452d289314280a0f8842A65")
    static let stranger = T.address("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
    static let policy = EVMCallPolicy(approvedSpenders: [router], blockedRecipients: [router])

    static func call(_ data: [UInt8], to: EVMAddress? = token, value: BigUInt = 0, type: UInt8 = 2) -> EVMCallProposal {
        EVMCallProposal(transactionType: type, to: to, value: value, data: data)
    }

    static func encode(_ signature: String, _ arguments: [ABIValue]) -> [UInt8] {
        try! ABIFunction(signature).encodeCall(arguments)
    }

    /// Seletores publicados (EIP-20, EIP-2612, DAI, Permit2 e 4byte.directory),
    /// conferidos contra o keccak das assinaturas que a guarda compila.
    @Test("Seletores recusados batem com os publicados")
    func deniedSelectors() throws {
        let expected: [String: String] = [
            "setApprovalForAll(address,bool)": "a22cb465",
            "increaseAllowance(address,uint256)": "39509351",
            "increaseApproval(address,uint256)": "d73dd623",
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)": "d505accf",
            "permit(address,address,uint256,uint256,bool,uint8,bytes32,bytes32)": "8fcbaf0c",
            "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)": "2b67b570",
            "permit(address,((address,uint160,uint48,uint48)[],address,uint256),bytes)": "2a2d80d1",
            "approve(address,address,uint160,uint48)": "87517c45",
        ]
        #expect(EVMCallGuard.deniedSelectors.count == expected.count)
        for (signature, selector) in expected {
            #expect(try ABIFunction(signature).selector.hex == selector, "\(signature)")
            #expect(EVMCallGuard.deniedSelectors[T.bytes(selector)] != nil, "\(signature)")
        }
    }

    @Test("Tipo 4 (EIP-7702), tipos desconhecidos e criacao de contrato sao recusados")
    func transactionTypes() {
        #expect(throws: EVMCallRefusal.eip7702Authorization) { try EVMCallGuard.inspect(Self.call([], type: 4), policy: Self.policy) }
        for type: UInt8 in [1, 3, 5, 0x7f] {
            #expect(throws: EVMCallRefusal.unsupportedTransactionType(type)) { try EVMCallGuard.inspect(Self.call([], type: type), policy: Self.policy) }
        }
        #expect(throws: EVMCallRefusal.contractCreation) { try EVMCallGuard.inspect(Self.call([0x60, 0x80], to: nil), policy: Self.policy) }
        #expect(throws: EVMCallRefusal.contractCreation) { try EVMCallGuard.inspect(Self.call([], to: nil, type: 0), policy: Self.policy) }
    }

    @Test("setApprovalForAll, increaseAllowance e permit: recusa mesmo com spender na allowlist")
    func deniedCalls() {
        let cases: [([UInt8], EVMCallRefusal)] = [
            (Self.encode("setApprovalForAll(address,bool)", [.address(Self.router), .bool(true)]), .setApprovalForAll),
            (Self.encode("increaseAllowance(address,uint256)", [.address(Self.router), .uint(1)]), .increaseAllowance),
            (Self.encode("increaseApproval(address,uint256)", [.address(Self.router), .uint(1)]), .increaseAllowance),
            (Self.encode("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
                         [.address(Self.stranger), .address(Self.router), .uint(1), .uint(1), .uint(27),
                          .fixedBytes([UInt8](repeating: 1, count: 32)), .fixedBytes([UInt8](repeating: 2, count: 32))]), .permit),
            (Self.encode("approve(address,address,uint160,uint48)", [.address(Self.token), .address(Self.router), .uint(1), .uint(1)]), .permit),
        ]
        for (data, refusal) in cases {
            #expect(throws: refusal) { try EVMCallGuard.inspect(Self.call(data), policy: Self.policy) }
            // So o seletor ja basta: argumento malformado nao muda a recusa.
            #expect(throws: refusal) { try EVMCallGuard.inspect(Self.call(Array(data.prefix(4))), policy: Self.policy) }
        }
    }

    @Test("approve: spender da allowlist passa, estranho recusa, revogar vale para qualquer um")
    func approvals() throws {
        let approve = ERC20.approve(spender: Self.router, amount: 5)
        #expect(try EVMCallGuard.inspect(Self.call(approve), policy: Self.policy) == .tokenApproval(token: Self.token, spender: Self.router, amount: 5))
        #expect(throws: EVMCallRefusal.spenderNotAllowed(Self.stranger)) {
            try EVMCallGuard.inspect(Self.call(ERC20.approve(spender: Self.stranger, amount: 5)), policy: Self.policy)
        }
        #expect(throws: EVMCallRefusal.spenderNotAllowed(Self.router)) {
            try EVMCallGuard.inspect(Self.call(approve), policy: EVMCallPolicy())
        }
        #expect(try EVMCallGuard.inspect(Self.call(ERC20.approve(spender: Self.stranger, amount: 0)), policy: EVMCallPolicy())
            == .tokenApproval(token: Self.token, spender: Self.stranger, amount: 0))
        #expect(throws: EVMCallRefusal.valueWithTokenCall) { try EVMCallGuard.inspect(Self.call(approve, value: 1), policy: Self.policy) }
        // Calldata nao canonica (lixo no fim) nao e decodificada.
        #expect(throws: EVMCallRefusal.invalidArguments(.trailingBytes(1))) {
            try EVMCallGuard.inspect(Self.call(approve + [0]), policy: Self.policy)
        }
        var dirty = approve
        dirty[4] = 0xFF
        #expect(throws: EVMCallRefusal.invalidArguments(.dirtyPadding)) { try EVMCallGuard.inspect(Self.call(dirty), policy: Self.policy) }
    }

    @Test("transfer: decodifica, e recusa destino no proprio token, zero ou bloqueado")
    func transfers() throws {
        #expect(try EVMCallGuard.inspect(Self.call(ERC20.transfer(to: Self.stranger, amount: 7)), policy: Self.policy)
            == .tokenTransfer(token: Self.token, to: Self.stranger, amount: 7))
        #expect(throws: EVMCallRefusal.recipientIsTokenContract) {
            try EVMCallGuard.inspect(Self.call(ERC20.transfer(to: Self.token, amount: 7)), policy: Self.policy)
        }
        #expect(throws: EVMCallRefusal.burnAddress) {
            try EVMCallGuard.inspect(Self.call(ERC20.transfer(to: .zero, amount: 7)), policy: Self.policy)
        }
        #expect(throws: EVMCallRefusal.blockedRecipient(Self.router)) {
            try EVMCallGuard.inspect(Self.call(ERC20.transfer(to: Self.router, amount: 7)), policy: Self.policy)
        }
    }

    @Test("Nativo: sem calldata passa; destino zero ou bloqueado recusa")
    func native() throws {
        #expect(try EVMCallGuard.inspect(Self.call([], to: Self.stranger, value: 9, type: 0), policy: Self.policy)
            == .nativeTransfer(to: Self.stranger, amount: 9))
        #expect(throws: EVMCallRefusal.burnAddress) { try EVMCallGuard.inspect(Self.call([], to: .zero, value: 9), policy: Self.policy) }
        #expect(throws: EVMCallRefusal.blockedRecipient(Self.router)) { try EVMCallGuard.inspect(Self.call([], to: Self.router, value: 9), policy: Self.policy) }
    }

    @Test("Seletor desconhecido: sem decodificador, sem assinatura")
    func unknown() {
        let transferFrom = Self.encode("transferFrom(address,address,uint256)", [.address(Self.stranger), .address(Self.router), .uint(1)])
        #expect(throws: EVMCallRefusal.unknownSelector(T.bytes("23b872dd"))) { try EVMCallGuard.inspect(Self.call(transferFrom), policy: Self.policy) }
        // Mesmo para destino que a rede diz nao ter codigo.
        #expect(throws: EVMCallRefusal.unknownSelector([0xde, 0xad, 0xbe, 0xef])) {
            try EVMCallGuard.inspect(Self.call([0xde, 0xad, 0xbe, 0xef], to: Self.stranger), policy: Self.policy)
        }
        #expect(throws: EVMCallRefusal.malformedCalldata) { try EVMCallGuard.inspect(Self.call([0x01, 0x02]), policy: Self.policy) }
    }

    struct WrongReceiver: Error {}

    @Test("Regra de contrato: decodifica estrito e deixa a camada de cima validar")
    func contractRules() throws {
        let swap = try ABIFunction("swap(address,(address,address,address,address,uint256,uint256,uint256),bytes)")
        let owner = Self.stranger
        let rule = EVMContractCallRule(contract: Self.router, function: swap) { arguments, value in
            guard case .tuple(let desc) = arguments[1], desc[3].addressValue == owner, value.isZero else { throw WrongReceiver() }
        }
        let policy = EVMCallPolicy(approvedSpenders: [Self.router], contractRules: [rule])
        func calldata(receiver: EVMAddress) throws -> [UInt8] {
            try swap.encodeCall([
                .address(T.address("0xE37e799D5077682FA0a244D46E5649F71457BD09")),
                .tuple([.address(Self.token), .address(T.address("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48")),
                        .address(T.address("0xE37e799D5077682FA0a244D46E5649F71457BD09")), .address(receiver),
                        .uint(1_000_000), .uint(990_000), .uint(0)]),
                .bytes([0x01, 0x02, 0x03]),
            ])
        }
        let good = try calldata(receiver: owner)
        guard case .contractCall(let contract, let function, _, _) = try EVMCallGuard.inspect(Self.call(good, to: Self.router), policy: policy) else {
            Issue.record("esperava chamada de contrato")
            return
        }
        #expect(contract == Self.router)
        #expect(function == swap.signature)
        #expect(throws: WrongReceiver.self) { try EVMCallGuard.inspect(Self.call(try calldata(receiver: Self.token), to: Self.router), policy: policy) }
        // A mesma calldata para outro contrato nao casa com a regra.
        #expect(throws: EVMCallRefusal.unknownSelector(swap.selector)) { try EVMCallGuard.inspect(Self.call(good, to: Self.token), policy: policy) }
        #expect(throws: EVMCallRefusal.invalidArguments(.trailingBytes(32))) {
            try EVMCallGuard.inspect(Self.call(good + [UInt8](repeating: 0, count: 32), to: Self.router), policy: policy)
        }
    }
}
