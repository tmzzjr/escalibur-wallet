#!/usr/bin/env python3
# Grava as respostas reais que os testes do NEARReader e do motor usam. Uma vez, a mao:
#   python3 gravar.py
# Tudo no mesmo bloco final (o do dRPC na hora da gravacao), que os testes usam tambem
# como resposta de `block` com `finality: final`. O dono e a conta implicita
# 78cb7728...0a31, que fez transferencias reais (Fixtures/near/transferencias-reais.json
# nos testes de EscaliburChains).
import json, urllib.request

RPC = "https://near.drpc.org"
HIST = "https://tx.main.fastnear.com"
DONO = "78cb7728d7f6257f78d979791c7372917fba684620485ccf9fcf80d91b450a31"
CHAVE = "ed25519:98XsSQeTLFP7B2WBXfmqyMmfy2xFBEQjFM3ynYiXCohr"
OUTRA_CHAVE = "ed25519:DSXAby8hudFEsmghQtjLpPrVnjT7dADgZRrCsuMf2UqC"
DESTINO = "madturk.near"
SEM_CONTA = "conta-que-nao-existe-escalibur.near"
TX = "8VhtMYxX6hRaD827eaQcptC7Nw623n8FXuf17CdokwTg"

def post(url, body):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "User-Agent": "escalibur-fixtures"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        return e.read()

def rpc(method, params):
    return post(RPC, {"jsonrpc": "2.0", "id": 1, "method": method, "params": params})

def save(name, data):
    open(name + ".json", "wb").write(data)

final = json.loads(rpc("block", {"finality": "final"}))["result"]["header"]
bloco = final["hash"]
save("status", rpc("status", []))
save("block-referencia", rpc("block", {"block_id": final["height"]}))
save("view_account-dono", rpc("query", {"request_type": "view_account", "account_id": DONO, "block_id": bloco}))
save("view_access_key-dono", rpc("query", {"request_type": "view_access_key", "account_id": DONO, "public_key": CHAVE, "block_id": bloco}))
save("view_access_key-outra", rpc("query", {"request_type": "view_access_key", "account_id": DONO, "public_key": OUTRA_CHAVE, "block_id": bloco}))
save("view_account-destino", rpc("query", {"request_type": "view_account", "account_id": DESTINO, "block_id": bloco}))
save("view_account-inexistente", rpc("query", {"request_type": "view_account", "account_id": SEM_CONTA, "block_id": bloco}))
save("protocol_config", rpc("EXPERIMENTAL_protocol_config", {"block_id": bloco}))
save("gas_price", rpc("gas_price", [bloco]))
save("tx-final", rpc("tx", {"tx_hash": TX, "sender_account_id": DONO, "wait_until": "NONE"}))
save("tx-desconhecida", rpc("tx", {"tx_hash": "11111111111111111111111111111111", "sender_account_id": DONO, "wait_until": "NONE"}))
reais = json.load(open("../../../../EscaliburChainsTests/Fixtures/near/transferencias-reais.json"))
import base64
assinada = base64.b64decode(reais[0]["signed_base64"])
zerada = base64.b64encode(assinada[:-64] + bytes(64)).decode()
save("send_tx-assinatura-invalida", rpc("send_tx", {"signed_tx_base64": zerada, "wait_until": "INCLUDED"}))
save("send_tx-ja-incluida", rpc("send_tx", {"signed_tx_base64": reais[0]["signed_base64"], "wait_until": "INCLUDED"}))
conta = post(HIST + "/v0/account", {"account_id": DONO})
save("historico-conta", conta)
lista = sorted(json.loads(conta)["account_txs"], key=lambda t: -t["tx_block_height"])
hashes = []
for t in lista:
    if t["transaction_hash"] not in hashes: hashes.append(t["transaction_hash"])
save("historico-transacoes", post(HIST + "/v0/transactions", {"tx_hashes": hashes[:20]}))
print("bloco", final["height"], bloco)
