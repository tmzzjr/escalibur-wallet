#!/usr/bin/env python3
"""Decifrador de referência do formato .esclbr do Escalibur.

Este arquivo existe por um motivo só: um cofre que apenas um aplicativo consegue
abrir é um cofre com prazo de validade. Se o Escalibur sair da App Store, se o
iPhone morrer, se a pessoa que guardou a frase morrer, este script continua
abrindo o cofre com nada além de Python e duas bibliotecas públicas.

    pip install argon2-cffi cryptography
    python3 decifrar.py meu-cofre.esclbr

Ele pede a senha, tenta os quatro compartimentos e imprime o que encontrar. Não
escreve nada em disco, não acessa a rede.

FORMATO (versão 1). Todos os inteiros em big-endian.

Cabeçalho, 120 bytes em claro:

      offset  tam  campo
           0    6  magic "ESCLBR"
           6    1  versão do formato (1)
           7    1  conjunto de algoritmos (1)
           8   16  identificador do cofre (UUID, sorteado, sem significado)
          24    1  identificador do KDF (1 = Argon2id v1.3)
          25    4  memória do Argon2, em KiB
          29    4  passes do Argon2
          33    1  faixas do Argon2
          34   16  salt do Argon2
          50    1  vínculo com o aparelho (0 = nenhum, 1 = Secure Enclave)
          51    1  reservado
          52   65  chave pública efêmera do vínculo (zeros quando não há)
         117    1  marcador de nuvem
         118    2  reservado

Em seguida, QUATRO compartimentos de 4096 bytes cada, sempre. Os que não estão
em uso contêm bytes aleatórios, e bytes aleatórios não se distinguem de cifra
autenticada. É isso, e só isso, que dá negação plausível: quem obriga o dono a
abrir um compartimento não consegue provar que existe outro.

Cada compartimento:

      offset  tam  campo
           0   32  salt do compartimento
          32   32  salt da subchave do embrulho
          64   48  DEK embrulhada (32 de cifra + 16 de tag)
         112   32  salt da subchave do conteúdo
         144 3952  conteúdo cifrado (3936 de texto + 16 de tag)

DERIVAÇÃO

    A senha entra como **UTF-8 da forma NFKC** da senha digitada. A normalização é
    parte do formato, não detalhe de interface: sem ela, a mesma senha com acento
    digitada em teclados diferentes vira bytes diferentes, e o cofre que abre no app
    não abre aqui. Senha só de ASCII é a própria forma NFKC dela, e nada muda.

    MK   = Argon2id(NFKC(senha) em UTF-8, salt do cabeçalho, m, t, p, saída de 32 bytes)
    KEK  = HKDF-SHA256(ikm=MK, salt=salt do compartimento,
                       info=b"escalibur/v1/kek" + byte do índice + UUID, L=32)
    Kw   = HKDF-SHA256(ikm=KEK, salt=salt do embrulho,
                       info=b"escalibur/v1/wrap", L=32)
    DEK  = ChaCha20-Poly1305(Kw, nonce=12 zeros).decrypt(embrulho, aad=AAD_W)
    Kp   = HKDF-SHA256(ikm=DEK, salt=salt do conteúdo,
                       info=b"escalibur/v1/payload", L=32)
    texto = ChaCha20-Poly1305(Kp, nonce=12 zeros).decrypt(conteúdo, aad=AAD_P)

O nonce é sempre doze zeros, e isso é seguro porque a CHAVE nunca se repete: os
salts de subchave são sorteados a cada gravação. É de propósito que não exista
contador de nonce em lugar nenhum. Um contador voltaria no tempo quando o dono
restaurasse um backup antigo do iPhone, e repetir um nonce em cifra autenticada
não vaza só aquela mensagem, vaza a chave que autentica todas.

Dados autenticados (o que a tag protege):

    AAD_W = cabeçalho(120) + byte do índice + salt do compartimento
    AAD_P = AAD_W + salt do embrulho + DEK embrulhada(48)

O índice entra no AAD para que um compartimento não possa ser copiado para outra
posição do arquivo. O AAD do conteúdo engloba o embrulho, o que encadeia as duas
camadas: mexer no cabeçalho, no marcador de nuvem ou colar o envelope de outro
cofre invalida a tag. Não existe recortar e colar entre cofres.

CONTEÚDO, depois de decifrado (3936 bytes, o resto zerado):

      offset  tam  campo
           0    1  versão do conteúdo (1)
           1    1  tipo (1 = frase BIP-39, 2 = parte SLIP-39)
           2    1  índice do idioma da lista BIP-39
           3    1  reservado
           4    2  tamanho da frase
           6    2  tamanho da 25ª palavra
           8    2  tamanho do nome do cofre
          10    2  tamanho das anotações
          12  ...  os quatro campos, nessa ordem, em UTF-8

A frase é gravada já na forma canônica do BIP-39: **NFKD, minúsculas, palavras
separadas por um único espaço comum (U+0020)** — inclusive em japonês, que no
papel usa o espaço ideográfico (U+3000). Os bytes lidos daqui são exatamente a
entrada do PBKDF2 do BIP-39; quem reimplementar não deve normalizar de novo nem
"consertar" os espaços. Uma parte SLIP-39 segue a mesma forma.

O bloco tem tamanho fixo, então o arquivo inteiro tem sempre 16504 bytes e o
tamanho não conta nem quantas palavras a frase tem nem se existe anotação.
"""

import getpass
import struct
import sys
import unicodedata

try:
    from argon2.low_level import Type, hash_secret_raw
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
except ImportError:
    sys.exit("faltam dependências:  pip install argon2-cffi cryptography")

MAGIC = b"ESCLBR"
HEADER_LEN = 120
SLOT_COUNT = 4
SLOT_LEN = 4096
FILE_LEN = HEADER_LEN + SLOT_COUNT * SLOT_LEN
PLAINTEXT_LEN = SLOT_LEN - 144 - 16
NONCE = b"\x00" * 12

IDIOMAS = [
    "english", "japanese", "chinese_simplified", "chinese_traditional",
    "french", "italian", "korean", "spanish", "czech", "portuguese",
]


def hkdf(ikm, salt, info):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(ikm)


def ler_cabecalho(blob):
    if len(blob) != FILE_LEN:
        sys.exit(f"tamanho inesperado: {len(blob)} bytes, esperado {FILE_LEN}")
    if blob[0:6] != MAGIC:
        sys.exit("este arquivo não é um cofre do Escalibur")
    versao = blob[6]
    if versao > 1:
        sys.exit(f"cofre da versão {versao} do formato; este script entende a 1")
    return {
        "uuid": blob[8:24],
        "memoria_kib": struct.unpack(">I", blob[25:29])[0],
        "passes": struct.unpack(">I", blob[29:33])[0],
        "faixas": blob[33],
        "salt": blob[34:50],
        "vinculo": blob[50],
        "nuvem": blob[117] == 1,
    }


def abrir(blob, senha):
    cab = ler_cabecalho(blob)

    if cab["vinculo"] == 1:
        print(
            "aviso: este cofre está preso ao Secure Enclave do aparelho que o criou.\n"
            "       sem aquele aparelho ele não abre, aqui nem em lugar nenhum.",
            file=sys.stderr,
        )

    cabecalho = blob[:HEADER_LEN]

    mk = hash_secret_raw(
        # NFKC antes de codificar. Ver a especificação no topo deste arquivo.
        secret=unicodedata.normalize("NFKC", senha).encode("utf-8"),
        salt=cab["salt"],
        time_cost=cab["passes"],
        memory_cost=cab["memoria_kib"],
        parallelism=cab["faixas"],
        hash_len=32,
        type=Type.ID,
        version=0x13,
    )

    encontrados = []
    for indice in range(SLOT_COUNT):
        base = HEADER_LEN + indice * SLOT_LEN
        slot = blob[base:base + SLOT_LEN]
        salt_slot = slot[0:32]
        salt_embrulho = slot[32:64]
        dek_embrulhada = slot[64:112]
        salt_conteudo = slot[112:144]
        conteudo = slot[144:SLOT_LEN]

        info = b"escalibur/v1/kek" + bytes([indice]) + cab["uuid"]
        kek = hkdf(mk, salt_slot, info)

        aad_w = cabecalho + bytes([indice]) + salt_slot
        try:
            dek = ChaCha20Poly1305(
                hkdf(kek, salt_embrulho, b"escalibur/v1/wrap")
            ).decrypt(NONCE, dek_embrulhada, aad_w)
        except Exception:
            continue

        aad_p = aad_w + salt_embrulho + dek_embrulhada
        try:
            bloco = ChaCha20Poly1305(
                hkdf(dek, salt_conteudo, b"escalibur/v1/payload")
            ).decrypt(NONCE, conteudo, aad_p)
        except Exception:
            continue

        encontrados.append((indice, decodificar(bloco)))

    return cab, encontrados


def decodificar(bloco):
    if len(bloco) != PLAINTEXT_LEN or bloco[0] != 1 or bloco[1] not in (1, 2):
        # Versao de conteudo ou tipo que este script nao conhece. O bloco ja foi
        # autenticado, entao ele e legitimo: o certo aqui e despejar os bytes, e nao
        # sair em silencio. Este script existe justamente para o dia em que o formato
        # evoluiu, e alguem consegue ler as palavras a mao a partir do hexadecimal.
        return {"desconhecido": bloco}

    idioma = IDIOMAS[bloco[2]] if bloco[2] < len(IDIOMAS) else "desconhecido"
    tamanhos = struct.unpack(">HHHH", bloco[4:12])
    cursor = 12
    campos = []
    for tamanho in tamanhos:
        campos.append(bloco[cursor:cursor + tamanho].decode("utf-8"))
        cursor += tamanho
    return {
        "tipo": "parte SLIP-39" if bloco[1] == 2 else "frase BIP-39",
        "frase": campos[0],
        "passphrase": campos[1],
        "nome": campos[2],
        # Uma parte SLIP-39 nao pertence a idioma nenhum: a lista dela e unica.
        "anotacoes": campos[3],
        "idioma": "-" if bloco[1] == 2 else idioma,
    }


def main():
    if len(sys.argv) != 2:
        sys.exit(f"uso: {sys.argv[0]} arquivo.esclbr")

    with open(sys.argv[1], "rb") as arquivo:
        blob = arquivo.read()

    senha = getpass.getpass("senha do cofre: ")
    cab, encontrados = abrir(blob, senha)

    print()
    print(f"  Argon2id      m={cab['memoria_kib']} KiB  t={cab['passes']}  p={cab['faixas']}")
    print(f"  nuvem         {'ligada' if cab['nuvem'] else 'desligada'}")
    print()

    if not encontrados:
        # Uma mensagem só, de propósito. Distinguir "senha errada" de "arquivo
        # corrompido" daria a quem ataca um verificador barato.
        sys.exit("não foi possível abrir este cofre.")

    for indice, conteudo in encontrados:
        if conteudo is None:
            continue
        if "desconhecido" in conteudo:
            bruto = conteudo["desconhecido"].rstrip(b"\x00")
            print(f"  compartimento {indice}")
            print("  tipo          desconhecido por este programa")
            print()
            print("  O conteúdo abriu e a autenticação passou, mas a versão ou o tipo")
            print("  do bloco são mais novos do que este programa. Os bytes em claro")
            print("  estão abaixo, em hexadecimal, e as palavras estão dentro deles.")
            print()
            for offset in range(0, len(bruto), 32):
                pedaco = bruto[offset:offset + 32]
                texto = "".join(chr(b) if 32 <= b < 127 else "." for b in pedaco)
                print(f"    {offset:04x}  {pedaco.hex()}  {texto}")
            print()
            continue
        print(f"  compartimento {indice}")
        print(f"  tipo          {conteudo['tipo']}")
        print(f"  nome          {conteudo['nome']}")
        print(f"  idioma        {conteudo['idioma']}")
        if conteudo["anotacoes"]:
            print(f"  anotações     {conteudo['anotacoes']}")
        if conteudo["passphrase"]:
            print(f"  25ª palavra   {conteudo['passphrase']}")
        print()
        palavras = conteudo["frase"].split()
        for numero, palavra in enumerate(palavras, start=1):
            print(f"    {numero:2d}. {palavra}")
        print()


if __name__ == "__main__":
    main()
