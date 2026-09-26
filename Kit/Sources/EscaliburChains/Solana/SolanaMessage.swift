import EscaliburCore
import Foundation

// A mensagem da Solana: o que a assinatura Ed25519 cobre, byte a byte.
//
// Formato legado:
//   header(3) || compact(n) || n chaves de 32 || blockhash(32) || compact(m) || m instrucoes
// Formato v0: o byte 0x80 na frente, a mesma estrutura, e no fim
//   compact(k) || k consultas a tabelas de enderecos (ALT)
// Instrucao compilada:
//   indice do programa(1) || compact(a) || a indices de conta || compact(d) || d bytes
//
// A ordem das chaves e parte do contrato: signatarios gravaveis (o pagador da taxa
// primeiro), signatarios somente leitura, nao signatarios gravaveis, nao
// signatarios somente leitura. O header diz onde cada grupo comeca, e e dele que o
// validador tira quem assina e quem pode ser alterado. Dentro de cada grupo as
// chaves vao em ordem de bytes, como no `CompiledKeys` do solana-sdk.
//
// Fica de fora a tx v1 (prefixo 0x81, ativa desde 15/09/2026): a decodificacao a
// recusa explicitamente em vez de tentar ler como v0.

/// Uma conta referenciada por uma instrucao.
public struct SolanaAccountMeta: Sendable, Equatable {
    public let publicKey: SolanaPublicKey
    public let isSigner: Bool
    public let isWritable: Bool

    public init(_ publicKey: SolanaPublicKey, isSigner: Bool, isWritable: Bool) {
        self.publicKey = publicKey
        self.isSigner = isSigner
        self.isWritable = isWritable
    }
}

/// Uma instrucao antes de compilar: programa, contas com papel, dados.
public struct SolanaInstruction: Sendable, Equatable {
    public let programID: SolanaPublicKey
    public let accounts: [SolanaAccountMeta]
    public let data: [UInt8]

    public init(programID: SolanaPublicKey, accounts: [SolanaAccountMeta], data: [UInt8]) {
        self.programID = programID
        self.accounts = accounts
        self.data = data
    }
}

/// Um hash de bloco recente: 32 bytes em Base58. Ele da validade a transacao
/// (cerca de 150 blocos) e impede que ela seja reexecutada depois.
public struct SolanaBlockhash: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw SolanaPublicKey.Problem.malformed }
        self.bytes = bytes
    }

    public init(base58 text: String) throws {
        guard let raw = Base58.bitcoin.decode(text), raw.count == 32 else { throw SolanaPublicKey.Problem.malformed }
        self.bytes = raw
    }

    public var base58: String { Base58.bitcoin.encode(bytes) }
    public var description: String { base58 }
}

public struct SolanaMessageHeader: Sendable, Equatable {
    public let numRequiredSignatures: UInt8
    public let numReadonlySignedAccounts: UInt8
    public let numReadonlyUnsignedAccounts: UInt8

    public init(numRequiredSignatures: UInt8, numReadonlySignedAccounts: UInt8, numReadonlyUnsignedAccounts: UInt8) {
        self.numRequiredSignatures = numRequiredSignatures
        self.numReadonlySignedAccounts = numReadonlySignedAccounts
        self.numReadonlyUnsignedAccounts = numReadonlyUnsignedAccounts
    }
}

public struct SolanaCompiledInstruction: Sendable, Equatable {
    public let programIDIndex: UInt8
    public let accountIndexes: [UInt8]
    public let data: [UInt8]

    public init(programIDIndex: UInt8, accountIndexes: [UInt8], data: [UInt8]) {
        self.programIDIndex = programIDIndex
        self.accountIndexes = accountIndexes
        self.data = data
    }
}

/// A referencia a uma tabela de enderecos dentro de uma mensagem v0.
public struct SolanaAddressTableLookup: Sendable, Equatable {
    public let tableAddress: SolanaPublicKey
    public let writableIndexes: [UInt8]
    public let readonlyIndexes: [UInt8]

    public init(tableAddress: SolanaPublicKey, writableIndexes: [UInt8], readonlyIndexes: [UInt8]) {
        self.tableAddress = tableAddress
        self.writableIndexes = writableIndexes
        self.readonlyIndexes = readonlyIndexes
    }
}

/// O conteudo de uma tabela de enderecos, lido da cadeia **pelo chamador**. A
/// seguranca (docs/seguranca.md §4.6) pede que venha de dois RPCs e que eles
/// concordem: uma tabela adulterada troca a conta de destino sem mudar um byte da
/// mensagem que o dono assina.
public struct SolanaAddressLookupTable: Sendable, Equatable {
    public let address: SolanaPublicKey
    public let addresses: [SolanaPublicKey]

    public init(address: SolanaPublicKey, addresses: [SolanaPublicKey]) {
        self.address = address
        self.addresses = addresses
    }
}

/// As contas que as tabelas carregam: todas as gravaveis (na ordem das consultas)
/// e depois todas as somente leitura. Os indices das instrucoes contam a partir do
/// fim das chaves estaticas nessa ordem.
public struct SolanaLoadedAddresses: Sendable, Equatable {
    public let writable: [SolanaPublicKey]
    public let readonly: [SolanaPublicKey]

    public init(writable: [SolanaPublicKey], readonly: [SolanaPublicKey]) {
        self.writable = writable
        self.readonly = readonly
    }

    public static let none = SolanaLoadedAddresses(writable: [], readonly: [])
}

public struct SolanaMessage: Sendable, Equatable {
    public enum Version: Sendable, Equatable {
        case legacy
        case v0
    }

    public enum Problem: Error, Equatable, Sendable {
        /// Mais de 256 contas: os indices sao de um byte.
        case tooManyAccounts
        case unknownInstructionKey(SolanaPublicKey)
        case malformed
        /// Mensagem versionada de versao que esta carteira nao le (v1 e adiante).
        case unsupportedVersion(UInt8)
        case trailingBytes
        /// Violacoes das regras de sanidade do validador.
        case headerOutOfBounds
        case noWritableFeePayer
        case programIndexOutOfBounds
        case programIsFeePayer
        case accountIndexOutOfBounds
        case emptyLookup
        case duplicateAccount(SolanaPublicKey)
        /// A tabela citada na mensagem nao foi fornecida, ou o indice passa do fim.
        case missingLookupTable(SolanaPublicKey)
        case lookupIndexOutOfBounds(SolanaPublicKey, UInt8)
        case lookupTablesNotAllowedInLegacy
    }

    public let version: Version
    public let header: SolanaMessageHeader
    public let staticAccountKeys: [SolanaPublicKey]
    public let recentBlockhash: SolanaBlockhash
    public let instructions: [SolanaCompiledInstruction]
    /// Vazio no formato legado.
    public let addressTableLookups: [SolanaAddressTableLookup]

    public init(
        version: Version, header: SolanaMessageHeader, staticAccountKeys: [SolanaPublicKey], recentBlockhash: SolanaBlockhash,
        instructions: [SolanaCompiledInstruction], addressTableLookups: [SolanaAddressTableLookup] = []
    ) throws {
        if version == .legacy, !addressTableLookups.isEmpty { throw Problem.lookupTablesNotAllowedInLegacy }
        self.version = version
        self.header = header
        self.staticAccountKeys = staticAccountKeys
        self.recentBlockhash = recentBlockhash
        self.instructions = instructions
        self.addressTableLookups = addressTableLookups
    }

    /// O pagador da taxa: sempre a primeira chave estatica.
    public var feePayer: SolanaPublicKey? { staticAccountKeys.first }

    // MARK: Compilacao

    /// Compila no formato legado (`Message::new` do solana-sdk).
    public static func compileLegacy(
        payer: SolanaPublicKey, instructions: [SolanaInstruction], recentBlockhash: SolanaBlockhash
    ) throws -> SolanaMessage {
        let keys = CompiledKeys(instructions: instructions, payer: payer)
        let (header, staticKeys) = try keys.messageComponents()
        let compiled = try compileInstructions(instructions, accountKeys: staticKeys)
        return try SolanaMessage(
            version: .legacy, header: header, staticAccountKeys: staticKeys, recentBlockhash: recentBlockhash,
            instructions: compiled
        )
    }

    /// Compila no formato v0 (`v0::Message::try_compile`). As tabelas entram na
    /// ordem dada; de cada uma saem as contas que nao assinam, nao sao programa
    /// invocado e nao sao a conta de nonce. Tabela da qual nada sai nao aparece.
    public static func compileV0(
        payer: SolanaPublicKey, instructions: [SolanaInstruction], recentBlockhash: SolanaBlockhash,
        lookupTables: [SolanaAddressLookupTable] = []
    ) throws -> SolanaMessage {
        var keys = CompiledKeys(instructions: instructions, payer: payer)
        var lookups = [SolanaAddressTableLookup]()
        var loadedWritable = [SolanaPublicKey]()
        var loadedReadonly = [SolanaPublicKey]()
        for table in lookupTables {
            let (writableIndexes, writableKeys) = try keys.drain(from: table.addresses) { meta in
                !meta.isSigner && !meta.isInvoked && !meta.isNonce && meta.isWritable
            }
            let (readonlyIndexes, readonlyKeys) = try keys.drain(from: table.addresses) { meta in
                !meta.isSigner && !meta.isInvoked && !meta.isNonce && !meta.isWritable
            }
            if writableIndexes.isEmpty, readonlyIndexes.isEmpty { continue }
            lookups.append(SolanaAddressTableLookup(tableAddress: table.address, writableIndexes: writableIndexes, readonlyIndexes: readonlyIndexes))
            loadedWritable += writableKeys
            loadedReadonly += readonlyKeys
        }
        let (header, staticKeys) = try keys.messageComponents()
        let allKeys = staticKeys + loadedWritable + loadedReadonly
        guard allKeys.count <= 256 else { throw Problem.tooManyAccounts }
        let compiled = try compileInstructions(instructions, accountKeys: allKeys)
        return try SolanaMessage(
            version: .v0, header: header, staticAccountKeys: staticKeys, recentBlockhash: recentBlockhash,
            instructions: compiled, addressTableLookups: lookups
        )
    }

    private static func compileInstructions(_ instructions: [SolanaInstruction], accountKeys: [SolanaPublicKey]) throws -> [SolanaCompiledInstruction] {
        guard accountKeys.count <= 256 else { throw Problem.tooManyAccounts }
        var position = [SolanaPublicKey: UInt8]()
        for (index, key) in accountKeys.enumerated() where position[key] == nil {
            position[key] = UInt8(index)
        }
        func index(_ key: SolanaPublicKey) throws -> UInt8 {
            guard let found = position[key] else { throw Problem.unknownInstructionKey(key) }
            return found
        }
        return try instructions.map { ix in
            SolanaCompiledInstruction(
                programIDIndex: try index(ix.programID),
                accountIndexes: try ix.accounts.map { try index($0.publicKey) },
                data: ix.data
            )
        }
    }

    // MARK: Serializacao

    /// Os bytes que a assinatura cobre.
    public func serialize() -> [UInt8] {
        var out = [UInt8]()
        if version == .v0 { out.append(0x80) }
        out += [header.numRequiredSignatures, header.numReadonlySignedAccounts, header.numReadonlyUnsignedAccounts]
        out += SolanaShortVec.encode(staticAccountKeys.count)
        for key in staticAccountKeys { out += key.bytes }
        out += recentBlockhash.bytes
        out += SolanaShortVec.encode(instructions.count)
        for ix in instructions {
            out.append(ix.programIDIndex)
            out += SolanaShortVec.encode(ix.accountIndexes.count)
            out += ix.accountIndexes
            out += SolanaShortVec.encode(ix.data.count)
            out += ix.data
        }
        if version == .v0 {
            out += SolanaShortVec.encode(addressTableLookups.count)
            for lookup in addressTableLookups {
                out += lookup.tableAddress.bytes
                out += SolanaShortVec.encode(lookup.writableIndexes.count)
                out += lookup.writableIndexes
                out += SolanaShortVec.encode(lookup.readonlyIndexes.count)
                out += lookup.readonlyIndexes
            }
        }
        return out
    }

    /// Le uma mensagem vinda de fora (de um agregador, por exemplo). So a estrutura:
    /// quem decide se ela pode ser assinada e `sanitize()` e o verificador.
    public static func deserialize(_ bytes: [UInt8]) throws -> SolanaMessage {
        var reader = SolanaByteReader(bytes)
        let message = try read(from: &reader)
        guard reader.isAtEnd else { throw Problem.trailingBytes }
        return message
    }

    static func read(from reader: inout SolanaByteReader) throws -> SolanaMessage {
        do {
            var version = Version.legacy
            guard let first = reader.peek() else { throw Problem.malformed }
            if first & 0x80 != 0 {
                _ = try reader.byte()
                let number = first & 0x7F
                guard number == 0 else { throw Problem.unsupportedVersion(number) }
                version = .v0
            }
            let header = SolanaMessageHeader(
                numRequiredSignatures: try reader.byte(),
                numReadonlySignedAccounts: try reader.byte(),
                numReadonlyUnsignedAccounts: try reader.byte()
            )
            let keyCount = try reader.shortVecLength()
            var keys = [SolanaPublicKey]()
            for _ in 0..<keyCount { keys.append(try SolanaPublicKey(bytes: try reader.take(32))) }
            let blockhash = try SolanaBlockhash(bytes: try reader.take(32))
            let ixCount = try reader.shortVecLength()
            var instructions = [SolanaCompiledInstruction]()
            for _ in 0..<ixCount {
                let program = try reader.byte()
                let accounts = try reader.take(try reader.shortVecLength())
                let data = try reader.take(try reader.shortVecLength())
                instructions.append(SolanaCompiledInstruction(programIDIndex: program, accountIndexes: accounts, data: data))
            }
            var lookups = [SolanaAddressTableLookup]()
            if version == .v0 {
                let lookupCount = try reader.shortVecLength()
                for _ in 0..<lookupCount {
                    let table = try SolanaPublicKey(bytes: try reader.take(32))
                    let writable = try reader.take(try reader.shortVecLength())
                    let readonly = try reader.take(try reader.shortVecLength())
                    lookups.append(SolanaAddressTableLookup(tableAddress: table, writableIndexes: writable, readonlyIndexes: readonly))
                }
            }
            return try SolanaMessage(
                version: version, header: header, staticAccountKeys: keys, recentBlockhash: blockhash,
                instructions: instructions, addressTableLookups: lookups
            )
        } catch let problem as Problem {
            throw problem
        } catch {
            throw Problem.malformed
        }
    }

    // MARK: Sanidade (as regras do validador)

    /// As mesmas conferencias do `sanitize` do solana-sdk (legado e v0), mais a de
    /// conta repetida, que o validador faz ao carregar a transacao. Sem `loaded`, a
    /// repeticao e conferida so entre as chaves estaticas.
    public func sanitize(loaded: SolanaLoadedAddresses? = nil) throws {
        let staticCount = staticAccountKeys.count
        let required = Int(header.numRequiredSignatures)
        guard required + Int(header.numReadonlyUnsignedAccounts) <= staticCount else { throw Problem.headerOutOfBounds }
        // Tem de haver pelo menos um signatario gravavel: o pagador da taxa.
        guard header.numReadonlySignedAccounts < header.numRequiredSignatures else { throw Problem.noWritableFeePayer }
        var dynamicCount = 0
        for lookup in addressTableLookups {
            let count = lookup.writableIndexes.count + lookup.readonlyIndexes.count
            guard count > 0 else { throw Problem.emptyLookup }
            dynamicCount += count
        }
        let total = staticCount + dynamicCount
        guard total <= 256 else { throw Problem.tooManyAccounts }
        for ix in instructions {
            // Programa nunca vem de tabela: precisa estar entre as chaves estaticas.
            guard Int(ix.programIDIndex) < staticCount else { throw Problem.programIndexOutOfBounds }
            guard ix.programIDIndex != 0 else { throw Problem.programIsFeePayer }
            for account in ix.accountIndexes where Int(account) >= total {
                throw Problem.accountIndexOutOfBounds
            }
        }
        var keys = staticAccountKeys
        if let loaded {
            guard loaded.writable.count + loaded.readonly.count == dynamicCount else { throw Problem.malformed }
            keys += loaded.writable + loaded.readonly
        }
        var seen = Set<SolanaPublicKey>()
        for key in keys {
            guard seen.insert(key).inserted else { throw Problem.duplicateAccount(key) }
        }
    }

    // MARK: Contas

    /// Resolve as consultas a tabelas com o conteudo que o chamador leu da cadeia.
    public func resolveLookups(_ tables: [SolanaAddressLookupTable]) throws -> SolanaLoadedAddresses {
        var writable = [SolanaPublicKey]()
        var readonly = [SolanaPublicKey]()
        for lookup in addressTableLookups {
            guard let table = tables.first(where: { $0.address == lookup.tableAddress }) else {
                throw Problem.missingLookupTable(lookup.tableAddress)
            }
            for index in lookup.writableIndexes {
                guard Int(index) < table.addresses.count else { throw Problem.lookupIndexOutOfBounds(table.address, index) }
                writable.append(table.addresses[Int(index)])
            }
            for index in lookup.readonlyIndexes {
                guard Int(index) < table.addresses.count else { throw Problem.lookupIndexOutOfBounds(table.address, index) }
                readonly.append(table.addresses[Int(index)])
            }
        }
        return SolanaLoadedAddresses(writable: writable, readonly: readonly)
    }

    /// Todas as contas na ordem dos indices: estaticas, carregadas gravaveis,
    /// carregadas somente leitura.
    public func accountKeys(loaded: SolanaLoadedAddresses = .none) -> [SolanaPublicKey] {
        staticAccountKeys + loaded.writable + loaded.readonly
    }

    public func isSigner(index: Int) -> Bool {
        index < Int(header.numRequiredSignatures)
    }

    /// Gravabilidade pela posicao, como o header e as tabelas a declaram. O
    /// validador ainda rebaixa programas invocados e contas reservadas para
    /// somente leitura; aqui vale a declaracao, que e o que um atacante controla.
    public func isWritable(index: Int, loaded: SolanaLoadedAddresses = .none) -> Bool {
        let staticCount = staticAccountKeys.count
        let required = Int(header.numRequiredSignatures)
        if index < required {
            return index < required - Int(header.numReadonlySignedAccounts)
        }
        if index < staticCount {
            return index < staticCount - Int(header.numReadonlyUnsignedAccounts)
        }
        return index - staticCount < loaded.writable.count
    }
}

// MARK: Chaves compiladas

/// O papel acumulado de cada conta, como o `CompiledKeys` do solana-sdk.
private struct CompiledKeys {
    struct Meta {
        var isSigner = false
        var isWritable = false
        var isInvoked = false
        var isNonce = false
    }

    let payer: SolanaPublicKey
    var metas: [SolanaPublicKey: Meta]

    init(instructions: [SolanaInstruction], payer: SolanaPublicKey) {
        var metas = [SolanaPublicKey: Meta]()
        for ix in instructions {
            metas[ix.programID, default: Meta()].isInvoked = true
            for account in ix.accounts {
                metas[account.publicKey, default: Meta()].isSigner = metas[account.publicKey, default: Meta()].isSigner || account.isSigner
                metas[account.publicKey, default: Meta()].isWritable = metas[account.publicKey, default: Meta()].isWritable || account.isWritable
            }
        }
        // Nonce duravel: a conta de nonce da primeira instrucao fica fora das tabelas.
        if let first = instructions.first, first.programID == SolanaProgramID.system,
           first.data.count >= 4, Array(first.data.prefix(4)) == [4, 0, 0, 0],
           let nonce = first.accounts.first {
            metas[nonce.publicKey, default: Meta()].isNonce = true
        }
        metas[payer, default: Meta()].isSigner = true
        metas[payer, default: Meta()].isWritable = true
        self.payer = payer
        self.metas = metas
    }

    /// Chaves ordenadas por bytes que passam no filtro, sem o pagador.
    func keys(where filter: (Meta) -> Bool) -> [SolanaPublicKey] {
        metas.filter { $0.key != payer && filter($0.value) }.map(\.key).sorted()
    }

    func messageComponents() throws -> (SolanaMessageHeader, [SolanaPublicKey]) {
        let writableSigners = [payer] + keys { $0.isSigner && $0.isWritable }
        let readonlySigners = keys { $0.isSigner && !$0.isWritable }
        let writableNonSigners = keys { !$0.isSigner && $0.isWritable }
        let readonlyNonSigners = keys { !$0.isSigner && !$0.isWritable }
        let all = writableSigners + readonlySigners + writableNonSigners + readonlyNonSigners
        let signers = writableSigners.count + readonlySigners.count
        guard all.count <= 256, signers <= 255, readonlyNonSigners.count <= 255 else {
            throw SolanaMessage.Problem.tooManyAccounts
        }
        let header = SolanaMessageHeader(
            numRequiredSignatures: UInt8(signers),
            numReadonlySignedAccounts: UInt8(readonlySigners.count),
            numReadonlyUnsignedAccounts: UInt8(readonlyNonSigners.count)
        )
        return (header, all)
    }

    /// Tira da lista as chaves que a tabela contem e passam no filtro, devolvendo
    /// os indices na tabela (a primeira ocorrencia) e as chaves, na ordem de bytes.
    mutating func drain(from table: [SolanaPublicKey], where filter: (Meta) -> Bool) throws -> ([UInt8], [SolanaPublicKey]) {
        var indexes = [UInt8]()
        var drained = [SolanaPublicKey]()
        for key in keys(where: filter) {
            guard let position = table.firstIndex(of: key) else { continue }
            guard position <= Int(UInt8.max) else { throw SolanaMessage.Problem.tooManyAccounts }
            indexes.append(UInt8(position))
            drained.append(key)
        }
        for key in drained { metas.removeValue(forKey: key) }
        return (indexes, drained)
    }
}
