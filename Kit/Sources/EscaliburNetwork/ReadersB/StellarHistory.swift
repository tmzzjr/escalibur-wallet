import EscaliburChains
import EscaliburCore
import Foundation

/// Uma operacao de `/accounts/{G}/operations`. Os campos variam por tipo; os de
/// cada tipo que o historico interpreta sao exigidos em `StellarHistory`.
struct HorizonOperation: Decodable, Sendable {
    let id: String
    let type: String
    let createdAt: String
    let transactionHash: String
    let transactionSuccessful: Bool
    let sourceAccount: String

    let from: String?
    let to: String?
    let amount: String?
    let assetType: String?
    let assetCode: String?
    let assetIssuer: String?
    let sourceAmount: String?
    let sourceAssetType: String?
    let sourceAssetCode: String?
    let sourceAssetIssuer: String?
    let funder: String?
    let account: String?
    let startingBalance: String?
    let into: String?
    /// `create_claimable_balance`: "native" ou "CODIGO:EMISSOR".
    let asset: String?

    enum CodingKeys: String, CodingKey {
        case id, type, from, to, amount, funder, account, into, asset
        case createdAt = "created_at"
        case transactionHash = "transaction_hash"
        case transactionSuccessful = "transaction_successful"
        case sourceAccount = "source_account"
        case assetType = "asset_type"
        case assetCode = "asset_code"
        case assetIssuer = "asset_issuer"
        case sourceAmount = "source_amount"
        case sourceAssetType = "source_asset_type"
        case sourceAssetCode = "source_asset_code"
        case sourceAssetIssuer = "source_asset_issuer"
        case startingBalance = "starting_balance"
    }
}

/// Um trade de `/accounts/{G}/trades`: uma oferta executada contra outra (ou contra
/// um pool de liquidez, quando um dos lados nao tem conta).
struct HorizonTrade: Decodable, Sendable {
    let id: String
    let ledgerCloseTime: String
    let baseAccount: String?
    let baseAmount: String
    let baseAssetType: String
    let baseAssetCode: String?
    let baseAssetIssuer: String?
    let counterAccount: String?
    let counterAmount: String
    let counterAssetType: String
    let counterAssetCode: String?
    let counterAssetIssuer: String?
    let baseIsSeller: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case ledgerCloseTime = "ledger_close_time"
        case baseAccount = "base_account"
        case baseAmount = "base_amount"
        case baseAssetType = "base_asset_type"
        case baseAssetCode = "base_asset_code"
        case baseAssetIssuer = "base_asset_issuer"
        case counterAccount = "counter_account"
        case counterAmount = "counter_amount"
        case counterAssetType = "counter_asset_type"
        case counterAssetCode = "counter_asset_code"
        case counterAssetIssuer = "counter_asset_issuer"
        case baseIsSeller = "base_is_seller"
    }
}

enum StellarHistory {
    /// Ate 0,01 unidade (100.000 stroops) vindo de desconhecido e poeira: o spam da
    /// Stellar manda 0,0000001 XLM com memo de propaganda, ou de endereco parecido.
    static let dustThreshold = BigUInt(100_000)

    static func activities(
        account: StellarAccountID, operations: [HorizonOperation], trades: [HorizonTrade],
        limit: Int, listedAssets: [StellarAsset], knownCounterparties: Set<String>
    ) throws -> [ChainActivity] {
        let me = account.address
        let decimals = StellarReader.decimals

        func amount(_ text: String?, _ field: String) throws -> BigUInt {
            guard let text else { throw ChainReaderError.malformedResponse(field: field) }
            return try DecimalUnits.parse(text, decimals: decimals, field: field)
        }
        func asset(_ type: String?, _ code: String?, _ issuer: String?, _ field: String) throws -> StellarAsset {
            guard let type else { throw ChainReaderError.malformedResponse(field: field) }
            return try HorizonAssetFields(type: type, code: code, issuer: issuer).asset(field: field)
        }
        func ref(_ asset: StellarAsset) -> ChainActivity.AssetRef {
            guard let issuer = asset.issuer else { return .native }
            return .issued(code: asset.code, issuer: issuer.address)
        }
        func listed(_ asset: StellarAsset) -> Bool { asset.isNative || listedAssets.contains(asset) }
        func required(_ value: String?, _ field: String) throws -> String {
            guard let value else { throw ChainReaderError.malformedResponse(field: field) }
            return value
        }

        // Quem a conta ja pagou (ou criou) deixa de ser desconhecido.
        var known = knownCounterparties
        for op in operations where op.transactionSuccessful {
            if op.from == me, let to = op.to, to != me { known.insert(to) }
            if op.type == "create_account", op.funder == me, let created = op.account { known.insert(created) }
        }

        var items: [(date: Date?, order: String, item: ChainActivity)] = []
        for (index, op) in operations.enumerated() where op.transactionSuccessful {
            let field = "operations.\(index)"
            let date = UTXOProviderClient.isoDate(op.createdAt)
            var kind = ChainActivity.Kind.other
            var movements: [ChainActivity.Movement] = []
            var counterparty: String?
            var suspicion: ChainActivity.Suspicion?

            func incoming(_ value: BigUInt, _ what: StellarAsset, from sender: String) {
                if !listed(what) {
                    suspicion = .unlistedAsset
                } else if value <= dustThreshold, !known.contains(sender) {
                    suspicion = .dust
                }
            }

            switch op.type {
            case "payment":
                let from = try required(op.from, field), to = try required(op.to, field)
                let value = try amount(op.amount, field)
                let what = try asset(op.assetType, op.assetCode, op.assetIssuer, field)
                if from == me, to == me {
                    kind = .selfTransfer
                } else if from == me {
                    kind = .send
                    movements = [.init(asset: ref(what), amount: value, incoming: false)]
                    counterparty = to
                } else if to == me {
                    kind = .receive
                    movements = [.init(asset: ref(what), amount: value, incoming: true)]
                    counterparty = from
                    incoming(value, what, from: from)
                }
            case "path_payment_strict_send", "path_payment_strict_receive":
                let from = try required(op.from, field), to = try required(op.to, field)
                let received = try amount(op.amount, field)
                let receivedAsset = try asset(op.assetType, op.assetCode, op.assetIssuer, field)
                let sent = try amount(op.sourceAmount, field)
                let sentAsset = try asset(op.sourceAssetType, op.sourceAssetCode, op.sourceAssetIssuer, field)
                if from == me, to == me {
                    kind = .swap
                    movements = [
                        .init(asset: ref(sentAsset), amount: sent, incoming: false),
                        .init(asset: ref(receivedAsset), amount: received, incoming: true),
                    ]
                } else if from == me {
                    kind = .send
                    movements = [.init(asset: ref(sentAsset), amount: sent, incoming: false)]
                    counterparty = to
                } else if to == me {
                    kind = .receive
                    movements = [.init(asset: ref(receivedAsset), amount: received, incoming: true)]
                    counterparty = from
                    incoming(received, receivedAsset, from: from)
                }
            case "create_account":
                let funder = try required(op.funder, field), created = try required(op.account, field)
                let value = try amount(op.startingBalance, field)
                kind = .createAccount
                if funder == me {
                    movements = [.init(asset: .native, amount: value, incoming: false)]
                    counterparty = created
                } else if created == me {
                    // Criar conta custa pelo menos 1 XLM a quem cria: nao e poeira.
                    movements = [.init(asset: .native, amount: value, incoming: true)]
                    counterparty = funder
                }
            case "account_merge":
                let merged = try required(op.account, field), into = try required(op.into, field)
                kind = .accountMerge
                counterparty = merged == me ? into : merged
            case "manage_sell_offer", "manage_buy_offer", "create_passive_sell_offer":
                kind = op.sourceAccount == me ? .offer : .other
            case "change_trust":
                kind = .trustline
            case "create_claimable_balance":
                kind = .claimableBalance
                let value = try amount(op.amount, field)
                let what = try Self.claimableAsset(try required(op.asset, field), field: field)
                if op.sourceAccount == me {
                    movements = [.init(asset: ref(what), amount: value, incoming: false)]
                } else {
                    // Ainda nao e saldo: so vira saldo se o dono reivindicar.
                    movements = [.init(asset: ref(what), amount: value, incoming: true)]
                    counterparty = op.sourceAccount
                    if !known.contains(op.sourceAccount) || !listed(what) { suspicion = .unsolicitedClaimable }
                }
            case "claim_claimable_balance":
                kind = .claimableBalance
            default:
                kind = .other
            }

            items.append((date, op.id, ChainActivity(
                id: op.id, chainID: Chain.stellar.id, transactionHash: op.transactionHash, kind: kind,
                movements: movements, fee: nil, counterparty: counterparty, date: date,
                status: .confirmed(confirmations: nil), suspicion: suspicion
            )))
        }

        for (index, trade) in trades.enumerated() {
            let field = "trades.\(index)"
            let base = try asset(trade.baseAssetType, trade.baseAssetCode, trade.baseAssetIssuer, field)
            let counter = try asset(trade.counterAssetType, trade.counterAssetCode, trade.counterAssetIssuer, field)
            let baseAmount = try amount(trade.baseAmount, field)
            let counterAmount = try amount(trade.counterAmount, field)
            // base_is_seller: o lado base vendeu o ativo base e recebeu o contrario.
            let gave: (StellarAsset, BigUInt), got: (StellarAsset, BigUInt)
            let other: String?
            if trade.baseAccount == me {
                (gave, got) = trade.baseIsSeller ? ((base, baseAmount), (counter, counterAmount)) : ((counter, counterAmount), (base, baseAmount))
                other = trade.counterAccount
            } else if trade.counterAccount == me {
                (gave, got) = trade.baseIsSeller ? ((counter, counterAmount), (base, baseAmount)) : ((base, baseAmount), (counter, counterAmount))
                other = trade.baseAccount
            } else {
                throw ChainReaderError.mismatchedResponse
            }
            let date = UTXOProviderClient.isoDate(trade.ledgerCloseTime)
            items.append((date, trade.id, ChainActivity(
                id: "trade-\(trade.id)", chainID: Chain.stellar.id, transactionHash: nil, kind: .trade,
                movements: [
                    .init(asset: ref(gave.0), amount: gave.1, incoming: false),
                    .init(asset: ref(got.0), amount: got.1, incoming: true),
                ],
                fee: nil, counterparty: other, date: date, status: .confirmed(confirmations: nil),
                suspicion: listed(got.0) ? nil : .unlistedAsset
            )))
        }

        items.sort { a, b in
            switch (a.date, b.date) {
            case (let x?, let y?) where x != y: return x > y
            default: return a.order > b.order
            }
        }
        return Array(items.prefix(max(0, limit)).map(\.item))
    }

    /// "native" ou "CODIGO:EMISSOR".
    static func claimableAsset(_ text: String, field: String) throws -> StellarAsset {
        if text == "native" { return .native }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let asset = try? StellarAsset(code: String(parts[0]), issuer: String(parts[1])) else {
            throw ChainReaderError.malformedResponse(field: field)
        }
        return asset
    }
}
