import EscaliburChains
import EscaliburCore
import Foundation
import Testing
@testable import EscaliburWallet

/// Com um desafio do destino na tela, o campo do endereco colado some: a resposta (o fim do
/// ID de um M, o trecho escondido) se leria nele. "Editar" desfaz o desafio e devolve o
/// campo, vazio (segunda revisao dos enderecos parecidos).
@MainActor
struct SendChallengeTests {
    static let wallet: WalletMeta = {
        let account = DerivedAccount(chainID: "stellar", path: DefaultPaths.path(for: .stellar),
                                     address: "GA7QYNF7SOWQ3GLR2BGMZEHXAVIRZA4KVWLTJJFC7MGXUA74P7UJVSGZ", publicKey: [UInt8](repeating: 2, count: 32), accountXPub: nil)
        return WalletMeta(id: UUID(), name: "Teste", kind: .phrase(wordCount: 12), origin: .created, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                          accounts: [account], fingerprint: nil, hasPassphrase: false)
    }()

    static let key = [UInt8](repeating: 0x5A, count: 32)
    static let mine = StellarKey.muxedAddress(publicKey: key, id: 1_234_567)
    static let attacker = StellarKey.muxedAddress(publicKey: key, id: 7_654_321)

    @Test func fieldHidesWhileAChallengeIsOnScreen() {
        let model = SendModel(wallet: Self.wallet, holding: nil)
        model.destinationText = Self.attacker
        model.destination = Address.Destination(address: Self.attacker, tag: nil)
        // Endereco valido sem desafio: o campo fica.
        #expect(!model.challengeOnScreen)

        // O ID trocado: o campo some, e a resposta nao esta na tela.
        model.otherID = AddressPoisoning.sameAccountOtherID(Self.attacker, among: [Self.mine], chain: .stellar)
        #expect(model.otherID != nil && model.challengeOnScreen)
        #expect(!model.lookalikeCleared)
        model.otherIDCheck = "7654321"
        #expect(model.lookalikeCleared && model.challengeOnScreen)

        // "Editar": o desafio sai com o endereco, e o campo volta vazio.
        model.tagText = "99"
        model.editDestination()
        #expect(!model.challengeOnScreen && model.destinationText.isEmpty && model.destination == nil)
        #expect(model.otherID == nil && model.otherIDCheck.isEmpty && model.tagText.isEmpty)
    }

    @Test func blindAndLookalikeChallengesHideTheFieldToo() {
        let model = SendModel(wallet: Self.wallet, holding: nil)
        model.destination = Address.Destination(address: Self.attacker, tag: nil)
        model.blindSource = Self.attacker
        model.blindSegment = AddressPoisoning.blindSegment(Self.attacker, chain: .stellar)
        #expect(model.challengeOnScreen)
        model.blindSegment = nil
        model.lookalike = Self.mine
        #expect(model.challengeOnScreen)
        // Sem destino valido nao ha desafio, nem campo escondido.
        model.destination = nil
        #expect(!model.challengeOnScreen)
    }
}
