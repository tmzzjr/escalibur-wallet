import Foundation
import Testing
@testable import EscaliburCore

/// O envelope precisa abrir nos dois sentidos: o que a carteira lacra abre no
/// Escalibur e no decifrador de referencia, e o que eles lacram abre aqui.
@Suite("Envelope Escalibur")
struct EnvelopeTests {
    /// Parametros minimos aceitos pelo formato, para o teste nao levar segundos.
    static let fast = KDFParameters(memoryKiB: 64 * 1024, passes: 2, lanes: 1)
    static let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    static func secure(_ text: String) -> SecureBytes {
        let bytes = SecureBytes(capacity: max(text.utf8.count, 1))
        bytes.replaceAll(with: Array(text.utf8))
        return bytes
    }

    @Test("Ida e volta, senha errada sem mensagem distinta, tamanho constante")
    func roundTrip() throws {
        let data = try Envelope.seal(
            phrase: BIP39.canonical(Self.phrase), label: "Principal",
            password: Self.secure("senha longa de teste"), parameters: Self.fast
        )
        #expect(data.count == 16_504)
        #expect(Envelope.looksLikeEnvelope(data))
        let opened = try Envelope.open(data, password: Self.secure("senha longa de teste"))
        #expect(opened.phrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } == Self.phrase)
        #expect(opened.label == "Principal")
        #expect(throws: CryptoError.cannotOpen) {
            try Envelope.open(data, password: Self.secure("senha errada"))
        }
    }

    @Test("Envelope de referencia, conferido pelo decifrar.py do Escalibur")
    func referenceFixture() throws {
        guard let url = Bundle.module.url(forResource: "interop", withExtension: "esclbr", subdirectory: "Fixtures") else {
            Issue.record("fixture ausente")
            return
        }
        let data = try Data(contentsOf: url)
        let opened = try Envelope.open(data, password: Self.secure("cavalo correto bateria grampo"))
        #expect(opened.phrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } == Self.phrase)
        #expect(opened.label == "Interoperabilidade")
    }

    /// Gera a fixture. Roda so com ESCALIBUR_GERAR_FIXTURE=1, e o arquivo gerado e
    /// conferido a parte com `python3 tools/decifrar.py` antes de entrar no repo.
    @Test("Gerar fixture de interoperabilidade", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_GERAR_FIXTURE"] == "1"))
    func generateFixture() throws {
        let data = try Envelope.seal(
            phrase: BIP39.canonical(Self.phrase), label: "Interoperabilidade",
            password: Self.secure("cavalo correto bateria grampo"), parameters: Self.fast
        )
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ESCALIBUR_FIXTURE_SAIDA"] ?? "/tmp/interop.esclbr")
        try data.write(to: out)
    }
}
