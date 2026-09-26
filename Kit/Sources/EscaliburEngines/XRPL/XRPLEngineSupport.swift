import EscaliburChains
import EscaliburCore
import EscaliburNetwork
import Foundation

/// O que os motores do XRP Ledger tem em comum: a conta que assina, a tag, o id e a
/// validade de uma transacao assinada, os tokens da lista curada e as frases de erro.
enum XRPLEngineSupport {
    // MARK: Conta

    /// A conta do dono no XRP Ledger, conferida: rede certa, chave publica comprimida que
    /// da o proprio endereco. O planejador recebe a conta no tipo dele (caminho e chave
    /// publica, dado publico de EscaliburChains), montado em cada chamada com
    /// `.init(path:publicKey:)`, que confere a chave de novo.
    @discardableResult
    static func owner(_ account: DerivedAccount) throws -> String {
        guard account.chainID == Chain.xrpl.id, account.publicKey.count == 33,
              (try? Address.from(publicKey: account.publicKey, chain: .xrpl)) == account.address
        else { throw SendEngineError.message(NetworkFailureText.wrongAccount) }
        return account.address
    }

    /// A tag digitada: inteiro de 32 bits, so digitos.
    static func tag(_ text: String?) throws -> UInt32? {
        guard let text, !text.isEmpty else { return nil }
        guard text.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let tag = UInt32(text) else {
            throw SendEngineError.message("A tag de destino é um número de 0 a 4.294.967.295. Confira com quem pediu o envio.")
        }
        return tag
    }

    static func xrp(_ drops: BigUInt) -> String {
        EngineFormat.amount(drops, decimals: Chain.xrpl.nativeDecimals, symbol: "XRP")
    }

    // MARK: Transacao assinada

    /// O id calculado aqui dos bytes assinados: SHA512Half("TXN\0" + blob), em hex
    /// maiusculo como o explorador mostra. Tem de ser o id que a transacao carrega.
    static func localID(_ signed: SignedTransaction) throws -> String {
        guard signed.chainID == Chain.xrpl.id, Hex.decode(signed.encoded) == signed.raw else {
            throw SendEngineError.message(NetworkFailureText.inconsistent)
        }
        let id = Hex.encode(Hash.sha512Half([0x54, 0x58, 0x4E, 0x00] + signed.raw)).uppercased()
        guard id == signed.id.uppercased() else { throw SendEngineError.message(NetworkFailureText.inconsistent) }
        return id
    }

    /// O `LastLedgerSequence` gravado na transacao serializada.
    ///
    /// Na serializacao canonica os campos vem por tipo e depois por numero. O primeiro e o
    /// TransactionType (UInt16, campo 2: cabecalho 0x12 e dois bytes); logo depois vem
    /// todos os UInt32 (tipo 2), cada um com cabecalho de um byte (0x2n, campo menor que
    /// 16) ou de dois (0x20 e o campo), seguido de quatro bytes big-endian. O
    /// LastLedgerSequence e o campo 27. A leitura para no primeiro campo de outro tipo.
    static func lastLedgerSequence(_ blob: [UInt8]) -> UInt32? {
        guard blob.count >= 3, blob[0] == 0x12 else { return nil }
        var index = 3
        while index < blob.count, blob[index] >> 4 == 2 {
            var field = Int(blob[index] & 0x0F)
            index += 1
            if field == 0 {
                guard index < blob.count else { return nil }
                field = Int(blob[index])
                index += 1
            }
            guard index + 4 <= blob.count else { return nil }
            let value = blob[index..<(index + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            index += 4
            if field == 27 { return value }
        }
        return nil
    }

    // MARK: Tokens

    /// Os tokens do XRP Ledger na lista curada (`TokenRegistry`): codigo de moeda do
    /// ledger (3 letras ou 40 hex) e emissor.
    static var registryAssets: [Asset] {
        TokenRegistry.tokens.filter { asset in
            guard asset.chainID == Chain.xrpl.id, case .issued = asset.kind else { return false }
            return true
        }
    }

    static func curated(_ asset: Asset) -> XRPLCuratedAsset? {
        guard asset.chainID == Chain.xrpl.id, case .issued(let code, let issuer) = asset.kind,
              let currency = try? XRPLCurrency(code: code)
        else { return nil }
        return try? XRPLCuratedAsset(currency: currency, issuer: issuer, issuerName: asset.name)
    }

    // MARK: Erros

    static func text(_ error: XRPLPlanError) -> String {
        switch error {
        case .stateForOtherAccount, .implausibleReserve, .invalidLedgerIndex, .destinationStateMismatch:
            return NetworkFailureText.malformed
        case .masterKeyDisabled:
            return "Esta conta desativou a chave mestra no XRP Ledger. A carteira não tem a chave que assina por ela."
        case .sequenceUnconfirmed, .destinationUnconfirmed:
            return NetworkFailureText.fewSources
        case .sequenceMismatch, .destinationReadingsDisagree:
            return NetworkFailureText.disagree
        case .feeAboveCap:
            return "A taxa da rede está acima do teto da carteira agora. Espere a rede acalmar e tente de novo."
        case .insufficientFunds:
            return "XRP livre insuficiente para este valor mais a taxa. A reserva da conta fica presa pela rede."
        case .invalidDestination(let problem):
            switch problem {
            case .badChecksum: return "Um caractere deste endereço não confere. Copie de novo, inteiro."
            case .otherNetwork(let other): return "Este endereço é da rede \(other.name), não do XRP Ledger."
            default: return "Este não é um endereço do XRP Ledger."
            }
        case .sendToSelf:
            return "O destino é a própria conta."
        case .conflictingDestinationTag:
            return "O endereço já traz uma tag, e a tag digitada é outra. Confira com quem pediu o envio."
        case .destinationTagRequired:
            return "Esta conta exige tag de destino. Sem ela o depósito se perde."
        case .destinationDisallowsXRP:
            return "Esta conta pediu para não receber XRP. Nesta versão a carteira não envia para ela."
        case .depositNotAuthorized:
            return "Esta conta só aceita depósitos de quem ela autorizou antes, e esta carteira não está entre eles."
        case .belowActivationReserve:
            return "A conta de destino ainda não existe. O primeiro envio precisa ser do mínimo que ativa a conta."
        case .zeroAmount:
            return "O valor precisa ser maior que zero."
        case .amountTooLarge:
            return "O valor passa do máximo que o XRP Ledger representa."
        case .invalidValue, .invalidMemo:
            return "O valor tem casas demais para o XRP Ledger."
        case .assetNotCurated:
            return "Este token não está na lista de ativos da carteira."
        case .sameAssetBothSides, .xrpBothSides:
            return "Os dois lados da troca são o mesmo ativo."
        case .expirationInPast:
            return "A validade da ordem precisa ser de pelo menos um minuto."
        case .expirationTooFar(let maxDays):
            return "A validade máxima de uma ordem é de \(maxDays) dias."
        case .invalidOfferSequence:
            return "Oferta inválida."
        case .transaction:
            return "A transação não passou na conferência de montagem. Nada foi montado."
        }
    }

    static func translate(_ error: Error) -> Error {
        if let planError = error as? XRPLPlanError { return SendEngineError.message(text(planError)) }
        return NetworkFailureText.error(error)
    }
}

/// Onde as transacoes transmitidas por este processo vencem: o id e o
/// `LastLedgerSequence`, para o acompanhamento saber quando "nao achada" passa a ser
/// "venceu sem entrar". Depois desse ledger a transacao nao entra mais.
enum XRPLSubmissions {
    static let lastLedger = ShortLivedMemory<String, UInt32>(lifetime: 60 * 60, capacity: 128)
}
