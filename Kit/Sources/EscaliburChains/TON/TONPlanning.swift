import EscaliburCore
import Foundation

/// Estado de uma conta TON como a rede reporta.
public enum TONAccountStatus: String, Sendable, Codable {
    /// Sem contrato: nunca recebeu (`nonexist`) ou recebeu e nunca enviou (`uninit`).
    case uninitialized
    case active
    /// Congelada por divida de armazenamento.
    case frozen
}

/// O estado publico da carteira do dono e do destino, que `EscaliburNetwork` preenche
/// (toncenter/tonapi: `getWalletInformation`, `get_account_state`, estimativa de taxa).
/// Nada aqui e segredo e nada aqui e confiavel sozinho: o planejamento confere o que
/// da para conferir e o resto so afeta o que a tela mostra.
public struct TONChainState: Sendable, Equatable {
    /// Estado do contrato da carteira do dono.
    public var accountStatus: TONAccountStatus
    /// `seqno` atual. Zero em carteira nao inicializada.
    public var seqno: UInt32
    /// Saldo em nanoton.
    public var balance: BigUInt
    /// Hash do codigo do contrato ativo, se a rede informou. Quando vem, precisa ser o
    /// da versao que a carteira acha que tem: corpo V4R2 num contrato W5 e recusado
    /// pelo contrato e so gasta a validade.
    public var codeHash: [UInt8]?
    /// Estado da conta de destino (envio de TON): decide o bounce.
    public var destinationStatus: TONAccountStatus
    /// Hash do codigo da conta de destino, se ativa e se a rede informou. Serve para
    /// recusar destino que e carteira jetton (dinheiro mandado para la nao tem dono).
    public var destinationCodeHash: [UInt8]?
    /// Taxa estimada em nanoton (emulacao do provedor). Na TON a taxa nao entra no que
    /// se assina: a rede cobra o custo real do saldo. A estimativa so serve para a
    /// conferencia de saldo e para a tela, e passa por um teto.
    public var estimatedFee: BigUInt

    public init(
        accountStatus: TONAccountStatus, seqno: UInt32, balance: BigUInt, codeHash: [UInt8]? = nil,
        destinationStatus: TONAccountStatus, destinationCodeHash: [UInt8]? = nil, estimatedFee: BigUInt
    ) {
        self.accountStatus = accountStatus
        self.seqno = seqno
        self.balance = balance
        self.codeHash = codeHash
        self.destinationStatus = destinationStatus
        self.destinationCodeHash = destinationCodeHash
        self.estimatedFee = estimatedFee
    }
}

/// O estado do USDT do dono: a carteira jetton (resolvida pela rede com
/// `get_wallet_address` no mestre) e o saldo dela, nas unidades do token (6 casas).
public struct TONJettonState: Sendable, Equatable {
    public var ownerJettonWallet: String
    public var balance: BigUInt

    public init(ownerJettonWallet: String, balance: BigUInt) {
        self.ownerJettonWallet = ownerJettonWallet
        self.balance = balance
    }
}

public enum TONPlanError: Error, Equatable, Sendable {
    case invalidDestination(Address.Problem)
    case destinationIsSelf
    /// Destino e o contrato do token ou a carteira jetton do proprio dono: o que for
    /// mandado para la nao chega a ninguem.
    case destinationIsTokenContract
    case destinationFrozen
    case zeroAmount
    case insufficientBalance(needed: BigUInt, available: BigUInt)
    case insufficientTokenBalance(needed: BigUInt, available: BigUInt)
    case missingFee
    case feeAboveCeiling(fee: BigUInt, ceiling: BigUInt)
    case accountFrozen
    /// O estado da rede se contradiz (seqno > 0 numa conta nao inicializada).
    case inconsistentState
    /// O contrato ativo nao e da versao que a carteira esperava.
    case walletVersionMismatch
    /// A carteira jetton que a rede informou nao e a do dono.
    case jettonWalletMismatch
    case commentTooLong(maxBytes: Int)
    /// Caractere de controle, invisivel ou de direcao de texto: o comentario na tela
    /// do explorador (e da exchange) nao seria o que o dono leu aqui.
    case commentHasControlCharacters
    /// Espaco no comeco ou no fim: invisivel na revisao, e a exchange que usa o
    /// comentario como memo nao reconhece "123 " como "123".
    case commentHasSurroundingSpaces
    /// Caminho com indice nao endurecido: Ed25519 (SLIP-10) nao deriva.
    case invalidPath
}

/// As funcoes que transformam a intencao do dono num `SigningPlan` validado.
public enum TONPlanner {
    /// Teto da taxa estimada. Uma transferencia comum custa alguns milesimos de TON;
    /// uma estimativa acima de 0,1 TON e provedor errado (ou mentindo), e a
    /// conferencia de saldo com ela nao significaria nada.
    public static let feeCeiling: BigUInt = 100_000_000

    /// A mensagem vale ate 2 minutos depois do plano: os 60 s de vida do plano mais
    /// uma folga para chegar a um bloco. Mensagem antiga que ficou em algum lugar nao
    /// executa depois disso.
    public static let validitySeconds: TimeInterval = SigningPlan.lifetime + 60

    // MARK: TON

    /// Enviar TON.
    ///
    /// Bounce (regra do Tonkeeper, `userInputAddressIsBounceable`): endereco `UQ...`
    /// nunca volta; `EQ...` e raw voltam so se o destino estiver ativo. Carteira nova
    /// (nao inicializada) recebe sem bounce, senao o dinheiro voltaria.
    public static func planSendTON(
        walletID: UUID, wallet: TONWallet, path: DerivationPath,
        to destination: String, amount: BigUInt, comment: String? = nil,
        state: TONChainState, now: Date = .now
    ) throws -> SigningPlan {
        let context = try Context(wallet: wallet, path: path, state: state, comment: comment)
        let parsed = try parseDestination(destination)
        guard parsed.address != wallet.address else { throw TONPlanError.destinationIsSelf }
        guard parsed.address != TONJetton.usdtMaster, !TONJetton.isUSDTJettonWallet(codeHash: state.destinationCodeHash) else {
            throw TONPlanError.destinationIsTokenContract
        }
        guard state.destinationStatus != .frozen else { throw TONPlanError.destinationFrozen }
        guard !amount.isZero else { throw TONPlanError.zeroAmount }

        let needed = amount + state.estimatedFee
        guard state.balance >= needed else {
            throw TONPlanError.insufficientBalance(needed: needed, available: state.balance)
        }

        let bounce = parsed.bounceable != false && state.destinationStatus == .active
        let body = try context.comment.map(TONComment.cell)
        let message = TONOutgoingMessage(destination: parsed.address, amount: amount, bounce: bounce, body: body)
        let transfer = try context.transfer(messages: [message], now: now)

        var lines = [PlanReview.Line("Para", displayAddress(parsed), verbatim: true)]
        lines.append(PlanReview.Line("Valor", TONFormat.amount(amount, decimals: 9, symbol: "TON")))
        if let comment = context.comment {
            lines.append(PlanReview.Line("Comentário", comment, verbatim: true))
        }
        lines += context.commonLines(fee: state.estimatedFee)
        if !bounce {
            lines.append(PlanReview.Line("Se o destino recusar", "O valor não volta"))
        }

        var warnings = [PlanReview.Warning]()
        // Taxa acima de 10% do valor: o dono provavelmente nao quer pagar isso.
        if state.estimatedFee * 10 > amount {
            let percent = Double(state.estimatedFee.decimalString).map { fee in
                fee / (Double(amount.decimalString) ?? 1) * 100
            } ?? 0
            warnings.append(.highFee(percentOfAmount: percent))
        }

        let review = PlanReview(
            kind: .send,
            title: "Enviar \(TONFormat.amount(amount, decimals: 9, symbol: "TON"))",
            lines: lines,
            warnings: warnings
        )
        return SigningPlan(walletID: walletID, chain: .ton, review: review, transactions: [transfer], createdAt: now)
    }

    // MARK: USDT

    /// Enviar USDT na TON. `amount` em unidades do token (6 casas).
    ///
    /// A carteira jetton do dono vem da rede e e conferida contra o calculo local; o
    /// destino e o dono do USDT que vai receber (nao a carteira jetton dele).
    public static func planSendUSDT(
        walletID: UUID, wallet: TONWallet, path: DerivationPath,
        to destination: String, amount: BigUInt, comment: String? = nil,
        state: TONChainState, jetton: TONJettonState, now: Date = .now
    ) throws -> SigningPlan {
        let context = try Context(wallet: wallet, path: path, state: state, comment: comment)
        let parsed = try parseDestination(destination)

        let ownJettonWallet = try TONJetton.usdtWallet(owner: wallet.address)
        guard case .success(let reported) = TONAddress.parse(jetton.ownerJettonWallet),
              reported.address == ownJettonWallet
        else { throw TONPlanError.jettonWalletMismatch }

        guard parsed.address != wallet.address else { throw TONPlanError.destinationIsSelf }
        // O destino e o DONO que recebe. Mestre do token, a propria carteira jetton ou
        // qualquer carteira jetton do USDT (reconhecida pelo codigo) no lugar do dono
        // criaria uma carteira jetton que ninguem movimenta.
        guard parsed.address != TONJetton.usdtMaster, parsed.address != ownJettonWallet,
              !TONJetton.isUSDTJettonWallet(codeHash: state.destinationCodeHash)
        else { throw TONPlanError.destinationIsTokenContract }
        guard !amount.isZero else { throw TONPlanError.zeroAmount }
        guard jetton.balance >= amount else {
            throw TONPlanError.insufficientTokenBalance(needed: amount, available: jetton.balance)
        }
        let needed = TONJetton.attachedTON + state.estimatedFee
        guard state.balance >= needed else {
            throw TONPlanError.insufficientBalance(needed: needed, available: state.balance)
        }

        let body = try TONJetton.transferBody(
            queryID: UInt64(unixTime(now)),
            amount: amount,
            destination: parsed.address,
            responseDestination: wallet.address,
            forwardTON: TONJetton.forwardTON,
            comment: context.comment
        )
        // A carteira jetton e um contrato ativo: bounce sempre, para os 0,05 TON
        // voltarem se ela recusar.
        let message = TONOutgoingMessage(destination: ownJettonWallet, amount: TONJetton.attachedTON, bounce: true, body: body)
        let transfer = try context.transfer(messages: [message], now: now)

        let amountText = TONFormat.amount(amount, decimals: TONJetton.usdtDecimals, symbol: TONJetton.usdtSymbol)
        var lines = [PlanReview.Line("Para", displayAddress(parsed), verbatim: true)]
        lines.append(PlanReview.Line("Valor", amountText))
        lines.append(PlanReview.Line("Token", "USDT (Tether) na TON"))
        lines.append(PlanReview.Line("Contrato do token", TONJetton.usdtMaster.friendly(bounceable: true), verbatim: true))
        if let comment = context.comment {
            lines.append(PlanReview.Line("Comentário", comment, verbatim: true))
        }
        lines.append(PlanReview.Line(
            "TON para o envio",
            "\(TONFormat.amount(TONJetton.attachedTON, decimals: 9, symbol: "TON")), o que sobrar volta"
        ))
        lines += context.commonLines(fee: state.estimatedFee)

        let review = PlanReview(kind: .send, title: "Enviar \(amountText)", lines: lines)
        return SigningPlan(walletID: walletID, chain: .ton, review: review, transactions: [transfer], createdAt: now)
    }

    // MARK: Comum

    /// O que vale para os dois envios: caminho, estado da conta, versao, taxa e
    /// comentario.
    struct Context {
        let wallet: TONWallet
        let path: DerivationPath
        let state: TONChainState
        let comment: String?

        init(wallet: TONWallet, path: DerivationPath, state: TONChainState, comment: String?) throws {
            guard !path.components.isEmpty, path.isFullyHardened else { throw TONPlanError.invalidPath }
            guard state.accountStatus != .frozen else { throw TONPlanError.accountFrozen }
            if state.accountStatus == .uninitialized, state.seqno != 0 { throw TONPlanError.inconsistentState }
            if state.accountStatus == .active, let codeHash = state.codeHash, codeHash != wallet.version.codeHash {
                throw TONPlanError.walletVersionMismatch
            }
            guard !state.estimatedFee.isZero else { throw TONPlanError.missingFee }
            guard state.estimatedFee <= TONPlanner.feeCeiling else {
                throw TONPlanError.feeAboveCeiling(fee: state.estimatedFee, ceiling: TONPlanner.feeCeiling)
            }
            self.wallet = wallet
            self.path = path
            self.state = state
            self.comment = try TONPlanner.checkedComment(comment)
        }

        var deploys: Bool { state.accountStatus == .uninitialized }

        func transfer(messages: [TONOutgoingMessage], now: Date) throws -> TONTransfer {
            try TONTransfer(
                wallet: wallet, path: path, seqno: state.seqno,
                validUntil: TONPlanner.unixTime(now.addingTimeInterval(TONPlanner.validitySeconds)),
                messages: messages, mode: TONSendMode.standard, deploy: deploys
            )
        }

        func commonLines(fee: BigUInt) -> [PlanReview.Line] {
            var lines = [
                PlanReview.Line("Taxa estimada", TONFormat.amount(fee, decimals: 9, symbol: "TON")),
                PlanReview.Line("Rede", "TON"),
                PlanReview.Line("Carteira", wallet.version.displayName),
            ]
            if deploys {
                lines.append(PlanReview.Line("Ativação", "Este envio também ativa a sua carteira TON"))
            }
            return lines
        }
    }

    /// Valida o destino como qualquer tela faria (`Address.validate`), e le a grafia
    /// de novo para saber a flag.
    static func parseDestination(_ text: String) throws -> TONAddress.Parsed {
        switch Address.validate(text, for: .ton) {
        case .failure(let problem):
            throw TONPlanError.invalidDestination(problem)
        case .success(let destination):
            switch TONAddress.parse(destination.address) {
            case .failure(let problem): throw TONPlanError.invalidDestination(problem)
            case .success(let parsed): return parsed
            }
        }
    }

    /// O destino como o dono escreveu (normalizado): a flag faz parte do que ele copiou.
    static func displayAddress(_ parsed: TONAddress.Parsed) -> String {
        guard let bounceable = parsed.bounceable else { return parsed.address.raw }
        return parsed.address.friendly(bounceable: bounceable)
    }

    /// Comentario vazio vira nenhum; o resto passa inteiro ou e recusado. Nada e
    /// corrigido em silencio: o comentario e o memo da exchange, e o que sai tem de ser
    /// exatamente o que o dono viu.
    static func checkedComment(_ comment: String?) throws -> String? {
        guard let comment, !comment.isEmpty else { return nil }
        guard comment.utf8.count <= TONComment.maxBytes else { throw TONPlanError.commentTooLong(maxBytes: TONComment.maxBytes) }
        for scalar in comment.unicodeScalars {
            // Controle (C0, DEL, C1) e formato (Cf: direcao de texto, espaco de
            // largura zero, BOM, marca de hifen suave).
            let v = scalar.value
            if v < 0x20 || (0x7F...0x9F).contains(v) || scalar.properties.generalCategory == .format {
                throw TONPlanError.commentHasControlCharacters
            }
        }
        if let first = comment.unicodeScalars.first, let last = comment.unicodeScalars.last,
           first.properties.isWhitespace || last.properties.isWhitespace {
            throw TONPlanError.commentHasSurroundingSpaces
        }
        return comment
    }

    static func unixTime(_ date: Date) -> UInt32 {
        let seconds = date.timeIntervalSince1970
        guard seconds > 0 else { return 0 }
        return seconds >= Double(UInt32.max) ? UInt32.max : UInt32(seconds)
    }
}

/// Valor exato para a revisao: todas as casas que o valor tem, sem arredondar,
/// separador de milhar "." e decimal "," (pt_BR, como `Fmt` do app).
enum TONFormat {
    static func amount(_ value: BigUInt, decimals: Int, symbol: String) -> String {
        let digits = value.decimalString
        let padded = digits.count <= decimals ? String(repeating: "0", count: decimals - digits.count + 1) + digits : digits
        let cut = padded.index(padded.endIndex, offsetBy: -decimals)
        let whole = String(padded[..<cut])
        var fraction = String(padded[cut...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        var grouped = ""
        for (index, c) in whole.reversed().enumerated() {
            if index > 0, index % 3 == 0 { grouped.append(".") }
            grouped.append(c)
        }
        let number = String(grouped.reversed()) + (fraction.isEmpty ? "" : "," + fraction)
        return "\(number) \(symbol)"
    }
}
