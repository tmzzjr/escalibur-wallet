import Foundation

/// A porta de entrada da carteira para o envelope Escalibur (`.esclbr`).
///
/// O formato e o do app Escalibur, sem nenhuma extensao: um envelope lacrado aqui
/// abre no cofre e no decifrador de referencia em Python, e um envelope do cofre
/// abre aqui. `VaultFormat` e `VaultFile` sao a copia do Escalibur, e os testes de
/// interoperabilidade conferem os dois sentidos.
public enum Envelope {
    /// O que um envelope aberto entrega a carteira.
    public struct Contents: Sendable {
        /// A frase, na forma canonica, em buffer seguro.
        public let phrase: SecureBytes
        /// A 25a palavra, quando o dono gravou uma. Vazia quase sempre.
        public let passphrase: String
        public let label: String
        public let notes: String
        public let language: BIP39Language
        /// Uma parte SLIP-39 nao e uma carteira sozinha: a interface mostra, mas nao
        /// importa.
        public let isSLIP39Share: Bool
    }

    /// Lacra uma frase num envelope novo, com parametros de Argon2id calibrados para
    /// este aparelho e nunca abaixo do piso de lacre.
    public static func seal(
        phrase: SecureBytes,
        passphrase: String = "",
        label: String,
        notes: String = "",
        password: SecureBytes,
        parameters: KDFParameters? = nil
    ) throws -> Data {
        let chosen = parameters ?? KDFCalibration.calibrate()
        let sealing = SealingContents(
            mnemonic: phrase,
            passphrase: passphrase,
            label: label,
            notes: notes,
            language: detectLanguage(phrase),
            kind: .bip39
        )
        let data = try VaultFile.create(sealing: sealing, password: password, parameters: chosen)
        // Conferencia antes de entregar: um envelope que nao abre com a senha que o
        // dono acabou de digitar nao pode sair daqui.
        let check = try VaultFile.open(data, password: password)
        let original = phrase.withUnsafeBytes { Array($0) }
        var reopened = Array(check.contents.mnemonic.utf8)
        defer { reopened.resetBytes() }
        guard Hash.constantTimeEqual(original, reopened) else {
            throw CryptoError.malformedVault("o envelope gravado não confere com a frase")
        }
        return data
    }

    /// Abre um envelope vindo de fora. O arquivo e dado nao confiavel: tamanho,
    /// cabecalho e parametros do KDF sao validados antes de qualquer alocacao grande.
    public static func open(_ data: Data, password: SecureBytes) throws -> Contents {
        let opened = try VaultFile.open(data, password: password)
        var text = opened.contents.mnemonic
        defer { text = "" }
        let phrase = BIP39.canonical(text)
        return Contents(
            phrase: phrase,
            passphrase: opened.contents.passphrase,
            label: opened.contents.label,
            notes: opened.contents.notes,
            language: opened.contents.language,
            isSLIP39Share: opened.contents.kind == .slip39Share
        )
    }

    /// Um arquivo parece um envelope? Confere so tamanho e assinatura, sem senha.
    public static func looksLikeEnvelope(_ data: Data) -> Bool {
        data.count == VaultFormat.fileLength && data.prefix(6) == Data(VaultFormat.magic)
    }

    private static func detectLanguage(_ phrase: SecureBytes) -> BIP39Language {
        if case .valid(let language) = BIP39.validate(phrase) { return language }
        return .english
    }
}
