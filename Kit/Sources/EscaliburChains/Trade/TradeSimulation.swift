import EscaliburCore
import Foundation

// A simulacao: a segunda opiniao (docs/seguranca.md 4.9).
//
// A rede roda `eth_simulateV1` com `traceTransfers: true` em dois provedores diferentes,
// com as chamadas exatas do plano: os approves e a troca, a partir da conta do dono.
// Aqui, sem rede, cada resultado e conferido:
//
// - toda chamada termina com sucesso;
// - na troca, sai do dono so o token vendido, e no maximo `amountIn` (a moeda nativa
//   aparece como Transfer do endereco 0xEeee...EEeE, que e como o geth reporta valor);
// - entra no dono pelo menos o garantido do token comprado;
// - nenhum `Approval` do dono alem do approve exato do plano (e do consumo dessa mesma
//   allowance pelo router, que alguns tokens emitem), nenhum `ApprovalForAll`.
//
// Drainers detectam simulacao, entao isto e a segunda camada, nao a unica: a primeira e a
// calldata decodificada e o minimo garantido pelo router.

public struct TradeSimulatedLog: Sendable, Equatable {
    public let address: EVMAddress
    public let topics: [[UInt8]]
    public let data: [UInt8]

    public init(address: EVMAddress, topics: [[UInt8]], data: [UInt8]) {
        self.address = address
        self.topics = topics
        self.data = data
    }
}

public struct TradeSimulatedCall: Sendable, Equatable {
    public let success: Bool
    public let gasUsed: UInt64
    public let logs: [TradeSimulatedLog]
    /// A mensagem de revert, quando o no informa. So para diagnostico.
    public let error: String?

    public init(success: Bool, gasUsed: UInt64, logs: [TradeSimulatedLog], error: String? = nil) {
        self.success = success
        self.gasUsed = gasUsed
        self.logs = logs
        self.error = error
    }
}

/// O resultado de uma simulacao, de um provedor.
public struct TradeSimulation: Sendable, Equatable {
    /// Qual provedor simulou. Duas simulacoes do mesmo provedor contam como uma.
    public let source: String
    public let calls: [TradeSimulatedCall]

    public init(source: String, calls: [TradeSimulatedCall]) {
        self.source = source
        self.calls = calls
    }
}

/// As chamadas que a simulacao tem de reproduzir, na ordem.
public struct TradeSimulationRequest: Sendable, Equatable {
    public struct Call: Sendable, Equatable {
        public let from: EVMAddress
        public let to: EVMAddress
        public let value: BigUInt
        public let data: [UInt8]

        public init(from: EVMAddress, to: EVMAddress, value: BigUInt, data: [UInt8]) {
            self.from = from
            self.to = to
            self.value = value
            self.data = data
        }
    }

    public let calls: [Call]
    /// Valores dos approves, na ordem (vazio se nao ha approve).
    let approvals: [BigUInt]
}

enum TradeSimulationCheck {
    static let transferTopic = Hash.keccak256(Array("Transfer(address,address,uint256)".utf8))
    static let approvalTopic = Hash.keccak256(Array("Approval(address,address,uint256)".utf8))
    static let approvalForAllTopic = Hash.keccak256(Array("ApprovalForAll(address,address,bool)".utf8))
    /// O geth reporta valor nativo como Transfer deste endereco (`traceTransfers`).
    static let nativePseudoToken = TradeConstants.eeeeSentinel

    /// O gas medido: de cada approve e da troca. Exige duas fontes diferentes, as duas
    /// passando.
    static func verify(
        _ simulations: [TradeSimulation], request: TradeSimulationRequest, quote: ValidatedTradeQuote
    ) throws -> (approvals: [UInt64], swap: UInt64) {
        let sources = Set(simulations.map(\.source))
        guard sources.count >= 2 else { throw TradeRefusal.simulationUnavailable }
        var approvalGas = [UInt64](repeating: 0, count: request.approvals.count)
        var swapGas: UInt64 = 0
        for simulation in simulations {
            let (approvals, swap) = try verify(simulation, request: request, quote: quote)
            for index in approvals.indices { approvalGas[index] = max(approvalGas[index], approvals[index]) }
            swapGas = max(swapGas, swap)
        }
        return (approvalGas, swapGas)
    }

    static func verify(
        _ simulation: TradeSimulation, request: TradeSimulationRequest, quote: ValidatedTradeQuote
    ) throws -> (approvals: [UInt64], swap: UInt64) {
        let intent = quote.intent
        let owner = intent.owner
        guard simulation.calls.count == request.approvals.count + 1 else { throw TradeRefusal.simulationShape }
        for (index, call) in simulation.calls.enumerated() where !call.success {
            throw TradeRefusal.simulationFailed(call: index)
        }

        // Approves: so o Approval exato do plano, nada saindo.
        for (index, expected) in request.approvals.enumerated() {
            for log in simulation.calls[index].logs {
                if let transfer = parseTransfer(log), transfer.from == owner, !transfer.value.isZero {
                    throw TradeRefusal.simulationUnexpectedTransfer(token: log.address)
                }
                if let approval = parseApproval(log), approval.owner == owner {
                    guard log.address == intent.sell.contract, approval.spender == quote.spender, approval.value == expected else {
                        throw TradeRefusal.simulationUnexpectedApproval(token: log.address, spender: approval.spender)
                    }
                }
                try refuseApprovalForAll(log, owner: owner)
            }
        }

        // A troca.
        let swap = simulation.calls[simulation.calls.count - 1]
        let sellToken = intent.sell.contract ?? nativePseudoToken
        let buyToken = intent.buy.contract ?? nativePseudoToken
        var spent = BigUInt()
        var received = BigUInt()
        for log in swap.logs {
            try refuseApprovalForAll(log, owner: owner)
            if let approval = parseApproval(log), approval.owner == owner {
                // O consumo da allowance pelo router (tokens OpenZeppelin 4 emitem
                // Approval no transferFrom): mesmo token, mesmo spender, valor que so
                // pode ter descido.
                guard log.address == intent.sell.contract, approval.spender == quote.spender, approval.value <= intent.amountIn else {
                    throw TradeRefusal.simulationUnexpectedApproval(token: log.address, spender: approval.spender)
                }
            }
            guard let transfer = parseTransfer(log) else { continue }
            if transfer.from == owner, transfer.to != owner, !transfer.value.isZero {
                guard log.address == sellToken else { throw TradeRefusal.simulationUnexpectedTransfer(token: log.address) }
                spent = spent + transfer.value
            }
            if transfer.to == owner, transfer.from != owner, log.address == buyToken {
                received = received + transfer.value
            }
        }
        guard spent <= intent.amountIn else { throw TradeRefusal.simulationSpentTooMuch(found: spent, allowed: intent.amountIn) }
        guard received >= quote.guaranteedOut else {
            throw TradeRefusal.simulationReceivedTooLittle(found: received, required: quote.guaranteedOut)
        }
        let approvals = simulation.calls.prefix(request.approvals.count).map(\.gasUsed)
        return (Array(approvals), swap.gasUsed)
    }

    struct Transfer { let from: EVMAddress; let to: EVMAddress; let value: BigUInt }
    struct Approval { let owner: EVMAddress; let spender: EVMAddress; let value: BigUInt }

    static func topicAddress(_ topic: [UInt8]) -> EVMAddress? {
        guard topic.count == 32, topic.prefix(12).allSatisfy({ $0 == 0 }) else { return nil }
        return EVMAddress(uncheckedBytes: Array(topic.suffix(20)))
    }

    static func parseTransfer(_ log: TradeSimulatedLog) -> Transfer? {
        guard log.topics.count == 3, log.topics[0] == transferTopic, log.data.count == 32,
              let from = topicAddress(log.topics[1]), let to = topicAddress(log.topics[2])
        else { return nil }
        return Transfer(from: from, to: to, value: BigUInt(bigEndian: log.data))
    }

    static func parseApproval(_ log: TradeSimulatedLog) -> Approval? {
        guard log.topics.count == 3, log.topics[0] == approvalTopic, log.data.count == 32,
              let owner = topicAddress(log.topics[1]), let spender = topicAddress(log.topics[2])
        else { return nil }
        return Approval(owner: owner, spender: spender, value: BigUInt(bigEndian: log.data))
    }

    static func refuseApprovalForAll(_ log: TradeSimulatedLog, owner: EVMAddress) throws {
        guard log.topics.count >= 2, log.topics[0] == approvalForAllTopic, topicAddress(log.topics[1]) == owner else { return }
        throw TradeRefusal.simulationUnexpectedApproval(token: log.address, spender: log.topics.count > 2 ? topicAddress(log.topics[2]) ?? .zero : .zero)
    }
}
