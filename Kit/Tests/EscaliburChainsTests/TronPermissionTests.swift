import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

/// Checagem de permissoes contra respostas reais de `POST /wallet/getaccount`
/// (Fixtures/tron/conta-*.json, mainnet, 25/09/2026) e casos sinteticos de multi-sig.
@Suite("Tron: permissoes da conta")
struct TronPermissionTests {
    static let normal = TronAddress("41c6d1f82361a9cdd04366501432fdfece5236a8d2")!
    /// TR8Ab9eQAwF1fPE8Baf5L4z6uf2ngaBxPu: passou owner e active para TShbAfd9... na tx
    /// b6b8a2e4a1bd683b471220ea86d423a34b7c9e86134910dd645856990b716303.
    static let changed = TronAddress("41a63b9de5c9a77026af57e3156f106782a8b1ebe0")!
    static let attacker = TronAddress("41b785fc63372bced2b345e8edc1913260465c6e0b")!

    @Test("Conta real com permissoes padrao: dono unico (hex e base58)")
    func normalAccount() throws {
        let hexForm = try TronPermissions.check(getAccountJSON: TronFixtures.load("conta-normal"), derived: Self.normal)
        #expect(hexForm.verdict == .soleOwner)
        let visible = try TronPermissions.check(getAccountJSON: TronFixtures.load("conta-normal-visible"), derived: Self.normal)
        #expect(visible.verdict == .soleOwner)
        #expect(Self.normal.base58 == "TU6UKxqHCG743kdKURsXK37ZhvND9SBgTv")
    }

    @Test("Conta real com o dono trocado: comprometida, com a chave do atacante nomeada")
    func changedAccount() throws {
        let control = try TronPermissions.check(getAccountJSON: TronFixtures.load("conta-permissao-trocada"), derived: Self.changed)
        #expect(control.isCompromised)
        #expect(control.verdict == .compromised([
            .ownerForeignKeys([Self.attacker]),
            .ownerThresholdUnreachable(threshold: 1, weight: 0),
            .activeForeignKeys(permissionID: 2, keys: [Self.attacker]),
            .activeThresholdUnreachable(permissionID: 2, threshold: 1, weight: 0),
        ]))
        #expect(Self.changed.base58 == "TR8Ab9eQAwF1fPE8Baf5L4z6uf2ngaBxPu")
        #expect(Self.attacker.base58 == "TShbAfd9V7f8go8Y8s4dgqHGGE4epcpY24")
    }

    @Test("JSON de outra conta nao conclui nada")
    func otherAccount() throws {
        #expect(throws: TronPermissions.Failure.addressMismatch) {
            try TronPermissions.check(getAccountJSON: TronFixtures.load("conta-normal"), derived: Self.changed)
        }
    }

    @Test("{} e conta nao ativada; sem permissoes gravadas vale a padrao")
    func emptyAndDefault() throws {
        let empty = try TronPermissions.check(getAccountJSON: Data("{}".utf8), derived: Self.normal)
        #expect(empty.verdict == .notActivated)
        let bare = try TronPermissions.check(getAccountJSON: Self.json(["address": Self.normal.hex]), derived: Self.normal)
        #expect(bare.verdict == .soleOwner)
        #expect(throws: TronPermissions.Failure.malformedJSON) {
            try TronPermissions.check(getAccountJSON: Data("[]".utf8), derived: Self.normal)
        }
        #expect(throws: TronPermissions.Failure.malformedJSON) {
            try TronPermissions.check(getAccountJSON: Self.json(["balance": 1]), derived: Self.normal)
        }
    }

    @Test("Multi-sig: outra chave junto, mesmo com peso menor, e comprometida")
    func multisig() throws {
        // A nossa chave com peso 2 e threshold 2 alcanca sozinha, mas existe outra
        // chave na permissao de dono: a carteira so opera conta de dono unico.
        let shared = try TronPermissions.check(getAccountJSON: Self.json([
            "address": Self.normal.hex,
            "owner_permission": Self.permission(threshold: 2, keys: [(Self.normal, 2), (Self.attacker, 1)]),
        ]), derived: Self.normal)
        #expect(shared.verdict == .compromised([.ownerForeignKeys([Self.attacker])]))

        // 2 de 2: a nossa sozinha nao alcanca.
        let twoOfTwo = try TronPermissions.check(getAccountJSON: Self.json([
            "address": Self.normal.hex,
            "owner_permission": Self.permission(threshold: 2, keys: [(Self.normal, 1), (Self.attacker, 1)]),
        ]), derived: Self.normal)
        #expect(twoOfTwo.verdict == .compromised([
            .ownerForeignKeys([Self.attacker]),
            .ownerThresholdUnreachable(threshold: 2, weight: 1),
        ]))

        // Dono limpo, mas uma permissao ativa extra com a chave do atacante.
        let sneakyActive = try TronPermissions.check(getAccountJSON: Self.json([
            "address": Self.normal.hex,
            "owner_permission": Self.permission(threshold: 1, keys: [(Self.normal, 1)]),
            "active_permission": [
                Self.permission(threshold: 1, keys: [(Self.normal, 1)], id: 2),
                Self.permission(threshold: 1, keys: [(Self.attacker, 1)], id: 3),
            ],
        ]), derived: Self.normal)
        #expect(sneakyActive.verdict == .compromised([
            .activeForeignKeys(permissionID: 3, keys: [Self.attacker]),
            .activeThresholdUnreachable(permissionID: 3, threshold: 1, weight: 0),
        ]))

        // Threshold zero ou ausente nao existe na rede: JSON mal formado.
        #expect(throws: TronPermissions.Failure.malformedPermission("owner_permission")) {
            try TronPermissions.check(getAccountJSON: Self.json([
                "address": Self.normal.hex,
                "owner_permission": ["keys": [["address": Self.normal.hex, "weight": 1]]],
            ]), derived: Self.normal)
        }
    }

    static func permission(threshold: Int, keys: [(TronAddress, Int)], id: Int? = nil) -> [String: Any] {
        var out: [String: Any] = [
            "threshold": threshold,
            "keys": keys.map { ["address": $0.0.hex, "weight": $0.1] },
        ]
        if let id { out["id"] = id }
        return out
    }

    static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}
