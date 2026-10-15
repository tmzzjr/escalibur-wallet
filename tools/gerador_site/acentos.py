"""Acento de volta no texto que o repositorio escreve sem acento.

Commits, comentarios e mensagens do tools/verificar.sh sao escritos sem acento (convencao
do repositorio). O site e lido por gente: o assunto do commit e as verificacoes aparecem
com acento. A regra so mexe no que nao tem ambiguidade: terminacoes que em portugues
sempre levam acento (-cao, -coes, -sao, -vel, -encia) e uma lista fechada de palavras.
Palavra fora disso sai como esta; "e"/"é", "esta"/"está" e "tem"/"têm" so mudam nas
frases listadas em FRASES. Trecho com cara de codigo (barra, ponto no meio, crase,
sublinhado) nunca e tocado.
"""

import re

PALAVRAS = {
    "nao": "não", "so": "só", "ja": "já", "ate": "até", "tambem": "também", "voce": "você", "voces": "vocês",
    "alem": "além", "apos": "após", "tres": "três", "mes": "mês", "meses": "meses", "sera": "será", "ninguem": "ninguém",
    "alguem": "alguém", "porem": "porém", "atraves": "através", "atras": "atrás", "entao": "então", "estao": "estão",
    "sao": "são", "tao": "tão", "le": "lê", "ha": "há", "contem": "contém", "mantem": "mantém", "obtem": "obtém",
    "pagina": "página", "paginas": "páginas", "numero": "número", "numeros": "números", "unico": "único",
    "unica": "única", "unicos": "únicos", "unicas": "únicas", "ultimo": "último", "ultima": "última", "ultimos": "últimos",
    "ultimas": "últimas", "minimo": "mínimo", "minima": "mínima", "minimos": "mínimos", "maximo": "máximo",
    "maxima": "máxima", "maximos": "máximos", "codigo": "código", "codigos": "códigos", "modulo": "módulo",
    "modulos": "módulos", "titulo": "título", "titulos": "títulos", "pilula": "pílula", "pilulas": "pílulas",
    "capsula": "cápsula", "proprio": "próprio", "propria": "própria", "proprios": "próprios", "proprias": "próprias",
    "proximo": "próximo", "proxima": "próxima", "rapido": "rápido", "rapida": "rápida", "facil": "fácil",
    "dificil": "difícil", "util": "útil", "uteis": "úteis", "seguranca": "segurança", "preco": "preço", "precos": "preços",
    "memoria": "memória", "historia": "história", "historico": "histórico", "historicos": "históricos",
    "grafico": "gráfico", "graficos": "gráficos", "publico": "público", "publica": "pública", "publicos": "públicos",
    "publicas": "públicas", "tecnico": "técnico", "tecnica": "técnica", "classico": "clássico", "basico": "básico",
    "diagnostico": "diagnóstico", "automatico": "automático", "automatica": "automática", "automaticos": "automáticos",
    "politica": "política", "logica": "lógica", "pratica": "prática", "especifico": "específico",
    "especifica": "específica", "generico": "genérico", "numerico": "numérico", "atomico": "atômico",
    "cientifica": "científica", "periodo": "período", "periodos": "períodos", "indice": "índice", "metodo": "método",
    "parametro": "parâmetro", "parametros": "parâmetros", "destinatario": "destinatário", "formulario": "formulário",
    "binario": "binário", "binarios": "binários", "repositorio": "repositório", "horaria": "horária",
    "obrigatorio": "obrigatório", "aleatorio": "aleatório", "aleatoria": "aleatória", "relogio": "relógio",
    "deposito": "depósito", "oraculo": "oráculo", "minusculo": "minúsculo", "maiusculo": "maiúsculo",
    "analise": "análise", "audio": "áudio", "anuncio": "anúncio", "anuncios": "anúncios", "inicio": "início",
    "varias": "várias", "varios": "vários", "copia": "cópia", "copias": "cópias", "conteudo": "conteúdo",
    "saida": "saída", "nucleo": "núcleo", "simbolo": "símbolo", "simbolos": "símbolos", "camera": "câmera",
    "conteiner": "contêiner", "area": "área", "areas": "áreas", "endereco": "endereço", "enderecos": "endereços",
    "servico": "serviço", "servicos": "serviços", "espaco": "espaço", "comeco": "começo", "comeca": "começa",
    "comecar": "começar", "forca": "força", "cabecalho": "cabeçalho", "pedaco": "pedaço", "lancamento": "lançamento",
    "licenca": "licença", "diferenca": "diferença", "dolar": "dólar", "dolares": "dólares", "ingles": "inglês",
    "portugues": "português", "serie": "série", "duvida": "dúvida", "duvidas": "dúvidas", "ruido": "ruído",
    "juridico": "jurídico", "lingua": "língua", "linguas": "línguas", "estrategia": "estratégia", "economico": "econômico", "medio": "médio",
    "invalido": "inválido", "invalida": "inválida", "valido": "válido", "unidade": "unidade", "rotulo": "rótulo",
    "rotulos": "rótulos", "icone": "ícone", "icones": "ícones", "botao": "botão", "botoes": "botões",
    "padrao": "padrão", "padroes": "padrões", "transicao": "transição", "decifravel": "decifrável", "frase": "frase",
    "silaba": "sílaba", "logico": "lógico", "fisico": "físico", "fisica": "física", "tipico": "típico",
    "mecanica": "mecânica", "dinamico": "dinâmico", "dinamica": "dinâmica", "critico": "crítico", "critica": "crítica",
    "valida": "válida", "otimo": "ótimo", "pessimo": "péssimo", "previa": "prévia", "secundario": "secundário",
    "necessario": "necessário", "necessaria": "necessária", "provisorio": "provisório", "usuario": "usuário",
    "usuarios": "usuários", "dicionario": "dicionário", "calendario": "calendário", "cenario": "cenário",
    "cenarios": "cenários", "comentario": "comentário", "comentarios": "comentários", "intermediario": "intermediário",
    "saldo": "saldo", "nivel": "nível", "niveis": "níveis", "mae": "mãe", "manha": "manhã", "amanha": "amanhã",
    "veiculo": "veículo", "tamanho": "tamanho", "chines": "chinês", "japones": "japonês", "frances": "francês",
    "coreano": "coreano", "tcheco": "tcheco", "matematica": "matemática", "musica": "música", "fragil": "frágil",
    "acessivel": "acessível", "ola": "olá", "aqui": "aqui", "agua": "água", "unicode": "unicode",
}

# Terminacoes que sempre levam acento (a palavra inteira tem de terminar assim).
SUFIXOS = [
    ("coes", "ções"), ("cao", "ção"), ("soes", "sões"), ("oes", "ões"), ("aes", "ães"),
    ("iveis", "íveis"), ("aveis", "áveis"), ("ivel", "ível"), ("avel", "ável"),
    ("encias", "ências"), ("encia", "ência"), ("ancias", "âncias"), ("ancia", "ância"),
    ("ao", "ão"),
]
NAO_MEXER = {"ao", "aos", "does", "goes", "shoes", "heroes", "dao", "cacao", "vel", "evel"}

# Frases em que "e", "esta" ou "tem" sao verbo.
FRASES = [
    (r"\baleatoriedade e o\b", "aleatoriedade é o"),
    (r"\bcopiado e local\b", "copiado é local"),
    (r"\besta na Política\b", "está na Política"),
    (r"\bnão tem código de rede\b", "não têm código de rede"),
    (r"\bo envelope e tao forte\b", "o envelope é tão forte"),
]

_PALAVRA = re.compile(r"[A-Za-z]+")


def _troca(palavra):
    baixa = palavra.lower()
    if palavra.isupper() and len(palavra) > 1:
        return palavra
    nova = PALAVRAS.get(baixa)
    if nova is None and baixa not in NAO_MEXER and len(baixa) > 3:
        for sufixo, acentuado in SUFIXOS:
            if baixa.endswith(sufixo):
                nova = baixa[: -len(sufixo)] + acentuado
                break
    if nova is None:
        return palavra
    return nova[0].upper() + nova[1:] if palavra[0].isupper() else nova


def _parece_codigo(trecho):
    return bool(re.search(r"[/_`=@<>{}\\]|\w\.\w|[a-z][A-Z]|^\.|^#|\(\)", trecho))


def acentuar(texto):
    pedacos = re.split(r"(\s+)", texto)
    saida = []
    for pedaco in pedacos:
        if not pedaco or pedaco.isspace() or _parece_codigo(pedaco):
            saida.append(pedaco)
        else:
            saida.append(_PALAVRA.sub(lambda m: _troca(m.group(0)), pedaco))
    resultado = "".join(saida)
    for padrao, troca in FRASES:
        resultado = re.sub(padrao, troca, resultado)
    return sem_travessao(resultado)


def sem_travessao(texto):
    """Nenhum texto do site tem travessao: vira virgula entre palavras, hifen no resto."""
    texto = re.sub(r"\s+[—–]\s+", ", ", texto)
    return texto.replace("—", "-").replace("–", "-")
