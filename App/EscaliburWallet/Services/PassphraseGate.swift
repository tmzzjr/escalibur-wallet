import EscaliburCore
import EscaliburKeys
import SwiftUI

/// Carteira com passphrase e "Pedir a passphrase para enviar" (ligado de fabrica, pedido do
/// dono, 16/10/2026): antes do Face ID ou do PIN de um envio, troca ou ponte, o dono digita a
/// passphrase. Quem viu o PIN, ou tem o rosto do dono a mao, nao move o saldo da carteira
/// com passphrase sem saber a passphrase.
///
/// A conferencia nao acontece aqui: a passphrase digitada vai para `Signer.sign`, que a
/// compara com a do cofre (NFKD, tempo constante) antes de nascer qualquer chave. Errada,
/// nada e assinado. Esta folha so coleta o que foi digitado, num buffer que o chamador zera.
@MainActor
final class PassphraseGate {
    static let shared = PassphraseGate()

    struct Request: Identifiable {
        let id = UUID()
        let walletID: UUID
        let walletName: String
        /// A frase de cima da folha: mover saldo, ou deixar de pedir a passphrase.
        let reason: String
        /// Mover saldo oferece a folga de alguns minutos; ver as palavras, lacrar o envelope e
        /// deixar de pedir, nao.
        let offersGrace: Bool
        let continuation: CheckedContinuation<SecureBytes?, Never>
    }

    private var current: Request?

    /// A carteira pede a passphrase para mover saldo? E o ajuste, sem a folga.
    static func asks(_ wallet: WalletMeta?) -> Bool {
        guard let wallet, wallet.hasPassphrase, !wallet.isWatchOnly else { return false }
        return wallet.passphraseToSend ?? true
    }

    /// Para mover saldo agora: pede, a menos que a folga escolhida depois de acertar ainda valha.
    static func needed(_ wallet: WalletMeta?) -> Bool {
        guard let wallet, asks(wallet) else { return false }
        return !shared.inGrace(wallet.id)
    }

    /// A passphrase digitada, ou nil se o dono fechou a folha. O buffer e do chamador: ele
    /// zera depois de assinar.
    func ask(_ wallet: WalletMeta, reason: String? = nil) async -> SecureBytes? {
        let line = reason ?? String(localized: "\(wallet.name) pede a passphrase para mover saldo. Depois dela vem o \(KeyServices.biometryName) ou o PIN, como sempre.")
        // Um pedido em cima de outro: o de antes recebe "fechou", e nao fica pendurado.
        if let pending = current { finish(pending, with: nil) }
        pendingGrace = nil
        return await withCheckedContinuation { continuation in
            let request = Request(walletID: wallet.id, walletName: wallet.name, reason: line, offersGrace: reason == nil, continuation: continuation)
            current = request
            OverlayWindow.shared.show(PassphrasePromptSheet(request: request))
        }
    }

    /// `grace`: os minutos escolhidos na folha, que so passam a valer quando o assinador
    /// conferir a passphrase (`confirmGrace`).
    func finish(_ request: Request, with passphrase: SecureBytes?, grace minutes: Int? = nil) {
        // Uma resposta por pedido: fechar e confirmar quase juntos nao retoma duas vezes.
        guard current?.id == request.id else { passphrase?.wipe(); return }
        current = nil
        if let minutes, passphrase != nil, request.offersGrace, Self.graceChoices.contains(minutes) {
            pendingGrace = (request.walletID, minutes)
        }
        OverlayWindow.shared.hide()
        request.continuation.resume(returning: passphrase)
    }

    // MARK: Folga depois de acertar

    /// "Nao pedir nos proximos minutos" (pedido do dono, 17/10/2026): 5, 10, 15 ou 20
    /// minutos, 5 ao ligar. Vale so para mover saldo, so na carteira em que a passphrase
    /// conferiu, e so na memoria, no relogio monotono: fechar o app ou travar zera, e o PIN
    /// ou o rosto continuam sendo pedidos a cada envio.
    static let graceChoices = [5, 10, 15, 20]
    private var pendingGrace: (wallet: UUID, minutes: Int)?
    private var graceUntil: [UUID: TimeInterval] = [:]

    func inGrace(_ walletID: UUID) -> Bool {
        (graceUntil[walletID] ?? 0) > PINPolicy.uptime
    }

    /// O assinador conferiu a passphrase desta carteira: a folga pedida na folha comeca agora.
    func confirmGrace(_ walletID: UUID) {
        defer { pendingGrace = nil }
        guard let pending = pendingGrace, pending.wallet == walletID else { return }
        graceUntil[walletID] = PINPolicy.uptime + TimeInterval(pending.minutes * 60)
    }

    /// Travar o app encerra toda folga: quem destrava com o PIN depois nao pula a passphrase.
    func clearGrace() {
        graceUntil = [:]
        pendingGrace = nil
    }

    // MARK: Espera depois de erros

    /// Erros livres antes da primeira espera; a espera comeca em 1 minuto e dobra a cada
    /// erro, ate 24 horas. Acertar zera.
    static let freeFailures = 5
    static let firstWait: TimeInterval = 60
    static let longestWait: TimeInterval = 24 * 3600

    /// Antes de conferir uma passphrase: conta a tentativa (gravada antes da conferencia) e
    /// devolve nil para seguir, ou o texto da espera. Sem gravar, nao confere.
    func begin(_ session: AppSession) -> String? {
        let left = lockRemaining(session)
        if left > 0 {
            let until = Date.now.addingTimeInterval(left)
            return String(localized: "Muitas passphrases erradas. Tente de novo às \(until.formatted(date: .omitted, time: .shortened)).")
        }
        var guardState = session.metadata.settings.passphraseGuard ?? PassphraseGuard()
        guardState.failures += 1
        session.metadata.settings.passphraseGuard = guardState
        do { try session.persist() } catch { return String(localized: "Não foi possível conferir a passphrase agora.") }
        return nil
    }

    /// O dono cancelou o PIN ou o rosto antes de o cofre abrir: nada foi conferido, e a
    /// tentativa contada em `begin` volta.
    func refund(_ session: AppSession) {
        pendingGrace = nil
        guard var guardState = session.metadata.settings.passphraseGuard, guardState.failures > 0 else { return }
        guardState.failures -= 1
        session.metadata.settings.passphraseGuard = guardState
        try? session.persist()
    }

    /// Acertou: a conta zera.
    func passed(_ session: AppSession) {
        guard session.metadata.settings.passphraseGuard != nil else { return }
        session.metadata.settings.passphraseGuard = nil
        try? session.persist()
    }

    /// Errou (a tentativa ja foi contada em `begin`): passado o limite, comeca a espera.
    func failed(_ session: AppSession) {
        pendingGrace = nil
        var guardState = session.metadata.settings.passphraseGuard ?? PassphraseGuard(failures: 1)
        guard guardState.failures >= Self.freeFailures else { return }
        let extra = Double(guardState.failures - Self.freeFailures)
        guardState.startLock(seconds: min(Self.firstWait * pow(2, extra), Self.longestWait))
        session.metadata.settings.passphraseGuard = guardState
        try? session.persist()
    }

    /// Quanto falta da espera, no relogio monotono. De outro boot, ela recomeca cheia (falha
    /// para o lado de esperar mais), como a da voz.
    private func lockRemaining(_ session: AppSession) -> TimeInterval {
        guard var guardState = session.metadata.settings.passphraseGuard, guardState.lockUptimeDeadline != nil else { return 0 }
        let full = min(Self.firstWait * pow(2, Double(max(guardState.failures - Self.freeFailures, 0))), Self.longestWait)
        let boot = PINPolicy.bootSession
        if boot == PINPolicy.unknownBoot {
            return max(0, (guardState.lockedUntil ?? .distantPast).timeIntervalSinceNow)
        }
        if !PINPolicy.isSameBoot(guardState.lockBoot.flatMap(Hex.decode) ?? [], boot) {
            guardState.startLock(seconds: full)
            session.metadata.settings.passphraseGuard = guardState
            try? session.persist()
            return full
        }
        let left = min(full, (guardState.lockUptimeDeadline ?? 0) - PINPolicy.uptime)
        if left <= 0 {
            guardState.clearLock()
            session.metadata.settings.passphraseGuard = guardState
            try? session.persist()
            return 0
        }
        return left
    }

    /// A passphrase digitada confere com a do cofre? As duas em NFKD, em tempo constante:
    /// a mesma regra do assinador (`Signer.sign`) e da conferencia da copia.
    nonisolated static func matches(_ stored: SecureBytes, _ typed: SecureBytes) -> Bool {
        let a = BIP39.nfkd(stored), b = BIP39.nfkd(typed)
        defer { a.wipe(); b.wipe() }
        return a.count > 0 && Hash.constantTimeEqual(a, b)
    }

    /// O texto da passphrase errada, depois do Face ID ou do PIN.
    static let mismatchMessage = String(localized: "A passphrase não confere. Nada foi assinado. Escreva igual ao que você anotou: maiúscula, acento e espaço contam.")
}

/// A folha da passphrase antes de assinar.
struct PassphrasePromptSheet: View {
    let request: PassphraseGate.Request
    @State private var buffer = SecureBytes(capacity: 256)
    @State private var length = 0
    @State private var reveal = false
    @State private var cipher = LiveCipher()
    @State private var answered = false
    /// A folga: desligada a cada folha; ligar comeca em 5 minutos.
    @State private var graceOn = false
    @State private var graceMinutes = PassphraseGate.graceChoices[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(localized: "Digite a passphrase")) { close() }
            Text(request.reason)
                .typeStyle(.body).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.gutter).padding(.top, Space.sm)
            PasswordBox(buffer: buffer, length: $length, placeholder: String(localized: "Passphrase"), focusOnAppear: true, reveal: $reveal,
                        onSubmit: { confirm() }, glyphs: glyphs)
                .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
                .accessibilityIdentifier("passphrase-envio")
            Text("Segure o dedo no campo para conferir o que digitou.")
                .typeStyle(.note).foregroundStyle(Palette.inkMuted)
                .padding(.horizontal, Space.gutter).padding(.top, Space.xs)
            if request.offersGrace {
                grace
                    .padding(.horizontal, Space.gutter).padding(.top, Space.lg)
            }
            Spacer(minLength: Space.md)
            PrimaryButton(title: String(localized: "Continuar"), enabled: length > 0) { confirm() }
                .padding(.horizontal, Space.gutter).padding(.bottom, Space.xs)
                .accessibilityIdentifier("passphrase-envio-continuar")
        }
        .padding(.top, Space.sm)
        .background(Palette.void.ignoresSafeArea())
        .guardedAgainstCapture()
        .onChange(of: length) { _, _ in cipher.seal(0, buffer: buffer) }
        .onDisappear {
            cipher.clearAll()
            if !answered { buffer.wipe() }
        }
    }

    private var glyphs: ((UInt64) -> String)? {
        guard length > 0 else { return nil }
        let cipher = self.cipher, count = length
        return { tick in cipher.glyphs(0, count: count, tick: tick) }
    }

    /// "Nao pedir de novo por alguns minutos", com a escolha dos minutos ao ligar.
    private var grace: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Toggle(isOn: $graceOn.animation(Motion.fade)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Não pedir de novo por um tempo").typeStyle(.body).foregroundStyle(Palette.ink)
                    Text(graceOn
                         ? String(localized: "Nos próximos \(graceMinutes) minutos, \(request.walletName) não pede a passphrase para mover saldo. O \(KeyServices.biometryName) ou o PIN continuam. Travar o app encerra.")
                         : String(localized: "Depois de a passphrase conferir, os próximos envios, trocas e ordens pulam esta etapa por alguns minutos."))
                        .typeStyle(.note).foregroundStyle(Palette.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Palette.success)
            .accessibilityIdentifier("passphrase-folga")
            if graceOn {
                Segmented(options: PassphraseGate.graceChoices.map { ($0, String(localized: "\($0) min")) }, selection: $graceMinutes)
                    .accessibilityIdentifier("passphrase-folga-minutos")
                    .transition(.opacity)
            }
        }
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.body))
    }

    private func confirm() {
        guard length > 0, !answered else { return }
        answered = true
        // O chamador fica com uma copia; o campo zera o dele.
        let copy = SecureBytes(capacity: buffer.count)
        buffer.withUnsafeBytes { copy.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
        buffer.wipe()
        PassphraseGate.shared.finish(request, with: copy, grace: graceOn ? graceMinutes : nil)
    }

    private func close() {
        answered = true
        buffer.wipe()
        PassphraseGate.shared.finish(request, with: nil)
    }
}
