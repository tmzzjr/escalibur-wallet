# Motores de envio, troca e histórico

Os motores (`Kit/Sources/EscaliburEngines`) juntam o leitor de cada rede
(EscaliburNetwork) e o planejador (EscaliburChains). Nenhum assina, nenhum abre cofre:
o `verificar.sh` recusa segredo, cofre, assinador e `SigningPlan(` fora das redes. E
nenhum motor escreve a revisão de um plano: juntar planos (a divisão EVM, a linha de
confiança antes da oferta no XRP Ledger) é só dos compositores de EscaliburChains
(`TradePlanner.combineSplit`, `XRPLPlanner.combineTrustlineAndOffer`), que derivam tipo,
título e linhas das partes e recusam envio dentro de troca ou ordem.

Todo plano diz o que sai (`review.outgoing`) e, na troca e na ordem, o mínimo que entra
(`review.incomingMinimum`) e quem recebe (`review.beneficiary`), tirados dos valores
gravados na transação, com o `Asset.id` da lista curada. O app confere contra o pedido.

| Família | Envio | Histórico | Troca | Ordem limite |
|---|---|---|---|---|
| Bitcoin, Litecoin, Dogecoin | Varredura com gap limit endereço a endereço; troco no próximo índice livre, conferido em dois provedores; poeira fica de fora, e a revisão conta o que ficou | Sim | Não (pede ponte entre redes) | Não |
| EVM (7 redes) | Nativo e tokens da lista; a transação exata simulada com `eth_call` em dois provedores | Sim, menos BNB (sem indexador público sem chave) | Velora, KyberSwap, LI.FI e De¹, com divisão, recotação e `eth_simulateV1` em duas fontes; Ethereum pelos relays contra MEV. Não na Avalanche (sem duas fontes de simulação) | CoW, menos na Optimism |
| Solana | SOL e tokens da lista | Sim | Jupiter, montada localmente; o mínimo é o que a rota compilada garante, e a cotação é conferida contra o preço de referência | Não na v1 |
| XRP Ledger | Com tag; RequireDest lido; reserva de ativação | Sim | **Desligada**: a DEX nativa só troca com token da lista curada, e a lista ainda não tem token do XRP Ledger. O código (livro em dois servidores no mesmo ledger, OfferCreate tudo ou nada) é testado com um token de teste | Desligada pelo mesmo motivo |
| Stellar | XLM e ativos da lista com memo; SEP-29 lido; cria conta | Sim | Path payment cotado nas duas Horizons, rota só por XLM e ativos da lista | ManageSellOffer, sem prazo |
| Tron | TRX e USDT; conta com controle dividido recusada | Sim, com o envenenamento de zero USDT marcado | Não na v1 | Não |
| TON | TON e USDT; bounce conforme a conta | Sim | Não na v1 | Não |

Taxa da Escalibur: zero em todas as trocas, com teste por provedor.

## O que cada leitura exige

- **Nonce EVM**: `eth_getTransactionCount(pending)` em dois provedores. Sem a fila local
  do app (`PendingNonceQueue` no `SendRequest`, no `TradeRequest` e no
  `LimitOrderRequest`), as duas fontes têm de concordar; com ela, cada fonte tem de estar
  entre o primeiro nonce ainda em trânsito e o próximo da fila, e vale o da fila. As duas
  acima da fila (outro aparelho com a mesma frase) valem. Fila à frente do que ela mesma
  explica é recusada com frase própria.
- **Taxa EVM**: baseFee e gorjetas pela mediana de dois provedores (com dois, a média);
  gas pela menor de duas estimativas ou simulações, mais 20%; tetos por rede compilados
  (`EVMFeeProfile`; na BNB, 1 gwei). O envio de token avisa taxa acima de 3% do valor,
  pelo preço de mercado; sem preço, sem aviso.
- **Troca EVM**: o mínimo ancora fora do provedor. Com preço de referência do mercado
  (CoinGecko, ou a paridade entre dois stablecoins da lista), a cotação mais de 5% pior
  bloqueia, e acima de 2% a revisão diz quanto. Sem referência, a troca exige duas
  cotações válidas e só escolhe a que garante o mínimo calculado da maior estimativa
  entre elas; no plano, a recotação tem de garantir pelo menos o mínimo que a tela
  mostrou.
- **Troca na Solana**: a Jupiter propõe a rota; o preço de referência vem do oráculo do
  app, com os mesmos degraus (5% bloqueia, 2% avisa). Par que não é de dois stablecoins
  da lista, sem referência, é recusado. A simulação lê também as contas de token do dono
  nos mints da lista, e nenhuma pode perder saldo. Destino, conta de token e mint vêm de
  dois RPCs concordando.
- **Troca na Stellar**: as duas Horizons cotam, e as duas têm de responder; o `destMin`
  sai da maior cotação. A rota só passa por XLM e ativos da lista, conferida no leitor e
  no `StellarPlanner`. Preço de referência com os mesmos degraus, quando existe; sem ele,
  a troca segue com as duas cotações.
- **Taxa UTXO**: teto compilado por rede (500 sat/vB, 200 lit/vB, 10 DOGE/kB); duas
  fontes que não divergem mais de 3x (perto do piso da rede a comparação parte de 5x o
  piso); cada nível é o menor de duas fontes ou a mediana de três; aviso acima de 1% do
  valor. As moedas que a leitura deixou de fora (poeira, além do teto de leitura, sem
  prova da transação anterior) aparecem na revisão com quantidade e motivo, e "enviar
  tudo" só é dito quando o que fica para trás é poeira.
- **XRP Ledger**: Sequence, saldo e flags em dois servidores no mesmo ledger validado; o
  `LastLedgerSequence` parte desse ledger, e o `server_info` a mais de 10 ledgers dele é
  recusado.
- **Vencimento**: na Solana, "venceu, pode enviar de novo" só com a altura finalizada de
  dois provedores 150 blocos além do `lastValidBlockHeight` e o histórico dos dois sem a
  transação. Na Tron, pela hora do último bloco solidificado em dois provedores (a
  menor), nunca pelo relógio do aparelho; o plano é recusado com o relógio a mais de 2
  minutos do bloco da rede.

Leituras que ainda vêm de uma fonte só, sob teto ou faixa compilados: a taxa e a reserva
da Stellar e do XRP Ledger (`server_info`, `fee_stats`); o blockhash, o saldo e o preço de
prioridade da Solana; o bloco de referência, os recursos, os parâmetros, "destino é
contrato" e a energia estimada da Tron; as leituras da TON além do `seqno` (auditoria 2,
B3, ainda aberta para a TON).

## Ordens limite abertas e cancelamento

O `TradeEngine` lista as ordens abertas (`openOrders(account:)`) e monta o cancelamento
(`planCancel(_:walletID:account:via:nonceQueue:)`), que vai para o `submit` de sempre.
Onde não há ordem limite, as duas lançam `SendEngineError.unavailable`.

| Rede | Lista | Cancela | Prazo |
|---|---|---|---|
| EVM (CoW) | API da CoW (única fonte do livro), UID conferido, só abertas, não invalidadas e no prazo | Pela CoW, grátis e sem garantia (`.offchain`), ou `invalidateOrder` na cadeia, garantido, com taxa (`.onchain`) | De 1 hora a 30 dias, ou "até cancelar": 364 dias, perto do máximo de um ano que o livro da CoW aceita, com a data na revisão |
| XRP Ledger | `account_offers` em dois servidores no mesmo ledger | `OfferCancel`, depois de conferir que a oferta ainda está aberta | Opcional; sem prazo, a oferta fica até executar ou ser cancelada |
| Stellar | `/accounts/{G}/offers` nas duas Horizons, juntas, com quantas viram cada oferta | `ManageSellOffer` com quantidade zero, com os ativos lidos da rede | Não existe: a oferta fica até executar ou ser cancelada |

Limites conhecidos, ditos na tela:
- Os provedores sem chave têm limite de taxa. Uma carteira muito usada (dezenas de
  endereços UTXO) pode esbarrar nele; a varredura vale um minuto para o envio e para a
  Atividade, e moeda que não paga a própria taxa não é baixada.
- Os nós veem o IP do aparelho e os endereços consultados, até existir um relay próprio.
