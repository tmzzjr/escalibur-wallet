import CryptoKit
import Foundation

/// O conteudo de um compartimento, depois de aberto.
///
/// Tudo que tem significado esta aqui dentro, e portanto cifrado: o nome do cofre
/// inclusive. Nome em claro no arquivo conta a quem o pega quais carteiras o dono
/// tem, e isso sozinho ja transforma alguem em alvo.
public struct VaultContents {
    /// O que este cofre guarda.
    ///
    /// Uma parte SLIP-39 nao e uma frase BIP-39, e gravar as duas com o mesmo tipo
    /// fazia o decifrador de referencia imprimir "idioma english" acima de vinte
    /// palavras que nao pertencem a lista inglesa. Quem abrir o arquivo daqui a dez
    /// anos precisa saber o que esta lendo.
    public enum Kind: UInt8 {
        case bip39 = 0x01
        case slip39Share = 0x02
    }

    public var mnemonic: String
    public var passphrase: String
    public var label: String
    public var notes: String
    public var language: BIP39Language
    public var kind: Kind = .bip39

    /// Serializa para o bloco de tamanho fixo do compartimento.
    ///
    /// O bloco tem sempre o mesmo tamanho, entao nao existe padding a calcular: o que
    /// sobra fica zerado. E por isso que uma frase de 12 palavras e uma de 24 produzem
    /// arquivos identicos em tamanho.
    public func encoded() throws -> [UInt8] {
        var body = [UInt8]()
        var fields: [(UInt16, [UInt8])] = []

        for text in [mnemonic, passphrase, label, notes] {
            let bytes = Array(text.utf8)
            guard bytes.count <= Int(UInt16.max) else {
                throw CryptoError.malformedVault("campo longo demais")
            }
            fields.append((UInt16(bytes.count), bytes))
        }

        var header = [UInt8]()
        header.append(0x01)  // versao do conteudo
        header.append(kind.rawValue)  // tipo: 0x01 frase BIP-39, 0x02 parte SLIP-39
        header.append(UInt8(BIP39Language.allCases.firstIndex(of: language) ?? 0))
        header.append(0x00)  // reservado
        for (length, _) in fields {
            header.append(contentsOf: length.bigEndianBytes)
        }
        for (_, bytes) in fields {
            body.append(contentsOf: bytes)
        }

        let total = header.count + body.count
        guard total <= VaultFormat.plaintextLength else {
            throw CryptoError.malformedVault("conteúdo maior do que um compartimento comporta")
        }

        var block = [UInt8](repeating: 0, count: VaultFormat.plaintextLength)
        block.replaceSubrange(0..<header.count, with: header)
        block.replaceSubrange(header.count..<(header.count + body.count), with: body)
        return block
    }

    public static func decode(_ block: [UInt8]) throws -> VaultContents {
        guard
            block.count == VaultFormat.plaintextLength, block[0] == 0x01,
            let kind = Kind(rawValue: block[1])
        else {
            throw CryptoError.cannotOpen
        }
        let languageIndex = Int(block[2])
        let language = BIP39Language.allCases.indices.contains(languageIndex)
            ? BIP39Language.allCases[languageIndex]
            : .english

        var lengths: [Int] = []
        for field in 0..<4 {
            let start = 4 + field * 2
            lengths.append(Int(UInt16(bigEndian: block[start..<(start + 2)])))
        }

        var cursor = 12
        var texts: [String] = []
        for length in lengths {
            guard cursor + length <= block.count else { throw CryptoError.cannotOpen }
            texts.append(String(decoding: block[cursor..<(cursor + length)], as: UTF8.self))
            cursor += length
        }

        return VaultContents(
            mnemonic: texts[0],
            passphrase: texts[1],
            label: texts[2],
            notes: texts[3],
            language: language,
            kind: kind
        )
    }
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
    public var passphrase: String = ""
    public var label: String
    public var notes: String
    public var language: BIP39Language
    public var kind: VaultContents.Kind

    public func encoded() throws -> [UInt8] {
        let mnemonicLength = mnemonic.count
        let others = [passphrase, label, notes].map { Array($0.utf8) }
        let lengths = [mnemonicLength] + others.map(\.count)
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
        for field in others {
            block.replaceSubrange(cursor..<(cursor + field.count), with: field)
            cursor += field.count
        }
        return block
    }
}

/// Le e escreve o arquivo `.esclbr`.
///
/// A abertura merece atencao especial e esta documentada em `open`: ela **sempre**
/// tenta os quatro compartimentos, mesmo depois de achar o certo. Sair mais cedo
/// faria o tempo de resposta contar quantos compartimentos existem, e a negacao
/// plausivel morreria por um canal lateral de relogio.
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

    public static func create(
        contents: VaultContents,
        password: SecureBytes,
        parameters: KDFParameters,
        binding: VaultFormat.Binding = .passwordOnly,
        cloudEnabled: Bool = false,
        slotIndex: Int? = nil
    ) throws -> Data {
        // **O compartimento real e sorteado.** Enquanto todo cofre nascia no
        // compartimento 0, o dia em que o cofre-isca existisse ele cairia no 1, e a
        // ordem de preenchimento viraria a prova de que existe um cofre escondido:
        // abrir o 1 diria que ha um 0. Sortear agora e uma linha; depois de existirem
        // cofres em campo nao tem mais conserto, porque um arquivo antigo com o real
        // no 0 seria distinguivel de um novo.
        let slotIndex = try slotIndex ?? randomSlotIndex()
        precondition((0..<VaultFormat.slotCount).contains(slotIndex))

        // **O cabecalho nunca pode anunciar o que a chave nao cumpre.** O vinculo com
        // o Secure Enclave existe no formato e ainda nao existe na derivacao: `write`
        // nao recebe segredo de vinculo nenhum. Aceitar `.secureEnclave` aqui
        // produziria um arquivo que anuncia vinculo com o aparelho enquanto abre com a
        // senha em qualquer iPhone, e a especificacao publicada passaria a descrever
        // arquivos que mentem. Recusar e a unica saida honesta ate a implementacao
        // chegar.
        guard binding == .passwordOnly else {
            throw CryptoError.malformedVault("vínculo com o aparelho ainda não implementado")
        }

        let header = VaultFormat.Header_(
            vaultID: UUID(),
            kdf: raisedToFloor(parameters),
            kdfSalt: try randomBytes(VaultFormat.saltLength),
            binding: binding,
            bindingPublicKey: [UInt8](repeating: 0, count: 65),
            cloudEnabled: cloudEnabled
        )

        // Os compartimentos comecam inteiramente aleatorios. O que nao for usado
        // permanece assim, e ruido nao se distingue de cifra autenticada.
        var file = header.encoded()
        file.append(contentsOf: try randomBytes(VaultFormat.slotCount * VaultFormat.slotLength))

        try write(
            contents: contents,
            password: password,
            into: &file,
            slotIndex: slotIndex
        )
        return Data(file)
    }

    /// Grava um conteudo num compartimento de um arquivo que ja existe.
    ///
    /// Toda gravacao sorteia salts novos, entao nenhuma chave de mensagem se repete.
    /// E isso, e nao um contador, que garante que o nonce nunca colide: um contador
    /// voltaria no tempo quando o dono restaurasse um backup do iPhone, e reemitir um
    /// nonce em cifra autenticada nao vaza so a mensagem, vaza a chave que autentica.
    public static func write(
        contents: VaultContents,
        password: SecureBytes,
        into file: inout [UInt8],
        slotIndex: Int
    ) throws {
        var block = try contents.encoded()
        defer { block.resetBytes() }
        try write(block: block, password: password, into: &file, slotIndex: slotIndex)
    }

    /// A gravacao de verdade, sobre um bloco ja serializado.
    ///
    /// Receber o bloco pronto e o que permite o caminho de lacrar nunca materializar a
    /// frase como `String`: quem monta o bloco pode monta-lo a partir de um buffer
    /// zeravel.
    public static func write(
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

    public struct Opened {
        var contents: VaultContents
        var slotIndex: Int
        var header: VaultFormat.Header_
    }

    /// Abre o arquivo com a senha dada.
    ///
    /// **Os quatro compartimentos sao sempre tentados, e sempre na mesma ordem, mesmo
    /// depois de um deles abrir.** Parar no primeiro que abre economizaria alguns
    /// microssegundos e entregaria de graca a informacao que o formato inteiro existe
    /// para esconder: quantos compartimentos estao em uso e qual deles e o do dono.
    ///
    /// O Argon2 roda **uma vez**, nao quatro, porque o salt caro e do arquivo e o que
    /// distingue os compartimentos e o HKDF, que custa microssegundos. Sem isso, abrir
    /// um cofre levaria seis segundos.
    /// Sorteia um compartimento com o gerador do sistema. Nunca com o da linguagem:
    /// um gerador previsivel aqui devolveria a ordem de preenchimento ao atacante.
    // MARK: Troca de senha

    /// Troca a senha do cofre, preservando a identidade dele.
    ///
    /// O identificador e o marcador de nuvem atravessam intactos, entao o arquivo
    /// continua sendo o mesmo cofre para a estante e para o indice de nomes. Todo o
    /// resto nasce de novo: salt de derivacao, compartimento sorteado, ruido dos
    /// compartimentos vazios. **Um cofre com a senha trocada e indistinguivel de um
    /// cofre recem-criado**, e e assim que tem de ser: um arquivo que preservasse os
    /// compartimentos antigos deixaria a senha velha abrindo o conteudo velho.
    ///
    /// O preco declarado: a troca reescreve o arquivo inteiro, entao **um
    /// compartimento isca gravado antes da troca nao sobrevive a ela.** A isca
    /// pertence a senha velha; quem trocou a senha recria a isca.
    public static func rekey(
        _ data: Data,
        currentPassword: SecureBytes,
        newPassword: SecureBytes
    ) throws -> Data {
        try reseal(open(data, password: currentPassword), newPassword: newPassword)
    }

    /// O miolo da troca, para quem ja pagou a derivacao da senha atual.
    ///
    /// A interface abre o cofre uma vez, mostra a etapa da senha nova, e chama isto:
    /// exigir a senha atual de novo aqui seria cobrar um segundo Argon2 por nada.
    public static func reseal(_ opened: Opened, newPassword: SecureBytes) throws -> Data {
        let header = VaultFormat.Header_(
            vaultID: opened.header.vaultID,
            // O custo sobe ate o piso de lacre e nunca desce. Um envelope importado
            // de um aparelho antigo pode carregar m=64 MiB, quatro vezes mais chutes
            // por segundo que o pior cofre novo; a troca de senha e o unico momento
            // em que o app tem a chave na mao e vai reescrever tudo de qualquer
            // jeito, entao e o momento de subir o que estiver abaixo do piso.
            kdf: raisedToFloor(opened.header.kdf),
            kdfSalt: try randomBytes(VaultFormat.saltLength),
            binding: .passwordOnly,
            bindingPublicKey: [UInt8](repeating: 0, count: 65),
            cloudEnabled: opened.header.cloudEnabled
        )

        var file = header.encoded()
        file.append(contentsOf: try randomBytes(VaultFormat.slotCount * VaultFormat.slotLength))
        try write(
            contents: opened.contents,
            password: newPassword,
            into: &file,
            slotIndex: try randomSlotIndex()
        )
        return Data(file)
    }

    // MARK: Compartimento isca

    /// Grava um segundo conteudo, com senha propria, num compartimento livre.
    ///
    /// E a funcao que aproveita a propriedade que o formato sempre teve: os quatro
    /// compartimentos sao indistinguiveis de ruido, entao um deles pode guardar um
    /// conteudo de sacrificio que abre com uma senha de sacrificio. Sob coacao, o
    /// dono entrega a senha da isca, o cofre abre, e nada no arquivo prova que
    /// existe outro compartimento.
    ///
    /// A senha real e exigida aqui por um motivo mecanico: sem abrir o compartimento
    /// real nao ha como saber qual ele e, e a isca poderia cair em cima dele. O
    /// compartimento da isca e sorteado entre os outros tres; **uma isca anterior
    /// que esteja num deles pode ser sobrescrita**, porque o arquivo nao tem como
    /// saber dela, e nao saber e o ponto.
    public static func addDecoy(
        to data: Data,
        realPassword: SecureBytes,
        decoyContents: VaultContents,
        decoyPassword: SecureBytes
    ) throws -> Data {
        try plantDecoy(
            open(data, password: realPassword),
            realPassword: realPassword,
            decoyContents: decoyContents,
            decoyPassword: decoyPassword
        )
    }

    /// Grava a isca reescrevendo **o arquivo inteiro**, nunca um compartimento so.
    ///
    /// A primeira versao disto trocava apenas os 4096 bytes do compartimento da
    /// isca, e isso era um erro critico: quem tivesse duas versoes do arquivo, um
    /// backup de ontem e o arquivo de hoje, via exatamente um bloco mudado, e sob
    /// coacao a senha entregue abria justamente o bloco que apareceu depois. A
    /// negacao plausivel morria num diff. Reescrevendo tudo, cabecalho com salt
    /// novo, quatro compartimentos renascidos, um cofre com isca fica indistinguivel
    /// de um cofre recem-lacrado, de uma troca de senha, e de um cofre sem isca.
    ///
    /// A senha real e exigida por dois motivos mecanicos: o compartimento real
    /// precisa ser recifrado sob o salt novo, e a senha da isca precisa ser
    /// **diferente** da real. Sem essa recusa, uma isca com a mesma senha fazia dois
    /// compartimentos abrirem com ela, e a abertura devolvia o primeiro: o cofre
    /// real ficava integro, no arquivo, e inalcancavel. O dono concluiria que perdeu
    /// a frase.
    ///
    /// No fim, a pos-condicao reabre o arquivo com as duas senhas e exige que cada
    /// uma caia no proprio compartimento. Se qualquer coisa nao bater, o resultado e
    /// descartado e o arquivo original fica como estava.
    public static func plantDecoy(
        _ opened: Opened,
        realPassword: SecureBytes,
        decoyContents: VaultContents,
        decoyPassword: SecureBytes
    ) throws -> Data {
        guard !Hash.constantTimeEqual(realPassword, decoyPassword) else {
            throw CryptoError.malformedVault(
                "a senha da isca precisa ser diferente da senha do cofre"
            )
        }

        let header = VaultFormat.Header_(
            vaultID: opened.header.vaultID,
            kdf: raisedToFloor(opened.header.kdf),
            kdfSalt: try randomBytes(VaultFormat.saltLength),
            binding: .passwordOnly,
            bindingPublicKey: [UInt8](repeating: 0, count: 65),
            cloudEnabled: opened.header.cloudEnabled
        )

        var file = header.encoded()
        file.append(contentsOf: try randomBytes(VaultFormat.slotCount * VaultFormat.slotLength))

        let realSlot = try randomIndex(below: VaultFormat.slotCount)
        let others = (0..<VaultFormat.slotCount).filter { $0 != realSlot }
        let decoySlot = others[try randomIndex(below: others.count)]

        try write(contents: opened.contents, password: realPassword, into: &file, slotIndex: realSlot)
        try write(contents: decoyContents, password: decoyPassword, into: &file, slotIndex: decoySlot)

        let armed = Data(file)
        let realCheck = try open(armed, password: realPassword)
        let decoyCheck = try open(armed, password: decoyPassword)
        guard realCheck.slotIndex == realSlot, decoyCheck.slotIndex == decoySlot else {
            throw CryptoError.malformedVault("a gravação da isca não passou na conferência")
        }
        return armed
    }

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

    public static func open(
        _ data: Data,
        password: SecureBytes,
        bindingSecret: SecureBytes? = nil
    ) throws -> Opened {
        let raw = try openBlock(data, password: password, bindingSecret: bindingSecret)
        defer { raw.block.wipe() }
        let bytes = raw.block.withUnsafeBytes { Array($0) }
        var clearable = bytes
        defer { clearable.resetBytes() }
        guard let contents = try? VaultContents.decode(clearable) else { throw CryptoError.cannotOpen }
        return Opened(contents: contents, slotIndex: raw.slotIndex, header: raw.header)
    }

    /// O bloco decifrado de um compartimento, ainda em buffer seguro.
    ///
    /// E a abertura de verdade. `open` decodifica o bloco para `String` (o caminho do
    /// Escalibur, que exibe a frase); a carteira usa este e decodifica direto para
    /// `SecureBytes` (`OpeningContents`), porque importar nao pode deixar a frase no
    /// heap pela vida do processo.
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
                let dekData = try? ChaChaPoly.open(
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
            var dekBytes = [UInt8](dekData)
            defer { dekBytes.resetBytes() }
            let payloadKey = VaultFormat.messageKey(
                from: dekBytes.withUnsafeBytes { SymmetricKey(data: $0) },
                salt: payloadSalt,
                purpose: "escalibur/v1/payload"
            )

            guard
                let blockData = try? ChaChaPoly.open(
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
            var clearable = blockData
            defer {
                clearable.withUnsafeMutableBytes { raw in
                    guard let address = raw.baseAddress else { return }
                    memset_s(address, raw.count, 0, raw.count)
                }
            }
            if found == nil {
                let block = SecureBytes(capacity: VaultFormat.plaintextLength)
                clearable.withUnsafeBytes { block.append(contentsOf: $0.bindMemory(to: UInt8.self)) }
                found = (block, slotIndex)
            }
        }

        guard let found else { throw CryptoError.cannotOpen }
        return (found.0, found.1, header)
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
