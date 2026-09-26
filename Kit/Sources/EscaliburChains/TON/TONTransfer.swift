import EscaliburCore
import Foundation

// Mensagens e a transferencia assinavel da carteira TON.
//
// Uma transferencia sao tres camadas:
// 1. a mensagem interna que a carteira vai emitir (destino, valor, bounce, corpo);
// 2. o corpo assinado da carteira (subwallet/wallet id, validade, seqno, modo e a
//    mensagem interna), cujo hash de celula e o que a chave assina;
// 3. a mensagem externa que leva esse corpo (e o state init na primeira vez) ate o
//    contrato da carteira. E ela que vai para a rede, em BOC base64.
//
// Layout conferido contra transacoes reais da rede principal assinadas pelo
// trustwallet/wallet-core (`rust/tw_tests/tests/chains/ton/ton_sign.rs` e
// `ton_sign_wallet_v5r1.rs`): corpo e state init sempre por referencia, corpo da
// mensagem interna sempre por referencia. Com isso o id que a Escalibur calcula e o
// mesmo que a Trust Wallet calcularia para a mesma transferencia.

/// Modo de envio. A carteira usa sempre 3: paga a taxa a parte (1) e ignora erro na
/// fase de acao (2). O +2 e obrigatorio no W5 para mensagem externa; na V4R2 evita
/// que um erro de acao desfaca o seqno e a mesma mensagem seja reprocessada ate
/// expirar, cobrando taxa a cada vez.
public enum TONSendMode {
    public static let payFeesSeparately: UInt8 = 1
    public static let ignoreErrors: UInt8 = 2
    public static let standard: UInt8 = payFeesSeparately | ignoreErrors
}

/// Uma mensagem interna que a carteira emite.
public struct TONOutgoingMessage: Sendable, Equatable {
    public let destination: TONAddress
    public let amount: BigUInt
    public let bounce: Bool
    public let body: TONCell?

    public init(destination: TONAddress, amount: BigUInt, bounce: Bool, body: TONCell?) {
        self.destination = destination
        self.amount = amount
        self.bounce = bounce
        self.body = body
    }

    /// `MessageRelaxed` com `int_msg_info$0`: ihr desligado, bounce conforme pedido,
    /// origem vazia (a rede preenche), valor em Coins, sem moedas extras, taxas e
    /// tempos zerados (a rede preenche), sem state init, corpo por referencia.
    public func cell() throws -> TONCell {
        var b = TONCellBuilder()
        try b.storeBit(false)             // int_msg_info$0
        try b.storeBit(true)              // ihr_disabled
        try b.storeBit(bounce)
        try b.storeBit(false)             // bounced
        try b.storeAddress(nil)           // src: addr_none
        try b.storeAddress(destination)
        try b.storeCoins(amount)
        try b.storeBit(false)             // extra currencies: dicionario vazio
        try b.storeCoins(0)               // ihr_fee
        try b.storeCoins(0)               // fwd_fee
        try b.storeUInt(0, bits: 64)      // created_lt
        try b.storeUInt(0, bits: 32)      // created_at
        try b.storeBit(false)             // init: nenhum
        try b.storeBit(true)              // corpo por referencia
        try b.storeRef(body ?? .empty)
        return b.build()
    }
}

public enum TONComment {
    /// Maior comentario aceito, em bytes UTF-8. Cabe em 9 celulas encadeadas; mais
    /// que isso so encarece a mensagem.
    public static let maxBytes = 1024

    /// Comentario de texto: op 0 (32 bits) e o texto em UTF-8, continuando em celulas
    /// encadeadas quando passa de 123 bytes. Sem normalizar nada: exchange usa o
    /// comentario como memo, e um byte a mais ou a menos e outro memo.
    public static func cell(_ text: String) throws -> TONCell {
        var b = TONCellBuilder()
        try b.storeUInt(0, bits: 32)
        try b.storeStringTail(Array(text.utf8))
        return b.build()
    }

    /// Le o texto de volta (para teste e para exibir mensagem recebida).
    public static func text(of cell: TONCell) throws -> String? {
        var slice = cell.beginParse()
        guard slice.remainingBits >= 32, try slice.loadUInt(bits: 32) == 0 else { return nil }
        return String(bytes: try slice.loadStringTail(), encoding: .utf8)
    }
}

/// Uma transferencia da carteira, pronta para ser assinada.
///
/// O que a chave assina e o hash (32 bytes) da celula do corpo sem a assinatura,
/// calculado aqui a partir dos campos. `assemble` poe a assinatura na frente (V4R2)
/// ou no fim (V5R1) desse mesmo corpo e embrulha na mensagem externa.
public struct TONTransfer: SignableTransaction {
    public var chain: Chain { .ton }
    public let wallet: TONWallet
    public let path: DerivationPath
    public let seqno: UInt32
    /// Unix time depois do qual o contrato recusa a mensagem.
    public let validUntil: UInt32
    public let messages: [TONOutgoingMessage]
    public let mode: UInt8
    /// A primeira transacao de uma carteira ainda nao inicializada leva o state init:
    /// e ela que publica o contrato no endereco.
    public let deploy: Bool
    /// O corpo sem assinatura.
    let unsigned: TONCellBuilder
    /// O que vai ser assinado: hash da celula do corpo sem assinatura.
    public let signingHash: [UInt8]

    public init(
        wallet: TONWallet, path: DerivationPath, seqno: UInt32, validUntil: UInt32,
        messages: [TONOutgoingMessage], mode: UInt8 = TONSendMode.standard, deploy: Bool
    ) throws {
        // Sem mensagem nao ha transferencia; no W5 a mensagem externa sem o +2 no modo
        // e recusada pelo contrato (wallet-contract-v5, `contracts/wallet_v5.fc`,
        // erro 137 `external_send_message_must_have_ignore_errors_send_mode`).
        guard !messages.isEmpty else { throw TONCellError.valueTooLarge }
        if wallet.version == .v5r1, mode & TONSendMode.ignoreErrors == 0 { throw TONCellError.valueTooLarge }
        self.wallet = wallet
        self.path = path
        self.seqno = seqno
        self.validUntil = validUntil
        self.messages = messages
        self.mode = mode
        self.deploy = deploy

        var b = TONCellBuilder()
        switch wallet.version {
        case .v4r2:
            // subwallet_id, valid_until, seqno, op 0 (enviar) e ate 4 pares (modo, ^msg).
            guard messages.count <= 4 else { throw TONCellError.refOverflow }
            try b.storeUInt(UInt64(wallet.walletID), bits: 32)
            try b.storeUInt(UInt64(validUntil), bits: 32)
            try b.storeUInt(UInt64(seqno), bits: 32)
            try b.storeUInt(0, bits: 8)
            for message in messages {
                try b.storeUInt(UInt64(mode), bits: 8)
                try b.storeRef(message.cell())
            }
        case .v5r1:
            // op "sign" (0x7369676e), wallet_id, valid_until, seqno, Maybe ^OutList e
            // o bit de "sem acoes estendidas" (ton-blockchain/wallet-contract-v5,
            // `types.tlb`: signed_request$_ ... = SignedRequest).
            guard messages.count <= 255 else { throw TONCellError.refOverflow }
            try b.storeUInt(0x7369_676E, bits: 32)
            try b.storeUInt(UInt64(wallet.walletID), bits: 32)
            try b.storeUInt(UInt64(validUntil), bits: 32)
            try b.storeUInt(UInt64(seqno), bits: 32)
            try b.storeMaybeRef(Self.outList(messages, mode: mode))
            try b.storeBit(false)
        }
        unsigned = b
        signingHash = b.build().hash
    }

    /// `OutList`: lista encadeada de tras para frente. Cada no guarda o anterior na
    /// primeira referencia, `action_send_msg#0ec3c86d`, o modo e a mensagem.
    static func outList(_ messages: [TONOutgoingMessage], mode: UInt8) throws -> TONCell {
        var previous = TONCell.empty
        for message in messages {
            var node = TONCellBuilder()
            try node.storeRef(previous)
            try node.storeUInt(0x0EC3_C86D, bits: 32)
            try node.storeUInt(UInt64(mode), bits: 8)
            try node.storeRef(message.cell())
            previous = node.build()
        }
        return previous
    }

    public var signingRequests: [SigningRequest] {
        [SigningRequest(path: path, curve: .ed25519, scheme: .ed25519, payload: signingHash, expectedPublicKey: wallet.publicKey)]
    }

    /// Corpo assinado da carteira.
    func signedBody(signature: [UInt8]) throws -> TONCell {
        var b = TONCellBuilder()
        switch wallet.version {
        case .v4r2:
            try b.storeBytes(signature)
            try b.storeBuilder(unsigned)
        case .v5r1:
            try b.storeBuilder(unsigned)
            try b.storeBytes(signature)
        }
        return b.build()
    }

    /// `Message` com `ext_in_msg_info$10`: origem vazia, destino a carteira, import_fee
    /// 0, state init por referencia quando e a primeira transacao, corpo por referencia.
    func externalMessage(body: TONCell) throws -> TONCell {
        var b = TONCellBuilder()
        try b.storeUInt(0b10, bits: 2)
        try b.storeAddress(nil)
        try b.storeAddress(wallet.address)
        try b.storeCoins(0)
        if deploy {
            try b.storeBit(true)          // Maybe: tem init
            try b.storeBit(true)          // Either: por referencia
            try b.storeRef(wallet.stateInit)
        } else {
            try b.storeBit(false)
        }
        try b.storeBit(true)              // corpo por referencia
        try b.storeRef(body)
        return b.build()
    }

    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == 1 else { throw SigningError.wrongSignatureCount }
        let signature = signatures[0].bytes
        // O assinador ja verificou; conferir de novo custa pouco e impede que uma
        // assinatura de outra mensagem saia embrulhada nesta.
        guard signature.count == 64,
              Ed25519.verify(signature: signature, message: signingHash, publicKey: wallet.publicKey)
        else { throw SigningError.malformedSignature }
        let message = try externalMessage(body: signedBody(signature: signature))
        let boc = TONBOC.serialize(message)
        return SignedTransaction(
            chainID: Chain.ton.id,
            raw: boc,
            encoded: Data(boc).base64EncodedString(),
            id: Hex.encode(message.hash)
        )
    }
}
