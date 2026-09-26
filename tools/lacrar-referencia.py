#!/usr/bin/env python3
"""Lacrador de referencia do formato .esclbr v1, escrito so a partir de docs/formato.md
do Escalibur, sem olhar o codigo Swift. Existe para gerar a fixture do sentido
"envelope de fora abre na carteira": se a carteira abrir o que este programa lacra,
o formato esta implementado pela especificacao, e nao so consistente consigo mesmo.

    pip install argon2-cffi cryptography
    python3 tools/lacrar-referencia.py saida.esclbr
"""
import os, sys, struct, unicodedata, uuid
from argon2.low_level import hash_secret_raw, Type
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes

def hkdf(ikm, salt, info):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(ikm)

def lacrar(frase, senha, nome, passphrase="", m=65536, t=2, p=1, idioma=0):
    vault_id = uuid.uuid4().bytes
    salt = os.urandom(16)
    header = b"ESCLBR" + bytes([1, 1]) + vault_id + bytes([1]) + struct.pack(">II", m, t) + bytes([p]) + salt
    header += bytes([0, 0]) + bytes(65) + bytes([0]) + bytes(2)
    assert len(header) == 120
    corpo = bytearray(os.urandom(4 * 4096))
    slot = int.from_bytes(os.urandom(1), "big") % 4

    campos = [frase.encode(), unicodedata.normalize("NFKD", passphrase).encode(), nome.encode(), b""]
    bloco = bytes([1, 1, idioma, 0]) + b"".join(struct.pack(">H", len(c)) for c in campos) + b"".join(campos)
    bloco = bloco + bytes(3936 - len(bloco))

    mk = hash_secret_raw(unicodedata.normalize("NFKC", senha).encode(), salt, time_cost=t, memory_cost=m,
                         parallelism=p, hash_len=32, type=Type.ID, version=19)
    slot_salt, wrap_salt, payload_salt = os.urandom(32), os.urandom(32), os.urandom(32)
    kek = hkdf(mk, slot_salt, b"escalibur/v1/kek" + bytes([slot]) + vault_id)
    kw = hkdf(kek, wrap_salt, b"escalibur/v1/wrap")
    dek = os.urandom(32)
    aad_w = header + bytes([slot]) + slot_salt
    embrulho = ChaCha20Poly1305(kw).encrypt(bytes(12), dek, aad_w)
    kp = hkdf(dek, payload_salt, b"escalibur/v1/payload")
    aad_p = aad_w + wrap_salt + embrulho
    conteudo = ChaCha20Poly1305(kp).encrypt(bytes(12), bloco, aad_p)

    base = slot * 4096
    corpo[base:base + 4096] = slot_salt + wrap_salt + embrulho + payload_salt + conteudo
    return header + bytes(corpo)

if __name__ == "__main__":
    frase = "legal winner thank year wave sausage worth useful legal winner thank yellow"
    dados = lacrar(frase, "senha de referencia em python", "Lacrado em Python", passphrase="TREZOR")
    assert len(dados) == 16504
    open(sys.argv[1], "wb").write(dados)
    print("ok", len(dados))
