import SwiftUI
import UIKit

/// Protecao contra captura nas telas de segredo (pedido do dono, 16/10/2026): o que esta
/// dentro sai em branco na captura de tela, na gravacao, no espelhamento por AirPlay e na
/// captura por outro app (ReplayKit). Na tela, nada muda.
///
/// **Como.** Um `UITextField` com `isSecureTextEntry` desenha o texto numa subview propria,
/// e o UIKit marca a camada dessa subview para ficar fora de toda captura (no iOS 17.5 e no
/// 26.5, `_didChangeSecureTextEntry` faz isso na vista de desenho do campo). A marca vale
/// para tudo o que esta dentro da camada: o conteudo vai num `UIHostingController` dentro
/// dela. Na captura, o lugar sai vazio, com o que esta por tras (a chapa sem as palavras).
///
/// **Sem API privada.** Nenhum nome de classe privada, seletor privado nem chave de KVC: a
/// vista e achada pela hierarquia publica (`subviews` e `frame`). Um campo seguro novo, sem
/// borda, sem texto de exemplo e sem botao de limpar, tem uma subview so, a que desenha o
/// texto, do tamanho do campo (`SecureCanvas`). Se ela nao aparecer, a tela mostra o
/// conteudo como antes; a guarda de captura (`guardedAgainstCapture`) continua valendo nos
/// dois casos.
///
/// **O que nao cobre** (docs/seguranca.md §7): jailbreak (quem le a memoria do app nao
/// precisa da tela), camera apontada para a tela e o teclado do iPhone, que e desenhado
/// por outro processo. O teclado da Escalibur e desenhado pelo app e entra na mesma
/// camada (`WordKeyboardInputView`). Depende da hierarquia do UIKit: conferir a cada iOS
/// novo (`CaptureShieldTests`).
extension View {
    /// Desenha esta vista fora da captura. Com `interactive: false` (o que so mostra, como
    /// as palavras na chapa), o toque passa para o que esta por tras: o arrastar do cartao
    /// e da chapa continua sendo deles.
    func protectedFromCapture(interactive: Bool = true) -> some View {
        CaptureShield(content: self, interactive: interactive)
    }
}

/// Com a camada, o conteudo vai para dentro dela; sem, fica onde estava.
private struct CaptureShield<Content: View>: View {
    let content: Content
    let interactive: Bool

    var body: some View {
        if SecureCanvas.isAvailable {
            SecureCaptureContainer(content: content)
                .allowsHitTesting(interactive)
        } else {
            content
        }
    }
}

/// O conteudo SwiftUI num hospedeiro proprio, dentro da vista de desenho de um campo
/// seguro. O tamanho e o que o conteudo pede para a proposta de fora, como se estivesse
/// no lugar: o layout da tela nao muda.
struct SecureCaptureContainer<Content: View>: UIViewRepresentable {
    let content: Content

    func makeUIView(context: Context) -> SecureCaptureView<Content> {
        SecureCaptureView(root: SecureCaptureRoot(content: content, environment: context.environment))
    }

    /// O conteudo novo a cada desenho da tela de fora: o estado (as palavras, o que foi
    /// digitado, o revelado) mora nela, e os toques de dentro escrevem nele.
    func updateUIView(_ view: SecureCaptureView<Content>, context: Context) {
        view.host.rootView = SecureCaptureRoot(content: content, environment: context.environment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: SecureCaptureView<Content>, context: Context) -> CGSize? {
        // O hospedeiro mede o infinito como a proposta aberta: devolve o tamanho ideal
        // (conferido no SwiftUI do iOS 26). A proposta aberta de fora vira infinito.
        let fitted = view.host.sizeThatFits(in: CGSize(width: proposal.width ?? .infinity, height: proposal.height ?? .infinity))
        // Nunca mais largo nem mais alto que o oferecido: uma senha longa na cifra pedia mais
        // largura e esticava o campo ate as bordas da tela (visto pelo dono, 16/10/2026).
        let width = min(fitted.width.isFinite ? fitted.width : 0, proposal.width ?? .infinity)
        let height = min(fitted.height.isFinite ? fitted.height : 0, proposal.height ?? .infinity)
        return CGSize(width: width, height: height)
    }
}

/// A raiz do hospedeiro de dentro: o conteudo com o ambiente da tela de fora. O
/// hospedeiro nao herda o ambiente do SwiftUI: sem isto, perdia o tamanho de texto
/// limitado, a cor de destaque, a sessao e o `disabled` da guarda de captura, que fecha
/// o teclado quando a gravacao comeca.
struct SecureCaptureRoot<Content: View>: View {
    var content: Content
    var environment: EnvironmentValues

    var body: some View {
        content.environment(\.self, environment)
    }
}

/// A vista UIKit do conteiner: a vista de desenho do campo seguro cobre ela inteira, e o
/// hospedeiro do conteudo fica dentro da vista de desenho.
final class SecureCaptureView<Content: View>: UIView {
    let host: UIHostingController<SecureCaptureRoot<Content>>
    /// Nil quando a vista de desenho nao foi achada: o conteudo fica direto aqui.
    private let secure: SecureCanvas?

    init(root: SecureCaptureRoot<Content>) {
        host = UIHostingController(rootView: root)
        secure = SecureCanvas()
        super.init(frame: .zero)
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        // O hospedeiro de dentro nao aplica area segura nem teclado: quem faz isso e a tela
        // de fora, como antes.
        host.safeAreaRegions = []
        if let canvas = secure?.view {
            addSubview(canvas)
            canvas.addSubview(host.view)
        } else {
            addSubview(host.view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        secure?.view.frame = bounds
        host.view.frame = bounds
    }
}

/// A vista de desenho de um campo seguro, tirada dele para hospedar outra coisa.
///
/// Achada sem nome de classe: a primeira subview do campo que nao e rotulo, imagem nem
/// controle e que cobre o campo (a largura toda e o meio). O campo fica vivo junto, fora
/// da tela e sem layout: a vista de desenho consulta o campo no layout dela, e um layout
/// do campo a puxaria de volta para dentro dele. No iOS 17.5 e no 26.5 a vista nasce sem
/// toque (`isUserInteractionEnabled` falso) e o `hitTest` dela devolve nil para ela mesma:
/// ligado o toque, ele chega ao que esta dentro, e o que cai fora do conteudo passa direto.
@MainActor
final class SecureCanvas {
    /// Se este iOS tem a vista: conferido uma vez, na primeira tela protegida.
    static let isAvailable = SecureCanvas() != nil

    private let field: UITextField
    let view: UIView

    init?() {
        #if DEBUG
        // `-sem-camada-segura`: as telas como antes, para fotografar no simulador e para o
        // teste comparar (CaptureShieldTests).
        if DebugDemo.arguments.contains("-sem-camada-segura") { return nil }
        #endif
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 160, height: 48))
        field.borderStyle = .none
        field.isSecureTextEntry = true
        field.layoutIfNeeded()
        let bounds = field.bounds
        let found = field.subviews.first { view in
            !(view is UILabel) && !(view is UIImageView) && !(view is UIControl)
                && view.frame.minX <= bounds.minX + 1 && view.frame.maxX >= bounds.maxX - 1
                && view.frame.contains(CGPoint(x: bounds.midX, y: bounds.midY))
        }
        guard let canvas = found else { return nil }
        canvas.removeFromSuperview()
        canvas.isUserInteractionEnabled = true
        canvas.clipsToBounds = false
        canvas.backgroundColor = .clear
        self.field = field
        view = canvas
    }
}
