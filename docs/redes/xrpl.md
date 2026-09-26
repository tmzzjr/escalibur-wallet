# XRP Ledger: resumo da implementação (branch rede/xrpl, 42af15e)

Arquivos em `Kit/Sources/EscaliburChains/XRPL/`: XRPLDefinitions, XRPLBinary, XRPLAmount, XRPLTransaction, XRPLState, XRPLPlanner, XRPLIncomingPayment.

API: `XRPLPlanner.planSend / planTrustline / planOffer / planCancelOffer` → `SigningPlan`. `fee(openLedgerFee:)`, `spendable(account:ledger:)`, `rippleTime(_:)`. Teto de taxa 1.000 drops, piso 10, ×1,2, janela 20 ledgers, oferta ≤ 30 dias. `XRPLIncomingPayment.read(json:)` só lê `delivered_amount`.

A camada de rede preenche:
- `XRPLLedgerState`: validatedLedgerIndex, reserveBase, reserveIncrement (drops, de server_info), openLedgerFee.
- `XRPLAccountState`: address, sequenceReadings (≥ 2 servidores, iguais), balance, ownerCount, flags.
- `XRPLDestinationState`: address, readings (.notFound/.found(flags:), ≥ 2 concordando), depositPreauthorized.
- `XRPLCuratedAsset`: lista compilada de moeda + emissor.

Decisões: lsfDisallowXRP exige `acknowledgesDisallowXRP`; reserva sempre exigida para trustline/oferta; lsfDisableMaster bloqueia; trustline com tfSetNoRipple; "XRP" recusado como código de moeda.
Fora: Ed25519/family seed/Secret Numbers, multisig, tickets, paths em plano, MPT, swap.
