import Foundation
import Testing
@testable import EscaliburChains
import EscaliburCore

@Suite("EVM: planejamento")
struct EVMPlannerTests {
    typealias T = EVMTestSupport

    static let wallet = UUID()
    static let gwei = BigUInt(1_000_000_000)
    static let ether = BigUInt(decimal: "1000000000000000000")!
    static let recipient = T.address("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
    static let router = T.address("0x111111125421cA6dc452d289314280a0f8842A65")
    static let usdt = EVMToken(chain: .ethereum, contract: T.address("0xdAC17F958D2ee523a2206206994597C13D831ec7"), symbol: "USDT", decimals: 6)
    static let usdc = EVMToken(chain: .ethereum, contract: T.address("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"), symbol: "USDC", decimals: 6)

    static func state(
        _ chain: Chain = .ethereum, nonces: [UInt64] = [12, 12], local: UInt64? = nil, baseFee: BigUInt = BigUInt(70_000_000),
        tips: EVMPriorityFees = EVMPriorityFees(slow: BigUInt(10_000_000), normal: BigUInt(50_000_000), fast: BigUInt(2_000_000_000)),
        gas: UInt64 = 21_000, l1: BigUInt? = nil, balance: BigUInt = ether, hasCode: Bool = false
    ) -> EVMNetworkState {
        EVMNetworkState(chain: chain, pendingNonces: nonces, localNextNonce: local, baseFeePerGas: baseFee, priorityFees: tips,
                        gasEstimate: gas, l1DataFee: l1, nativeBalance: balance, destinationHasCode: hasCode)
    }

    static func line(_ plan: SigningPlan, _ label: String) -> String? {
        plan.review.lines.first { $0.label == label }?.value
    }

    static func only(_ plan: SigningPlan) -> EVMTransaction {
        plan.transactions[0] as! EVMTransaction
    }

    @Test("Envio nativo: taxa, gas, nonce, revisao e assinatura de ponta a ponta")
    func nativeSend() throws {
        let account = try T.account(T.testKey)
        let amount = BigUInt(decimal: "500000000000000000")!
        let plan = try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient,
                                                 amount: amount, state: Self.state())
        let transaction = Self.only(plan)
        // Transferencia simples para conta sem codigo: 21.000 exato.
        #expect(transaction.gasLimit == 21_000)
        // maxFee = 2 * 0,07 + 0,05 gwei; tip = 0,05 gwei.
        #expect(transaction.fee == .eip1559(maxPriorityFeePerGas: BigUInt(50_000_000), maxFeePerGas: BigUInt(190_000_000)))
        #expect(transaction.nonce == 12)
        #expect(transaction.chainID == 1)
        #expect(transaction.to == Self.recipient)
        #expect(transaction.value == amount)
        #expect(plan.review.kind == .send)
        #expect(plan.review.title == "Enviar 0,5\u{00A0}ETH")
        #expect(plan.review.lines.contains(PlanReview.Line("Para", "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", verbatim: true)))
        #expect(Self.line(plan, "Taxa estimada") == "0,00000252\u{00A0}ETH")
        #expect(Self.line(plan, "Taxa máxima") == "0,00000399\u{00A0}ETH")
        #expect(plan.review.warnings.isEmpty)

        // Ponta a ponta: assina com a chave de teste e monta.
        let signed = try transaction.assemble(with: [T.sign(transaction.signingDigest, key: T.testKey)])
        #expect(signed.raw.first == 0x02)
    }

    @Test("Teto de taxa: maxFee cortado no teto da rede, e recusa se a baseFee ja passa")
    func feeCeiling() throws {
        let account = try T.account(T.testKey)
        // Ethereum: teto de 500 gwei. baseFee 300 gwei: 2*300+tip passa do teto, entao
        // maxFee = 500 gwei (ainda cobre baseFee + tip).
        let plan = try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: 1,
                                                 state: Self.state(baseFee: Self.gwei * BigUInt(300)))
        #expect(Self.only(plan).fee.maxPerGas == Self.gwei * BigUInt(500))
        #expect(throws: EVMPlanError.feeAboveCeiling) {
            try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: 1,
                                          state: Self.state(baseFee: Self.gwei * BigUInt(501)))
        }
        // Gorjeta sugerida absurda e cortada no teto (10 gwei na Ethereum).
        let greedy = try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: 1,
                                                   state: Self.state(tips: EVMPriorityFees(slow: 0, normal: Self.gwei * BigUInt(1000), fast: 0)))
        #expect(Self.only(greedy).fee == .eip1559(maxPriorityFeePerGas: Self.gwei * BigUInt(10), maxFeePerGas: BigUInt(140_000_000) + Self.gwei * BigUInt(10)))
        // Polygon: gorjeta minima de 25 gwei, mesmo com sugestao menor.
        let polygon = try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .polygon, to: Self.recipient, amount: Self.ether / BigUInt(10),
                                                    state: Self.state(.polygon, baseFee: Self.gwei * BigUInt(245), balance: Self.ether * BigUInt(10)))
        #expect(Self.only(polygon).fee == .eip1559(maxPriorityFeePerGas: Self.gwei * BigUInt(25), maxFeePerGas: Self.gwei * BigUInt(515)))
    }

    @Test("gasLimit: estimativa * 1,2 e teto de 2^24")
    func gasLimit() throws {
        let account = try T.account(T.testKey)
        let plan = try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: 1,
                                                 state: Self.state(gas: 50_001, hasCode: true))
        let limit = Self.only(plan).gasLimit
        #expect(limit == 60_002)
        #expect(limit * 10 <= 50_001 * 13)
        #expect(plan.review.warnings.contains(.destinationIsContract))
        let capped = try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: 1,
                                                   state: Self.state(gas: 16_000_000, balance: Self.ether * BigUInt(100)))
        #expect(Self.only(capped).gasLimit == 16_777_216)
        #expect(throws: EVMPlanError.gasLimitAboveCap) {
            try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: 1,
                                          state: Self.state(gas: 16_777_217))
        }
        #expect(throws: EVMPlanError.invalidGasEstimate) {
            try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: 1,
                                          state: Self.state(gas: 20_999))
        }
    }

    @Test("Nonce: duas fontes, o maior, e recusa quando divergem demais")
    func nonce() throws {
        let account = try T.account(T.testKey)
        func plan(_ nonces: [UInt64], local: UInt64? = nil) throws -> UInt64 {
            Self.only(try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: 1,
                                                    state: Self.state(nonces: nonces, local: local))).nonce
        }
        #expect(try plan([12, 13]) == 13)
        #expect(try plan([12, 13], local: 15) == 15)
        #expect(throws: EVMPlanError.nonceNeedsTwoSources) { try plan([12]) }
        #expect(throws: EVMPlanError.nonceSourcesDisagree) { try plan([12, 500]) }
        #expect(throws: EVMPlanError.nonceSourcesDisagree) { try plan([12, 12], local: 100) }
    }

    @Test("Saldo, valor zero, destino queimado e rede trocada")
    func refusals() throws {
        let account = try T.account(T.testKey)
        #expect(throws: EVMPlanError.self) {
            try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: Self.ether, state: Self.state())
        }
        #expect(throws: EVMPlanError.zeroAmount) {
            try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: 0, state: Self.state())
        }
        #expect(throws: EVMPlanError.refused(.burnAddress)) {
            try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: .zero, amount: 1, state: Self.state())
        }
        #expect(throws: EVMPlanError.chainMismatch) {
            try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .base, to: Self.recipient, amount: 1, state: Self.state())
        }
        #expect(throws: EVMPlanError.notEVMChain) {
            try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .bitcoin, to: Self.recipient, amount: 1, state: Self.state(.bitcoin))
        }
        #expect(throws: EVMPlanError.legacyNotSupported) {
            try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: 1, state: Self.state(), format: .legacy)
        }
        // Enviar tudo: o maximo cabe exatamente.
        let max = try EVMPlanner.maxNativeSendAmount(chain: .ethereum, state: Self.state())
        _ = try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: max, state: Self.state())
        #expect(throws: EVMPlanError.insufficientNativeBalance(needed: max + BigUInt(1) + BigUInt(21_000 * 190_000_000), available: Self.ether)) {
            try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient, amount: max + BigUInt(1), state: Self.state())
        }
    }

    @Test("Taxa alta: aviso acima de 3% do valor")
    func highFee() throws {
        let account = try T.account(T.testKey)
        // Taxa provavel = 21.000 * 0,12 gwei = 2.520 gwei; 3% disso = 84.000 gwei.
        let plan = try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .ethereum, to: Self.recipient,
                                                 amount: BigUInt(50_000) * Self.gwei, state: Self.state())
        #expect(plan.review.warnings == [.highFee(percentOfAmount: 5.04)])
    }

    @Test("Base e OP: taxa L1 obrigatoria e somada")
    func l1Fee() throws {
        let account = try T.account(T.testKey)
        #expect(throws: EVMPlanError.missingL1DataFee) {
            try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .base, to: Self.recipient, amount: 1, state: Self.state(.base))
        }
        let l1 = BigUInt(3_000_000_000_000)
        let plan = try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .optimism, to: Self.recipient, amount: 1,
                                                 state: Self.state(.optimism, baseFee: BigUInt(5_000_000), l1: l1))
        #expect(Self.line(plan, "Parte da taxa paga à L1") == "0,000003\u{00A0}ETH")
        let max = try EVMPlanner.maxNativeSendAmount(chain: .optimism, state: Self.state(.optimism, baseFee: BigUInt(5_000_000), l1: l1))
        let fee = Self.only(plan).maxExecutionCost + l1
        #expect(max == Self.ether - fee)
    }

    @Test("BNB: tipo 2 com maxFee = maxPriority, e legado como alternativa")
    func bnb() throws {
        let account = try T.account(T.testKey)
        let state = Self.state(.bnb, baseFee: 0, tips: EVMPriorityFees(slow: 0, normal: BigUInt(10_000_000), fast: BigUInt(100_000_000)))
        let type2 = try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .bnb, to: Self.recipient, amount: 1, state: state)
        // Sugestao de 0,01 gwei sobe para o minimo de 0,05.
        #expect(Self.only(type2).fee == .eip1559(maxPriorityFeePerGas: BigUInt(50_000_000), maxFeePerGas: BigUInt(50_000_000)))
        let legacy = try EVMPlanner.planNativeSend(walletID: Self.wallet, account: account, chain: .bnb, to: Self.recipient, amount: 1, state: state,
                                                   speed: .fast, format: .legacy)
        let transaction = Self.only(legacy)
        #expect(transaction.fee == .legacy(gasPrice: BigUInt(100_000_000)))
        #expect(transaction.transactionType == 0)
        let signature = try T.sign(transaction.signingDigest, key: T.testKey)
        let signed = try transaction.assemble(with: [signature])
        // A lista termina em v, r, s, com v = recid + 35 + 2 * 56 (147 ou 148).
        let v = BigUInt(UInt64(signature.recoveryID!) + 35 + 2 * 56)
        let tail = RLP.uint(v).encoded + RLP.uint(BigUInt(bigEndian: signature.bytes.prefix(32))).encoded
            + RLP.uint(BigUInt(bigEndian: signature.bytes.suffix(32))).encoded
        #expect(Array(signed.raw.suffix(tail.count)) == tail)
        #expect([147, 148].contains(v.uint64!))
    }

    @Test("Envio de token: calldata transfer, bloqueio no proprio contrato, saldo do token")
    func tokenSend() throws {
        let account = try T.account(T.testKey)
        let tokenState = EVMTokenState(contractHasCode: true, balance: BigUInt(5_000_000))
        let plan = try EVMPlanner.planTokenSend(walletID: Self.wallet, account: account, token: Self.usdc, to: Self.recipient, amount: BigUInt(1_500_000),
                                                state: Self.state(gas: 45_000), tokenState: tokenState)
        let transaction = Self.only(plan)
        #expect(transaction.to == Self.usdc.contract)
        #expect(transaction.value.isZero)
        #expect(transaction.data == ERC20.transfer(to: Self.recipient, amount: BigUInt(1_500_000)))
        #expect(transaction.gasLimit == 54_000)
        #expect(plan.review.title == "Enviar 1,5\u{00A0}USDC")
        #expect(plan.review.lines.contains(PlanReview.Line("Contrato do token", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", verbatim: true)))

        #expect(throws: EVMPlanError.refused(.recipientIsTokenContract)) {
            try EVMPlanner.planTokenSend(walletID: Self.wallet, account: account, token: Self.usdc, to: Self.usdc.contract, amount: 1,
                                         state: Self.state(gas: 45_000), tokenState: tokenState)
        }
        #expect(throws: EVMPlanError.refused(.blockedRecipient(Self.router))) {
            try EVMPlanner.planTokenSend(walletID: Self.wallet, account: account, token: Self.usdc, to: Self.router, amount: 1,
                                         state: Self.state(gas: 45_000), tokenState: tokenState, policy: EVMCallPolicy(blockedRecipients: [Self.router]))
        }
        #expect(throws: EVMPlanError.insufficientTokenBalance(needed: BigUInt(6_000_000), available: BigUInt(5_000_000))) {
            try EVMPlanner.planTokenSend(walletID: Self.wallet, account: account, token: Self.usdc, to: Self.recipient, amount: BigUInt(6_000_000),
                                         state: Self.state(gas: 45_000), tokenState: tokenState)
        }
        #expect(throws: EVMPlanError.tokenHasNoCode) {
            try EVMPlanner.planTokenSend(walletID: Self.wallet, account: account, token: Self.usdc, to: Self.recipient, amount: 1,
                                         state: Self.state(gas: 45_000), tokenState: EVMTokenState(contractHasCode: false, balance: 1))
        }
        let warned = try EVMPlanner.planTokenSend(walletID: Self.wallet, account: account, token: Self.usdc, to: Self.recipient, amount: 1,
                                                  state: Self.state(gas: 45_000, hasCode: true), tokenState: tokenState, valueInNativeUnits: BigUInt(1_000))
        #expect(warned.review.warnings.contains(.destinationIsContract))
        #expect(warned.review.warnings.contains { if case .highFee = $0 { return true } else { return false } })
    }

    @Test("Approve exato: spender da allowlist, com codigo, e o aviso do ilimitado")
    func approve() throws {
        let account = try T.account(T.testKey)
        let policy = EVMCallPolicy(approvedSpenders: [Self.router])
        let state = Self.state(gas: 46_000, hasCode: true)
        let tokenState = EVMTokenState(contractHasCode: true, balance: 0, allowance: 0)
        let plan = try EVMPlanner.planApprove(walletID: Self.wallet, account: account, token: Self.usdc, spender: Self.router, amount: .exact(BigUInt(2_000_000)),
                                              state: state, tokenState: tokenState, policy: policy)
        #expect(plan.transactions.count == 1)
        #expect(Self.only(plan).data == ERC20.approve(spender: Self.router, amount: BigUInt(2_000_000)))
        #expect(plan.review.kind == .approve)
        #expect(plan.review.title == "Autorizar 2\u{00A0}USDC")
        #expect(plan.review.warnings.isEmpty)

        #expect(throws: EVMPlanError.refused(.spenderNotAllowed(Self.recipient))) {
            try EVMPlanner.planApprove(walletID: Self.wallet, account: account, token: Self.usdc, spender: Self.recipient, amount: .exact(1),
                                       state: state, tokenState: tokenState, policy: policy)
        }
        #expect(throws: EVMPlanError.spenderHasNoCode) {
            try EVMPlanner.planApprove(walletID: Self.wallet, account: account, token: Self.usdc, spender: Self.router, amount: .exact(1),
                                       state: Self.state(gas: 46_000), tokenState: tokenState, policy: policy)
        }
        #expect(throws: EVMPlanError.unlimitedMustBeExplicit) {
            try EVMPlanner.planApprove(walletID: Self.wallet, account: account, token: Self.usdc, spender: Self.router, amount: .exact(.uint256Max),
                                       state: state, tokenState: tokenState, policy: policy)
        }
        #expect(throws: EVMPlanError.zeroAmount) {
            try EVMPlanner.planApprove(walletID: Self.wallet, account: account, token: Self.usdc, spender: Self.router, amount: .exact(0),
                                       state: state, tokenState: tokenState, policy: policy)
        }
        #expect(throws: EVMPlanError.missingAllowance) {
            try EVMPlanner.planApprove(walletID: Self.wallet, account: account, token: Self.usdc, spender: Self.router, amount: .exact(1),
                                       state: state, tokenState: EVMTokenState(contractHasCode: true, balance: 0), policy: policy)
        }
        let unlimited = try EVMPlanner.planApprove(walletID: Self.wallet, account: account, token: Self.usdc, spender: Self.router, amount: .unlimited,
                                                   state: state, tokenState: tokenState, policy: policy)
        #expect(unlimited.review.warnings == [.unlimitedApproval])
        #expect(Self.only(unlimited).data == ERC20.approve(spender: Self.router, amount: .uint256Max))
    }

    @Test("USDT na Ethereum: approve(0) antes do novo valor, duas transacoes com nonces seguidos")
    func usdtReset() throws {
        let account = try T.account(T.testKey)
        let policy = EVMCallPolicy(approvedSpenders: [Self.router])
        let state = Self.state(gas: 46_000, hasCode: true)
        let plan = try EVMPlanner.planApprove(walletID: Self.wallet, account: account, token: Self.usdt, spender: Self.router, amount: .exact(BigUInt(3_000_000)),
                                              state: state, tokenState: EVMTokenState(contractHasCode: true, balance: 0, allowance: 1), policy: policy)
        #expect(plan.transactions.count == 2)
        #expect(plan.review.transactionCount == 2)
        let first = plan.transactions[0] as! EVMTransaction
        let second = plan.transactions[1] as! EVMTransaction
        #expect(first.data == ERC20.approve(spender: Self.router, amount: 0))
        #expect(second.data == ERC20.approve(spender: Self.router, amount: BigUInt(3_000_000)))
        #expect(first.nonce == 12 && second.nonce == 13)
        #expect(Self.line(plan, "Nonce") == "12 e 13")
        // Allowance atual zero: uma transacao so.
        let single = try EVMPlanner.planApprove(walletID: Self.wallet, account: account, token: Self.usdt, spender: Self.router, amount: .exact(BigUInt(3_000_000)),
                                                state: state, tokenState: EVMTokenState(contractHasCode: true, balance: 0, allowance: 0), policy: policy)
        #expect(single.transactions.count == 1)
        // O mesmo USDT em outra rede nao e o contrato com a regra.
        let usdtBase = EVMToken(chain: .base, contract: Self.usdt.contract, symbol: "USDT", decimals: 6)
        #expect(!EVMPlanner.requiresZeroFirstApproval(usdtBase))
        #expect(EVMPlanner.requiresZeroFirstApproval(Self.usdt))
        #expect(!EVMPlanner.requiresZeroFirstApproval(Self.usdc))
    }

    @Test("Revogar: approve(0) para qualquer spender, recusa se ja esta zerado")
    func revoke() throws {
        let account = try T.account(T.testKey)
        let dead = T.address("0xCf5540fFFCdC3d510B18bFcA6d2b9987b0772559")
        let plan = try EVMPlanner.planRevoke(walletID: Self.wallet, account: account, token: Self.usdc, spender: dead,
                                             state: Self.state(gas: 30_000), tokenState: EVMTokenState(contractHasCode: true, balance: 0, allowance: 10))
        #expect(Self.only(plan).data == ERC20.approve(spender: dead, amount: 0))
        #expect(plan.review.kind == .revoke)
        #expect(plan.review.title == "Revogar autorização de USDC")
        #expect(throws: EVMPlanError.nothingToRevoke) {
            try EVMPlanner.planRevoke(walletID: Self.wallet, account: account, token: Self.usdc, spender: dead,
                                      state: Self.state(gas: 30_000), tokenState: EVMTokenState(contractHasCode: true, balance: 0, allowance: 0))
        }
    }

    @Test("Texto de valor exato, sem arredondar")
    func amountText() {
        #expect(EVMText.number(0, decimals: 18) == "0")
        #expect(EVMText.number(1, decimals: 18) == "0,000000000000000001")
        #expect(EVMText.number(BigUInt(decimal: "1234567890000000000000")!, decimals: 18) == "1.234,56789")
        #expect(EVMText.number(BigUInt(1_000_000), decimals: 6) == "1")
        #expect(EVMText.number(BigUInt(123), decimals: 0) == "123")
        #expect(EVMText.number(.uint256Max, decimals: 0).hasPrefix("115.792.089"))
    }
}
