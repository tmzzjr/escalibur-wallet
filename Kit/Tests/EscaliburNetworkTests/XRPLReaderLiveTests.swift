import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra os servidores reais do XRP Ledger, so com ESCALIBUR_REDE=1.
///
/// A conta do dono e rEb8TK3gBgk5auZkwc6sHnwrGVJH8DuaLh, que assina com a chave mestra
/// secp256k1 02F52B01... (lida do `SigningPubKey` da transacao
/// 692B5317FE8FB841C8F3F1EBA99E9F525191055F4F107F01876F8C62ECE83D0E, em 25/09/2026); o
/// teste confere que a chave da o endereco. Nada e assinado nem transmitido.
@Suite("Leitor XRP Ledger ao vivo", .enabled(if: Live.enabled), .serialized)
struct XRPLReaderLiveTests {
    static let ownerKey = [UInt8](hex: "02F52B0157F76581EE932D6EDF8DBC1AD876042C8633D16FC81D17838E67BFD4B1")!
    static let ownerPath = DerivationPath("m/44'/144'/0'/0/0")!
    /// Conta existente, sem flags (Flags 0).
    static let plainDestination = "rJb5KsHsDHF1YS5B5DU6QCkH5NsPaKQTcy"
    /// Conta de exchange com lsfRequireDestTag e lsfDisallowXRP.
    static let taggedDestination = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"

    let reader = XRPLReader()

    func signer() throws -> XRPLSigner {
        let signer = try XRPLSigner(path: Self.ownerPath, publicKey: Self.ownerKey)
        #expect(signer.address == "rEb8TK3gBgk5auZkwc6sHnwrGVJH8DuaLh")
        return signer
    }

    @Test("Estado real ate o SigningPlan: destino comum")
    func planToPlainDestination() async throws {
        let signer = try signer()
        let ledger = try await reader.ledgerState()
        #expect(ledger.validatedLedgerIndex > 100_000_000)
        #expect(!ledger.reserveBase.isZero)
        #expect(ledger.openLedgerFee >= 10)
        let account = try await reader.accountState(address: signer.address)
        #expect(account.sequenceReadings.count == 2)
        #expect(Set(account.sequenceReadings).count == 1)
        let destination = try await reader.destinationState(address: Self.plainDestination, source: signer.address)
        #expect(destination.readings.count == 2)
        let plan = try XRPLPlanner.planSend(
            XRPLSendIntent(destination: Self.plainDestination, drops: 1_000), signer: signer, account: account, ledger: ledger,
            destination: destination, walletID: UUID()
        )
        #expect(plan.transactions.count == 1)
        Live.note("xrpl: ledger \(ledger.validatedLedgerIndex), reserva \(ledger.reserveBase)/\(ledger.reserveIncrement), fee \(ledger.openLedgerFee), seq \(account.sequenceReadings)")
    }

    @Test("Destino com tag obrigatoria e DisallowXRP: flags lidas e o plano exige tag e confirmacao")
    func taggedDestination() async throws {
        let signer = try signer()
        let ledger = try await reader.ledgerState()
        let account = try await reader.accountState(address: signer.address)
        let destination = try await reader.destinationState(address: Self.taggedDestination, source: signer.address)
        guard case .found(let flags) = destination.readings[0] else { Issue.record("destino nao achado"); return }
        #expect(flags & XRPLAccountFlags.requireDestTag != 0)
        #expect(throws: XRPLPlanError.destinationTagRequired) {
            _ = try XRPLPlanner.planSend(
                XRPLSendIntent(destination: Self.taggedDestination, drops: 1_000), signer: signer, account: account, ledger: ledger,
                destination: destination, walletID: UUID()
            )
        }
        let plan = try XRPLPlanner.planSend(
            XRPLSendIntent(destination: Self.taggedDestination, destinationTag: 1, drops: 1_000, acknowledgesDisallowXRP: true),
            signer: signer, account: account, ledger: ledger, destination: destination, walletID: UUID()
        )
        #expect(plan.transactions.count == 1)
    }

    @Test("Destino que nao existe: duas leituras notFound e a reserva de ativacao")
    func unfundedDestination() async throws {
        let signer = try signer()
        // Endereco valido de uma chave qualquer (0x02 seguido de 32 bytes 0x11), nunca ativado.
        let unfunded = try Address.from(publicKey: [0x02] + [UInt8](repeating: 0x11, count: 32), chain: .xrpl)
        let destination = try await reader.destinationState(address: unfunded, source: signer.address)
        #expect(destination.readings == [.notFound, .notFound])
        let ledger = try await reader.ledgerState()
        let account = try await reader.accountState(address: signer.address)
        #expect(throws: XRPLPlanError.belowActivationReserve(minimum: ledger.reserveBase)) {
            _ = try XRPLPlanner.planSend(
                XRPLSendIntent(destination: unfunded, drops: 1_000), signer: signer, account: account, ledger: ledger,
                destination: destination, walletID: UUID()
            )
        }
    }

    @Test("Transacao conhecida validada em dois servidores")
    func knownTransaction() async throws {
        let status = try await reader.status(of: "AA422A0AF62C58042BE3A243954CC1BD2560E2345F475E577F8E21F4D455BEA5")
        #expect(status == .confirmed(block: 106_836_736, confirmations: nil))
    }

    @Test("Historico com delivered_amount e o po de golpe escondido")
    func history() async throws {
        let page = try await reader.history(address: Self.taggedDestination)
        #expect(page.items.count <= ActivityRules.pageSize)
        Live.note("xrpl: \(page.items.count) itens, \(page.suspiciousCount) suspeitos (\(page.suspicious))")
    }
}
