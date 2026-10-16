import CryptoKit
import EscaliburCore
import Foundation
import LocalAuthentication
import Security

/// Chaves de hardware que embrulham a chave raiz (RK).
///
/// Chaves P-256 no Secure Enclave:
/// - `K_pin` (e `K_pin` da troca de PIN em andamento): `.privateKeyUsage` +
///   `.applicationPassword`, com a senha derivada do PIN. O SE so desembrulha com ela:
///   cada chute de PIN passa por este aparelho, um de cada vez (auditoria 3, A1;
///   conferido num iPhone 13 Pro Max em 10/10/2026: a senha errada e recusada pelo
///   proprio SE, 22 ms por tentativa).
/// - `K_dev`: so `.privateKeyUsage`. A chave do PIN das versoes anteriores; e trocada
///   pela `K_pin` no primeiro PIN certo e apagada.
/// - `K_bio`: `.privateKeyUsage` + `.biometryCurrentSet`. Embrulha a RK para o
///   caminho do Face ID. A decisao de liberar e do SEP, nao de um booleano no app, e
///   cadastrar um rosto novo destroi a chave em vez de abri-la.
///
/// Nenhum embrulho abre fora deste aparelho: a parte privada nunca sai do SE.
public protocol KeyWrapper: Sendable {
    func createKey(_ slot: WrapSlot) throws
    func hasKey(_ slot: WrapSlot) -> Bool
    func deleteKey(_ slot: WrapSlot)
    func wrap(_ secret: SecureBytes, slot: WrapSlot) throws -> Data
    /// Abre um embrulho. No slot biometrico, o sistema mostra o Face ID com
    /// `reason`; a chamada bloqueia a thread ate a decisao, entao nunca no MainActor.
    func unwrap(_ blob: Data, slot: WrapSlot, reason: String?) throws -> SecureBytes
    /// Cria a chave do slot do PIN com senha de aplicativo. Substitui a que houver no
    /// mesmo slot: o slot do PIN so e gravado quando nao existe.
    func createKey(_ slot: WrapSlot, password: Data) throws
    /// Desembrulha com a senha de aplicativo. Senha errada: `EnclaveError.wrongPassword`.
    func unwrap(_ blob: Data, slot: WrapSlot, password: Data) throws -> SecureBytes
    /// Existe, nao existe, ou o SE e o chaveiro nao conseguiram dizer. "Nao sei" nunca vira
    /// "nao existe": e o que separa "o Face ID mudou" de "o iPhone esta bloqueado".
    func probeKey(_ slot: WrapSlot) -> ItemState
}

public enum WrapSlot: String, Sendable, CaseIterable {
    case device = "kdev"
    case biometry = "kbio"
    /// A chave do slot principal do PIN, com senha de aplicativo.
    case pin = "kpin"
    /// A do slot da troca de PIN em andamento.
    case pinPending = "kpin.novo"
    /// Modo reforcado: a camada de fora do rk.and, `.biometryCurrentSet`.
    case hardenedBiometry = "kand.bio"
    /// Modo reforcado: a camada de dentro, `.applicationPassword` derivada do PIN. Duas
    /// geracoes que se alternam na troca de PIN; o cabecalho do rk.and diz qual vale.
    case hardenedPINA = "kand.pin.a"
    case hardenedPINB = "kand.pin.b"

    public var usesBiometry: Bool { self == .biometry || self == .hardenedBiometry }
    public var usesPassword: Bool { [.pin, .pinPending, .hardenedPINA, .hardenedPINB].contains(self) }
}

public enum EnclaveError: Error, Equatable, Sendable {
    case unavailable
    case keyMissing
    /// A autenticacao nao liberou a chave desta vez. Se o cadastro de rostos mudou, e
    /// o RootKeyVault que decide, comparando o estado gravado.
    case cancelled
    case failed(String)
    /// O SE recusou a senha de aplicativo: o PIN nao e este.
    case wrongPassword
}

/// O Secure Enclave de verdade.
public final class SecureEnclaveWrapper: KeyWrapper, @unchecked Sendable {
    private static let tagPrefix = "app.escalibur.wallet."
    private static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    public init() {}

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    private func tag(_ slot: WrapSlot) -> Data { Data((Self.tagPrefix + slot.rawValue).utf8) }

    public func createKey(_ slot: WrapSlot) throws {
        // A chave do aparelho nunca e substituida em silencio: ela e o que abre a RK
        // de todas as carteiras. So a da biometria e recriada ao religar.
        if slot == .device, hasKey(.device) { throw EnclaveError.failed("chave do aparelho ja existe") }
        guard slot == .device || slot.usesBiometry else { throw EnclaveError.failed("o slot do PIN pede senha") }
        deleteKey(slot)
        let flags: SecAccessControlCreateFlags = slot == .device
            ? [.privateKeyUsage]
            : [.privateKeyUsage, .biometryCurrentSet]
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, KeychainStore.accessibility, flags, &error) else {
            throw EnclaveError.failed("controle de acesso")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag(slot),
                kSecAttrAccessControl as String: access,
            ],
        ]
        guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil else {
            throw EnclaveError.unavailable
        }
    }

    public func hasKey(_ slot: WrapSlot) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        return (try? privateKey(slot, context: context)) != nil
    }

    public func probeKey(_ slot: WrapSlot) -> ItemState {
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag(slot),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed: return .present
        case errSecItemNotFound: return .absent
        default: return .unknown
        }
    }

    public func deleteKey(_ slot: WrapSlot) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag(slot),
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func privateKey(_ slot: WrapSlot, context: LAContext?) throws -> SecKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag(slot),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else { throw EnclaveError.keyMissing }
        return item as! SecKey  // swiftlint:disable:this force_cast
    }

    public func wrap(_ secret: SecureBytes, slot: WrapSlot) throws -> Data {
        let key = try privateKey(slot, context: nil)
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw EnclaveError.keyMissing }
        var error: Unmanaged<CFError>?
        let blob = secret.withUnsafeData { plain in
            SecKeyCreateEncryptedData(publicKey, Self.algorithm, plain as CFData, &error)
        }
        guard let blob else { throw EnclaveError.failed("embrulho") }
        return blob as Data
    }

    public func unwrap(_ blob: Data, slot: WrapSlot, reason: String?) throws -> SecureBytes {
        let context = LAContext()
        // Nenhum reuso de autenticacao: cada assinatura pede presenca nova. Sem botao
        // de alternativa do sistema: a alternativa e o PIN do app.
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = ""
        if let reason { context.localizedReason = reason } else { context.interactionNotAllowed = true }
        let key: SecKey
        do {
            key = try privateKey(slot, context: context)
        } catch {
            throw EnclaveError.keyMissing
        }
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(key, Self.algorithm, blob as CFData, &error) else {
            let nsError = (error?.takeRetainedValue() as Error?).map { $0 as NSError }
            // Qualquer recusa da autenticacao (cancelar, ligacao chegando, bloqueio por
            // tentativas, rosto nao reconhecido) e "nao desta vez", nao "a biometria
            // mudou". Quem decide se o cadastro mudou e o RootKeyVault, pelo estado.
            if nsError?.domain == LAErrorDomain || nsError?.code == Int(errSecUserCanceled) || nsError?.code == Int(errSecAuthFailed) {
                throw EnclaveError.cancelled
            }
            throw EnclaveError.failed("desembrulho")
        }
        return SecureBytes.consuming(plain)
    }
}

extension SecureEnclaveWrapper {
    /// O contexto com a senha de aplicativo vale para uma chamada so: na volta, a
    /// credencial e solta e o contexto invalidado, para a senha derivada do PIN nao ficar
    /// retida num objeto vivo (auditoria 4, C7-21). O mesmo que `KeychainStore` faz.
    private static func release(_ context: LAContext) {
        context.setCredential(nil, type: .applicationPassword)
        context.invalidate()
    }

    public func createKey(_ slot: WrapSlot, password: Data) throws {
        guard slot.usesPassword else { throw EnclaveError.failed("senha so nos slots do PIN") }
        deleteKey(slot)
        let context = LAContext()
        defer { Self.release(context) }
        guard context.setCredential(password, type: .applicationPassword) else { throw EnclaveError.failed("credencial") }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, KeychainStore.accessibility, [.privateKeyUsage, .applicationPassword], &error) else {
            throw EnclaveError.failed("controle de acesso")
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseAuthenticationContext as String: context,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(("app.escalibur.wallet." + slot.rawValue).utf8),
                kSecAttrAccessControl as String: access,
            ],
        ]
        guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil else { throw EnclaveError.unavailable }
    }

    public func unwrap(_ blob: Data, slot: WrapSlot, password: Data) throws -> SecureBytes {
        let context = LAContext()
        defer { Self.release(context) }
        context.interactionNotAllowed = true
        guard context.setCredential(password, type: .applicationPassword) else { throw EnclaveError.failed("credencial") }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(("app.escalibur.wallet." + slot.rawValue).utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item else { throw EnclaveError.keyMissing }
        let key = item as! SecKey  // swiftlint:disable:this force_cast
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(key, .eciesEncryptionCofactorVariableIVX963SHA256AESGCM, blob as CFData, &error) else {
            let nsError = (error?.takeRetainedValue() as Error?).map { $0 as NSError }
            // A senha errada volta do proprio SE como erro do CryptoTokenKit (no iPhone,
            // "dado corrompido": a senha entra na chave) ou como falha de autenticacao.
            if nsError?.domain == "CryptoTokenKit" || nsError?.code == Int(errSecAuthFailed) || nsError?.domain == LAErrorDomain {
                throw EnclaveError.wrongPassword
            }
            throw EnclaveError.failed("desembrulho")
        }
        return SecureBytes.consuming(plain)
    }
}

extension SecureBytes {
    /// Copia de um `CFData` que acabou de sair de uma API do sistema para o buffer
    /// seguro, e apaga a origem. O `CFData` e imutavel pela API, mas a memoria e do
    /// processo: zerar e o que encurta a janela do segredo em claro.
    static func consuming(_ data: CFData) -> SecureBytes {
        let length = CFDataGetLength(data)
        let out = SecureBytes(capacity: max(length, 1))
        if let pointer = CFDataGetBytePtr(data), length > 0 {
            out.append(contentsOf: UnsafeBufferPointer(start: pointer, count: length))
            memset_s(UnsafeMutableRawPointer(mutating: pointer), length, 0, length)
        }
        return out
    }
}

#if DEBUG
/// So no build de teste: o experimento do MUST 1 (auditoria 1) e do A1 (auditoria 3).
/// Uma chave descartavel no Secure Enclave com `.privateKeyUsage` e
/// `.applicationPassword`, que nunca toca as chaves da carteira (tag propria, apagada no
/// fim). Confere no aparelho de verdade se o SE abre com a senha certa e recusa a
/// errada e a falta dela, sem pedir nada na tela, e quanto custa cada tentativa.
public enum EnclaveSpike {
    static let tag = Data("app.escalibur.wallet.experimento".utf8)
    static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    public static func run() -> [String] {
        var log: [String] = ["Secure Enclave disponivel: \(SecureEnclave.isAvailable)"]
        delete()
        defer { delete() }
        let password = Data("senha-certa-do-experimento".utf8)
        let creation = LAContext()
        creation.setCredential(password, type: .applicationPassword)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, KeychainStore.accessibility, [.privateKeyUsage, .applicationPassword], &error) else {
            log.append("controle de acesso: recusado (\(describe(error)))")
            return log
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseAuthenticationContext as String: creation,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access,
            ],
        ]
        guard let created = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            log.append("criar a chave: recusado (\(describe(error)))")
            return log
        }
        log.append("criar a chave: ok")
        guard let publicKey = SecKeyCopyPublicKey(created),
              let blob = SecKeyCreateEncryptedData(publicKey, algorithm, Data("segredo do experimento".utf8) as CFData, &error) as Data?
        else {
            log.append("embrulhar: falhou (\(describe(error)))")
            return log
        }
        log.append(attempt("senha certa", credential: password))
        log.append(attempt("senha errada", credential: Data("senha-errada".utf8)))
        log.append(attempt("sem senha", credential: nil))
        let start = Date()
        var refused = 0
        for index in 0..<20 where !attempt("errada \(index)", credential: Data("errada-\(index)".utf8)).hasSuffix("abriu") { refused += 1 }
        log.append("20 erradas seguidas: \(refused) recusadas, \(String(format: "%.0f", Date().timeIntervalSince(start) * 1000 / 20)) ms cada")
        log.append(attempt("senha certa depois das 20 erradas", credential: password))
        _ = blob
        return log

        func attempt(_ label: String, credential: Data?) -> String {
            let context = LAContext()
            context.interactionNotAllowed = true
            if let credential { context.setCredential(credential, type: .applicationPassword) }
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecReturnRef as String: true,
                kSecUseAuthenticationContext as String: context,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            guard status == errSecSuccess, let item else { return "\(label): chave nao encontrada (\(status))" }
            let key = item as! SecKey  // swiftlint:disable:this force_cast
            var failure: Unmanaged<CFError>?
            if let plain = SecKeyCreateDecryptedData(key, algorithm, blob as CFData, &failure) as Data? {
                return "\(label): \(plain == Data("segredo do experimento".utf8) ? "abriu" : "abriu com conteudo errado")"
            }
            return "\(label): recusou (\(describe(failure)))"
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error = error?.takeRetainedValue() else { return "sem erro" }
        let ns = error as Error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
#endif
