"""PNG reduzido so com a biblioteca padrao.

As logos do app tem 250 px e o icone 1024 px; o site mostra a 40 ou 48 px. Copiar o
original pesaria meio megabyte so de logos de rede na pagina inicial. Aqui o PNG e
lido (zlib e os cinco filtros do formato), reduzido pela metade quantas vezes couber
acima do tamanho pedido (media de cada bloco 2x2, com alfa pre-multiplicado para a
borda nao escurecer) e gravado de novo. Sem Pillow: o gerador do site so usa a
biblioteca padrao.

Formatos aceitos: 8 bits por canal, sem entrelacamento, em cinza, RGB, paleta, cinza
com alfa e RGBA. Fora disso, `reduzir` devolve None e quem chama copia o original.
"""

import struct
import zlib

ASSINATURA = b"\x89PNG\r\n\x1a\n"


def _ler(dados):
    if dados[:8] != ASSINATURA:
        return None
    pos, idat, plte, trns, cab = 8, [], None, None, None
    while pos < len(dados):
        n, tipo = struct.unpack(">I4s", dados[pos:pos + 8])
        corpo = dados[pos + 8:pos + 8 + n]
        pos += 12 + n
        if tipo == b"IHDR":
            cab = struct.unpack(">IIBBBBB", corpo)
        elif tipo == b"PLTE":
            plte = corpo
        elif tipo == b"tRNS":
            trns = corpo
        elif tipo == b"IDAT":
            idat.append(corpo)
        elif tipo == b"IEND":
            break
    if cab is None:
        return None
    largura, altura, profundidade, cor, _, _, entrelacado = cab
    if profundidade != 8 or entrelacado or cor not in (0, 2, 3, 4, 6):
        return None
    canais = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[cor]
    cru = zlib.decompress(b"".join(idat))
    linhas = _desfiltrar(cru, largura * canais, altura, canais)
    return largura, altura, _para_rgba(linhas, largura, cor, plte, trns)


def _desfiltrar(cru, passo, altura, bpp):
    linhas, anterior, p = [], bytearray(passo), 0
    for _ in range(altura):
        filtro = cru[p]
        linha = bytearray(cru[p + 1:p + 1 + passo])
        p += 1 + passo
        if filtro == 1:
            for i in range(bpp, passo):
                linha[i] = (linha[i] + linha[i - bpp]) & 255
        elif filtro == 2:
            for i in range(passo):
                linha[i] = (linha[i] + anterior[i]) & 255
        elif filtro == 3:
            for i in range(passo):
                a = linha[i - bpp] if i >= bpp else 0
                linha[i] = (linha[i] + ((a + anterior[i]) >> 1)) & 255
        elif filtro == 4:
            for i in range(passo):
                a = linha[i - bpp] if i >= bpp else 0
                b = anterior[i]
                c = anterior[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                linha[i] = (linha[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        linhas.append(linha)
        anterior = linha
    return linhas


def _para_rgba(linhas, largura, cor, plte, trns):
    """Cada linha vira RGBA de 8 bits."""
    saida = []
    for linha in linhas:
        if cor == 6:
            saida.append(linha)
            continue
        rgba = bytearray(largura * 4)
        for x in range(largura):
            if cor == 2:
                r, g, b = linha[3 * x], linha[3 * x + 1], linha[3 * x + 2]
                a = 255
            elif cor == 0:
                r = g = b = linha[x]
                a = 255
            elif cor == 4:
                r = g = b = linha[2 * x]
                a = linha[2 * x + 1]
            else:
                i = linha[x]
                r, g, b = plte[3 * i], plte[3 * i + 1], plte[3 * i + 2]
                a = trns[i] if trns is not None and i < len(trns) else 255
            rgba[4 * x:4 * x + 4] = bytes((r, g, b, a))
        saida.append(rgba)
    return saida


def _metade(largura, altura, linhas):
    """Media de cada bloco 2x2, com alfa pre-multiplicado."""
    nl, na = max(1, largura // 2), max(1, altura // 2)
    saida = []
    for y in range(na):
        l0, l1 = linhas[min(2 * y, altura - 1)], linhas[min(2 * y + 1, altura - 1)]
        nova = bytearray(nl * 4)
        for x in range(nl):
            r = g = b = a = 0
            for linha in (l0, l1):
                for xx in (min(2 * x, largura - 1), min(2 * x + 1, largura - 1)):
                    k = 4 * xx
                    alfa = linha[k + 3]
                    r += linha[k] * alfa
                    g += linha[k + 1] * alfa
                    b += linha[k + 2] * alfa
                    a += alfa
            if a:
                nova[4 * x:4 * x + 4] = bytes(((r + a // 2) // a, (g + a // 2) // a, (b + a // 2) // a, (a + 2) // 4))
        saida.append(nova)
    return nl, na, saida


def _gravar(largura, altura, linhas):
    """PNG RGBA, com o filtro de menor soma em cada linha."""
    corpo, anterior = bytearray(), bytearray(largura * 4)
    for linha in linhas:
        candidatos = [(0, linha)]
        sub = bytearray(linha)
        for i in range(4, len(linha)):
            sub[i] = (linha[i] - linha[i - 4]) & 255
        candidatos.append((1, sub))
        cima = bytearray((linha[i] - anterior[i]) & 255 for i in range(len(linha)))
        candidatos.append((2, cima))
        paeth = bytearray(len(linha))
        for i in range(len(linha)):
            a = linha[i - 4] if i >= 4 else 0
            b = anterior[i]
            c = anterior[i - 4] if i >= 4 else 0
            pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
            paeth[i] = (linha[i] - (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        candidatos.append((4, paeth))
        filtro, escolhida = min(candidatos, key=lambda c: sum(v if v < 128 else 256 - v for v in c[1]))
        corpo.append(filtro)
        corpo += escolhida
        anterior = linha

    def pedaco(tipo, dados):
        return struct.pack(">I", len(dados)) + tipo + dados + struct.pack(">I", zlib.crc32(tipo + dados) & 0xFFFFFFFF)

    cabecalho = struct.pack(">IIBBBBB", largura, altura, 8, 6, 0, 0, 0)
    return ASSINATURA + pedaco(b"IHDR", cabecalho) + pedaco(b"IDAT", zlib.compress(bytes(corpo), 9)) + pedaco(b"IEND", b"")


def reduzir(dados, lado_minimo):
    """O PNG reduzido pela metade enquanto o maior lado continuar >= `lado_minimo`.

    Devolve (bytes, largura, altura), ou None se o formato nao for aceito. Se nao
    houver o que reduzir, devolve o original.
    """
    lido = _ler(dados)
    if lido is None:
        return None
    largura, altura, linhas = lido
    if max(largura, altura) // 2 < lado_minimo:
        return dados, largura, altura
    while max(largura, altura) // 2 >= lado_minimo:
        largura, altura, linhas = _metade(largura, altura, linhas)
    return _gravar(largura, altura, linhas), largura, altura


def dimensoes(dados):
    if dados[:8] != ASSINATURA:
        return None
    largura, altura = struct.unpack(">II", dados[16:24])
    return largura, altura
