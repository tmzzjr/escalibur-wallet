#!/usr/bin/env python3
"""Gera o site da Escalibur Wallet (GitHub Pages: tmzzjr.github.io/escalibur-wallet).

    python3 tools/gerar-site.py build/site      o site inteiro, estatico
    python3 tools/gerar-site.py --contagem      "redes N tokens M", para o verificar.sh

O que o site mostra sai do repositorio no build, nunca digitado a mao (tools/gerador_site):
- as redes de Chain.swift e os tokens de TokenRegistry.swift, com os logos do app;
- a versao de project.yml e as novidades do historico da main;
- a auditoria: as verificacoes do tools/verificar.sh, os hosts do hosts.lock, as
  dependencias dos *.lock, o commit publicado, o estado do CI (SITE_CI, do workflow) e
  os arquivos que assinam e guardam as chaves, linha a linha;
- suporte, privacidade e termos dos mesmos arquivos que o app mostra
  (`Resources/Legal/*.md`), lidos pela mesma regra de `LegalDocument.parse`: `#` titulo,
  `##` secao, `- ` item, linha em branco separa paragrafo, `<!--` e nota interna que
  nunca aparece. As URLs /suporte/, /privacidade/ e /termos/ estao cadastradas na App
  Store Connect e nao mudam.

As telas do app em video vem de site/midia (tools/gravar-site/gravar.sh). So biblioteca
padrao. Nenhuma fonte, script ou imagem de fora: a Content Security Policy de cada
pagina so deixa carregar o que vem do proprio site, e o unico script (site/site.js) e
opcional: sem ele tudo continua legivel.
"""

import hashlib
import html
import re
import shutil
import sys
from pathlib import Path

# Sem __pycache__ dentro de tools/: o gerador roda no verificar.sh de todo mundo.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

from gerador_site import acentos, codigo, dados, paginas, png  # noqa: E402

RAIZ = dados.RAIZ
LEGAL = RAIZ / "App/EscaliburWallet/Resources/Legal"
SITE = RAIZ / "site"
ICONE = RAIZ / "App/EscaliburWallet/Resources/Assets.xcassets/AppIcon.appiconset/wallet-1024.png"

# O dia do lancamento: o link do app na App Store (https://apps.apple.com/br/app/...id123).
# Enquanto for None, o site diz "Em breve na App Store" e nao mostra o selo da Apple, que
# so pode levar a um app que ja esta na loja. Trocar aqui e so aqui.
APP_STORE_URL = None
# Nao existe app Android. Enquanto for None, o site diz "Em breve para Android", sem o
# selo do Google Play.
PLAY_STORE_URL = None

# Paginas de texto: (fonte, pasta de saida, rotulo, descricao, sobretitulo).
TEXTOS = [
    (SITE / "suporte.md", "suporte", "Suporte", "Como falar com a Escalibur e o que fazer antes de escrever.", "Ajuda"),
    (LEGAL / "privacidade.md", "privacidade", "Privacidade", "O que a Escalibur Wallet guarda, onde guarda e com quem fala.", "Legal"),
    (LEGAL / "termos.md", "termos", "Termos", "Os termos de uso da Escalibur Wallet.", "Legal"),
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


def gravar(saida, rota, conteudo):
    destino = saida / rota if rota else saida
    destino.mkdir(parents=True, exist_ok=True)
    (destino / "index.html").write_text(conteudo, encoding="utf-8")


def base_de(rota):
    return "../" * (rota.count("/") + 1) if rota else "./"


# MARK: Imagens


CACHE = RAIZ / "build/cache-site"


def reduzido(bruto, lado):
    """`png.reduzir` com cache em build/cache-site, pelo SHA-256 do original: reduzir em
    Python puro leva segundos, e o mesmo logo nao muda de um build para outro."""
    chave = CACHE / f"{hashlib.sha256(bruto).hexdigest()}-{lado}.png"
    if chave.is_file():
        return chave.read_bytes()
    resultado = png.reduzir(bruto, lado)
    if resultado is None:
        return None
    try:
        CACHE.mkdir(parents=True, exist_ok=True)
        chave.write_bytes(resultado[0])
    except OSError:
        pass
    return resultado[0]


def preparar_logos(saida, redes, tokens):
    """Os logos que o site usa, do catalogo do app, reduzidos para 96 px ou mais (48 pt
    em tela de densidade 2). JPEG vai como esta: ja e pequeno."""
    nomes = set()
    for rede in redes:
        nomes.update({f"rede-{rede['id']}", f"logo-{rede['gecko']}"})
    for token in tokens:
        nomes.add(f"logo-{token['gecko']}")
    pasta = saida / "logos"
    pasta.mkdir()
    mapa = {}
    for nome in sorted(nomes):
        origem = dados.arquivo_de_logo(nome)
        if origem is None:
            continue
        bruto = origem.read_bytes()
        extensao = origem.suffix.lower()
        if extensao == ".png":
            bruto = reduzido(bruto, 96) or bruto
        elif extensao not in (".jpg", ".jpeg"):
            continue
        (pasta / f"{nome}{extensao}").write_bytes(bruto)
        mapa[nome] = f"logos/{nome}{extensao}"
    return mapa


def preparar_icones(saida):
    original = ICONE.read_bytes()
    for lado in (64, 256):
        (saida / f"icone-{lado}.png").write_bytes(reduzido(original, lado) or original)
    # O nome antigo, para quem ja apontava para ele.
    shutil.copyfile(saida / "icone-256.png", saida / "icone.png")


# MARK: Contexto


def auditorias():
    saida = []
    for caminho in sorted((RAIZ / "docs").glob("auditoria-*.md"), key=lambda p: int(re.sub(r"\D", "", p.stem) or 0)):
        texto = caminho.read_text(encoding="utf-8")
        titulo = re.search(r"^# (.+)$", texto, re.M)
        paragrafos = [p.strip() for p in re.split(r"\n\s*\n", texto) if p.strip() and not p.strip().startswith(("#", "|", "-"))]
        resumo = re.sub(r"[*`]", "", paragrafos[0]).replace("\n", " ") if paragrafos else ""
        saida.append({"titulo": titulo.group(1) if titulo else caminho.stem, "resumo": acentos.sem_travessao(resumo),
                      "caminho": f"docs/{caminho.name}"})
    return list(reversed(saida))


def arquivos_chave():
    info = {}
    for _, slug, _, caminho in paginas.ARQUIVOS_CHAVE:
        arquivo = RAIZ / caminho
        if not arquivo.is_file():
            sys.exit(f"gerar-site: arquivo-chave sumiu: {caminho} (atualize ARQUIVOS_CHAVE em tools/gerador_site/paginas.py)")
        fonte = arquivo.read_text(encoding="utf-8")
        resumo = acentos.acentuar(codigo.resumo(fonte))
        curto = re.split(r"(?<=[.:])\s", resumo, maxsplit=1)[0]
        if len(curto) > 150:
            curto = curto[:147].rsplit(" ", 1)[0] + "…"
        info[slug] = {"fonte": fonte, "linhas": fonte.count("\n") + (0 if fonte.endswith("\n") else 1),
                      "digesto": paginas.digesto(fonte), "resumo": resumo, "resumo_curto": curto}
    return info


def contar_testes():
    total = 0
    for arquivo in (RAIZ / "Kit/Tests").rglob("*.swift"):
        total += len(re.findall(r"^\s*@Test\b", arquivo.read_text(encoding="utf-8"), re.M))
    return total


def contexto(saida=None):
    redes, tokens = dados.redes(), dados.tokens()
    travas = dados.travas()
    verificacoes = dados.verificacoes()
    app_store_id = None
    if APP_STORE_URL:
        achado = re.search(r"id(\d+)", APP_STORE_URL)
        app_store_id = achado.group(1) if achado else None
    ctx = {
        "versao": dados.versao(), "redes": redes, "tokens": tokens, "commit": dados.commit_atual(),
        "ci": dados.estado_ci(), "commits": dados.commits(30), "hosts": dados.hosts(),
        "grupos_hosts": dados.grupos_de_hosts(), "travas": travas, "verificacoes": verificacoes,
        "n_verificacoes": sum(len(s["itens"]) for s in verificacoes),
        "n_travados": sum(len(t["arquivos"]) for t in travas if t["origem"]),
        "n_testes": contar_testes(), "auditorias": auditorias(), "arquivos_chave": arquivos_chave(),
        "conjuntos_logo": dados.conjuntos_de_logo(), "logos": {},
        "app_store_url": APP_STORE_URL, "app_store_id": app_store_id, "play_store_url": PLAY_STORE_URL,
        "tem_imagem_og": (SITE / "compartilhar.jpg").is_file(),
    }
    if saida is not None:
        ctx["logos"] = preparar_logos(saida, redes, tokens)
    return ctx


# MARK: Saida


def copiar_estaticos(saida):
    for nome in ("estilo.css", "site.js", "marca-ok.svg", "compartilhar.jpg"):
        if (SITE / nome).is_file():
            shutil.copyfile(SITE / nome, saida / nome)
    for pasta in ("midia", "selos"):
        if (SITE / pasta).is_dir():
            shutil.copytree(SITE / pasta, saida / pasta)
    (saida / ".nojekyll").write_text("")


def mapa_do_site(saida, rotas):
    urls = "".join(f"<url><loc>{paginas.SITE_URL}{r + '/' if r else ''}</loc></url>" for r in rotas)
    (saida / "sitemap.xml").write_text(
        f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{urls}</urlset>\n',
        encoding="utf-8")
    (saida / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {paginas.SITE_URL}sitemap.xml\n", encoding="utf-8")


def main():
    if sys.argv[1:] == ["--contagem"]:
        print(f"redes {len(dados.redes())} tokens {len(dados.tokens())}")
        return
    if len(sys.argv) != 2:
        sys.exit("uso: gerar-site.py <pasta de saida> | --contagem")
    saida = preparar(Path(sys.argv[1]))
    ctx = contexto(saida)
    rotas = []

    def modelo(rota, arquivo, titulo, descricao, ativa=None):
        base = base_de(rota)
        texto = (SITE / arquivo).read_text(encoding="utf-8")
        corpo_html = paginas.preencher(ctx, base, texto, arquivo)
        gravar(saida, rota, paginas.moldura(ctx, base, rota, titulo, descricao, corpo_html, ativa))
        rotas.append(rota)

    modelo("", "inicio.html", "", "Carteira cripto sem custódia para iPhone. As chaves ficam só no seu aparelho. "
           f"Envie, receba e troque em {len(ctx['redes'])} redes, com cada transação conferida antes de assinar.")
    modelo("seguranca", "seguranca.html", "Segurança",
           "O que protege a sua carteira na Escalibur Wallet, contra quem, e onde cada proteção para.", "seguranca")

    gravar(saida, "auditoria", paginas.pagina_auditoria(ctx, "../"))
    rotas.append("auditoria")
    for _, slug, titulo, caminho in paginas.ARQUIVOS_CHAVE:
        rota = f"auditoria/codigo/{slug}"
        gravar(saida, rota, paginas.pagina_codigo(ctx, base_de(rota), slug, titulo, caminho))
        rotas.append(rota)
    gravar(saida, "redes", paginas.pagina_redes(ctx, "../"))
    gravar(saida, "novidades", paginas.pagina_novidades(ctx, "../"))
    rotas += ["redes", "novidades"]

    for fonte, pasta, rotulo, descricao, sobretitulo in TEXTOS:
        titulo, itens = blocos(fonte.read_text(encoding="utf-8"))
        if not titulo:
            sys.exit(f"{fonte} sem titulo")
        ativa = pasta if pasta == "suporte" else None
        gravar(saida, pasta, paginas.pagina_de_texto(ctx, base_de(pasta), pasta, titulo, descricao, corpo(itens), ativa, sobretitulo))
        rotas.append(pasta)

    (saida / "404.html").write_text(paginas.pagina_404(ctx), encoding="utf-8")
    copiar_estaticos(saida)
    preparar_icones(saida)
    mapa_do_site(saida, rotas)
    print(f"site em {saida}: {len(rotas)} paginas, {len(ctx['redes'])} redes, {len(ctx['tokens'])} tokens, "
          f"{len(ctx['commits'])} novidades, {ctx['n_verificacoes']} verificacoes")


if __name__ == "__main__":
    main()
