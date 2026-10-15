"""Codigo-fonte em HTML, linha a linha, com cor so para comentario, texto, palavra-chave,
tipo e atributo. Sem biblioteca de destaque: um varredor curto que entende o bastante
de Swift e de shell para nao errar a cor de um comentario dentro de string.
"""

import html
import re

PALAVRAS_SWIFT = set("""
actor any as associatedtype async await break case catch class consuming continue default defer deinit do else enum
extension fallthrough false fileprivate final for func guard if import in indirect init inout internal is lazy let
mutating nil nonisolated open operator override package private protocol public repeat rethrows return self Self some
static struct subscript super switch throw throws true try typealias var weak where while borrowing unowned
""".split())

PALAVRAS_SHELL = set("""
if then else elif fi for in do done while until case esac function local return exit set export readonly shift
""".split())


def _span(classe, texto):
    return f'<span class="{classe}">{html.escape(texto, quote=True)}</span>'


def linhas_swift(fonte):
    """Uma lista de linhas em HTML. Guarda o estado de comentario de bloco e de string
    de varias linhas entre uma linha e outra."""
    saida, em_bloco, em_multilinha = [], False, False
    for linha in fonte.split("\n"):
        partes, i, n = [], 0, len(linha)
        while i < n:
            if em_bloco:
                fim = linha.find("*/", i)
                pedaco = linha[i:] if fim < 0 else linha[i:fim + 2]
                partes.append(_span("c", pedaco))
                i += len(pedaco)
                em_bloco = fim < 0
                continue
            if em_multilinha:
                fim = linha.find('"""', i)
                pedaco = linha[i:] if fim < 0 else linha[i:fim + 3]
                partes.append(_span("s", pedaco))
                i += len(pedaco)
                em_multilinha = fim < 0
                continue
            c = linha[i]
            if linha.startswith("//", i):
                partes.append(_span("c", linha[i:]))
                break
            if linha.startswith("/*", i):
                em_bloco = True
                continue
            if linha.startswith('"""', i):
                fim = linha.find('"""', i + 3)
                if fim < 0:
                    partes.append(_span("s", linha[i:]))
                    em_multilinha = True
                    break
                partes.append(_span("s", linha[i:fim + 3]))
                i = fim + 3
                continue
            if c == '"':
                j = i + 1
                while j < n and linha[j] != '"':
                    j += 2 if linha[j] == "\\" else 1
                partes.append(_span("s", linha[i:j + 1]))
                i = j + 1
                continue
            if c == "@" and i + 1 < n and linha[i + 1].isalpha():
                achado = re.match(r"@\w+", linha[i:])
                partes.append(_span("a", achado.group(0)))
                i += len(achado.group(0))
                continue
            if c == "#" and i + 1 < n and linha[i + 1].isalpha():
                achado = re.match(r"#\w+", linha[i:])
                partes.append(_span("k", achado.group(0)))
                i += len(achado.group(0))
                continue
            if c.isalpha() or c == "_":
                achado = re.match(r"[A-Za-z_]\w*", linha[i:])
                palavra = achado.group(0)
                if palavra in PALAVRAS_SWIFT:
                    partes.append(_span("k", palavra))
                elif palavra[0].isupper():
                    partes.append(_span("t", palavra))
                else:
                    partes.append(html.escape(palavra, quote=True))
                i += len(palavra)
                continue
            partes.append(html.escape(c, quote=True))
            i += 1
        saida.append("".join(partes))
    return saida


def linhas_shell(fonte):
    saida = []
    for linha in fonte.split("\n"):
        partes, i, n = [], 0, len(linha)
        while i < n:
            c = linha[i]
            if c == "#" and (i == 0 or linha[i - 1] in " \t;"):
                partes.append(_span("c", linha[i:]))
                break
            if c in "\"'":
                j = i + 1
                while j < n and linha[j] != c:
                    j += 2 if (linha[j] == "\\" and c == '"') else 1
                partes.append(_span("s", linha[i:j + 1]))
                i = j + 1
                continue
            if c.isalpha() or c == "_":
                achado = re.match(r"[A-Za-z_][\w-]*", linha[i:])
                palavra = achado.group(0)
                anterior = linha[i - 1] if i else " "
                if palavra in PALAVRAS_SHELL and anterior in " \t;(":
                    partes.append(_span("k", palavra))
                else:
                    partes.append(html.escape(palavra, quote=True))
                i += len(palavra)
                continue
            partes.append(html.escape(c, quote=True))
            i += 1
        saida.append("".join(partes))
    return saida


def destacar(caminho, fonte):
    """As linhas em HTML. Travessao citado no codigo sai como entidade: o texto do site
    nao tem travessao, e o verificar.sh confere isso nas paginas geradas."""
    if caminho.endswith(".swift"):
        linhas = linhas_swift(fonte)
    elif caminho.endswith(".sh"):
        linhas = linhas_shell(fonte)
    else:
        linhas = [html.escape(l, quote=True) for l in fonte.split("\n")]
    return [l.replace("\u2014", "&#8212;").replace("\u2013", "&#8211;") for l in linhas]


def resumo(fonte):
    """O primeiro paragrafo do comentario de abertura do arquivo (`///` ou `//`)."""
    linhas = []
    for linha in fonte.split("\n"):
        tirada = linha.strip()
        if not tirada and not linhas:
            continue
        if tirada.startswith("import ") or tirada.startswith("#!"):
            continue
        achado = re.match(r"^(///|//|#)\s?(.*)$", tirada)
        if not achado:
            break
        texto = achado.group(2).strip()
        if not texto:
            if linhas:
                break
            continue
        if texto.startswith("```"):
            break
        linhas.append(texto)
    return " ".join(linhas)
