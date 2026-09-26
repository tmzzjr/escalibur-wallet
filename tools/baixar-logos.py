#!/usr/bin/env python3
"""Baixa os logos das moedas e redes da lista curada para dentro do app.

Logos embarcados, e nao baixados em tempo de uso: pedir o logo de um token a um CDN
conta ao CDN quais tokens a carteira tem. Roda uma vez por versao; o resultado vai
para o repositorio e passa por revisao como qualquer outro arquivo.

    python3 tools/baixar-logos.py
"""
import json, os, sys, urllib.request, hashlib

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(RAIZ, "App/EscaliburWallet/Resources/Assets.xcassets/Logos")
MOEDAS = ["bitcoin", "ethereum", "solana", "ripple", "stellar", "tron", "the-open-network", "litecoin",
          "dogecoin", "binancecoin", "avalanche-2", "polygon-ecosystem-token", "tether", "usd-coin", "dai",
          "wrapped-bitcoin", "weth", "chainlink", "uniswap", "arbitrum", "optimism", "jupiter-exchange-solana"]
REDES = {"base": "base", "arbitrum": "arbitrum-one", "optimism": "optimistic-ethereum", "polygon": "polygon-pos",
         "bnb": "binance-smart-chain", "avalanche": "avalanche", "ethereum": "ethereum", "solana": "solana",
         "tron": "tron", "ton": "the-open-network", "stellar": "stellar", "xrpl": "xrp", "litecoin": "litecoin",
         "dogecoin": "dogecoin", "bitcoin": "bitcoin"}

def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "EscaliburWallet-tools"})
    return urllib.request.urlopen(req, timeout=30).read()

def salvar(nome, url):
    dados = get(url.replace("/large/", "/large/"))
    if not (dados.startswith(b"\x89PNG") or dados.startswith(b"\xff\xd8\xff")):
        print("formato recusado", nome, url); return
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
mercados = json.loads(get("https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=" + ",".join(MOEDAS)))
for m in mercados:
    salvar("logo-" + m["id"], m["image"])
plataformas = {p["id"]: p for p in json.loads(get("https://api.coingecko.com/api/v3/asset_platforms"))}
for rede, pid in REDES.items():
    p = plataformas.get(pid)
    img = (p or {}).get("image") or {}
    url = img.get("large") or img.get("small")
    if url: salvar("rede-" + rede, url)
    else: print("sem logo de plataforma", rede)
