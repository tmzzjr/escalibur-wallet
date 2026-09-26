import CryptoKit
import Foundation

// O arquivo `.esclbr` v1 do Escalibur, na parte que a carteira usa: lacrar a partir de
// buffer seguro e abrir para buffer seguro. As funcoes do app Escalibur que trabalham
// com o conteudo em `String` (isca, troca de senha, reabertura com texto) nao estao
// aqui: a carteira nao as usa, e codigo que nao roda e superficie de auditoria a toa.
// O formato em disco e o mesmo, byte a byte (tools/decifrar.py e os testes de
// interoperabilidade nos dois sentidos conferem).

/// O que este cofre guarda.
///
/// Uma parte SLIP-39 nao e uma frase BIP-39, e gravar as duas com o mesmo tipo
/// fazia o decifrador de referencia imprimir "idioma english" acima de vinte
/// palavras que nao pertencem a lista inglesa. Quem abrir o arquivo daqui a dez
/// anos precisa saber o que esta lendo.
public enum VaultContentKind: UInt8 {
    case bip39 = 0x01
    case slip39Share = 0x02
}

/// O conteudo no caminho de **lacrar**, com a frase ainda dentro de um buffer zeravel.
///
/// Existe porque o caminho do lacre era o pior vazamento de higiene do app. Ele saia
/// de um `SecureBytes` e virava `String`, depois a normalizacao canonica gerava mais
/// cinco alocacoes intermediarias, depois a struct atravessava a fronteira de thread
/// de uma `Task.detached`, e por fim `encoded()` fazia `Array(text.utf8)`. Eram pelo
/// menos onze copias da frase no heap, das quais **uma** era zerada.
///
/// Aqui a frase nao vira `String` em momento nenhum: os bytes vao do buffer seguro
/// direto para o bloco do compartimento.
public struct SealingContents {
    public let mnemonic: SecureBytes
    /// A 25a palavra, tambem em buffer: vazia quando nao ha.
    public let passphrase: SecureBytes
    public var label: String
    public var notes: String
    public var language: BIP39Language
    public var kind: VaultContentKind

    public func encoded() throws -> [UInt8] {
        let mnemonicLength = mnemonic.count
        let passphraseLength = passphrase.count
        let others = [label, notes].map { Array($0.utf8) }
        let lengths = [mnemonicLength, passphraseLength] + others.map(\.count)
        guard lengths.allSatisfy({ $0 <= Int(UInt16.max) }) else {
            throw CryptoError.malformedVault("campo longo demais")
        }

        var header = [UInt8]()
        header.append(0x01)  // versao do conteudo
        header.append(kind.rawValue)
        header.append(UInt8(BIP39Language.allCases.firstIndex(of: language) ?? 0))
        header.append(0x00)  // reservado
        for length in lengths {
            header.append(contentsOf: UInt16(length).bigEndianBytes)
        }

        let total = header.count + lengths.reduce(0, +)
        guard total <= VaultFormat.plaintextLength else {
            throw CryptoError.malformedVault("conteúdo maior do que um compartimento comporta")
        }

        var block = [UInt8](repeating: 0, count: VaultFormat.plaintextLength)
        block.replaceSubrange(0..<header.count, with: header)

        var cursor = header.count
        // A frase vai byte a byte do buffer para o bloco. Nenhuma copia intermediaria.
        mnemonic.withUnsafeBytes { raw in
            block.replaceSubrange(cursor..<(cursor + raw.count), with: raw)
        }
        cursor += mnemonicLength
        passphrase.withUnsafeBytes { raw in
            block.replaceSubrange(cursor..<(cursor + raw.count), with: raw)
        }
        cursor += passphraseLength
        for field in others {
            block.replaceSubrange(cursor..<(cursor + field.count), with: field)
            cursor += field.count
        }
        return block
    }
}

/// Le e escreve o arquivo `.esclbr`.
///
/// A abertura merece atencao especial e esta documentada em `openBlock`: ela
/// **sempre** tenta os quatro compartimentos, mesmo depois de achar o certo. Sair
/// mais cedo faria o tempo de resposta contar quantos compartimentos existem, e a
/// negacao plausivel morreria por um canal lateral de relogio.
public enum VaultFile {

    // MARK: Criacao

    /// Cria um arquivo novo com um compartimento em uso e tres cheios de ruido.
    /// Lacra um cofre a partir de um conteudo cujo segredo ainda esta em buffer.
    public static func create(
        sealing: SealingContents,
        password: SecureBytes,
        parameters: KDFParameters,
        cloudEnabled: Bool = false,
        slotIndex: Int? = nil
    ) throws -> Data {
        let slot = try slotIndex ?? randomSlotIndex()
        precondition((0..<VaultFormat.slotCount).contains(slot))

        // Nenhum arquivo nasce abaixo do piso de lacre, venha o parametro de onde vier:
        // o cabecalho grava o custo para sempre.
        let header = VaultFormat.Header_(
            vaultID: UUID(),
            kdf: raisedToFloor(parameters),
            kdfSalt: try randomBytes(VaultFormat.saltLength),
            binding: .passwordOnly,
            bindingPublicKey: [UInt8](repeating: 0, count: 65),
            cloudEnabled: cloudEnabled
        )

        var file = header.encoded()
        file.append(contentsOf: try randomBytes(VaultFormat.slotCount * VaultFormat.slotLength))

        var block = try sealing.encoded()
        defer { block.resetBytes() }
        try write(block: block, password: password, into: &file, slotIndex: slot)
        return Data(file)
    }

    /// A gravacao de verdade, sobre um bloco ja serializado.
    ///
    /// Receber o bloco pronto e o que permite o caminho de lacrar nunca materializar a
    /// frase como `String`: quem monta o bloco pode monta-lo a partir de um buffer
    /// zeravel.
    static func write(
        block: [UInt8],
        password: SecureBytes,
        into file: inout [UInt8],
        slotIndex: Int
    ) throws {
        let header = try VaultFormat.Header_.decode(file)
        let headerBytes = Array(file[0..<VaultFormat.headerLength])

        let slotSalt = try randomBytes(VaultFormat.subkeySaltLength)
        let wrapSalt = try randomBytes(VaultFormat.subkeySaltLength)
        let payloadSalt = try randomBytes(VaultFormat.subkeySaltLength)

        let masterKey = try KeyDerivation.deriveMasterKey(
            password: password,
            salt: header.kdfSalt,
            parameters: header.kdf
        )
        defer { masterKey.wipe() }

        let kek = VaultFormat.encryptionKey(
            masterKey: masterKey,
            bindingSecret: nil,
            slotSalt: slotSalt,
            slotIndex: slotIndex,
            vaultID: header.vaultID
        )

        // A chave que cifra o conteudo nasce do gerador do sistema, nunca da senha.
        // E o que faz trocar a senha custar 32 bytes reembrulhados em vez de recifrar
        // o cofre inteiro.
        let dek = try SecureBytes.random(count: VaultFormat.keyLength)
        defer { dek.wipe() }

        let wrapAAD = aadForWrap(header: headerBytes, slotIndex: slotIndex, slotSalt: slotSalt)
        let wrappedDEK = try dek.withUnsafeData { dekData in
            try ChaChaPoly.seal(
                dekData,
                using: VaultFormat.messageKey(from: kek, salt: wrapSalt, purpose: "escalibur/v1/wrap"),
                nonce: VaultFormat.zeroNonce,
                authenticating: Data(wrapAAD)
            )
        }

        let payloadAAD = aadForPayload(
            header: headerBytes,
            slotIndex: slotIndex,
            slotSalt: slotSalt,
            wrapSalt: wrapSalt,
            wrappedDEK: Array(wrappedDEK.ciphertext) + Array(wrappedDEK.tag)
        )
        // `SymmetricKey` zera a si mesma no dealloc; o problema era o `Data`
        // intermediario que a alimentava, que ninguem zerava. O inicializador aceita
        // qualquer `ContiguousBytes`, entao o buffer seguro vai direto.
        let dekKey = dek.withUnsafeBytes { SymmetricKey(data: $0) }
        let sealedPayload = try ChaChaPoly.seal(
            Data(block),
            using: VaultFormat.messageKey(from: dekKey, salt: payloadSalt, purpose: "escalibur/v1/payload"),
            nonce: VaultFormat.zeroNonce,
            authenticating: Data(payloadAAD)
        )

        let base = VaultFormat.headerLength + slotIndex * VaultFormat.slotLength
        replace(&file, at: base + VaultFormat.Slot.salt, with: slotSalt)
        replace(&file, at: base + VaultFormat.Slot.wrapSalt, with: wrapSalt)
        replace(
            &file, at: base + VaultFormat.Slot.wrappedDEK,
            with: Array(wrappedDEK.ciphertext) + Array(wrappedDEK.tag)
        )
        replace(&file, at: base + VaultFormat.Slot.payloadSalt, with: payloadSalt)
        replace(
            &file, at: base + VaultFormat.Slot.payload,
            with: Array(sealedPayload.ciphertext) + Array(sealedPayload.tag)
        )
    }

    // MARK: Abertura

    /// Os parametros de derivacao, elevados ao piso de lacre quando estiverem abaixo.
    private static func raisedToFloor(_ kdf: KDFParameters) -> KDFParameters {
        KDFParameters(
            memoryKiB: max(kdf.memoryKiB, KDFCalibration.sealFloorKiB),
            passes: max(kdf.passes, KDFParameters.passesRange.lowerBound),
            lanes: kdf.lanes
        )
    }

    /// Um indice uniforme em `0..<limit`, por rejeicao de amostra.
    ///
    /// `byte % n` com n que nao divide 256 tem vies: para tres candidatos, o
    /// primeiro saia com 86/256 e os outros com 85/256. Irrelevante hoje, e a mesma
    /// linha reescrita com `slotCount` 5 viraria vies de 20%. A rejeicao custa em
    /// media um sorteio e meio e e uniforme para qualquer limite.
    private static func randomIndex(below limit: Int) throws -> Int {
        precondition(limit > 0 && limit <= 256)
        let ceiling = 256 - (256 % limit)
        while true {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else {
                throw CryptoError.randomnessUnavailable
            }
            if Int(byte) < ceiling { return Int(byte) % limit }
        }
    }

    private static func randomSlotIndex() throws -> Int {
        try randomIndex(below: VaultFormat.slotCount)
    }

    /// O bloco decifrado de um compartimento, ainda em buffer seguro.
    ///
    /// A carteira decodifica o bloco direto para `SecureBytes` (`Envelope.open`),
    /// porque importar nao pode deixar a frase no heap pela vida do processo.
    ///
    /// **Os quatro compartimentos sao sempre tentados, na mesma ordem, mesmo depois de
    /// um abrir.** Parar no primeiro entregaria pelo relogio quantos estao em uso.
    public static func openBlock(
        _ data: Data,
        password: SecureBytes,
        bindingSecret: SecureBytes? = nil
    ) throws -> (block: SecureBytes, slotIndex: Int, header: VaultFormat.Header_) {
        let file = [UInt8](data)
        guard file.count == VaultFormat.fileLength else {
            throw CryptoError.malformedVault("arquivo com tamanho fora do formato")
        }
        let header = try VaultFormat.Header_.decode(file)
        let headerBytes = Array(file[0..<VaultFormat.headerLength])

        if header.binding == .secureEnclave, bindingSecret == nil {
            throw CryptoError.malformedVault(
                "este cofre está vinculado a um aparelho, e este app ainda não sabe reproduzir o vínculo"
            )
        }

        let masterKey = try KeyDerivation.deriveMasterKey(
            password: password,
            salt: header.kdfSalt,
            parameters: header.kdf
        )
        defer { masterKey.wipe() }

        var found: (SecureBytes, Int)?

        for slotIndex in 0..<VaultFormat.slotCount {
            let base = VaultFormat.headerLength + slotIndex * VaultFormat.slotLength
            let slotSalt = Array(file[(base + VaultFormat.Slot.salt)..<(base + VaultFormat.Slot.salt + 32)])
            let wrapSalt = Array(file[(base + VaultFormat.Slot.wrapSalt)..<(base + VaultFormat.Slot.wrapSalt + 32)])
            let wrappedDEK = Array(file[(base + VaultFormat.Slot.wrappedDEK)..<(base + VaultFormat.Slot.wrappedDEK + 48)])
            let payloadSalt = Array(file[(base + VaultFormat.Slot.payloadSalt)..<(base + VaultFormat.Slot.payloadSalt + 32)])
            let payload = Array(file[(base + VaultFormat.Slot.payload)..<(base + VaultFormat.slotLength)])

            let kek = VaultFormat.encryptionKey(
                masterKey: masterKey,
                bindingSecret: bindingSecret,
                slotSalt: slotSalt,
                slotIndex: slotIndex,
                vaultID: header.vaultID
            )

            let wrapAAD = aadForWrap(header: headerBytes, slotIndex: slotIndex, slotSalt: slotSalt)
            guard
                var dekData = try? ChaChaPoly.open(
                    ChaChaPoly.SealedBox(
                        nonce: VaultFormat.zeroNonce,
                        ciphertext: Data(wrappedDEK.prefix(32)),
                        tag: Data(wrappedDEK.suffix(16))
                    ),
                    using: VaultFormat.messageKey(from: kek, salt: wrapSalt, purpose: "escalibur/v1/wrap"),
                    authenticating: Data(wrapAAD)
                )
            else {
                continue  // compartimento de outra senha, ou ruido. Segue tentando.
            }

            let payloadAAD = aadForPayload(
                header: headerBytes, slotIndex: slotIndex, slotSalt: slotSalt,
                wrapSalt: wrapSalt, wrappedDEK: wrappedDEK
            )
            // O `Data` que o ChaChaPoly devolveu e zerado nele mesmo: copiar para outro
            // buffer e zerar a copia deixaria o original intacto no heap.
            defer { Self.zero(&dekData) }
            var dekBytes = [UInt8](dekData)
            defer { dekBytes.resetBytes() }
            let payloadKey = VaultFormat.messageKey(
                from: dekBytes.withUnsafeBytes { SymmetricKey(data: $0) },
                salt: payloadSalt,
                purpose: "escalibur/v1/payload"
            )

            guard
                var blockData = try? ChaChaPoly.open(
                    ChaChaPoly.SealedBox(
                        nonce: VaultFormat.zeroNonce,
                        ciphertext: Data(payload.prefix(VaultFormat.plaintextLength)),
                        tag: Data(payload.suffix(16))
                    ),
                    using: payloadKey,
                    authenticating: Data(payloadAAD)
                )
            else {
                continue
            }
            // Zerar uma copia (`var c = blockData`) nao alcanca o original: o `Data` e
            // copy-on-write, e mexer na copia duplica o buffer. Zera-se o proprio.
            defer { Self.zero(&blockData) }
            if found == nil {
                let block = SecureBytes(capacity: VaultFormat.plaintextLength)
                blockData.withUnsafeBytes { block.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
                found = (block, slotIndex)
            }
        }

        guard let found else { throw CryptoError.cannotOpen }
        return (found.0, found.1, header)
    }

    /// Zera um `Data` no proprio buffer. So vale com referencia unica: quem chama
    /// nao pode ter feito copia antes.
    static func zero(_ data: inout Data) {
        data.withUnsafeMutableBytes { raw in
            guard let address = raw.baseAddress else { return }
            memset_s(address, raw.count, 0, raw.count)
        }
    }

    // MARK: Dados autenticados

    /// O que a tag do embrulho protege: o cabecalho inteiro, a posicao do
    /// compartimento e o salt dele.
    ///
    /// A posicao entra porque, sem ela, um compartimento poderia ser copiado para
    /// outra posicao do arquivo e continuar valido.
    private static func aadForWrap(header: [UInt8], slotIndex: Int, slotSalt: [UInt8]) -> [UInt8] {
        header + [UInt8(slotIndex)] + slotSalt
    }

    /// O que a tag do conteudo protege: tudo do embrulho, mais o proprio embrulho.
    ///
    /// Isso encadeia as duas camadas: trocar o cabecalho, mexer no marcador de nuvem,
    /// ou colar o envelope de outro cofre invalida a tag do conteudo. Nao existe
    /// recortar e colar entre cofres.
    private static func aadForPayload(
        header: [UInt8], slotIndex: Int, slotSalt: [UInt8],
        wrapSalt: [UInt8], wrappedDEK: [UInt8]
    ) -> [UInt8] {
        header + [UInt8(slotIndex)] + slotSalt + wrapSalt + wrappedDEK
    }

    // MARK: Utilidades

    private static func randomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw CryptoError.randomnessUnavailable }
        return bytes
    }

    private static func replace(_ file: inout [UInt8], at offset: Int, with bytes: [UInt8]) {
        file.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
