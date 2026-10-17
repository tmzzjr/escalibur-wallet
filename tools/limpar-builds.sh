#!/bin/bash
# Limpa os builds que tarefas e subagentes deixaram para tras (pedido do dono, 17/10/2026).
#
#   tools/limpar-builds.sh            lista o que sairia e quanto libera
#   tools/limpar-builds.sh --apagar   apaga
#
# Onde procura: os scratchpads das sessoes do Claude Code deste projeto e as worktrees dos
# agentes (.claude/worktrees). O que sai: intermediarios do Xcode (Build, Index.noindex,
# ModuleCache.noindex, SourcePackages, CompilationCache.noindex, SDKStatCaches.noindex) e
# as pastas de build do SwiftPM (.build, ou a pasta passada em --scratch-path). O que fica:
# relatorios, logs (inclusive os Logs do Xcode), .xcresult com as capturas, .xcarchive, .ipa
# e o build principal do projeto (build/dd-ui e Kit/.build), que deixa o proximo build rapido.
set -euo pipefail
cd "$(dirname "$0")/.."
PROJETO="$(pwd)"
MODO="${1:-}"
SCRATCH="/private/tmp/claude-$(id -u)/$(echo "$PROJETO" | sed 's|/|-|g')"

python3 -I - "$MODO" "$PROJETO" "$SCRATCH" <<'PY'
import os, shutil, sys
modo, projeto, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
XCODE = {"Build", "Index.noindex", "ModuleCache.noindex", "SourcePackages", "CompilationCache.noindex",
         "SDKStatCaches.noindex", "TextIndex", "EagerLinkingTBDs", "ExplicitPrecompiledModules"}
SPM = {"build.db", "workspace-state.json", "arm64-apple-macosx", "x86_64-apple-macosx"}
EVIDENCIA = (".xcresult", ".xcarchive", ".app", ".ipa", ".git")
PRINCIPAL = {os.path.join(projeto, "build", "dd-ui"), os.path.join(projeto, "Kit", ".build")}

def tamanho(path):
    total = 0
    for raiz, _, arquivos in os.walk(path, followlinks=False):
        for nome in arquivos:
            try:
                caminho = os.path.join(raiz, nome)
                if not os.path.islink(caminho): total += os.lstat(caminho).st_blocks * 512
            except OSError:
                pass
    return total

def alvos(base):
    for raiz, pastas, arquivos in os.walk(base, followlinks=False):
        nomes = set(pastas) | set(arquivos)
        if os.path.realpath(raiz) in PRINCIPAL:
            pastas[:] = []
            continue
        if "Build" in pastas and nomes & {"Logs", "info.plist", "Index.noindex", "ModuleCache.noindex", "SourcePackages"}:
            for nome in sorted(set(pastas) & XCODE): yield os.path.join(raiz, nome)
            pastas[:] = [p for p in pastas if p not in XCODE]
            continue
        if nomes & SPM and nomes & {"debug", "release", "arm64-apple-macosx"}:
            yield raiz
            pastas[:] = []
            continue
        for nome in (".build",):
            if nome in pastas and os.path.realpath(os.path.join(raiz, nome)) not in PRINCIPAL:
                yield os.path.join(raiz, nome)
        pastas[:] = [p for p in pastas if p != ".build" and not p.endswith(EVIDENCIA)]

bases = []
if os.path.isdir(scratch):
    bases += [os.path.join(scratch, s, "scratchpad") for s in os.listdir(scratch) if os.path.isdir(os.path.join(scratch, s, "scratchpad"))]
worktrees = os.path.join(projeto, ".claude", "worktrees")

lista = []
for base in bases:
    for caminho in alvos(base): lista.append((tamanho(caminho), caminho))
if os.path.isdir(worktrees):
    for w in sorted(os.listdir(worktrees)):
        for sub in ("build", ".build", os.path.join("Kit", ".build")):
            caminho = os.path.join(worktrees, w, sub)
            if os.path.isdir(caminho): lista.append((tamanho(caminho), caminho))

lista.sort(reverse=True)
total = sum(t for t, _ in lista)
for t, caminho in lista[:30]: print("%8.0f MB  %s" % (t / 1e6, caminho))
if len(lista) > 30: print("  ... e mais %d" % (len(lista) - 30))
print("%d pastas de build, %.1f GB" % (len(lista), total / 1e9))
if modo == "--apagar":
    for _, caminho in lista:
        real = os.path.realpath(caminho)
        if real in PRINCIPAL or not (real.startswith(os.path.realpath(scratch) + "/") or real.startswith(os.path.realpath(worktrees) + "/")):
            continue
        shutil.rmtree(real, ignore_errors=True)
    print("apagado.")
else:
    print("nada apagado; rode com --apagar para liberar.")
PY
