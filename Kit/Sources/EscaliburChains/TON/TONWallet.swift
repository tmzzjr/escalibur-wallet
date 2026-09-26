import EscaliburCore
import Foundation

/// Versao do contrato de carteira. A mesma chave tem um endereco por versao.
public enum TONWalletVersion: String, Sendable, Codable, CaseIterable {
    /// Wallet V4R2: a versao que Trust Wallet e Ledger Live derivam, e que Tonkeeper
    /// e MyTonWallet reconhecem na importacao. E o padrao da Escalibur.
    case v4r2 = "V4R2"
    /// Wallet V5R1 ("W5"): padrao das carteiras novas no Tonkeeper e no MyTonWallet.
    case v5r1 = "V5R1"

    /// Carteira nova na Escalibur nasce V4R2. Motivo: a Trust Wallet, a maior carteira
    /// BIP-39 multi-rede com TON, deriva so V4R2 em `m/44'/607'/0'` (wallet-core,
    /// `rust/chains/tw_ton/src/entry.rs`: "Currently, we use the V4R2 wallet"). Quem
    /// levar a frase da Escalibur para la ve o saldo. Tonkeeper e MyTonWallet olham as
    /// duas versoes ao importar, entao V4R2 tambem aparece nelas.
    public static let `default` = TONWalletVersion.v4r2

    /// O hash de representacao do codigo, o mesmo que `get_account_state` devolve
    /// como `code_hash`. Conferido contra o BOC abaixo toda vez que o codigo e lido.
    public var codeHash: [UInt8] {
        switch self {
        case .v4r2: return TONWalletCode.v4r2Hash
        case .v5r1: return TONWalletCode.v5r1Hash
        }
    }

    /// Nome que a interface mostra.
    public var displayName: String {
        switch self {
        case .v4r2: return "V4R2"
        case .v5r1: return "W5 (V5R1)"
        }
    }

    public func code() throws -> TONCell {
        switch self {
        case .v4r2: return try TONWalletCode.v4r2.get()
        case .v5r1: return try TONWalletCode.v5r1.get()
        }
    }
}

/// Os codigos compilados das carteiras, copiados das fontes oficiais.
///
/// Sao constantes de seguranca: o endereco da carteira e o hash do codigo mais os
/// dados. Um byte trocado aqui gera um endereco que nenhum contrato real controla, e
/// o dinheiro recebido nele fica perdido. Por isso cada BOC e conferido contra o hash
/// publicado antes de ser usado, e o teste confere de novo.
enum TONWalletCode {
    /// Wallet V4R2. Fonte: ton-org/ton, `src/wallets/v4/WalletContractV4.ts` (o mesmo
    /// codigo de trustwallet/wallet-core `rust/chains/tw_ton/resources/wallet/wallet_v4r2.code`).
    /// Codigo FunC em ton-blockchain/wallet-contract, `func/wallet-v4-code.fc`.
    static let v4r2BOC = "te6ccgECFAEAAtQAART/APSkE/S88sgLAQIBIAIDAgFIBAUE+PKDCNcYINMf0x/THwL4I7vyZO1E0NMf0x/T//QE0VFDuvKhUVG68qIF+QFUEGT5EPKj+AAkpMjLH1JAyx9SMMv/UhD0AMntVPgPAdMHIcAAn2xRkyDXSpbTB9QC+wDoMOAhwAHjACHAAuMAAcADkTDjDQOkyMsfEssfy/8QERITAubQAdDTAyFxsJJfBOAi10nBIJJfBOAC0x8hghBwbHVnvSKCEGRzdHK9sJJfBeAD+kAwIPpEAcjKB8v/ydDtRNCBAUDXIfQEMFyBAQj0Cm+hMbOSXwfgBdM/yCWCEHBsdWe6kjgw4w0DghBkc3RyupJfBuMNBgcCASAICQB4AfoA9AQw+CdvIjBQCqEhvvLgUIIQcGx1Z4MesXCAGFAEywUmzxZY+gIZ9ADLaRfLH1Jgyz8gyYBA+wAGAIpQBIEBCPRZMO1E0IEBQNcgyAHPFvQAye1UAXKwjiOCEGRzdHKDHrFwgBhQBcsFUAPPFiP6AhPLassfyz/JgED7AJJfA+ICASAKCwBZvSQrb2omhAgKBrkPoCGEcNQICEekk30pkQzmkD6f+YN4EoAbeBAUiYcVnzGEAgFYDA0AEbjJftRNDXCx+AA9sp37UTQgQFA1yH0BDACyMoHy//J0AGBAQj0Cm+hMYAIBIA4PABmtznaiaEAga5Drhf/AABmvHfaiaEAQa5DrhY/AAG7SB/oA1NQi+QAFyMoHFcv/ydB3dIAYyMsFywIizxZQBfoCFMtrEszMyXP7AMhAFIEBCPRR8qcCAHCBAQjXGPoA0z/IVCBHgQEI9FHyp4IQbm90ZXB0gBjIywXLAlAGzxZQBPoCFMtqEssfyz/Jc/sAAgBsgQEI1xj6ANM/MFIkgQEI9Fnyp4IQZHN0cnB0gBjIywXLAlAFzxZQA/oCE8tqyx8Syz/Jc/sAAAr0AMntVA=="

    /// Hash do codigo V4R2, o mesmo que tonkeeper/tongo (`tvm/precompiled`) usa para
    /// reconhecer a V4R2 na rede.
    static let v4r2Hash: [UInt8] = hex("feb5ff6820e2ff0d9483e7e0d62c817d846789fb4ae580c878866d959dabd5c0")

    /// Wallet V5R1. Fonte: ton-blockchain/wallet-contract-v5, `build/wallet_v5.compiled.json`
    /// (commit 4fab977f4fae3a37c1aac216ed2b7e611a9bc2af, citado por ton-org/ton em
    /// `src/wallets/v5r1/WalletContractV5R1.ts`). O arquivo publica o hash abaixo.
    static let v5r1BOC = "b5ee9c7241021401000281000114ff00f4a413f4bcf2c80b01020120020d020148030402dcd020d749c120915b8f6320d70b1f2082106578746ebd21821073696e74bdb0925f03e082106578746eba8eb48020d72101d074d721fa4030fa44f828fa443058bd915be0ed44d0810141d721f4058307f40e6fa1319130e18040d721707fdb3ce03120d749810280b99130e070e2100f020120050c020120060902016e07080019adce76a2684020eb90eb85ffc00019af1df6a2684010eb90eb858fc00201480a0b0017b325fb51341c75c875c2c7e00011b262fb513435c280200019be5f0f6a2684080a0eb90fa02c0102f20e011e20d70b1f82107369676ebaf2e08a7f0f01e68ef0eda2edfb218308d722028308d723208020d721d31fd31fd31fed44d0d200d31f20d31fd3ffd70a000af90140ccf9109a28945f0adb31e1f2c087df02b35007b0f2d0845125baf2e0855036baf2e086f823bbf2d0882292f800de01a47fc8ca00cb1f01cf16c9ed542092f80fde70db3cd81003f6eda2edfb02f404216e926c218e4c0221d73930709421c700b38e2d01d72820761e436c20d749c008f2e09320d74ac002f2e09320d71d06c712c2005230b0f2d089d74cd7393001a4e86c128407bbf2e093d74ac000f2e093ed55e2d20001c000915be0ebd72c08142091709601d72c081c12e25210b1e30f20d74a111213009601fa4001fa44f828fa443058baf2e091ed44d0810141d718f405049d7fc8ca0040048307f453f2e08b8e14038307f45bf2e08c22d70a00216e01b3b0f2d090e2c85003cf1612f400c9ed54007230d72c08248e2d21f2e092d200ed44d0d2005113baf2d08f54503091319c01810140d721d70a00f2e08ee2c8ca0058cf16c9ed5493f2c08de20010935bdb31e1d74cd0b4d6c35e"

    static let v5r1Hash: [UInt8] = hex("20834b7b72b112147e1b2fb457b84e74d1a30f04f737d4f62a668e9552d2b72f")

    /// Lidos uma vez. O resultado guarda o erro, e quem pede o codigo recebe o erro:
    /// sem `try!`, um BOC adulterado nunca derruba o app, so impede derivar endereco.
    static let v4r2: Result<TONCell, TONCellError> = load(base64: v4r2BOC, expectedHash: v4r2Hash)
    static let v5r1: Result<TONCell, TONCellError> = load(hex: v5r1BOC, expectedHash: v5r1Hash)

    static func load(base64: String, expectedHash: [UInt8]) -> Result<TONCell, TONCellError> {
        guard let data = Data(base64Encoded: base64) else { return .failure(.malformedBOC("base64")) }
        return load(bytes: Array(data), expectedHash: expectedHash)
    }

    static func load(hex: String, expectedHash: [UInt8]) -> Result<TONCell, TONCellError> {
        guard let bytes = Hex.decode(hex) else { return .failure(.malformedBOC("hex")) }
        return load(bytes: bytes, expectedHash: expectedHash)
    }

    static func load(bytes: [UInt8], expectedHash: [UInt8]) -> Result<TONCell, TONCellError> {
        do {
            let cell = try TONBOC.parseRoot(bytes)
            guard cell.hash == expectedHash else { return .failure(.codeHashMismatch) }
            return .success(cell)
        } catch let error as TONCellError {
            return .failure(error)
        } catch {
            return .failure(.malformedBOC("desconhecido"))
        }
    }

    private static func hex(_ text: String) -> [UInt8] { Hex.decode(text) ?? [] }
}

/// Uma carteira TON: chave publica, versao do contrato e o endereco que sai deles.
public struct TONWallet: Sendable, Hashable {
    public let publicKey: [UInt8]
    public let version: TONWalletVersion
    /// V4R2: `subwallet_id` 698983191 (0x29A9A317) na workchain 0, o valor que todas
    /// as carteiras usam. V5R1: `wallet_id` da rede principal (global id -239, contexto
    /// de cliente, workchain 0, versao 0, subcarteira 0) = 2147483409 (0x7FFFFF11),
    /// de ton-org/ton `src/wallets/v5r1/WalletV5R1WalletId.ts`.
    public let walletID: UInt32
    public let code: TONCell
    public let data: TONCell
    public let stateInit: TONCell
    public let address: TONAddress

    public static let v4r2SubwalletID: UInt32 = 698_983_191
    public static let mainnetGlobalID: Int32 = -239

    public init(publicKey: [UInt8], version: TONWalletVersion = .default) throws {
        guard publicKey.count == 32 else { throw Address.Problem.malformed }
        self.publicKey = publicKey
        self.version = version
        code = try version.code()

        var builder = TONCellBuilder()
        switch version {
        case .v4r2:
            walletID = Self.v4r2SubwalletID
            try builder.storeUInt(0, bits: 32)                 // seqno
            try builder.storeUInt(UInt64(walletID), bits: 32)  // subwallet_id
            try builder.storeBytes(publicKey)
            try builder.storeBit(false)                        // plugins: dicionario vazio
        case .v5r1:
            walletID = Self.v5r1WalletID(networkGlobalID: Self.mainnetGlobalID)
            try builder.storeBit(true)                         // is_signature_allowed
            try builder.storeUInt(0, bits: 32)                 // seqno
            try builder.storeUInt(UInt64(walletID), bits: 32)  // wallet_id
            try builder.storeBytes(publicKey)
            try builder.storeBit(false)                        // extensions: dicionario vazio
        }
        data = builder.build()
        stateInit = try Self.stateInit(code: code, data: data)
        address = TONAddress(workchain: TONAddress.basechain, stateInit: stateInit)
    }

    /// `wallet_id` do W5: global id da rede XOR o contexto de cliente
    /// (1 bit 1, workchain int8, versao uint8 = 0, subcarteira uint15 = 0).
    static func v5r1WalletID(networkGlobalID: Int32, workchain: Int8 = 0, subwallet: UInt16 = 0) -> UInt32 {
        let context: UInt32 = 1 << 31 | UInt32(UInt8(bitPattern: workchain)) << 23 | UInt32(subwallet & 0x7FFF)
        return UInt32(bitPattern: networkGlobalID) ^ context
    }

    /// `StateInit`: sem split_depth, sem special, codigo e dados por referencia, sem
    /// bibliotecas. O hash desta celula e o endereco.
    public static func stateInit(code: TONCell, data: TONCell) throws -> TONCell {
        var builder = TONCellBuilder()
        try builder.storeBit(false)       // split_depth
        try builder.storeBit(false)       // special
        try builder.storeMaybeRef(code)
        try builder.storeMaybeRef(data)
        try builder.storeBit(false)       // library
        return builder.build()
    }

    public static func == (a: TONWallet, b: TONWallet) -> Bool {
        a.publicKey == b.publicKey && a.version == b.version
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(publicKey)
        hasher.combine(version)
    }
}

// MARK: Descoberta na importacao

/// Um caminho e uma versao que outra carteira BIP-39 pode ter usado para a TON.
///
/// Importar com o esquema errado mostra saldo zero, e o dono conclui que perdeu o
/// dinheiro. A importacao consulta o estado de cada candidato (saldo, estado da
/// conta) e grava o que achou; sem nada achado, fica o padrao da Escalibur.
public struct TONDerivationScheme: Sendable, Hashable {
    public let path: DerivationPath
    public let version: TONWalletVersion
    /// De onde vem, para a folha de recuperacao e para a tela de importacao.
    public let origin: String

    /// Os candidatos da conta `account`, na ordem de preferencia. Todas as carteiras
    /// abaixo derivam Ed25519 por SLIP-10 a partir da seed BIP-39 (so indices
    /// endurecidos). A frase TON nativa (24 palavras, PBKDF2 "TON default seed") nao e
    /// BIP-39 e nao entra aqui.
    ///
    /// Fontes (conferidas em 25/09/2026):
    /// - Trust Wallet: `m/44'/607'/0'`, V4R2 (wallet-core `registry.json` e
    ///   `rust/chains/tw_ton/src/entry.rs`).
    /// - Tonkeeper: `m/44'/607'/0'` para frase BIP-39 (tonkeeper-web
    ///   `packages/core/src/service/mnemonicService.ts`), W5 como padrao de carteira
    ///   nova (`apps/web/src/App.tsx`), V4R2 reconhecida.
    /// - MyTonWallet: `m/44'/607'/{i}'` (`src/api/chains/ton/derivationConstants.ts`),
    ///   W5 padrao (`src/config.ts`), consulta v3R1, v3R2, v4R2 e W5.
    /// - Ledger Live: `m/44'/607'/0'/0'/{i}'/0'`, V4R2 (ledger-live
    ///   `libs/ledger-wallet-framework/src/derivation.ts` e `coin-ton/src/utils.ts`).
    public static func importCandidates(account: UInt32 = 0) -> [TONDerivationScheme] {
        let h = DerivationPath.hardened
        let standard = DefaultPaths.path(for: .ton, account: account)
        let ledger = DerivationPath(components: [h(44), h(607), h(0), h(0), h(account), h(0)])
        return [
            TONDerivationScheme(path: standard, version: .v4r2, origin: "Escalibur, Trust Wallet, Tonkeeper e MyTonWallet (V4R2)"),
            TONDerivationScheme(path: standard, version: .v5r1, origin: "Tonkeeper e MyTonWallet (W5)"),
            TONDerivationScheme(path: ledger, version: .v4r2, origin: "Ledger Live (V4R2)"),
        ]
    }
}
