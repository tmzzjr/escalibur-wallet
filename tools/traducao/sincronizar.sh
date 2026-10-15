#!/bin/bash
# Atualiza o catalogo de traducoes com os textos que o codigo usa hoje.
#
#   tools/traducao/sincronizar.sh
#
# Compila o app (e o Kit junto) pedindo ao compilador a lista de textos traduziveis
# (SWIFT_EMIT_LOC_STRINGS): Text("..."), String(localized:) no app e kitText(...) no Kit.
# A lista entra no App/EscaliburWallet/Resources/Localizable.xcstrings, o unico catalogo do
# projeto. Texto novo entra sem traducao; texto que saiu do codigo fica marcado como
# velho. Depois, tools/traducao/conferir.py diz o que falta traduzir.
set -euo pipefail
cd "$(dirname "$0")/../.."

catalogo="App/EscaliburWallet/Resources/Localizable.xcstrings"
saida="build/dd-loc"

xcodebuild -project EscaliburWallet.xcodeproj -scheme EscaliburWallet -configuration Debug \
    -destination "generic/platform=iOS Simulator" -derivedDataPath "$saida" \
    SWIFT_EMIT_LOC_STRINGS=YES build -quiet

# Uma arquitetura basta: as duas listam os mesmos textos.
lista=()
while IFS= read -r arquivo; do lista+=(--stringsdata "$arquivo"); done < <(
    find "$saida/Build/Intermediates.noindex" -path "*/Objects-normal/arm64/*.stringsdata" | sort
)
[ ${#lista[@]} -gt 0 ] || { echo "nenhum .stringsdata: a compilacao nao extraiu os textos" >&2; exit 1; }
xcrun xcstringstool sync "$catalogo" "${lista[@]}"
python3 tools/traducao/conferir.py --resumo
