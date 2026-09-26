import Foundation
import CArgon2
import os

/// Os parametros do Argon2id de um cofre.
///
/// Eles moram no cabecalho do arquivo e sao lidos **de la** na abertura, nunca da
/// configuracao do aparelho atual. E o que faz um cofre criado num iPhone antigo
/// abrir num novo sem cerimonia, e o que permite subir o custo depois sem quebrar
/// arquivo nenhum.
public struct KDFParameters: Equatable, Sendable {
    /// Memoria em KiB.
    public var memoryKiB: UInt32
    /// Numero de passes.
    public var passes: UInt32
    /// Faixas de trilha.
    public var lanes: UInt8

    /// O padrao de referencia, para aparelho que aguenta.
    /// `p = 4`, e nao 1.
    ///
    /// As faixas de trilha sao um multiplicador que **so o defensor ganha**: com
    /// quatro faixas num aparelho de varios nucleos, a mesma parede de tempo comporta
    /// quatro vezes mais trafego de memoria por tentativa. O atacante ja paraleliza
    /// entre palpites e nao tira proveito extra disso.
    public static let reference = KDFParameters(memoryKiB: 512 * 1024, passes: 4, lanes: 4)

    /// Os limites aceitos na leitura de um arquivo.
    ///
    /// Existem por um motivo bem concreto: sem eles, alguem escreve `m = 4 GiB` no
    /// seu arquivo e o app se mata tentando alocar. A validacao acontece **antes** de
    /// qualquer alocacao. Nao e defesa contra downgrade, que o AAD ja impede, e sim
    /// contra negacao de servico.
    public static let memoryRange: ClosedRange<UInt32> = (64 * 1024)...(1024 * 1024)
    public static let passesRange: ClosedRange<UInt32> = 2...16
    public static let lanesRange: ClosedRange<UInt8> = 1...8

    public var isWithinAcceptedRange: Bool {
        Self.memoryRange.contains(memoryKiB)
            && Self.passesRange.contains(passes)
            && Self.lanesRange.contains(lanes)
    }

    /// Quanto o cofre custa por tentativa, em MiB de trafego de memoria. O numero que
    /// a interface mostra ao dono vem daqui.
    public var memoryTrafficMiB: Double {
        2 * Double(memoryKiB) / 1024 * Double(passes)
    }
}

/// Argon2id v1.3, RFC 9106, sobre a implementacao de referencia compilada junto com
/// o app.
///
/// Argon2id foi escolhido porque o gargalo dele e **largura de banda de memoria**, e
/// e exatamente ai que uma fazenda de GPU e ruim. PBKDF2 com um milhao de iteracoes
/// e limitado por ALU, que e onde a GPU e otima: a troca custaria cerca de dois mil
/// vezes menos ao atacante.
public enum KeyDerivation {

    /// Normaliza a senha, uma vez, imediatamente antes de derivar.
    ///
    /// **A forma da senha e parte do formato, e ela precisa estar num lugar so.**
    /// Antes a normalizacao acontecia no campo de digitacao, a cada tecla, sobre o
    /// pedaco que o teclado entregava. Isso e diferente de normalizar a senha
    /// inteira: NFKC nao e fechado sob concatenacao, e uma sequencia composta que
    /// chega em dois eventos ("e" e depois o acento) ficava sem combinar. A mesma
    /// senha colada de uma vez produzia outros bytes, outra chave, e um cofre que nao
    /// abre. Agora o campo guarda os bytes crus e a normalizacao acontece aqui.
    ///
    /// A forma e NFKC, e esta escrita em docs/formato.md e no decifrar.py. Sem isso
    /// documentado, o cofre abriria no app e nao no decifrador de referencia, e a
    /// descoberta seria no dia da recuperacao.
    public static func normalized(_ password: SecureBytes) -> SecureBytes {
        let needsWork = password.withUnsafeBytes { bytes in
            bytes.contains { $0 >= 0x80 }
        }
        // Senha so de ASCII e o proprio NFKC dela. O caminho comum nao materializa
        // String nenhuma.
        guard needsWork else { return password }

        var text = password.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        var bytes = Array(text.precomposedStringWithCompatibilityMapping.utf8)
        defer {
            bytes.resetBytes()
            text = ""
        }
        let out = SecureBytes(capacity: max(bytes.count, password.capacity))
        out.replaceAll(with: bytes)
        return out
    }

    /// Deriva a chave mestra a partir da senha.
    ///
    /// Sai e entra em `SecureBytes`: a senha nao vira `Data` no caminho, e a chave
    /// nasce ja dentro de uma regiao zeravel.
    public static func deriveMasterKey(
        password: SecureBytes,
        salt: [UInt8],
        parameters: KDFParameters
    ) throws -> SecureBytes {
        guard parameters.isWithinAcceptedRange else {
            throw CryptoError.malformedVault("parâmetros de derivação fora da faixa aceita")
        }
        guard salt.count == VaultFormat.saltLength else {
            throw CryptoError.malformedVault("salt com tamanho inválido")
        }

        let normalizedPassword = normalized(password)
        defer { if normalizedPassword !== password { normalizedPassword.wipe() } }

        let key = SecureBytes(capacity: VaultFormat.keyLength)
        var scratch = [UInt8](repeating: 0, count: VaultFormat.keyLength)
        defer { scratch.resetBytes() }

        let status: Int32 = normalizedPassword.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBufferPointer { saltBytes in
                argon2id_hash_raw(
                    parameters.passes,
                    parameters.memoryKiB,
                    UInt32(parameters.lanes),
                    passwordBytes.baseAddress,
                    passwordBytes.count,
                    saltBytes.baseAddress,
                    saltBytes.count,
                    &scratch,
                    scratch.count
                )
            }
        }

        guard status == ARGON2_OK.rawValue else {
            key.wipe()
            throw CryptoError.keyDerivationFailed(code: status)
        }

        key.replaceAll(with: scratch)
        return key
    }
}

/// Escolhe os parametros que este aparelho aguenta.
///
/// A regra que guia a calibracao: **memoria vale mais que passes**. Contra GPU, a
/// memoria e o gargalo real, entao entre reduzir `m` e reduzir `t`, reduza `t`.
public enum KDFCalibration {

    /// Alvo de tempo para uma abertura de cofre. Acima disso o dono desiste do app,
    /// abaixo disso o atacante fica barato demais.
    public static let targetSeconds: Double = 1.5

    /// Faixas de trilha. Ver a nota em `KDFParameters.reference`: e o unico parametro
    /// que o defensor ganha de graca. Limitado pelos nucleos que o aparelho tem.
    public static var lanes: UInt8 {
        UInt8(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))
    }
    public static let ceilingSeconds: Double = 2.5

    private static let log = Logger(subsystem: "com.thomazjr.escalibur.wallet", category: "kdf")

    /// Teto de memoria seguro para este aparelho.
    ///
    /// Pedir mais do que o sistema tem para dar nao rende cofre mais forte: rende o
    /// app morto pelo jetsam no meio da derivacao, que para o dono e um cofre que nao
    /// abre.
    /// O piso para **lacrar** um cofre novo.
    ///
    /// A faixa aceita na leitura continua em 64 MiB, para cofres antigos abrirem. A
    /// assimetria e proposital: um cofre nasce forte, e nenhum cofre existente vira
    /// ilegivel.
    ///
    /// Sem este piso, um vale momentaneo de memoria disponivel (app voltando do
    /// segundo plano, sistema sob pressao) fazia `byAvailable` virar zero, e o cofre
    /// nascia com 64 MiB gravados no cabecalho, **para sempre**: oito vezes mais
    /// tentativas por segundo para o atacante, sem nenhum aviso ao dono, e sem
    /// caminho no app para re-derivar depois.
    public static let sealFloorKiB: UInt32 = 256 * 1024

    /// Memoria disponivel ao processo agora, em bytes. No iOS e o teto do jetsam.
    public static func availableMemoryBytes() -> UInt64 {
        #if os(iOS)
        return UInt64((0..<3).map { _ in os_proc_available_memory() }.max() ?? 0)
        #else
        return ProcessInfo.processInfo.physicalMemory / 2
        #endif
    }

    /// Custo medido deste aparelho, em segundos por KiB por passe. Medido uma vez,
    /// com uma derivacao pequena, e reaproveitado.
    private static let unitCost: Double = {
        let probeMemory: UInt32 = 64 * 1024
        let probe = SecureBytes(capacity: 16)
        probe.replaceAll(with: [UInt8](repeating: 0x61, count: 16))
        defer { probe.wipe() }
        let salt = [UInt8](repeating: 0x00, count: VaultFormat.saltLength)
        let started = Date()
        _ = try? KeyDerivation.deriveMasterKey(
            password: probe, salt: salt,
            parameters: KDFParameters(memoryKiB: probeMemory, passes: 2, lanes: lanes)
        )
        return Date().timeIntervalSince(started) / (Double(probeMemory) * 2)
    }()

    /// Quanto uma derivacao com estes parametros leva neste aparelho. A interface usa
    /// para avisar antes de abrir um envelope caro vindo de fora.
    public static func estimatedSeconds(for parameters: KDFParameters) -> Double {
        let laneFactor = Double(lanes) / Double(max(1, min(Int(parameters.lanes), Int(lanes))))
        return unitCost * Double(parameters.memoryKiB) * Double(parameters.passes) * laneFactor
    }

    public static func memoryCeilingKiB() -> UInt32 {
        let physical = ProcessInfo.processInfo.physicalMemory
        // Tres medidas, vale a maior: uma so pode cair num vale transitorio.
        #if os(iOS)
        let available = (0..<3).map { _ in os_proc_available_memory() }.max() ?? 0
        #else
        // No Mac (so os testes rodam aqui) nao existe o teto do jetsam.
        let available = Int(physical / 2)
        #endif

        let byPhysical = physical / 8
        // Deixa folga para a interface e para o resto do processo.
        let byAvailable = available > 400 * 1024 * 1024 ? UInt64(available) - 400 * 1024 * 1024 : 0
        let reference = UInt64(KDFParameters.reference.memoryKiB) * 1024

        let bytes = min(reference, min(byPhysical, byAvailable))
        let kib = UInt32(bytes / 1024)
        return max(kib, KDFParameters.memoryRange.lowerBound)
    }

    /// Mede a taxa real deste aparelho com uma derivacao pequena e escolhe o maior
    /// numero de passes que ainda cabe no tempo alvo.
    public static func calibrate(password sample: SecureBytes? = nil) -> KDFParameters {
        let memory = memoryCeilingKiB()

        let probeMemory: UInt32 = 64 * 1024
        let probe = SecureBytes(capacity: 16)
        probe.replaceAll(with: [UInt8](repeating: 0x61, count: 16))
        defer { probe.wipe() }
        let salt = [UInt8](repeating: 0x00, count: VaultFormat.saltLength)

        let started = Date()
        _ = try? KeyDerivation.deriveMasterKey(
            password: probe,
            salt: salt,
            parameters: KDFParameters(memoryKiB: probeMemory, passes: 2, lanes: Self.lanes)
        )
        let probeSeconds = Date().timeIntervalSince(started)

        // O custo do Argon2id e proporcional a memoria vezes passes, entao a medida
        // pequena projeta a grande.
        let unitCost = probeSeconds / (Double(probeMemory) * 2)

        var chosenPasses: UInt32 = KDFParameters.passesRange.lowerBound
        for candidate in [8, 6, 4, 3, 2] as [UInt32] {
            let predicted = unitCost * Double(memory) * Double(candidate)
            if predicted <= targetSeconds {
                chosenPasses = candidate
                break
            }
            chosenPasses = candidate
        }

        let predicted = unitCost * Double(memory) * Double(chosenPasses)
        log.info(
            "calibração: m=\(memory, privacy: .public) KiB t=\(chosenPasses, privacy: .public) previsto=\(predicted, privacy: .public)s"
        )

        return KDFParameters(memoryKiB: memory, passes: chosenPasses, lanes: Self.lanes)
    }
}
