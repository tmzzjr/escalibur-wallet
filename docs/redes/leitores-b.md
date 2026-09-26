# Leitores de rede B: BTC, LTC, DOGE, Stellar (branch rede-leitores-b, 71a68cb)

Código em `Kit/Sources/EscaliburNetwork/ReadersB/`: ReaderSupport, ChainActivity, UTXOAccount, UTXOBackends, UTXOReader, StellarReader, StellarHistory.

API:
- `UTXOAccount(chain:kind:account:accountKey:)`, `address(change:index:)`.
- `UTXOReader(chain:)`: `discover(_:gapLimit:knownUsed:) -> UTXODiscovery` (used, usedReceiveIndices, usedChangeIndices, nextReceive, nextChange, changeAddress), `coins(for:) -> UTXOCoinReading`, `feeLevels() -> UTXOFeeLevels` (slow, normal, fast, estimates), `tipHeight()`, `isUnused(_:)` (dois provedores), `spendState(_:) -> UTXOSpendState` (com as moedas fora da leitura em `network.skipped`), `broadcast(SignedTransaction) -> UTXOBroadcastReceipt`, `status(txid:)`, `history(_:limit:knownCounterparties:) -> [ChainActivity]`.
- `StellarReader()`: `ownerAccount(_:localSequence:) -> StellarAccountState?`, `destination(_:) -> StellarDestinationState`, `networkState()`, `offers(_:)`, `offersOnBoth(_:)` (as duas Horizons, juntas), `quoteStrictSend(send:amount:receive:allowedPath:) -> StellarPathQuote?`, `quoteStrictSendOnBoth(send:amount:receive:allowedPath:)` (a troca ancora na maior), `broadcast(_:) -> StellarSubmission`, `status(hash:)`, `history(_:limit:listedAssets:knownCounterparties:)`.
- Comuns: `ChainActivity`, `ChainTransactionStatus`, `ChainReaderError`; transporte injetável `ChainReaderTransport` (produção `HTTPReaderTransport`).

Regras: respostas estritas; xpub nunca sai (teste confere); cada moeda passa por `UTXOPreviousOutput.verify` e paga o script da chave derivada; transmissão confere txid local; Stellar: sequence de 2 provedores, memo obrigatório se qualquer um disser, "confirmada" exige 2.
Fora: Blockchair sem key bloqueia IP (HTTP 430); descoberta ao vivo de LTC/DOGE por xpub; motivo exato de recusa na transmissão (HTTPClient não devolve corpo de erro); retentativa com jitter; fee bump.
