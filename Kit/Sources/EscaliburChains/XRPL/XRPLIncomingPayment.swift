import EscaliburCore
import Foundation

/// Leitura segura de um pagamento recebido no XRP Ledger.
///
/// **O valor recebido e `meta.delivered_amount`, nunca `Amount` nem `DeliverMax`.**
/// Com tfPartialPayment, o `Amount` e so um teto: o golpe classico manda um pagamento
/// parcial com `Amount` de 1.000 XRP que entrega 0,000001 XRP, e a carteira que le
/// `Amount` mostra 1.000 XRP recebidos (docs/seguranca.md §4.8). Esta leitura nao
/// tem caminho que chegue ao `Amount`: se o `delivered_amount` nao esta la, o
/// resultado diz que o valor e desconhecido, e a tela nao inventa um.
public enum XRPLIncomingPayment {

    /// Um pagamento validado, com o que de fato chegou.
    public struct Delivery: Sendable, Equatable {
        public let hash: String?
        public let sender: String
        public let destination: String
        public let destinationTag: UInt32?
        /// O que o destino recebeu (`meta.delivered_amount`).
        public let delivered: XRPLAmount
        /// A transacao tinha tfPartialPayment. A tela marca, porque e o formato do golpe
        /// mesmo quando o valor entregue esta certo.
        public let isPartialPayment: Bool
        public let ledgerIndex: UInt32?
    }

    public enum Reading: Sendable, Equatable {
        case delivered(Delivery)
        /// Sem `validated: true`: pode sumir ou mudar. Nao mostrar como recebido.
        case notValidated
        /// Resultado diferente de tesSUCCESS (tec...): a taxa foi cobrada, nada entregue.
        case failed(result: String)
        /// Sem `delivered_amount` (ou "unavailable", em transacoes anteriores a 2014).
        case deliveredAmountUnavailable
        /// Nao e um Payment.
        case notAPayment
        /// Ativo que a carteira nao le (MPT) ou JSON fora do formato.
        case unsupported
    }

    /// Le o JSON de uma transacao com meta, como o rippled devolve.
    ///
    /// Aceita a API v2 (`tx_json` + `meta` + `validated`, resposta de `tx` e item de
    /// `account_tx`) e as formas antigas (`transaction` do stream `subscribe`, campos da
    /// transacao no topo, `metaData`).
    public static func read(json data: Data) -> Reading {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unsupported }
        return read(object: object)
    }

    public static func read(object root: [String: Any]) -> Reading {
        // A resposta completa do `tx` embrulha tudo em `result`.
        let top = (root["result"] as? [String: Any]) ?? root
        let tx = (top["tx_json"] as? [String: Any]) ?? (top["transaction"] as? [String: Any])
            ?? (top["tx"] as? [String: Any]) ?? top

        guard (tx["TransactionType"] as? String) == "Payment" else { return .notAPayment }
        guard (top["validated"] as? Bool) == true else { return .notValidated }
        guard let meta = (top["meta"] as? [String: Any]) ?? (top["metaData"] as? [String: Any]) else {
            return .deliveredAmountUnavailable
        }
        guard let result = meta["TransactionResult"] as? String else { return .unsupported }
        guard result == "tesSUCCESS" else { return .failed(result: result) }

        // `delivered_amount` e o campo sintetico da API; `DeliveredAmount` e o campo do
        // meta que o rippled grava em pagamentos parciais. Os dois dizem o entregue.
        guard let raw = meta["delivered_amount"] ?? meta["DeliveredAmount"] else { return .deliveredAmountUnavailable }
        if let text = raw as? String, text == "unavailable" { return .deliveredAmountUnavailable }
        guard let delivered = try? XRPLAmount.fromJSON(raw) else { return .unsupported }

        guard let sender = tx["Account"] as? String, XRPLAddress.accountID(sender) != nil,
              let destination = tx["Destination"] as? String, XRPLAddress.accountID(destination) != nil
        else { return .unsupported }

        var tag: UInt32?
        if let rawTag = tx["DestinationTag"] {
            guard let value = uint32(rawTag) else { return .unsupported }
            tag = value
        }
        var flags: UInt32 = 0
        if let rawFlags = tx["Flags"] {
            guard let value = uint32(rawFlags) else { return .unsupported }
            flags = value
        }

        let hash = (top["hash"] as? String) ?? (tx["hash"] as? String)
        let ledgerIndex = (top["ledger_index"]).flatMap(uint32) ?? (tx["ledger_index"]).flatMap(uint32)
        return .delivered(Delivery(
            hash: hash?.uppercased(),
            sender: sender,
            destination: destination,
            destinationTag: tag,
            delivered: delivered,
            isPartialPayment: flags & XRPLTransactionFlags.partialPayment != 0,
            ledgerIndex: ledgerIndex
        ))
    }

    /// Inteiro JSON sem sinal de ate 32 bits. Numero com parte fracionaria ou booleano
    /// nao passa.
    static func uint32(_ any: Any) -> UInt32? {
        guard let number = any as? NSNumber, !CFNumberIsFloatType(number),
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.int64Value
        guard value >= 0, value <= Int64(UInt32.max) else { return nil }
        return UInt32(value)
    }
}
