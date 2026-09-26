import EscaliburCore
import Foundation
import LocalAuthentication
import Security

/// Onde os itens da carteira moram. Um protocolo para os testes poderem trocar o
/// chaveiro por memoria; em producao existe uma implementacao so, `KeychainStore`.
public protocol SecretStore: Sendable {
    func read(_ account: String, context: LAContext?) throws -> Data?
    func add(_ data: Data, account: String, protection: ItemProtection, context: LAContext?) throws
    func update(_ data: Data, account: String) throws
    func delete(_ account: String) throws
    func deleteAll() throws
    func exists(_ account: String) -> Bool
    /// Um contexto que carrega a senha de aplicativo para a proxima operacao, sem
    /// nenhuma interface (`interactionNotAllowed`).
    func applicationPasswordContext(_ password: SecureBytes) -> LAContext?
}

/// A protecao de cada item. So existem estas duas, e as duas sao
/// `WhenPasscodeSetThisDeviceOnly`: o item some se o dono tirar o codigo do iPhone,
/// nunca sincroniza, nunca vai para backup, e nunca abre em outro aparelho.
///
/// Proibidos no projeto inteiro, por verificar.sh: `.userPresence`, `.devicePasscode`,
/// `.biometryAny`, `AfterFirstUnlock` e `Always`. Quem viu o codigo do iPhone passa
/// por `.userPresence`; com `.biometryAny` o ladrao cadastra o proprio rosto.
public enum ItemProtection: Sendable {
    /// Item comum, legivel com o aparelho desbloqueado.
    case standard
    /// Item que o proprio chaveiro so devolve com a senha de aplicativo certa
    /// (`kSecAccessControlApplicationPassword`). E o que prende o PIN ao aparelho:
    /// nao existe verificador de PIN gravado em lugar nenhum; o chaveiro recusa.
    case applicationPassword
}

public enum StoreError: Error, Equatable, Sendable {
    /// O chaveiro recusou a senha de aplicativo: PIN errado.
    case authenticationFailed
    /// O aparelho nao tem codigo configurado.
    case passcodeNotSet
    case unexpected(OSStatus)
}

/// O chaveiro do iOS, com os atributos exatos de docs/seguranca.md §2.3.
public final class KeychainStore: SecretStore, @unchecked Sendable {
    public static let service = "com.thomazjr.escalibur.wallet"

    public init() {}

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
        ]
    }

    public func read(_ account: String, context: LAContext?) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed: throw StoreError.authenticationFailed
        default: throw StoreError.unexpected(status)
        }
    }

    public func add(_ data: Data, account: String, protection: ItemProtection, context: LAContext?) throws {
        var query = baseQuery(account)
        query[kSecValueData as String] = data
        switch protection {
        case .standard:
            query[kSecAttrAccessible as String] = Self.accessibility
        case .applicationPassword:
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, Self.accessibility, [.applicationPassword], &error) else {
                throw StoreError.unexpected(errSecParam)
            }
            query[kSecAttrAccessControl as String] = access
        }
        if let context { query[kSecUseAuthenticationContext as String] = context }
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return
        case errSecDecode, errSecNotAvailable: throw StoreError.passcodeNotSet
        default: throw StoreError.unexpected(status)
        }
    }

    /// Altera no lugar. O contador de tentativas usa isto e nunca apagar e recriar:
    /// um `SecItemAdd` que falha depois de um `SecItemDelete` (disco cheio) zerava o
    /// atraso no Escalibur. Aqui, se a gravacao falha, a tentativa nao e avaliada.
    public func update(_ data: Data, account: String) throws {
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { throw StoreError.unexpected(status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.unexpected(status) }
    }

    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue!,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.unexpected(status) }
    }

    public func exists(_ account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    public func applicationPasswordContext(_ password: SecureBytes) -> LAContext? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let ok = password.withUnsafeData { context.setCredential($0, type: .applicationPassword) }
        return ok ? context : nil
    }

    /// No aparelho, `WhenPasscodeSetThisDeviceOnly`. O simulador nao tem codigo de
    /// aparelho e recusa essa classe; so nele, e so em compilacao para simulador,
    /// a classe cai para `WhenUnlockedThisDeviceOnly`. verificar.sh confere que esta
    /// e a unica excecao e que ela esta atras de `targetEnvironment(simulator)`.
    static var accessibility: CFString {
        #if targetEnvironment(simulator)
        return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        return kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        #endif
    }
}

/// Armazenamento em memoria, para testes. Simula a recusa por senha de aplicativo
/// comparando a credencial, o que o chaveiro real faz por dentro.
public final class MemoryStore: SecretStore, @unchecked Sendable {
    private var items: [String: (Data, ItemProtection, Data?)] = [:]
    private let lock = NSLock()
    /// Credencial usada pela proxima leitura ou gravacao com senha de aplicativo.
    public var pendingCredential: Data?

    public init() {}

    public func read(_ account: String, context: LAContext?) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let (data, protection, credential) = items[account] else { return nil }
        if protection == .applicationPassword, credential != pendingCredential { throw StoreError.authenticationFailed }
        return data
    }

    public func add(_ data: Data, account: String, protection: ItemProtection, context: LAContext?) throws {
        lock.lock(); defer { lock.unlock() }
        guard items[account] == nil else { throw StoreError.unexpected(errSecDuplicateItem) }
        items[account] = (data, protection, protection == .applicationPassword ? pendingCredential : nil)
    }

    public func update(_ data: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let existing = items[account] else { throw StoreError.unexpected(errSecItemNotFound) }
        items[account] = (data, existing.1, existing.2)
    }

    public func delete(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = nil
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }

    public func exists(_ account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return items[account] != nil
    }

    public func applicationPasswordContext(_ password: SecureBytes) -> LAContext? {
        lock.lock(); defer { lock.unlock() }
        pendingCredential = password.withUnsafeBytes { Data($0) }
        return nil
    }
}
