import EscaliburCore
import Foundation

// A checagem de permissoes da conta Tron.
//
// Na Tron, o endereco nao e a chave. A conta tem `owner_permission` e
// `active_permission`, cada uma com uma lista de chaves, pesos e um threshold, e o dono
// pode trocar tudo isso com `AccountPermissionUpdateContract`. Depois da troca, a chave
// que gerou o endereco ve o saldo mas nao move nada.
//
// E o golpe da "seed com USDT": o golpista publica uma frase de uma conta com USDT e
// passa o controle para outra chave. Quem importa a frase ve o saldo, manda TRX para
// pagar a taxa de saque, e o golpista leva o TRX. Por isso a carteira confere as
// permissoes ao importar e antes de cada plano, e recusa se a chave derivada nao for a
// unica dona.

/// O resultado da checagem. So nasce de `TronPermissions.check`: o chamador nao tem como
/// declarar "conta limpa" sem passar o JSON pela checagem.
public struct TronAccountControl: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// A chave derivada e a unica chave em todas as permissoes e sozinha atinge o
        /// threshold de cada uma.
        case soleOwner
        /// A conta ainda nao existe na rede (`getaccount` devolveu `{}`). Nao ha
        /// permissao gravada; quando ela for criada, nasce com a chave do endereco.
        case notActivated
        /// Outra chave controla ou divide o controle, ou a chave derivada nao alcanca o
        /// threshold. A carteira nao monta transacao para esta conta.
        case compromised([TronPermissionIssue])
    }

    public let address: TronAddress
    public let verdict: Verdict

    init(address: TronAddress, verdict: Verdict) {
        self.address = address
        self.verdict = verdict
    }

    public var isCompromised: Bool {
        if case .compromised = verdict { return true }
        return false
    }
}

/// O que esta errado nas permissoes, para a interface explicar.
public enum TronPermissionIssue: Sendable, Equatable {
    /// Chaves que nao sao a derivada na permissao de dono.
    case ownerForeignKeys([TronAddress])
    /// O peso da chave derivada no dono nao alcanca o threshold (zero se ela nem esta la).
    case ownerThresholdUnreachable(threshold: Int64, weight: Int64)
    /// Chaves que nao sao a derivada numa permissao ativa.
    case activeForeignKeys(permissionID: Int64, keys: [TronAddress])
    case activeThresholdUnreachable(permissionID: Int64, threshold: Int64, weight: Int64)
    /// Chaves estranhas na permissao de produtor de bloco (so contas de SR a tem).
    case witnessForeignKeys([TronAddress])
}

public enum TronPermissions {
    public enum Failure: Error, Equatable, Sendable {
        /// O JSON nao e um objeto, ou falta o endereco numa conta que existe.
        case malformedJSON
        /// O JSON e de outra conta: resposta trocada, nao da para concluir nada.
        case addressMismatch
        case malformedPermission(String)
    }

    /// Confere o JSON de `POST /wallet/getaccount` (com `visible` true ou false) contra
    /// o endereco da chave derivada.
    ///
    /// Regras, da fonte (java-tron, commit d5c3d1d1fd0cad12f09c4346d6ac937ab2cbb071):
    /// - Sem `owner_permission`, vale a padrao: a propria conta, peso 1, threshold 1
    ///   (AccountCapsule.getPermissionById: `getDefaultPermission(address)`). O mesmo
    ///   para `active_permission` ausente.
    /// - Uma transacao sem `Permission_id` e assinada pela permissao de dono (id 0).
    /// - Toda chave estranha em qualquer permissao marca a conta como comprometida,
    ///   mesmo com peso abaixo do threshold: a carteira so opera conta de dono unico.
    public static func check(getAccountJSON data: Data, derived: TronAddress) throws -> TronAccountControl {
        guard let object = try? JSONSerialization.jsonObject(with: data), let account = object as? [String: Any] else {
            throw Failure.malformedJSON
        }
        guard let addressValue = account["address"] else {
            // `{}`: a rede nao conhece a conta.
            guard account.isEmpty else { throw Failure.malformedJSON }
            return TronAccountControl(address: derived, verdict: .notActivated)
        }
        guard let text = addressValue as? String, let address = TronAddress(text) else { throw Failure.malformedJSON }
        guard address == derived else { throw Failure.addressMismatch }

        var issues: [TronPermissionIssue] = []

        if let value = account["owner_permission"] {
            let owner = try Permission(value, name: "owner_permission")
            let (foreign, weight) = owner.evaluate(for: derived)
            if !foreign.isEmpty { issues.append(.ownerForeignKeys(foreign)) }
            if weight < owner.threshold {
                issues.append(.ownerThresholdUnreachable(threshold: owner.threshold, weight: weight))
            }
        }

        if let value = account["active_permission"] {
            guard let list = value as? [Any] else { throw Failure.malformedPermission("active_permission") }
            for item in list {
                let active = try Permission(item, name: "active_permission")
                let (foreign, weight) = active.evaluate(for: derived)
                if !foreign.isEmpty { issues.append(.activeForeignKeys(permissionID: active.id, keys: foreign)) }
                if weight < active.threshold {
                    issues.append(.activeThresholdUnreachable(permissionID: active.id, threshold: active.threshold, weight: weight))
                }
            }
        }

        if let value = account["witness_permission"] {
            let witness = try Permission(value, name: "witness_permission")
            let (foreign, _) = witness.evaluate(for: derived)
            if !foreign.isEmpty { issues.append(.witnessForeignKeys(foreign)) }
        }

        return TronAccountControl(address: derived, verdict: issues.isEmpty ? .soleOwner : .compromised(issues))
    }

    /// Uma permissao lida do JSON (Tron.proto, `message Permission`: threshold = 4,
    /// keys = 7; `message Key`: address = 1, weight = 2).
    private struct Permission {
        let id: Int64
        let threshold: Int64
        let keys: [(address: TronAddress, weight: Int64)]

        init(_ value: Any, name: String) throws {
            guard let object = value as? [String: Any] else { throw Failure.malformedPermission(name) }
            // O java-tron exige threshold maior que zero; ausente no JSON seria zero.
            guard let threshold = Self.integer(object["threshold"]), threshold > 0 else {
                throw Failure.malformedPermission(name)
            }
            guard let rawKeys = object["keys"] as? [Any], !rawKeys.isEmpty else { throw Failure.malformedPermission(name) }
            var keys: [(TronAddress, Int64)] = []
            for rawKey in rawKeys {
                guard let key = rawKey as? [String: Any],
                      let text = key["address"] as? String,
                      let address = TronAddress(text)
                else { throw Failure.malformedPermission(name) }
                let weight = Self.integer(key["weight"]) ?? 0
                guard weight >= 0 else { throw Failure.malformedPermission(name) }
                keys.append((address, weight))
            }
            self.id = Self.integer(object["id"]) ?? 0
            self.threshold = threshold
            self.keys = keys
        }

        /// As chaves estranhas e o peso somado da chave derivada.
        func evaluate(for derived: TronAddress) -> (foreign: [TronAddress], weight: Int64) {
            var foreign: [TronAddress] = []
            var weight: Int64 = 0
            for key in keys {
                if key.address == derived {
                    let (sum, overflow) = weight.addingReportingOverflow(key.weight)
                    weight = overflow ? Int64.max : sum
                } else {
                    foreign.append(key.address)
                }
            }
            return (foreign, weight)
        }

        private static func integer(_ value: Any?) -> Int64? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.int64Value
        }
    }
}
