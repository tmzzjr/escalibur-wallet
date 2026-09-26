import EscaliburCore
import Foundation

// Transacoes EVM: tipo 2 (EIP-1559) e legado com EIP-155.
//
// O que se assina e calculado aqui, dos campos, e nunca aceito pronto de fora:
//
//   tipo 2:  keccak256(0x02 || rlp([chainId, nonce, maxPriorityFeePerGas,
//            maxFeePerGas, gasLimit, to, value, data, accessList]))
//   legado:  keccak256(rlp([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]))
//
// O chainId vem sempre de `Chain.evmChainID`, constante compilada. Nao existe
// parametro para informar outro: uma assinatura com chainId trocado vale em outra
// rede, e o jeito mais simples de levar alguem a assinar para a rede errada e deixar
// o numero chegar de fora (docs/seguranca.md 4.11).

public enum EVMTransactionError: Error, Equatable, Sendable {
    /// A rede nao e da familia EVM ou nao tem chainId compilado.
    case notEVMChain
    case gasLimitOutOfRange
}

/// Os campos de uma transacao, com o chainId como numero. E interno ao modulo de
/// proposito: e o unico lugar onde o chainId entra como parametro, e so os vetores
/// oficiais (com chainIds arbitrarios, via `@testable`) e o `EVMTransaction` (com o
/// chainId compilado da rede) o usam.
struct EVMTransactionFields: Sendable, Equatable {
    var chainID: BigUInt
    var nonce: BigUInt
    var fee: EVMTransaction.Fee
    var gasLimit: BigUInt
    var to: [UInt8]
    var value: BigUInt
    var data: [UInt8]

    init(chainID: BigUInt, nonce: BigUInt, fee: EVMTransaction.Fee, gasLimit: BigUInt, to: [UInt8], value: BigUInt, data: [UInt8]) {
        self.chainID = chainID
        self.nonce = nonce
        self.fee = fee
        self.gasLimit = gasLimit
        self.to = to
        self.value = value
        self.data = data
    }

    /// A lista RLP dos campos, sem assinatura. A access list e sempre vazia: a
    /// carteira nao monta access list, e uma lista vinda de fora so aumentaria o
    /// que precisa ser conferido.
    private var body: [RLP] {
        switch fee {
        case .eip1559(let tip, let maxFee):
            return [.uint(chainID), .uint(nonce), .uint(tip), .uint(maxFee), .uint(gasLimit), .bytes(to), .uint(value), .bytes(data), .list([])]
        case .legacy(let gasPrice):
            return [.uint(nonce), .uint(gasPrice), .uint(gasLimit), .bytes(to), .uint(value), .bytes(data)]
        }
    }

    /// Os bytes cujo keccak e assinado ("signing data" na EIP-155).
    var signingPayload: [UInt8] {
        switch fee {
        case .eip1559:
            return [0x02] + RLP.list(body).encoded
        case .legacy:
            return RLP.list(body + [.uint(chainID), .uint(0), .uint(0)]).encoded
        }
    }

    var signingDigest: [UInt8] { Hash.keccak256(signingPayload) }

    /// A transacao assinada. `r` e `s` entram como inteiros (sem zero a esquerda),
    /// que e o que o RLP canonico exige: um no recusa `r` com byte zero na frente.
    func signed(recoveryID: UInt8, r: [UInt8], s: [UInt8]) -> [UInt8] {
        let rValue = BigUInt(bigEndian: r)
        let sValue = BigUInt(bigEndian: s)
        switch fee {
        case .eip1559:
            return [0x02] + RLP.list(body + [.uint(BigUInt(recoveryID)), .uint(rValue), .uint(sValue)]).encoded
        case .legacy:
            // EIP-155: v = recid + 35 + 2 * chainId.
            let v = BigUInt(UInt64(recoveryID) + 35) + chainID * BigUInt(2)
            return RLP.list(body + [.uint(v), .uint(rValue), .uint(sValue)]).encoded
        }
    }
}

/// Uma transacao EVM pronta para assinar.
public struct EVMTransaction: SignableTransaction, Equatable {
    public enum Fee: Sendable, Equatable {
        /// Tipo 2. O no cobra `min(maxFee, baseFee + tip)` por gas.
        case eip1559(maxPriorityFeePerGas: BigUInt, maxFeePerGas: BigUInt)
        /// Legado com EIP-155. So a BNB Chain usa, como alternativa.
        case legacy(gasPrice: BigUInt)

        /// O maximo por unidade de gas que a transacao pode pagar.
        public var maxPerGas: BigUInt {
            switch self {
            case .eip1559(_, let maxFee): return maxFee
            case .legacy(let gasPrice): return gasPrice
            }
        }
    }

    /// Teto de gas de uma transacao desde a EIP-7825 (Fusaka): 2^24.
    public static let maxGasLimit: UInt64 = 16_777_216

    public let chain: Chain
    public let account: EVMAccount
    public let nonce: UInt64
    public let fee: Fee
    public let gasLimit: UInt64
    public let to: EVMAddress
    public let value: BigUInt
    public let data: [UInt8]

    public init(chain: Chain, account: EVMAccount, nonce: UInt64, fee: Fee, gasLimit: UInt64, to: EVMAddress, value: BigUInt, data: [UInt8]) throws {
        guard chain.family == .evm, chain.evmChainID != nil else { throw EVMTransactionError.notEVMChain }
        guard gasLimit >= 21_000, gasLimit <= Self.maxGasLimit else { throw EVMTransactionError.gasLimitOutOfRange }
        self.chain = chain
        self.account = account
        self.nonce = nonce
        self.fee = fee
        self.gasLimit = gasLimit
        self.to = to
        self.value = value
        self.data = data
    }

    /// O chainId compilado da rede.
    public var chainID: UInt64 { chain.evmChainID ?? 0 }

    /// 2 (EIP-1559) ou 0 (legado).
    public var transactionType: UInt8 {
        if case .legacy = fee { return 0 }
        return 2
    }

    var fields: EVMTransactionFields {
        EVMTransactionFields(
            chainID: BigUInt(chainID), nonce: BigUInt(nonce), fee: fee, gasLimit: BigUInt(gasLimit),
            to: to.bytes, value: value, data: data
        )
    }

    /// Os bytes que vao ao keccak.
    public var signingPayload: [UInt8] { fields.signingPayload }

    /// O digesto de 32 bytes que o assinador assina.
    public var signingDigest: [UInt8] { fields.signingDigest }

    /// O maximo que a execucao pode custar, sem a taxa L1 das redes OP.
    public var maxExecutionCost: BigUInt { BigUInt(gasLimit) * fee.maxPerGas }

    public var signingRequests: [SigningRequest] {
        [SigningRequest(
            path: account.path, curve: .secp256k1, scheme: .ecdsaRecoverable,
            payload: signingDigest, expectedPublicKey: account.publicKey
        )]
    }

    public func assemble(with signatures: [ProducedSignature]) throws -> SignedTransaction {
        guard signatures.count == 1 else { throw SigningError.wrongSignatureCount }
        let digest = signingDigest
        let (r, s, recoveryID) = try EVMSignature.check(signatures[0], digest: digest, publicKey: account.publicKey)
        let raw = fields.signed(recoveryID: recoveryID, r: r, s: s)
        return SignedTransaction(
            chainID: chain.id, raw: raw, encoded: Hex.encode(raw, prefix: true),
            id: Hex.encode(Hash.keccak256(raw), prefix: true)
        )
    }
}

/// Conferencias sobre uma assinatura recuperavel antes de ela virar transacao.
enum EVMSignature {
    /// n/2 da secp256k1. A EIP-2 recusa `s` acima disso.
    static let halfOrder = BigUInt(bigEndian: [UInt8](hex: "7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0")!)

    /// O assinador ja verificou, mas a transacao confere de novo o que depende dela:
    /// forma (64 bytes, id 0 ou 1), `r` e `s` nao nulos, `s` baixo, e que a chave
    /// recuperada e a da conta. Um id de recuperacao errado nao perde dinheiro, mas
    /// transmite uma transacao "de outra conta" que falha e confunde o historico.
    static func check(_ signature: ProducedSignature, digest: [UInt8], publicKey: [UInt8]) throws -> (r: [UInt8], s: [UInt8], recoveryID: UInt8) {
        guard signature.bytes.count == 64, let recoveryID = signature.recoveryID, recoveryID <= 1 else {
            throw SigningError.malformedSignature
        }
        let r = Array(signature.bytes.prefix(32))
        let s = Array(signature.bytes.suffix(32))
        let sValue = BigUInt(bigEndian: s)
        guard !BigUInt(bigEndian: r).isZero, !sValue.isZero, sValue <= halfOrder else { throw SigningError.malformedSignature }
        guard let recovered = try? Secp256k1.recover(digest: digest, compact: signature.bytes, recoveryID: recoveryID, compressed: true),
              recovered == publicKey
        else { throw SigningError.malformedSignature }
        return (r, s, recoveryID)
    }
}
