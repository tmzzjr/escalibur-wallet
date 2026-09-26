# Stellar: resumo (branch rede/stellar, 1c214a0)

Arquivos em `Kit/Sources/EscaliburChains/Stellar/`: StellarXDR, StellarAccount, StellarAsset, StellarTransactionXDR, StellarSigning, StellarState, StellarPlanner.
API (`StellarPlanner`, → SigningPlan ou `StellarPlanError.reason`): `planSendNative(amount:to:memo:destination:context:)` (CreateAccount se o destino não existe), `planSendAsset`, `planAddTrustline`, `planSwap(send:amount:receive:quotedReceive:slippageBasisPoints:path:context:)` (strict send, ChangeTrust na mesma tx se faltar, ≤ 500 bps), `planLimitOrder(sell:amount:buy:minimumReceive:context:)`, `planCancelOrder(offerID:selling:buying:context:)`.
Regras: seq + 1; timeBounds 0 a agora + 180 s; taxa por op = max(100, base, p90), teto 0,01 XLM.

Rede preenche: `StellarPlanContext` (walletID, source, account, network, allowedAssets, now); `StellarSource` (path m/44'/148'/i', chave); `StellarAccountState` (/accounts/{G}: sequence, balance, subentryCount, sellingLiabilities, numSponsoring, numSponsored, trustlines); `StellarTrustline`; `StellarDestinationState` (exists, trustlines, memoRequired; helper `memoRequired(dataEntries:)`); `StellarNetworkState` (baseReserve, baseFee, feeChargedP90).
Fora: fee bump, precondições V2, Soroban, claimable balance, ManageBuyOffer, remover trustline, chave S, strict receive em plano, home_domain/stellar.toml.
