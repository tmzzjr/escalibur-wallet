# Auditoria 3 (10/10/2026)

Auditoria de segurança completa pedida pelo dono ("make sure que ela tá unbreachable"), feita pelo agente de cybersecurity sobre a main f615343 com as mudanças em andamento. Nenhum achado crítico. "Inviolável" não existe para carteira nenhuma; esta é a lista de onde a proteção real era mais fraca que a documentação, e o que foi feito.

## Estado dos achados

| Item | Achado | Estado |
|---|---|---|
| A1 | O slot do PIN virava verificador offline depois de uma única chamada ao SE: a `K_dev` não pedia nada, e quem lesse o item testava os 10^6 PINs fora do aparelho. | Feito. Chave do SE com `.applicationPassword` derivada do PIN, conferida num iPhone 13 Pro Max; formato 1 migra no primeiro PIN certo (docs/seguranca.md §2). |
| A2 | Quem via o PIN desligava a voz só com o PIN; 20 envios de R$ 4.999 passavam um a um; trocar a moeda multiplicava o limite. | Feito. Mudar ou desligar a voz pede a frase; "esqueci a frase" espera 72 h no relógio monótono. Limite acumulado em 24 h, preso à moeda em que foi escolhido. |
| M1 | A tolerância automática somava o impacto informado pela API do agregador, que alargaria o próprio teto de perda. | Feito. O app não passa impacto da API para a tolerância; ele só aparece como aviso. |
| M2 | "Confirmada" num recebimento vinha de um indexador só. | Feito. O detalhe diz "segundo o indexador" até dois RPCs mostrarem o mesmo recibo com o valor chegando à conta. |
| B1 | Sem histórico da rede (Base, Arbitrum e Polygon com o indexador recusando o app), a detecção de endereço parecido não tinha com o que comparar. | Feito. Primeiro envio para endereço novo sem histórico pede os 6 caracteres do meio. |
| B2 | Reiniciar e acertar a hora para o boot antigo religava o Face ID sem PIN. | Feito. O registro guarda também o tempo desde o boot, que recomeça do zero ao reiniciar. |
| B3 | Receber numa carteira só de observação não avisava que o app não tem a chave. | Feito. Aviso fixo na tela. |
| B4 | Logos remotas decodificadas no processo que assina, conferidas só pelos bytes mágicos. | Feito. `SafeImage`: PNG ou JPEG pelo tipo do ImageIO, uma imagem, até 2048 px, reduzida a 256 px. |
| B5 | Sal da frase de voz vazio se o gerador falhasse. | Feito. Sem sal aleatório, nada é gravado. |
| B6 | Captura só da cena percebida só nas notificações. | Feito. `registerForTraitChanges` na tela sensível. |

## Conferido e sólido

`verificar.sh` inteiro; chaveiro todo em `WhenPasscodeSetThisDeviceOnly`; `K_bio` com `biometryCurrentSet` e hash de estado; contador gravado antes de avaliar, no relógio monótono; apagamento destrói as chaves do SE primeiro; `SecureBytes` com páginas de guarda e `memset_s`; assinador síncrono, com conferência da chave pública e da assinatura; `PlanIntentCheck` antes de revisar e de assinar; hosts travados, sem redirecionamento, corte em 4 MB; saldo e nonce por consenso; envelope limitado; capa no seletor de apps; teclados de terceiros bloqueados; área de transferência local com 120 s; código de demonstração só no build de teste, conferido no binário pelo CI; ações do CI fixadas por SHA e pip por hash.
