import Foundation
import Testing
@testable import EscaliburChains
@testable import EscaliburCore

/// Transacoes reais aceitas pela rede principal da Cardano, lidas pelo `tx_cbor` da Koios
/// em 27/09/2026 e conferidas no `tx_info` (entradas, enderecos, taxa, bloco). Tres
/// formatos: conjuntos com a tag 258 (Conway) e sem ela, uma e duas entradas, com e sem
/// troco. O id de cada uma e o hash do corpo relido aqui, e a assinatura verifica.
enum CardanoRealTransactions {
    struct Vector {
        let id: String
        let cbor: String
        /// Endereco das entradas (todas do mesmo dono) e chave publica da testemunha.
        let inputAddress: String
        let block: UInt64
    }

    /// Bloco 13.997.279: uma entrada de 999.822.399, duas saidas base, tag 258.
    static let withChange = Vector(
        id: "d8da3593663c88b2aa46dc27f7bcb8cef20bc86f7e456b43e467674fe6889c3a",
        cbor: "84a400d9010281825820167d2716707f45cc00d4ba7086bcd8fba87798f6c240df667eb8be4f46462d770001828258390128caffe80c22a311396ae276ecda15fbf25ebd248e416da4a7d1f1ead6f178d9c364bc7708deaa011061f8705374549f03b0ff56aad991fc1a1c4fecc08258390175ff736277d74c545cbbf6b195a1cca497baaa984aa12723925c944a3771f91d1c5fdd859d60109540760e46721fe0a7be9cec6995fb37c81a1f4594fa021a00029285031a0bdc889ca100d9010281825820553b50e5fa0eb4235549af74117451b42bfc4eac182525ed4ad187e4849d132158407aa2c1cea05ca546b7a1f5f9c3789c6971a8fad4c849d3f2f51ead1fc0843f24e3671f3a319c8b70886e757f2aeb1df6ea8bddbed3dc768c25e2754e409cfb0ff5f6",
        inputAddress: "addr1qyxwr37rh2v8rwx5u2agl3rn6pca8hpl85wxmzugsrkxk33hw8u368zlmkze6cqsj4q8vrjxwg07pfa7nnkxn90mxlyqkzcp2q",
        block: 13_997_279
    )

    /// Bloco 13.997.301: formato sem a tag 258, uma entrada, uma saida.
    static let untagged = Vector(
        id: "71fcd8583c44f5e94243f81bb9498d6479c311faf864e86ddd1653061619b6e5",
        cbor: "84a400818258201159b3b890643a4838754419d96797504748b596ab2636fbe179235ef9d0c8df000181825839010d93d40a3b055fb9c61c24aba4b8a11907084702d599565ac48e4226cc552eaa4d8ce0b0e674a2f32096094ef8c3b433b8ecd1ca9e7c98301a1191e7dc021a00028f04031a0bdc7cbda100818258202cfe7dc06bc2693c82924eba788fd107db77b7af8863e4b5b2e764c608ac51fe5840fe2fa453011406f3f0b812e9ff9c1901f4c02ec81748f84151acad220438ec65b89c1f415cec8c70857730da2712d9b8aea438cd76cc40b6a272558b72ff0004f5f6",
        inputAddress: "addr1qythw04n268ywgxrrd6f0fy0m8q4en67nsyd6527k9dhc3v7wxlnu5jq4rlj5kmuvs4sddzwuzwpcmfamldnaul4sxwshyqlvg",
        block: 13_997_301
    )

    /// Bloco 13.997.301: duas entradas do mesmo endereco, tudo numa saida so, tag 258. A
    /// taxa e exatamente a minima pela conta da transacao inteira.
    static let sweep = Vector(
        id: "1497077d89a9b0e6fe31bda8de945fbca5cf06cdf6ea067e13e450e8949dd499",
        cbor: "84a400d9010282825820a797b2caa21ca44328b5edc2d81f3de51ed4e260fa6aa224134f5eb1dbd7e71300825820fbf2df72ca415eb34ba2d5296653a2edc266e25cbe86c6087c7a1849d3c7cec800018182583901c22fa01d4946aee587b7a5dccd4979cbfdc49765bdbe6cd9bc4f3d96c22fa01d4946aee587b7a5dccd4979cbfdc49765bdbe6cd9bc4f3d961b0000000412f3bcf7021a00028d89031a7fffffffa100d9010281825820d0b0d7720c0e51e7fac3ccd653017147dadc9d954e9d05322ffc3a474a475b975840db8229fca2c23957f06a3fea9816722a1304dc05c1d434784006a2e1590241c58747e88ae5d1678ed960a531f75bacafdd607d6136f9a50fec4d40fcc849ff0af5f6",
        inputAddress: "addr1q9l2kye3nkmf6aw39mu8denl8ahyzt44rgx2svz8qw68jun74vfnr8dkn46azthcwmn870mwgyht2xsv4qcywqa509eqc5r4hd",
        block: 13_997_301
    )

    static let all = [withChange, untagged, sweep]

    /// Parametros da rede principal em 27/09/2026 (Koios `cli_protocol_params` e Yoroi
    /// `protocolparameters`, protocolo 11.0).
    static let parameters = CardanoProtocolParameters(minFeeA: 44, minFeeB: 155_381, coinsPerUTxOByte: 4_310, maxTxSize: 16_384)
}

@Suite("Cardano: CBOR e transacoes reais")
struct CardanoTransactionTests {
    @Test("Transacoes reais: releitura byte a byte, id, assinatura e dono", arguments: CardanoRealTransactions.all.indices)
    func realTransactions(index: Int) throws {
        let vector = CardanoRealTransactions.all[index]
        let bytes = try #require(Hex.decode(vector.cbor))
        let parsed = try CardanoSignedTransaction.parse(bytes)
        #expect(parsed.bytes == bytes)
        #expect(Hex.encode(parsed.body.hash) == vector.id)
        #expect(parsed.signaturesVerify)
        let witness = try #require(parsed.witnesses.first)
        guard case .success(let owner) = CardanoAddress.parse(vector.inputAddress) else { Issue.record("endereco"); return }
        #expect(owner.paymentHash == CardanoAddress.keyHash(witness.publicKey))

        // A taxa paga cobre a minima, e cada saida o minimo de ADA.
        let minimum = CardanoPlanner.minimumFee(size: bytes.count, CardanoRealTransactions.parameters)
        #expect(parsed.body.fee >= minimum)
        #expect(CardanoPlanner.signedSize(parsed.body) == bytes.count)
        for output in parsed.body.outputs {
            #expect(output.lovelace >= CardanoPlanner.minimumCoin(output, CardanoRealTransactions.parameters))
        }
    }

    @Test("A taxa de uma transacao real e exatamente a formula (min_fee_a x tamanho + min_fee_b)")
    func exactFee() throws {
        let bytes = try #require(Hex.decode(CardanoRealTransactions.sweep.cbor))
        let parsed = try CardanoSignedTransaction.parse(bytes)
        #expect(bytes.count == 271)
        #expect(parsed.body.fee == 167_305)
        #expect(CardanoPlanner.minimumFee(size: bytes.count, CardanoRealTransactions.parameters) == 167_305)
    }

    @Test("Os dois formatos de conjunto: com a tag 258 e sem ela")
    func setFormats() throws {
        let tagged = try CardanoSignedTransaction.parse(Hex.decode(CardanoRealTransactions.withChange.cbor)!)
        let plain = try CardanoSignedTransaction.parse(Hex.decode(CardanoRealTransactions.untagged.cbor)!)
        #expect(tagged.body.taggedSets)
        #expect(!plain.body.taggedSets)
        #expect(tagged.body.bytes.starts(with: [0xA4, 0x00, 0xD9, 0x01, 0x02]))
        #expect(plain.body.bytes.starts(with: [0xA4, 0x00, 0x81]))
    }

    @Test("Transacao alterada ou com campo a mais e recusada")
    func strictParse() throws {
        var bytes = try #require(Hex.decode(CardanoRealTransactions.untagged.cbor))
        // Metadados no lugar do null.
        bytes[bytes.count - 1] = 0xA0
        #expect(throws: CardanoTransactionBody.ParseError.self) { try CardanoSignedTransaction.parse(bytes) }
        // Um byte a mais no fim.
        #expect(throws: CardanoTransactionBody.ParseError.self) {
            try CardanoSignedTransaction.parse(Hex.decode(CardanoRealTransactions.untagged.cbor)! + [0x00])
        }
        // Assinatura trocada: rele, mas nao verifica.
        var forged = try #require(Hex.decode(CardanoRealTransactions.untagged.cbor))
        forged[forged.count - 5] ^= 0x01
        #expect(!(try CardanoSignedTransaction.parse(forged)).signaturesVerify)
    }

    @Test("CBOR: cabecalho mais curto na escrita, forma canonica exigida na leitura")
    func cbor() throws {
        let cases: [(UInt64, String)] = [
            (0, "00"), (23, "17"), (24, "1818"), (255, "18ff"), (256, "190100"), (65_535, "19ffff"),
            (65_536, "1a00010000"), (4_294_967_295, "1affffffff"), (4_294_967_296, "1b0000000100000000"),
        ]
        for (value, hex) in cases {
            #expect(Hex.encode(CBOR.unsigned(value).encoded) == hex)
            #expect(try CBOR.decode(Hex.decode(hex)!) == .unsigned(value))
        }
        #expect(Hex.encode(CBOR.tag(258, .array([])).encoded) == "d9010280")
        #expect(throws: CBOR.DecodingError.nonCanonical) { try CBOR.decode([0x18, 0x17]) }
        #expect(throws: CBOR.DecodingError.unsupported) { try CBOR.decode([0x9F, 0x00, 0xFF]) }
        #expect(throws: CBOR.DecodingError.unsupported) { try CBOR.decode([0x20]) }
        #expect(throws: CBOR.DecodingError.trailingBytes) { try CBOR.decode([0x00, 0x00]) }
        #expect(throws: CBOR.DecodingError.truncated) { try CBOR.decode([0x58, 0x20, 0x00]) }
    }

    @Test("Montagem: assinatura sobre o id, conferida antes de sair")
    func assemble() throws {
        // Chave de teste: kL e kR da semente do TEST 1 da RFC 8032.
        var digest = Hash.sha512(Hex.decode("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")!)
        digest[0] &= 248
        digest[31] &= 127
        digest[31] |= 64
        let key = SecureBytes(capacity: 64)
        key.replaceAll(with: digest)
        defer { key.wipe() }
        let publicKey = try Ed25519.publicKey(extendedKey: key)

        let real = try CardanoSignedTransaction.parse(Hex.decode(CardanoRealTransactions.withChange.cbor)!)
        let transfer = CardanoTransfer(body: real.body, path: DerivationPath("m/1852'/1815'/0'/0/0")!, publicKey: publicKey)
        let request = try #require(transfer.signingRequests.first)
        #expect(transfer.signingRequests.count == 1)
        #expect(request.scheme == .ed25519Cardano)
        #expect(request.curve == .ed25519)
        #expect(request.payload == real.body.hash)
        #expect(request.expectedPublicKey == publicKey)

        let signature = try Ed25519.signExtended(request.payload, extendedKey: key)
        let signed = try transfer.assemble(with: [ProducedSignature(bytes: signature)])
        #expect(signed.id == CardanoRealTransactions.withChange.id)
        #expect(signed.chainID == "cardano")
        let reread = try CardanoSignedTransaction.parse(signed.raw)
        #expect(reread.body == real.body)
        #expect(reread.signaturesVerify)

        var bad = signature
        bad[10] ^= 1
        #expect(throws: SigningError.malformedSignature) { try transfer.assemble(with: [ProducedSignature(bytes: bad)]) }
        #expect(throws: SigningError.wrongSignatureCount) { try transfer.assemble(with: []) }
    }
}
