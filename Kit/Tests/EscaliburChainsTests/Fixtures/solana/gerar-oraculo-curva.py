#!/usr/bin/env python3
"""Oraculo independente para a checagem "estes 32 bytes sao ponto da Ed25519?".

Escrito so com inteiros do Python e o criterio de Euler, sem nada em comum com o
codigo Swift (que calcula a raiz quadrada pela RFC 8032 sobre limbs de 16 bits):
se os dois concordam em centenas de entradas aleatorias e nos casos de borda, um
erro de aritmetica num deles aparece.

Semantica do curve25519-dalek (a do validador da Solana):
  y = bytes little-endian com o bit 255 zerado, reduzido mod p;
  u = y^2 - 1, v = d*y^2 + 1; ponto existe <=> u/v e quadrado (ou zero).
Como v != 0 sempre, u/v e quadrado <=> u*v e quadrado, e o criterio de Euler
decide: (u*v)^((p-1)/2) == 1, ou u*v == 0.

    python3 gerar-oraculo-curva.py > curve-oracle.json
"""
import json, random

P = 2**255 - 19
D = (-121665 * pow(121666, P - 2, P)) % P

def on_curve(b: bytes) -> bool:
    y = (int.from_bytes(b, "little") & ((1 << 255) - 1)) % P
    u = (y * y - 1) % P
    v = (D * y * y + 1) % P
    w = (u * v) % P
    return w == 0 or pow(w, (P - 1) // 2, P) == 1

def le(n: int, sign: int = 0) -> bytes:
    b = bytearray(n.to_bytes(32, "little"))
    b[31] |= sign << 7
    return bytes(b)

edge = [
    ("y = 0 (o System Program): x^2 = -1, que e quadrado", le(0)),
    ("y = 1: x = 0", le(1)),
    ("y = 1 com bit de sinal: x = 0 e sinal 1, aceito pelo dalek, recusado pela RFC 8032", le(1, 1)),
    ("y = p - 1 (-1): x = 0", le(P - 1)),
    ("y = p: nao canonico, reduz a 0; aceito pelo dalek, recusado pela RFC 8032", le(P)),
    ("y = p + 1: nao canonico, reduz a 1", le(P + 1)),
    ("y = 2^255 - 1: nao canonico, reduz a 18", le(2**255 - 1)),
    ("todos os bytes 0xff: bit 255 ignorado, igual ao anterior", b"\xff" * 32),
    ("y = 2", le(2)),
    ("y = 3", le(3)),
    ("y = 4", le(4)),
    ("y = 5", le(5)),
    ("y do ponto base, 4/5 mod p", le(4 * pow(5, P - 2, P) % P)),
    ("y do ponto base com sinal", le(4 * pow(5, P - 2, P) % P, 1)),
]

rng = random.Random(25092026)
cases = [{"note": note, "hex": b.hex(), "onCurve": on_curve(b)} for note, b in edge]
for _ in range(400):
    b = bytes(rng.getrandbits(8) for _ in range(32))
    cases.append({"hex": b.hex(), "onCurve": on_curve(b)})

print(json.dumps({
    "LEIA": "Gerado por gerar-oraculo-curva.py (criterio de Euler em inteiros do Python, semantica do curve25519-dalek). Os casos com 'note' sao de borda; os demais sao aleatorios com semente fixa.",
    "cases": cases,
}, indent=1, ensure_ascii=False))
