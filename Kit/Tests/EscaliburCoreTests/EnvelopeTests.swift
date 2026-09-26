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
            password: Self.secure(Self.strong), parameters: Self.fast
        )
        #expect(data.count == 16_504)
        #expect(Envelope.looksLikeEnvelope(data))
        let opened = try Envelope.open(data, password: Self.secure(Self.strong))
        #expect(opened.phrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } == Self.phrase)
        #expect(opened.label == "Principal")
        #expect(opened.passphrase.count == 0)
        #expect(throws: Envelope.Failure.cannotOpen) {
            try Envelope.open(data, password: Self.secure("senha errada"))
        }
    }

    /// Seis palavras da lista: 66 bits, acima do piso de lacre.
    static let strong = "crane violin orbit maple harbor tunnel"

    @Test("Senha abaixo do piso nao lacra")
    func weakPasswordRefused() {
        #expect(throws: Envelope.Failure.weakPassword) {
            try Envelope.seal(phrase: BIP39.canonical(Self.phrase), label: "x", password: Self.secure("senha longa de teste"), parameters: Self.fast)
        }
        #expect(throws: Envelope.Failure.weakPassword) {
            try Envelope.seal(phrase: BIP39.canonical(Self.phrase), label: "x", password: Self.secure("12345678"), parameters: Self.fast)
        }
    }

    @Test("Nenhum envelope nasce abaixo de 256 MiB, mesmo pedindo menos")
    func sealFloor() throws {
        let weak = KDFParameters(memoryKiB: 64 * 1024, passes: 2, lanes: 1)
        let data = try Envelope.seal(
            phrase: BIP39.canonical(Self.phrase), label: "Principal",
            password: Self.secure(Self.strong), parameters: weak
        )
        let header = try Envelope.inspect(data)
        #expect(header.kdf.memoryKiB >= KDFCalibration.sealFloorKiB)
        #expect(KDFCalibration.calibrate().memoryKiB >= KDFCalibration.sealFloorKiB)
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

    @Test("Envelope lacrado por implementacao independente (tools/lacrar-referencia.py)")
    func independentSealer() throws {
        let url = try #require(Bundle.module.url(forResource: "referencia-python", withExtension: "esclbr", subdirectory: "Fixtures"))
        let opened = try Envelope.open(try Data(contentsOf: url), password: Self.secure("senha de referencia em python"))
        #expect(opened.phrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } == "legal winner thank year wave sausage worth useful legal winner thank yellow")
        #expect(opened.passphrase.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } == "TREZOR")
        #expect(opened.label == "Lacrado em Python")
        // A 25a palavra honrada: a seed tem de ser a do vetor oficial com "TREZOR".
        let seed = try BIP39.seed(phrase: opened.phrase, passphrase: "TREZOR")
        #expect(seed.withUnsafeBytes { Array($0) }.hex == "2e8905819b8723fe2c1d161860e5ee1830318dbf49a83bd451cfb8440c28bd6fa457fe1296106559a3c80937a1c1069be3a3a5bd381ee6260e8d9739fce1f607")
    }

    @Test("Arquivo hostil: tamanho e cabecalho recusados antes de derivar")
    func hostileFile() {
        #expect(throws: Envelope.Failure.notAnEnvelope) { try Envelope.inspect(Data(repeating: 0, count: 100)) }
        #expect(throws: Envelope.Failure.notAnEnvelope) { try Envelope.inspect(Data(repeating: 0, count: 16_504)) }
    }

    @Test("Nome vindo de arquivo alheio perde controles bidirecionais")
    func sanitize() {
        #expect(Envelope.sanitize("Carteira\u{202E}lanigiro", limit: 64) == "Carteiralanigiro")
        #expect(Envelope.sanitize(String(repeating: "a", count: 100), limit: 64).count == 64)
    }

    /// Gera a fixture. Roda so com ESCALIBUR_GERAR_FIXTURE=1, e o arquivo gerado e
    /// conferido a parte com `python3 tools/decifrar.py` antes de entrar no repo.
    @Test("Gerar fixture de interoperabilidade", .enabled(if: ProcessInfo.processInfo.environment["ESCALIBUR_GERAR_FIXTURE"] == "1"))
    func generateFixture() throws {
        // A fixture guarda a senha de antes do piso de 60 bits; o lacre vai direto ao
        // arquivo para continuar reproduzivel com a mesma senha.
        let phrase = try BIP39.canonical(Self.phrase)
        guard case .valid(let language) = BIP39.validate(phrase) else { Issue.record("frase"); return }
        let sealing = SealingContents(mnemonic: phrase, passphrase: "", label: "Interoperabilidade", notes: "", language: language, kind: .bip39)
        let data = try VaultFile.create(sealing: sealing, password: Self.secure("cavalo correto bateria grampo"), parameters: Self.fast)
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ESCALIBUR_FIXTURE_SAIDA"] ?? "/tmp/interop.esclbr")
        try data.write(to: out)
    }
}
