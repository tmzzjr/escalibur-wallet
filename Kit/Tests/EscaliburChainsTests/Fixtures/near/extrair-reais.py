#!/usr/bin/env python3
# Refaz transferencias-reais.json a partir da rede: acha transferencias de NEAR simples
# (uma acao Transfer) nos chunks dos ultimos blocos finais e descobre o block_hash de cada
# uma, que a visao JSON do no nao mostra, procurando o bloco cujo hash monta uma
# transacao Borsh com o SHA-256 igual ao id. Com o bloco achado, confere a assinatura
# Ed25519 original sobre esse hash. So precisa do Python e do pacote cryptography.
#   python3 extrair-reais.py
import base64, hashlib, json, struct, sys, urllib.request
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

RPC = "https://near.drpc.org"
ALFABETO = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30)).get("result")

def b58d(s):
    n = 0
    for c in s: n = n * 58 + ALFABETO.index(c)
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    return b"\0" * (len(s) - len(s.lstrip("1"))) + raw

def b58e(b):
    n, s = int.from_bytes(b, "big"), ""
    while n: n, r = divmod(n, 58); s = ALFABETO[r] + s
    return "1" * (len(b) - len(b.lstrip(b"\0"))) + s

def texto(s): e = s.encode(); return struct.pack("<I", len(e)) + e

def borsh(t, bloco):
    return (texto(t["signer_id"]) + b"\0" + b58d(t["public_key"][8:]) + struct.pack("<Q", t["nonce"]) + texto(t["receiver_id"])
            + bloco + struct.pack("<I", 1) + b"\x03" + int(t["actions"][0]["Transfer"]["deposit"]).to_bytes(16, "little"))

quantas = int(sys.argv[1]) if len(sys.argv) > 1 else 3
ponta = rpc("block", {"finality": "final"})["header"]["height"]
saida = []
for altura in range(ponta, ponta - 2000, -1):
    bloco = rpc("block", {"block_id": altura})
    if not bloco: continue
    for chunk in bloco["chunks"]:
        for t in (rpc("chunk", {"chunk_id": chunk["chunk_hash"]}) or {}).get("transactions", []):
            if len(t["actions"]) != 1 or "Transfer" not in t["actions"][0]: continue
            for recuo in range(1, 400):
                ref = rpc("block", {"block_id": altura - recuo})
                if not ref: continue
                raw = borsh(t, b58d(ref["header"]["hash"]))
                digest = hashlib.sha256(raw).digest()
                if b58e(digest) != t["hash"]: continue
                assinatura = b58d(t["signature"][8:])
                Ed25519PublicKey.from_public_bytes(b58d(t["public_key"][8:])).verify(assinatura, digest)
                saida.append({"hash": t["hash"], "signer_id": t["signer_id"], "public_key": t["public_key"], "nonce": t["nonce"],
                              "receiver_id": t["receiver_id"], "block_hash": ref["header"]["hash"], "signature": t["signature"],
                              "deposit": t["actions"][0]["Transfer"]["deposit"], "included_height": altura,
                              "reference_height": altura - recuo, "borsh_hex": raw.hex(),
                              "signed_base64": base64.b64encode(raw + b"\0" + assinatura).decode()})
                break
    if len(saida) >= quantas: break
json.dump(saida, open("transferencias-reais.json", "w"), indent=1)
