#!/usr/bin/env python3
"""Grava as respostas da Koios e do backend da Yoroi para os testes do CardanoReader.

Sem chave. Contas: um endereco base com moedas so de ADA e chave conhecida (a testemunha
das transacoes dele na rede) e um endereco com moedas que carregam tokens. Alteracao: o
`costModels` dos parametros sai (o leitor nao le, e sao dezenas de KB).

    python3 gravar.py
"""
import json, os, urllib.request

AQUI = os.path.dirname(os.path.abspath(__file__))
KOIOS = "https://api.koios.rest/api/v1"
YOROI = "https://api.yoroiwallet.com/api"
ZERO = "https://zero.yoroiwallet.com"
DONO = "addr1q8ph5dwx5hzrygtwfdpk2nxp2y4p0rr35tds049rz3dee4kr0g6udfwyxgskuj6rv4xvz5f2z7x8rgkmql22x9zmnntqar3scw"
TOKENS = "addr1qxhss4frkp0hhhm3vku2mcj8lu47ezadcpfn8fw8njldx7fzh4dpaxkdtqwh5u7srvagl0sam4un2xfjrr7erw46ujuq4rs8u7"
TX = "d8da3593663c88b2aa46dc27f7bcb8cef20bc86f7e456b43e467674fe6889c3a"
NENHUMA = "00" * 32

def pedir(url, corpo=None):
    dados = json.dumps(corpo).encode() if corpo is not None else None
    req = urllib.request.Request(url, data=dados, headers={
        "Content-Type": "application/json", "Accept": "application/json", "User-Agent": "EscaliburWallet-tools"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read())

def gravar(nome, valor):
    with open(os.path.join(AQUI, nome + ".json"), "w") as f:
        json.dump(valor, f, indent=1, sort_keys=True)
        f.write("\n")

gravar("koios-address_utxos-dono", pedir(KOIOS + "/address_utxos", {"_addresses": [DONO], "_extended": True}))
gravar("yoroi-utxoForAddresses-dono", pedir(YOROI + "/txs/utxoForAddresses", {"addresses": [DONO]}))
gravar("koios-tip", pedir(KOIOS + "/tip"))
gravar("yoroi-bestblock", pedir(YOROI + "/v2/bestblock"))
gravar("koios-address_utxos-tokens", pedir(KOIOS + "/address_utxos", {"_addresses": [TOKENS], "_extended": True}))
gravar("yoroi-utxoForAddresses-tokens", pedir(YOROI + "/txs/utxoForAddresses", {"addresses": [TOKENS]}))
parametros = pedir(KOIOS + "/cli_protocol_params")
parametros.pop("costModels", None)
gravar("koios-cli_protocol_params", parametros)
zero = pedir(ZERO + "/protocolparameters")
zero.pop("costModels", None)
gravar("yoroi-protocolparameters", zero)
gravar("koios-genesis", pedir(KOIOS + "/genesis"))
gravar("koios-tx_status", pedir(KOIOS + "/tx_status", {"_tx_hashes": [TX]}))
gravar("koios-tx_status-nenhuma", pedir(KOIOS + "/tx_status", {"_tx_hashes": [NENHUMA]}))
gravar("yoroi-tx_status", pedir(YOROI + "/tx/status", {"txHashes": [TX]}))
gravar("yoroi-tx_status-nenhuma", pedir(YOROI + "/tx/status", {"txHashes": [NENHUMA]}))
lista = pedir(KOIOS + "/address_txs?limit=5&order=block_height.desc", {"_addresses": [DONO]})
gravar("koios-address_txs-dono", lista)
gravar("koios-tx_info-dono", pedir(KOIOS + "/tx_info", {"_tx_hashes": [t["tx_hash"] for t in lista], "_inputs": True}))
