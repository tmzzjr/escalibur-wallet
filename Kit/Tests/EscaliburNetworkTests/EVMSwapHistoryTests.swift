import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Trocas no historico EVM: o ETH que volta por transacao interna e a ordem da CoW
/// executada pelo solver. Um spender qualquer nunca vira "troca".
@Suite("Historico EVM: trocas")
struct EVMSwapHistoryTests {
    static let owner = try! EVMAddress("0xF977814e90dA44bFA03b6295A0616a897441aceC")
    static let usdc = try! EVMAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")
    static let weth = try! EVMAddress("0x4200000000000000000000000000000000000006")
    static let router = try! EVMAddress("0x6fF5693b99212Da76ad316178A184AB56D299b43")
    static let drainer = try! EVMAddress("0x2652742DE21ED9a6c37e73b0E3a51b239A6D1008")
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Token por ETH: o ETH chega por interna e a linha vira troca")
    func tokenForNative() throws {
        let rows = [EVMReader.TransactionRow(hash: "0xa1", date: Self.now, status: .confirmed, from: Self.owner, to: Self.router, value: 0, fee: 900)]
        let tokens = [EVMReader.TokenRow(hash: "0xa1", index: "3", date: Self.now, from: Self.owner, to: Self.router, contract: Self.usdc, amount: 50_000_000)]
        let internals = [EVMReader.InternalRow(hash: "0xa1", index: "i1", date: Self.now, from: Self.router, to: Self.owner, value: BigUInt(12_000_000_000_000_000))]
        let page = EVMReader.assemble(chain: .base, owner: Self.owner, rows: rows, tokens: tokens, internals: internals)
        let swap = try #require(page.items.first { $0.direction == .swap })
        #expect(swap.asset.symbol == "USDC" && swap.amount == 50_000_000)
        #expect(swap.receivedAsset?.kind == .native && swap.receivedAmount == BigUInt(12_000_000_000_000_000))
        #expect(!page.items.contains { $0.direction == .sent })
    }

    @Test("Interna recebida sem transacao do dono aparece como recebimento; po fica de fora")
    func internalReceive() {
        let internals = [
            EVMReader.InternalRow(hash: "0xb1", index: "i0", date: Self.now, from: Self.router, to: Self.owner, value: BigUInt(5_000_000_000_000_000)),
            EVMReader.InternalRow(hash: "0xb2", index: "i0", date: Self.now, from: Self.router, to: Self.owner, value: 1),
        ]
        let page = EVMReader.assemble(chain: .base, owner: Self.owner, rows: [], tokens: [], internals: internals)
        #expect(page.items.count == 1)
        #expect(page.items.first?.direction == .received && page.items.first?.amount == BigUInt(5_000_000_000_000_000))
    }

    @Test("Ordem da CoW executada pelo solver vira troca")
    func cowSettlement() throws {
        let tokens = [
            EVMReader.TokenRow(hash: "0xc1", index: "1", date: Self.now, from: Self.owner, to: CoWProtocol.settlement, contract: Self.usdc, amount: 100_000_000),
            EVMReader.TokenRow(hash: "0xc1", index: "2", date: Self.now, from: CoWProtocol.settlement, to: Self.owner, contract: Self.weth, amount: BigUInt(25_000_000_000_000_000)),
        ]
        let page = EVMReader.assemble(chain: .base, owner: Self.owner, rows: [], tokens: tokens)
        let swap = try #require(page.items.first { $0.direction == .swap })
        #expect(swap.asset.symbol == "USDC" && swap.receivedAsset?.symbol == "WETH")
        #expect(swap.fee == nil)
    }

    @Test("Spender qualquer que leva o token e devolve migalha nao vira troca: a saida aparece")
    func drainIsNotSwap() {
        let tokens = [
            EVMReader.TokenRow(hash: "0xd1", index: "1", date: Self.now, from: Self.owner, to: Self.drainer, contract: Self.usdc, amount: 900_000_000),
            EVMReader.TokenRow(hash: "0xd1", index: "2", date: Self.now, from: Self.drainer, to: Self.owner, contract: Self.weth, amount: BigUInt(1_000_000_000_000_000)),
        ]
        let page = EVMReader.assemble(chain: .base, owner: Self.owner, rows: [], tokens: tokens)
        #expect(!page.items.contains { $0.direction == .swap })
        #expect(page.items.contains { $0.direction == .sent && $0.amount == 900_000_000 })
    }

    @Test("Blockscout: internas lidas, as que falharam e as sem valor ficam de fora")
    func parseInternals() throws {
        func item(_ hash: String, _ value: String, success: Bool) -> StrictJSON {
            .object([
                "transaction_hash": .string(hash), "index": .number("1"), "success": .bool(success),
                "timestamp": .string("2026-10-03T00:02:21.000000Z"), "value": .string(value),
                "from": .object(["hash": .string(Self.router.checksummed)]), "to": .object(["hash": .string(Self.owner.checksummed)]),
            ])
        }
        let internals = StrictJSON.object(["items": .array([item("0xe1", "7000000000000000", success: true), item("0xe2", "7000000000000000", success: false), item("0xe3", "0", success: true)])])
        let page = try EVMReader.parseBlockscoutHistory(
            chain: .base, owner: Self.owner, transactions: .object(["items": .array([])]), tokenTransfers: .object(["items": .array([])]),
            internals: internals
        )
        #expect(page.items.map(\.hash) == ["0xe1"])
    }
}
