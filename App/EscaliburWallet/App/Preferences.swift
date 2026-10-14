import Foundation

/// As unicas chaves que o app grava em `UserDefaults`. O arquivo de preferencias
/// fica fora do cofre (nao e cifrado nem protegido ate o desbloqueio), entao nada
/// que diga respeito as carteiras, a saldos ou a enderecos entra aqui. verificar.sh
/// recusa `UserDefaults` e `@AppStorage` em qualquer outro arquivo.
enum Preferences {
    private static let installMarkKey = "instalacao.marcada"
    private static let receiptChoiceKey = "recebimento.escolhido"

    /// Este app ja rodou nesta instalacao? Ver `KeyServices.firstLaunchCleanup`.
    static var installMarked: Bool {
        get { UserDefaults.standard.bool(forKey: installMarkKey) }
        set { UserDefaults.standard.set(newValue, forKey: installMarkKey) }
    }

    /// O aviso de recebimento ja foi ligado ou desligado (pelo dono ou pelo padrao)? So um
    /// sim ou nao: nada da carteira. Ver `ReceiptAccounts.enableByDefault`.
    static var receiptWatchChosen: Bool {
        get { UserDefaults.standard.bool(forKey: receiptChoiceKey) }
        set { UserDefaults.standard.set(newValue, forKey: receiptChoiceKey) }
    }
}
