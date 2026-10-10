import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburNetwork

/// Recebimento do historico conferido em dois RPCs (auditoria 3, M2).
@Suite("Recebimento conferido na rede")
struct IncomingVerificationTests {
    static let owner = try! EVMAddress("0xF977814e90dA44bFA03b6295A0616a897441aceC")
    static let usdt = try! EVMAddress("0xdAC17F958D2ee523a2206206994597C13D831ec7")
    static let other = try! EVMAddress("0x2652742DE21ED9a6c37e73b0E3a51b239A6D1008")
    static let hash = "0x" + String(repeating: "ab", count: 32)

    static func receipt(status: String = "0x1", contract: EVMAddress = usdt, to: EVMAddress = owner, amount: UInt64 = 5_000_000_000) -> Data {
        let topicTo = "0x" + String(repeating: "0", count: 24) + Hex.encode(to.bytes)
        let data = "0x" + String(repeating: "0", count: 64 - String(amount, radix: 16).count) + String(amount, radix: 16)
        let json = """
        {"jsonrpc":"2.0","id":1,"result":{"status":"\(status)","blockNumber":"0x10","blockHash":"0x\(String(repeating: "cd", count: 32))",
        "logs":[{"address":"\(contract.checksummed)","topics":["\(EVMReader.transferTopic)","0x000000000000000000000000\(Hex.encode(other.bytes))","\(topicTo)"],"data":"\(data)"}]}}
        """
        return Data(json.utf8)
    }

    static func transport(_ receipts: [String: Data]) throws -> FixtureTransport {
        let chainID = try ReaderFixtures.data("evm", "eth_chainId-ethereum")
        let head = Data(#"{"jsonrpc":"2.0","id":1,"result":"0x20"}"#.utf8)
        return FixtureTransport([{ request, body in
            guard let method = FixtureTransport.method(body) else { return nil }
            switch method {
            case "eth_chainId": return chainID
            case "eth_blockNumber": return head
            case "eth_getTransactionReceipt": return receipts[request.url.host ?? ""]
            default: return nil
            }
        }])
    }

    func check(_ receipts: [String: Data], amount: BigUInt = 5_000_000_000) async throws -> EVMReader.IncomingCheck {
        let reader = EVMReaderTests.reader(try Self.transport(receipts))
        return try await reader.verifyIncoming(chain: .ethereum, hash: Self.hash, owner: Self.owner, contract: Self.usdt, amount: amount)
    }

    @Test("Os dois RPCs mostram o Transfer para a conta com o valor: conferido, com confirmacoes")
    func confirmed() async throws {
        let result = try await check(["a.test": Self.receipt(), "b.test": Self.receipt()])
        #expect(result == .confirmed(confirmations: 17))
    }

    @Test("Valor, contrato ou destino diferente, ou transacao que falhou: nao confere")
    func mismatch() async throws {
        #expect(try await check(["a.test": Self.receipt(), "b.test": Self.receipt()], amount: 1) == .mismatch)
        #expect(try await check(["a.test": Self.receipt(contract: Self.other), "b.test": Self.receipt(contract: Self.other)]) == .mismatch)
        #expect(try await check(["a.test": Self.receipt(to: Self.other), "b.test": Self.receipt(to: Self.other)]) == .mismatch)
        #expect(try await check(["a.test": Self.receipt(status: "0x0"), "b.test": Self.receipt(status: "0x0")]) == .mismatch)
    }

    @Test("Sem recibo: ainda nao chegou na rede")
    func notFound() async throws {
        let none = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)
        #expect(try await check(["a.test": none, "b.test": none]) == .notFound)
    }

    @Test("Um RPC diz que chegou e o outro nao: nao confere, erro")
    func disagree() async throws {
        let none = Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8)
        await #expect(throws: ReaderError.self) { _ = try await check(["a.test": Self.receipt(), "b.test": none]) }
    }
}
