"""Tudo o que o site mostra sobre o app sai daqui, lido do repositorio no build.

Redes de Chain.swift, tokens de TokenRegistry.swift, versao de project.yml, novidades do
historico da main, hosts do hosts.lock, dependencias dos *.lock, verificacoes do
tools/verificar.sh. Nada e digitado a mao: se o codigo muda, o site muda junto. Quando
a leitura nao reconhece um trecho, o gerador para com erro em vez de publicar uma lista
pela metade.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent.parent
REPO = "https://github.com/tmzzjr/escalibur-wallet"
CHAIN = RAIZ / "Kit/Sources/EscaliburChains/Chain.swift"
TOKENS = RAIZ / "Kit/Sources/EscaliburChains/TokenRegistry.swift"
LOGOS = RAIZ / "App/EscaliburWallet/Resources/Assets.xcassets/Logos"
COIN_LOGO = RAIZ / "App/EscaliburWallet/Design/CoinLogo.swift"
PROJETO = RAIZ / "project.yml"
HOSTS = RAIZ / "hosts.lock"
PRIVACIDADE = RAIZ / "App/EscaliburWallet/Resources/Legal/privacidade.md"
VERIFICAR = RAIZ / "tools/verificar.sh"


def falha(mensagem):
    sys.exit(f"gerar-site: {mensagem}")


# MARK: Versao


def versao():
    texto = PROJETO.read_text(encoding="utf-8")
    marketing = re.search(r'MARKETING_VERSION:\s*"?([0-9][0-9.]*)"?', texto)
    build = re.search(r'CURRENT_PROJECT_VERSION:\s*"?([0-9]+)"?', texto)
    if not marketing or not build:
        falha("MARKETING_VERSION ou CURRENT_PROJECT_VERSION fora do project.yml")
    return {"marketing": marketing.group(1), "build": build.group(1)}


# MARK: Redes

FAMILIAS = {
    "utxo": "UTXO", "evm": "EVM", "solana": "Solana", "xrpl": "XRP Ledger", "stellar": "Stellar",
    "tron": "Tron", "ton": "TON", "sui": "Sui", "cardano": "Cardano", "polkadot": "Polkadot",
    "near": "NEAR", "aptos": "Aptos",
}
CURVAS = {
    "utxo": "secp256k1", "evm": "secp256k1", "xrpl": "secp256k1", "tron": "secp256k1",
    "solana": "Ed25519", "stellar": "Ed25519", "ton": "Ed25519", "sui": "Ed25519", "cardano": "Ed25519",
    "polkadot": "Ed25519", "near": "Ed25519", "aptos": "Ed25519",
}
TAGS = {"none": None, "xrplTag": "tag de destino", "stellarMemo": "memo", "tonComment": "comentário"}


def _campo(bloco, nome, padrao=r'"([^"]*)"'):
    achado = re.search(rf"\b{nome}:\s*{padrao}", bloco)
    return achado.group(1) if achado else None


def redes():
    """As redes na ordem de `Chain.all`, a mesma da interface."""
    texto = CHAIN.read_text(encoding="utf-8")
    porvar = {}
    for var, bloco in re.findall(r"static let (\w+) = Chain\((.*?)\n    \)", texto, re.S):
        evm_id = _campo(bloco, "evmChainID", r"(nil|\d+)")
        porvar[var] = {
            "id": _campo(bloco, "id"), "nome": _campo(bloco, "name"), "familia": _campo(bloco, "family", r"\.(\w+)"),
            "simbolo": _campo(bloco, "nativeSymbol"), "nome_nativo": _campo(bloco, "nativeName"),
            "casas": int(_campo(bloco, "nativeDecimals", r"(\d+)") or 0), "gecko": _campo(bloco, "coingeckoID"),
            "chain_id": None if evm_id in (None, "nil") else int(evm_id),
            "explorador": _campo(bloco, "explorerName"), "explorador_endereco": _campo(bloco, "explorerAddress"),
            "segundos": int(_campo(bloco, "typicalConfirmationSeconds", r"(\d+)") or 0),
            "tag": TAGS.get(_campo(bloco, "destinationTag", r"\.(\w+)")),
            "slip44": int(_campo(bloco, "coinType", r"(\d+)") or 0),
        }
    padrao_evm = re.compile(
        r'static let (\w+) = evm\("([^"]+)", "([^"]+)", chainID: (\d+), symbol: "([^"]+)", nativeName: "([^"]+)", '
        r'gecko: "([^"]+)",\s*explorer: "([^"]+)", explorerName: "([^"]+)", seconds: (\d+)\)'
    )
    for var, ident, nome, chain_id, simbolo, nativo, gecko, explorador, nome_explorador, segundos in padrao_evm.findall(texto):
        porvar[var] = {
            "id": ident, "nome": nome, "familia": "evm", "simbolo": simbolo, "nome_nativo": nativo, "casas": 18,
            "gecko": gecko, "chain_id": int(chain_id), "explorador": nome_explorador,
            "explorador_endereco": f"{explorador}/address/{{address}}", "segundos": int(segundos), "tag": None, "slip44": 60,
        }
    lista = re.search(r"static let all: \[Chain\] = \[(.*?)\]", texto, re.S)
    if not lista:
        falha("Chain.all nao encontrado em Chain.swift")
    ordem = re.findall(r"\.(\w+)", lista.group(1))
    faltando = [v for v in ordem if v not in porvar]
    if faltando:
        falha(f"redes de Chain.all sem definicao reconhecida: {faltando}")
    saida = [porvar[v] for v in ordem]
    for rede in saida:
        if not all(rede[k] for k in ("id", "nome", "familia", "simbolo", "gecko")):
            falha(f"rede incompleta em Chain.swift: {rede}")
    return saida


# MARK: Tokens


def _sem_comentarios(texto):
    """Tira `//` ate o fim da linha, fora de string."""
    saida, em_string, i = [], False, 0
    while i < len(texto):
        c = texto[i]
        if c == '"' and (i == 0 or texto[i - 1] != "\\"):
            em_string = not em_string
        if not em_string and texto.startswith("//", i):
            fim = texto.find("\n", i)
            i = len(texto) if fim < 0 else fim
            continue
        saida.append(c)
        i += 1
    return "".join(saida)


def _entradas_do_array(corpo):
    """Os elementos de nivel zero de um array Swift, separados por virgula."""
    entradas, atual, nivel, em_string = [], [], 0, False
    for i, c in enumerate(corpo):
        if c == '"' and (i == 0 or corpo[i - 1] != "\\"):
            em_string = not em_string
        if not em_string:
            if c in "([":
                nivel += 1
            elif c in ")]":
                nivel -= 1
            elif c == "," and nivel == 0:
                entradas.append("".join(atual))
                atual = []
                continue
        atual.append(c)
    entradas.append("".join(atual))
    return [" ".join(e.split()) for e in entradas if e.strip()]


_ESTAVEL = r'(?:, stable: (true|false))?'
_PADROES_TOKEN = [
    ("erc20", re.compile(rf'^erc20\("(\w+)", "([^"]+)", "([^"]+)", "([^"]+)", (\d+), "([^"]+)"{_ESTAVEL}\)$')),
    ("spl", re.compile(rf'^spl\("([^"]+)", "([^"]+)", "([^"]+)", (\d+), "([^"]+)"{_ESTAVEL}\)$')),
    ("issued", re.compile(rf'^issued\("(\w+)", code: "([^"]+)", issuer: "([^"]+)", "([^"]+)", "([^"]+)", (\d+), "([^"]+)"{_ESTAVEL}\)$')),
    ("asset", re.compile(
        r'^Asset\(chainID: "(\w+)", kind: \.(?:token\(contract: "([^"]+)"\)|issued\(code: "([^"]+)", issuer: "([^"]+)"\)), '
        r'symbol: "([^"]+)", name: "([^"]+)", decimals: (\d+), coingeckoID: "([^"]+)", isStablecoin: (true|false)\)$'
    )),
]


def _bloco_tokens():
    texto = TOKENS.read_text(encoding="utf-8")
    inicio = texto.find("public static let tokens: [Asset] = [")
    if inicio < 0:
        falha("TokenRegistry.tokens nao encontrado")
    texto = _sem_comentarios(texto[inicio:])
    abre = texto.index("[Asset] = [") + len("[Asset] = [")
    nivel, em_string = 1, False
    for i in range(abre, len(texto)):
        c = texto[i]
        if c == '"' and texto[i - 1] != "\\":
            em_string = not em_string
        if em_string:
            continue
        if c in "([":
            nivel += 1
        elif c in ")]":
            nivel -= 1
            if nivel == 0:
                return texto[abre:i]
    falha("fim de TokenRegistry.tokens nao encontrado")


def tokens():
    """Os tokens da lista conferida, na ordem do arquivo."""
    saida = []
    for entrada in _entradas_do_array(_bloco_tokens()):
        for tipo, padrao in _PADROES_TOKEN:
            achado = padrao.match(entrada)
            if not achado:
                continue
            g = achado.groups()
            if tipo == "erc20":
                item = dict(rede=g[0], contrato=g[1], simbolo=g[2], nome=g[3], casas=int(g[4]), gecko=g[5], estavel=g[6] == "true")
            elif tipo == "spl":
                item = dict(rede="solana", contrato=g[0], simbolo=g[1], nome=g[2], casas=int(g[3]), gecko=g[4], estavel=g[5] == "true")
            elif tipo == "issued":
                item = dict(rede=g[0], codigo=g[1], emissor=g[2], simbolo=g[3], nome=g[4], casas=int(g[5]), gecko=g[6], estavel=g[7] == "true")
            else:
                item = dict(rede=g[0], simbolo=g[4], nome=g[5], casas=int(g[6]), gecko=g[7], estavel=g[8] == "true")
                if g[1]:
                    item["contrato"] = g[1]
                else:
                    item["codigo"], item["emissor"] = g[2], g[3]
            saida.append(item)
            break
        else:
            falha(f"token que o gerador nao sabe ler em TokenRegistry.swift: {entrada[:160]}")
    return saida


# MARK: Logos


def conjuntos_de_logo():
    """Os mesmos conjuntos do `CoinLogo` do app: logo sem circulo proprio vai num disco,
    logo escuro ganha disco claro."""
    texto = COIN_LOGO.read_text(encoding="utf-8") if COIN_LOGO.exists() else ""

    def conjunto(nome):
        achado = re.search(rf"static let {nome}: Set<String> = \[([^\]]*)\]", texto)
        return set(re.findall(r'"([^"]+)"', achado.group(1))) if achado else set()

    return conjunto("bareLogos"), conjunto("darkLogos")


def arquivo_de_logo(nome):
    """O arquivo de imagem do conjunto `nome` no catalogo do app, ou None."""
    pasta = LOGOS / f"{nome}.imageset"
    if not pasta.is_dir():
        return None
    try:
        conteudo = json.loads((pasta / "Contents.json").read_text(encoding="utf-8"))
        for imagem in conteudo.get("images", []):
            if imagem.get("filename") and (pasta / imagem["filename"]).is_file():
                return pasta / imagem["filename"]
    except (OSError, ValueError):
        return None
    return None


# MARK: Git


def _git(*args):
    try:
        return subprocess.run(["git", "-C", str(RAIZ), *args], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None


def commit_atual():
    sha = os.environ.get("GITHUB_SHA") or (_git("rev-parse", "HEAD") or "").strip()
    data = (_git("show", "-s", "--format=%cI", sha) or "").strip() if sha else ""
    return {"sha": sha or None, "data": data or None}


def commits(limite=40):
    """O historico da main pela primeira linha de pais: cada mescla conta como uma entrega."""
    saida = _git("log", "--first-parent", f"-n{limite}", "--format=%H%x1f%cI%x1f%s%x1f%b%x1e", "HEAD")
    if not saida:
        return []
    lista = []
    for registro in saida.split("\x1e"):
        partes = registro.strip("\n").split("\x1f")
        if len(partes) < 4:
            continue
        sha, data, assunto, corpo = partes
        if assunto.startswith("Merge "):
            continue
        lista.append({"sha": sha.strip(), "data": data.strip(), "assunto": assunto.strip(), "corpo": _corpo_do_commit(corpo)})
    return lista


def _corpo_do_commit(corpo):
    """O corpo em blocos: ('titulo', texto), ('item', texto) ou ('p', texto). Sem as
    linhas de coautoria."""
    blocos, atual = [], None
    for bruta in corpo.split("\n"):
        linha = bruta.rstrip()
        if re.match(r"^(Co-Authored-By|Signed-off-by|Co-authored-by):", linha.strip()):
            continue
        if not linha.strip():
            atual = None
            continue
        if linha.lstrip().startswith("- "):
            atual = ["item", linha.lstrip()[2:].strip()]
            blocos.append(atual)
        elif atual is not None and bruta.startswith(" "):
            atual[1] += " " + linha.strip()
        elif atual is not None and atual[0] == "p":
            atual[1] += " " + linha.strip()
        else:
            atual = ["p", linha.strip()]
            blocos.append(atual)
    # Paragrafo curto seguido de itens e titulo de grupo ("Troca", "Envio").
    for i, bloco in enumerate(blocos):
        if bloco[0] == "p" and len(bloco[1]) <= 40 and not bloco[1].endswith(".") and i + 1 < len(blocos) and blocos[i + 1][0] == "item":
            bloco[0] = "titulo"
    return [tuple(b) for b in blocos]


# MARK: Hosts e dependencias


def hosts():
    return [l.strip().replace("https://", "") for l in HOSTS.read_text(encoding="utf-8").splitlines() if l.strip()]


def grupos_de_hosts():
    """Os hosts agrupados pelo uso, como a Politica de privacidade descreve cada um."""
    todos = hosts()
    grupos, vistos = [], set()
    for linha in PRIVACIDADE.read_text(encoding="utf-8").splitlines():
        achado = re.match(r"^- \*\*(.+?):?\*\*:?\s*(.*)$", linha.strip())
        if not achado:
            continue
        do_grupo = [h for h in re.findall(r"`([^`]+)`", achado.group(2)) if h in todos and h not in vistos]
        if do_grupo:
            grupos.append((achado.group(1).rstrip(":"), do_grupo))
            vistos.update(do_grupo)
    resto = [h for h in todos if h not in vistos]
    if resto:
        grupos.append(("Outros", resto))
    return grupos


DESCRICAO_TRAVA = {
    "secp256k1.lock": "libsecp256k1 do bitcoin-core, a curva das assinaturas de Bitcoin, Ethereum, XRP Ledger e Tron. Compilada do fonte.",
    "argon2.lock": "Argon2 de referência, a derivação de chave do PIN e do envelope. Compilado do fonte.",
    "wordlists.lock": "As listas oficiais de palavras do BIP-39, uma por idioma.",
    "forca.lock": "As listas de frequência do medidor de força da senha do envelope (zxcvbn-ts, MIT).",
    "recuperacao.lock": "O decifrador de referência do envelope e a especificação do formato, usados nos testes.",
    "modelos.lock": "As texturas da moeda 3D do tour, recortadas de “Bit Coin”, de marcio3d (CC BY 4.0).",
}


def travas():
    """Os arquivos *.lock da raiz (menos o hosts.lock): cada arquivo travado por SHA-256."""
    saida = []
    for caminho in sorted(RAIZ.glob("*.lock")):
        if caminho.name == "hosts.lock":
            continue
        texto = caminho.read_text(encoding="utf-8")
        item = {"arquivo": caminho.name, "descricao": DESCRICAO_TRAVA.get(caminho.name, ""), "origem": None, "versao": None,
                "extra": [], "arquivos": []}
        try:
            dados = json.loads(texto)
        except ValueError:
            dados = None
        if isinstance(dados, dict):
            item["origem"] = dados.get("origem")
            item["versao"] = dados.get("versao")
            for chave in ("tag_objeto", "tarball_sha256"):
                if dados.get(chave):
                    item["extra"].append((chave, dados[chave]))
            arquivos = dados.get("arquivos") if isinstance(dados.get("arquivos"), dict) else {
                k: v for k, v in dados.items() if isinstance(v, str) and re.fullmatch(r"[0-9a-f]{64}", v)}
            item["arquivos"] = sorted(arquivos.items())
        else:
            for linha in texto.splitlines():
                achado = re.match(r"^([0-9a-f]{64})\s+\*?(.+)$", linha.strip())
                if achado:
                    item["arquivos"].append((achado.group(2), achado.group(1)))
        saida.append(item)
    return saida


# MARK: Verificacoes do verificar.sh


def verificacoes():
    """As verificacoes do tools/verificar.sh, por secao: o que cada `ok` garante e a
    linha onde mora. As de `--testes` vem marcadas: so rodam com o Kit compilado."""
    linhas = VERIFICAR.read_text(encoding="utf-8").splitlines()
    n_hosts = len(hosts())
    travas_por_nome = {t["arquivo"]: len(t["arquivos"]) for t in travas()}
    secoes, atual, so_testes, em_funcao, pular = [], None, False, False, False
    for numero, linha in enumerate(linhas, 1):
        # Funcao de varias linhas (a de uma linha so, como `ok() { ...; }`, nao conta).
        if re.match(r"^\s*\w+\(\)\s*\{\s*$", linha):
            em_funcao = True
        if em_funcao and re.match(r"^\}", linha):
            em_funcao = False
            continue
        # O ramo de --atualizar-hosts reescreve as listas: nao e verificacao.
        if '"--atualizar-hosts" ]; then' in linha:
            pular = True
            continue
        if pular:
            pular = not re.match(r"^\s*(elif|else|fi)\b", linha)
            if pular:
                continue
        if re.match(r'^if \[ "\$\{1:-\}" = "--testes" \]', linha):
            so_testes = True
        achado = re.match(r'^\s*secao "([^"]+)"', linha)
        if achado:
            atual = {"nome": achado.group(1), "itens": []}
            secoes.append(atual)
            continue
        chamada = re.match(r"^conferir_lock (\S+) \S+ (\S+)", linha)
        if chamada and atual is not None:
            lock, nome = chamada.groups()
            atual["itens"].append((numero, f"{travas_por_nome.get(lock, 0)} arquivos de {nome} conferem com {lock}", so_testes))
            continue
        if em_funcao or atual is None:
            continue
        for mensagem in re.findall(r'\bok "((?:\$\([^)]*\)|[^"\\]|\\.)*)"', linha):
            atual["itens"].append((numero, _limpa_mensagem(mensagem, n_hosts), so_testes))
    return [s for s in secoes if s["itens"]]


def _limpa_mensagem(mensagem, n_hosts):
    mensagem = mensagem.replace("$(wc -l < hosts.lock | tr -d ' ')", str(n_hosts))
    mensagem = re.sub(r"\s*\((?:[^()]|\([^)]*\))*\$[^)]*\)\)?", "", mensagem)
    mensagem = re.sub(r"\$\([^)]*\)|\$\{?\w+\}?", "", mensagem)
    mensagem = re.sub(r"\(\s*\)", "", mensagem)
    return " ".join(mensagem.split()).strip(" ,:")


# MARK: CI


def estado_ci():
    """O estado do workflow `verificar` para o commit publicado, que o workflow do site
    busca na API do GitHub e entrega num JSON (`SITE_CI`). Fora do CI: None."""
    caminho = os.environ.get("SITE_CI")
    if not caminho:
        return None
    try:
        dados = json.loads(Path(caminho).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    corridas = dados.get("workflow_runs") or []
    if not corridas:
        return {"estado": "sem", "url": None, "sha": None, "quando": None}
    corrida = corridas[0]
    if corrida.get("status") != "completed":
        estado = "rodando"
    else:
        estado = {"success": "passou", "failure": "falhou", "cancelled": "cancelado"}.get(corrida.get("conclusion"), "outro")
    url = corrida.get("html_url") or ""
    if not url.startswith(REPO + "/"):
        url = None
    return {"estado": estado, "url": url, "sha": corrida.get("head_sha"), "quando": corrida.get("updated_at")}
