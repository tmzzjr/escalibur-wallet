import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// O motor TON contra a rede de verdade (toncenter e tonapi), so com ESCALIBUR_REDE=1.
/// So leitura: os planos sao montados e conferidos, nunca assinados nem transmitidos.
///
/// O dono e a carteira V4R2 0:12d12a69...eca2, com TON e USDT; a chave publica veio de
/// `get_public_key` do proprio contrato (ver EscaliburNetworkTests/TONReaderLiveTests).
/// O destino e a carteira V4R2 das respostas gravadas, na grafia sem bounce.
@Suite("Motor TON ao vivo", .enabled(if: TONRecorded.liveNetwork), .serialized)
struct TONEngineLiveTests {
    typealias R = TONRecorded

    static let ownerKey = Hex.decode("b2ce21c85fde8cc2474ddfc1ba399186983dc8f7f636924a57cb54e7f0a35417") ?? []
    static let destination = R.wallet.address.friendly(bounceable: false)

    let engine = TONSendEngine()

    func request(asset: Asset, amount: BigUInt, comment: String? = nil, sendAll: Bool = false) throws -> SendRequest {
        let wallet = try TONWallet(publicKey: Self.ownerKey, version: .v4r2)
        #expect(wallet.address.raw == "0:12d12a693dbeff8e278fb409f2a1fc5896403f878f442a646e3613b85c13eca2")
        let account = R.account(address: wallet.address.friendly(bounceable: false), key: Self.ownerKey)
        return SendRequest(
            walletID: UUID(), chain: .ton, asset: asset, account: account, destination: Self.destination, tag: comment,
            amount: amount, sendAll: sendAll, feeLevel: .normal, utxoUsage: nil
        )
    }

    @Test("Destino ativo lido da rede")
    func destination() async throws {
        let info = try await engine.destination(Self.destination, chain: .ton)
        #expect(info.exists && !info.isContract)
    }

    @Test("TON: maximo e plano completo, com o destino e o comentario pedidos")
    func tonPlan() async throws {
        let spendable = try await engine.spendable(try request(asset: R.ton, amount: 1_000_000, sendAll: true))
        #expect(!spendable.amount.isZero)
        let plan = try await engine.plan(try request(asset: R.ton, amount: 1_000_000, comment: "escalibur"))
        #expect(Address.sameRecipient(plan.review.recipient, Self.destination, chain: .ton))
        #expect(plan.review.recipientTag == "escalibur")
        let transfer = try #require(plan.transactions.first as? TONTransfer)
        #expect(transfer.messages.first?.destination == R.wallet.address)
        #expect(transfer.messages.first?.bounce == false)
    }

    @Test("USDT: maximo e plano completo, pela carteira jetton do dono")
    func usdtPlan() async throws {
        let spendable = try await engine.spendable(try request(asset: R.usdt, amount: 0, sendAll: true))
        #expect(!spendable.amount.isZero)
        let plan = try await engine.plan(try request(asset: R.usdt, amount: 1_000_000, comment: "escalibur"))
        #expect(Address.sameRecipient(plan.review.recipient, Self.destination, chain: .ton))
        #expect(plan.review.recipientTag == "escalibur")
        let transfer = try #require(plan.transactions.first as? TONTransfer)
        let owner = try TONWallet(publicKey: Self.ownerKey, version: .v4r2)
        #expect(transfer.messages.first?.destination == (try TONJetton.usdtWallet(owner: owner.address)))
    }

    @Test("Atividade lida da tonapi")
    func activity() async throws {
        let account = R.account(address: R.poisoned.friendly(bounceable: false))
        let entries = try await TONActivitySource().history(chain: .ton, account: account, usage: nil)
        #expect(entries.count <= 30)
    }
}
