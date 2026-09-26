# Tron: resumo (branch rede/tron, 29cbd44)

Arquivos em `Kit/Sources/EscaliburChains/Tron/`: TronAddress, TronProtobuf, TronTransaction, TRC20, TronPermissions, TronPlanner.

API: `TronPlanner.planSendTRX / planSendUSDT(walletID, owner, to, amount, memo, state, now)`. Broadcast: `encoded` = hex de Transaction{raw_data, signature} para `POST /wallet/broadcasthex {"transaction": encoded}`; id = txID. Assinatura v = recid + 27. Expiração 60 s a partir do maior entre hora do bloco e relógio.

Rede preenche `TronNetworkState`: block (TronBlockReference de getnowblock), trxBalance, usdtBalance, resources (getaccountresource), parameters (getchainparameters: getEnergyFee, getTransactionFee, getCreateNewAccountFeeInSystemContract, getCreateAccountFee, getMemoFee), destinationActivated, destinationIsContract, usdtEnergyEstimate (triggerconstantcontract/estimateenergy), destinationHoldsUSDT, ownerControl (TronPermissions.check sobre getaccount). `TronOwner(path:publicKey:)`.

Regras: fee_limit = estimativa × preço × 1,25 (teto 100 TRX, energy 10k a 200k); sem TRX → .noTRXForFees; ativação 1 TRX (+0,1 sem bandwidth); memo 1 TRX; recusa destino = própria conta, contrato USDT, queima; conta comprometida bloqueia.
Fora: outros TRC-20, TRC-10, estimativa separada para "Máximo", multi-sig.
