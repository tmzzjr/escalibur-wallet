import SwiftUI

/// Termos de uso e Politica de privacidade, lidos do proprio app: nenhum texto legal
/// vem da internet, entao o que o dono aceitou e o que esta nesta versao.
enum LegalDocument: String, Identifiable {
    case terms = "termos"
    case privacy = "privacidade"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terms: return "Termos de uso"
        case .privacy: return "Política de privacidade"
        }
    }

    /// Os blocos do texto: titulo de secao, item de lista ou paragrafo, na ordem.
    enum Block: Hashable {
        case heading(String)
        case item(String)
        case paragraph(String)
    }

    var blocks: [Block] {
        let url = Bundle.main.url(forResource: rawValue, withExtension: "md")
            ?? Bundle.main.url(forResource: rawValue, withExtension: "md", subdirectory: "Legal")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Self.parse(text)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("<!--") {
                // Nota interna (revisao juridica), nunca mostrada no app.
                continue
            } else if line.hasPrefix("# ") {
                flush()
            } else if line.hasPrefix("## ") {
                flush()
                blocks.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("- ") {
                flush()
                blocks.append(.item(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .heading(let text):
                            Text(text).typeStyle(.heading).foregroundStyle(Palette.ink).padding(.top, Space.md)
                        case .item(let text):
                            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                                Circle().fill(Palette.inkMuted).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 5 }
                                Self.rich(text).typeStyle(.body).foregroundStyle(Palette.inkSoft)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        case .paragraph(let text):
                            Self.rich(text).typeStyle(.body).foregroundStyle(Palette.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Palette.void.ignoresSafeArea())
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fechar") { dismiss() }.foregroundStyle(Palette.ink)
                }
            }
        }
    }

    /// Negrito e codigo do Markdown, sem link: nenhum texto legal abre nada fora do app.
    static func rich(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in attributed.runs where run.link != nil { attributed[run.range].link = nil }
        return Text(attributed)
    }
}
