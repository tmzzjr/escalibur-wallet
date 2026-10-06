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
        #expect(!VoiceGate.sendNeedsVoice(fiat: 999, settings: settings()))
        #expect(VoiceGate.sendNeedsVoice(fiat: 1_000, settings: settings()))
        #expect(VoiceGate.sendNeedsVoice(fiat: 25_000, settings: settings(limit: 20_000)))
    }

    @Test func unknownValueAsks() {
        #expect(VoiceGate.sendNeedsVoice(fiat: nil, settings: settings()))
    }

    @Test func sendsOffNeverAsk() {
        #expect(!VoiceGate.sendNeedsVoice(fiat: 1_000_000, settings: settings(limit: nil)))
        #expect(!VoiceGate.sendNeedsVoice(fiat: nil, settings: settings(limit: nil, max: 1, done: 5)))
    }

    @Test func streakOfSmallSendsAsksAtTheLimit() {
        #expect(!VoiceGate.sendNeedsVoice(fiat: 10, settings: settings(max: 3, done: 2)))
        #expect(VoiceGate.sendNeedsVoice(fiat: 10, settings: settings(max: 3, done: 3)))
        #expect(!VoiceGate.sendNeedsVoice(fiat: 10, settings: settings(max: 3, done: nil)))
    }

    @Test func oldMetadataStillOpens() throws {
        // Ajustes de voz gravados antes da lingua e da sequencia existirem.
        let old = Data(#"{"enabled":true,"onReveal":true,"onEnvelope":false,"onSendAboveFiat":5000}"#.utf8)
        let voice = try JSONDecoder().decode(VoiceSettings.self, from: old)
        #expect(voice.phraseLanguage == .portuguese)
        #expect(voice.maxSendsWithoutVoice == nil && voice.sendsWithoutVoice == nil)
    }
}
