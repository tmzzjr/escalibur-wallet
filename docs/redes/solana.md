# Solana: resumo (branch rede/solana, 656ce81)

Arquivos em `Kit/Sources/EscaliburChains/Solana/`: Edwards25519 (checagem de ponto, semântica do dalek), SolanaPublicKey (PDA, ATA), SolanaShortVec, SolanaMessage (legado e v0), SolanaTransaction (+ SolanaWireTransaction só leitura), SolanaPrograms, SolanaVerifier, SolanaPlanner.

API: `SolanaPlanner.planSendSOL / planSendToken / sendSOLFee`. `SolanaMessageVerifier.verify(_:policy:lookupTables:)` (política exige a lista de programas esperados). `SolanaAssociatedToken.address(owner:mint:tokenProgram:allowOwnerOffCurve:)`. Transmitir o base64 de `SignedTransaction.encoded`, nunca reassinar.

Rede preenche: `SolanaNetworkState` (blockhash, lastValidBlockHeight, altura, fetchedAt, saldo, rentExemptMinimum de getMinimumBalanceForRentExemption(0), preço de prioridade sugerido, simulatedComputeUnits?); `SolanaDestinationAccount` (nonexistent/system/tokenAccount/programOwned); `SolanaDestinationTokenAccount` (missing/existing); `SolanaTokenState` (mint, programa, casas, símbolo, curado?, extensões, conta de origem, rent da conta de token); `SolanaOwner` (caminho, chave); `SolanaAddressLookupTable` (2 RPCs).

Regras extras: conta de token como destino usada direto após conferir o mint; destino fora da curva recusado em token sem confirmação; AdvanceNonceAccount recusado em qualquer posição; ATA de terceiro recusado; prioridade ≤ 10 lamports/CU e ≤ 0,002 SOL.
Achados: USDC correto é EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v (o da lista estava errado; corrigido e agora conferido ao vivo). PYUSD bloqueado por permanentDelegate.
Fora: tx v1 (0x81), multiassinatura, rota da Jupiter (camada de troca), TransferCheckedWithFee, nonce durável, varredura de caminhos, NFT.
