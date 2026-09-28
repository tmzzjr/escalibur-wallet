#!/usr/bin/env python3
"""Grava as respostas da Aptos usadas nos testes, sem chave.

    python3 gravar.py

Provedores: PublicNode (Allnodes) e Sentio, os dois primeiros de Endpoints.aptos, e o
indexador GraphQL da Aptos Labs (historico). Conta: 0x966e3ee0...6c41, uma conta de saque
com mais de um milhao de transacoes; a chave publica vem da assinatura de uma transacao
dela na rede. Destinos: 0xa816db9f...9cc6 (ja tem APT) e um endereco novo, o SHA3-256 de
um texto fixo, que nunca recebeu nada.

As leituras de estado sao feitas na mesma versao do ledger nos dois provedores (a menor
das duas), como o AptosReader faz. As transacoes simuladas sao montadas aqui com a mesma
regra do AptosPlanner: 1 octa na estimativa, com o gas maximo = min(20.000, 5.000.000 /
preco, (saldo - 1) / preco); no envio, o gas maximo = max(200, teto de 1,2 x o maior gas
usado nas duas simulacoes); validade = hora do ledger + 120 s. Os bytes vao junto para o
teste remontar a mesma transacao e conferir.
"""
import hashlib, json, os, time, urllib.request

AQUI = os.path.dirname(os.path.abspath(__file__))
PROVEDORES = {"publicnode": "https://aptos-rest.publicnode.com/v1", "sentio": "https://rpc.sentio.xyz/aptos/v1"}
INDEXADOR = "https://api.mainnet.aptoslabs.com/v1/graphql"
DONO = "0x966e3ee07a3403a72f44c53f457d34c7148c2c8812c8d52509f54d4a00a36c41"
CHAVE = "466ca5a1cb600f73a5edc1dc36f38d12c4514a9131ee6ec9619504778bf27280"
EXISTENTE = "0xa816db9fa6e242878969f54c5e8ae5081f01ffc9442c0c055ef62a9b02459cc6"
NOVA = "0x" + hashlib.sha3_256(b"escalibur: destino aptos que nunca recebeu").hexdigest()
VALOR = 100_000_000
TRANSACAO_CONHECIDA = "0x766b1e652e49d0beeb99a4fc60f28d3c1460d5f17196810ccd9617609a6b68e0"


def uleb(n):
    out = b""
    while True:
        b = n & 0x7F; n >>= 7
        if n: out += bytes([b | 0x80])
        else: return out + bytes([b])


def endereco(h):
    return bytes.fromhex(h[2:].rjust(64, "0"))


def texto(x):
    x = x.encode(); return uleb(len(x)) + x


def u64(n):
    return n.to_bytes(8, "little")


def bruta(seq, destino, valor, gas, preco, validade):
    b = endereco(DONO) + u64(seq) + uleb(2) + endereco("0x1") + texto("aptos_account") + texto("transfer") + uleb(0)
    b += uleb(2) + uleb(32) + endereco(destino) + uleb(8) + u64(valor)
    return b + u64(gas) + u64(preco) + u64(validade) + bytes([1])


def assinada_zero(raw):
    return raw + uleb(0) + uleb(32) + bytes.fromhex(CHAVE) + uleb(64) + bytes(64)


def pedir(url, corpo=None, tipo="application/json"):
    req = urllib.request.Request(url, data=corpo, headers={"Content-Type": tipo, "User-Agent": "EscaliburWallet"})
    time.sleep(0.4)
    return urllib.request.urlopen(req, timeout=30).read()


def gravar(nome, dados):
    with open(os.path.join(AQUI, nome), "wb") as f:
        f.write(dados)


def view(base, funcao, tipos, args, versao):
    corpo = json.dumps({"function": funcao, "type_arguments": tipos, "arguments": args}).encode()
    return pedir(f"{base}/view?ledger_version={versao}", corpo)


def main():
    indices = {n: pedir(b) for n, b in PROVEDORES.items()}
    for n, dados in indices.items():
        gravar(f"indice-{n}.json", dados)
    lidos = {n: json.loads(d) for n, d in indices.items()}
    menor = min(lidos, key=lambda n: int(lidos[n]["ledger_version"]))
    versao = int(lidos[menor]["ledger_version"])
    hora = int(lidos[menor]["ledger_timestamp"]) // 1_000_000

    leituras = {
        "sequencia-dono": ("0x1::account::get_sequence_number", [], [DONO]),
        "chave-dono": ("0x1::account::get_authentication_key", [], [DONO]),
        "saldo-dono": ("0x1::coin::balance", ["0x1::aptos_coin::AptosCoin"], [DONO]),
        "loja-existente": ("0x1::primary_fungible_store::primary_store_exists", ["0x1::fungible_asset::Metadata"], [EXISTENTE, "0xa"]),
        "loja-nova": ("0x1::primary_fungible_store::primary_store_exists", ["0x1::fungible_asset::Metadata"], [NOVA, "0xa"]),
    }
    valores = {}
    for nome, (funcao, tipos, args) in leituras.items():
        respostas = [view(b, funcao, tipos, args, versao) for b in PROVEDORES.values()]
        assert json.loads(respostas[0]) == json.loads(respostas[1]), nome
        gravar(f"view-{nome}.json", respostas[0])
        valores[nome] = json.loads(respostas[0])[0]
    precos = [pedir(f"{b}/estimate_gas_price") for b in PROVEDORES.values()]
    assert json.loads(precos[0])["gas_estimate"] == json.loads(precos[1])["gas_estimate"]
    gravar("preco-gas.json", precos[0])
    preco = json.loads(precos[0])["gas_estimate"]
    seq = int(valores["sequencia-dono"])
    saldo = int(valores["saldo-dono"])
    validade = hora + 120

    def simular(nome, raw):
        corpo = assinada_zero(raw)
        gravar(f"simulacao-{nome}.bcs.hex", corpo.hex().encode())
        usados = []
        for n, b in PROVEDORES.items():
            resposta = pedir(f"{b}/transactions/simulate", corpo, "application/x.aptos.signed_transaction+bcs")
            gravar(f"simulacao-{nome}-{n}.json", resposta)
            tx = json.loads(resposta)[0]
            assert tx["success"], (nome, tx["vm_status"])
            usados.append(int(tx["gas_used"]))
        return max(usados)

    for destino_nome, destino in (("existente", EXISTENTE), ("nova", NOVA)):
        gas_estimativa = min(20_000, 5_000_000 // preco, (saldo - 1) // preco)
        usado = simular(f"estimativa-{destino_nome}", bruta(seq, destino, 1, gas_estimativa, preco, validade))
        gas = max(200, (usado * 12 + 9) // 10)
        simular(f"envio-{destino_nome}", bruta(seq, destino, VALOR, gas, preco, validade))

    for n, b in PROVEDORES.items():
        gravar(f"transacao-{n}.json", pedir(f"{b}/transactions/by_hash/{TRANSACAO_CONHECIDA}"))

    consulta = open(os.path.join(AQUI, "historico.graphql")).read()
    corpo = json.dumps({"query": consulta, "variables": {"owner": DONO, "limit": 30}}).encode()
    gravar("graphql-historico-dono.json", pedir(INDEXADOR, corpo))

    gravar("gravacao.json", json.dumps({
        "dono": DONO, "chave": CHAVE, "existente": EXISTENTE, "nova": NOVA, "valor": VALOR,
        "versao": versao, "hora": hora, "preco": preco, "sequencia": seq, "saldo": saldo,
        "transacao": TRANSACAO_CONHECIDA,
    }, indent=1).encode())


if __name__ == "__main__":
    main()
