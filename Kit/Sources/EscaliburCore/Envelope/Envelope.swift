import Foundation

/// A porta de entrada da carteira para o envelope Escalibur (`.esclbr`).
///
/// O formato e o do app Escalibur, sem extensao nenhuma: um envelope lacrado aqui
/// abre no cofre e no decifrador de referencia em Python, e um envelope do cofre
/// abre aqui. Os testes de interoperabilidade conferem os dois sentidos.
///
/// Diferenca deliberada em relacao ao Escalibur: a abertura decodifica o bloco
/// direto para `SecureBytes` (frase e 25a palavra), sem passar por `String`. No
/// cofre a frase e exibida; na carteira ela e importada, e importar nao pode deixar
/// a frase no heap pela vida inteira do processo.
public enum Envelope {
    public static let fileLength = VaultFormat.fileLength

    public enum Failure: Error, Equatable, Sendable {
        /// Tamanho, assinatura ou cabecalho fora do formato. Nada foi derivado.
        case notAnEnvelope
        /// O cabecalho pede mais memoria do que este aparelho tem agora.
        case tooExpensiveForThisDevice(memoryMiB: Int)
        /// Envelope vinculado a outro aparelho (formato previsto, nao implementado).
        case boundToDevice
        /// Senha errada ou arquivo adulterado. Uma mensagem so, de proposito.
        case cannotOpen
        /// Abriu, mas guarda uma parte SLIP-39, que sozinha nao e uma carteira.
        case slip39Share
        /// Abriu, mas o idioma gravado nao e nenhum dos dez conhecidos.
        case unknownLanguage
        /// Abriu, mas a frase dentro nao fecha o checksum BIP-39.
        case invalidPhrase
    }

    /// O que um envelope aberto entrega a carteira.
    public struct Contents: Sendable {
        /// A frase, na forma canonica, em buffer seguro.
        public let phrase: SecureBytes
        /// A 25a palavra, em buffer seguro. Vazia quase sempre, e **nunca ignorada**:
        /// sem ela, a carteira importada seria outra, valida e vazia.
        public let passphrase: SecureBytes
        /// Nome e anotacoes sao texto nao confiavel, ja higienizados.
        public let label: String
        public let notes: String
        public let language: BIP39Language

        public func wipe() {
            phrase.wipe()
            passphrase.wipe()
        }
    }

    /// Informacao publica do cabecalho, para a interface decidir antes de derivar.
    public struct Inspection: Sendable {
        public let kdf: KDFParameters
        /// Segundos estimados para abrir, pela taxa medida neste aparelho.
        public let estimatedSeconds: Double
    }

    // MARK: Lacrar

    /// Lacra uma frase num envelope novo, com Argon2id calibrado para este aparelho e
    /// nunca abaixo do piso de lacre. Reabre o resultado antes de devolver.
    public static func seal(
        phrase: SecureBytes,
        passphrase: String = "",
        label: String,
        notes: String = "",
        password: SecureBytes,
        parameters: KDFParameters? = nil
    ) throws -> Data {
        let chosen = parameters ?? KDFCalibration.calibrate()
        let language: BIP39Language
        if case .valid(let detected) = BIP39.validate(phrase) { language = detected } else { throw Failure.invalidPhrase }
        let sealing = SealingContents(
            mnemonic: phrase, passphrase: passphrase, label: label, notes: notes,
            language: language, kind: .bip39
        )
        let data = try VaultFile.create(sealing: sealing, password: password, parameters: chosen)

        // Condicao posterior: um envelope que nao abre com a senha que o dono acabou
        // de digitar, ou que abre com outra frase, nao sai daqui.
        let check = try open(data, password: password)
        defer { check.wipe() }
        let same = phrase.withUnsafeBytes { a in check.phrase.withUnsafeBytes { b in Hash.constantTimeEqual(Array(a), Array(b)) } }
        guard same else { throw CryptoError.malformedVault("o envelope gravado não confere com a frase") }
        return data
    }

    // MARK: Abrir

    /// Confere forma e custo antes de qualquer derivacao. O arquivo veio de fora
    /// (AirDrop, Arquivos) e e tratado como hostil: um cabecalho com m = 1 GiB
    /// derrubaria o app pelo jetsam no meio do Argon2.
    public static func inspect(_ data: Data) throws -> Inspection {
        guard looksLikeEnvelope(data) else { throw Failure.notAnEnvelope }
        let header: VaultFormat.Header_
        do { header = try VaultFormat.Header_.decode([UInt8](data)) } catch { throw Failure.notAnEnvelope }
        guard header.binding == .passwordOnly else { throw Failure.boundToDevice }
        let available = KDFCalibration.availableMemoryBytes()
        let needed = UInt64(header.kdf.memoryKiB) * 1024
        guard needed + 300 * 1024 * 1024 <= available else {
            throw Failure.tooExpensiveForThisDevice(memoryMiB: Int(header.kdf.memoryKiB / 1024))
        }
        let seconds = KDFCalibration.estimatedSeconds(for: header.kdf)
        return Inspection(kdf: header.kdf, estimatedSeconds: seconds)
    }

    /// Abre um envelope. Chamar fora do MainActor: o Argon2 leva segundos.
    public static func open(_ data: Data, password: SecureBytes) throws -> Contents {
        _ = try inspect(data)
        let raw: (block: SecureBytes, slotIndex: Int, header: VaultFormat.Header_)
        do {
            raw = try VaultFile.openBlock(data, password: password)
        } catch CryptoError.cannotOpen {
            throw Failure.cannotOpen
        }
        defer { raw.block.wipe() }
        return try decode(raw.block)
    }

    /// Um arquivo parece um envelope? Tamanho e assinatura, sem senha.
    public static func looksLikeEnvelope(_ data: Data) -> Bool {
        data.count == VaultFormat.fileLength && data.prefix(6) == Data(VaultFormat.magic)
    }

    // MARK: Conteudo

    /// Decodifica o bloco de 3936 bytes direto para buffers seguros.
    ///
    /// Os erros daqui so existem depois que as duas tags AEAD fecharam, entao nao
    /// servem de oraculo de senha.
    static func decode(_ block: SecureBytes) throws -> Contents {
        try block.withUnsafeBytes { raw -> Contents in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count == VaultFormat.plaintextLength, bytes[0] == 0x01 else { throw Failure.cannotOpen }
            guard let kind = VaultContents.Kind(rawValue: bytes[1]) else { throw Failure.cannotOpen }
            guard kind == .bip39 else { throw Failure.slip39Share }
            let languageIndex = Int(bytes[2])
            guard BIP39Language.allCases.indices.contains(languageIndex) else { throw Failure.unknownLanguage }
            let language = BIP39Language.allCases[languageIndex]

            var lengths: [Int] = []
            for field in 0..<4 {
                let at = 4 + field * 2
                lengths.append(Int(bytes[at]) << 8 | Int(bytes[at + 1]))
            }
            var cursor = 12
            func take(_ length: Int) throws -> UnsafeBufferPointer<UInt8> {
                guard cursor + length <= bytes.count else { throw Failure.cannotOpen }
                defer { cursor += length }
                return UnsafeBufferPointer(rebasing: bytes[cursor..<(cursor + length)])
            }

            let phraseSlice = try take(lengths[0])
            let phrase = SecureBytes(capacity: max(phraseSlice.count, 1))
            phrase.append(contentsOf: phraseSlice)

            let passphraseSlice = try take(lengths[1])
            let passphrase = SecureBytes(capacity: max(passphraseSlice.count, 1))
            passphrase.append(contentsOf: passphraseSlice)

            let label = sanitize(String(decoding: try take(lengths[2]), as: UTF8.self), limit: 64)
            let notes = sanitize(String(decoding: try take(lengths[3]), as: UTF8.self), limit: 500)

            guard case .valid = BIP39.validate(phrase) else {
                phrase.wipe()
                passphrase.wipe()
                throw Failure.invalidPhrase
            }
            return Contents(phrase: phrase, passphrase: passphrase, label: label, notes: notes, language: language)
        }
    }

    /// Texto vindo de arquivo alheio: sem controles bidirecionais (que reordenam o
    /// que a tela mostra), sem largura zero, sem controle, com tamanho limitado.
    public static func sanitize(_ text: String, limit: Int) -> String {
        let forbidden: Set<UInt32> = Set(Array(0x202A...0x202E) + Array(0x2066...0x2069) + [0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0xFEFF, 0x00AD])
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !forbidden.contains(scalar.value) {
            if scalar.properties.generalCategory == .control, scalar != "\n" { continue }
            scalars.append(scalar)
        }
        return String(String(scalars).prefix(limit))
    }
}
