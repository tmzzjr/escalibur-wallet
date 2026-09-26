import EscaliburChains
import EscaliburCore
import Foundation

/// Leitura das fixtures de Fixtures/tron. As transacoes sao reais, da mainnet, lidas
/// em 25/09/2026 com `POST https://api.trongrid.io/wallet/gettransactionbyid`; os
/// blocos com `/wallet/getblockbynum`; os recibos com `/wallet/gettransactioninfobyid`.
enum TronFixtures {
    struct MainnetTransaction {
        let json: [String: Any]
        let txID: String
        let rawDataHex: String
        let signature: [UInt8]
        let rawData: [String: Any]
        let note: String
    }

    struct Block {
        let number: UInt64
        let id: String
        let timestamp: Int64
    }

    static func load(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/tron") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func mainnet() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: load("transacoes-mainnet")) as! [String: Any]
    }

    static func transactions() throws -> [MainnetTransaction] {
        let list = try mainnet()["transacoes"] as! [[String: Any]]
        return list.map { item in
            MainnetTransaction(
                json: item,
                txID: item["txID"] as! String,
                rawDataHex: item["raw_data_hex"] as! String,
                signature: Hex.decode((item["signature"] as! [String])[0])!,
                rawData: item["raw_data"] as! [String: Any],
                note: item["_nota"] as! String
            )
        }
    }

    static func blocks() throws -> [Block] {
        let list = try mainnet()["blocos"] as! [[String: Any]]
        return list.map {
            Block(
                number: ($0["number"] as! NSNumber).uint64Value,
                id: $0["blockID"] as! String,
                timestamp: ($0["timestamp"] as! NSNumber).int64Value
            )
        }
    }

    /// Recibos por txID: `receipt` e `fee` de gettransactioninfobyid.
    static func receipts() throws -> [String: (receipt: [String: Any], fee: Int64)] {
        let list = try mainnet()["infos"] as! [[String: Any]]
        var out: [String: (receipt: [String: Any], fee: Int64)] = [:]
        for item in list {
            out[item["id"] as! String] = (item["receipt"] as! [String: Any], (item["fee"] as? NSNumber)?.int64Value ?? 0)
        }
        return out
    }

    /// Monta o raw a partir dos campos do JSON (nao do hex), para conferir a
    /// serializacao contra o `raw_data_hex` que a rede devolveu.
    static func rawFromJSON(_ raw: [String: Any]) throws -> TronRawTransaction {
        let contract = (raw["contract"] as! [[String: Any]])[0]
        let parameter = contract["parameter"] as! [String: Any]
        let value = parameter["value"] as! [String: Any]
        let owner = TronAddress(value["owner_address"] as! String)!
        let built: TronContract
        switch contract["type"] as! String {
        case "TransferContract":
            built = .transfer(
                owner: owner,
                to: TronAddress(value["to_address"] as! String)!,
                amount: BigUInt((value["amount"] as! NSNumber).uint64Value)
            )
        case "TriggerSmartContract":
            built = .triggerSmartContract(
                owner: owner,
                contract: TronAddress(value["contract_address"] as! String)!,
                callValue: BigUInt((value["call_value"] as? NSNumber)?.uint64Value ?? 0),
                data: Hex.decode(value["data"] as! String)!
            )
        default:
            fatalError("tipo inesperado na fixture")
        }
        return try TronRawTransaction(
            refBlockBytes: Hex.decode(raw["ref_block_bytes"] as! String)!,
            refBlockHash: Hex.decode(raw["ref_block_hash"] as! String)!,
            expiration: (raw["expiration"] as! NSNumber).int64Value,
            memo: Hex.decode(raw["data"] as? String ?? "")!,
            contract: built,
            timestamp: (raw["timestamp"] as! NSNumber).int64Value,
            feeLimit: BigUInt((raw["fee_limit"] as? NSNumber)?.uint64Value ?? 0)
        )
    }
}
