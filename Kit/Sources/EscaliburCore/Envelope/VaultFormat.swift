import CryptoKit
import Foundation

/// O formato do arquivo `.esclbr`, campo a campo.
///
/// Duas exigencias se cruzam aqui, e a segunda molda a primeira:
///
/// - Do desenho criptografico: envelope explicito. A chave que cifra a frase (`DEK`)
///   nasce do gerador do sistema e nunca da senha; ela e guardada embrulhada por uma
///   chave derivada da senha (`KEK`). Trocar a senha re-embrulha 32 bytes em vez de
///   re-cifrar o cofre inteiro.
///
/// - Do desenho de custodia: negacao plausivel de verdade. Um cofre isca guardado
///   como "mais um arquivo" nao nega nada, porque a existencia do arquivo ja e a
///   prova. Entao **todo arquivo tem sempre quatro compartimentos do mesmo tamanho**,
///   e os compartimentos sem uso ficam cheios de bytes aleatorios. Cifra autenticada
///   e ruido sao indistinguiveis, entao quem obriga o dono a abrir um compartimento
///   nao consegue provar que existe outro.
///
/// Consequencias que valem por si:
///
/// - **Todo cofre tem exatamente 16.504 bytes.** O tamanho do arquivo nao conta
///   quantas palavras a frase tem, se ha anotacao, nem quantos compartimentos estao
///   em uso. Metadado de tamanho e de graca para o atacante escolher qual arquivo
///   atacar primeiro, e aqui ele nao existe.
/// - **O cabecalho em claro nao tem nada com significado.** Sem nome, sem data, sem
///   dica de senha, sem contador. So o que a mecanica de abertura exige. O nome do
///   cofre mora dentro do compartimento cifrado, porque "Ledger principal" escrito em
///   claro ja diz a quem pega o arquivo que vale a pena insistir.
///
/// O formato e publico de proposito. Um cofre que so este app abre e um cofre com
/// prazo de validade, e a especificacao em docs/formato.md mais o decifrador de
/// referencia existem para que o dono nunca dependa da loja de aplicativos.
public enum VaultFormat {

    // MARK: Constantes

    public static let magic: [UInt8] = Array("ESCLBR".utf8)
    public static let formatVersion: UInt8 = 0x01

    /// Argon2id v1.3 + HKDF-SHA256 + ChaCha20-Poly1305 com subchave por mensagem.
    public static let suiteID: UInt8 = 0x01
    public static let kdfID: UInt8 = 0x01

    public static let headerLength = 120
    public static let saltLength = 16
    public static let keyLength = 32
    public static let subkeySaltLength = 32
    public static let tagLength = 16

    /// Quatro, sempre. Nao e um contador gravado no arquivo: e uma constante desta
    /// versao do formato, entao ler o arquivo nao diz quantos estao em uso.
    public static let slotCount = 4
    public static let slotLength = 4096

    public static let fileLength = headerLength + slotCount * slotLength

    // MARK: Deslocamentos do cabecalho

    private enum Header {
        static let magic = 0            // 6
        static let formatVersion = 6    // 1
        static let suiteID = 7          // 1
        static let vaultUUID = 8        // 16
        static let kdfID = 24           // 1
        static let kdfMemoryKiB = 25    // 4
        static let kdfPasses = 29       // 4
        static let kdfLanes = 33        // 1
        static let kdfSalt = 34         // 16
        static let bindingID = 50       // 1
        static let reserved = 51        // 1
        static let bindingPublicKey = 52  // 65
        static let cloudFlag = 117      // 1
        static let reserved2 = 118      // 2
    }

    /// Deslocamentos dentro de um compartimento.
    public enum Slot {
        static let salt = 0             // 32
        static let wrapSalt = 32        // 32
        static let wrappedDEK = 64      // 48 = 32 de cifra + 16 de tag
        static let payloadSalt = 112    // 32
        static let payload = 144        // 3952 = 3936 de texto + 16 de tag
        static let payloadLength = 3952
        static let plaintextLength = 3952 - VaultFormat.tagLength
    }

    public static let plaintextLength = Slot.plaintextLength

    // MARK: Vinculo com o aparelho

    public enum Binding: UInt8, Sendable {
        /// O arquivo abre com a senha, em qualquer aparelho. E o que permite backup.
        case passwordOnly = 0x00

        /// A chave tambem depende de um segredo que so este aparelho consegue
        /// reproduzir, no Secure Enclave. Elimina o ataque offline por completo, e
        /// cobra o preco correspondente: perdeu o aparelho, perdeu o cofre.
        case secureEnclave = 0x01
    }

    // MARK: Cabecalho

    public struct Header_ : Equatable, Sendable {
        var vaultID: UUID
        var kdf: KDFParameters
        var kdfSalt: [UInt8]
        var binding: Binding
        var bindingPublicKey: [UInt8]  // 65 bytes, zeros quando nao ha vinculo
        var cloudEnabled: Bool

        func encoded() -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: VaultFormat.headerLength)
            bytes.replaceSubrange(Header.magic..<(Header.magic + 6), with: VaultFormat.magic)
            bytes[Header.formatVersion] = VaultFormat.formatVersion
            bytes[Header.suiteID] = VaultFormat.suiteID

            let uuid = withUnsafeBytes(of: vaultID.uuid) { Array($0) }
            bytes.replaceSubrange(Header.vaultUUID..<(Header.vaultUUID + 16), with: uuid)

            bytes[Header.kdfID] = VaultFormat.kdfID
            bytes.replaceSubrange(
                Header.kdfMemoryKiB..<(Header.kdfMemoryKiB + 4),
                with: kdf.memoryKiB.bigEndianBytes
            )
            bytes.replaceSubrange(
                Header.kdfPasses..<(Header.kdfPasses + 4),
                with: kdf.passes.bigEndianBytes
            )
            bytes[Header.kdfLanes] = kdf.lanes
            bytes.replaceSubrange(
                Header.kdfSalt..<(Header.kdfSalt + VaultFormat.saltLength),
                with: kdfSalt
            )
            bytes[Header.bindingID] = binding.rawValue
            bytes.replaceSubrange(
                Header.bindingPublicKey..<(Header.bindingPublicKey + 65),
                with: bindingPublicKey
            )
            bytes[Header.cloudFlag] = cloudEnabled ? 0x01 : 0x00
            return bytes
        }

        static func decode(_ bytes: [UInt8]) throws -> Header_ {
            guard bytes.count >= VaultFormat.headerLength else {
                throw CryptoError.malformedVault("arquivo curto demais para ser um cofre")
            }
            guard Array(bytes[Header.magic..<(Header.magic + 6)]) == VaultFormat.magic else {
                throw CryptoError.malformedVault("este arquivo não é um cofre do Escalibur")
            }
            // Versao exata, e nao "ate a atual": aceitar 0x00 e trata-lo como v1
            // daria significado retroativo a um valor que a especificacao reservou
            // como invalido. Nao e vetor de downgrade, porque o cabecalho inteiro
            // entra no AAD, mas um arquivo escrito a mao com 0x00 nao pode passar.
            guard bytes[Header.formatVersion] == VaultFormat.formatVersion else {
                throw CryptoError.malformedVault(
                    bytes[Header.formatVersion] > VaultFormat.formatVersion
                        ? "cofre de uma versão mais nova do formato; atualize o app"
                        : "versão de formato inválida"
                )
            }
            guard bytes[Header.suiteID] == VaultFormat.suiteID,
                  bytes[Header.kdfID] == VaultFormat.kdfID
            else {
                throw CryptoError.malformedVault("conjunto de algoritmos desconhecido")
            }

            let uuidBytes = Array(bytes[Header.vaultUUID..<(Header.vaultUUID + 16)])
            let vaultID = uuidBytes.withUnsafeBytes { raw in
                UUID(uuid: raw.load(as: uuid_t.self))
            }

            let kdf = KDFParameters(
                memoryKiB: UInt32(
                    bigEndian: Array(bytes[Header.kdfMemoryKiB..<(Header.kdfMemoryKiB + 4)])
                ),
                passes: UInt32(
                    bigEndian: Array(bytes[Header.kdfPasses..<(Header.kdfPasses + 4)])
                ),
                lanes: bytes[Header.kdfLanes]
            )
            // A faixa e conferida aqui, antes de qualquer alocacao. Um arquivo com
            // `m = 4 GiB` escrito a mao mataria o app por falta de memoria, e isso
            // seria negacao de servico de graca.
            guard kdf.isWithinAcceptedRange else {
                throw CryptoError.malformedVault("parâmetros de derivação fora da faixa aceita")
            }

            guard let binding = Binding(rawValue: bytes[Header.bindingID]) else {
                throw CryptoError.malformedVault("tipo de vínculo desconhecido")
            }

            let cloudEnabled = bytes[Header.cloudFlag] == 0x01
            // Um cofre preso a este aparelho e ao mesmo tempo marcado para a nuvem
            // seria lixo irrecuperavel do outro lado. So um adversario produz essa
            // combinacao, entao ela e recusada.
            guard !(binding == .secureEnclave && cloudEnabled) else {
                throw CryptoError.malformedVault("cofre com vínculo de aparelho não vai para a nuvem")
            }

            return Header_(
                vaultID: vaultID,
                kdf: kdf,
                kdfSalt: Array(bytes[Header.kdfSalt..<(Header.kdfSalt + VaultFormat.saltLength)]),
                binding: binding,
                bindingPublicKey: Array(
                    bytes[Header.bindingPublicKey..<(Header.bindingPublicKey + 65)]
                ),
                cloudEnabled: cloudEnabled
            )
        }
    }

    // MARK: Material de chave

    /// `KEK` do compartimento `index`.
    ///
    /// O salt do Argon2 e do arquivo, nao do compartimento, e isso e deliberado: com
    /// um salt por compartimento, abrir um cofre exigiria rodar o Argon2 quatro
    /// vezes, o que a 1,5 s cada tornaria a abertura insuportavel. Com um salt so, a
    /// derivacao cara acontece uma vez e os quatro compartimentos sao testados com
    /// HKDF, que e barato.
    public static func encryptionKey(
        masterKey: SecureBytes,
        bindingSecret: SecureBytes?,
        slotSalt: [UInt8],
        slotIndex: Int,
        vaultID: UUID
    ) -> SymmetricKey {
        var ikm = [UInt8]()
        defer { ikm.resetBytes() }

        masterKey.withUnsafeBytes { ikm.append(contentsOf: $0) }
        // O segredo do aparelho entra na **mesma** chave, e nao num segundo
        // compartimento. Num segundo compartimento, o compartimento da senha
        // continuaria atacavel offline e o vinculo nao valeria nada.
        bindingSecret?.withUnsafeBytes { ikm.append(contentsOf: $0) }

        var info = Array("escalibur/v1/kek".utf8)
        info.append(UInt8(slotIndex))
        info.append(contentsOf: withUnsafeBytes(of: vaultID.uuid) { Array($0) })

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: slotSalt,
            info: info,
            outputByteCount: keyLength
        )
    }

    /// Subchave de uma operacao de cifra.
    ///
    /// O nonce e sempre zero, e isso e seguro porque a **chave** nunca se repete: ela
    /// nasce de um salt de 32 bytes aleatorios gerado a cada gravacao. E o padrao do
    /// `secretstream` do libsodium, e resolve de forma definitiva o problema que
    /// derrubaria um contador de nonce: restaurar um backup antigo do iPhone faz o
    /// contador voltar no tempo e reemitir um nonce ja usado, o que em cifra
    /// autenticada nao vaza so a mensagem, vaza a chave de autenticacao.
    public static func messageKey(from key: SymmetricKey, salt: [UInt8], purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: salt,
            info: Array(purpose.utf8),
            outputByteCount: keyLength
        )
    }

    /// Doze zeros, sempre. E seguro porque a **chave** nunca se repete: cada
    /// operacao deriva a sua a partir de um salt sorteado na hora.
    public static let zeroNonce = try! ChaChaPoly.Nonce(
        data: Data(repeating: 0, count: 12)
    )
}

// MARK: - Conversao de inteiros

extension UInt32 {
    public var bigEndianBytes: [UInt8] {
        [UInt8(truncatingIfNeeded: self >> 24),
         UInt8(truncatingIfNeeded: self >> 16),
         UInt8(truncatingIfNeeded: self >> 8),
         UInt8(truncatingIfNeeded: self)]
    }

    public init(bigEndian bytes: [UInt8]) {
        precondition(bytes.count == 4)
        self = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }
}

extension UInt16 {
    public var bigEndianBytes: [UInt8] {
        [UInt8(truncatingIfNeeded: self >> 8), UInt8(truncatingIfNeeded: self)]
    }

    public init(bigEndian bytes: ArraySlice<UInt8>) {
        precondition(bytes.count == 2)
        let start = bytes.startIndex
        self = (UInt16(bytes[start]) << 8) | UInt16(bytes[start + 1])
    }
}
