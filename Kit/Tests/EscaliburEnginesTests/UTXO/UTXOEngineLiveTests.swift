import EscaliburChains
import EscaliburCore
import EscaliburKeys
import EscaliburNetwork
import Foundation
import Testing
@testable import EscaliburEngines

/// O motor UTXO contra os provedores reais, so com ESCALIBUR_REDE=1. Nada e assinado nem
/// transmitido: os planos usam chaves publicas de terceiros.
@Suite("Motor UTXO ao vivo", .enabled(if: EngineFixture.live), .serialized)
struct UTXOEngineLiveTests {
    @Test("Bitcoin: varredura real da xpub publica do BIP-84, e plano completo de um endereco real com saldo")
    func bitcoinEndToEnd() async throws {
        let engine = try #require(UTXOSendEngine(chain: .bitcoin))
        let destination = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        // A conta "abandon" e publica e varrida por robos: a varredura acha o historico e
        // o maximo sai zero, com a nota do motivo, sem erro.
        let request = SendRequest(
            walletID: UUID(), chain: .bitcoin, asset: .native(.bitcoin), account: TestAccounts.bitcoin, destination: destination,
            tag: nil, amount: 0, sendAll: true, feeLevel: .normal, utxoUsage: nil
        )
        let empty = try await engine.spendable(request)
        #expect(empty.amount.isZero || empty.feeNote != nil)

        // Um endereco P2WPKH real com saldo, achado no ultimo bloco (a witness traz a chave),
        // posto como varredura da conta: o resto do caminho e o do app.
        let account = try UTXOEngineSupport.account(TestAccounts.bitcoin, chain: .bitcoin)
        let funded = try await Self.fundedAddress(reader: engine.reader)
        let discovery = UTXODiscovery(account: account, gapLimit: 20, used: [funded], scanned: [funded], nextReceive: funded, nextChange: funded)
        let plan = try await engine.plan(request, account: account, discovery: discovery)
        #expect(plan.review.recipient == destination)
        #expect(plan.review.recipientTag == nil)
        let summary = try #require(UTXOEngineSupport.summary(plan))
        #expect(summary.sendsAll && !summary.amount.isZero)
    }

    /// Entradas P2WPKH do ultimo bloco cujo endereco ainda tem moeda confirmada que paga
    /// a propria taxa.
    static func fundedAddress(reader: UTXOReader) async throws -> UTXODerivedAddress {
        let client = HTTPClient.shared
        let esplora = "https://mempool.space/api"
        let hash = String(decoding: try await client.get(URL(string: "\(esplora)/blocks/tip/hash")!, timeout: 30), as: UTF8.self)
        let data = try await client.get(URL(string: "\(esplora)/block/\(hash)/txs/0")!, timeout: 30)
        let txs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var candidates: [(String, String)] = []
        for tx in txs {
            for input in tx["vin"] as? [[String: Any]] ?? [] {
                guard let prevout = input["prevout"] as? [String: Any], prevout["scriptpubkey_type"] as? String == "v0_p2wpkh",
                      let address = prevout["scriptpubkey_address"] as? String,
                      let witness = input["witness"] as? [String], witness.count == 2, witness[1].count == 66
                else { continue }
                candidates.append((address, witness[1]))
            }
        }
        let h = DerivationPath.hardened
        for (address, keyHex) in candidates.prefix(12) {
            guard let key = Hex.decode(keyHex) else { continue }
            let script = UTXOInputKind.p2wpkh.scriptPubKey(publicKey: key)
            guard UTXOScript.address(for: script, chain: .bitcoin) == address else { continue }
            let derived = UTXODerivedAddress(
                address: address, path: DerivationPath(components: [h(84), h(0), h(0), 0, 0]), publicKey: key,
                scriptPubKey: script, isChange: false, index: 0
            )
            guard let reading = try? await reader.coins(for: [derived]), reading.rejected.isEmpty else { continue }
            if reading.coins.contains(where: { $0.confirmations > 0 && (reading.values[$0.outpoint] ?? 0) > 20_000 }) { return derived }
        }
        throw EngineFixture.Missing(name: "endereco com saldo no ultimo bloco")
    }
}
