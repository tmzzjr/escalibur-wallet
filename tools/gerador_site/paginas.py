"""O HTML do site: a moldura de toda pagina, os componentes (iPhone, logo, botoes da
loja) e as paginas geradas dos dados (auditoria, codigo, redes e moedas, novidades).

Todo texto que vem de fora (commit, comentario de codigo, nome de token) passa por
html.escape. Nenhum atributo de evento, nenhum estilo em linha: a Content Security
Policy so deixa carregar o estilo e o script do proprio site.
"""

import hashlib
import html
import re
from datetime import datetime

from . import acentos, codigo, dados

SITE_URL = "https://tmzzjr.github.io/escalibur-wallet/"
EMPRESA = "X TECH A.I FUND HOLDING E PARTICIPACOES LTDA"
CNPJ = "64.019.520/0001-29"

# As paginas do menu, na ordem: (pasta, rotulo).
MENU = [
    ("seguranca", "Segurança"),
    ("auditoria", "Auditoria"),
    ("redes", "Redes e moedas"),
    ("novidades", "Novidades"),
    ("suporte", "Suporte"),
]

MESES = ["jan.", "fev.", "mar.", "abr.", "maio", "jun.", "jul.", "ago.", "set.", "out.", "nov.", "dez."]
MESES_LONGOS = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro",
                "novembro", "dezembro"]

# Os arquivos que a pagina de auditoria abre linha a linha: (grupo, slug, titulo, caminho).
ARQUIVOS_CHAVE = [
    ("Assinatura", "assinador", "O assinador", "Kit/Sources/EscaliburKeys/Signer.swift"),
    ("Assinatura", "contrato-de-assinatura", "O contrato entre redes e assinador", "Kit/Sources/EscaliburChains/Signing.swift"),
    ("Assinatura", "conferencia-do-plano", "A conferência do plano", "Kit/Sources/EscaliburChains/PlanIntentCheck.swift"),
    ("Assinatura", "movimento-do-plano", "O que sai e o que entra", "Kit/Sources/EscaliburChains/PlanMovement.swift"),
    ("Contratos e destinos", "guarda-de-chamada-evm", "A guarda de chamada EVM", "Kit/Sources/EscaliburChains/EVM/EVMCallGuard.swift"),
    ("Contratos e destinos", "allowlist-de-troca", "A lista de contratos da troca", "Kit/Sources/EscaliburChains/Trade/TradeAllowlist.swift"),
    ("Contratos e destinos", "allowlist-da-ponte", "A lista de contratos da ponte", "Kit/Sources/EscaliburChains/Bridge/BridgeAllowlist.swift"),
    ("Contratos e destinos", "envenenamento-de-endereco", "Endereço parecido", "Kit/Sources/EscaliburChains/AddressPoisoning.swift"),
    ("Chaves", "chave-raiz", "A chave raiz, o PIN e o Face ID", "Kit/Sources/EscaliburKeys/RootKeyVault.swift"),
    ("Chaves", "secure-enclave", "As chaves do Secure Enclave", "Kit/Sources/EscaliburKeys/Enclave.swift"),
    ("Chaves", "politica-do-pin", "As regras do PIN", "Kit/Sources/EscaliburKeys/PINPolicy.swift"),
    ("Chaves", "chaveiro", "O chaveiro", "Kit/Sources/EscaliburKeys/SecretStore.swift"),
    ("Envelope", "envelope", "O envelope", "Kit/Sources/EscaliburCore/Envelope/Envelope.swift"),
    ("Envelope", "formato-do-envelope", "O formato .esclbr", "Kit/Sources/EscaliburCore/Envelope/VaultFormat.swift"),
    ("Rede", "cliente-http", "O cliente HTTP", "Kit/Sources/EscaliburNetwork/HTTPClient.swift"),
    ("Rede", "hosts-permitidos", "Os hosts permitidos", "Kit/Sources/EscaliburNetwork/AllowedHosts.swift"),
    ("Verificação", "verificador", "O verificador", "tools/verificar.sh"),
]


def e(texto):
    return html.escape(str(texto), quote=True)


def acento(texto):
    return e(acentos.acentuar(texto))


def numero(n):
    return f"{n:,}".replace(",", ".")


def data_curta(iso):
    if not iso:
        return ""
    d = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    return f"{d.day} {MESES[d.month - 1]} {d.year}"


def data_longa(iso):
    if not iso:
        return ""
    d = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    return f"{d.day} de {MESES_LONGOS[d.month - 1]} de {d.year}"


def data_iso(iso):
    return iso[:10] if iso else ""


def blob(ctx, caminho, linha=None):
    ref = ctx["commit"]["sha"] or "main"
    return f"{dados.REPO}/blob/{ref}/{caminho}" + (f"#L{linha}" if linha else "")


# MARK: Componentes

ICONE_PAUSA = '<svg class="pausa" viewBox="0 0 14 14" aria-hidden="true"><rect x="2.5" y="2" width="3" height="10" rx="1" fill="currentColor"/><rect x="8.5" y="2" width="3" height="10" rx="1" fill="currentColor"/></svg>'
ICONE_TOCAR = '<svg class="tocar" viewBox="0 0 14 14" aria-hidden="true"><path d="M4 2.4v9.2c0 .5.5.8.9.5l7-4.6c.4-.3.4-.8 0-1.1l-7-4.6c-.4-.2-.9 0-.9.6Z" fill="currentColor"/></svg>'
ICONE_IPHONE = '<svg viewBox="0 0 26 26" aria-hidden="true"><rect x="7" y="2.5" width="12" height="21" rx="3" fill="none" stroke="currentColor" stroke-width="1.6"/><rect x="11" y="4.8" width="4" height="1.4" rx=".7" fill="currentColor"/></svg>'
ICONE_ANDROID = '<svg viewBox="0 0 26 26" aria-hidden="true"><rect x="7" y="2.5" width="12" height="21" rx="2.2" fill="none" stroke="currentColor" stroke-width="1.6"/><circle cx="13" cy="5.6" r=".9" fill="currentColor"/></svg>'


def aparelho(base, cena, rotulo, classe="", video=True, cedo=False):
    """Um iPhone desenhado em CSS com a gravacao real do app dentro.

    A capa e uma imagem com carregamento preguicoso (so baixa perto da tela) e leva o
    texto alternativo. O video fica por cima, invisivel e sem baixar nada (preload none)
    ate o site.js mandar tocar; sem JS, fica a capa."""
    carregamento = "eager" if cedo else "lazy"
    capa = (f'<img class="capa" src="{base}midia/{cena}.webp" alt="{e(rotulo)}" width="720" height="1566" '
            f'loading="{carregamento}" decoding="async">')
    botao = ""
    if video:
        capa += (f'<video muted loop playsinline preload="none" data-auto aria-hidden="true" tabindex="-1">'
                 f'<source src="{base}midia/{cena}.mp4" type="video/mp4"></video>')
        botao = (f'<button class="pausar" type="button" data-estado="pausado" aria-label="Tocar a animação">'
                 f'{ICONE_PAUSA}{ICONE_TOCAR}</button>')
    classes = "aparelho" + (f" {classe}" if classe else "")
    return f'<div class="{classes}"><div class="tela">{capa}</div>{botao}</div>'


def botoes_baixar(ctx, base):
    """App Store e Android. Antes do lancamento nao ha selo nem link: o selo oficial da
    Apple so pode levar a um app que esta na loja."""
    partes = []
    if ctx["app_store_url"]:
        partes.append(
            f'<a class="selo-loja" href="{e(ctx["app_store_url"])}">'
            f'<img src="{base}selos/baixar-na-app-store.svg" alt="Baixar na App Store" width="156" height="52"></a>'
        )
    else:
        partes.append(f'<p class="em-breve">{ICONE_IPHONE}<span><small>Em breve</small><b>na App Store</b></span></p>')
    if ctx["play_store_url"]:
        partes.append(f'<a class="botao botao-secundario" href="{e(ctx["play_store_url"])}">Baixar para Android</a>')
    else:
        partes.append(f'<p class="em-breve">{ICONE_ANDROID}<span><small>Em breve</small><b>para Android</b></span></p>')
    return '<div class="botoes">' + "".join(partes) + "</div>"


def logo(ctx, base, nome, classe="", texto=""):
    """Um logo do catalogo do app, no mesmo disco do app."""
    caminho = ctx["logos"].get(nome)
    if not caminho:
        letras = re.sub(r"[^A-Za-z0-9]", "", texto)[:2].upper() or "?"
        return f'<span class="logo letra" aria-hidden="true">{e(letras)}</span>'
    classes = "logo" + (f" {classe}" if classe else "")
    return f'<span class="{classes}"><img src="{base}{caminho}" alt="" width="48" height="48" loading="lazy" decoding="async"></span>'


def logo_rede(ctx, base, rede):
    """Como o selo de rede do app (NetworkBadge): a Base e o quadrado branco no disco
    azul; XRP Ledger e Stellar, escuros, num disco claro."""
    if rede["id"] == "base":
        return '<span class="logo logo-base" aria-hidden="true"></span>'
    nome = f"rede-{rede['id']}" if f"rede-{rede['id']}" in ctx["logos"] else f"logo-{rede['gecko']}"
    classe = "clara" if rede["id"] in ("xrpl", "stellar") else ""
    return logo(ctx, base, nome, classe, rede["nome"])


def logo_token(ctx, base, token):
    soltas, escuras = ctx["conjuntos_logo"]
    classe = "solta" if token["gecko"] in soltas else ("clara" if token["gecko"] in escuras else "")
    return logo(ctx, base, f"logo-{token['gecko']}", classe, token["simbolo"])


def estado_ci(ctx, base, curto=False):
    commit = ctx["commit"]
    sha = commit["sha"]
    partes = []
    if sha:
        partes.append(f'Commit <a href="{dados.REPO}/commit/{sha}">{sha[:7]}</a> de {data_curta(commit["data"])}')
    ci = ctx["ci"]
    classe = "sem"
    if ci is None:
        partes.append("sem o estado do CI neste build local")
    else:
        textos = {
            "passou": "verificação no CI: passou", "falhou": "verificação no CI: falhou",
            "rodando": "verificação no CI: rodando", "cancelado": "verificação no CI: cancelada",
            "sem": "verificação no CI: ainda sem resultado para este commit", "outro": "verificação no CI: sem conclusão",
        }
        classe = ci["estado"]
        texto = textos.get(ci["estado"], "verificação no CI")
        partes.append(f'<a href="{e(ci["url"])}">{texto}</a>' if ci.get("url") else texto)
    return f'<p class="estado-ci {e(classe)}"><span class="ponto" aria-hidden="true"></span>{" · ".join(partes)}</p>'


def redes_com_tag(ctx):
    nomes = {"tag de destino": "tag de destino", "memo": "memo", "comentário": "comentário"}
    partes = []
    for rede in ctx["redes"]:
        if rede["tag"]:
            preposicao = "no" if rede["nome"] in ("XRP Ledger",) else "na"
            partes.append(f"{nomes[rede['tag']]} {preposicao} {rede['nome']}")
    if not partes:
        return ""
    return e(", ".join(partes[:-1]) + (" e " if len(partes) > 1 else "") + partes[-1])


def grade_de_redes(ctx, base):
    itens = "".join(f"<li>{logo_rede(ctx, base, r)}<span>{e(r['nome'])}</span></li>" for r in ctx["redes"])
    return f'<ul class="redes-grade" aria-label="As {len(ctx["redes"])} redes da carteira">{itens}</ul>'


def resumo_novidades(ctx, base, quantos=3):
    itens = []
    for c in ctx["commits"][:quantos]:
        itens.append(
            f'<li><time datetime="{data_iso(c["data"])}">{data_curta(c["data"])}</time>'
            f'<p class="assunto"><a href="{base}novidades/#c-{c["sha"][:7]}">{acento(c["assunto"])}</a></p></li>'
        )
    return '<ol class="linha-do-tempo">' + "".join(itens) + "</ol>"


def link_codigo(base, slug, texto=None):
    for _, s, titulo, caminho in ARQUIVOS_CHAVE:
        if s == slug:
            nome = caminho.rsplit("/", 1)[-1]
            return f'<a class="codigo-link" href="{base}auditoria/codigo/{s}/">{e(texto or "Ler " + nome)}</a>'
    raise SystemExit(f"gerar-site: arquivo-chave desconhecido: {slug}")


# MARK: Moldura


def moldura(ctx, base, rota, titulo, descricao, corpo, ativa=None):
    """A pagina inteira: cabeca com CSP, topo, conteudo e rodape."""
    nome = "Escalibur Wallet" if not titulo else f"{titulo} · Escalibur Wallet"
    canonica = SITE_URL + (rota + "/" if rota else "")
    menu = []
    for pasta, rotulo in MENU:
        atual = ' aria-current="page"' if pasta == ativa else ""
        menu.append(f'<a href="{base}{pasta}/"{atual}>{rotulo}</a>')
    menu_html = "".join(menu)
    banner = ""
    if ctx["app_store_id"]:
        banner = f'<meta name="apple-itunes-app" content="app-id={e(ctx["app_store_id"])}">\n'
    imagem_og = ""
    if ctx["tem_imagem_og"]:
        imagem_og = (f'<meta property="og:image" content="{SITE_URL}compartilhar.jpg">\n'
                     '<meta property="og:image:width" content="1200">\n<meta property="og:image:height" content="630">\n'
                     '<meta name="twitter:card" content="summary_large_image">\n')
    return f"""<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; media-src 'self'; base-uri 'none'; form-action 'none'">
<meta name="referrer" content="no-referrer">
<meta name="description" content="{e(descricao)}">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#0B0B0C">
{banner}<title>{e(nome)}</title>
<link rel="canonical" href="{canonica}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Escalibur Wallet">
<meta property="og:title" content="{e(nome)}">
<meta property="og:description" content="{e(descricao)}">
<meta property="og:url" content="{canonica}">
<meta property="og:locale" content="pt_BR">
{imagem_og}<link rel="stylesheet" href="{base}estilo.css">
<link rel="icon" href="{base}icone-64.png" sizes="64x64" type="image/png">
<link rel="apple-touch-icon" href="{base}icone-180.png">
<script src="{base}site.js" defer></script>
</head>
<body>
<a class="pular" href="#conteudo">Pular para o conteúdo</a>
<header class="topo">
<div class="wrap topo-barra">
<a class="marca" href="{base}"><img src="{base}icone-64.png" alt="" width="28" height="28">Escalibur Wallet</a>
<nav class="nav-largo" aria-label="Principal">{menu_html}</nav>
<details class="nav-curto">
<summary aria-label="Menu"><span>Menu</span><span class="icone-menu" aria-hidden="true"></span></summary>
<nav class="nav-curto-lista" aria-label="Principal"><a href="{base}">Início</a>{menu_html}</nav>
</details>
</div>
</header>
<main id="conteudo">
{corpo}
</main>
{rodape(ctx, base)}
</body>
</html>
"""


def rodape(ctx, base):
    v = ctx["versao"]
    sha = ctx["commit"]["sha"]
    gerado = ""
    if sha:
        gerado = (f'<p>Este site foi gerado do commit <a href="{dados.REPO}/commit/{sha}">{sha[:7]}</a>, '
                  f'de {data_curta(ctx["commit"]["data"])}. Sem análise de uso, sem cookie, sem nada carregado de outro site.</p>')
    return f"""<footer class="rodape">
<div class="wrap">
<div class="rodape-colunas">
<div class="rodape-marca">
<a class="marca" href="{base}"><img src="{base}icone-64.png" alt="" width="28" height="28">Escalibur Wallet</a>
<p>Carteira cripto sem custódia para iPhone.<br>Versão {e(v["marketing"])} (build {e(v["build"])}).</p>
</div>
<div>
<h2>Produto</h2>
<ul><li><a href="{base}">Início</a></li><li><a href="{base}redes/">Redes e moedas</a></li><li><a href="{base}novidades/">Novidades</a></li></ul>
</div>
<div>
<h2>Segurança</h2>
<ul><li><a href="{base}seguranca/">Como protege</a></li><li><a href="{base}auditoria/">Auditoria</a></li><li><a href="{dados.REPO}">Código no GitHub</a></li><li><a href="{dados.REPO}/security/advisories/new">Relatar uma falha</a></li></ul>
</div>
<div>
<h2>Ajuda</h2>
<ul><li><a href="{base}suporte/">Suporte</a></li><li><a href="{base}privacidade/">Privacidade</a></li><li><a href="{base}termos/">Termos de uso</a></li></ul>
</div>
</div>
<div class="rodape-legal">
<p>A Escalibur Wallet é oferecida por {EMPRESA}, CNPJ {CNPJ}.</p>
<p>Apple, iPhone, Face ID e App Store são marcas da Apple Inc. Android é marca do Google LLC. Os logos de redes e moedas pertencem aos seus donos e aparecem só para identificar cada uma.</p>
{gerado}
</div>
</div>
</footer>"""


# MARK: Modelos (site/*.html)

_MARCADOR = re.compile(r"\{\{\s*(\w+)(?:\s+([^}]*?))?\s*\}\}")


def preencher(ctx, base, modelo, origem):
    """Troca cada {{nome argumentos}} do modelo pelo HTML gerado. Marcador desconhecido
    para o build: o site nao sai com um {{...}} perdido na pagina."""

    def troca(achado):
        nome, argumento = achado.group(1), (achado.group(2) or "").strip()
        partes = [p.strip() for p in argumento.split("|")] if argumento else []
        if nome == "base":
            return base
        classe = partes[2] if len(partes) > 2 else ""
        cedo = "cedo" in classe.split()
        classe = " ".join(c for c in classe.split() if c != "cedo")
        if nome == "aparelho":
            return aparelho(base, partes[0], partes[1], classe, cedo=cedo)
        if nome == "capa":
            return aparelho(base, partes[0], partes[1], classe, video=False, cedo=cedo)
        if nome == "codigo":
            return link_codigo(base, partes[0], partes[1] if len(partes) > 1 else None)
        valores = {
            "botoes_baixar": lambda: botoes_baixar(ctx, base),
            "versao": lambda: e(ctx["versao"]["marketing"]),
            "build": lambda: e(ctx["versao"]["build"]),
            "n_redes": lambda: str(len(ctx["redes"])),
            "n_redes_resto": lambda: str(len(ctx["redes"]) - 7),
            "n_tokens": lambda: str(len(ctx["tokens"])),
            "n_verificacoes": lambda: str(ctx["n_verificacoes"]),
            "n_hosts": lambda: str(len(ctx["hosts"])),
            "n_testes": lambda: numero(ctx["n_testes"]),
            "n_travados": lambda: str(ctx["n_travados"]),
            "redes_logos": lambda: grade_de_redes(ctx, base),
            "redes_com_tag": lambda: redes_com_tag(ctx),
            "estado_ci": lambda: estado_ci(ctx, base),
            "novidades_resumo": lambda: resumo_novidades(ctx, base),
            "situacao_loja": lambda: ("Disponível na App Store." if ctx["app_store_url"] else "Em preparação para a App Store."),
            "prazos_seguranca": lambda: prazos_seguranca(),
            "repo": lambda: dados.REPO,
        }
        if nome not in valores:
            raise SystemExit(f"gerar-site: marcador desconhecido {{{{{nome}}}}} em {origem}")
        return valores[nome]()

    return _MARCADOR.sub(troca, modelo)


def prazos_seguranca():
    texto = (dados.RAIZ / "SECURITY.md").read_text(encoding="utf-8")
    bloco = re.search(r"Prazos que assumimos:\n((?:- .+\n?)+)", texto)
    if not bloco:
        return ""
    itens = [l[2:].strip().rstrip(";.") for l in bloco.group(1).splitlines() if l.startswith("- ")]
    return "<ul class=\"pontos\">" + "".join(f"<li>{e(i[0].upper() + i[1:])}.</li>" for i in itens) + "</ul>"


# MARK: Paginas de texto (suporte, privacidade, termos)


def pagina_de_texto(ctx, base, rota, titulo, descricao, corpo_html, ativa=None, sobretitulo=""):
    sobre = f'<p class="sobretitulo">{e(sobretitulo)}</p>' if sobretitulo else ""
    corpo = f"""<header class="cabeca-pagina"><div class="wrap estreito">{sobre}<h1 class="titulo-pagina">{e(titulo)}</h1></div></header>
<article class="artigo"><div class="wrap estreito">
{corpo_html}
</div></article>"""
    return moldura(ctx, base, rota, titulo, descricao, corpo, ativa)


# MARK: Auditoria


def _nome_secao(nome):
    texto = acentos.acentuar(nome)
    return texto[0].upper() + texto[1:]


def pagina_auditoria(ctx, base):
    v = ctx["versao"]
    commit = ctx["commit"]
    sha = commit["sha"]
    ci = ctx["ci"]

    if ci is None:
        ci_html = "Sem dado<small>Este build foi gerado fora do GitHub Actions.</small>"
    else:
        rotulos = {"passou": "Passou", "falhou": "Falhou", "rodando": "Rodando", "cancelado": "Cancelada",
                   "sem": "Ainda sem resultado", "outro": "Sem conclusão"}
        rotulo = rotulos.get(ci["estado"], "Sem dado")
        detalhe = "Workflow verificar, no macOS: verificar.sh --testes, app em Release e testes de unidade."
        if ci.get("url"):
            detalhe += f' <a href="{e(ci["url"])}">Ver a execução</a>.'
        ci_html = f"{rotulo}<small>{detalhe}</small>"

    commit_html = "Sem git neste build"
    if sha:
        commit_html = (f'<a href="{dados.REPO}/commit/{sha}"><code>{sha[:12]}</code></a>'
                       f'<small>{data_longa(commit["data"])}, na main.</small>')

    publicado = f"""<dl class="publicado">
<div><dt>Commit publicado</dt><dd>{commit_html}</dd></div>
<div><dt>Verificação no CI</dt><dd>{ci_html}</dd></div>
<div><dt>Versão do app</dt><dd>{e(v["marketing"])} (build {e(v["build"])})<small>De project.yml. {"Disponível na App Store." if ctx["app_store_url"] else "Em preparação para a App Store."}</small></dd></div>
</dl>"""

    ref = sha or "main"
    xcode = (dados.RAIZ / ".xcode-version").read_text(encoding="utf-8").strip() if (dados.RAIZ / ".xcode-version").exists() else "Xcode"
    passos = f"""<ol class="passos">
<li><code>git clone {dados.REPO}.git
cd escalibur-wallet
git checkout {e(ref[:12])}</code><span>O mesmo commit desta página.</span></li>
<li><code>./tools/verificar.sh --testes</code><span>As verificações abaixo e os {numero(ctx["n_testes"])} testes do núcleo. Num Mac com {e(xcode)}.</span></li>
<li><code>python3 tools/gerar-site.py build/site</code><span>Gera este site de novo, com os mesmos números.</span></li>
</ol>"""

    grupos = []
    for i, secao in enumerate(ctx["verificacoes"]):
        itens = []
        for linha, mensagem, so_testes in secao["itens"]:
            marca = '<span class="marca-teste">com --testes</span>' if so_testes else ""
            itens.append(
                f'<li><span>{acento(mensagem)}{marca} '
                f'<span class="onde"><a href="{blob(ctx, "tools/verificar.sh", linha)}" aria-label="verificar.sh, linha {linha}">linha {linha}</a></span></span></li>'
            )
        grupos.append(
            f'<section class="cartao"><h3>{e(_nome_secao(secao["nome"]))}<span class="conta">{len(secao["itens"])}</span></h3>'
            f'<ul class="checagens">{"".join(itens)}</ul></section>'
        )

    hosts = []
    for rotulo, lista in ctx["grupos_hosts"]:
        chips = "".join(f"<li>{e(h)}</li>" for h in lista)
        hosts.append(f'<section class="cartao"><h3>{e(rotulo)}<span class="conta">{len(lista)}</span></h3>'
                     f'<ul class="hosts">{chips}</ul></section>')

    travas = []
    for t in ctx["travas"]:
        meta = []
        if t["origem"]:
            meta.append(f'Origem: <a href="{e(t["origem"])}">{e(t["origem"].replace("https://", ""))}</a>')
        if t["versao"]:
            meta.append(f"versão <code>{e(t['versao'])}</code>")
        for chave, valor in t["extra"]:
            rotulo = {"tag_objeto": "objeto da tag", "tarball_sha256": "SHA-256 do pacote"}.get(chave, chave)
            meta.append(f"{rotulo} <code>{e(valor)}</code>")
        linhas = "".join(f"<div><dt>{e(nome)}</dt><dd>{e(digesto)}</dd></div>" for nome, digesto in t["arquivos"])
        descricao = f"<p>{e(t['descricao'])}</p>" if t["descricao"] else ""
        travas.append(
            f'<details class="grupo"><summary><code>{e(t["arquivo"])}</code><span class="conta">{len(t["arquivos"])} arquivos</span></summary>'
            f'<div class="grupo-corpo"><div class="trava-meta">{descricao}<p>{" · ".join(meta)}</p>'
            f'<p><a href="{blob(ctx, t["arquivo"])}">Ver {e(t["arquivo"])} no GitHub</a></p></div>'
            f'<dl class="digestos">{linhas}</dl></div></details>'
        )

    arquivos = []
    grupo_atual = None
    for grupo, slug, titulo, caminho in ARQUIVOS_CHAVE:
        info = ctx["arquivos_chave"][slug]
        if grupo != grupo_atual:
            if grupo_atual is not None:
                arquivos.append("</ul>")
            arquivos.append(f'<h3 class="sobretitulo subtitulo-bloco">{e(grupo)}</h3><ul class="arquivos">')
            grupo_atual = grupo
        arquivos.append(
            f'<li><a href="{base}auditoria/codigo/{slug}/"><b>{e(titulo)}</b>'
            f'<span>{e(info["resumo_curto"])}</span><code>{e(caminho)} · {numero(info["linhas"])} linhas</code></a></li>'
        )
    arquivos.append("</ul>")
    arquivos_html = "".join(arquivos)

    auditorias = "".join(
        f'<li><b>{e(a["titulo"])}</b><a href="{blob(ctx, a["caminho"])}">Ler o relatório no GitHub</a></li>'
        for a in ctx["auditorias"]
    )

    corpo = f"""<header class="cabeca-pagina"><div class="wrap">
<p class="sobretitulo">Auditoria</p>
<h1 class="titulo-pagina">Confira você mesmo.</h1>
<p class="lead">Tudo nesta página saiu do repositório no build que a publicou: as verificações que rodam a cada mudança, os servidores que o app pode chamar, o código de terceiros travado por digesto e os arquivos que guardam as chaves. Nada é buscado depois.</p>
</div></header>

<section class="bloco" aria-labelledby="t-build"><div class="wrap">
<h2 id="t-build">Este build</h2>
{publicado}
<h3 class="sobretitulo subtitulo-bloco">Conferir na sua máquina</h3>
{passos}
</div></section>

<section class="bloco" aria-labelledby="t-verificacoes"><div class="wrap">
<h2 id="t-verificacoes">{ctx["n_verificacoes"]} verificações</h2>
<p class="lead intro">O <code>tools/verificar.sh</code> confere no código o que o app promete em texto. Cada linha abaixo é uma afirmação que o script prova a cada mudança, no CI, e para o merge se falhar. Cada uma leva à linha onde mora.</p>
<div class="mosaico">{"".join(grupos)}</div>
</div></section>

<section class="bloco" aria-labelledby="t-hosts"><div class="wrap">
<h2 id="t-hosts">{len(ctx["hosts"])} servidores, e nenhum outro</h2>
<p class="lead intro">O app só fala com os endereços do <code>hosts.lock</code>. O cliente HTTP recusa qualquer outro em tempo de execução, e cada um está na Política de privacidade, com o que vê. Agrupados como a Política descreve.</p>
<p class="apoio links-bloco">{link_codigo(base, "hosts-permitidos", "Ler a lista compilada no app")} · <a href="{blob(ctx, "hosts.lock")}">hosts.lock no GitHub</a></p>
<div class="mosaico">{"".join(hosts)}</div>
</div></section>

<section class="bloco" aria-labelledby="t-travas"><div class="wrap">
<h2 id="t-travas">Código de terceiros, travado por digesto</h2>
<p class="lead intro">Nenhum pacote baixado no build e nenhum binário de terceiro. O que vem de fora está no repositório, compilado do fonte, e cada arquivo tem o SHA-256 conferido pelo verificador.</p>
<div class="verificacoes">{"".join(travas)}</div>
</div></section>

<section class="bloco" aria-labelledby="t-codigo"><div class="wrap">
<h2 id="t-codigo">O código que importa</h2>
<p class="lead intro">Os arquivos que assinam, conferem o que se assina, guardam as chaves e falam com a rede, linha a linha, no commit publicado. Cada linha leva à mesma linha no GitHub.</p>
<div class="arquivos-grupos">{arquivos_html}</div>
</div></section>

<section class="bloco" aria-labelledby="t-auditorias"><div class="wrap">
<h2 id="t-auditorias">Auditorias de segurança</h2>
<p class="lead intro">Os relatórios das revisões de segurança, com os achados e o que foi feito de cada um.</p>
<ul class="auditorias">{auditorias}</ul>
</div></section>"""
    return moldura(ctx, base, "auditoria", "Auditoria", "Confira o código da Escalibur Wallet: verificações, servidores, dependências travadas e os arquivos que guardam as chaves, gerados do repositório.", corpo, "auditoria")


def pagina_codigo(ctx, base, slug, titulo, caminho):
    info = ctx["arquivos_chave"][slug]
    fonte = info["fonte"]
    linhas = codigo.destacar(caminho, fonte)
    if linhas and linhas[-1] == "" and fonte.endswith("\n"):
        linhas = linhas[:-1]
    sha = ctx["commit"]["sha"]
    corpo_linhas = "".join(
        f'<tr id="L{n}"><td class="n"><a href="{blob(ctx, caminho, n)}" aria-label="Linha {n} no GitHub">{n}</a></td>'
        f'<td class="l">{conteudo or " "}</td></tr>'
        for n, conteudo in enumerate(linhas, 1)
    )
    no_commit = f"no commit {sha[:7]}" if sha else "na main"
    corpo = f"""<header class="codigo-cabeca"><div class="wrap">
<a class="voltar" href="{base}auditoria/#t-codigo">Auditoria</a>
<h1 class="titulo-pagina">{e(titulo)}</h1>
<code class="caminho">{e(caminho)}</code>
<p class="lead">{e(info["resumo"])}</p>
<div class="codigo-meta"><span>{numero(len(linhas))} linhas</span><span>SHA-256 <code>{info["digesto"][:16]}…</code></span><a href="{blob(ctx, caminho)}">Abrir no GitHub, {no_commit}</a></div>
</div></header>
<div class="wrap"><div class="fonte" tabindex="0" aria-label="Código de {e(caminho)}"><table><tbody>{corpo_linhas}</tbody></table></div></div>"""
    return moldura(ctx, base, f"auditoria/codigo/{slug}", titulo, f"{titulo}: {caminho}, linha a linha, no código da Escalibur Wallet.", corpo, "auditoria")


# MARK: Redes e moedas


def _tempo(segundos):
    if segundos < 60:
        return f"cerca de {segundos} s"
    minutos = round(segundos / 60)
    return f"cerca de {minutos} min"


def pagina_redes(ctx, base):
    redes = ctx["redes"]
    por_id = {r["id"]: r for r in redes}
    linhas = []
    for r in redes:
        familia = dados.FAMILIAS.get(r["familia"], r["familia"])
        if r["chain_id"] is not None:
            familia += f", chainId {r['chain_id']}"
        elif familia == r["nome"]:
            familia = f"curva {dados.CURVAS.get(r['familia'], '')}".strip()
        detalhes = [r["simbolo"], familia]
        segunda = [f"confirma em {_tempo(r['segundos'])}"]
        if r["tag"]:
            segunda.append(f"pede {r['tag']}")
        segunda.append(f"explorador {r['explorador']}")
        linhas.append(
            f'<li>{logo_rede(ctx, base, r)}<div><b>{e(r["nome"])}</b><small>{e(" · ".join(detalhes))}</small>'
            f'<small>{e(", ".join(segunda))}</small></div></li>'
        )

    # Uma linha por moeda: mesmo simbolo e mesmo id de preco. O ETH da Binance na BNB tem
    # o preco do WETH, mas nao e o WETH: fica na linha dele.
    grupos = {}
    for t in ctx["tokens"]:
        grupos.setdefault((t["simbolo"].upper(), t["gecko"]), []).append(t)
    ordenados = sorted(grupos.values(), key=lambda g: (g[0]["simbolo"].lower(), g[0]["nome"].lower()))
    itens = []
    for grupo in ordenados:
        primeiro = grupo[0]
        estavel = '<span class="selo-estavel">stablecoin</span>' if primeiro["estavel"] else ""
        minis = "".join(logo_rede(ctx, base, por_id[t["rede"]]) for t in grupo[:6] if t["rede"] in por_id)
        resto = f'<span class="mais-redes">+{len(grupo) - 6}</span>' if len(grupo) > 6 else ""
        nomes_redes = ", ".join(por_id[t["rede"]]["nome"] for t in grupo if t["rede"] in por_id)
        contratos = []
        for t in grupo:
            rede = por_id.get(t["rede"])
            if not rede:
                continue
            if "contrato" in t:
                alvo, rotulo = t["contrato"], t["contrato"]
            else:
                alvo, rotulo = t["emissor"], f"{t['simbolo']} emitido por {t['emissor']}"
            url = (rede["explorador_endereco"] or "").replace("{address}", alvo)
            link = f'<a href="{e(url)}">{e(rotulo)}</a>' if url.startswith("https://") else e(rotulo)
            variante = f" · {t['nome']}" if t["nome"] != primeiro["nome"] else ""
            contratos.append(f"<div><dt>{e(rede['nome'])}, {t['casas']} casas{e(variante)}</dt><dd>{link}</dd></div>")
        busca = " ".join([primeiro["simbolo"], primeiro["nome"], primeiro["gecko"], nomes_redes]).lower()
        busca = re.sub(r"\s+", " ", busca)
        plural = "redes" if len(grupo) > 1 else "rede"
        itens.append(
            f'<li data-busca="{e(acentos_fora(busca))}"><details class="token"><summary>{logo_token(ctx, base, primeiro)}'
            f'<span class="token-nome"><b>{e(primeiro["simbolo"])}</b>{estavel}<small>{e(primeiro["nome"])} · {len(grupo)} {plural}</small></span>'
            f'<span class="mini-redes" aria-label="{e(nomes_redes)}">{minis}{resto}</span></summary>'
            f'<dl class="contratos">{"".join(contratos)}</dl></details></li>'
        )

    corpo = f"""<header class="cabeca-pagina"><div class="wrap">
<p class="sobretitulo">Redes e moedas</p>
<h1 class="titulo-pagina">{len(redes)} redes.<br>{len(ctx["tokens"])} tokens conferidos.</h1>
<p class="lead">Esta página sai do código do app a cada publicação: as redes de <a href="{blob(ctx, "Kit/Sources/EscaliburChains/Chain.swift")}">Chain.swift</a> e os tokens de <a href="{blob(ctx, "Kit/Sources/EscaliburChains/TokenRegistry.swift")}">TokenRegistry.swift</a>. Nenhuma rede ou token entra no app por resposta de servidor.</p>
</div></header>

<section class="bloco" aria-labelledby="t-redes"><div class="wrap">
<h2 id="t-redes">As redes</h2>
<p class="lead intro">Cada carteira é uma frase BIP-39 de 12 ou 24 palavras, derivada pelos caminhos padrão de cada rede. O chainId, o explorador e o tempo de confirmação são constantes compiladas.</p>
<ul class="tabela-redes">{"".join(linhas)}</ul>
</div></section>

<section class="bloco" aria-labelledby="t-tokens"><div class="wrap">
<h2 id="t-tokens">Os tokens conferidos</h2>
<p class="lead intro">{len(grupos)} moedas em {len(ctx["tokens"])} contratos. Cada contrato foi conferido na fonte oficial do emissor e lido em dois nós da rede antes de entrar na lista. Token fora dela aparece no app como não verificado, sem entrar no saldo total sem preço pelo contrato.</p>
<div class="busca"><label class="apoio" for="busca-token">Procurar por nome, símbolo ou rede</label><br><input id="busca-token" type="search" placeholder="USDC, Solana, Lido…" autocomplete="off" spellcheck="false"></div>
<ul class="lista-tokens">{"".join(itens)}</ul>
<p id="busca-vazia" class="apoio" hidden>Nenhum token da lista com esse nome. Fora da lista, o app mostra o token como não verificado.</p>
</div></section>"""
    return moldura(ctx, base, "redes", "Redes e moedas", f"As {len(redes)} redes e os {len(ctx['tokens'])} tokens conferidos da Escalibur Wallet, gerados do código do app.", corpo, "redes")


def acentos_fora(texto):
    import unicodedata
    return "".join(c for c in unicodedata.normalize("NFD", texto) if unicodedata.category(c) != "Mn")


# MARK: Novidades


def corpo_do_commit(blocos):
    partes, lista = [], []

    def fecha():
        if lista:
            partes.append("<ul>" + "".join(f"<li>{acento(i)}</li>" for i in lista) + "</ul>")
            lista.clear()

    for tipo, texto in blocos:
        if tipo == "item":
            lista.append(texto)
            continue
        fecha()
        if tipo == "titulo":
            partes.append(f"<h3>{acento(texto)}</h3>")
        else:
            partes.append(f"<p>{acento(texto)}</p>")
    fecha()
    return "".join(partes)


def pagina_novidades(ctx, base):
    v = ctx["versao"]
    entregas = []
    for c in ctx["commits"]:
        corpo = corpo_do_commit(c["corpo"])
        detalhe = f'<details><summary>O que mudou</summary><div class="entrega-corpo">{corpo}</div></details>' if corpo else ""
        entregas.append(
            f'<article class="entrega" id="c-{c["sha"][:7]}"><time datetime="{data_iso(c["data"])}">{data_longa(c["data"])}</time>'
            f'<h2>{acento(c["assunto"])}</h2>{detalhe}'
            f'<p class="commit"><a href="{dados.REPO}/commit/{c["sha"]}">Commit {c["sha"][:7]} no GitHub</a></p></article>'
        )
    situacao = "Disponível na App Store." if ctx["app_store_url"] else "Em preparação para a App Store."
    vazio = "<p>O histórico não estava disponível neste build.</p>" if not entregas else ""
    corpo = f"""<header class="cabeca-pagina"><div class="wrap estreito">
<p class="sobretitulo">Novidades</p>
<h1 class="titulo-pagina">O que mudou.</h1>
<p class="lead">Versão <strong>{e(v["marketing"])}</strong> (build {e(v["build"])}). {situacao}</p>
<p class="apoio">Esta página é gerada a cada publicação, do histórico da main no GitHub: cada item é uma entrega, com o que mudou e o commit. Os textos do repositório são escritos sem acento; aqui o acento volta onde não há dúvida.</p>
</div></header>
<section class="bloco"><div class="wrap estreito">{vazio}{"".join(entregas)}</div></section>"""
    return moldura(ctx, base, "novidades", "Novidades", "As últimas atualizações da Escalibur Wallet, geradas do histórico de commits.", corpo, "novidades")


# MARK: 404


def pagina_404(ctx):
    base = "/escalibur-wallet/"
    corpo = """<header class="cabeca-pagina"><div class="wrap estreito">
<p class="sobretitulo">Erro 404</p>
<h1 class="titulo-pagina">Esta página não existe.</h1>
<p class="lead">O endereço pode ter mudado. Comece pelo início, ou vá direto ao que procura.</p>
<div class="botoes"><a class="botao botao-principal" href="/escalibur-wallet/">Ir para o início</a><a class="botao botao-secundario" href="/escalibur-wallet/suporte/">Suporte</a></div>
</div></header>"""
    return moldura(ctx, base, "404", "Página não encontrada", "Página não encontrada.", corpo)


def digesto(texto):
    return hashlib.sha256(texto.encode("utf-8")).hexdigest()
