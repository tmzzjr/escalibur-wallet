#!/usr/bin/env python3
"""Grava as respostas gRPC-Web e GraphQL da Sui usadas nos testes, sem chave.

    python3 gravar.py

Conta: Binance 1 (0x935029ca...9cbd, rotulo publico de exchange). Destino das simulacoes:
OKX 1 (0xab73ad38...cd56). As transacoes simuladas sao montadas aqui com a mesma regra do
SuiPlanner (todas as moedas, da maior para a menor; 1 MIST na estimativa com o orcamento
min(0,05 SUI, total - 1); orcamento do envio = (computacao + armazenamento) * 1,2; validade
ate a epoca seguinte), e os bytes vao junto para o teste remontar e conferir o digesto.
"""
import base64, hashlib, json, os, struct, urllib.request

AQUI = os.path.dirname(os.path.abspath(__file__))
DONO = "0x935029ca5219502a47ac9b69f556ccf6e2198b5e7815cf50f68846f723739cbd"
DESTINO = "0xab73ad38c63f83eda02182422b545395be1d3caeb54b5869159a9f70b678cd56"
VALOR = 1_000_000_000
HOST = "https://fullnode.mainnet.sui.io"
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

def b58d(s):
    n = 0
    for c in s: n = n * 58 + B58.index(c)
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return b"\0" * (len(s) - len(s.lstrip("1"))) + b

def b58e(b):
    n = int.from_bytes(b, "big"); s = ""
    while n: n, r = divmod(n, 58); s = B58[r] + s
    return "1" * (len(b) - len(b.lstrip(b"\0"))) + s

def vi(n):
    out = b""
    while True:
        x = n & 0x7F; n >>= 7
        if n: out += bytes([x | 0x80])
        else: return out + bytes([x])

def s(f, x):
    x = x.encode() if isinstance(x, str) else x
    return vi((f << 3) | 2) + vi(len(x)) + x

def u(f, n): return vi(f << 3) + vi(n)

def mask(*paths): return b"".join(s(1, p) for p in paths)

def grpc(metodo, corpo, nome):
    req = urllib.request.Request(HOST + "/" + metodo, data=b"\0" + struct.pack(">I", len(corpo)) + corpo,
                                 headers={"content-type": "application/grpc-web+proto", "x-grpc-web": "1"})
    dados = urllib.request.urlopen(req, timeout=30).read()
    open(os.path.join(AQUI, nome + ".bin"), "wb").write(dados)
    return dados

def mensagem(dados):
    assert dados[0] == 0
    n = struct.unpack(">I", dados[1:5])[0]
    return dados[5:5 + n]

def campos(b):
    i = 0; out = []
    while i < len(b):
        k = 0; sh = 0
        while True:
            x = b[i]; i += 1; k |= (x & 0x7F) << sh; sh += 7
            if x < 0x80: break
        f, t = k >> 3, k & 7
        if t == 0:
            v = 0; sh = 0
            while True:
                x = b[i]; i += 1; v |= (x & 0x7F) << sh; sh += 7
                if x < 0x80: break
        elif t == 2:
            n = 0; sh = 0
            while True:
                x = b[i]; i += 1; n |= (x & 0x7F) << sh; sh += 7
                if x < 0x80: break
            v = b[i:i + n]; i += n
        elif t == 1: v = b[i:i + 8]; i += 8
        elif t == 5: v = b[i:i + 4]; i += 4
        out.append((f, v))
    return out

def tx(moedas, preco, orcamento, valor, epoca):
    t = b"\0\0" + vi(2) + b"\0" + vi(8) + struct.pack("<Q", valor) + b"\0" + vi(32) + bytes.fromhex(DESTINO[2:])
    t += vi(2) + b"\x02\x00" + vi(1) + b"\x01" + struct.pack("<H", 0) + b"\x01" + vi(1) + b"\x03" + struct.pack("<HH", 0, 0) + b"\x01" + struct.pack("<H", 1)
    t += bytes.fromhex(DONO[2:]) + vi(len(moedas))
    for oid, ver, dig, _ in moedas:
        d = b58d(dig); t += bytes.fromhex(oid[2:]) + struct.pack("<Q", ver) + vi(len(d)) + d
    t += bytes.fromhex(DONO[2:]) + struct.pack("<QQ", preco, orcamento) + b"\x01" + struct.pack("<Q", epoca)
    return t

def simular(t, nome):
    m = mask("transaction.effects.transaction_digest", "transaction.effects.status", "transaction.effects.gas_used", "transaction.balance_changes")
    dados = grpc("sui.rpc.v2.TransactionExecutionService/SimulateTransaction", s(1, s(1, s(2, t))) + s(2, m), nome)
    open(os.path.join(AQUI, nome + "-tx.bin"), "wb").write(t)
    executada = dict(campos(mensagem(dados)))[1]
    efeitos = dict(campos(executada))[4]
    gas = dict(campos(dict(campos(efeitos))[6]))
    return gas.get(1, 0), gas.get(2, 0), gas.get(3, 0)

grpc("sui.rpc.v2.LedgerService/GetServiceInfo", b"", "GetServiceInfo")
epoca = grpc("sui.rpc.v2.LedgerService/GetEpoch", s(2, mask("epoch", "reference_gas_price")), "GetEpoch")
ep = dict(campos(dict(campos(mensagem(epoca)))[1])); numero, preco = ep[1], ep[8]
grpc("sui.rpc.v2.StateService/GetBalance", s(1, DONO) + s(2, "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"), "GetBalance-dono")
grpc("sui.rpc.v2.StateService/ListBalances", s(1, DONO) + u(2, 100), "ListBalances-dono")
lista = grpc("sui.rpc.v2.StateService/ListOwnedObjects",
             s(1, DONO) + u(2, 250) + s(4, mask("object_id", "version", "digest", "owner", "object_type", "balance")) + s(5, "0x2::coin::Coin<0x2::sui::SUI>"),
             "ListOwnedObjects-dono")
moedas = []
for f, v in campos(mensagem(lista)):
    if f == 1:
        o = dict(campos(v)); moedas.append((o[2].decode(), o[3], o[4].decode(), o.get(101, 0)))
    if f == 2: raise SystemExit("mais de uma pagina")
moedas.sort(key=lambda m: (-m[3], m[0]))
moedas = moedas[:250]
total = sum(m[3] for m in moedas)
c, st, r = simular(tx(moedas, preco, min(50_000_000, total - 1), 1, numero + 1), "SimulateTransaction-estimativa")
orcamento = max(1000 * preco, ((c + st) * 12 + 9) // 10)
simular(tx(moedas, preco, orcamento, VALOR, numero + 1), "SimulateTransaction-envio")
print("epoca", numero, "preco", preco, "moedas", len(moedas), "gas", c, st, r, "orcamento", orcamento)

# Uma transacao da propria conta, recente, para o acompanhamento: encontrada e nao encontrada.
gql = lambda q, v: json.loads(urllib.request.urlopen(urllib.request.Request(
    "https://graphql.mainnet.sui.io/graphql", data=json.dumps({"query": q, "variables": v}).encode(),
    headers={"content-type": "application/json"}), timeout=30).read())
ultima = gql("query($a: SuiAddress!) { transactions(last: 1, filter: { sentAddress: $a }) { nodes { digest } } }", {"a": DONO})
digesto = ultima["data"]["transactions"]["nodes"][0]["digest"]
lookup = mask("digest", "effects.status", "checkpoint")
grpc("sui.rpc.v2.LedgerService/BatchGetTransactions", s(1, digesto) + s(2, lookup), "BatchGetTransactions-achada")
grpc("sui.rpc.v2.LedgerService/BatchGetTransactions", s(1, "Ea7JiCRKcxigeKMTwFx1y3SjVRg5nK3tJR68SovpBB8j") + s(2, lookup), "BatchGetTransactions-nao-achada")
open(os.path.join(AQUI, "digesto-achado.txt"), "w").write(digesto)

# Historico: GraphQL (10 transacoes) e o ListTransactions do gRPC (5), da conta do dono.
doc = ("query($a: SuiAddress!, $n: Int!) { transactions(last: $n, filter: { affectedAddress: $a }) { nodes { "
       "digest sender { address } effects { status timestamp gasEffects { gasSummary { computationCost storageCost storageRebate } } "
       "balanceChanges(first: 20) { nodes { owner { address } coinType { repr } amount } } } } } }")
json.dump(gql(doc, {"a": DONO, "n": 10}), open(os.path.join(AQUI, "graphql-historico-dono.json"), "w"))
filtro = s(1, s(1, s(3, s(1, DONO))))
grpc("sui.rpc.v2.LedgerService/ListTransactions",
     s(1, mask("digest", "transaction.sender", "effects.status", "effects.gas_used", "balance_changes", "timestamp")) + s(4, filtro) + s(5, u(1, 5) + u(4, 1)),
     "ListTransactions-dono")
print("digesto", digesto)
