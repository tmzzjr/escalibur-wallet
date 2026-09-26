#!/bin/bash
# Grava e corta as respostas usadas pelos testes dos motores da Solana
# (Kit/Tests/EscaliburEnginesTests/Solana/). So leitura: nada e assinado nem
# transmitido. Uso, nesta pasta: ./gravar.sh
#
# Parte 1 grava na rede principal, pelo publicnode, as leituras de estado.
# Parte 2 copia, cortadas, respostas ja gravadas por outras suites (Rede e Redes).
set -euo pipefail
cd "$(dirname "$0")"

RPC=https://solana-rpc.publicnode.com
TOLY=86xCnPeV69n6t3DnyGvkKobf9FdN2H9oiVDdaMpo2MMY        # toly.sol, conta publica com saldo
EXCHANGE=5tzFkiKscXHK5ZXCGbXZxdw7gTjjD1mBwuoFbhUvuAi9    # carteira quente de exchange
NOVA=5tFUx2GVxip3kMhdwHG1yPGP2gYMzAikagio3GgyLAZZ        # sha256("escalibur: motores solana, destino nunca usado") como semente
USDC=EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v
TOLY_USDC=9SHQTA66Ekh7ZgMnKWsjxXk6DwXku8przs45E8bcEe38   # ATA de USDC do toly
EXCHANGE_USDC=FzbcyEZ9m8xjtergWgWDq7mfPoHEbboBF791B6cTpzbq # ATA de USDC da exchange
JUPITER=JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4
PARSED='{"encoding":"jsonParsed","commitment":"confirmed"}'
CONFIRMED='{"commitment":"confirmed"}'

rpc() {
    curl -s -m 20 -X POST "$RPC" -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" | jq . > "$3.json"
}

# Parte 1: estado
rpc getLatestBlockhash "[$CONFIRMED]" rpc-blockhash
rpc getEpochInfo "[$CONFIRMED]" rpc-epoca
rpc getBalance "[\"$TOLY\",$CONFIRMED]" rpc-saldo-toly
rpc getMinimumBalanceForRentExemption '[0]' rpc-rent-0
rpc getMinimumBalanceForRentExemption '[165]' rpc-rent-165
rpc getRecentPrioritizationFees "[[\"$TOLY\",\"$EXCHANGE\"]]" rpc-prioridade
for pair in "$TOLY:conta-toly" "$EXCHANGE:conta-exchange" "$NOVA:conta-nova" "$TOLY_USDC:conta-usdc-toly" \
    "$EXCHANGE_USDC:conta-usdc-exchange" "$USDC:conta-mint-usdc" "$JUPITER:conta-jupiter"; do
    rpc getAccountInfo "[\"${pair%%:*}\",$PARSED]" "${pair##*:}"
done
# Corte: as 20 ultimas taxas de prioridade bastam para o percentil.
jq '.result |= .[-20:]' rpc-prioridade.json > corte.tmp && mv corte.tmp rpc-prioridade.json

# Parte 2: copias cortadas
REDE=../../../EscaliburNetworkTests/FixturesSolana
REDES=../../../EscaliburChainsTests/Fixtures/solana-troca
# getTransaction (jsonParsed): sem logs, recompensas e custo, que o leitor nao le.
for name in tx-sol-transfer tx-usdc-transfer tx-dust tx-unlisted-token tx-failed tx-jupiter-swap; do
    jq 'del(.result.meta.logMessages, .result.meta.rewards, .result.meta.costUnits, .result.meta.computeUnitsConsumed, .result.meta.status)' \
        "$REDE/$name.json" > "$name.json"
done
jq . "$REDE/signature-statuses.json" > rpc-status.json
jq . "$REDE/send-preflight-error.json" > rpc-envio-recusado.json
# /swap/v2/build: sem o plano de rota em JSON, o blockhash sugerido e o conteudo das
# tabelas (a carteira le as tabelas da cadeia e so usa os enderecos delas daqui).
for name in build-sol-usdc build-usdc-sol; do
    jq 'del(.routePlan, .blockhashWithMetadata) | .addressesByLookupTableAddress |= map_values([])' "$REDES/$name.json" > "jupiter-$name.json"
done
# Tabelas lidas da cadeia: so as citadas pelas duas propostas acima.
jq --slurpfile a jupiter-build-sol-usdc.json --slurpfile b jupiter-build-usdc-sol.json \
    '.tables |= with_entries(select(.key as $k | ($a[0].addressesByLookupTableAddress + $b[0].addressesByLookupTableAddress) | has($k)))' \
    "$REDES/lookup-tables.json" > tabelas.json
