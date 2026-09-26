import EscaliburCore
import Foundation

// A guarda de chamada: toda transacao EVM passa por aqui antes de virar plano.
//
// Ela decodifica a calldata e so deixa passar o que sabe ler por inteiro. A regra e
// a de docs/seguranca.md 4.3: **sem decodificador, sem assinatura.** O que a
// carteira nao entende nao vai para a tela como "dados hex" para o dono aprovar as
// cegas; e recusado.
//
// Recusado sempre, antes de qualquer allowlist:
// - tipo 4 (EIP-7702): delega a conta inteira a um contrato; com chainId 0 vale em
//   todas as redes de uma vez. Numa amostra, 63% das autorizacoes eram de drainer.
// - `setApprovalForAll`: entrega todos os NFTs de uma colecao.
// - `increaseAllowance`/`increaseApproval`: approve disfarcado, fora do fluxo de
//   valor exato.
// - `permit` (EIP-2612, DAI, Permit2): permissao que o dono nao ve virar gasto.
// - criacao de contrato (sem destino).
// - calldata que nenhum decodificador reconhece.

public enum EVMCallRefusal: Error, Equatable, Sendable {
    case eip7702Authorization
    case unsupportedTransactionType(UInt8)
    case contractCreation
    case malformedCalldata
    case setApprovalForAll
    case increaseAllowance
    case permit
    case spenderNotAllowed(EVMAddress)
    /// Seletor sem decodificador conhecido para aquele destino.
    case unknownSelector([UInt8])
    /// Valor nativo junto de uma chamada ERC-20 (que nao e payable).
    case valueWithTokenCall
    /// `transfer` para o proprio contrato do token: o token fica preso para sempre.
    case recipientIsTokenContract
    /// Destino 0x000...000.
    case burnAddress
    /// Destino que a politica bloqueia (router, contrato de token conhecido).
    case blockedRecipient(EVMAddress)
    /// Os argumentos nao decodificam de forma canonica.
    case invalidArguments(ABIError)
    /// A regra da chamada de contrato recusou o conteudo.
    case ruleRejected(String)
}

/// A transacao como proposta: o tipo cru, destino, valor e calldata. Pode vir de um
/// `EVMTransaction` montado aqui ou da resposta de um provedor.
public struct EVMCallProposal: Sendable, Equatable {
    public let transactionType: UInt8
    /// `nil` e criacao de contrato.
    public let to: EVMAddress?
    public let value: BigUInt
    public let data: [UInt8]

    public init(transactionType: UInt8, to: EVMAddress?, value: BigUInt, data: [UInt8]) {
        self.transactionType = transactionType
        self.to = to
        self.value = value
        self.data = data
    }

    public init(_ transaction: EVMTransaction) {
        self.init(transactionType: transaction.transactionType, to: transaction.to, value: transaction.value, data: transaction.data)
    }
}

/// Uma chamada de contrato que a camada de cima sabe decodificar e validar (router
/// de swap, por exemplo). A funcao fixa o seletor e os tipos; `validate` confere os
/// argumentos decodificados contra a intencao do dono e lanca para recusar.
public struct EVMContractCallRule: Sendable {
    public let contract: EVMAddress
    public let function: ABIFunction
    public let validate: @Sendable (_ arguments: [ABIValue], _ value: BigUInt) throws -> Void

    public init(contract: EVMAddress, function: ABIFunction, validate: @escaping @Sendable (_ arguments: [ABIValue], _ value: BigUInt) throws -> Void) {
        self.contract = contract
        self.function = function
        self.validate = validate
    }
}

/// O que a guarda aceita alem do basico. Tudo vem de quem chama, compilado.
public struct EVMCallPolicy: Sendable {
    /// Spenders que podem receber approve de valor diferente de zero.
    public var approvedSpenders: Set<EVMAddress>
    /// Destinos que nunca recebem valor nem token: routers, contratos de token.
    public var blockedRecipients: Set<EVMAddress>
    public var contractRules: [EVMContractCallRule]

    public init(approvedSpenders: Set<EVMAddress> = [], blockedRecipients: Set<EVMAddress> = [], contractRules: [EVMContractCallRule] = []) {
        self.approvedSpenders = approvedSpenders
        self.blockedRecipients = blockedRecipients
        self.contractRules = contractRules
    }
}

/// O que a transacao faz, decodificado. E isto que vai para a revisao.
public enum EVMDecodedCall: Sendable, Equatable {
    case nativeTransfer(to: EVMAddress, amount: BigUInt)
    case tokenTransfer(token: EVMAddress, to: EVMAddress, amount: BigUInt)
    case tokenApproval(token: EVMAddress, spender: EVMAddress, amount: BigUInt)
    case contractCall(contract: EVMAddress, function: String, arguments: [ABIValue], value: BigUInt)
}

public enum EVMCallGuard {
    // Assinaturas recusadas. Os seletores saem do keccak da assinatura e os testes
    // conferem contra os valores publicados (4byte.directory, EIPs 2612 e o Permit2).
    static let deniedFunctions: [(signature: String, refusal: EVMCallRefusal)] = [
        ("setApprovalForAll(address,bool)", .setApprovalForAll),                                          // a22cb465
        ("increaseAllowance(address,uint256)", .increaseAllowance),                                       // 39509351
        ("increaseApproval(address,uint256)", .increaseAllowance),                                        // d73dd623
        ("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)", .permit),                       // d505accf EIP-2612
        ("permit(address,address,uint256,uint256,bool,uint8,bytes32,bytes32)", .permit),                  // 8fcbaf0c DAI
        ("permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)", .permit),             // 2b67b570 Permit2
        ("permit(address,((address,uint160,uint48,uint48)[],address,uint256),bytes)", .permit),           // 2a2d80d1 Permit2
        ("approve(address,address,uint160,uint48)", .permit),                                             // 87517c45 Permit2
    ]

    static let deniedSelectors: [[UInt8]: EVMCallRefusal] = {
        var out = [[UInt8]: EVMCallRefusal]()
        for entry in deniedFunctions {
            // As assinaturas sao literais deste arquivo; se uma nao ler, o teste pega.
            if let function = try? ABIFunction(entry.signature) { out[function.selector] = entry.refusal }
        }
        return out
    }()

    /// Decodifica e valida. Devolve o que a transacao faz, ou lanca o motivo da recusa.
    public static func inspect(_ proposal: EVMCallProposal, policy: EVMCallPolicy) throws -> EVMDecodedCall {
        switch proposal.transactionType {
        case 0, 2: break
        case 4: throw EVMCallRefusal.eip7702Authorization
        default: throw EVMCallRefusal.unsupportedTransactionType(proposal.transactionType)
        }
        guard let to = proposal.to else { throw EVMCallRefusal.contractCreation }

        if proposal.data.isEmpty {
            try checkRecipient(to, policy: policy)
            return .nativeTransfer(to: to, amount: proposal.value)
        }
        guard proposal.data.count >= 4 else { throw EVMCallRefusal.malformedCalldata }
        let selector = Array(proposal.data.prefix(4))
        if let refusal = deniedSelectors[selector] { throw refusal }

        if selector == ERC20.transferFunction.selector {
            let (recipient, amount) = try addressAndAmount(ERC20.transferFunction, proposal.data)
            guard proposal.value.isZero else { throw EVMCallRefusal.valueWithTokenCall }
            guard recipient != to else { throw EVMCallRefusal.recipientIsTokenContract }
            try checkRecipient(recipient, policy: policy)
            return .tokenTransfer(token: to, to: recipient, amount: amount)
        }
        if selector == ERC20.approveFunction.selector {
            let (spender, amount) = try addressAndAmount(ERC20.approveFunction, proposal.data)
            guard proposal.value.isZero else { throw EVMCallRefusal.valueWithTokenCall }
            // Revogar (approve 0) vale para qualquer spender: e assim que se desfaz
            // uma aprovacao antiga, inclusive de router que morreu.
            if !amount.isZero, !policy.approvedSpenders.contains(spender) {
                throw EVMCallRefusal.spenderNotAllowed(spender)
            }
            return .tokenApproval(token: to, spender: spender, amount: amount)
        }
        for rule in policy.contractRules where rule.contract == to && rule.function.selector == selector {
            let arguments: [ABIValue]
            do {
                arguments = try rule.function.decodeCall(proposal.data)
            } catch let error as ABIError {
                throw EVMCallRefusal.invalidArguments(error)
            }
            try rule.validate(arguments, proposal.value)
            return .contractCall(contract: to, function: rule.function.signature, arguments: arguments, value: proposal.value)
        }
        // Calldata desconhecida e recusada mesmo para destino sem codigo: "tem codigo"
        // e dado de rede, e a guarda nao aposta nele.
        throw EVMCallRefusal.unknownSelector(selector)
    }

    static func checkRecipient(_ recipient: EVMAddress, policy: EVMCallPolicy) throws {
        guard !recipient.isZero else { throw EVMCallRefusal.burnAddress }
        guard !policy.blockedRecipients.contains(recipient) else { throw EVMCallRefusal.blockedRecipient(recipient) }
    }

    static func addressAndAmount(_ function: ABIFunction, _ data: [UInt8]) throws -> (EVMAddress, BigUInt) {
        do {
            let arguments = try function.decodeCall(data)
            guard arguments.count == 2, let address = arguments[0].addressValue, let amount = arguments[1].uintValue else {
                throw EVMCallRefusal.malformedCalldata
            }
            return (address, amount)
        } catch let error as ABIError {
            throw EVMCallRefusal.invalidArguments(error)
        }
    }
}
