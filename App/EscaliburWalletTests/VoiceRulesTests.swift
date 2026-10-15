import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburWallet

/// Quando um envio pede a frase de voz: o valor escolhido e a sequencia de envios sem ela.
@MainActor
struct VoiceRulesTests {
    func settings(limit: Double? = 1_000, max: Int? = nil, done: Int? = nil) -> VoiceSettings {
        var voice = VoiceSettings()
        voice.enabled = true
        voice.onSendAboveFiat = limit
        voice.maxSendsWithoutVoice = max
        voice.sendsWithoutVoice = done
        return voice
    }

    @Test func valueChosenByOwner() {
        #expect(!VoiceGate.sendNeedsVoice(fiat: 999, settings: settings(), currency: "brl"))
        #expect(VoiceGate.sendNeedsVoice(fiat: 1_000, settings: settings(), currency: "brl"))
        #expect(VoiceGate.sendNeedsVoice(fiat: 25_000, settings: settings(limit: 20_000), currency: "brl"))
    }

    @Test func unknownValueAsks() {
        #expect(VoiceGate.sendNeedsVoice(fiat: nil, settings: settings(), currency: "brl"))
    }

    @Test func sendsOffNeverAsk() {
        #expect(!VoiceGate.sendNeedsVoice(fiat: 1_000_000, settings: settings(limit: nil), currency: "brl"))
        #expect(!VoiceGate.sendNeedsVoice(fiat: nil, settings: settings(limit: nil, max: 1, done: 5), currency: "brl"))
    }

    @Test func streakOfSmallSendsAsksAtTheLimit() {
        #expect(!VoiceGate.sendNeedsVoice(fiat: 10, settings: settings(max: 3, done: 2), currency: "brl"))
        #expect(VoiceGate.sendNeedsVoice(fiat: 10, settings: settings(max: 3, done: 3), currency: "brl"))
        #expect(!VoiceGate.sendNeedsVoice(fiat: 10, settings: settings(max: 3, done: nil), currency: "brl"))
    }

    @Test func limitAddsUpOverTheDay() {
        var voice = settings(limit: 5_000)
        voice.recentSends = [
            VoiceSend(at: .now.addingTimeInterval(-3_600), uptime: PINPolicy.uptime - 3_600, boot: Hex.encode(PINPolicy.bootSession), fiat: 4_000),
        ]
        #expect(!VoiceGate.sendNeedsVoice(fiat: 900, settings: voice, currency: "brl"))
        #expect(VoiceGate.sendNeedsVoice(fiat: 1_000, settings: voice, currency: "brl"))
        // Mais de 24 h no relogio monotono: nao conta mais.
        voice.recentSends = [
            VoiceSend(at: .now.addingTimeInterval(-90_000), uptime: PINPolicy.uptime - 90_000, boot: Hex.encode(PINPolicy.bootSession), fiat: 4_000),
        ]
        #expect(!VoiceGate.sendNeedsVoice(fiat: 1_000, settings: voice, currency: "brl"))
    }

    @Test func limitIsInTheCurrencyItWasSet() {
        var voice = settings(limit: 5_000)
        voice.limitCurrency = "brl"
        #expect(!VoiceGate.sendNeedsVoice(fiat: 100, settings: voice, currency: "brl"))
        // A moeda do app mudou para dolar: o limite de 5.000 nao vale 5.000 dolares.
        #expect(VoiceGate.sendNeedsVoice(fiat: 100, settings: voice, currency: "usd"))
    }

    /// Desenho de voz de 14/10/2026, Q1: as frases erradas somam entre folhas (a conta
    /// mora nos metadados, gravada antes de cada conferencia), e so a certa ou a pausa zeram.
    @Test func wrongPhrasesAddUpAcrossSheets() {
        var voice = settings()
        #expect(voice.attemptsLeft(limit: VoiceGate.attemptsBeforeLock) == 9)
        for _ in 0..<4 { voice.countAttempt() }
        // Fechar a folha e abrir outra nao mexe na conta: ela nao mora na folha.
        #expect(voice.attemptsLeft(limit: VoiceGate.attemptsBeforeLock) == 5)
        for _ in 0..<5 { voice.countAttempt() }
        #expect(voice.attemptsLeft(limit: VoiceGate.attemptsBeforeLock) == 0)
        voice.clearLock()
        #expect(voice.failedAttempts == nil && voice.attemptsLeft(limit: VoiceGate.attemptsBeforeLock) == 9)
    }

    @Test func oldMetadataStillOpens() throws {
        // Ajustes de voz gravados antes da lingua e da sequencia existirem.
        let old = Data(#"{"enabled":true,"onReveal":true,"onEnvelope":false,"onSendAboveFiat":5000}"#.utf8)
        let voice = try JSONDecoder().decode(VoiceSettings.self, from: old)
        #expect(voice.phraseLanguage == .portuguese)
        #expect(voice.maxSendsWithoutVoice == nil && voice.sendsWithoutVoice == nil)
    }
}
