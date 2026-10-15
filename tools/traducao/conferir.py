#!/usr/bin/env python3
"""Confere e alimenta o catalogo de traducoes (App/EscaliburWallet/Resources/Localizable.xcstrings).

    python3 tools/traducao/conferir.py                  falha se faltar ou se houver traducao invalida
    python3 tools/traducao/conferir.py --resumo         so conta, sem falhar
    python3 tools/traducao/conferir.py --exportar en x.json      o que falta em ingles, com ids curtos
    python3 tools/traducao/conferir.py --validar en x.json y.json...  so confere as traducoes, sem gravar
    python3 tools/traducao/conferir.py --importar en x.json y.json... grava as traducoes de y (ids de x)

Toda traducao passa pelas mesmas regras antes de entrar e a cada conferencia:
- os campos (%@, %lld, %u...) sao os mesmos do original, em qualquer ordem (%1$@, %2$@);
- espaco no comeco e no fim fica como no original (o texto e colado em outro);
- sem travessao nem meia-risca, como no resto da interface;
- texto sem letra (so numero, simbolo ou campo) nao se traduz: vai igual em todo idioma.
A traducao pode ter formas de plural ("one", "other", e no arabe "zero", "two", "few",
"many"), cada uma com os mesmos campos.
"""
import json, os, re, sys

RAIZ = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOGO = os.path.join(RAIZ, "App/EscaliburWallet/Resources/Localizable.xcstrings")
IDIOMAS = ["en", "es", "fr", "de", "hi", "zh-Hans", "ja", "ko", "tr", "id", "vi", "ar"]
PLURAIS = {"zero", "one", "two", "few", "many", "other"}
CAMPO = re.compile(r"%(?:(\d+)\$)?(lld|llu|ld|lu|u|d|i|@|lf|f|%)")
TRAVESSAO = re.compile("[—–]")


def campos(texto):
    """Os tipos dos campos na ordem dos argumentos, e a contagem de %% literais."""
    sequencial, posicional, literais = [], {}, 0
    for m in CAMPO.finditer(texto):
        if m.group(2) == "%":
            literais += 1
            continue
        tipo = {"lld": "int", "llu": "int", "ld": "int", "lu": "int", "u": "int", "d": "int", "i": "int",
                "@": "obj", "lf": "real", "f": "real"}[m.group(2)]
        if m.group(1):
            posicional[int(m.group(1))] = tipo
        else:
            sequencial.append(tipo)
    if posicional:
        return [posicional.get(i) for i in range(1, max(posicional) + 1)] + sequencial, literais
    return sequencial, literais


def sem_letra(chave):
    """So campos, numeros e simbolos: vai igual em todo idioma. Uma letra solta ja conta
    como texto ("%@ e %@" junta duas frases com o "e" do portugues)."""
    return not re.search(r"[^\W\d_]", CAMPO.sub("", chave))


def problemas(chave, valor):
    erros = []
    origem, literais = campos(chave)
    destino, literais_destino = campos(valor)
    if origem:
        if sorted(map(str, origem)) != sorted(map(str, destino)) or (destino and destino != origem and None in destino):
            erros.append("campos diferentes do original")
        elif destino != origem:
            erros.append("campos fora de ordem sem posicao (%1$@)")
        if literais != literais_destino:
            erros.append("quantidade de %% diferente")
    elif destino:
        erros.append("campo que o original nao tem")
    if chave[:1].isspace() != valor[:1].isspace() or chave[-1:].isspace() != valor[-1:].isspace():
        erros.append("espaco no comeco ou no fim diferente")
    if TRAVESSAO.search(valor):
        erros.append("travessao")
    return erros


def formas(localizacao):
    """O texto de uma traducao: {"": valor} ou {categoria: valor} no plural."""
    if "stringUnit" in localizacao:
        return {"": localizacao["stringUnit"].get("value", "")}
    plural = localizacao.get("variations", {}).get("plural")
    if plural:
        return {k: v.get("stringUnit", {}).get("value", "") for k, v in plural.items()}
    return {}


def ler():
    with open(CATALOGO, encoding="utf-8") as arquivo:
        return json.load(arquivo)


def gravar(dados):
    # O mesmo formato que o Xcode grava: chaves em ordem, " : " e 2 espacos.
    texto = json.dumps(dados, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    with open(CATALOGO, "w", encoding="utf-8") as arquivo:
        arquivo.write(texto + "\n")


def ativas(dados):
    return {k: v for k, v in dados["strings"].items() if v.get("extractionState") != "stale" and v.get("shouldTranslate", True)}


def conferir(dados, estrito):
    chaves = ativas(dados)
    total_erros = 0
    for idioma in IDIOMAS:
        faltam, invalidas = 0, []
        for chave, entrada in chaves.items():
            if sem_letra(chave):
                continue
            loc = entrada.get("localizations", {}).get(idioma)
            textos = formas(loc) if loc else {}
            if not textos or not any(textos.values()):
                faltam += 1
                continue
            for categoria, valor in textos.items():
                if categoria and categoria not in PLURAIS:
                    invalidas.append((chave, "plural desconhecido " + categoria))
                for erro in problemas(chave, valor):
                    invalidas.append((chave, erro))
        print("%-8s %4d traduzidos, %4d faltando, %d invalidos" % (idioma, len(chaves) - faltam, faltam, len(invalidas)))
        for chave, erro in invalidas[:20]:
            print("    %s: %r" % (erro, chave[:90]))
        total_erros += len(invalidas) + (faltam if estrito else 0)
    return total_erros


def origens():
    """De que arquivos vem cada texto, pelo que o compilador extraiu (build/dd-loc): o
    contexto de quem traduz ("Para" na revisao do envio nao e o "Para" de um titulo)."""
    import glob
    mapa = {}
    for arquivo in glob.glob(os.path.join(RAIZ, "build/dd-loc/**/arm64/*.stringsdata"), recursive=True):
        with open(arquivo, encoding="utf-8") as entrada:
            dados = json.load(entrada)
        nome = os.path.basename(dados.get("source", ""))
        for itens in dados.get("tables", {}).values():
            for item in itens:
                mapa.setdefault(item["key"], set()).add(nome)
    return mapa


def exportar(dados, idioma, destino):
    chaves = sorted(ativas(dados))
    onde = origens()
    saida = []
    for numero, chave in enumerate(chaves, 1):
        if sem_letra(chave):
            continue
        entrada = dados["strings"][chave]
        loc = entrada.get("localizations", {}).get(idioma)
        if loc and any(formas(loc).values()):
            continue
        item = {"id": "t%04d" % numero, "pt": chave}
        ingles = entrada.get("localizations", {}).get("en")
        if idioma != "en" and ingles:
            item["en"] = formas(ingles)
            if list(item["en"]) == [""]:
                item["en"] = item["en"][""]
        if entrada.get("comment"):
            item["nota"] = entrada["comment"]
        if onde.get(chave):
            item["onde"] = sorted(onde[chave])[:3]
        saida.append(item)
    with open(destino, "w", encoding="utf-8") as arquivo:
        json.dump(saida, arquivo, ensure_ascii=False, indent=1)
    print(len(saida), "textos para", idioma, "em", destino)


def importar(dados, idioma, mapa, traducoes, gravando=True):
    ids = {item["id"]: item["pt"] for item in json.load(open(mapa, encoding="utf-8"))}
    novas = {}
    for caminho in traducoes:
        novas.update(json.load(open(caminho, encoding="utf-8")))
    aceitas, recusadas = 0, []
    for ident, valor in novas.items():
        chave = ids.get(ident)
        if chave is None or chave not in dados["strings"]:
            recusadas.append((ident, "id desconhecido"))
            continue
        textos = valor if isinstance(valor, dict) else {"": valor}
        erros = [e for c, v in textos.items() for e in (problemas(chave, v) + ([] if not c or c in PLURAIS else ["plural " + c]))]
        if isinstance(valor, dict) and "other" not in valor:
            erros.append("plural sem 'other'")
        if erros:
            recusadas.append((ident, "; ".join(sorted(set(erros))) + " | " + chave[:60]))
            continue
        if not gravando:
            aceitas += 1
            continue
        entrada = dados["strings"][chave]
        if isinstance(valor, dict):
            loc = {"variations": {"plural": {c: {"stringUnit": {"state": "translated", "value": v}} for c, v in valor.items()}}}
        else:
            loc = {"stringUnit": {"state": "translated", "value": valor}}
        entrada.setdefault("localizations", {})[idioma] = loc
        aceitas += 1
    faltam = sorted(set(ids) - set(novas))
    if gravando:
        gravar(dados)
    print(aceitas, "traducoes", "gravadas" if gravando else "validas", "em", idioma, "|", len(recusadas), "recusadas |",
          len(faltam), "ids do mapa sem traducao")
    for ident, motivo in recusadas:
        print("   ", ident, motivo)
    if faltam and not gravando:
        print("    sem traducao:", " ".join(faltam[:40]) + (" ..." if len(faltam) > 40 else ""))
    return not recusadas


def main():
    dados = ler()
    argumentos = sys.argv[1:]
    if argumentos[:1] == ["--exportar"]:
        exportar(dados, argumentos[1], argumentos[2])
    elif argumentos[:1] == ["--importar"]:
        importar(dados, argumentos[1], argumentos[2], argumentos[3:])
    elif argumentos[:1] == ["--validar"]:
        if not importar(dados, argumentos[1], argumentos[2], argumentos[3:], gravando=False):
            sys.exit(1)
    else:
        erros = conferir(dados, estrito="--resumo" not in argumentos)
        if erros and "--resumo" not in argumentos:
            sys.exit(1)


if __name__ == "__main__":
    main()
