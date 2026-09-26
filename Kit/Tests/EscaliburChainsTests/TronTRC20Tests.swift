import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

/// Calldata TRC-20 e o contrato do USDT.
///
/// Vetores: as tres transferencias de USDT da mainnet em Fixtures/tron (197d2038...,
/// 94bd6f1f..., 8f0df00f...), cuja `data` foi montada pela carteira de quem enviou; os
/// seletores sao recalculados com o Keccak do Core.
@Suite("Tron: TRC-20")
struct TronTRC20Tests {

    @Test("Seletores = keccak256 da assinatura da funcao")
    func selectors() {
        #expect(TRC20.transferSelector == Array(Hash.keccak256(Array("transfer(address,uint256)".utf8)).prefix(4)))
        #expect(TRC20.balanceOfSelector == Array(Hash.keccak256(Array("balanceOf(address)".utf8)).prefix(4)))
    }

    @Test("Contrato do USDT: TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t, 6 casas")
    func usdtContract() throws {
        #expect(TRC20.usdt.contract.base58 == "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t")
        #expect(TRC20.usdt.contract == TronAddress(base58: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"))
        #expect(TRC20.usdt.decimals == 6)
        // E o mesmo contrato das transferencias reais.
        for tx in try TronFixtures.transactions() {
            let raw = try TronRawTransaction.decode(Hex.decode(tx.rawDataHex)!)
            if case .triggerSmartContract(_, let contract, _, _) = raw.contract {
                #expect(contract == TRC20.usdt.contract)
            }
        }
    }

    @Test("transfer(address,uint256): a calldata montada e igual a das transferencias da mainnet")
    func transferCalldataMatchesMainnet() throws {
        var clean = 0
        var dirty = 0
        for tx in try TronFixtures.transactions() {
            let raw = try TronRawTransaction.decode(Hex.decode(tx.rawDataHex)!)
            guard case .triggerSmartContract(_, _, let callValue, let data) = raw.contract else { continue }
            #expect(callValue.isZero)
            if let decoded = TRC20.decodeTransfer(data) {
                #expect(try TRC20.transferCalldata(to: decoded.to, amount: decoded.amount) == data)
                clean += 1
            } else {
                // 94bd6f1f...: a carteira de origem pos o 0x41 no byte alto da palavra do
                // endereco (byte 4 + 11 da calldata). O USDT leu os 20 bytes baixos e a
                // tx deu SUCCESS; a decodificacao estrita recusa, e a nossa codificacao
                // do mesmo destino sai com o byte zerado.
                #expect(tx.txID.hasPrefix("94bd6f1f"))
                #expect(data[15] == 0x41)
                var cleaned = data
                cleaned[15] = 0
                let decoded = try #require(TRC20.decodeTransfer(cleaned))
                #expect(try TRC20.transferCalldata(to: decoded.to, amount: decoded.amount) == cleaned)
                dirty += 1
            }
        }
        #expect(clean == 2)
        #expect(dirty == 1)

        // 8f0df00f...: 1.032.980.000 unidades (1.032,98 USDT) para 41d31229da2fb8542cdde300ecbda15ea81857645c.
        let to = try #require(TronAddress("41d31229da2fb8542cdde300ecbda15ea81857645c"))
        let data = try TRC20.transferCalldata(to: to, amount: 1_032_980_000)
        #expect(Hex.encode(data) == "a9059cbb000000000000000000000000d31229da2fb8542cdde300ecbda15ea81857645c000000000000000000000000000000000000000000000000000000003d920620")
    }

    @Test("A palavra do endereco vai sem o 0x41")
    func addressWordHasNoPrefix() throws {
        let owner = try #require(TronAddress(base58: "TU6UKxqHCG743kdKURsXK37ZhvND9SBgTv"))
        let word = TRC20.addressWord(owner)
        #expect(word.count == 32)
        #expect(word.prefix(12).allSatisfy { $0 == 0 })
        #expect(Array(word.suffix(20)) == owner.account20)
        #expect(Hex.encode(TRC20.balanceOfCalldata(owner: owner)) == "70a08231000000000000000000000000" + Hex.encode(owner.account20))
    }

    @Test("decodeTransfer e estrito")
    func decodeIsStrict() throws {
        let to = try #require(TronAddress(base58: "TU6UKxqHCG743kdKURsXK37ZhvND9SBgTv"))
        let good = try TRC20.transferCalldata(to: to, amount: 5)
        #expect(TRC20.decodeTransfer(good)?.to == to)
        #expect(TRC20.decodeTransfer(good)?.amount == 5)
        // Com o 0x41 dentro da palavra: bytes altos sujos.
        var dirty = good
        dirty[15] = 0x41
        #expect(TRC20.decodeTransfer(dirty) == nil)
        #expect(TRC20.decodeTransfer(Array(good.dropLast())) == nil)
        #expect(TRC20.decodeTransfer(good + [0]) == nil)
        #expect(TRC20.decodeTransfer(TRC20.approveLikeSelector + Array(good.dropFirst(4))) == nil)
        // uint256 acima de 2^256 - 1 nao cabe.
        #expect(throws: TRC20.Failure.amountTooLarge) {
            try TRC20.transferCalldata(to: to, amount: BigUInt.uint256Max + 1)
        }
        #expect(TRC20.decodeUint256([UInt8](repeating: 0, count: 31) + [7]) == 7)
        #expect(TRC20.decodeUint256([7]) == nil)
    }
}

extension TRC20 {
    /// `approve(address,uint256)`, so para o teste provar que outro seletor nao passa.
    static var approveLikeSelector: [UInt8] { Array(Hash.keccak256(Array("approve(address,uint256)".utf8)).prefix(4)) }
}
