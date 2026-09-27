# Formato `.esclbr`, versão 1

Este documento descreve o arquivo de cofre do Escalibur campo a campo, para que
qualquer pessoa possa escrever um programa que o abra sem depender do aplicativo.

Ele é gerado a partir do cabeçalho de `decifrar.py`, que é o programa de referência
que implementa exatamente o que está descrito aqui. Uma fonte só, então a descrição
não pode divergir do código.

## FORMATO (versão 1). Todos os inteiros em big-endian.

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
separadas por um único espaço comum (U+0020)**, inclusive em japonês, que no
papel usa o espaço ideográfico (U+3000). Os bytes lidos daqui são exatamente a
entrada do PBKDF2 do BIP-39; quem reimplementar não deve normalizar de novo nem
"consertar" os espaços. Uma parte SLIP-39 segue a mesma forma.

O bloco tem tamanho fixo, então o arquivo inteiro tem sempre 16504 bytes e o
tamanho não conta nem quantas palavras a frase tem nem se existe anotação.

## Verificando por conta própria

O decifrador de referência acompanha este documento:

```
pip install argon2-cffi cryptography
python3 decifrar.py cofre-XXXX.esclbr
```
