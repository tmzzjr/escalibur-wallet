import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Contra a toncenter e a tonapi, so com ESCALIBUR_REDE=1.
///
/// O dono e a carteira V4R2 0:12d12a69...eca2, com TON e USDT e sem movimento ha
/// semanas (o seqno fica parado entre as leituras das duas APIs). A chave publica veio
/// de `get_public_key` do proprio contrato (tonapi `/accounts/{a}/publickey`), em
/// 25/09/2026, e o teste confere que a V4R2 dessa chave da o endereco. Nada e assinado
/// nem transmitido.
@Suite("Leitor TON ao vivo", .enabled(if: Live.enabled), .serialized)
struct TONReaderLiveTests {
    static let ownerKey = [UInt8](hex: "b2ce21c85fde8cc2474ddfc1ba399186983dc8f7f636924a57cb54e7f0a35417")!
    /// A carteira das respostas gravadas (Fixtures/leitores/ton): V4R2 0:152696db...b43e,
    /// chave de `get_public_key` do proprio contrato.
    static let recordedOwnerKey = [UInt8](hex: "38b6bd15c9dc2c929269db0c8967e15cf2da2b96a937e4a7cc2938e1a1f30b2e")!
    static let path = DerivationPath("m/44'/607'/0'")!
    /// Outra carteira V4R2 ativa.
    static let destination = "0:152696db9ef6b82ec54b2c84b0b9c617baf4c34c74de186cbd2b4505c6abb43e"

    let reader = TONReader()

    func wallet() throws -> TONWallet {
        let wallet = try TONWallet(publicKey: Self.ownerKey, version: .v4r2)
        #expect(wallet.address.raw == "0:12d12a693dbeff8e278fb409f2a1fc5896403f878f442a646e3613b85c13eca2")
        return wallet
    }

    func friendlyDestination() throws -> String {
        guard case .success(let parsed) = TONAddress.parse(Self.destination) else { throw ReaderError.invalidInput("destino") }
        return parsed.address.friendly(bounceable: false)
    }

    @Test("TON: estado real ate o SigningPlan")
    func tonPlan() async throws {
        let wallet = try wallet()
        let to = try friendlyDestination()
        let amount = BigUInt(1_000_000)
        let state = try await reader.chainState(wallet: wallet, intent: .ton(to: to, amount: amount, comment: "teste"))
        #expect(state.accountStatus == .active)
        #expect(state.codeHash == TONWalletVersion.v4r2.codeHash)
        #expect(state.seqno > 0)
        #expect(state.destinationStatus == .active)
        #expect(!state.estimatedFee.isZero)
        let plan = try TONPlanner.planSendTON(
            walletID: UUID(), wallet: wallet, path: Self.path, to: to, amount: amount, comment: "teste", state: state
        )
        #expect(plan.transactions.count == 1)
        Live.note("ton: seqno \(state.seqno), taxa \(state.estimatedFee), saldo \(state.balance)")
    }

    @Test("USDT: carteira jetton conferida com o calculo local, saldo e plano")
    func usdtPlan() async throws {
        let wallet = try wallet()
        let to = try friendlyDestination()
        let jetton = try await reader.jettonState(owner: wallet.address)
        #expect(!jetton.balance.isZero)
        let state = try await reader.chainState(wallet: wallet, intent: .usdt(to: to, amount: 1_000_000, comment: nil))
        let plan = try TONPlanner.planSendUSDT(
            walletID: UUID(), wallet: wallet, path: Self.path, to: to, amount: 1_000_000, state: state, jetton: jetton
        )
        #expect(plan.transactions.count == 1)
        Live.note("ton: usdt \(jetton.balance), taxa \(state.estimatedFee)")
    }

    @Test("Mensagem externa conhecida: transacao achada nas duas APIs")
    func knownMessage() async throws {
        let status = try await reader.status(of: "732af3f9e362d8b32896464d6589f770a458a52a56eb45454a5f7cff92da407f")
        #expect(status == .confirmed(block: nil, confirmations: nil))
    }

    @Test("Historico da tonapi, com o po de golpe escondido")
    func history() async throws {
        guard case .success(let parsed) = TONAddress.parse("0:c44015434ad966c8dab4b5180f272d094855e0a7489a2dd05acf6a6c1ee47faa") else {
            Issue.record("endereco"); return
        }
        let page = try await reader.history(address: parsed.address)
        #expect(page.items.count <= ActivityRules.pageSize)
        Live.note("ton: \(page.items.count) itens, \(page.suspiciousCount) suspeitos (\(page.suspicious))")
    }
}
