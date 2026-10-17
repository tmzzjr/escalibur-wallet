# Escalibur Wallet

## Builds e disco (17/10/2026)

Cada tarefa e cada subagente criava uma pasta de build nova (o scratchpad chegou a 35 GB, o
disco a 21 GB livres). A regra agora:

- **Um build por tipo, reaproveitado.** Xcode sempre com `-derivedDataPath build/dd-ui`
  (simulador e testes) ou `build/dd-release` (archive). Kit pelo SwiftPM de dentro de `Kit/`,
  no `.build` padrão, sem `--scratch-path`. Reaproveitar deixa o build mais rápido.
- **Nada de pasta de build nova no scratchpad.** Se precisar de uma cópia isolada (commit
  antigo, auditoria, prova de conceito), compile nela e apague o build dela ao terminar a
  tarefa (`build/`, `.build`, `Kit/.build`, os intermediários do Xcode).
- **Dois builds ao mesmo tempo** (subagentes em paralelo) não dividem a mesma pasta: o Xcode
  trava o banco do build. Use uma pasta própria dentro de `build/` e apague ao terminar; em
  worktree, o build da própria worktree, apagado ao terminar.
- **O histórico fica:** relatórios, logs, capturas, `.xcresult`, `.xcarchive` e `.ipa` não se
  apagam.
- **Só o simulador iPhone 17 que já está aberto** (`C2047B7F-C3CF-4BE4-A01B-1AF9100A4D97`).
  Nada de criar nem bootar outro.
- Para limpar o que acumulou: `tools/limpar-builds.sh` lista; `tools/limpar-builds.sh
  --apagar` apaga. Ele nunca toca em `build/dd-ui`, em `Kit/.build`, nem em histórico.
