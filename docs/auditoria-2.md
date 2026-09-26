# Auditoria de segurança 2 (agente de segurança, 2026-09-26, main em 84d9c35)

Feita com os motores de todas as redes ligados. Nenhum achado crítico explorável de fora sem código novo; dois altos derrubam promessas centrais e o CI não pegava.

## Achados

Alta
- A1: `SigningPlan.sequence` público com título, linhas e tipo livres: um motor poderia embrulhar uma transferência como "troca" com revisão inventada, e a troca só conferia carteira, rede e tipo.
- A2: `verificar.sh` com `find | xargs` quebra em caminho com espaço (a regra fica verde); EscaliburEngines dependia de EscaliburKeys e enxergava chaveiro, SE e cofre; faltavam regras de `Security`/`LAContext` na rede e nos motores; nenhum controle de host em tempo de execução.

Média
- M1: envio e troca não amarravam ativo e valor ao plano; voz e "cerca de" usavam a intenção.
- M2: o desafio do endereço parecido pedia justamente as pontas que o atacante copia; conhecidos só deste app.
- M3: transmissão ambígua virava "tente de novo" e um segundo plano podia pagar duas vezes.
- M4: PIN errado dentro de envio ou troca aparecia como falha de rede, sem "faltam N".
- M5: sem campo de memo, tag ou comentário quando a rede não exige; `.noDestinationTag` nunca emitido.
- M6: ordem limite aceitava qualquer preço; no XRP Ledger e na Stellar ela cruza o livro na hora.

Baixa
- B1 aceite de impacto alto nunca volta a falso; B2 texto "nenhuma sai sozinha" falso; B3 voz: texto da ordem e pausa no relógio de parede; B4 Face ID zera o contador do PIN; B5 QR EIP-681 de token põe o contrato como destino; B6 palavras da importação passam por String; B7 memo texto "0123" igual a id 123; B8 CI sem hash no pip e sem compilar o app.

## Estado

Ver a tabela ao fim deste arquivo, atualizada a cada correção.

## Revisão dos motores (agente de blockchain, mesmo commit)

Alto
- A1 Stellar: rota e mínimo da troca de um Horizon só, path com qualquer ativo intermediário.
- A2 Solana: a Jupiter é a única fonte de rota, preço, impacto e mínimo; simulação olha só três contas.
- A3 Ordens limite: a revisão promete cancelar e o app não tem tela de ordens abertas; na Stellar a oferta nunca vence.

Médio
- M1 EVM sem fila local de nonce (max de duas fontes com folga de 4).
- M2 UTXO: teto de taxa sai dos provedores que ele limita.
- M3 UTXO: "enviar tudo" deixa moedas para trás sem dizer.
- M4 "Venceu, pode reenviar" decidido por uma fonte (Solana) ou pelo relógio do aparelho (Tron).
- M5 EVM: mínimo ancorado no número do próprio provedor; oráculo opcional.
- M6 `SigningPlan.sequence` deixa o motor escrever a revisão (mesmo achado A1 da outra revisão).

Baixo
- B1 tetos de taxa EVM de uma fonte, BNB alto; B2 LastLedgerSequence de um servidor; B3 leituras de uma fonte na Solana e TON; B4 regra de uma ordem CoW por token só pela API; B5 troca EVM sem prazo na cadeia; B6 índice de troco de um provedor; B7 documentação dizendo mais do que o código faz.

## Estado da revisão dos motores (Kit, branch seguranca-2)

| Achado | Estado | Onde |
|---|---|---|
| A1 Stellar | Corrigido: cotação nas duas Horizons e `destMin` da maior; rota só por XLM e ativos da lista; preço de referência (5% bloqueia, 2% avisa) | `StellarTradeEngine`, `StellarReader.quoteStrictSendOnBoth`, `StellarPlanner.planSwap` |
| A2 Solana | Corrigido: preço de referência fora da Jupiter, par não estável sem referência recusado; simulação lê as contas de token do dono nos mints da lista | `SolanaSwapPlanner`, `SolanaTradeEngine`, `SolanaNetworkReader.swapAccounts` |
| A3 Ordens limite | Corrigido no Kit: `openOrders` e `planCancel` no `TradeEngine` (CoW, XRP Ledger, Stellar); "até cancelar" com `validFor: nil`. A tela de ordens abertas é do app | `Trade.swift` |
| M1 nonce EVM | Corrigido no Kit: `PendingNonceQueue` no pedido; sem a fila, fontes iguais. O app guarda a fila | `EVMFeeCalculator.nonce` |
| M2 teto UTXO | Corrigido: teto compilado, duas fontes no máximo 3x distantes, o menor de duas, aviso acima de 1% | `UTXORules`, `UTXOFeeConsensus` |
| M3 moedas deixadas | Corrigido: `skipped` na revisão, "enviar tudo" só com poeira de fora | `UTXOPlanner` |
| M4 vencimento | Corrigido: Solana com duas fontes e altura finalizada com folga; Tron pelo bloco solidificado em dois provedores e relógio conferido no plano | `SolanaTransfers`, `TronReader.status`, `TronPlanner` |
| M5 âncora EVM | Corrigido: referência obrigatória ou duas cotações e a maior estimativa | `TradeValidator.anchored` |
| M6 `sequence` | Corrigido: interno; compositores nomeados | `Signing.swift`, `TradePlanner.combineSplit`, `XRPLPlanner.combineTrustlineAndOffer` |
| B1 | Corrigido: mediana de duas fontes, gas pela menor, BNB 1 gwei, aviso de taxa no envio de token | `EVMReader`, `TradeStateReader`, `EVMFeeProfile`, `EVMSendEngine` |
| B2 | Corrigido: LastLedgerSequence do ledger pinado | `XRPLPlanner.common` |
| B3 | Corrigido na Solana (destino, conta de token e mint em dois RPCs); a TON segue com leituras de uma fonte além do `seqno` | `SolanaNetworkReader` |
| B4, B5 | Fora desta rodada | |
| B6 | Corrigido: troco conferido em dois provedores | `UTXOReader.isUnused`, `UTXOSendEngine` |
| B7 | Corrigido: `docs/redes/motores.md` e `docs/blockchain.md` dizem o que o código faz; a DEX do XRP Ledger está desligada (a lista curada não tem token do XRP Ledger) | |
