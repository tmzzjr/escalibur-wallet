import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

// O que os motores EVM (envio, historico e troca) tem em comum.
//
// - A conta que assina e remontada da chave publica derivada, e o endereco guardado tem
//   de bater com ela: um endereco "do dono" que viesse separado poderia ser de outra
//   conta.
// - O ativo sai da lista curada (`TokenRegistry`), com contrato e casas decimais
//   compilados. Um `Asset` que nao esteja la nao vira transacao.
// - Os bytes assinados so saem para a rede depois de conferidos contra a transacao do
//   plano, e em ordem de nonce.

/// Os motivos de recusa proprios dos motores EVM. A tela nunca ve este tipo: ele passa
/// por `EVMEngineMessages` e vira `SendEngineError.message`.
enum EVMEngineFailure: Error, Equatable, Sendable {
    /// O pedido e de outra rede que nao a deste motor.
    case wrongChain
    /// A conta derivada nao e desta rede, ou o endereco guardado nao e o da chave.
    case accountMismatch
    /// Token fora da lista curada, ou com casas decimais diferentes das compiladas.
    case assetNotListed
    /// Moeda custom cujas casas decimais na rede nao sao mais as salvas.
    case customDecimalsChanged
    /// Tag, memo ou comentario num envio EVM, que nao tem esse campo.
    case tagNotSupported
    /// O plano saiu com um destinatario diferente do pedido.
    case recipientMismatch
    /// A simulacao do `transfer` devolveu `false`: o token recusaria sem reverter.
    case transferReturnedFalse
    /// Os bytes assinados nao sao as transacoes do plano, ou nao estao em sequencia.
    case batchMismatch
    /// Parte do lote foi transmitida e parte nao.
    case partialBroadcast
    /// A cotacao nao e deste pedido (outro par, outro valor, provedor desconhecido).
    case quoteMismatch
    case quoteExpired
    /// O garantido da recotacao ficou abaixo do que a tela mostrou, alem da tolerancia.
    case priceMoved
    /// O impacto no preco subiu desde a cotacao e agora pede a confirmacao do dono.
    case riskIncreased
    /// Nenhum provedor devolveu cotacao valida.
    case noQuote
    /// Houve cotacoes, mas todas foram recusadas pela validacao.
    case allQuotesRefused
    case limitOrdersUnavailable
    /// O preco-alvo nao cabe num decimal exato que reproduza o minimo pedido.
    case limitPriceNotRepresentable
    /// Ja existe ordem aberta vendendo o mesmo token.
    case openOrderExists
    /// O plano da ordem limite venceu ou nao foi montado por este app.
    case pendingOrderMissing
    /// A autorizacao (ou o embrulho) da ordem limite falhou na cadeia.
    case prerequisiteFailed
    /// A autorizacao da ordem limite nao confirmou a tempo.
    case prerequisiteTimedOut
    /// O cancelamento nao e de ordens desta conta.
    case invalidOrderReference
}

/// Um ativo do pedido, ja conferido contra a lista curada.
enum EVMResolvedAsset: Sendable, Equatable {
    case native
    case token(EVMToken)

    func tradeAsset(on chain: Chain) -> TradeAsset {
        switch self {
        case .native: return .native(chain)
        case .token(let token): return .token(token)
        }
    }
}

enum EVMEngineSupport {
    /// As redes EVM com motor: as sete compiladas, cada uma com chainId e perfil de taxa.
    static func isSupported(_ chain: Chain) -> Bool {
        chain.family == .evm && chain.evmChainID != nil && EVMFeeProfile.for(chain) != nil
    }

    /// A conta que assina, remontada da chave publica derivada. O endereco guardado tem
    /// de ser o que sai da chave, e a conta tem de ser desta rede.
    static func account(_ derived: DerivedAccount, chain: Chain) throws -> EVMAccount {
        guard derived.chainID == chain.id else { throw EVMEngineFailure.accountMismatch }
        let account: EVMAccount
        do {
            account = try EVMAccount(path: derived.path, publicKey: derived.publicKey)
        } catch {
            throw EVMEngineFailure.accountMismatch
        }
        guard Address.sameRecipient(derived.address, account.address.checksummed, chain: chain) else {
            throw EVMEngineFailure.accountMismatch
        }
        return account
    }

    /// O ativo do pedido pela lista curada. Do `Asset` que o app manda so se usa o
    /// contrato para achar a entrada; simbolo e casas decimais vem da lista, e casas
    /// diferentes recusam (o valor digitado seria lido em outra escala).
    ///
    /// `allowCustom` (so o envio): uma moeda custom do dono, fora da lista, vira token com
    /// o contrato e as casas salvas. O motor rele as casas na rede, em dois provedores,
    /// antes de montar (`EVMSendEngine`), e a revisao leva o aviso de nao verificado.
    /// Contrato da lista nunca vira custom: com o mesmo contrato, vale a lista.
    static func resolve(_ asset: Asset, on chain: Chain, allowCustom: Bool = false) throws -> EVMResolvedAsset {
        guard asset.chainID == chain.id else { throw EVMEngineFailure.assetNotListed }
        switch asset.kind {
        case .native:
            guard asset.decimals == chain.nativeDecimals else { throw EVMEngineFailure.assetNotListed }
            return .native
        case .token(let contract):
            if let listed = TokenRegistry.find(chainID: chain.id, contract: contract) {
                guard listed.decimals == asset.decimals, case .token(let listedContract) = listed.kind,
                      let address = try? EVMAddress(listedContract), let decimals = UInt8(exactly: listed.decimals)
                else { throw EVMEngineFailure.assetNotListed }
                return .token(EVMToken(chain: chain, contract: address, symbol: listed.symbol, decimals: decimals))
            }
            guard allowCustom, asset.isCustom, let address = try? EVMAddress(contract),
                  let decimals = UInt8(exactly: asset.decimals), decimals <= 36
            else { throw EVMEngineFailure.assetNotListed }
            let symbol = TokenSafety.clean(asset.symbol, limit: TokenSafety.symbolLimit)
            return .token(EVMToken(chain: chain, contract: address, symbol: symbol.isEmpty ? String(address.checksummed.prefix(6)) : symbol, decimals: decimals))
        case .issued:
            throw EVMEngineFailure.assetNotListed
        }
    }

    /// Destinos que um envio nunca aceita (docs/seguranca.md 4.8): routers e spenders da
    /// troca, os contratos da CoW, os tokens da lista e o nativo embrulhado. Valor mandado
    /// a eles nao chega a carteira de ninguem, e "enviar para o contrato do token" e o
    /// erro que prende o saldo para sempre.
    static func sendPolicy(_ chain: Chain) -> EVMCallPolicy {
        var blocked = Set<EVMAddress>()
        for router in TradeAllowlist.routers(on: chain) {
            blocked.insert(router.address)
            blocked.insert(router.spender)
        }
        if CoWProtocol.supports(chain) {
            blocked.insert(CoWProtocol.settlement)
            blocked.insert(CoWProtocol.vaultRelayer)
        }
        if let wrapped = CoWProtocol.wrappedNative(on: chain) { blocked.insert(wrapped.contract) }
        for asset in TokenRegistry.assets(on: chain) {
            if case .token(let contract) = asset.kind, let address = try? EVMAddress(contract) { blocked.insert(address) }
        }
        return EVMCallPolicy(blockedRecipients: blocked)
    }

    static func speed(_ level: FeeLevel) -> EVMFeeSpeed {
        switch level {
        case .slow: return .slow
        case .normal: return .normal
        case .fast: return .fast
        }
    }

    /// A mesma revisao com avisos a mais. O plano e remontado com as mesmas transacoes e
    /// o mesmo instante de criacao, para o prazo de 60 s continuar contando do mesmo ponto.
    static func adding(_ warnings: [PlanReview.Warning], to plan: SigningPlan) -> SigningPlan {
        plan.addingWarnings(warnings)
    }

    // MARK: Lote assinado

    /// Os bytes assinados sao a transacao do plano: mesma rede, tipo 2, os campos sem
    /// assinatura sao o comeco da lista assinada (chainId ate accessList; depois vem
    /// yParity, r e s) e o id e o keccak dos bytes. Pega lote trocado ou fora de ordem
    /// antes de qualquer transmissao. Os planos destes motores so montam tipo 2.
    static func matches(_ signed: SignedTransaction, _ transaction: EVMTransaction) -> Bool {
        guard signed.chainID == transaction.chain.id, transaction.transactionType == 2,
              signed.raw.first == 0x02, transaction.signingPayload.first == 0x02,
              signed.id.lowercased() == Hex.encode(Hash.keccak256(signed.raw), prefix: true),
              let unsigned = EVMRLPList.payload(transaction.signingPayload.dropFirst()),
              let assembled = EVMRLPList.payload(signed.raw.dropFirst())
        else { return false }
        // yParity (1 byte) mais r e s (ate 33 bytes cada, com prefixo).
        let signatureBytes = assembled.count - unsigned.count
        return (3...67).contains(signatureBytes) && assembled.starts(with: unsigned)
    }

    /// Emparelha o lote assinado com as transacoes do plano, na mesma ordem, e devolve os
    /// pares em ordem de nonce. Exige nonces em sequencia, sem buraco nem repeticao: uma
    /// transacao com nonce a frente ficaria parada ate alguem preencher o buraco.
    static func pairs(_ signed: [SignedTransaction], _ transactions: [EVMTransaction]) throws -> [(EVMTransaction, SignedTransaction)] {
        guard !transactions.isEmpty, signed.count == transactions.count else { throw EVMEngineFailure.batchMismatch }
        let paired = zip(transactions, signed).map { ($0, $1) }
        guard paired.allSatisfy({ matches($0.1, $0.0) }) else { throw EVMEngineFailure.batchMismatch }
        let ordered = paired.sorted { $0.0.nonce < $1.0.nonce }
        for (index, pair) in ordered.enumerated() where pair.0.nonce != ordered[0].0.nonce + UInt64(index) {
            throw EVMEngineFailure.batchMismatch
        }
        return ordered
    }

    /// Transmite um por um, em ordem de nonce, e devolve os ids calculados aqui a partir
    /// dos bytes. Se um falhar depois de outro ter saido, o erro diz que o lote ficou
    /// pela metade: a tela manda conferir a Atividade em vez de repetir.
    static func broadcast(
        _ ordered: [(EVMTransaction, SignedTransaction)], chain: Chain, route: EVMBroadcastRoute, reader: EVMReader
    ) async throws -> [String] {
        var ids = [String]()
        for (_, signed) in ordered {
            let local = Hex.encode(Hash.keccak256(signed.raw), prefix: true)
            do {
                let receipt = try await reader.broadcast(signed, chain: chain, route: route)
                guard receipt.id.lowercased() == local else { throw ReaderError.broadcastMismatch }
            } catch {
                if ids.isEmpty { throw error }
                throw EVMEngineFailure.partialBroadcast
            }
            ids.append(local)
        }
        return ids
    }
}

/// O cabecalho de lista RLP, so o necessario para comparar a transacao sem assinatura com
/// a assinada. Nada que vem de provedor passa por aqui: os dois lados sao bytes locais.
enum EVMRLPList {
    /// O conteudo de uma lista RLP que ocupa exatamente `bytes`, ou `nil`.
    static func payload(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        guard let first = bytes.first else { return nil }
        let start = bytes.startIndex
        switch first {
        case 0xC0...0xF7:
            let length = Int(first - 0xC0)
            guard bytes.count == 1 + length else { return nil }
            return bytes[(start + 1)...]
        case 0xF8...0xFF:
            let lengthOfLength = Int(first - 0xF7)
            guard lengthOfLength <= 4, bytes.count > 1 + lengthOfLength else { return nil }
            var length = 0
            for byte in bytes[(start + 1)...(start + lengthOfLength)] { length = length << 8 | Int(byte) }
            guard length >= 56, bytes.count == 1 + lengthOfLength + length else { return nil }
            return bytes[(start + 1 + lengthOfLength)...]
        default:
            return nil
        }
    }
}

/// Texto exato de valor, no formato da revisao (`EVMText` de EscaliburChains, que e
/// interno ao modulo): sem arredondar, virgula decimal, ponto de milhar, espaco nao
/// separavel antes do simbolo.
enum EVMEngineText {
    static func amount(_ value: BigUInt, decimals: Int, symbol: String) -> String {
        let digits = Array(value.decimalString)
        let padded = [Character](repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let integer = Array(padded.prefix(padded.count - decimals))
        var fraction = Array(padded.suffix(decimals))
        while fraction.last == "0" { fraction.removeLast() }
        var grouped = [Character]()
        for (index, digit) in integer.enumerated() {
            if index > 0, (integer.count - index) % 3 == 0 { grouped.append(".") }
            grouped.append(digit)
        }
        let number = fraction.isEmpty ? String(grouped) : String(grouped) + "," + String(fraction)
        return number + "\u{00A0}" + symbol
    }

    static func amount(_ value: BigUInt, _ asset: TradeAsset) -> String {
        amount(value, decimals: asset.decimals, symbol: asset.symbol)
    }

    /// `2500` bps -> "25%"; `1250` -> "12,5%".
    static func percent(bps: Int) -> String {
        let integer = bps / 100
        var fraction = String(format: "%02d", bps % 100)
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? "\(integer)%" : "\(integer),\(fraction)%"
    }
}
