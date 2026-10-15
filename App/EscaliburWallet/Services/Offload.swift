import Foundation

/// Trabalho pesado e sincrono (Argon2 de 256 MiB, derivacao das contas, cifra do
/// envelope) numa fila do GCD, fora do pool cooperativo do Swift. O pool tem uma thread
/// por nucleo e e de todo o app: um Argon2 de segundos num `Task.detached` segura uma
/// delas o tempo inteiro, e a Apple pede trabalho bloqueante fora dele.
enum Offload {
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    static func compute<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
