import Darwin
import Foundation

/// Um buffer para segredo: senha, chave derivada, frase em claro.
///
/// Nada disso pode morar em `String` nem em `Data`. Os dois crescem realocando, e a
/// alocacao antiga fica no heap com o segredo dentro, sem endereco para apagar. Uma
/// senha digitada em `@State private var senha = ""` deixa para tras `"c"`, `"co"`,
/// `"cor"`, `"corr"`, e um dump de memoria do processo remonta a senha inteira. Isso
/// e um achado conhecido, nao uma preocupacao teorica.
///
/// Este tipo evita as tres armadilhas:
///
/// 1. **Capacidade fixa.** Nunca realoca, entao nunca deixa copia para tras. Estourar
///    a capacidade e erro de programacao e mata o processo, em vez de crescer em
///    silencio.
/// 2. **Paginas de guarda.** A regiao e mapeada com uma pagina inacessivel de cada
///    lado, entao leitura ou escrita fora do buffer estoura na hora, em vez de
///    alcancar o segredo do vizinho.
/// 3. **Zeragem que sobrevive ao otimizador.** `memset_s` do C11 nao pode ser
///    eliminado como escrita morta; `memset` pode, e e removido em `-O` justamente
///    quando ninguem le o resultado, que e sempre o caso aqui.
///
/// O que este tipo **nao** garante, e esta escrito em docs/criptografia.md para nao
/// virar promessa: o compilador ainda pode ter copiado bytes para a pilha ao passar
/// registradores, e o compressor de memoria do iOS pode ter guardado a pagina em
/// forma comprimida. A defesa real contra isso e a janela curta de vida, nao a
/// chamada de sistema.
public final class SecureBytes: @unchecked Sendable {

    /// A sincronizacao e de quem usa: um `SecureBytes` atravessa a fronteira de
    /// tarefa durante a derivacao de chave, e serializar aqui dentro esconderia esse
    /// contrato em vez de cumpri-lo. Cada instancia pertence a um fluxo de cada vez.

    private let region: UnsafeMutableRawPointer
    private let regionSize: Int
    private let base: UnsafeMutableRawPointer

    public let capacity: Int
    private(set) var count: Int = 0

    private var wiped = false

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity

        let pageSize = Int(getpagesize())
        let payloadPages = (capacity + pageSize - 1) / pageSize
        // Uma pagina de guarda antes, uma depois.
        let regionSize = (payloadPages + 2) * pageSize

        guard
            let region = mmap(
                nil, regionSize,
                PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANON, -1, 0
            ),
            region != MAP_FAILED
        else {
            fatalError("SecureBytes: mmap falhou")
        }

        // As guardas ficam sem permissao nenhuma: encostar nelas e sinal, nao
        // corrupcao silenciosa. E o retorno e conferido: um mprotect que falha em
        // silencio deixaria as guardas legiveis e gravaveis sem nenhum sinal, que e o
        // oposto do que elas existem para ser.
        guard mprotect(region, pageSize, PROT_NONE) == 0,
              mprotect(region.advanced(by: regionSize - pageSize), pageSize, PROT_NONE) == 0
        else {
            fatalError("SecureBytes: mprotect recusou as paginas de guarda")
        }

        self.region = region
        self.regionSize = regionSize
        self.base = region.advanced(by: pageSize)
    }

    deinit {
        wipeRegion()
        munmap(region, regionSize)
    }

    // MARK: Escrita

    public func append(_ byte: UInt8) {
        rearm()
        precondition(count + 1 <= capacity, "SecureBytes: capacidade estourada")
        base.advanced(by: count).storeBytes(of: byte, as: UInt8.self)
        count += 1
    }

    public func append(contentsOf buffer: UnsafeBufferPointer<UInt8>) {
        guard let source = buffer.baseAddress, !buffer.isEmpty else { return }
        rearm()
        precondition(count + buffer.count <= capacity, "SecureBytes: capacidade estourada")
        base.advanced(by: count).copyMemory(from: source, byteCount: buffer.count)
        count += buffer.count
    }

    /// Remove os ultimos `n` bytes, apagando o que sai. E o backspace do campo de
    /// senha: o byte removido nao pode continuar legivel no fim do buffer.
    public func removeLast(_ n: Int) {
        guard !wiped, n > 0, count > 0 else { return }
        let removing = min(n, count)
        let start = count - removing
        memset_s(base.advanced(by: start), removing, 0, removing)
        count = start
    }

    public func replaceAll(with bytes: [UInt8]) {
        rearm()
        precondition(bytes.count <= capacity, "SecureBytes: capacidade estourada")
        memset_s(base, capacity, 0, capacity)
        count = 0
        bytes.withUnsafeBufferPointer { append(contentsOf: $0) }
    }

    // MARK: Leitura

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: base, count: count))
    }

    /// Copia para um `Data` de vida curta. Usar so na fronteira com APIs que exigem
    /// `Data`, e nunca guardar o resultado.
    public func withUnsafeData<R>(_ body: (Data) throws -> R) rethrows -> R {
        try withUnsafeBytes { raw in
            var data = Data(raw)
            defer {
                data.withUnsafeMutableBytes { buffer in
                    guard let address = buffer.baseAddress else { return }
                    memset_s(address, buffer.count, 0, buffer.count)
                }
            }
            return try body(data)
        }
    }

    // MARK: Zeragem

    /// Apaga o conteudo. Idempotente, e o buffer continua utilizavel depois de um
    /// `reset()`.
    public func wipe() {
        wipeRegion()
        count = 0
        wiped = true
    }

    /// Escrever depois de uma zeragem **nao pode derrubar o processo**.
    ///
    /// Antes isto era um `precondition`, e ele disparava num caminho banal: uma
    /// notificacao chegando enquanto a senha era digitada fechava o cofre, zerava o
    /// buffer, e a tecla seguinte matava o app. Num aplicativo de custodia, morrer na
    /// hora de abrir o cofre faz o dono achar que perdeu o dinheiro.
    ///
    /// A regiao ja foi zerada quando `wiped` virou verdadeiro, entao rearmar nao
    /// desfaz nenhuma garantia: o segredo antigo nao esta mais la.
    private func rearm() {
        guard wiped else { return }
        wipeRegion()
        count = 0
        wiped = false
    }

    public func reset() {
        wipeRegion()
        count = 0
        wiped = false
    }

    private func wipeRegion() {
        memset_s(base, capacity, 0, capacity)
    }

    // MARK: Construcao

    /// Preenche com bytes do gerador do sistema. Nunca de `Int.random`, nunca de
    /// `arc4random`: chave de cofre so nasce do CSPRNG do sistema.
    public static func random(count: Int) throws -> SecureBytes {
        let bytes = SecureBytes(capacity: count)
        let status = bytes.base.withMemoryRebound(to: UInt8.self, capacity: count) {
            SecRandomCopyBytes(kSecRandomDefault, count, $0)
        }
        guard status == errSecSuccess else {
            bytes.wipe()
            throw CryptoError.randomnessUnavailable
        }
        bytes.count = count
        return bytes
    }
}

public enum CryptoError: Error, Equatable {
    /// `SecRandomCopyBytes` falhou. Nao existe plano B: a operacao aborta.
    case randomnessUnavailable

    /// Argon2 recusou os parametros ou nao conseguiu a memoria pedida.
    case keyDerivationFailed(code: Int32)

    /// A tag de autenticacao nao fecha.
    ///
    /// Deliberadamente um erro so, sem distinguir senha errada de arquivo adulterado.
    /// Separar os dois entregaria ao atacante um verificador barato, e e por isso que
    /// a interface tambem mostra uma unica mensagem.
    case cannotOpen

    /// O arquivo nao e um cofre, ou e de uma versao que este app nao conhece.
    case malformedVault(String)
}
