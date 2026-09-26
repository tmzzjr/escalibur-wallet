#!/bin/bash
# Lacra um envelope com o codigo de hoje e abre com o decifrar.py embarcado.
# Precisa de: pip install argon2-cffi cryptography
set -euo pipefail
cd "$(dirname "$0")/.."
saida=$(mktemp -d)/carteira.esclbr
( cd Kit && ESCALIBUR_ENVELOPE_SAIDA="$saida" swift test --filter "envelopeForReference" >/dev/null 2>&1 ) || { echo "swift test falhou ao lacrar"; exit 1; }
test -s "$saida" || { echo "o teste nao gerou o envelope"; exit 1; }
python3 tools/conferir-envelope.py "$saida"
rm -f "$saida"
