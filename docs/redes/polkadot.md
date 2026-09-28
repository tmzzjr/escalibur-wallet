# Polkadot: resumo (branch rede-polkadot)

## Conta: Ed25519 por SLIP-10, a da Trust Wallet

Derivação: SLIP-10 Ed25519 em `m/44'/354'/i'/0'/0'`, a chave de 32 bytes vira a conta; endereço SS58 com prefixo 0 (começa com 1), checksum = 2 primeiros bytes do BLAKE2b-512 de `"SS58PRE" || prefixo || conta`. Assinatura Ed25519 pelo CryptoKit, como Solana, Stellar, TON e Sui.

Quem abre a mesma conta com a mesma frase, e quem não abre (conferido em 28/09/2026):

| Carteira | Esquema | Mesma conta? |
|---|---|---|
| Trust Wallet (e o que usa o wallet-core) | Ed25519, SLIP-10, `m/44'/354'/0'/0'/0'` (`registry.json`) | Sim. Vetor do wallet-core: "shoot island..." dá `13nN6BGA...SsFk` |
| Ledger (app Polkadot da Zondax) | Ed25519 no mesmo caminho, mas por BIP32-Ed25519 (`os_derive_bip32_with_seed_no_throw(HDW_NORMAL, CX_CURVE_Ed25519, ...)`, `app/src/crypto.c`) | Não. A mesma frase dá `14Gr3Rp3...WnZh9` (o `hdLedger` do polkadot-js) |
| Polkadot.js, Nova, Talisman, SubWallet | sr25519 (Schnorrkel) a partir da entropia BIP-39 | Não. A mesma frase dá `16FUHt4K...24gH3` |

Por que não sr25519: exige Ristretto255, Merlin e Schnorrkel, e não há implementação vendorizada, auditada e com vetores publicados no repositório. Escrever essa criptografia à mão fica fora da regra da casa. A Ledger dá para suportar depois sem cripto nova: a derivação BIP32-Ed25519 e a assinatura com chave estendida já existem no núcleo para a Cardano (`Ed25519Extended`); faltaria a chave mestra do `hdLedger` e a descoberta na importação.

## Onde o DOT mora: Polkadot Asset Hub

Desde a migração de 4/11/2025 (Asset Hub Migration), saldos, contas e transferências de DOT ficam na Polkadot Asset Hub. Lido ao vivo em 28/09/2026: emissão de cerca de 1,7 bilhão de DOT na Asset Hub contra 238 mil na relay; uma conta ativa com nonce 131.797 na Asset Hub e zero na relay. A carteira lê e envia só na Asset Hub (genese `68d56f15...de2f`, `specName` `statemint`), como a Trust Wallet (explorador `assethub-polkadot.subscan.io` no `registry.json`) e a Nova. A nota de recebimento diz para escolher a Asset Hub na exchange: DOT enviado pela relay chain antiga fica na conta da relay e não aparece aqui.

Constantes compiladas (`PolkadotRuntime`): genese, `transaction_version` 15, `Balances` 10 e `transfer_keep_alive` 3, depósito existencial 0,01 DOT, era de 256 blocos (uns 9 minutos com blocos de 2,2 s), teto de taxa de 0,1 DOT (uma transferência custa cerca de 0,0009 DOT).

## Transação

Extrinsic v4 assinada: `MultiAddress::Id`, `MultiSignature::Ed25519`, era mortal, nonce, gorjeta zero, `ChargeAssetTxPayment` com `asset_id` None (taxa em DOT) e `CheckMetadataHash` com modo 0; no que se assina, `spec_version`, `transaction_version`, genese, hash do bloco da era e `None` do hash de metadados. Layout tirado dos metadados v16 (`transactionExtensionsByVersion[0]`). Id = BLAKE2b-256 da extrinsic inteira, em hex com 0x.

Vetores: duas transferências reais da rede principal no runtime de hoje (a extrinsic sai byte a byte igual, e a assinatura original verifica sobre o payload montado aqui); três montadas pelo polkadot-js com os metadados ao vivo; a transferência transmitida na Kusama Asset Hub do wallet-core; SS58 da conta //Alice e do wallet-core; SCALE da tabela oficial.

Arquivos: `Kit/Sources/EscaliburChains/Polkadot/` (PolkadotAddress, PolkadotSCALE, PolkadotRuntime, PolkadotTransfer, PolkadotPlanner), `EscaliburNetwork/Polkadot/PolkadotReader`, `EscaliburEngines/Polkadot/` e `Families/Polkadot.swift`.

## Leitura

Quatro operadores de JSON-RPC sem chave, com nó próprio: Parity (`polkadot-asset-hub-rpc.polkadot.io`), LuckyFriday, Dwellir e OnFinality. Dois concordando, no mesmo bloco: o bloco de referência (o finalizado mais baixo de dois, com o hash igual em dois), o runtime, as contas do dono e do destino (`System.Account`) e a taxa da transação exata (`TransactionPaymentApi_query_info`). A genese é conferida uma vez por provedor. A avaliação da taxa também prova que o nó decodifica a transação como a carteira monta: extensão nova no runtime faz os nós recusarem, e nada é montado. `transaction_version` diferente de 15 também para o envio até o app ser conferido de novo.

Uma fonte só, com o motivo: o saldo da tela (o plano relê em dois), o resultado da transação no acompanhamento (o sidecar público da Parity, depois de um nó achar a transação num bloco finalizado; o JSON-RPC só diria decodificando os eventos com os metadados inteiros) e o histórico (indexador SubQuery da Nova, `subquery-history-polkadot-ah-prod.novasama-tech.org`, o único sem chave: o Subscan passou a exigir chave).

## Envio

Só DOT, por `transfer_keep_alive`. Recusa: destino SS58 de outro prefixo (Kusama, parachain, formato genérico 5...), a própria conta, valor zero, valor mais taxa com 20% de folga acima do que a conta pode tirar (livre menos o maior entre o congelado além do reservado e o depósito existencial), destino que ficaria abaixo do depósito existencial, runtime de outra rede ou com outra `transaction_version`, taxa zero ou acima do teto, caminho não endurecido. A revisão mostra destino, valor, taxa, a rede, o mínimo que fica na conta e a validade; conta nova no destino ganha o aviso de ativação.

Fora da v1: sr25519 e a conta da Ledger (acima), relay chain, staking, tokens da Asset Hub (USDT, USDC), parachains, XCM, troca, gorjeta, e o acompanhamento de uma transação transmitida antes de o app ser reaberto (fica pendente até aparecer na Atividade).
