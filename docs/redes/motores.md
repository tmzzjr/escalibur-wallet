# Motores de envio, troca e histórico

Os motores (`Kit/Sources/EscaliburEngines`) juntam o leitor de cada rede
(EscaliburNetwork) e o planejador (EscaliburChains). Nenhum assina, nenhum abre cofre:
o `verificar.sh` recusa segredo, cofre, assinador e `SigningPlan(` fora das redes.
Todo valor que entra numa transação vem de dois provedores concordando.

| Família | Envio | Histórico | Troca | Ordem limite |
|---|---|---|---|---|
| Bitcoin, Litecoin, Dogecoin | Varredura com gap limit endereço a endereço; troco no próximo índice livre; poeira fica de fora | Sim | Não (pede ponte entre redes) | Não |
| EVM (7 redes) | Nativo e tokens da lista; a transação exata simulada com `eth_call` em dois provedores | Sim, menos BNB (sem indexador público sem chave) | Velora, KyberSwap, LI.FI e De¹, com divisão, recotação e `eth_simulateV1` em duas fontes; Ethereum pelos relays contra MEV. Não na Avalanche (sem duas fontes de simulação) | CoW, menos na Optimism |
| Solana | SOL e tokens da lista | Sim | Jupiter, montada localmente; o mínimo é o que a rota compilada garante | Não na v1 |
| XRP Ledger | Com tag; RequireDest lido; reserva de ativação | Sim | DEX nativa, livro lido em dois servidores no mesmo ledger | OfferCreate |
| Stellar | XLM e ativos da lista com memo; SEP-29 lido; cria conta | Sim | Path payment cotado no Horizon | ManageSellOffer |
| Tron | TRX e USDT; conta com controle dividido recusada | Sim, com o envenenamento de zero USDT marcado | Não na v1 | Não |
| TON | TON e USDT; bounce conforme a conta | Sim | Não na v1 | Não |

Taxa da Escalibur: zero em todas as trocas, com teste por provedor.

Limites conhecidos, ditos na tela:
- Os provedores sem chave têm limite de taxa. Uma carteira muito usada (dezenas de
  endereços UTXO) pode esbarrar nele; a varredura vale um minuto para o envio e para a
  Atividade, e moeda que não paga a própria taxa não é baixada.
- Os nós veem o IP do aparelho e os endereços consultados, até existir um relay próprio.
