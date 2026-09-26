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
