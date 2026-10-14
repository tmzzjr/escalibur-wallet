#!/usr/bin/env python3
"""Gera as paginas publicas da Escalibur Wallet (GitHub Pages).

    python3 tools/gerar-site.py build/site

A App Store pede uma URL de suporte e uma de politica de privacidade. As paginas saem
dos mesmos arquivos que o app mostra (`Resources/Legal/*.md`), lidos pela mesma regra
de `LegalDocument.parse`: `#` titulo, `##` secao, `- ` item, linha em branco separa
paragrafo, `<!--` e nota interna que nunca aparece. Assim a politica publicada e a do
app nao divergem.

So biblioteca padrao. Sem JavaScript, sem fonte nem script de fora: a Content Security
Policy das paginas so deixa carregar o que vem do proprio site.
"""

import html
import re
import shutil
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
LEGAL = RAIZ / "App/EscaliburWallet/Resources/Legal"
SITE = RAIZ / "site"
ICONE = RAIZ / "App/EscaliburWallet/Resources/Assets.xcassets/AppIcon.appiconset/wallet-1024.png"

EMPRESA = "X TECH A.I FUND HOLDING E PARTICIPACOES LTDA"
CNPJ = "64.019.520/0001-29"

# (fonte, pasta de saida, rotulo no menu, descricao)
PAGINAS = [
    (SITE / "inicio.md", "", "Início", "Carteira cripto sem custódia para iPhone."),
    (SITE / "suporte.md", "suporte", "Suporte", "Como falar com a Escalibur e o que fazer antes de escrever."),
    (LEGAL / "privacidade.md", "privacidade", "Privacidade", "O que a Escalibur Wallet guarda, onde guarda e com quem fala."),
    (LEGAL / "termos.md", "termos", "Termos", "Os termos de uso da Escalibur Wallet."),
]

EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
LINK = re.compile(r"\[([^\]]+)\]\((https://[^)\s]+)\)")
NEGRITO = re.compile(r"\*\*(.+?)\*\*")
CODIGO = re.compile(r"`([^`]+)`")


def blocos(texto):
    """A mesma leitura de `LegalDocument.parse`, com o titulo guardado."""
    titulo, saida, paragrafo, em_nota = None, [], [], False

    def fecha():
        if paragrafo:
            saida.append(("p", " ".join(paragrafo)))
            paragrafo.clear()

    for bruta in texto.split("\n"):
        linha = bruta.strip()
        if em_nota:
            em_nota = "-->" not in linha
            continue
        if not linha:
            fecha()
        elif linha.startswith("<!--"):
            em_nota = "-->" not in linha
        elif linha.startswith("# "):
            fecha()
            titulo = linha[2:]
        elif linha.startswith("## "):
            fecha()
            saida.append(("h2", linha[3:]))
        elif linha.startswith("- "):
            fecha()
            saida.append(("li", linha[2:]))
        else:
            paragrafo.append(linha)
    fecha()
    return titulo, saida


def inline(texto):
    """Negrito, codigo, link https e e-mail. Todo o resto sai escapado."""
    partes, ultimo = [], 0
    for achado in LINK.finditer(texto):
        partes.append(inline_simples(texto[ultimo:achado.start()]))
        partes.append(f'<a href="{html.escape(achado.group(2))}">{inline_simples(achado.group(1))}</a>')
        ultimo = achado.end()
    partes.append(inline_simples(texto[ultimo:]))
    return "".join(partes)


def inline_simples(texto):
    seguro = html.escape(texto, quote=False)
    seguro = NEGRITO.sub(r"<strong>\1</strong>", seguro)
    seguro = CODIGO.sub(r"<code>\1</code>", seguro)
    return EMAIL.sub(lambda m: f'<a href="mailto:{m.group(0)}">{m.group(0)}</a>', seguro)


def corpo(itens):
    linhas, em_lista = [], False
    for tipo, texto in itens:
        if tipo == "li" and not em_lista:
            linhas.append("<ul>")
            em_lista = True
        if tipo != "li" and em_lista:
            linhas.append("</ul>")
            em_lista = False
        tag = {"p": "p", "h2": "h2", "li": "li"}[tipo]
        linhas.append(f"<{tag}>{inline(texto)}</{tag}>")
    if em_lista:
        linhas.append("</ul>")
    return "\n".join(linhas)


def pagina(titulo, descricao, conteudo, pasta, ativa):
    volta = "../" if pasta else "./"
    itens_menu = []
    # O inicio fica no nome do app, no topo: o menu cabe numa linha no iPhone.
    for _, destino, rotulo, _ in PAGINAS:
        if not destino:
            continue
        href = volta + destino + "/"
        atual = ' aria-current="page"' if destino == ativa else ""
        itens_menu.append(f'<a href="{href}"{atual}>{rotulo}</a>')
    menu = "\n".join(itens_menu)
    nome = "Escalibur Wallet" if titulo == "Escalibur Wallet" else f"{titulo} · Escalibur Wallet"
    return f"""<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'">
<meta name="referrer" content="no-referrer">
<meta name="description" content="{html.escape(descricao)}">
<meta name="color-scheme" content="dark">
<title>{html.escape(nome)}</title>
<link rel="stylesheet" href="{volta}estilo.css">
<link rel="icon" href="{volta}icone.png">
<link rel="apple-touch-icon" href="{volta}icone.png">
</head>
<body>
<header>
<a class="marca" href="{volta}"><img src="{volta}icone.png" alt="" width="32" height="32">Escalibur Wallet</a>
<nav>
{menu}
</nav>
</header>
<main>
<h1>{html.escape(titulo)}</h1>
{conteudo}
</main>
<footer>
<p>A Escalibur Wallet é oferecida por {EMPRESA}, CNPJ {CNPJ}.</p>
</footer>
</body>
</html>
"""


ESTILO = """:root {
  --void: #0B0B0C;
  --body: #151518;
  --edge: #2A2A2F;
  --ink: #F5F5F6;
  --ink-soft: #A8A8AE;
  --ink-muted: #8A8A92;
  --accent: #FF007B;
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  background: var(--void);
  color: var(--ink-soft);
  font: 17px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
}
header, main, footer { max-width: 680px; margin: 0 auto; padding: 0 20px; }
header { padding-top: 20px; padding-bottom: 8px; }
.marca {
  display: inline-flex; align-items: center; gap: 10px;
  color: var(--ink); text-decoration: none; font-weight: 700; letter-spacing: -0.01em;
}
.marca img { border-radius: 8px; }
nav { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 16px; }
nav a {
  color: var(--ink-soft); text-decoration: none; font-size: 15px; font-weight: 600;
  padding: 7px 14px; border-radius: 999px; background: var(--body); border: 1px solid var(--edge);
}
nav a[aria-current="page"] { color: var(--ink); border-color: var(--accent); }
main { padding-top: 28px; padding-bottom: 40px; }
h1 { color: var(--ink); font-size: 34px; line-height: 1.15; letter-spacing: -0.02em; margin: 0 0 16px; }
h2 { color: var(--ink); font-size: 21px; line-height: 1.3; letter-spacing: -0.01em; margin: 36px 0 8px; }
p { margin: 0 0 14px; }
ul { margin: 0 0 14px; padding-left: 20px; }
li { margin-bottom: 10px; }
li::marker { color: var(--ink-muted); }
strong { color: var(--ink); font-weight: 600; }
code { font: inherit; color: var(--ink); }
a { color: var(--accent); text-underline-offset: 3px; overflow-wrap: anywhere; }
footer { padding-top: 20px; padding-bottom: 40px; border-top: 1px solid var(--edge); }
footer p { color: var(--ink-muted); font-size: 14px; }
@media (min-width: 720px) {
  h1 { font-size: 44px; }
  main { padding-top: 44px; }
}
"""


# So apaga a pasta de saida que este script criou (pentest de 14/10/2026, B7: com
# `gerar-site.py .` o rmtree levava a copia de trabalho inteira, .git incluido).
MARCA = ".gerado-por-gerar-site"


def preparar(saida):
    saida = saida.resolve()
    if saida in (RAIZ, SITE) or RAIZ.is_relative_to(saida) or saida.is_relative_to(SITE) or saida.is_relative_to(LEGAL):
        sys.exit(f"pasta de saida recusada: {saida}")
    if saida.exists():
        if not (saida / MARCA).is_file():
            sys.exit(f"{saida} ja existe e nao foi criada por este script; escolha outra pasta")
        shutil.rmtree(saida)
    saida.mkdir(parents=True)
    (saida / MARCA).write_text("")
    return saida


def main():
    if len(sys.argv) != 2:
        sys.exit("uso: gerar-site.py <pasta de saida>")
    saida = preparar(Path(sys.argv[1]))
    for fonte, pasta, _, descricao in PAGINAS:
        titulo, itens = blocos(fonte.read_text(encoding="utf-8"))
        if not titulo:
            sys.exit(f"{fonte} sem titulo")
        destino = saida / pasta if pasta else saida
        destino.mkdir(parents=True, exist_ok=True)
        (destino / "index.html").write_text(pagina(titulo, descricao, corpo(itens), pasta, pasta), encoding="utf-8")
    (saida / "estilo.css").write_text(ESTILO, encoding="utf-8")
    shutil.copyfile(ICONE, saida / "icone.png")
    print(f"site em {saida}: " + ", ".join("/" + p for _, p, _, _ in PAGINAS))


if __name__ == "__main__":
    main()
