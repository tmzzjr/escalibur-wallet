import SwiftUI

/// O quadro de escuta, igual no cadastro da frase e na conferencia: a onda que
/// reage ao microfone, o estado em palavras e a transcricao ao vivo.
struct VoiceListeningPanel: View {
    enum Outcome { case passed }

    @ObservedObject var listener: SpeechListener
    /// O que dizer antes de comecar a ouvir.
    let idle: String
    var outcome: Outcome? = nil

    var body: some View {
        VStack(spacing: Space.sm) {
            VoiceWave(levels: listener.levels, level: listener.level, active: listener.listening)
                .frame(height: 64)
                .accessibilityHidden(true)
            status
            VStack(spacing: Space.xxs) {
                if !listener.transcript.isEmpty {
                    Text(listener.transcript)
                        .typeStyle(.heading).foregroundStyle(Palette.ink)
                        .accessibilityIdentifier("voz-transcricao")
                } else if listener.listening {
                    Text("Pode falar").typeStyle(.heading).foregroundStyle(Palette.inkDead)
                }
                if let other = listener.alternate {
                    Text("Em \(other.language.name): \(other.text)").typeStyle(.note).foregroundStyle(Palette.inkMuted)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body)
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Palette.edge, lineWidth: 1))
        )
        .accessibilityElement(children: .contain)
    }

    private var status: some View {
        HStack(spacing: Space.xs) {
            if outcome == .passed {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Frase conferida").foregroundStyle(Palette.ink)
            } else if listener.listening {
                Circle().fill(Palette.lime).frame(width: 8, height: 8)
                Text("Ouvindo").foregroundStyle(Palette.ink)
            } else if listener.busy {
                Text("Conferindo o que ouvi").foregroundStyle(Palette.inkSoft)
            } else if !listener.transcript.isEmpty {
                Text("Ouvi").foregroundStyle(Palette.inkSoft)
            } else {
                Text(idle).foregroundStyle(Palette.inkSoft)
            }
        }
        .typeStyle(.note)
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("voz-estado")
    }
}

/// A onda: barras brancas que crescem com o nivel do microfone. O som mais novo
/// nasce no meio e anda para as pontas. Com Reduzir Movimento, vira uma barra de
/// nivel parada, que so muda de comprimento.
struct VoiceWave: View {
    let levels: [Float]
    let level: Float
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bars = 2 * SpeechListener.historyCount - 1

    var body: some View {
        if reduceMotion { meter } else { wave }
    }

    private var wave: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<Self.bars, id: \.self) { index in
                Capsule()
                    .fill(active ? Palette.ink : Palette.edgeStrong)
                    .frame(width: 4, height: height(index))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(active ? .linear(duration: 0.1) : .easeOut(duration: 0.3), value: levels)
    }

    /// Distancia do meio escolhe a idade do nivel; as pontas afinam um pouco.
    private func height(_ index: Int) -> CGFloat {
        let center = Self.bars / 2
        let distance = abs(index - center)
        let value = levels.indices.contains(levels.count - 1 - distance) ? CGFloat(levels[levels.count - 1 - distance]) : 0
        let taper = 1 - 0.5 * CGFloat(distance) / CGFloat(center + 1)
        return 4 + value * 56 * taper
    }

    private var meter: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.rail)
                Capsule()
                    .fill(active ? Palette.ink : Palette.edgeStrong)
                    .frame(width: max(8, proxy.size.width * CGFloat(active ? level : 0)))
            }
            .frame(height: 8)
            .frame(maxHeight: .infinity)
        }
    }
}
