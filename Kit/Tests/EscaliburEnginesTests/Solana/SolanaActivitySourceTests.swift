import EscaliburCore
import EscaliburKeys
import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburEngines
@testable import EscaliburNetwork

private typealias F = SolanaEngineFixtures

/// O historico gravado (getTransaction de transacoes reais) na forma da Atividade, e
/// as marcas de suspeita que escondem envenenamento de endereco.
@Suite("Solana: historico")
struct SolanaActivitySourceTests {
    static let recipient = F.key("5x3G4wvfePnbgT2jBcuVpz48C8yMbjjwbKHeQYKzsN4N")

    func history(_ activities: [SolanaActivity], owner: SolanaPublicKey) async throws -> [ActivityEntry] {
        let network = try RecordedSolanaNetwork(balance: BigUInt())
        await network.setActivities(activities)
        return try await SolanaActivitySource(network: network).history(chain: .solana, account: F.account(owner), usage: nil)
    }

    /// Um recebimento sintetico, para as regras que a rede nao ofereceu na gravacao.
    static func incoming(from counterparty: String?, lamports: UInt64, id: String) -> SolanaActivity {
        SolanaActivity(
            id: id, direction: .incoming, asset: .listed(.native(.solana)), amount: BigUInt(lamports), counterparty: counterparty,
            date: Date(timeIntervalSince1970: 1_790_391_400), slot: 1, status: .finalized, fee: BigUInt(), changes: [], suspicions: []
        )
    }

    /// O mesmo comeco e o mesmo fim, o meio trocado: o endereco que o golpista gera.
    static func lookalike(of address: String) -> String {
        String(address.prefix(6)) + String(repeating: "Z", count: address.count - 12) + String(address.suffix(6))
    }

    @Test("Envio e recebimento de SOL e de USDC: direcao, ativo da lista, valor, contraparte e taxa so de quem pagou")
    func transfers() async throws {
        let sent = try await history(
            [try F.activity("tx-sol-transfer", owner: F.exchange), try F.activity("tx-usdc-transfer", owner: F.exchange)], owner: F.exchange
        )
        #expect(sent.count == 2)
        #expect(sent[0].direction == .sent && sent[0].asset == F.sol && sent[0].amount == BigUInt(2_307_000_000))
        #expect(sent[0].counterparty == Self.recipient.base58 && sent[0].fee == BigUInt(7_000) && sent[0].status == .confirmed)
        #expect(sent[0].hash == sent[0].id && sent[0].id.hasPrefix("AePrTTwYp8nG") && sent[0].chainID == "solana")
        #expect(sent[0].date == Date(timeIntervalSince1970: 1_790_391_347))
        #expect(sent[1].direction == .sent && sent[1].asset == F.usdc && sent[1].amount == BigUInt(203_700_000))
        #expect(sent.allSatisfy { !$0.suspicious })

        let received = try await history([try F.activity("tx-sol-transfer", owner: Self.recipient)], owner: Self.recipient)
        #expect(received[0].direction == .received && received[0].counterparty == F.exchange.base58)
        #expect(received[0].fee == nil && !received[0].suspicious)
    }

    @Test("Troca pela Jupiter e transacao que falhou")
    func swapAndFailure() async throws {
        let trader = F.key("HMrGX1kUVxedoJyDtv1LTwzUL9NRpDqETHxP3Ki5i9U3")
        let swap = try await history([try F.activity("tx-jupiter-swap", owner: trader)], owner: trader)[0]
        #expect(swap.direction == .swap && swap.asset == F.sol && swap.amount == BigUInt(43_008_894) && swap.counterparty == nil)
        #expect(!swap.suspicious)

        let payer = F.key("HckQ93Xqjjo8mwt5pNPWvyCTZXQZ858rvzmm7ZRrZg9t")
        let failed = try await history([try F.activity("tx-failed", owner: payer)], owner: payer)[0]
        // O erro do no nao vai para a tela; sem movimento de ativo, sem ativo a mostrar.
        #expect(failed.status == .failed(nil) && failed.direction == .other && failed.asset == nil)
        #expect(failed.fee == BigUInt(9_000) && !failed.suspicious)
    }

    @Test("Token fora da lista e poeira de desconhecido: suspeitos; o token sem nome vindo da rede")
    func recordedSuspicious() async throws {
        let unlisted = try await history([try F.activity("tx-unlisted-token", owner: F.toly)], owner: F.toly)[0]
        #expect(unlisted.suspicious && unlisted.direction == .received && unlisted.asset == nil)
        let victim = F.key("BT8HFgD5kwsqBDhnAy87iUjUiNYcWoeUDZj6b2MAoof4")
        let dust = try await history([try F.activity("tx-dust", owner: victim)], owner: victim)[0]
        #expect(dust.suspicious && dust.amount == BigUInt(1))
    }

    @Test("Recebimento de endereco parecido com quem o dono pagou, ou com o proprio: suspeito, mesmo sem ser poeira")
    func lookalikes() async throws {
        let paid = try F.activity("tx-sol-transfer", owner: F.exchange)
        let fake = Self.lookalike(of: Self.recipient.base58)
        let ownFake = Self.lookalike(of: F.exchange.base58)
        let entries = try await history([
            paid,
            Self.incoming(from: fake, lamports: 500_000_000, id: "parecido"),
            Self.incoming(from: ownFake, lamports: 500_000_000, id: "parecido-com-o-dono"),
            Self.incoming(from: Self.recipient.base58, lamports: 500_000_000, id: "o-mesmo"),
        ], owner: F.exchange)
        #expect(AddressPoisoning.lookalike(fake, among: [Self.recipient.base58], chain: .solana) != nil)
        #expect(entries.first { $0.id == "parecido" }?.suspicious == true)
        #expect(entries.first { $0.id == "parecido-com-o-dono" }?.suspicious == true)
        #expect(entries.first { $0.id == "o-mesmo" }?.suspicious == false)
        #expect(entries.first { $0.id == paid.id }?.suspicious == false)
    }

    @Test("Envio assinado pelo dono nunca e escondido, nem para endereco parecido")
    func ownSendNeverHidden() async throws {
        let paid = try F.activity("tx-sol-transfer", owner: F.exchange)
        let toFake = SolanaActivity(
            id: "enviou-para-parecido", direction: .outgoing, asset: .listed(.native(.solana)), amount: BigUInt(1_000_000_000),
            counterparty: Self.lookalike(of: Self.recipient.base58), date: nil, slot: 2, status: .finalized, fee: BigUInt(5_000), changes: [],
            suspicions: []
        )
        let entries = try await history([paid, toFake], owner: F.exchange)
        #expect(entries.allSatisfy { !$0.suspicious })
    }

    @Test("Transferencia de valor zero: suspeita")
    func zeroValue() async throws {
        let entries = try await history([Self.incoming(from: Self.recipient.base58, lamports: 0, id: "zero")], owner: F.exchange)
        #expect(entries[0].suspicious)
    }

    @Test("Rede errada e conta que nao confere: recusa traduzida")
    func refusals() async throws {
        let source = SolanaActivitySource(network: try RecordedSolanaNetwork(balance: BigUInt()))
        await #expect(throws: SendEngineError.message(SolanaEngineMessages.text(SolanaEngineProblem.wrongChain))) {
            try await source.history(chain: .ethereum, account: F.account(F.toly), usage: nil)
        }
        let broken = DerivedAccount(chainID: "solana", path: DefaultPaths.path(for: .solana), address: F.exchange.base58, publicKey: F.toly.bytes, accountXPub: nil)
        await #expect(throws: SendEngineError.message(SolanaEngineMessages.text(SolanaEngineProblem.accountMismatch))) {
            try await source.history(chain: .solana, account: broken, usage: nil)
        }
    }
}
