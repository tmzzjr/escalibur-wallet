#!/usr/bin/env python3
"""Baixa os logos das moedas e redes da lista curada para dentro do app.

Logos embarcados, e nao baixados em tempo de uso: pedir o logo de um token a um CDN
conta ao CDN quais tokens a carteira tem. Roda uma vez por versao; o resultado vai
para o repositorio e passa por revisao como qualquer outro arquivo.

    python3 tools/baixar-logos.py              todos
    python3 tools/baixar-logos.py celo linea   so os nomes dados (id do CoinGecko da
                                               moeda ou id da rede em Chain.swift)
    python3 tools/baixar-logos.py --mercado 250
                                               as 250 maiores do Mercado que ainda nao
                                               tem logo, em 128 px: com o CoinGecko em
                                               429, a lista de reserva nao traz logo

So aceita imagem dos hosts de imagem do CoinGecko (os mesmos do `ImageLoader` do app),
id em [a-z0-9-] e ate 160 KB: uma resposta adulterada nao poe arquivo local nem de
outro host no repositorio (pentest de 14/10/2026, B7).
"""
import json, os, re, sys, time, urllib.error, urllib.request, hashlib, shutil, subprocess, tempfile

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(RAIZ, "App/EscaliburWallet/Resources/Assets.xcassets/Logos")
MOEDAS = ["bitcoin", "ethereum", "solana", "ripple", "stellar", "tron", "the-open-network", "litecoin",
          "dogecoin", "binancecoin", "avalanche-2", "polygon-ecosystem-token", "tether", "usd-coin", "dai",
          "wrapped-bitcoin", "weth", "chainlink", "uniswap", "arbitrum", "optimism", "jupiter-exchange-solana",
          "plasma", "okb", "sonic-3", "celo", "ripple-usd", "wrapped-steth", "usds", "leo-token",
          "coinbase-wrapped-btc", "binance-bitcoin", "binance-peg-xrp", "binance-peg-dogecoin", "binance-peg-cardano", "binance-peg-polkadot", "binance-peg-litecoin", "binance-peg-avalanche", "binance-peg-near-protocol", "binance-peg-sol", "wrapped-eeth", "ethena-usde", "susds", "usd1-wlfi", "crypto-com-chain",
          "global-dollar", "ethena", "paypal-usd", "ondo-finance", "tether-gold", "aave", "mantle", "aster-2",
          "sky", "morpho", "pax-gold", "pepe", "usdd", "bitget-token", "ethena-staked-usde", "jito-staked-sol",
          "pancakeswap-token", "render-token", "rocket-pool-eth", "nexo", "aerodrome-finance",
          "injective-protocol", "gho", "ether-fi", "pyth-network", "official-trump", "raydium", "fetch-ai",
          "curve-dao-token", "virtual-protocol", "coinbase-wrapped-staked-eth", "true-usd", "usdtb", "euro-coin",
          "pendle", "lido-dao", "the-graph", "gnosis", "jito-governance-token", "starknet",
          "ethereum-name-service", "syrup", "eigenlayer", "trust-wallet-token", "compound-governance-token",
          "crvusd", "agora-dollar", "convex-finance", "immutable-x", "havven", "basic-attention-token",
          "the-sandbox", "golem"]
MOEDAS += ["sui"]
MOEDAS += ["cardano"]
MOEDAS += ["polkadot"]
MOEDAS += ["near"]
MOEDAS += ["aptos"]
MOEDAS += ["shiba-inu", "bnb-frog-inu"]
# Provedores de troca com token proprio: o logo e o do token no CoinGecko. LI.FI e
# De¹ nao tem token; o app desenha a inicial.
PROVEDORES = {"kyberswap": "kyber-network-crystal", "cow": "cow-protocol", "velora": "paraswap",
              "jupiter": "jupiter-exchange-solana"}
REDES = {"base": "base", "arbitrum": "arbitrum-one", "optimism": "optimistic-ethereum", "polygon": "polygon-pos",
         "bnb": "binance-smart-chain", "avalanche": "avalanche", "ethereum": "ethereum", "solana": "solana",
         "tron": "tron", "ton": "the-open-network", "stellar": "stellar", "xrpl": "xrp", "litecoin": "litecoin",
         "dogecoin": "dogecoin", "bitcoin": "bitcoin",
         "plasma": "plasma", "xlayer": "x-layer", "linea": "linea", "unichain": "unichain", "sonic": "sonic",
         "celo": "celo"}
REDES["sui"] = "sui"
REDES["cardano"] = "cardano"
REDES["polkadot"] = "polkadot"
REDES["near"] = "near-protocol"
REDES["aptos"] = "aptos"
ARGS = sys.argv[1:]
MERCADO = 0
if ARGS[:1] == ["--mercado"]:
    MERCADO = int(ARGS[1]) if len(ARGS) > 1 else 250
    ARGS = []
SO = set(ARGS)
ORIGENS = ("https://coin-images.coingecko.com/", "https://assets.coingecko.com/")
API = "https://api.coingecko.com/api/v3/"
ID = re.compile(r"^[a-z0-9-]{1,80}$")
LIMITE = 160 * 1024

def get(url):
    if not (url.startswith(API) or url.startswith(ORIGENS)):
        raise SystemExit("host recusado: " + url)
    req = urllib.request.Request(url, headers={"User-Agent": "EscaliburWallet-tools"})
    # O CoinGecko sem chave limita por minuto: 429 espera e tenta de novo.
    for tentativa in range(6):
        try:
            with urllib.request.urlopen(req, timeout=30) as resposta:
                return resposta.read(LIMITE + 1 if not url.startswith(API) else 8 * 1024 * 1024)
        except urllib.error.HTTPError as erro:
            if erro.code != 429 or tentativa == 5: raise
            time.sleep(20 * (tentativa + 1))

def webp_para_png(dados):
    """O CoinGecko serve alguns logos so em WebP. O app so decodifica PNG e JPEG (menos
    decodificador no processo que assina), entao o WebP vira PNG aqui, com o sips do macOS."""
    if not shutil.which("sips"): return None
    with tempfile.TemporaryDirectory() as pasta:
        origem, destino = os.path.join(pasta, "a.webp"), os.path.join(pasta, "a.png")
        open(origem, "wb").write(dados)
        r = subprocess.run(["sips", "-s", "format", "png", origem, "--out", destino], capture_output=True)
        if r.returncode != 0 or not os.path.exists(destino): return None
        return open(destino, "rb").read()

def reduzir(dados, lado):
    """Logo do Mercado em `lado` px: a lista mostra 40 pt."""
    with tempfile.TemporaryDirectory() as pasta:
        origem, destino = os.path.join(pasta, "a.png"), os.path.join(pasta, "b.png")
        open(origem, "wb").write(dados)
        r = subprocess.run(["sips", "-s", "format", "png", "-Z", str(lado), origem, "--out", destino], capture_output=True)
        return open(destino, "rb").read() if r.returncode == 0 and os.path.exists(destino) else dados

def salvar(nome, url, lado=None):
    if not ID.match(nome.split("-", 1)[1] if "-" in nome else nome) or not isinstance(url, str) or not url.startswith(ORIGENS):
        print("recusado", nome, url); return
    dados = get(url)
    if len(dados) > LIMITE:
        print("grande demais", nome, len(dados)); return
    if dados[:4] == b"RIFF" and dados[8:12] == b"WEBP":
        dados = webp_para_png(dados) or dados
    if not (dados.startswith(b"\x89PNG") or dados.startswith(b"\xff\xd8\xff")):
        print("formato recusado", nome, url); return
    if lado: dados = reduzir(dados, lado)
    ext = "png" if dados.startswith(b"\x89PNG") else "jpg"
    pasta = os.path.join(ASSETS, nome + ".imageset")
    os.makedirs(pasta, exist_ok=True)
    arquivo = nome + "." + ext
    open(os.path.join(pasta, arquivo), "wb").write(dados)
    json.dump({"images": [{"filename": arquivo, "idiom": "universal"}], "info": {"author": "xcode", "version": 1}},
              open(os.path.join(pasta, "Contents.json"), "w"))
    print(nome, len(dados), hashlib.sha256(dados).hexdigest()[:12])

os.makedirs(ASSETS, exist_ok=True)
json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}},
          open(os.path.join(ASSETS, "Contents.json"), "w"))
if MERCADO:
    # As maiores do Mercado, na ordem da lista, que ainda nao tem logo no app.
    feitos = 0
    for pagina in range(1, (MERCADO + 249) // 250 + 1):
        lista = json.loads(get(API + "coins/markets?vs_currency=usd&order=market_cap_desc&per_page=%d&page=%d" % (min(MERCADO, 250), pagina)))
        for m in lista:
            if feitos >= MERCADO: break
            feitos += 1
            mid = m.get("id", "")
            if not ID.match(mid) or os.path.exists(os.path.join(ASSETS, "logo-" + mid + ".imageset")): continue
            salvar("logo-" + mid, m.get("image"), lado=128)
    sys.exit(0)
moedas = [m for m in MOEDAS if not SO or m in SO]
if moedas:
    mercados = json.loads(get("https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=" + ",".join(moedas)))
    for m in mercados:
        if m.get("id") in moedas: salvar("logo-" + m["id"], m.get("image"))
plataformas = {p["id"]: p for p in json.loads(get("https://api.coingecko.com/api/v3/asset_platforms"))}
for rede, pid in REDES.items():
    if SO and rede not in SO: continue
    p = plataformas.get(pid)
    img = (p or {}).get("image") or {}
    url = img.get("large") or img.get("small")
    if url: salvar("rede-" + rede, url)
    else: print("sem logo de plataforma", rede)
prov = json.loads(get("https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=" + ",".join(PROVEDORES.values())))
por_id = {m["id"]: m for m in prov}
for nome, gid in PROVEDORES.items():
    m = por_id.get(gid)
    if m: salvar("provedor-" + nome, m["image"])
    else: print("sem logo de provedor", nome)
