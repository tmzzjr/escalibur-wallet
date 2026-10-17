import EscaliburChains
import EscaliburCore
import MessageUI
import SwiftUI

/// O contato da Escalibur. O mesmo e-mail esta na pagina publica de suporte
/// (`site/suporte.md`), nos Termos e na Politica; verificar.sh confere os quatro.
enum SupportContact {
    static let email = "thomaz@xtech.international"

    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(version) (\(build))"
    }

    /// O chamado como e-mail, para quando nao ha conta no app Mail: o app de e-mail que
    /// estiver instalado abre com tudo preenchido.
    static func mailURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return components.url
    }
}

/// Ajustes, Suporte: um questionario curto que vira um chamado por e-mail (pedido do dono,
/// 16/10/2026). O endereco do suporte nao aparece na tela; a resposta vai para o e-mail
/// que a pessoa digita duas vezes. Vai junto so o que ela escreveu, esse e-mail, a versao
/// do app e a do iOS: nem endereco da carteira, nem saldo, e nada fica guardado. Sem chat
/// nem resposta dentro do app, que pediriam servidor. Texto com cara de senha da carteira
/// nao sai.
struct SupportView: View {
    enum Topic: String, CaseIterable, Identifiable {
        case transfer, trade, balance, access, restore, idea, other
        var id: String { rawValue }

        var title: String {
            switch self {
            case .transfer: return String(localized: "Envio ou recebimento")
            case .trade: return String(localized: "Troca ou ponte")
            case .balance: return String(localized: "Saldo que não aparece")
            case .access: return String(localized: "Entrar no app: PIN ou Face ID")
            case .restore: return String(localized: "Importar ou recuperar uma carteira")
            case .idea: return String(localized: "Sugestão")
            case .other: return String(localized: "Outro assunto")
            }
        }

        var icon: String {
            switch self {
            case .transfer: return "arrow.up.arrow.down"
            case .trade: return "arrow.left.arrow.right"
            case .balance: return "eye.slash"
            case .access: return "faceid"
            case .restore: return "arrow.counterclockwise"
            case .idea: return "lightbulb"
            case .other: return "ellipsis.bubble"
            }
        }

        /// Assuntos em que a rede e a transacao ajudam a achar o problema.
        var asksNetwork: Bool { [.transfer, .trade, .balance].contains(self) }
        var asksTransaction: Bool { [.transfer, .trade].contains(self) }
    }

    @State private var topic: Topic?
    @State private var chain: Chain?
    @State private var details = ""
    @State private var transaction = ""
    /// O e-mail para a resposta, digitado duas vezes (pedido do dono, 16/10/2026). Fica so
    /// nesta tela: vai no chamado e nada e guardado.
    @State private var email = ""
    @State private var emailAgain = ""
    @State private var composing = false
    @State private var noMailApp = false
    @State private var sent = false
    @Environment(\.openURL) private var openURL
    @FocusState private var writing: Bool

    /// Seis palavras seguidas da lista BIP-39 e texto de senha da carteira, nao conversa.
    private var looksLikePhrase: Bool { Self.longestWordRun(details) >= 6 || Self.longestWordRun(transaction) >= 6 }
    private var replyEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var emailValid: Bool { replyEmail.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]{2,}/) != nil }
    private var emailsMatch: Bool { replyEmail.lowercased() == emailAgain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var canSend: Bool {
        topic != nil && details.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10 && !looksLikePhrase
            && emailValid && emailsMatch
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Fale com o suporte").typeStyle(.title).foregroundStyle(Palette.ink)
                Text("Conte o que aconteceu em poucos passos. O chamado vai para o suporte da Escalibur, e a resposta chega no seu e-mail.")
                    .typeStyle(.body).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xs)

                step(1, String(localized: "Sobre o que é?")).padding(.top, Space.lg)
                VStack(spacing: 0) {
                    ForEach(Topic.allCases) { option in
                        Button {
                            withAnimation(Motion.select) { topic = option }
                        } label: {
                            HStack(spacing: Space.sm) {
                                Image(systemName: option.icon).font(.system(size: 16, weight: .regular))
                                    .foregroundStyle(Palette.inkSoft).frame(width: 28)
                                Text(option.title).typeStyle(.body).foregroundStyle(Palette.ink)
                                Spacer()
                                if topic == option {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Palette.success)
                                }
                            }
                            .padding(.horizontal, Space.md)
                            .frame(minHeight: Height.rowCompact)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowStyle(surface: .body))
                        .accessibilityAddTraits(topic == option ? .isSelected : [])
                        .accessibilityIdentifier("suporte-assunto-\(option.rawValue)")
                    }
                }
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .padding(.top, Space.sm)
                .sensoryFeedback(.selection, trigger: topic)

                if topic?.asksNetwork == true {
                    step(2, String(localized: "Em qual rede?")).padding(.top, Space.lg)
                    Menu {
                        Button(String(localized: "Não sei")) { chain = nil }
                        ForEach(Chain.all) { option in
                            Button(option.name) { chain = option }
                        }
                    } label: {
                        HStack(spacing: Space.xs) {
                            if let chain { NetworkBadge(chain: chain, size: 22, ring: .clear) }
                            Text(chain?.name ?? String(localized: "Não sei")).typeStyle(.body).foregroundStyle(Palette.ink)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkMuted)
                        }
                        .padding(.horizontal, Space.md)
                        .frame(height: Height.field)
                        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                    }
                    .padding(.top, Space.sm)
                }

                step(topic?.asksNetwork == true ? 3 : 2, String(localized: "O que aconteceu?")).padding(.top, Space.lg)
                ZStack(alignment: .topLeading) {
                    if details.isEmpty {
                        Text("O que você fez, o que esperava e o que apareceu na tela.")
                            .typeStyle(.body).foregroundStyle(Palette.inkMuted)
                            .padding(.horizontal, Space.md).padding(.vertical, Space.sm + 2)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $details)
                        .typeStyle(.body).foregroundStyle(Palette.ink)
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled(false)
                        .focused($writing)
                        .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
                        .frame(minHeight: 132)
                        .accessibilityIdentifier("suporte-texto")
                }
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                .padding(.top, Space.sm)
                if looksLikePhrase {
                    Banner(kind: .failure, title: String(localized: "Isto parece a senha da carteira"),
                           message: String(localized: "Apague as palavras antes de mandar. Ninguém da Escalibur precisa delas, nem para ajudar."))
                        .padding(.top, Space.sm)
                }

                if topic?.asksTransaction == true {
                    Text("ID da transação, se tiver").typeStyle(.note).foregroundStyle(Palette.inkSoft).padding(.top, Space.md)
                    TextField("", text: $transaction, prompt: Text("Copie na Atividade, no detalhe do envio").foregroundStyle(Palette.inkMuted))
                        .typeStyle(.body).foregroundStyle(Palette.ink)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($writing)
                        .padding(.horizontal, Space.md).frame(height: Height.field)
                        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                        .padding(.top, Space.xs)
                }

                step(topic?.asksNetwork == true ? 4 : 3, String(localized: "Seu e-mail para a resposta")).padding(.top, Space.lg)
                emailField(String(localized: "seu@email.com"), text: $email, id: "suporte-email")
                    .padding(.top, Space.sm)
                emailField(String(localized: "Repita o e-mail"), text: $emailAgain, id: "suporte-email-repita")
                    .padding(.top, Space.xs)
                if !email.isEmpty, !emailAgain.isEmpty, !emailsMatch {
                    Text("Os dois e-mails não conferem.").typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.xs)
                } else if !email.isEmpty, !emailValid, !writing {
                    Text("Confira o e-mail: falta o @ ou o domínio.").typeStyle(.note).foregroundStyle(Palette.down).padding(.top, Space.xs)
                }

                if sent {
                    Banner(kind: .neutral, title: String(localized: "Chamado pronto no e-mail"),
                           message: String(localized: "Depois de enviar, a resposta do suporte chega no seu e-mail."))
                        .padding(.top, Space.md)
                }
                if noMailApp {
                    Banner(kind: .neutral, title: String(localized: "Nenhum app de e-mail abriu"),
                           message: String(localized: "Copie o chamado e mande pelo e-mail que você usa. O endereço do suporte vai junto no texto."),
                           actionTitle: String(localized: "Copiar o chamado")) {
                        Pasteboard.copyTicket(String(localized: "Para: \(SupportContact.email)") + "\n" + subject + "\n\n" + ticketBody)
                    }
                    .padding(.top, Space.md)
                }

                VStack(alignment: .leading, spacing: Space.md) {
                    point("hand.raised", String(localized: "Nunca mande as palavras da carteira, o PIN ou a senha de um envelope. Ninguém da Escalibur pede, nem pelo suporte."))
                    point("iphone", String(localized: "A carteira roda só neste iPhone: o suporte não vê, não move nem devolve saldo, e não desfaz transação."))
                    point("doc.text.magnifyingglass", String(localized: "Vai junto só o que você escreveu, o seu e-mail, a versão do app e a do iOS. Endereço da carteira e saldo não vão, e o app não guarda nada disso."))
                }
                .padding(Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
                .padding(.top, Space.lg)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            ActionFooter {
                PrimaryButton(title: String(localized: "Enviar ao suporte"), enabled: canSend) { send() }
                    .accessibilityIdentifier("suporte-enviar")
            }
        }
        .background(Palette.void.ignoresSafeArea())
        .navigationTitle("Suporte")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "OK")) { writing = false }
            }
        }
        .sheet(isPresented: $composing) {
            MailComposer(to: SupportContact.email, subject: subject, body: ticketBody) { result in
                composing = false
                if result == .sent { sent = true }
            }
            .ignoresSafeArea()
        }
    }

    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: Space.xs) {
            Text(verbatim: "\(number)").typeStyle(.label).foregroundStyle(Palette.ink)
                .frame(width: 24, height: 24).background(Circle().fill(Palette.control))
            Text(title).typeStyle(.heading).foregroundStyle(Palette.ink)
        }
    }

    private func emailField(_ prompt: String, text: Binding<String>, id: String) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Palette.inkMuted))
            .typeStyle(.body).foregroundStyle(Palette.ink)
            .keyboardType(.emailAddress).textContentType(.emailAddress)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .focused($writing)
            .padding(.horizontal, Space.md).frame(height: Height.field)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
            .accessibilityIdentifier(id)
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                .frame(width: 32, height: 32).background(Circle().fill(Palette.control))
            Text(text).typeStyle(.note).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
    }

    private var subject: String {
        String(localized: "Suporte: \(topic?.title ?? "") · Escalibur \(SupportContact.version)")
    }

    private var ticketBody: String {
        var lines = [String(localized: "Responder para: \(replyEmail)"), String(localized: "Assunto: \(topic?.title ?? "")")]
        if topic?.asksNetwork == true { lines.append(String(localized: "Rede: \(chain?.name ?? String(localized: "não sei"))")) }
        lines.append("")
        lines.append(details.trimmingCharacters(in: .whitespacesAndNewlines))
        let id = transaction.trimmingCharacters(in: .whitespacesAndNewlines)
        if topic?.asksTransaction == true, !id.isEmpty {
            lines.append("")
            lines.append(String(localized: "ID da transação: \(id)"))
        }
        lines.append("")
        lines.append("Escalibur \(SupportContact.version) · iOS \(UIDevice.current.systemVersion)")
        return lines.joined(separator: "\n")
    }

    private func send() {
        writing = false
        noMailApp = false
        sent = false
        if MFMailComposeViewController.canSendMail() {
            composing = true
        } else if let url = SupportContact.mailURL(subject: subject, body: ticketBody) {
            openURL(url) { accepted in
                if accepted { sent = true } else { noMailApp = true }
            }
        } else {
            noMailApp = true
        }
    }

    /// As palavras da lista BIP-39 (todas as listas latinas, sem acento), para reconhecer
    /// uma senha de carteira colada no texto.
    private static let bip39Words: Set<String> = Set(WordLexicon.entries.compactMap(\.folded))

    /// A maior sequencia de palavras seguidas do texto que estao na lista BIP-39.
    static func longestWordRun(_ text: String) -> Int {
        var longest = 0, run = 0
        for token in text.split(whereSeparator: { !$0.isLetter }) {
            if bip39Words.contains(WordLexicon.fold(String(token))) {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return longest
    }
}

/// O compositor de e-mail do iOS, com o chamado preenchido.
private struct MailComposer: UIViewControllerRepresentable {
    let to: String
    let subject: String
    let body: String
    let onFinish: (MFMailComposeResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([to])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult) -> Void
        init(onFinish: @escaping (MFMailComposeResult) -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish(result)
        }
    }
}
