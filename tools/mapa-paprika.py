#!/usr/bin/env python3
"""Gera a tabela de ids do CoinPaprika para ids do CoinGecko das maiores do Mercado.

Com o CoinGecko em 429, o Mercado mostra a lista de reserva do CoinPaprika. O id de la
(`steth-lido-staked-ether`) nao e o do CoinGecko (`staked-ether`), e sem o id certo a
linha fica sem o logo embarcado e o favorito nao acha a moeda. Esta tabela liga os dois.

    python3 tools/mapa-paprika.py          as 300 maiores
    python3 tools/mapa-paprika.py 500

Uma moeda so entra quando o simbolo e o mesmo nos dois e, alem disso, o nome normalizado
e o mesmo ou o valor de mercado difere menos de 10%, e um unico id do CoinGecko passa.
O CoinGecko deixa sem posicao alguns derivados grandes (o stETH): fora da lista por valor,
eles sao achados na lista completa de moedas, so com simbolo e nome iguais e um unico
candidato entre todas.
Na duvida fica de fora: um logo trocado numa lista de precos engana mais do que logo
nenhum. Roda uma vez por versao; o resultado vai para o repositorio e passa por revisao.
"""
import json, os, re, sys, time, urllib.error, urllib.request

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAIDA = os.path.join(RAIZ, "Kit/Sources/EscaliburNetwork/PaprikaGeckoIDs.swift")
MARKET = os.path.join(RAIZ, "Kit/Sources/EscaliburNetwork/Market.swift")
GECKO = "https://api.coingecko.com/api/v3/"
PAPRIKA = "https://api.coinpaprika.com/v1/"
ID = re.compile(r"^[a-z0-9-]{1,80}$")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 300

def get(url):
    if not (url.startswith(GECKO) or url.startswith(PAPRIKA)):
        raise SystemExit("host recusado: " + url)
    req = urllib.request.Request(url, headers={"User-Agent": "EscaliburWallet-tools"})
    for tentativa in range(6):
        try:
            with urllib.request.urlopen(req, timeout=60) as resposta:
                return json.loads(resposta.read(16 * 1024 * 1024))
        except urllib.error.HTTPError as erro:
            if erro.code != 429 or tentativa == 5: raise
            time.sleep(20 * (tentativa + 1))

def nome(texto):
    return re.sub(r"[^a-z0-9]", "", texto.lower())

# A tabela feita a mao (Market.swift) vale mais: o que ja esta nela nao entra aqui.
tabela = open(MARKET).read().split("static let paprikaIDs: [String: String] = [")[1].split("\n    ]")[0]
mao = dict(re.findall(r'"([a-z0-9-]+)": "([a-z0-9-]+)"', tabela))
mao_paprika = set(mao.values())

gecko = []
for pagina in range(1, (N + 249) // 250 + 1):
    lista = get(GECKO + "coins/markets?vs_currency=usd&order=market_cap_desc&per_page=250&page=%d" % pagina)
    if not isinstance(lista, list): raise SystemExit("o CoinGecko nao devolveu a lista: %r" % lista)
    gecko += lista
gecko = gecko[: N + 100]
paprika = sorted((t for t in get(PAPRIKA + "tickers?quotes=USD") if t.get("rank")), key=lambda t: t["rank"])[:N]
todas = None

mapa = {}
for t in paprika:
    pid = t.get("id", "")
    if not ID.match(pid): continue
    palpite = pid.split("-", 1)[1] if "-" in pid else pid
    cap = ((t.get("quotes") or {}).get("USD") or {}).get("market_cap") or 0
    def passa(g):
        if (g.get("symbol") or "").upper() != (t.get("symbol") or "").upper(): return False
        if nome(g.get("name") or "") == nome(t.get("name") or ""): return True
        gcap = g.get("market_cap") or 0
        return cap > 0 and gcap > 0 and abs(gcap - cap) / max(gcap, cap) < 0.10
    candidatos = [g["id"] for g in gecko if ID.match(g.get("id", "")) and passa(g)]
    if not candidatos and not any((g.get("symbol") or "").upper() == (t.get("symbol") or "").upper() for g in gecko):
        if todas is None:
            todas = get(GECKO + "coins/list")
            if not isinstance(todas, list): raise SystemExit("o CoinGecko nao devolveu a lista completa: %r" % todas)
        candidatos = [g["id"] for g in todas if ID.match(g.get("id", ""))
                      and (g.get("symbol") or "").upper() == (t.get("symbol") or "").upper()
                      and nome(g.get("name") or "") == nome(t.get("name") or "")]
    if os.environ.get("ESCALIBUR_POR_QUE", "-").upper() == (t.get("symbol") or "").upper():
        print(pid, t.get("name"), cap, [(g["id"], g.get("name"), g.get("market_cap")) for g in gecko if (g.get("symbol") or "").upper() == t["symbol"].upper()])
    if len(candidatos) != 1: continue
    gid = candidatos[0]
    if gid == palpite or gid in mao or pid in mao_paprika: continue
    mapa[pid] = gid

# Duas moedas do CoinPaprika no mesmo id do CoinGecko: nenhuma das duas entra.
contagem = {}
for g in mapa.values(): contagem[g] = contagem.get(g, 0) + 1
mapa = {p: g for p, g in mapa.items() if contagem[g] == 1}

linhas = ["        %s: %s," % (json.dumps(p), json.dumps(g)) for p, g in sorted(mapa.items())]
open(SAIDA, "w").write("""// Gerado por tools/mapa-paprika.py: nao editar a mao.
//
// Ids do CoinPaprika para ids do CoinGecko das maiores do Mercado, onde o nome depois do
// simbolo nao e o id do CoinGecko. Entra so quem bate no simbolo e no nome ou no valor de
// mercado, com um unico candidato.

extension MarketService {
    static let generatedGeckoIDs: [String: String] = [
%s
    ]
}
""" % "\n".join(linhas))
print(len(mapa), "ids;", SAIDA)
