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

## Tabela de estado

Atualizada a cada correção. "motores" = ramo `seguranca-2`, em andamento, ainda fora do main.

| Achado | Estado | Onde |
|---|---|---|
| Seg A1 / Mot M6: `sequence` público | motores | `SigningPlan.sequence` interno, compositores nomeados por rede |
| Seg A2: verificador, fronteiras, hosts | feito | `tools/verificar.sh`, `Package.swift`, `AllowedHosts` no `HTTPClient` |
| Seg M1: ativo e valor amarrados ao plano | parte | planejadores preenchem `outgoing`/`incomingMinimum` (motores); a tela comparar vem depois do merge |
| Seg M2: desafio do endereço parecido | aberto | |
| Seg M3: transmissão ambígua | aberto | |
| Seg M4: PIN errado dentro de envio ou troca | feito | `AuthCoordinator.perform` volta ao teclado com o aviso da tela de bloqueio; teste de interface em `EnvelopeFlowTests` |
| Seg M5: memo opcional, `.noDestinationTag` | aberto | |
| Seg M6: preço limite sem conferência | feito | `TradeView.limitSanity`: abaixo de 2% do mercado pede confirmação presa ao preço digitado, abaixo de 50% bloqueia, sem preço de mercado pede confirmação |
| Seg B1: aceite de impacto alto | feito | vale só para o impacto aceito ou menor; par, valor, rede ou tolerância novos zeram |
| Seg B2: "nenhuma sai sozinha" | feito | texto diz que são transações separadas e que a autorização exata fica valendo se a troca falhar |
| Seg B3: voz, texto da ordem e relógio | feito | texto diz a ordem real (frase, depois Face ID ou PIN); pausa no relógio monotônico com boot, como o PIN |
| Seg B4: Face ID zerava o contador | feito | `RootKeyVault` |
| Seg B5: QR EIP-681 de token | feito | `PaymentLink` no Kit, destino é o `address=`; rede diferente da do envio é recusada; testes em `PaymentLinkTests` |
| Seg B6: palavras da importação em String | aceito | o campo UIKit guarda a palavra em digitação (uma por vez, limpo a cada palavra, sem correção, sem sugestão, sem ferramentas de escrita, área de transferência limpa depois de colar); a frase inteira só existe em `SecureBytes`. `String` do Swift não se apaga |
| Seg B7: memo "0123" igual a 123 | aberto | |
| Seg B8: CI sem hash no pip e sem compilar o app | aberto | |
| Mot A1 Stellar, A2 Solana, A3 ordens, M1 a M5 | motores | ver commits do ramo `seguranca-2` |
