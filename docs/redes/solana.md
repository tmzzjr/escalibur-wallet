# Solana: resumo (branch rede/solana, 656ce81)

Arquivos em `Kit/Sources/EscaliburChains/Solana/`: Edwards25519 (checagem de ponto, semântica do dalek), SolanaPublicKey (PDA, ATA), SolanaShortVec, SolanaMessage (legado e v0), SolanaTransaction (+ SolanaWireTransaction só leitura), SolanaPrograms, SolanaVerifier, SolanaPlanner.

API: `SolanaPlanner.planSendSOL / planSendToken / sendSOLFee`. `SolanaMessageVerifier.verify(_:policy:lookupTables:)` (política exige a lista de programas esperados). `SolanaAssociatedToken.address(owner:mint:tokenProgram:allowOwnerOffCurve:)`. Transmitir o base64 de `SignedTransaction.encoded`, nunca reassinar.

Rede preenche: `SolanaNetworkState` (blockhash, lastValidBlockHeight, altura, fetchedAt, saldo, rentExemptMinimum de getMinimumBalanceForRentExemption(0), preço de prioridade sugerido, simulatedComputeUnits?); `SolanaDestinationAccount` (nonexistent/system/tokenAccount/programOwned); `SolanaDestinationTokenAccount` (missing/existing); `SolanaTokenState` (mint, programa, casas, símbolo, curado?, extensões, conta de origem, rent da conta de token); `SolanaOwner` (caminho, chave); `SolanaAddressLookupTable` (2 RPCs).

Regras extras: conta de token como destino usada direto após conferir o mint; destino fora da curva recusado em token sem confirmação; AdvanceNonceAccount recusado em qualquer posição; ATA de terceiro recusado; prioridade ≤ 10 lamports/CU e ≤ 0,002 SOL.
Achados: USDC correto é EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v (o da lista estava errado; corrigido e agora conferido ao vivo). PYUSD bloqueado por permanentDelegate.
Fora: tx v1 (0x81), multiassinatura, rota da Jupiter (camada de troca), TransferCheckedWithFee, nonce durável, varredura de caminhos, NFT.

# Solana: rede e troca (branch solana-rede)

Arquivos: `Kit/Sources/EscaliburNetwork/Solana/` (SolanaRPC, SolanaAccountParser, SolanaNetworkReader, SolanaBroadcaster, SolanaHistory, JupiterClient, SolanaPlanningService) e `Kit/Sources/EscaliburChains/SolanaTrade/` (JupiterRoute, SolanaSwapProposal, SolanaSwapPlanner, SolanaSimulation), puro.

API que o app chama:
- `SolanaPlanningService.shared`: `planSendSOL`, `planSendToken`, `quoteSwap`, `planSwap` (devolvem `SigningPlan`, sem assinar).
- `SolanaNetworkReader.shared`: `networkState`, `destinationAccount`, `destinationTokenAccount`, `tokenState`, `mintInfo`, `swapAsset`, `swapAccounts`, `lookupTables` (2 RPCs), `simulate`, `snapshots`, `blockHeight`.
- `SolanaBroadcaster.shared`: `send(SignedTransaction)` (2 provedores, `skipPreflight: false`), `status(of:)`, `waitForConfirmation(_:lastValidBlockHeight:target:)` (reenvia os mesmos bytes ate confirmar ou vencer).
- `SolanaHistoryReader.shared.recentActivity(owner:limit:knownAddresses:)` devolve `[SolanaActivity]` (carteira + ATAs dos tokens da lista, 30 por padrao).

Troca pela Jupiter (docs/seguranca.md §4.6), conferido ao vivo em 26/09/2026:
- `GET api.jup.ag/swap/v2/quote` e `/build`, sem chave, 30 req/min por IP; `lite-api.jup.ag` esta sendo aposentado. `platformFeeBps=0` (taxa da Escalibur compilada em `SolanaSwapPlanner.escaliburFeeBps = 0`).
- O `/build` devolve `shared_accounts_route_v2` ou `route_v2`, formato conferido contra o IDL Anchor lido da cadeia. Nessas variantes os escalares (in, quoted_out, slippage, platform_fee, positive_slippage) vem antes do plano de rota; as variantes antigas sao recusadas por falta de decodificador completo.
- Da proposta so a rota entra na mensagem; preparo e limpeza tem de ser identicos aos que a carteira monta (e a carteira usa os dela); gorjeta e `otherInstructions` recusam; orcamento de CU e da carteira. Tabelas lidas de 2 RPCs (igual ou prefixo). Mensagem v0 por `compileV0`, verificada por `SolanaMessageVerifier`, rota redecodificada da mensagem compilada.
- Simulacao obrigatoria antes do plano: sai no maximo o valor, entra pelo menos o minimo na conta do dono, SOL do dono dentro de valor + taxa + rent. CU = consumo * 1,1.
- `/tx/v1/submit` (e `tx.jup.ag`) existe e responde sem chave, mas exige gorjeta >= 0,001 SOL a uma das 16 contas da Jupiter dentro da transacao: nao e terceira via de transmissao.

Achados:
- `solana-rpc.publicnode.com` devolve o slot em `getBlockHeight` com `commitment` (sem `commitment`, a altura). A altura vem de `getEpochInfo` do mesmo no do blockhash, e a janela `lastValidBlockHeight - altura <= 300` e conferida.
- ATA de Token-2022 tem 165 + 1 + extensoes de conta (TLV): PYUSD = 187 bytes, conferido na cadeia.

Ordem limite na Solana: fica de fora na v1.
- Trigger v2 e custodial (cofre Privy): fora.
- Trigger v1 (programa `j1o2qRpjcyUwEvwtcfhEQefh773ZgjxcVRry7LDqg5X`, escrow em PDA da ordem, so o dono cancela) ainda aceita ordens novas hoje, sem chave, e e nao custodial. Mas: (1) `createOrder` devolve transacao pronta; (2) o IDL gravado na cadeia (`limit_order_2`) nao bate com os dados que a API monta: `InitializeOrderParams` do IDL tem 6 campos e a instrucao real traz 9 bytes a mais depois deles (um campo que o IDL nao descreve). Sem decodificador completo, sem assinatura; (3) o programa nao esta na lista compilada de `SolanaProgram`; (4) recebe so atualizacoes criticas. Reabrir quando houver IDL que feche com os bytes.

Fora desta etapa: tx v1 (0x81) na troca, rotas de saida exata, divisao entre provedores, taxa da Escalibur diferente de zero (exigiria conta de taxa compilada), leitura da epoca para a taxa Token-2022 vigente (usa o pior caso).
