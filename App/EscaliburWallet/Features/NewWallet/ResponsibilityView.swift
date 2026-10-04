import SwiftUI

/// Antes das palavras, ao criar e ao importar: o que muda numa carteira so do dono,
/// dito com calma, e o aceite de responsabilidade gravado nos metadados. Um
/// componente so para os dois caminhos.
///
/// Aparece toda vez que uma frase vai entrar ou nascer neste iPhone, com a caixa
/// desmarcada, mesmo para quem ja aceitou: e um evento raro, e e o momento em que o
/// aviso vale. Um aceite antigo nunca pula a tela.
struct ResponsibilityView: View {
    /// Versao do texto de aceite. Mudou o texto do aceite ou a clausula dos Termos,
    /// sobe o numero.
    static let version = 1

    @Environment(AppSession.self) private var session
    let continueTitle: String
    var loading: Bool = false
    let onContinue: () -> Void

    @State private var accepted = false
    @State private var legalDocument: LegalDocument?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: Space.md) {
                        point("lock.iphone", "Cifrada, só neste iPhone",
                              "Tudo da carteira é cifrado e fica guardado aqui, em nenhum outro lugar.")
                        point("eye.slash", "A Escalibur não vê nada",
                              "Não temos servidor com as suas chaves. Não temos como ver, mover nem recuperar nada.")
                        point("key.horizontal", "As palavras recuperam",
                              "A senha da carteira, as 12 ou 24 palavras, é a única forma de trazer a carteira de volta.")
                        point("hand.raised", "Ninguém da Escalibur pede",
                              "Nem por suporte, e-mail ou mensagem. Quem pedir as palavras quer o seu saldo.")
                    }
                    .padding(.top, Space.lg)
                    acceptance
                        .padding(.top, Space.lg)
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.xs)
            }
            .scrollBounceBehavior(.basedOnSize)
            ActionFooter {
                // Desligado, o botao diz o que falta: no iPhone pequeno a caixa fica
                // abaixo da dobra.
                PrimaryButton(title: accepted ? continueTitle : "Marque o aceite para continuar",
                              enabled: accepted, loading: loading) { accept() }
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .sheet(item: $legalDocument) { LegalDocumentView(document: $0) }
    }

    private var header: some View {
        VStack(spacing: Space.xs) {
            Image(systemName: "lock.shield")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Palette.control))
                .accessibilityHidden(true)
            Text("Só você tem a chave")
                .typeStyle(.title).foregroundStyle(Palette.ink)
                .padding(.top, Space.xs)
            Text("A carteira é só sua. Por isso, o cuidado com ela também é.")
                .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Palette.control))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).typeStyle(.row).foregroundStyle(Palette.ink)
                Text(detail).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// A caixa e a frase sao um botao so (tocar em qualquer parte marca); o link dos
    /// Termos fica logo abaixo, separado, para nao marcar a caixa sem querer.
    private var acceptance: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { toggle() } label: {
                HStack(alignment: .top, spacing: Space.sm) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accepted ? Palette.purple : Palette.void)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(accepted ? Color.clear : Palette.edgeStrong, lineWidth: 1.5))
                        .overlay {
                            if accepted {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 24, height: 24)
                        .padding(.top, 1)
                    Text("Entendo que só eu guardo a senha desta carteira. Se eu perder a senha ou alguém tiver acesso a ela, a Escalibur não tem como recuperar meus ativos. Li e aceito os Termos de uso.")
                        .typeStyle(.note).foregroundStyle(accepted ? Palette.ink : Palette.inkSoft)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(accepted ? "Marcado" : "Desmarcado")
            .accessibilityAddTraits(accepted ? .isSelected : [])
            .accessibilityIdentifier("aceite-responsabilidade")
            .sensoryFeedback(.selection, trigger: accepted)

            Button { legalDocument = .terms } label: {
                HStack(spacing: Space.xxs) {
                    Text("Ler os Termos de uso").typeStyle(.note).fontWeight(.semibold).underline()
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Palette.ink)
                .frame(minHeight: Height.touch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 24 + Space.sm)
            .padding(.top, Space.xxs)
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAddTraits(.isLink)
            .accessibilityIdentifier("link-termos")
        }
        .padding(.horizontal, Space.md)
        .padding(.top, Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.body)
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(accepted ? Palette.purple : Palette.edge, lineWidth: 1))
        )
        .animation(Motion.select, value: accepted)
    }

    private func toggle() {
        withAnimation(Motion.select) { accepted.toggle() }
    }

    private func accept() {
        guard accepted else { return }
        session.acceptResponsibility(version: Self.version)
        onContinue()
    }
}
