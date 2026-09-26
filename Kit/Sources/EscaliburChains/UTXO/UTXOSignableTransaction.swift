import EscaliburCore
import Foundation

/// Constantes e conferencias da assinatura ECDSA das redes UTXO.
public enum UTXOSigning {
    /// DER de pior caso com S baixo (71 bytes) mais o byte de sighash.
    public static let maxSignatureLength = 72

    /// Codificacao DER estrita do BIP-66 (`IsValidSignatureEncoding` do Core), aqui
    /// sobre o DER sem o byte de sighash. O no recusa por consenso qualquer outra
    /// forma, e uma assinatura recusada deixa a transacao presa sem aviso.
    public static func isStrictDER(_ sig: [UInt8]) -> Bool {
        let n = sig.count
        guard n >= 8, n <= 72, sig[0] == 0x30, Int(sig[1]) == n - 2 else { return false }
        let lenR = Int(sig[3])
        guard 5 + lenR < n else { return false }
        let lenS = Int(sig[5 + lenR])
        guard lenR + lenS + 6 == n else { return false }
        guard sig[2] == 0x02, lenR != 0, sig[4] & 0x80 == 0 else { return false }
        if lenR > 1, sig[4] == 0x00, sig[5] & 0x80 == 0 { return false }
        guard sig[lenR + 4] == 0x02, lenS != 0, sig[lenR + 6] & 0x80 == 0 else { return false }
        if lenS > 1, sig[lenR + 6] == 0x00, sig[lenR + 7] & 0x80 == 0 { return false }
        return true
    }
}

/// Uma entrada da carteira: o que se sabe da saida gasta, ja conferido.
public struct UTXOSpend: Sendable, Equatable {
    public let kind: UTXOInputKind
    public let path: DerivationPath
    /// Chave publica comprimida (33 bytes). O assinador recusa se a chave derivada
    /// do caminho nao for esta.
    public let publicKey: [UInt8]
    /// Valor da saida gasta, tirado da transacao anterior conferida.
    public let value: UInt64

    public init(kind: UTXOInputKind, path: DerivationPath, publicKey: [UInt8], value: UInt64) {
        self.kind = kind
        self.path = path
        self.publicKey = publicKey
        self.value = value
    }

    /// O scriptCode que o digesto cobre: P2PKH da chave nos tres tipos (no P2PKH e o
    /// proprio scriptPubKey; no segwit v0 e o que o BIP-143 manda usar).
    var scriptCode: [UInt8] { UTXOScript.p2pkh(Hash.hash160(publicKey)) }
}

/// O resumo numerico do envio, para a tela e para o historico.
public struct UTXOSendSummary: Sendable, Equatable {
    public let destination: String
    public let amount: BigUInt
    public let fee: BigUInt
    public let feeRate: UTXOFeeRate
    /// Tamanho virtual estimado com assinaturas de pior caso. O real e igual ou menor,
    /// entao a taxa efetiva nunca fica abaixo da escolhida.
    public let virtualSize: Int
    /// Valor do troco, ou `nil` quando nao ha saida de troco.
    public let change: BigUInt?
    public let changeAddress: String?
    /// O que sobrou e virou taxa: troco abaixo do dust, ou menor que o custo de
    /// cria-lo. Zero quando nada sobrou. A tela mostra.
    public let absorbedIntoFee: BigUInt
    public let inputCount: Int
    public let sendsAll: Bool
}

/// Uma transacao UTXO pronta para o assinador.
///
/// So nasce dentro do pacote (pelo `UTXOPlanner` ou pelos testes). Os digestos sao
/// calculados na criacao, a partir dos campos da transacao e dos valores conferidos.
public struct UTXOSignableTransaction: SignableTransaction {
    public let chain: Chain
    /// A transacao sem assinatura: scriptSig e witness vazios.
    public let unsigned: UTXOTransaction
    public let spends: [UTXOSpend]
    public let summary: UTXOSendSummary?
    public let signingRequests: [SigningRequest]

    public enum BuildError: Error, Equatable, Sendable {
        case spendCountMismatch
        case segwitNotSupported
        case invalidPublicKey
    }

    package init(chain: Chain, unsigned: UTXOTransaction, spends: [UTXOSpend], summary: UTXOSendSummary? = nil) throws {
        guard unsigned.inputs.count == spends.count, !spends.isEmpty else { throw BuildError.spendCountMismatch }
        let rules = UTXORules.for(chain)
        var clean = unsigned
        for i in clean.inputs.indices {
            clean.inputs[i].scriptSig = []
            clean.inputs[i].witness = []
        }
        var requests = [SigningRequest]()
        for (index, spend) in spends.enumerated() {
            guard spend.publicKey.count == 33, (try? Secp256k1.reformat(publicKey: spend.publicKey, compressed: true)) == spend.publicKey else {
                throw BuildError.invalidPublicKey
            }
            if spend.kind.isSegwit, !rules.segwit { throw BuildError.segwitNotSupported }
            let digest = Self.digest(clean, index: index, spend: spend)
            requests.append(SigningRequest(
                path: spend.path, curve: .secp256k1, scheme: .ecdsaDER,
                payload: digest, expectedPublicKey: spend.publicKey
            ))
        }
        self.chain = chain
        self.unsigned = clean
        self.spends = spends
        self.summary = summary
        self.signingRequests = requests
    }

    static func digest(_ tx: UTXOTransaction, index: Int, spend: UTXOSpend) -> [UInt8] {
        switch spend.kind {
        case .p2wpkh, .p2shP2wpkh:
            return UTXOSighash.segwitV0(transaction: tx, inputIndex: index, scriptCode: spend.scriptCode, amount: spend.value, hashType: UTXOSighash.all)
        case .p2pkh:
            return UTXOSighash.legacy(transaction: tx, inputIndex: index, scriptCode: spend.scriptCode, hashType: UTXOSighash.all)
        }
    }

    /// Monta scriptSig e witness com as assinaturas, na ordem das entradas.
    ///
    /// Cada assinatura e conferida de novo aqui (DER estrito, S baixo e verificacao
    /// contra o digesto e a chave esperada), mesmo que o assinador ja tenha conferido:
    /// uma assinatura invalida transmitida nao perde dinheiro, mas deixa o dono sem
    /// saber por que o envio nao saiu.
    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == signingRequests.count else { throw SigningError.wrongSignatureCount }
        var tx = unsigned
        for (index, signature) in signatures.enumerated() {
            let request = signingRequests[index]
            let der = signature.bytes
            guard UTXOSigning.isStrictDER(der),
                  Secp256k1.verifyDER(signature: der, digest: request.payload, publicKey: request.expectedPublicKey)
            else { throw SigningError.malformedSignature }
            let sig = der + [UInt8(UTXOSighash.all)]
            let spend = spends[index]
            switch spend.kind {
            case .p2wpkh:
                tx.inputs[index].witness = [sig, spend.publicKey]
            case .p2shP2wpkh:
                let redeem = UTXOScript.p2wpkh(Hash.hash160(spend.publicKey))
                tx.inputs[index].scriptSig = UTXOScript.push(redeem)
                tx.inputs[index].witness = [sig, spend.publicKey]
            case .p2pkh:
                tx.inputs[index].scriptSig = UTXOScript.push(sig) + UTXOScript.push(spend.publicKey)
            }
        }
        let raw = tx.serialized()
        return SignedTransaction(chainID: chain.id, raw: raw, encoded: Hex.encode(raw), id: tx.txid.hex)
    }
}
