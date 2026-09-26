# TON: resumo (branch rede/ton, 61d1509)

Carteira nova V4R2 em `m/44'/607'/i'` (compatível com Trust Wallet; Tonkeeper reconhece). Descoberta na importação: `TONDerivationScheme.importCandidates(account:)` = [44'/607'/i' V4R2, 44'/607'/i' W5, 44'/607'/0'/0'/i'/0' V4R2 (Ledger)].

Arquivos em `Kit/Sources/EscaliburChains/TON/`: TONCell, TONBOC (+CRC32C), TONAddress, TONWallet, TONTransfer, TONJetton, TONPlanning.
API: `TONPlanner.planSendTON / planSendUSDT` → SigningPlan. `TONWallet(publicKey:version:)`. `TONJetton.usdtMaster / usdtWallet(owner:) / attachedTON 0,05 / forwardTON 1 nanoton`. Transmitir `SignedTransaction.encoded` (BOC base64 da mensagem externa).

Rede preenche `TONChainState`: accountStatus (.uninitialized/.active/.frozen), seqno, balance, codeHash?, destinationStatus, destinationCodeHash?, estimatedFee (0 < fee ≤ 0,1 TON). `TONJettonState`: ownerJettonWallet (get_wallet_address, conferido com cálculo local), balance.

Decisões: bounce pela regra do Tonkeeper (UQ nunca volta; EQ/raw só se destino ativo); valid_until = plano + 120 s; comentário ≤ 1024 bytes, sem controle/invisível/espaço nas pontas.
Fora: frase nativa TON (algoritmo descrito no relatório: HMAC-SHA512 + PBKDF2 "TON default seed" 100000), V3R1/V3R2, outros jettons, enviar tudo (modo 128).
