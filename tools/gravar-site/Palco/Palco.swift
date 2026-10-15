import SwiftUI

// O app vazio que hospeda o alvo de UI test. Quem aparece nas gravacoes e a Escalibur
// Wallet, aberta pelo bundle id em Cenas.swift.
@main
struct Palco: App {
    var body: some Scene {
        WindowGroup { Color.black.ignoresSafeArea() }
    }
}
