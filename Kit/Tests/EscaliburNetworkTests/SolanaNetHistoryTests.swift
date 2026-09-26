import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Historico a partir de `getTransaction` (jsonParsed) de transacoes reais da rede
/// principal, gravadas em 26/09/2026, cada uma vista pelos dois lados quando da:
///
/// - tx-sol-transfer: saque de SOL de uma exchange (5tzF...) para 5x3G...
/// - tx-usdc-transfer: saque de USDC da mesma exchange para 8Wq1...
/// - tx-jupiter-swap: troca SOL -> USDC pela Jupiter, de HMrG...
/// - tx-unlisted-token: token fora da lista despejado em toly.sol (e outros)
/// - tx-dust: envenenamento de endereco, 1 lamport para 19 contas, uma delas BT8H...
/// - tx-failed: transacao que falhou (InsufficientFundsForRent), paga por HckQ...
@Suite("Solana rede: historico")
struct SolanaNetHistoryTests {
    static let exchange = try! SolanaPublicKey(base58: "5tzFkiKscXHK5ZXCGbXZxdw7gTjjD1mBwuoFbhUvuAi9")

    func activity(_ name: String, _ owner: String, known: Set<String> = [], status: String? = "finalized") throws -> SolanaActivity? {
        try SolanaActivityParser.activity(
            transactionResponse: try SolanaNetFixtures.data(name), owner: try SolanaPublicKey(base58: owner),
            confirmationStatus: status, knownAddresses: known
        )
    }

    @Test("Envio de SOL: saida para quem enviou, entrada para quem recebeu, taxa so para o pagador")
    func solTransfer() throws {
        let sent = try #require(try activity("tx-sol-transfer", Self.exchange.base58))
        #expect(sent.direction == .outgoing)
        #expect(sent.asset.isNative && sent.amount == BigUInt(2_307_000_000))
        #expect(sent.counterparty == "5x3G4wvfePnbgT2jBcuVpz48C8yMbjjwbKHeQYKzsN4N")
        #expect(sent.fee == BigUInt(7_000))
        #expect(sent.status == .finalized && !sent.isSuspicious)
        #expect(sent.date == Date(timeIntervalSince1970: 1_790_391_347))
        #expect(sent.id.hasPrefix("AePrTTwYp8nG"))

        let received = try #require(try activity("tx-sol-transfer", "5x3G4wvfePnbgT2jBcuVpz48C8yMbjjwbKHeQYKzsN4N", status: "confirmed"))
        #expect(received.direction == .incoming && received.amount == BigUInt(2_307_000_000))
        #expect(received.counterparty == Self.exchange.base58)
        #expect(received.fee.isZero && received.status == .confirmed && !received.isSuspicious)
    }

    @Test("Envio de USDC: contraparte e a carteira dona da conta de token, nao a conta")
    func usdcTransfer() throws {
        let sent = try #require(try activity("tx-usdc-transfer", Self.exchange.base58))
        #expect(sent.direction == .outgoing)
        #expect(sent.asset.mint == "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v" && sent.amount == BigUInt(203_700_000))
        #expect(sent.counterparty == "8Wq1zfHPXNKwNnin2oHmyvwvE7qpRzhbeVr5n7N58Wmj")
        #expect(sent.fee == BigUInt(15_000))
        // A taxa nao aparece como movimento de SOL.
        #expect(sent.changes.count == 1)

        let received = try #require(try activity("tx-usdc-transfer", "8Wq1zfHPXNKwNnin2oHmyvwvE7qpRzhbeVr5n7N58Wmj"))
        #expect(received.direction == .incoming && received.amount == BigUInt(203_700_000))
        guard case .listed(let asset) = received.asset else { Issue.record("USDC e da lista"); return }
        #expect(asset.symbol == "USDC")
        #expect(received.counterparty == Self.exchange.base58 && !received.isSuspicious)
    }

    @Test("Troca pela Jupiter: sai SOL (sem a taxa, com o SOL embrulhado liquido), entra USDC")
    func swap() throws {
        let swap = try #require(try activity("tx-jupiter-swap", "HMrGX1kUVxedoJyDtv1LTwzUL9NRpDqETHxP3Ki5i9U3"))
        #expect(swap.direction == .swap)
        #expect(swap.asset.isNative && swap.amount == BigUInt(43_008_894))
        #expect(swap.fee == BigUInt(1_147_548))
        #expect(swap.counterparty == nil)
        let incoming = try #require(swap.changes.first { $0.isIncoming })
        #expect(incoming.asset.mint == "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v" && incoming.amount == BigUInt(5_227_523))
        #expect(!swap.isSuspicious)
    }

    @Test("Token fora da lista despejado na conta: suspeito, sem nome vindo da rede")
    func unlistedToken() throws {
        let spam = try #require(try activity("tx-unlisted-token", "86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY"))
        #expect(spam.direction == .incoming)
        #expect(spam.asset == .unlisted(mint: "CSRvuL45tXnqYKqk9RXBksuaFQzsamp3ACT5pgEQTVzn", decimals: 6))
        #expect(spam.amount == BigUInt(970_000_000))
        #expect(spam.suspicions.contains(.unknownToken(mint: "CSRvuL45tXnqYKqk9RXBksuaFQzsamp3ACT5pgEQTVzn")))
        #expect(spam.fee.isZero)
    }

    @Test("Poeira de desconhecido (envenenamento de endereco): suspeita; de contato conhecido, nao")
    func dust() throws {
        let owner = "BT8HFgD5kwsqBDhnAy87iUjUiNYcWoeUDZj6b2MAoof4"
        let poison = try #require(try activity("tx-dust", owner))
        #expect(poison.direction == .incoming && poison.amount == BigUInt(1))
        #expect(poison.counterparty == "G6Y7qJ9Gx1xGPT9Db5xvs244MKwxjpEQsbARj1gx8k8K")
        #expect(poison.suspicions == [.dustFromUnknown])
        let known = try #require(try activity("tx-dust", owner, known: ["G6Y7qJ9Gx1xGPT9Db5xvs244MKwxjpEQsbARj1gx8k8K"]))
        #expect(!known.isSuspicious)
    }

    @Test("Transacao que falhou: status com o erro, so a taxa; para quem so aparece nela, fora do historico")
    func failed() throws {
        let failed = try #require(try activity("tx-failed", "HckQ93Xqjjo8mwt5pNPWvyCTZXQZ858rvzmm7ZRrZg9t"))
        #expect(failed.status == .failed(#"{"InsufficientFundsForRent":{"account_index":9}}"#))
        #expect(failed.direction == .other && failed.changes.isEmpty && failed.fee == BigUInt(9_000))
        #expect(try activity("tx-failed", "86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY") == nil)
    }

    @Test("Duas passadas: quem recebeu envio do dono deixa de ser desconhecido")
    func secondPass() throws {
        // O dono (a exchange) enviou para 5x3G...; uma poeira de 5x3G... para ela nao e suspeita.
        let sent = try SolanaRPC.decode(try SolanaNetFixtures.data("tx-sol-transfer"), method: "t", as: RPCTransaction.self)
        let info = RPCSignatureInfo(signature: "x", slot: 1, err: nil, blockTime: nil, confirmationStatus: "finalized")
        let result = SolanaHistoryReader.activities([(info, sent)], owner: Self.exchange, knownAddresses: [])
        #expect(result.count == 1 && result[0].counterparty == "5x3G4wvfePnbgT2jBcuVpz48C8yMbjjwbKHeQYKzsN4N")
    }

    @Test("Soma com sinal sobre BigUInt")
    func signedAmount() {
        let five = SignedAmount(UInt64(5))
        let three = SignedAmount(UInt64(3))
        #expect((three - five).negative && (three - five).magnitude == BigUInt(2))
        #expect(!(five - three).negative && (five - three).magnitude == BigUInt(2))
        #expect((five - five).isZero && !(five - five).negative)
        #expect((-five + -three).magnitude == BigUInt(8) && (-five + -three).negative)
    }
}
