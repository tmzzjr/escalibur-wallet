import Foundation

/// As unicas chaves que o app grava em `UserDefaults`. O arquivo de preferencias
/// fica fora do cofre (nao e cifrado nem protegido ate o desbloqueio), entao nada
/// que diga respeito as carteiras, a saldos ou a enderecos entra aqui. verificar.sh
/// recusa `UserDefaults` e `@AppStorage` em qualquer outro arquivo.
enum Preferences {
    private static let installMarkKey = "instalacao.marcada"
    private static let receiptChoiceKey = "recebimento.escolhido"
    private static let priceAlertChoiceKey = "alertas.escolhido"
    private static let receiptOfferKey = "recebimento.oferta.vista"

    /// Este app ja rodou nesta instalacao? Ver `KeyServices.firstLaunchCleanup`.
    static var installMarked: Bool {
        get { UserDefaults.standard.bool(forKey: installMarkKey) }
        set { UserDefaults.standard.set(newValue, forKey: installMarkKey) }
    }

    /// O aviso de recebimento ja foi ligado ou desligado (pelo dono ou pelo padrao)? So um
    /// sim ou nao: nada da carteira. Ver `ReceiptAccounts.shouldOffer`.
    static var receiptWatchChosen: Bool {
        get { UserDefaults.standard.bool(forKey: receiptChoiceKey) }
        set { UserDefaults.standard.set(newValue, forKey: receiptChoiceKey) }
    }

    /// A folha do aviso de recebimento, que diz o preco antes do "sim", ja foi respondida
    /// (ou o dono mexeu no aviso em Ajustes)? So um sim ou nao. Ver
    /// `ReceiptAccounts.shouldOffer`.
    static var receiptOfferSeen: Bool {
        get { UserDefaults.standard.bool(forKey: receiptOfferKey) }
        set { UserDefaults.standard.set(newValue, forKey: receiptOfferKey) }
    }

    /// Os alertas de preco ja foram ligados ou desligados (pelo dono ou pelo padrao)? So
    /// um sim ou nao. Ver `PriceAlertDefaults.enableByDefault`.
    static var priceAlertsChosen: Bool {
        get { UserDefaults.standard.bool(forKey: priceAlertChoiceKey) }
        set { UserDefaults.standard.set(newValue, forKey: priceAlertChoiceKey) }
    }
}
