import EscaliburChains
import EscaliburCore
import Foundation

// A Legacy Mesh da Tether na rede (docs/seguranca.md 4.12, `USDT0Mesh`).
//
// Origem (EVM): tudo o que a cotacao precisa vem do proprio UsdtOFT, por `eth_call`, em duas
// fontes concordando: o token que ele puxa, o par na Tron, a taxa da Tether, a liquidez da Tron
// e o que chega (`quoteOFT`). A taxa de mensagem (`quoteSend`) pode variar de um no para outro
// por arredondamento do preco do gas: fica a maior (a sobra volta ao dono).
//
// Destino (Tron): a entrega e achada pelo `guid` da mensagem na API de eventos da TronGrid (so
// ela indexa) e lida, a transacao inteira, no no solidificado de dois provedores, que tem de
// concordar. A conferencia campo a campo e de `BridgeArrival.meshDelivered`.

extension TradeStateReader {
    /// A resposta inteira de um `eth_call`, igual em duas fontes.
    func agreedCall(chain: Chain, to: EVMAddress, data: [UInt8], what: String) async throws -> [UInt8] {
        let answers = try await collect(readProviders(chain), count: 2, what: what) { provider in
            try await self.rpc(provider, chain: chain, "eth_call",
                               [.object(["to": Self.address(to), "data": Self.data(data)]), .string("latest")], as: String.self).lowercased()
        }
        guard Set(answers.map(\.1)).count == 1, let text = answers.first?.1,
              let bytes = Hex.decode(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text)
        else { throw TradeStateError.sourcesDisagree(what) }
        return bytes
    }

    /// O UsdtOFT de origem para este envio. `minimum`: o minimo do envio, quando ja se sabe (no
    /// plano); na cotacao, o que `quoteOFT` diz que chega.
    public func readMesh(intent: BridgeIntent, minimum: BigUInt? = nil) async throws -> MeshQuote {
        guard let source = intent.from.mesh, let recipient = intent.tronRecipient else { throw BridgeRefusal.unsupportedRoute }
        let chain = intent.from.chain
        async let tokenWord = agreedWord(chain: chain, to: source.oft, data: USDT0Mesh.tokenFunction.selector, what: "token da Tether")
        async let peerWord = agreedWord(chain: chain, to: source.oft,
                                        data: try USDT0Mesh.peersFunction.encodeCall([.uint(BigUInt(USDT0Mesh.tronEID))]), what: "par na Tron")
        async let feeWord = agreedWord(chain: chain, to: source.oft, data: USDT0Mesh.feeBpsFunction.selector, what: "taxa da Tether")
        let oftData = try await agreedCall(chain: chain, to: source.oft,
                                           data: try USDT0Mesh.quoteOFTCall(recipient: recipient, amount: intent.amount), what: "quoteOFT")
        let oft = try USDT0Mesh.parseQuoteOFT(oftData)
        let sendCall = try USDT0Mesh.quoteSendCall(recipient: recipient, amount: intent.amount, minimum: minimum ?? oft.received)
        let fees = try await collect(readProviders(chain), count: 2, what: "quoteSend") { provider in
            let text = try await self.rpc(provider, chain: chain, "eth_call",
                                          [.object(["to": Self.address(source.oft), "data": Self.data(sendCall)]), .string("latest")],
                                          as: String.self)
            guard let bytes = Hex.decode(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text) else { throw TradeStateError.badResponse("quoteSend") }
            return try USDT0Mesh.parseQuoteSend(bytes)
        }.map(\.1)
        let token = try await tokenWord
        guard token.prefix(12).allSatisfy({ $0 == 0 }), let tokenAddress = EVMAddress(bytes: Array(token.suffix(20))) else {
            throw TradeStateError.badResponse("token da Tether")
        }
        return MeshQuote(
            token: tokenAddress, tronPeer: try await peerWord, feeBps: BigUInt(bigEndian: try await feeWord),
            maxAmount: oft.maxAmount, sent: oft.sent, received: oft.received,
            nativeFee: fees.map(\.nativeFee).max() ?? 0, lzTokenFee: fees.map(\.lzTokenFee).max() ?? 0
        )
    }
}

extension TronReader {
    /// A entrega da Legacy Mesh na Tron: a transacao do UsdtOFT da Tron com o OFTReceived desta
    /// mensagem (`guid`), e os logs dela no no solidificado de dois provedores concordando.
    /// `nil`: ainda nao entregue (ou ainda nao solidificada nos dois).
    public func meshDelivery(oft: TronAddress, guid: [UInt8], since: Date) async throws -> (txID: String, logs: [TradeSimulatedLog])? {
        guard guid.count == 32 else { throw ReaderError.invalidInput("guid") }
        guard !historyProviders.isEmpty else { throw ReaderError.unsupported("eventos sem indexador") }
        let transport = self.transport
        let historyPool = ProviderPool(historyProviders)
        let wanted = Hex.encode(guid)
        let start = String(Int64(max(0, since.timeIntervalSince1970) * 1_000))
        let found: String? = try await Quorum.first(historyProviders, pool: historyPool) { provider in
            let url = provider.baseURL.adding(path: "v1/contracts/" + oft.base58 + "/events").adding(query: [
                ("event_name", "OFTReceived"), ("only_confirmed", "true"), ("min_block_timestamp", start),
                ("order_by", "block_timestamp,asc"), ("limit", "200"),
            ])
            return try Self.meshEventTransaction(StrictJSON.parse(try await transport.send(.get(url, timeout: 30))), guid: wanted)
        }
        guard let txID = found else { return nil }
        let providers = await pool.available()
        let readings = try await Quorum.collect(providers, pool: pool, count: 2) { provider in
            try Self.parseTransactionLogs(try await Self.post(transport, provider, "walletsolidity/gettransactioninfobyid", ["value": .string(txID)]),
                                          id: txID)
        }.map(\.value)
        guard let first = readings[0], let second = readings[1] else { return nil }
        guard first == second else { throw ReaderError.responseMismatch(field: "gettransactioninfobyid.log") }
        return (txID, first)
    }

    /// O `transaction_id` do OFTReceived com este `guid`, na resposta da API de eventos.
    static func meshEventTransaction(_ json: StrictJSON, guid: String) throws -> String? {
        guard let events = json.optionalField("data")?.arrayValue else { throw ReaderError.malformed(field: "events.data") }
        for event in events {
            guard let result = event.optionalField("result"), let value = try? result.field("guid", "events.guid").string("events.guid"),
                  value.lowercased().replacingOccurrences(of: "0x", with: "") == guid
            else { continue }
            let id = try event.field("transaction_id", "events.transaction_id").string("events.transaction_id").lowercased()
            guard let bytes = Hex.decode(id), bytes.count == 32 else { throw ReaderError.malformed(field: "events.transaction_id") }
            return id
        }
        return nil
    }

    /// Os logs de uma transacao da Tron que deu certo (`receipt.result` SUCCESS), com os
    /// enderecos nos 20 bytes da TVM. `nil`: ainda nao esta no no solidificado.
    static func parseTransactionLogs(_ json: StrictJSON, id: String) throws -> [TradeSimulatedLog]? {
        guard let fields = json.objectValue else { throw ReaderError.malformed(field: "gettransactioninfobyid") }
        if fields.isEmpty { return nil }
        guard try json.field("id", "gettransactioninfobyid").string("gettransactioninfobyid.id").lowercased() == id else {
            throw ReaderError.responseMismatch(field: "gettransactioninfobyid.id")
        }
        guard try json.optionalField("receipt")?.optionalField("result")?.string("gettransactioninfobyid.receipt.result") == "SUCCESS" else {
            throw ReaderError.responseMismatch(field: "gettransactioninfobyid.receipt")
        }
        return try (json.optionalField("log")?.arrayValue ?? []).map { log in
            let address = try log.field("address", "log.address").string("log.address")
            guard let raw = Hex.decode(address.hasPrefix("41") && address.count == 42 ? String(address.dropFirst(2)) : address), raw.count == 20,
                  let contract = EVMAddress(bytes: raw)
            else { throw ReaderError.malformed(field: "log.address") }
            let topics = try (log.optionalField("topics")?.arrayValue ?? []).map { topic -> [UInt8] in
                guard let bytes = Hex.decode(try topic.string("log.topics")), bytes.count == 32 else { throw ReaderError.malformed(field: "log.topics") }
                return bytes
            }
            let data = try log.optionalField("data").map { try $0.string("log.data") } ?? ""
            guard let bytes = Hex.decode(data) else { throw ReaderError.malformed(field: "log.data") }
            return TradeSimulatedLog(address: contract, topics: topics, data: bytes)
        }
    }
}
