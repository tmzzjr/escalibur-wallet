# Sui: resumo (branch rede-sui)

Derivação: SLIP-10 Ed25519 em `m/44'/784'/i'/0'/0'`; endereço = BLAKE2b-256(0x00 || chave pública), "0x" + 64 hex. É o caminho da Slush (antiga Sui Wallet), do SDK oficial e da Trust Wallet: a mesma frase abre a mesma conta nas três. Vetores: `TEST_CASES` do SDK em TypeScript (frase para endereço) e as transações do wallet-core que a rede aceitou.

Endereço sem checksum, e com o formato da Aptos: `Address.guessChain` não chuta Sui para "0x" + 64 hex, e a tela de envio pede a confirmação da rede no primeiro envio (`needsNetworkConfirmation`, como na EVM). Endereços de 0x0 a 0xffff (pacotes e objetos do sistema) são recusados como destino.

Arquivos em `Kit/Sources/EscaliburChains/Sui/`: SuiAddress, SuiBCS, SuiTransactionData (BCS do `TransactionData` V1, só `SplitCoins`, `TransferObjects` e `MergeCoins` com entradas puras e objetos próprios; leitura estrita, recusa chamada Move e objeto compartilhado), SuiTransfer (`SignableTransaction`: assina BLAKE2b-256 de `[0, 0, 0] || bcs`; assinatura serializada `flag || sig || pk`), SuiPlanner.

API: `SuiPlanner.estimationTransaction`, `budget(for:price:)`, `maximumSendable`, `planSend`, `verifySimulation`. Rede: `SuiReader` (`accountState`, `estimateGas`, `simulate`, `broadcast`, `status`, `displayBalance`, `history`). Transmitir `SignedTransaction` como veio: `raw` é a transação seguida dos 97 bytes da assinatura; `encoded`, as duas partes em base64 com um ponto; o id é o digesto em base58.

Provedores (27/09/2026): o JSON-RPC foi desligado nos nós da Sui Foundation em 27/07/2026, com o código removido em meados de outubro de 2026. A carteira usa o gRPC (`sui.rpc.v2`) pelo gRPC-Web, um POST comum, em três operadores sem chave e com nó próprio: `fullnode.mainnet.sui.io` (Sui Foundation), `rpc-mainnet.suiscan.xyz` (Suiscan) e `sui-mainnet.nodeinfra.com` (NodeInfra). Os três têm versão de build e checkpoint mais antigo diferentes, e respondem ao `GetServiceInfo` com o `chain_id` da rede principal, conferido uma vez por provedor. Histórico pelo GraphQL da Sui Foundation (`graphql.mainnet.sui.io`), o único indexador sem chave com o histórico inteiro; na falha dele, `ListTransactions` de um nó gRPC, que guarda cerca de duas semanas.

Uma fonte só: o saldo da tela e o histórico (informativos). O gRPC-Web devolve erro sem dado só nos cabeçalhos, que o cliente HTTP não repassa: recusa na transmissão vira "não foi possível confirmar, confira a Atividade", nunca "nada saiu".

Fora da v1: saldo de endereço (SUI fora das moedas, que aparece no saldo mas não entra no máximo; exige retirada `FundsWithdrawal` e validade `ValidDuring`), outras moedas da Sui, troca, stake, zkLogin e multisig, conta com mais de 1.000 moedas de SUI (mais de 250 entram como gas só as maiores).
