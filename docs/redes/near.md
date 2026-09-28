# NEAR: resumo (branch rede-near)

## Conta: Ed25519 por SLIP-10, a conta implícita

Derivação: SLIP-10 Ed25519 em `m/44'/397'/i'`; a conta implícita é a chave pública de 32 bytes em hex minúsculo (64 caracteres). Assinatura Ed25519 pelo CryptoKit sobre o SHA-256 da transação.

Quem abre a mesma conta com a mesma frase (conferido em 28/09/2026):

| Carteira | Esquema | Mesma conta? |
|---|---|---|
| MyNearWallet e near-cli | near-seed-phrase, `KEY_DERIVATION_PATH = "m/44'/397'/0'"`, SLIP-10 (near-hd-key) | Sim. Vetor do near-seed-phrase: "shoot island..." dá `ed25519:r4yuiZE45mzeZAENDEF2pWeFBJkW8mQYGx3rU46zCqh` |
| Trust Wallet (wallet-core) | Ed25519, SLIP-10, `m/44'/397'/0'` (`registry.json`) | Sim. Vetor do wallet-core (`HDWallet.NearKey`): "owner erupt..." dá `b8d5df25...2fbf` |
| Meteor | Importa a frase da MyNearWallet | Esperado, pelo mesmo caminho; sem vetor publicado da própria Meteor |
| Ledger (app NEAR) | `44'/397'/0'/0'/1'` | Não: outro caminho, outra conta |

Os dois vetores foram conferidos também numa implementação independente em Python (SLIP-10 com `hmac` e o Ed25519 do `cryptography`), que deu a conta 1 e a frase "abandon ... about" usadas nos testes.

Receber mostra a conta implícita. Uma conta com nome do dono (`alice.near`) controlada pela mesma chave não aparece: a v1 não procura contas por chave pública.

## Destino

Aceita (regras do `near-account-id`): conta implícita, 64 hex, que pode ainda não existir (o primeiro envio a cria, e a rede cobra a mais por isso, `account_creation_charge`, 0,007 NEAR desde o protocolo 85), e conta com nome (2 a 64 caracteres, `a-z`, `0-9`, `-`, `_`, `.`), que só segue se existir, lida em dois provedores. Recusa: maiúscula (não existe conta NEAR com maiúscula; nada é corrigido em silêncio), conta implícita Ethereum (`0x` e 40 hex, a tela diz "rede Ethereum"), determinística (`0s`) e universal (`0u`), `system`, e texto que é endereço válido de outra rede com checksum (bech32 do Bitcoin e da Litecoin, Cardano), que passaria pela gramática como nome.

`Address.guessChain` reconhece os nomes sob `.near` e `.tg`; nome solto não diz a rede e fica sem palpite. A conta implícita também fica sem palpite: 64 hex sem prefixo é também um endereço da Sui ou da Aptos sem o `0x`, e o teste da Sui espera "malformado" nesse caso. Na tela da NEAR, esse texto é aceito como conta implícita; se ela ainda não existe, a tela do destino e a revisão dizem que o envio a cria e pedem para conferir que é uma conta NEAR: um endereço de outra rede recebe o valor, e ninguém tem a chave para movê-lo. Nenhum formato de outra rede da carteira é conta NEAR com checksum válido, então não há confirmação de rede no envio.

## Transação

`Transaction` v0 em Borsh: `signer_id`, `PublicKey` (0 e 32 bytes), `nonce` (u64, o da chave de acesso mais um), `receiver_id`, `block_hash` (32 bytes), uma ação `Transfer` (3 e o depósito em u128). `SignedTransaction` = transação, 0 e a assinatura de 64 bytes. Id = SHA-256 da transação em base58; a assinatura não entra no id, então reassinar não muda o id, e o nonce impede execução dupla.

Vetores: o do near-api-js e do wallet-core (Borsh, a `SignedTransaction` e o hash `eea6e680...`), e três transferências reais da rede principal (duas para conta com nome, uma para conta implícita que ela criou), remontadas byte a byte, com o id e a assinatura original conferidos sobre o hash calculado aqui. A visão JSON do nó não mostra o `block_hash`; `Fixtures/near/extrair-reais.py` acha o bloco cujo hash monta a transação com o id certo.

Arquivos: `Kit/Sources/EscaliburChains/NEAR/` (NEARAccount, NEARTransaction, NEARPlanner), `EscaliburNetwork/NEAR/NEARReader`, `EscaliburEngines/NEAR/` e `Families/NEAR.swift`.

## Leitura

Quatro operadores de JSON-RPC sem chave, com nó próprio (a chave de nó do `status` é diferente em cada um): FastNEAR (`free.rpc.fastnear.com`), dRPC (`near.drpc.org`), Shitzu (`rpc.shitzuapes.xyz`) e Intear (`rpc.intea.rs`, que sem chave espera 1 s por resposta). O RPC oficial (`rpc.mainnet.near.org`) foi descontinuado e respondeu em 3 a 26 s; o da Tatum aceita 5 chamadas por minuto sem chave; Lava, BlockPI, Ankr e 1RPC pedem chave, caíram ou não têm os métodos.

Dois concordando, no mesmo bloco: o bloco de referência (o final mais baixo de dois, com o hash igual em dois, que vai na transação), a conta do dono (`view_account`: saldo, stake, armazenamento, contrato), a chave de acesso dele (`view_access_key`: nonce e permissão; só acesso total assina), a conta de destino, o preço do gas (`gas_price`) e as regras do protocolo que entram na conta (`EXPERIMENTAL_protocol_config`: `chain_id`, custo de armazenamento por byte, taxas de recibo, transferência, criação de conta e chave, `min_gas_purchase_price` e `account_creation_charge`). `chain_id` e gênese são conferidos uma vez por provedor. Chave que não está na conta volta como resultado com `error`, não como erro do RPC, e vale "não está".

Uma fonte só, com o motivo: o saldo da tela (o plano relê em dois) e o histórico (a API de transações da FastNEAR, `tx.main.fastnear.com`, com a conta no corpo do POST; o RPC não lista transações por conta, e o NearBlocks manda valores em ponto flutuante).

## Envio

Só NEAR, da conta implícita. A taxa segue a conta do nearcore (`calculate_tx_cost`): o gas da conversão ao preço do bloco com 20% de folga, mais o gas do recibo comprado a `max(preço, min_gas_purchase_price)`; o que não for usado volta. Para conta implícita, a taxa de gas inclui criar a conta e a chave sempre (é pelo formato do destino), e a cobrança de conta nova entra quando ela ainda não existe. Conferido contra transferências reais: 0,0000446 NEAR para conta com nome e 0,0071 NEAR para conta implícita nova. O saldo que sai respeita o armazenamento: conta de até 770 bytes (a de uma chave só) não prende nada (NEP-448); acima disso, cada byte prende 10^19 yocto, pago primeiro pelo stake. Teto da reserva de taxa: 0,05 NEAR.

Recusa: destino inválido ou de outra rede, a própria conta, conta com nome que não existe, valor zero ou acima de u128, chave ausente ou só de contrato, nonce que passaria do limite do bloco (chave criada no próprio bloco de referência), outra rede, taxa acima do teto, saldo abaixo de valor mais reserva. A revisão mostra destino, valor, taxa esperada, reserva, rede, validade (86.400 blocos, cerca de 14 horas) e, para conta implícita nova, que o envio a cria; destino com contrato ganha aviso.

Transmissão por `send_tx` esperando a inclusão num bloco, nos mesmos bytes, em dois provedores: o nó confere assinatura, nonce e saldo antes de responder e diz por que recusou. Acompanhamento por `tx` em dois provedores, final só com os dois dizendo `FINAL`; sem registro (o app foi reaberto) fica pendente, e sem a transação nos dois depois da validade, venceu.

Fora da v1: tokens NEP-141, stake, troca, contas com nome do próprio dono, a conta da Ledger, contas implícitas Ethereum, determinísticas e universais como destino, e o acompanhamento de uma transação transmitida antes de o app ser reaberto.
