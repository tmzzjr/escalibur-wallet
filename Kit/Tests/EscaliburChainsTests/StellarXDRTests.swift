import EscaliburCore
import Foundation
import Testing
@testable import EscaliburChains

@Suite("Stellar XDR, hash e assinatura")
struct StellarXDRTests {

    @Test("networkId da rede principal e o SHA-256 da passphrase compilada")
    func networkID() {
        #expect(StellarNetwork.passphrase == "Public Global Stellar Network ; September 2015")
        #expect(Hex.encode(StellarNetwork.networkID) == "7ac33997544e3175d266bd022439b22cdb16508c01163f26e5cb2a3e1045a979")
    }

    // MARK: js-stellar-base

    @Test("js-stellar-base: envelopes da rede principal, hash e assinatura")
    func jsStellarBase() throws {
        let fixtures = try StellarFixtures.load()
        #expect(fixtures.jsStellarBase.count == 3)
        for vector in fixtures.jsStellarBase {
            #expect(vector.rede == "public")
            let raw = try StellarTestKeys.bytes(base64: vector.envelope)
            let envelope = try StellarEnvelope.decode(raw)
            // Decodificar e codificar devolve os mesmos bytes: nenhuma grafia alternativa.
            #expect(envelope.xdr == raw, "\(vector.nome)")
            #expect(envelope.base64 == vector.envelope)
            if let hash = vector.hash {
                #expect(Hex.encode(envelope.hash) == hash, "\(vector.nome)")
            }
            // A assinatura do vetor verifica sobre o hash calculado aqui, na rede
            // principal: se o payload estivesse errado em um bit, nao verificaria.
            try expectSignedBySource(envelope, hash: envelope.hash, vector.nome)
        }

        // Os detalhes que cada vetor existe para pegar.
        let nonUTF8 = try StellarEnvelope.decode(base64: fixtures.jsStellarBase[0].envelope)
        #expect(nonUTF8.isLegacyV0)
        #expect(nonUTF8.tx.memo == .text([0xd1]))
        #expect(nonUTF8.tx.memo.reviewValue == "hex d1")

        let offer = try StellarEnvelope.decode(base64: fixtures.jsStellarBase[1].envelope)
        guard case let .manageSellOffer(selling, buying, _, _, _) = offer.tx.operations[0].body else {
            Issue.record("esperava ManageSellOffer")
            return
        }
        #expect(selling.isNative)
        #expect(buying.code == "EUR")

        let withOpSource = try StellarEnvelope.decode(base64: fixtures.jsStellarBase[2].envelope)
        #expect(!withOpSource.isLegacyV0)
        #expect(withOpSource.tx.operations[0].source == withOpSource.tx.source)
        #expect(withOpSource.tx.memo == .text(Array("3".utf8)))
    }

    @Test("js-stellar-base: AccountMerge e fee bump sao recusados na leitura")
    func jsStellarBaseRefused() throws {
        let fixtures = try StellarFixtures.load()
        for vector in fixtures.jsStellarBaseRecusados {
            let raw = try StellarTestKeys.bytes(base64: vector.envelope)
            switch vector.motivo {
            case "forbiddenOperation":
                #expect(throws: StellarXDRError.forbiddenOperation("AccountMerge")) { try StellarEnvelope.decode(raw) }
            default:
                #expect(throws: StellarXDRError.unsupported("fee bump")) { try StellarEnvelope.decode(raw) }
            }
        }
    }

    // MARK: go-stellar-sdk

    /// Monta a transacao do vetor a partir das mesmas entradas do teste em Go e
    /// confere o envelope inteiro, byte a byte, usando a assinatura do vetor (o Go
    /// assina de forma deterministica). Depois assina de novo com o CryptoKit, que
    /// e aleatorizado, e confere pela verificacao.
    @Test("go-stellar-sdk: CreateAccount, Payment, muxed, ChangeTrust, ManageSellOffer e PathPayment")
    func goStellarSdk() throws {
        let fixtures = try StellarFixtures.load()
        let kp0 = try StellarTestKeys.account(StellarTestKeys.goAccount0)
        let kp1 = try StellarTestKeys.account(StellarTestKeys.goAccount1)
        let kp2 = try StellarTestKeys.account(StellarTestKeys.goAccount2)
        let abcd0 = try StellarAsset(code: "ABCD", issuer: kp0)
        let abcd1 = try StellarAsset(code: "ABCD", issuer: kp1)
        let xlm = BigUInt(10_000_000)

        struct Case {
            let name: String
            let secret: String
            let source: StellarMuxedAccount
            let sequence: Int64
            let operation: StellarOperation
        }
        // Precos 0.01 e 0.02 do Go saem daqui pela mesma conta que o planejamento
        // faz: recebe / vende.
        let price001 = try StellarPrice.atLeast(receive: xlm, forSelling: xlm * 100)
        let price002 = try StellarPrice.atLeast(receive: xlm, forSelling: xlm * 50)
        #expect(price001 == StellarPrice(n: 1, d: 100))
        #expect(price002 == StellarPrice(n: 1, d: 50))

        let muxedSource = StellarMuxedAccount(account: kp0, id: 0xcafe_babe)
        let cases: [Case] = [
            Case(name: "TestCreateAccount", secret: StellarTestKeys.goSecret0, source: .init(account: kp0),
                 sequence: 9_605_939_170_639_897 + 1,
                 operation: StellarOperation(.createAccount(
                     destination: try StellarTestKeys.account("GCCOBXW2XQNUSL467IEILE6MMCNRR66SSVL4YQADUNYYNUVREF3FIV2Z"),
                     startingBalance: 100_000_000))),
            Case(name: "TestPayment", secret: StellarTestKeys.goSecret0, source: .init(account: kp0),
                 sequence: 9_605_939_170_639_898 + 1,
                 operation: StellarOperation(.payment(destination: .init(account: kp2), asset: .native, amount: 100_000_000))),
            Case(name: "TestPaymentMuxedAccounts", secret: StellarTestKeys.goSecret0, source: muxedSource,
                 sequence: 9_605_939_170_639_898 + 1,
                 operation: StellarOperation(
                     .payment(destination: try StellarTestKeys.muxed("MA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVAAAAAAAAAAAAAJLK"),
                              asset: .native, amount: 100_000_000),
                     source: muxedSource)),
            Case(name: "TestChangeTrust", secret: StellarTestKeys.goSecret0, source: .init(account: kp0),
                 sequence: 40_385_577_484_348 + 1,
                 operation: StellarOperation(.changeTrust(asset: abcd1, limit: 100_000_000))),
            Case(name: "TestChangeTrustDeleteTrustline", secret: StellarTestKeys.goSecret0, source: .init(account: kp0),
                 sequence: 40_385_577_484_354 + 1,
                 operation: StellarOperation(.changeTrust(asset: abcd1, limit: 0))),
            Case(name: "TestChangeTrustMaxLimit", secret: StellarTestKeys.goSecret0, source: .init(account: kp0),
                 sequence: 9_605_939_170_639_898 + 1,
                 operation: StellarOperation(.changeTrust(asset: abcd0, limit: StellarLimits.trustlineLimit))),
            Case(name: "TestManageSellOfferNewOffer", secret: StellarTestKeys.goSecret1, source: .init(account: kp1),
                 sequence: 41_137_196_761_092 + 1,
                 operation: StellarOperation(.manageSellOffer(selling: .native, buying: abcd0, amount: 1_000_000_000, price: price001, offerID: 0))),
            Case(name: "TestManageSellOfferDeleteOffer", secret: StellarTestKeys.goSecret1, source: .init(account: kp1),
                 sequence: 41_137_196_761_105 + 1,
                 operation: StellarOperation(.manageSellOffer(
                     selling: .native,
                     buying: try StellarAsset(code: "FAKE", issuer: "GBAQPADEYSKYMYXTMASBUIS5JI3LMOAWSTM2CHGDBJ3QDDPNCSO3DVAA"),
                     amount: 0, price: StellarPrice(n: 1, d: 1), offerID: 2_921_622))),
            Case(name: "TestManageSellOfferUpdateOffer", secret: StellarTestKeys.goSecret1, source: .init(account: kp1),
                 sequence: 41_137_196_761_097 + 1,
                 operation: StellarOperation(.manageSellOffer(selling: .native, buying: abcd0, amount: 500_000_000, price: price002, offerID: 2_497_628))),
            Case(name: "TestPathPayment", secret: StellarTestKeys.goSecret2, source: .init(account: kp2),
                 sequence: 187_316_408_680_450 + 1,
                 operation: StellarOperation(.pathPaymentStrictReceive(
                     sendAsset: .native, sendMax: 100_000_000, destination: .init(account: kp2),
                     destAsset: .native, destAmount: 10_000_000, path: [abcd0]))),
        ]

        for item in cases {
            let vector = try #require(fixtures.goStellarSdk[item.name], "\(item.name)")
            #expect(vector.rede == "testnet")
            let expected = try StellarTestKeys.bytes(base64: vector.envelope)
            let tx = try StellarTx(
                source: item.source, fee: 100, sequence: item.sequence,
                timeBounds: StellarTimeBounds(minTime: 0, maxTime: 0), memo: .none, operations: [item.operation]
            )
            let seed = try StellarTestKeys.seed(item.secret)
            let signer = try StellarAccountID(publicKey: try Ed25519.publicKey(of: seed))
            #expect(signer == item.source.account)
            let transaction = StellarTransaction(
                tx: tx, path: DefaultPaths.path(for: .stellar), signer: signer, networkID: StellarTestKeys.testnetID
            )

            // O payload assinado, recalculado aqui de forma independente.
            let payload = StellarTestKeys.testnetID + [0, 0, 0, 2] + tx.xdr
            #expect(transaction.signingRequests.count == 1)
            #expect(transaction.signingRequests[0].payload == Hash.sha256(payload), "\(item.name)")
            #expect(transaction.signingRequests[0].expectedPublicKey == signer.publicKey)
            #expect(transaction.signingRequests[0].scheme == .ed25519)

            // Envelope inteiro igual ao do Go, com a assinatura do vetor.
            let vectorSignature = Array(expected.suffix(64))
            let assembled = try transaction.assemble(with: [ProducedSignature(bytes: vectorSignature)])
            #expect(assembled.raw == expected, "\(item.name)")
            #expect(assembled.encoded == vector.envelope, "\(item.name)")
            #expect(assembled.id == Hex.encode(Hash.sha256(payload)))

            // E a leitura devolve a mesma transacao.
            let decoded = try StellarEnvelope.decode(expected)
            #expect(decoded.tx == tx, "\(item.name)")

            // Ponta a ponta com o CryptoKit (aleatorizado): compara pela verificacao.
            let signature = try Ed25519.sign(transaction.signingRequests[0].payload, seed: seed)
            let signed = try transaction.assemble(with: [ProducedSignature(bytes: signature)])
            #expect(Array(signed.raw.dropLast(64)) == Array(expected.dropLast(64)))
        }
    }

    // MARK: Rede principal

    @Test("Rede principal: hash = id da rede, bytes identicos, assinatura da origem")
    func mainnet() throws {
        let fixtures = try StellarFixtures.load()
        var kinds = Set<String>()
        var alphanum12 = false
        var memoTypes = Set<String>()
        for vector in fixtures.mainnet {
            let raw = try StellarTestKeys.bytes(base64: vector.envelope)
            if vector.nota != nil {
                // payment|memo_id usa PRECOND_V2, que a carteira nao monta nem aceita.
                #expect(throws: StellarXDRError.unsupported("precondicoes V2")) { try StellarEnvelope.decode(raw) }
                continue
            }
            let envelope = try StellarEnvelope.decode(raw)
            #expect(envelope.xdr == raw, "\(vector.nome)")
            #expect(Hex.encode(envelope.hash) == vector.hash, "\(vector.nome)")
            // Multi-assinatura sem a chave de origem (payment|a12|memo_text) fica so no hash.
            if envelope.signatures.contains(where: { $0.hint == Array(envelope.tx.source.account.publicKey.suffix(4)) }) {
                try expectSignedBySource(envelope, hash: envelope.hash, vector.nome)
            }

            for operation in envelope.tx.operations {
                switch operation.body {
                case .createAccount: kinds.insert("createAccount")
                case .payment(_, let asset, _):
                    kinds.insert("payment")
                    if asset.code.utf8.count > 4 { alphanum12 = true }
                case .pathPaymentStrictReceive: kinds.insert("pathPaymentStrictReceive")
                case .pathPaymentStrictSend: kinds.insert("pathPaymentStrictSend")
                case .manageSellOffer(let selling, let buying, _, _, _):
                    kinds.insert("manageSellOffer")
                    if selling.code.utf8.count > 4 || buying.code.utf8.count > 4 { alphanum12 = true }
                case .changeTrust(let asset, _):
                    kinds.insert("changeTrust")
                    if asset.code.utf8.count > 4 { alphanum12 = true }
                }
            }
            switch envelope.tx.memo {
            case .text: memoTypes.insert("text")
            case .hash: memoTypes.insert("hash")
            default: break
            }

            if let muxed = vector.muxedDestino {
                // O pagamento muxed real: no XDR o id vem antes da chave; na StrKey,
                // depois. Os dois lados tem de apontar para o mesmo cliente.
                let payment = envelope.tx.operations.compactMap { operation -> StellarMuxedAccount? in
                    if case let .payment(destination, _, _) = operation.body { return destination }
                    return nil
                }.first
                let destination = try #require(payment)
                #expect(destination.id == UInt64(muxed.id))
                #expect(destination.account.address == muxed.base)
                #expect(destination.address == muxed.strkey)
                #expect(StellarMuxedAccount(address: muxed.strkey) == destination)
            }
        }
        #expect(kinds == ["createAccount", "payment", "pathPaymentStrictReceive", "pathPaymentStrictSend", "manageSellOffer", "changeTrust"])
        #expect(alphanum12)
        #expect(memoTypes == ["text", "hash"])
    }

    // MARK: Leitura estrita

    @Test("Leitura estrita: bytes sobrando, preenchimento, truncado, SetOptions")
    func strictDecoding() throws {
        let fixtures = try StellarFixtures.load()
        let raw = try StellarTestKeys.bytes(base64: try #require(fixtures.goStellarSdk["TestPayment"]).envelope)
        #expect(throws: StellarXDRError.trailingBytes) { try StellarEnvelope.decode(raw + [0, 0, 0, 0]) }
        #expect(throws: StellarXDRError.truncated) { try StellarEnvelope.decode(Array(raw.dropLast(1))) }

        // Memo de texto com preenchimento sujo: "Twas brillig" tem 12 bytes, sem
        // preenchimento; "3" do js-stellar-sdk#646 tem 3 bytes de preenchimento.
        let opSource = try StellarTestKeys.bytes(base64: fixtures.jsStellarBase[2].envelope)
        var dirty = opSource
        let memoText = 4 + 36 + 4 + 8 + 4 + 4  // tipo, conta, taxa, sequence, precondicao NONE, tipo do memo
        #expect(Array(dirty[memoText..<memoText + 8]) == [0, 0, 0, 1, 0x33, 0, 0, 0])
        dirty[memoText + 5] = 1
        #expect(throws: StellarXDRError.nonZeroPadding) { try StellarEnvelope.decode(dirty) }

        // SetOptions (tipo 5) no lugar do Payment (tipo 1) do mesmo envelope.
        var setOptions = raw
        let operationType = 4 + 36 + 4 + 8 + 4 + 16 + 4 + 4 + 4  // ... memo NONE, 1 operacao, sem fonte
        #expect(Array(setOptions[operationType..<operationType + 4]) == [0, 0, 0, 1])
        setOptions[operationType + 3] = 5
        #expect(throws: StellarXDRError.forbiddenOperation("SetOptions")) { try StellarEnvelope.decode(setOptions) }
    }

    @Test("Montagem recusa assinatura de outra chave e contagem errada")
    func assembleRejects() throws {
        let fixtures = try StellarFixtures.load()
        let envelope = try StellarEnvelope.decode(base64: try #require(fixtures.goStellarSdk["TestPayment"]).envelope)
        let seed = try StellarTestKeys.seed(StellarTestKeys.goSecret0)
        let signer = try StellarAccountID(publicKey: try Ed25519.publicKey(of: seed))
        let transaction = StellarTransaction(
            tx: envelope.tx, path: DefaultPaths.path(for: .stellar), signer: signer, networkID: StellarTestKeys.testnetID
        )
        // Assinatura valida, mas da chave errada.
        let otherSeed = try StellarTestKeys.seed(StellarTestKeys.goSecret1)
        let wrong = try Ed25519.sign(transaction.hash, seed: otherSeed)
        #expect(throws: SigningError.malformedSignature) { try transaction.assemble(with: [ProducedSignature(bytes: wrong)]) }
        // Assinatura sobre o hash da rede principal nao vale na testnet (e vice-versa).
        let mainnetSignature = try Ed25519.sign(envelope.tx.hash(networkID: StellarNetwork.networkID), seed: seed)
        #expect(throws: SigningError.malformedSignature) { try transaction.assemble(with: [ProducedSignature(bytes: mainnetSignature)]) }
        #expect(throws: SigningError.wrongSignatureCount) { try transaction.assemble(with: []) }
        let right = try Ed25519.sign(transaction.hash, seed: seed)
        #expect(throws: SigningError.wrongSignatureCount) {
            try transaction.assemble(with: [ProducedSignature(bytes: right), ProducedSignature(bytes: right)])
        }
    }

    // MARK: Auxiliares

    private func expectSignedBySource(_ envelope: StellarEnvelope, hash: [UInt8], _ name: String) throws {
        let key = envelope.tx.source.account.publicKey
        let hint = Array(key.suffix(4))
        let signature = try #require(envelope.signatures.first { $0.hint == hint }, "\(name): sem assinatura da origem")
        #expect(Ed25519.verify(signature: signature.signature, message: hash, publicKey: key), "\(name)")
    }
}
