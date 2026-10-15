import SwiftUI

/// O contato da Escalibur. O mesmo e-mail esta na pagina publica de suporte
/// (`site/suporte.md`), nos Termos e na Politica; verificar.sh confere os quatro.
enum SupportContact {
    static let email = "thomaz@xtech.international"

    /// O e-mail com a versao do app no assunto, e nada mais: nem endereco, nem saldo.
    static var mailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        components.queryItems = [URLQueryItem(name: "subject", value: "Escalibur Wallet \(version) (\(build))")]
        return components.url
    }
}

/// Ajustes, Suporte: como falar com a Escalibur e o que ela nunca pede.
struct SupportView: View {
    @Environment(\.openURL) private var openURL
    @State private var noMailApp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Fale com a Escalibur").typeStyle(.heading).foregroundStyle(Palette.ink)
                    Text("Dúvidas, problemas ou sugestões: escreva para este endereço.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    Text(SupportContact.email).typeStyle(.row).foregroundStyle(Palette.ink)
                        .textSelection(.enabled).padding(.top, Space.xxs)
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    PrimaryButton(title: String(localized: "Escrever e-mail")) {
                        guard let url = SupportContact.mailURL else { return }
                        openURL(url) { accepted in noMailApp = !accepted }
                    }
                    if noMailApp {
                        Text("Nenhum app de e-mail abriu. Toque e segure o endereço acima para copiar.")
                            .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Nunca mande as palavras da carteira").typeStyle(.heading).foregroundStyle(Palette.ink)
                    Text("Ninguém da Escalibur pede a senha da carteira, o PIN ou a senha de um envelope, nem pelo suporte. Quem pede quer o seu saldo.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("O que o suporte não consegue fazer").typeStyle(.heading).foregroundStyle(Palette.ink)
                    Text("A carteira roda só neste iPhone. A Escalibur não vê, não move e não devolve saldo, e não desfaz transação.")
                        .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.gutter)
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("Suporte")
        .navigationBarTitleDisplayMode(.inline)
    }
}
