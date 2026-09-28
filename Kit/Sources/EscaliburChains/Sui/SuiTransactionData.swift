import EscaliburCore
import Foundation

// `TransactionData` da Sui em BCS, so o subconjunto que a carteira monta e aceita ler.
//
// Layout da fonte (MystenLabs/sui, `crates/sui-types/src/transaction.rs`,
// `base_types.rs` e `digests.rs`; o mesmo do `bcs.ts` do SDK oficial):
//
//   enum TransactionData { V1(TransactionDataV1) }                        variante 0
//   struct TransactionDataV1 { kind, sender: [u8; 32], gas_data, expiration }
//   enum TransactionKind { ProgrammableTransaction(..) = 0, ... }
//   struct ProgrammableTransaction { inputs: Vec<CallArg>, commands: Vec<Command> }
//   enum CallArg { Pure(Vec<u8>) = 0, Object(ObjectArg) = 1, ... }
//   enum ObjectArg { ImmOrOwnedObject(ObjectRef) = 0, SharedObject = 1, Receiving = 2 }
//   ObjectRef = (ObjectID [u8; 32], SequenceNumber u64, ObjectDigest Vec<u8> de 32)
//   enum Command { MoveCall = 0, TransferObjects(Vec<Argument>, Argument) = 1,
//                  SplitCoins(Argument, Vec<Argument>) = 2,
//                  MergeCoins(Argument, Vec<Argument>) = 3, Publish = 4, ... }
//   enum Argument { GasCoin = 0, Input(u16) = 1, Result(u16) = 2, NestedResult(u16, u16) = 3 }
//   struct GasData { payment: Vec<ObjectRef>, owner: [u8; 32], price: u64, budget: u64 }
//   enum TransactionExpiration { None = 0, Epoch(u64) = 1, ValidDuring = 2, ... }
//
// Conferido contra as transacoes do wallet-core da Trust Wallet que a rede principal
// aceitou (`rust/tw_tests/tests/chains/sui/`): os bytes montados aqui sao os mesmos, e o
// digesto e o que o explorador mostra.
//
// Chamada Move, objeto compartilhado, `Receiving`, retirada de saldo de endereco e
// validade `ValidDuring` nao tem representacao aqui: a carteira nao monta, e a leitura
// recusa.

/// Referencia a uma versao exata de um objeto: id, versao e digesto.
public struct SuiObjectRef: Hashable, Sendable {
    public let objectID: SuiAddress
    public let version: UInt64
    /// 32 bytes (o digesto em base58 que os provedores mostram, decodificado).
    public let digest: [UInt8]

    public init(objectID: SuiAddress, version: UInt64, digest: [UInt8]) throws {
        guard digest.count == 32 else { throw SuiTransactionError.malformedDigest }
        self.objectID = objectID
        self.version = version
        self.digest = digest
    }

    /// Digesto em base58, como os provedores escrevem.
    public init(objectID: SuiAddress, version: UInt64, digestBase58 text: String) throws {
        guard let digest = Base58.bitcoin.decode(text) else { throw SuiTransactionError.malformedDigest }
        try self.init(objectID: objectID, version: version, digest: digest)
    }

    public var digestBase58: String { Base58.bitcoin.encode(digest) }
}

public enum SuiArgument: Hashable, Sendable {
    case gasCoin
    case input(UInt16)
    case result(UInt16)
    case nestedResult(UInt16, UInt16)
}

public enum SuiCallArg: Hashable, Sendable {
    /// Valor puro ja em BCS (u64 em little-endian, endereco de 32 bytes).
    case pure([UInt8])
    /// Objeto do proprio remetente, numa versao exata.
    case ownedObject(SuiObjectRef)
}

public enum SuiCommand: Hashable, Sendable {
    case transferObjects([SuiArgument], to: SuiArgument)
    case splitCoins(SuiArgument, amounts: [SuiArgument])
    case mergeCoins(SuiArgument, sources: [SuiArgument])
}

public enum SuiExpiration: Hashable, Sendable {
    case none
    /// Validadores so executam ate o fim desta epoca.
    case epoch(UInt64)
}

public struct SuiGasData: Hashable, Sendable {
    /// As moedas de SUI que pagam o gas. Na execucao elas viram uma so (a primeira).
    public let payment: [SuiObjectRef]
    public let owner: SuiAddress
    /// Preco por unidade de gas, em MIST. A rede exige pelo menos o preco de referencia.
    public let price: UInt64
    /// O maximo de SUI que a transacao pode gastar em gas. Fica retido da moeda de gas
    /// durante a execucao e o que nao for usado volta.
    public let budget: UInt64

    public init(payment: [SuiObjectRef], owner: SuiAddress, price: UInt64, budget: UInt64) {
        self.payment = payment
        self.owner = owner
        self.price = price
        self.budget = budget
    }
}

public enum SuiTransactionError: Error, Equatable, Sendable {
    case malformedDigest
    case malformed
    /// Variante que a carteira nao monta (chamada Move, objeto compartilhado, outra
    /// versao ou outro tipo de transacao).
    case unsupported
    /// Os bytes decodificam, mas a reescrita nao reproduz os mesmos bytes.
    case notCanonical
}

public struct SuiTransactionData: Hashable, Sendable {
    public let inputs: [SuiCallArg]
    public let commands: [SuiCommand]
    public let sender: SuiAddress
    public let gas: SuiGasData
    public let expiration: SuiExpiration

    public init(inputs: [SuiCallArg], commands: [SuiCommand], sender: SuiAddress, gas: SuiGasData, expiration: SuiExpiration) {
        self.inputs = inputs
        self.commands = commands
        self.sender = sender
        self.gas = gas
        self.expiration = expiration
    }

    /// Envio de SUI tirado da moeda de gas: `SplitCoins(GasCoin, [valor])` e
    /// `TransferObjects([moeda nova], destino)`, com o valor e o destino como entradas
    /// puras, nessa ordem. E o que o SDK oficial monta para
    /// `tx.transferObjects([tx.splitCoins(tx.gas, [valor])], destino)` e o que o
    /// wallet-core monta para um PaySui de um destino.
    public static func payFromGas(
        sender: SuiAddress, recipient: SuiAddress, amount: UInt64, gas: SuiGasData, expiration: SuiExpiration
    ) -> SuiTransactionData {
        SuiTransactionData(
            inputs: [.pure(amount.littleEndianByteArray), .pure(recipient.bytes)],
            commands: [
                .splitCoins(.gasCoin, amounts: [.input(0)]),
                .transferObjects([.nestedResult(0, 0)], to: .input(1)),
            ],
            sender: sender, gas: gas, expiration: expiration
        )
    }

    // MARK: Hashes

    /// O id da transacao: BLAKE2b-256 de "TransactionData::" e dos bytes
    /// (`sui-types`, `TransactionDigest` pelo `Signable` com o nome do tipo).
    public var digest: [UInt8] { Blake2b.hash(Array("TransactionData::".utf8) + bcs(), outputLength: 32) }

    /// O id como o explorador mostra, em base58.
    public var digestBase58: String { Base58.bitcoin.encode(digest) }

    /// O que a chave assina: BLAKE2b-256 da mensagem com intencao
    /// (`IntentMessage { Intent { scope: TransactionData = 0, version: V0 = 0,
    /// app_id: Sui = 0 }, value }`), ou seja, os tres bytes 0 seguidos da transacao.
    public var signingDigest: [UInt8] { Self.signingDigest(of: bcs()) }

    public static func signingDigest(of transactionBytes: [UInt8]) -> [UInt8] {
        Blake2b.hash([0, 0, 0] + transactionBytes, outputLength: 32)
    }

    // MARK: BCS

    public func bcs() -> [UInt8] {
        var w = SuiBCSWriter()
        w.uleb128(0)                        // TransactionData::V1
        w.uleb128(0)                        // TransactionKind::ProgrammableTransaction
        w.uleb128(UInt64(inputs.count))
        for input in inputs {
            switch input {
            case .pure(let value):
                w.uleb128(0)
                w.vector(value)
            case .ownedObject(let ref):
                w.uleb128(1)                // CallArg::Object
                w.uleb128(0)                // ObjectArg::ImmOrOwnedObject
                Self.write(ref, &w)
            }
        }
        w.uleb128(UInt64(commands.count))
        for command in commands {
            switch command {
            case .transferObjects(let objects, let to):
                w.uleb128(1)
                Self.write(objects, &w)
                Self.write(to, &w)
            case .splitCoins(let coin, let amounts):
                w.uleb128(2)
                Self.write(coin, &w)
                Self.write(amounts, &w)
            case .mergeCoins(let coin, let sources):
                w.uleb128(3)
                Self.write(coin, &w)
                Self.write(sources, &w)
            }
        }
        w.fixed(sender.bytes)
        w.uleb128(UInt64(gas.payment.count))
        for ref in gas.payment { Self.write(ref, &w) }
        w.fixed(gas.owner.bytes)
        w.u64(gas.price)
        w.u64(gas.budget)
        switch expiration {
        case .none:
            w.uleb128(0)
        case .epoch(let epoch):
            w.uleb128(1)
            w.u64(epoch)
        }
        return w.bytes
    }

    private static func write(_ ref: SuiObjectRef, _ w: inout SuiBCSWriter) {
        w.fixed(ref.objectID.bytes)
        w.u64(ref.version)
        w.vector(ref.digest)
    }

    private static func write(_ arguments: [SuiArgument], _ w: inout SuiBCSWriter) {
        w.uleb128(UInt64(arguments.count))
        for argument in arguments { write(argument, &w) }
    }

    private static func write(_ argument: SuiArgument, _ w: inout SuiBCSWriter) {
        switch argument {
        case .gasCoin:
            w.uleb128(0)
        case .input(let index):
            w.uleb128(1)
            w.u16(index)
        case .result(let index):
            w.uleb128(2)
            w.u16(index)
        case .nestedResult(let command, let index):
            w.uleb128(3)
            w.u16(command)
            w.u16(index)
        }
    }

    /// Le bytes de uma transacao. So o subconjunto acima; qualquer outra variante e
    /// recusada, e a leitura so vale se a reescrita der os mesmos bytes.
    public static func decode(_ bytes: [UInt8]) throws -> SuiTransactionData {
        var r = SuiBCSReader(bytes)
        do {
            guard try r.uleb128() == 0, try r.uleb128() == 0 else { throw SuiTransactionError.unsupported }
            var inputs: [SuiCallArg] = []
            for _ in 0..<(try r.uleb128()) {
                switch try r.uleb128() {
                case 0:
                    inputs.append(.pure(try r.vector(max: 16 * 1024)))
                case 1:
                    guard try r.uleb128() == 0 else { throw SuiTransactionError.unsupported }
                    inputs.append(.ownedObject(try readRef(&r)))
                default:
                    throw SuiTransactionError.unsupported
                }
            }
            var commands: [SuiCommand] = []
            for _ in 0..<(try r.uleb128()) {
                switch try r.uleb128() {
                case 1:
                    let objects = try readArguments(&r)
                    commands.append(.transferObjects(objects, to: try readArgument(&r)))
                case 2:
                    let coin = try readArgument(&r)
                    commands.append(.splitCoins(coin, amounts: try readArguments(&r)))
                case 3:
                    let coin = try readArgument(&r)
                    commands.append(.mergeCoins(coin, sources: try readArguments(&r)))
                default:
                    throw SuiTransactionError.unsupported
                }
            }
            guard let sender = SuiAddress(bytes: try r.take(32)) else { throw SuiTransactionError.malformed }
            var payment: [SuiObjectRef] = []
            for _ in 0..<(try r.uleb128()) { payment.append(try readRef(&r)) }
            guard let owner = SuiAddress(bytes: try r.take(32)) else { throw SuiTransactionError.malformed }
            let price = try r.u64()
            let budget = try r.u64()
            let expiration: SuiExpiration
            switch try r.uleb128() {
            case 0: expiration = .none
            case 1: expiration = .epoch(try r.u64())
            default: throw SuiTransactionError.unsupported
            }
            try r.finish()
            let data = SuiTransactionData(
                inputs: inputs, commands: commands, sender: sender,
                gas: SuiGasData(payment: payment, owner: owner, price: price, budget: budget), expiration: expiration
            )
            guard data.bcs() == bytes else { throw SuiTransactionError.notCanonical }
            return data
        } catch let error as SuiTransactionError {
            throw error
        } catch {
            throw SuiTransactionError.malformed
        }
    }

    private static func readRef(_ r: inout SuiBCSReader) throws -> SuiObjectRef {
        guard let id = SuiAddress(bytes: try r.take(32)) else { throw SuiTransactionError.malformed }
        let version = try r.u64()
        return try SuiObjectRef(objectID: id, version: version, digest: try r.vector(max: 32))
    }

    private static func readArguments(_ r: inout SuiBCSReader) throws -> [SuiArgument] {
        var out: [SuiArgument] = []
        for _ in 0..<(try r.uleb128()) { out.append(try readArgument(&r)) }
        return out
    }

    private static func readArgument(_ r: inout SuiBCSReader) throws -> SuiArgument {
        switch try r.uleb128() {
        case 0: return .gasCoin
        case 1: return .input(try r.u16())
        case 2: return .result(try r.u16())
        case 3: return .nestedResult(try r.u16(), try r.u16())
        default: throw SuiTransactionError.malformed
        }
    }
}
