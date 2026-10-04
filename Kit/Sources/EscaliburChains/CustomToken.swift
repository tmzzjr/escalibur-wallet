import EscaliburCore
import Foundation

/// Moeda custom: um token que o dono adiciona colando o contrato (ou o mint, o mestre do
/// jetton, o codigo e o emissor). Aqui so a forma do que foi colado, sem rede: o endereco
/// e conferido pelo formato e pelo checksum da propria rede e escrito na forma canonica
/// (EIP-55, mestre da TON amigavel), para o id da moeda ser um so. Nome, simbolo e casas
/// decimais sao lidos na rede depois, com dois provedores concordando nas casas.
public enum CustomToken {
    public enum Problem: Error, Equatable, Sendable {
        /// A rede nao tem token por contrato (UTXO) ou a carteira ainda nao le token dela.
        case unsupportedChain
        case empty
        /// O texto nao e um endereco desta rede (ou o checksum nao fecha).
        case invalidAddress
        /// XRP Ledger e Stellar: o codigo da moeda nao vale ("XRP", tamanho errado).
        case invalidCode
        /// O token ja esta na lista conferida: ele aparece sozinho, com o selo verificado.
        case alreadyListed(Asset)
        /// O endereco e de uma conta que nao emite token nesta forma (programa conhecido,
        /// o proprio mint do SOL embrulhado).
        case notAToken
    }

    /// As redes em que o dono pode adicionar moeda.
    public static func supports(_ chain: Chain) -> Bool {
        switch chain.family {
        case .evm, .solana, .tron, .ton, .xrpl, .stellar: return true
        case .utxo, .sui, .cardano, .polkadot, .near, .aptos: return false
        }
    }

    /// XRP Ledger e Stellar: a moeda e codigo mais emissor. As outras: um endereco.
    public static func usesIssuer(_ chain: Chain) -> Bool {
        chain.family == .xrpl || chain.family == .stellar
    }

    /// O que a tela pede, na lingua da rede.
    public static func addressLabel(_ chain: Chain) -> String {
        switch chain.family {
        case .solana: return "Mint do token"
        case .ton: return "Endereço mestre do jetton"
        case .xrpl, .stellar: return "Emissor"
        case .sui: return "Tipo da moeda"
        case .cardano: return "Política e nome do ativo"
        case .polkadot: return "Número do ativo"
        case .aptos: return "Endereço do ativo"
        default: return "Contrato do token"
        }
    }

    /// Por que a carteira nao envia moeda custom nesta rede, ou nil quando envia. O
    /// motor de cada rede diz o mesmo se receber o pedido.
    public static func sendUnavailableReason(_ chain: Chain) -> String? {
        switch chain.family {
        case .evm, .solana, .stellar:
            return nil
        case .tron:
            return "Na Tron, a Escalibur envia só TRX e USDT. Um TRC-20 qualquer pede a leitura da energia do contrato dele, que ainda não existe aqui. A moeda aparece no saldo e você recebe normalmente."
        case .ton:
            return "Na TON, a Escalibur envia só TON e USDT. Um jetton qualquer pede conferir a carteira de jetton e o código do contrato dele, o que ainda não existe aqui. A moeda aparece no saldo e você recebe normalmente."
        case .xrpl:
            return "No XRP Ledger, a Escalibur envia só XRP por enquanto, nem os tokens da lista. A moeda aparece no saldo e você recebe normalmente, se a conta já tiver a linha de confiança."
        default:
            return "Esta rede não tem moeda custom."
        }
    }

    /// Contrato (EVM, Tron), mint (Solana) ou mestre de jetton (TON).
    public static func kind(chain: Chain, address raw: String) throws -> Asset.Kind {
        guard supports(chain), !usesIssuer(chain) else { throw Problem.unsupportedChain }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Problem.empty }
        let kind: Asset.Kind
        switch chain.family {
        case .evm:
            guard let address = try? EVMAddress(text) else { throw Problem.invalidAddress }
            guard !address.bytes.allSatisfy({ $0 == 0 }) else { throw Problem.invalidAddress }
            kind = .token(contract: address.checksummed)
        case .solana:
            guard let key = try? SolanaPublicKey(base58: text), key.base58 == text else { throw Problem.invalidAddress }
            if SolanaProgram(id: key) != nil || key == SolanaWrappedSOL.mint { throw Problem.notAToken }
            kind = .token(contract: key.base58)
        case .tron:
            guard text.hasPrefix("T"), let address = TronAddress(base58: text) else { throw Problem.invalidAddress }
            kind = .token(contract: address.base58)
        case .ton:
            guard case .success(let parsed) = TONAddress.parse(text), !parsed.testnet else { throw Problem.invalidAddress }
            kind = .token(contract: parsed.address.friendly(bounceable: true))
        default:
            throw Problem.unsupportedChain
        }
        if let listed = TokenRegistry.listed(chainID: chain.id, kind: kind) { throw Problem.alreadyListed(listed) }
        return kind
    }

    /// XRP Ledger (codigo de 3 letras ou 40 hex, emissor r...) e Stellar (codigo de 1 a
    /// 12 letras e digitos, emissor G...).
    public static func kind(chain: Chain, code rawCode: String, issuer rawIssuer: String) throws -> Asset.Kind {
        guard usesIssuer(chain) else { throw Problem.unsupportedChain }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let issuer = rawIssuer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !issuer.isEmpty else { throw Problem.empty }
        let kind: Asset.Kind
        switch chain.family {
        case .xrpl:
            guard case .success(let destination) = XRPLAddress.validate(issuer), destination.tag == nil,
                  destination.address == issuer
            else { throw Problem.invalidAddress }
            let normalized = code.count == 40 ? code.uppercased() : code
            guard (try? XRPLCurrency(code: normalized)) != nil else { throw Problem.invalidCode }
            kind = .issued(code: normalized, issuer: issuer)
        case .stellar:
            guard issuer.hasPrefix("G"), StellarAccountID(address: issuer) != nil else { throw Problem.invalidAddress }
            guard let asset = try? StellarAsset(code: code, issuer: issuer), !asset.isNative else { throw Problem.invalidCode }
            kind = .issued(code: asset.code, issuer: issuer)
        default:
            throw Problem.unsupportedChain
        }
        if let listed = TokenRegistry.listed(chainID: chain.id, kind: kind) { throw Problem.alreadyListed(listed) }
        return kind
    }

    /// O simbolo de um codigo de moeda do XRP Ledger: as 3 letras, o texto de um codigo
    /// de 160 bits ou, sem texto legivel, o comeco do hex.
    public static func xrplSymbol(_ code: String) -> String {
        guard let currency = try? XRPLCurrency(ledgerCode: code) else { return String(code.prefix(8)) }
        let display = currency.displayCode
        return display.count == 40 ? String(display.prefix(8)) : display
    }

    /// A moeda custom pronta para guardar, com o que foi lido na rede ja limpo para a
    /// tela.
    public static func asset(chain: Chain, kind: Asset.Kind, symbol: String, name: String, decimals: Int) -> Asset {
        let cleanSymbol = TokenSafety.clean(symbol, limit: TokenSafety.symbolLimit)
        let cleanName = TokenSafety.clean(name, limit: TokenSafety.nameLimit)
        return Asset(
            chainID: chain.id, kind: kind, symbol: cleanSymbol.isEmpty ? fallbackSymbol(kind) : cleanSymbol,
            name: cleanName.isEmpty ? (cleanSymbol.isEmpty ? fallbackSymbol(kind) : cleanSymbol) : cleanName,
            decimals: decimals, coingeckoID: nil, isStablecoin: false, origin: .custom
        )
    }

    /// Sem simbolo legivel: o comeco do contrato.
    public static func fallbackSymbol(_ kind: Asset.Kind) -> String {
        switch kind {
        case .native: return "?"
        case .token(let contract): return String(contract.prefix(6))
        case .issued(let code, _): return xrplSymbolOrCode(code)
        }
    }

    static func xrplSymbolOrCode(_ code: String) -> String {
        code.count == 40 ? xrplSymbol(code) : code
    }

    /// O explorador da rede abre a pagina do token pelo mesmo endereco de conta? Na Sui,
    /// Cardano, Polkadot e Aptos o identificador do token nao e uma conta, e o link levaria
    /// a outro lugar.
    public static func explorerShowsToken(_ chain: Chain) -> Bool {
        switch chain.family {
        case .evm, .solana, .tron, .ton, .xrpl, .stellar, .near: return true
        case .utxo, .sui, .cardano, .polkadot, .aptos: return false
        }
    }

    /// O contrato inteiro, como a tela mostra e o dono confere. Na XRPL e na Stellar,
    /// o emissor (o codigo aparece a parte).
    public static func reference(_ kind: Asset.Kind) -> String? {
        switch kind {
        case .native: return nil
        case .token(let contract): return contract
        case .issued(_, let issuer): return issuer
        }
    }
}

extension CustomToken {
    /// O retorno de `name()` ou `symbol()` de um contrato EVM ou TRC-20: `string` ABI ou,
    /// nos tokens antigos (MKR, SAI), `bytes32` com zeros a direita. Bytes que nao sao
    /// UTF-8 valido ou tamanho fora do formato viram nil. Limite de 256 bytes: nome de
    /// token nao precisa de mais, e o resto nao vai para a tela.
    public static func decodeABIText(_ data: [UInt8]) -> String? {
        if data.count == 32 {
            let trimmed = Array(data.prefix { $0 != 0 })
            return String(bytes: trimmed, encoding: .utf8)
        }
        guard data.count >= 64, data.count % 32 == 0 else { return nil }
        guard let offset = BigUInt(bigEndian: data[0..<32]).uint64, offset == 32,
              let length = BigUInt(bigEndian: data[32..<64]).uint64, length <= 256, 64 + Int(length) <= data.count
        else { return nil }
        return String(bytes: data[64..<(64 + Int(length))], encoding: .utf8)
    }
}
