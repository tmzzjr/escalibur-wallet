import Foundation
import os

/// Texto de interface montado no Kit: linhas e titulos da revisao, recusas, avisos.
///
/// A traducao vem do catalogo do app (`Localizable.xcstrings`), o unico do projeto: no
/// app, o texto sai no idioma do aparelho. Nos testes do Kit, que rodam fora do app, o
/// catalogo nao existe e sai o original em portugues, que e o que os testes conferem.
///
/// So texto compilado passa por aqui. Nada que venha de provedor vira chave de traducao,
/// e o que entra por interpolacao (nome da rede, valor ja formatado) entra como valor.
public func kitText(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .main)
}

/// Os separadores dos numeros que o Kit e o app escrevem: valores da revisao, taxas,
/// percentuais, saldos.
///
/// O padrao e o do Brasil ("1.234,56"). O app adota o da regiao do aparelho uma vez, ao
/// abrir (`adopt`), e ele fica fixo durante a sessao: a revisao que o planejador monta e
/// a conferencia que o motor faz antes de assinar comparam o mesmo texto, e mudar a regiao
/// no meio nao pode separar um do outro. Os testes do Kit ficam no padrao.
public struct NumberStyle: Sendable, Equatable {
    public let decimal: String
    public let groupSeparator: String
    /// Algarismos no primeiro grupo e nos seguintes: 3 e 3; na India, 3 e 2.
    public let primaryGroup: Int
    public let secondaryGroup: Int
    /// Data e hora com algarismos, na ordem da regiao: "dd/MM/yyyy HH:mm" no Brasil.
    public let dateFormat: String
    public let locale: Locale

    public static let brazil = NumberStyle(decimal: ",", groupSeparator: ".")

    public init(
        decimal: String, groupSeparator: String, primaryGroup: Int = 3, secondaryGroup: Int = 3,
        dateFormat: String = "dd/MM/yyyy HH:mm", locale: Locale = Locale(identifier: "pt_BR")
    ) {
        self.decimal = decimal
        self.groupSeparator = groupSeparator
        self.primaryGroup = max(primaryGroup, 1)
        self.secondaryGroup = max(secondaryGroup, 1)
        self.dateFormat = dateFormat
        self.locale = locale
    }

    /// Os separadores da regiao, sempre com algarismos latinos. Separador vazio, repetido
    /// ou com algarismo dentro nao vale: fica o padrao.
    public init(locale: Locale) {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        let decimal = formatter.decimalSeparator ?? ""
        let grouping = formatter.groupingSeparator ?? ""
        let valid = !decimal.isEmpty && !grouping.isEmpty && decimal != grouping
            && !(decimal + grouping).contains(where: \.isNumber) && decimal.count == 1
        guard valid else {
            self = .brazil
            return
        }
        let primary = formatter.groupingSize > 0 ? formatter.groupingSize : 3
        let secondary = formatter.secondaryGroupingSize > 0 ? formatter.secondaryGroupingSize : primary
        let date = DateFormatter.dateFormat(fromTemplate: "ddMMyyyyjjmm", options: 0, locale: locale) ?? "dd/MM/yyyy HH:mm"
        self.init(
            decimal: decimal, groupSeparator: grouping, primaryGroup: primary, secondaryGroup: secondary,
            dateFormat: date, locale: locale
        )
    }

    private static let state = OSAllocatedUnfairLock(initialState: NumberStyle.brazil)

    /// O estilo da sessao.
    public static var current: NumberStyle { state.withLock { $0 } }

    /// Chamado pelo app ao abrir, antes de qualquer texto ser montado.
    public static func adopt(_ style: NumberStyle) {
        state.withLock { $0 = style }
    }

    /// "1234567" vira "1.234.567". So algarismos entram; outro texto volta como veio.
    public func group(_ digits: some StringProtocol) -> String {
        let text = String(digits)
        guard text.count > primaryGroup, text.allSatisfy(\.isASCIIDigit) else { return text }
        var groups: [Substring] = []
        var end = text.endIndex
        var size = primaryGroup
        while end > text.startIndex {
            let start = text.index(end, offsetBy: -size, limitedBy: text.startIndex) ?? text.startIndex
            groups.append(text[start..<end])
            end = start
            size = secondaryGroup
        }
        return groups.reversed().joined(separator: groupSeparator)
    }

    /// Data e hora em UTC, com "UTC" escrito: prazo de ordem e de cotacao, que vale igual
    /// em qualquer fuso.
    public func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = dateFormat
        return formatter.string(from: date) + " UTC"
    }

    /// Inteiro e fracao ja em algarismos: "12" e "5" viram "12,5". Sem fracao, so o inteiro.
    public func decimal(_ integer: some StringProtocol, _ fraction: some StringProtocol) -> String {
        fraction.isEmpty ? String(integer) : String(integer) + decimal + String(fraction)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
