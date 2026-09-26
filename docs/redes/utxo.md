# UTXO (BTC, LTC, DOGE): resumo (branch rede/utxo, 70c428e)

Arquivos em `Kit/Sources/EscaliburChains/UTXO/`: UTXOTransaction, UTXOScript, UTXOSighash, UTXOSignableTransaction, UTXORules, UTXOCoinSelection (BnB do Core + desperdício), UTXOPlanner, BIP21.

API:
```
UTXOCoin(outpoint:, previousTransaction: [UInt8] (tx crua inteira), confirmations:, path: (m/p'/c'/a'/0|1/i), publicKey: 33)
UTXONetworkState(coins:, feeEstimates: [UTXOFeeRate] (>= 2 fontes), tipHeight:, skipped: [UTXOSkippedCoin])
UTXOChangeAddress(address:, path: (cadeia 1), publicKey:, accountKey: ExtendedPublicKey)
UTXOSendIntent(destination:, amount: .exact(BigUInt) | .all, feeRate:, change:, coinControl:, knownAddresses:)
UTXOPlanner.planSend(walletID:, chain:, intent:, network:, now:) -> SigningPlan
UTXOPreviousOutput.verify(previousTransaction:, outpoint:) -> UTXOTxOut
BIP21URI.parse(_:expected:)
```
Regras: recusa taxa acima do teto compilado (500 sat/vB, 200 lit/vB, 10 DOGE/kB), acima de 2× a maior estimativa, estimativas mais de 3x distantes (`UTXOFeeConsensus`) e teto absoluto (0,1 BTC/LTC, 100 DOGE); aviso acima de 1% do valor; moedas fora da leitura na revisão; dust por tipo; não gasta sozinho moeda ≤ max(1000, dust) nem recebimento sem confirmação; nSequence 0xFFFFFFFD; locktime = altura; BIP-69; troco amarrado à xpub.
Fora: gasto Taproot, PSBT, MWEB (LTC). Parâmetros [P] de LTC/DOGE a confirmar.
