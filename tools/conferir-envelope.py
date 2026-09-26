#!/usr/bin/env python3
"""Abre com o decifrar.py embarcado no app um envelope lacrado pela carteira.

Uso: python3 tools/conferir-envelope.py arquivo.esclbr

Confere frase, 25a palavra e nome. E o sentido "carteira -> decifrador" da
interoperabilidade; o sentido contrario e o teste com a fixture do Escalibur.
"""
import importlib.util
import pathlib
import sys
import unicodedata

RAIZ = pathlib.Path(__file__).resolve().parent.parent
DECIFRAR = RAIZ / "App/EscaliburWallet/Resources/Recuperacao/decifrar.py"

spec = importlib.util.spec_from_file_location("decifrar", DECIFRAR)
decifrar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decifrar)

blob = pathlib.Path(sys.argv[1]).read_bytes()
_, encontrados = decifrar.abrir(blob, "crane violin orbit maple harbor tunnel")
abertos = [c for _, c in encontrados if c and "frase" in c]
if len(abertos) != 1:
    sys.exit("o decifrar.py nao abriu o envelope da carteira")
conteudo = abertos[0]
esperado = "legal winner thank year wave sausage worth useful legal winner thank yellow"
falhas = []
if conteudo["frase"] != esperado:
    falhas.append("frase")
if unicodedata.normalize("NFKD", conteudo["passphrase"]) != unicodedata.normalize("NFKD", "canção de ninar"):
    falhas.append("25a palavra")
if conteudo["nome"] != "Conferência do CI":
    falhas.append("nome")
if falhas:
    sys.exit("divergente: " + ", ".join(falhas))
print("envelope da carteira aberto pelo decifrar.py: frase, 25a palavra e nome conferem")
