import CryptoKit
import EscaliburCore
import Foundation
import Security

/// Cifra a frase enquanto ela e digitada, tecla a tecla: a mesma construcao do
/// Escalibur original (Escalibur/Crypto/LiveCipher.swift), trazida para a carteira a
/// pedido do dono (14/10/2026).
///
/// **Como funciona.** Ao abrir a tela, o app sorteia uma chave de sessao de 32 bytes do
/// gerador do sistema. A cada tecla, o que esta digitado naquela posicao e cifrado com
/// ChaCha20-Poly1305 sob uma subchave daquela posicao e daquela escrita, e a tela recebe
/// so glifos derivados da tag de autenticacao, que muda inteira a cada bit de diferenca.
/// O que aparece no lugar da palavra e o resultado de uma operacao criptografica de
/// verdade, nao um sorteio de caracteres.
///
/// **Por que glifos num relogio proprio.** Os glifos trocam num relogio de 12 Hz, ligado
/// ao foco e nao a digitacao: cada quadro deriva glifos novos da tag (HKDF com o tique),
/// entao a tela cintila do mesmo jeito com ou sem tecla, e uma camera nao le o ritmo da
/// digitacao. A fileira cresce com a palavra em digitacao (sem isso nao ha como saber
/// que a tecla entrou). Na importacao, a palavra confirmada fica com um glifo por letra
/// (pedido do dono, 16/10/2026): o tamanho ja aparecia enquanto ela era digitada, e as
/// quatro de antes pareciam palavra cortada.
///
/// **O que isto nao e.** Nao protege a frase mais do que o cofre ja protege: a protecao
/// de verdade e o Secure Enclave e o cofre cifrado. Isto mostra, de forma verificavel,
/// que o app cifra o que o dono digita, e tira a palavra da tela.
@MainActor
final class LiveCipher {
    /// Falso se o gerador do sistema recusou: a tela cai em pontos, nunca em chave fixa
    /// (uma chave conhecida tornaria os glifos calculaveis por qualquer um).
    let isOperational: Bool
    private let sessionKey: SymmetricKey
    /// A tag Poly1305 de cada posicao, recalculada a cada escrita.
    private var tags: [Int: [UInt8]] = [:]
    /// Cada escrita usa uma subchave nova: a mesma chave e o mesmo nonce nunca selam
    /// dois textos diferentes.
    private var writes: UInt64 = 0

    static let alphabet = Array("0123456789ABCDEF")

    init() {
        var material = [UInt8](repeating: 0, count: 32)
        isOperational = SecRandomCopyBytes(kSecRandomDefault, material.count, &material) == errSecSuccess
        sessionKey = SymmetricKey(data: material)
        material.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    }

    /// Cifra o que esta na posicao `index` agora. Vazio apaga a tag.
    func seal(_ index: Int, bytes: UnsafeRawBufferPointer) {
        guard isOperational, !bytes.isEmpty else {
            tags[index] = nil
            return
        }
        writes &+= 1
        var info = Data("escalibur-wallet/v1/frase".utf8)
        info.append(contentsOf: withUnsafeBytes(of: UInt32(truncatingIfNeeded: index).littleEndian) { Array($0) })
        info.append(contentsOf: withUnsafeBytes(of: writes.littleEndian) { Array($0) })
        let subkey = HKDF<SHA256>.deriveKey(inputKeyMaterial: sessionKey, info: info, outputByteCount: 32)
        // Nonce fixo: a subchave e unica por escrita.
        guard let nonce = try? ChaChaPoly.Nonce(data: Data(count: 12)),
              let box = try? ChaChaPoly.seal(bytes, using: subkey, nonce: nonce)
        else {
            tags[index] = nil
            return
        }
        tags[index] = Array(box.tag)
    }

    func seal(_ index: Int, text: String) {
        var bytes = Array(text.utf8)
        bytes.withUnsafeBytes { seal(index, bytes: $0) }
        bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    }

    func seal(_ index: Int, buffer: SecureBytes) {
        buffer.withUnsafeBytes { seal(index, bytes: $0) }
    }

    func clear(_ index: Int) { tags[index] = nil }

    func clearAll() { tags.removeAll() }

    /// `count` glifos da posicao no instante `tick`. Sem tag (vazio), nada; sem gerador,
    /// pontos.
    func glyphs(_ index: Int, count: Int, tick: UInt64) -> String {
        guard count > 0 else { return "" }
        guard isOperational, let tag = tags[index] else { return String(repeating: "•", count: count) }
        var info = Data("escalibur-wallet/v1/tela".utf8)
        info.append(contentsOf: withUnsafeBytes(of: UInt32(truncatingIfNeeded: index).littleEndian) { Array($0) })
        info.append(contentsOf: withUnsafeBytes(of: tick.littleEndian) { Array($0) })
        let stream = HKDF<SHA256>.deriveKey(inputKeyMaterial: sessionKey, salt: Data(tag), info: info, outputByteCount: 32)
            .withUnsafeBytes { Array($0) }
        return String((0..<count).map { Self.alphabet[Int(stream[$0 % stream.count]) % 16] })
    }
}
