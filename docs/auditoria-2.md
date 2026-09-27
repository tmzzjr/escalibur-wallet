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

## Estado da revisão de segurança

Atualizada a cada correção.

| Achado | Estado | Onde |
|---|---|---|
| Seg A1 / Mot M6: `sequence` público | feito | `SigningPlan.sequence` interno, compositores nomeados por rede |
| Seg A2: verificador, fronteiras, hosts | feito | `tools/verificar.sh`, `Package.swift`, `AllowedHosts` no `HTTPClient` |
| Seg M1: ativo e valor amarrados ao plano | feito | planejadores preenchem `outgoing`, `incomingMinimum` e `beneficiary` a partir da transação; `PlanIntentCheck` confere no envio e na troca antes de revisar e antes de assinar; voz e "cerca de" usam o valor do plano; os testes dos motores conferem que o plano real passa |
| Seg M2: desafio do endereço parecido | feito | o desafio pede os 6 caracteres do meio onde o destino difere do conhecido (`AddressPoisoning.differingSegment`), com os dois endereços lado a lado e o trecho marcado; conhecidos incluem para quem a carteira já pagou no histórico da rede; teste de interface em `SendLookalikeTests` |
| Seg M3: transmissão ambígua | feito | erro na transmissão depois de assinar vira "Não deu para confirmar": a tela só oferece transmitir de novo os mesmos bytes (mesmo id, não paga duas vezes), acompanha o id conhecido e manda conferir na Atividade; nonce EVM e índice de troco UTXO ficam anotados antes da transmissão |
| Seg M4: PIN errado dentro de envio ou troca | feito | `AuthCoordinator.perform` volta ao teclado com o aviso da tela de bloqueio; teste de interface em `EnvelopeFlowTests` |
| Seg M5: memo opcional, `.noDestinationTag` | feito | campo opcional de tag, memo ou comentário no destino quando a rede tem e o destino não exige; a revisão avisa `.noDestinationTag` no primeiro envio sem tag numa rede que tem |
| Seg M6: preço limite sem conferência | feito | `TradeView.limitSanity`: abaixo de 2% do mercado pede confirmação presa ao preço digitado, abaixo de 50% bloqueia, sem preço de mercado pede confirmação |
| Seg B1: aceite de impacto alto | feito | vale só para o impacto aceito ou menor; par, valor, rede ou tolerância novos zeram |
| Seg B2: "nenhuma sai sozinha" | feito | texto diz que são transações separadas e que a autorização exata fica valendo se a troca falhar |
| Seg B3: voz, texto da ordem e relógio | feito | texto diz a ordem real (frase, depois Face ID ou PIN); pausa no relógio monotônico com boot, como o PIN |
| Seg B4: Face ID zerava o contador | feito | `RootKeyVault` |
| Seg B5: QR EIP-681 de token | feito | `PaymentLink` no Kit, destino é o `address=`; rede diferente da do envio é recusada; testes em `PaymentLinkTests` |
| Seg B6: palavras da importação em String | aceito | o campo UIKit guarda a palavra em digitação (uma por vez, limpo a cada palavra, sem correção, sem sugestão, sem ferramentas de escrita, área de transferência limpa depois de colar); a frase inteira só existe em `SecureBytes`. `String` do Swift não se apaga |
| Seg B7: memo "0123" igual a 123 | feito | `PlanIntentCheck.sameTag`: número só na tag do XRP Ledger; memo da Stellar, comentário da TON e memo da Tron comparados exatamente; testes |
| Seg B8: CI sem hash no pip e sem compilar o app | feito | `tools/requisitos-ci.txt` com versão e hash de cada pacote (dependências incluídas), instalado com `--require-hashes`; o CI compila o app em Release para o simulador e recusa o binário que carregar algo do modo demo |

## Estado da revisão dos motores (Kit, branch seguranca-2)

| Achado | Estado | Onde |
|---|---|---|
| A1 Stellar | Corrigido: cotação nas duas Horizons e `destMin` da maior; rota só por XLM e ativos da lista; preço de referência (5% bloqueia, 2% avisa) | `StellarTradeEngine`, `StellarReader.quoteStrictSendOnBoth`, `StellarPlanner.planSwap` |
| A2 Solana | Corrigido: preço de referência fora da Jupiter, par não estável sem referência recusado; simulação lê as contas de token do dono nos mints da lista | `SolanaSwapPlanner`, `SolanaTradeEngine`, `SolanaNetworkReader.swapAccounts` |
| A3 Ordens limite | Corrigido no Kit: `openOrders` e `planCancel` no `TradeEngine` (CoW, XRP Ledger, Stellar); "até cancelar" com `validFor: nil`. A tela de ordens abertas é do app | `Trade.swift` |
| M1 nonce EVM | Corrigido: `PendingNonceQueue` no pedido; sem a fila, fontes iguais. O app guarda a fila por carteira, rede e conta (`NonceQueue`), poda antes de cada plano (confirmada, recusada ou pendente há mais de 30 minutos) e a esquece quando o motor diz que ela está à frente da rede | `EVMFeeCalculator.nonce`, `NonceQueue` |
| M2 teto UTXO | Corrigido: teto compilado, duas fontes no máximo 3x distantes, o menor de duas, aviso acima de 1% | `UTXORules`, `UTXOFeeConsensus` |
| M3 moedas deixadas | Corrigido: `skipped` na revisão, "enviar tudo" só com poeira de fora | `UTXOPlanner` |
| M4 vencimento | Corrigido: Solana com duas fontes e altura finalizada com folga; Tron pelo bloco solidificado em dois provedores e relógio conferido no plano | `SolanaTransfers`, `TronReader.status`, `TronPlanner` |
| M5 âncora EVM | Corrigido: referência obrigatória ou duas cotações e a maior estimativa | `TradeValidator.anchored` |
| M6 `sequence` | Corrigido: interno; compositores nomeados | `Signing.swift`, `TradePlanner.combineSplit`, `XRPLPlanner.combineTrustlineAndOffer` |
| B1 | Corrigido: mediana de duas fontes, gas pela menor, BNB 1 gwei, aviso de taxa no envio de token | `EVMReader`, `TradeStateReader`, `EVMFeeProfile`, `EVMSendEngine` |
| B2 | Corrigido: LastLedgerSequence do ledger pinado | `XRPLPlanner.common` |
| B3 | Corrigido. Solana: destino, conta de token e mint em dois RPCs. TON: `seqno`, status, saldo e código das contas do dono e do destino, e saldo, dono e mestre da carteira jetton de USDT na toncenter e na tonapi, concordando (saldo, o menor; uma releitura; sem contingência de uma fonte). Ficam de uma fonte na TON, com o motivo no código: a taxa estimada (teto compilado, fora da mensagem), o `get_wallet_address` (só confere o endereço calculado localmente, que é o usado) e o histórico | `SolanaNetworkReader`, `TONReader.agreedAccount`, `TONReader.jettonBalance` |
| B4, B5 | Fora desta rodada | |
| B6 | Corrigido: troco conferido em dois provedores | `UTXOReader.isUnused`, `UTXOSendEngine` |
| B7 | Corrigido: `docs/redes/motores.md` e `docs/blockchain.md` dizem o que o código faz; a DEX do XRP Ledger está desligada (a lista curada não tem token do XRP Ledger) | |
