import SwiftUI

/// "Como funciona" do envelope (pedido do dono, 14/10/2026): em quatro telas, a senha da
/// carteira virando um arquivo cifrado que so abre com a senha que a pessoa escolhe.
/// Nenhuma palavra de verdade aparece: as palavras sao pontos, e o cifrado e sorteado.
struct EnvelopeHowItWorks: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    struct Page {
        let title: String
        let text: String
    }

    static let pages = [
        Page(title: String(localized: "A senha da carteira entra no envelope"),
             text: String(localized: "O envelope pega as palavras da sua carteira e tranca tudo com uma senha que você escolhe. O resultado é um arquivo .esclbr.")),
        Page(title: String(localized: "Sem a senha, o arquivo é ruído"),
             text: String(localized: "Dentro do arquivo, as palavras viram dados cifrados. Ele não diz de quem é, nem quantas palavras guarda, nem o que tem dentro.")),
        Page(title: String(localized: "Só a sua senha abre"),
             text: String(localized: "Ninguém abre sem ela, nem a Escalibur, e ninguém recupera uma senha esquecida. Quem tiver uma cópia do arquivo pode tentar senhas à vontade, por isso a sugerida tem seis palavras sorteadas.")),
        Page(title: String(localized: "Para abrir, só o app"),
             text: String(localized: "Em Ajustes, Abrir um envelope, neste ou em outro iPhone com a Escalibur. Com a senha certa, a carteira volta. Guarde o arquivo e a senha em lugares diferentes.")),
    ]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: String(localized: "Como funciona")) { dismiss() }
            TabView(selection: $page) {
                ForEach(Self.pages.indices, id: \.self) { index in
                    VStack(spacing: 0) {
                        // So a tela visivel anima: as vizinhas que o TabView prepara ficam paradas.
                        Group {
                            if page == index { illustration(index) } else { Color.clear }
                        }
                        .frame(height: 236)
                        .padding(.top, Space.lg)
                        Text(Self.pages[index].title).typeStyle(.title).foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Space.xl)
                        Text(Self.pages[index].text).typeStyle(.body).foregroundStyle(Palette.inkSoft)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Space.sm)
                        Spacer(minLength: Space.xl)
                    }
                    .padding(.horizontal, Space.gutter)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            PrimaryButton(title: page < Self.pages.count - 1 ? String(localized: "Próximo") : String(localized: "Entendi")) {
                if page < Self.pages.count - 1 { withAnimation(Motion.fade) { page += 1 } } else { dismiss() }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xs)
            .padding(.top, Space.sm)
        }
        .background(Palette.void.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationBackground(Palette.void)
        .presentationCornerRadius(Radius.sheet)
        #if DEBUG
        .onAppear { if DebugDemo.screen == "envelope-como" { page = Int(DebugDemo.arguments.last ?? "") ?? 0 } }
        #endif
    }

    @ViewBuilder
    private func illustration(_ index: Int) -> some View {
        switch index {
        case 0: EnvelopeChain(mode: .working, direction: .inward)
        case 1: CipherNoise()
        case 2: EnvelopeChain(mode: .sealed)
        default: EnvelopeChain(mode: .opened, direction: .outward)
        }
    }
}

/// As palavras da carteira (pontos, nunca palavras de verdade) virando dados cifrados e
/// voltando: o que o arquivo guarda sem a senha. Com Reduzir Movimento, o quadro cifrado
/// parado.
private struct CipherNoise: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let period = 3.2
    static let columns = [GridItem(.flexible(), spacing: Space.xs), GridItem(.flexible(), spacing: Space.xs), GridItem(.flexible(), spacing: Space.xs)]
    static let hex = Array("0123456789abcdef")

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.09)) { context in
            let time = reduceMotion ? Self.period / 2 : context.date.timeIntervalSinceReferenceDate
            let phase = time.truncatingRemainder(dividingBy: Self.period) / Self.period
            // Do 0 aos 35%: palavras. Dos 35% aos 50%: cada uma cifra, uma depois da outra.
            // Ate os 90%: cifrado. Depois volta.
            LazyVGrid(columns: Self.columns, spacing: Space.xs) {
                ForEach(0..<12, id: \.self) { index in
                    let start = 0.35 + Double(index) * 0.0125
                    let ciphered = phase >= start && phase < 0.9 || reduceMotion
                    chip(index: index, ciphered: ciphered, tick: Int(time / 0.09))
                }
            }
            .padding(.horizontal, Space.sm)
        }
        .accessibilityHidden(true)
    }

    private func chip(index: Int, ciphered: Bool, tick: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1)").typeStyle(.note).foregroundStyle(Palette.inkMuted).frame(width: 18, alignment: .trailing)
            Text(ciphered ? Self.noise(seed: index &* 7_919 &+ tick) : "••••••")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(ciphered ? Palette.inkSoft : Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xs)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(ciphered ? Palette.void : Palette.body)
            .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).stroke(ciphered ? Palette.edgeStrong : Palette.edge, lineWidth: 1)))
        .animation(Motion.fade, value: ciphered)
    }

    /// Seis caracteres hex que mudam a cada quadro: so desenho, nada sai de chave.
    static func noise(seed: Int) -> String {
        var state = UInt64(bitPattern: Int64(seed)) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return String((0..<6).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return hex[Int((state >> 33) % 16)]
        })
    }
}
