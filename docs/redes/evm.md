# EVM: resumo (branch rede/evm, 780e813)

Arquivos em `Kit/Sources/EscaliburChains/EVM/`: EVMAddress, ABI, ABIDecoder, EVMTransaction, ERC20, EIP712, EVMJSON, EVMCallGuard, EVMFees, EVMPlanner, EIP681.

API: `EVMTransaction(chain:account:nonce:fee:gasLimit:to:value:data:)` (Fee .eip1559/.legacy), `ABIFunction(sig).encodeCall/decodeCall`, `ABI.decodePrefix`, `ERC20.*`, `EIP712TypedData` + `EIP712ValidatedMessage(_:chain:account:allowlist:[EIP712Rule])` (Permit/Permit2 recusados), `EVMCallGuard.inspect(EVMCallProposal, policy: EVMCallPolicy)` com `contractRules` como gancho da troca. `EVMPlanner.planNativeSend / planTokenSend / planApprove(.exact/.unlimited) / planRevoke / maxNativeSendAmount`. `EIP681Request.parse`.

Rede preenche `EVMNetworkState`: chain, pendingNonces [2 fontes; sem fila local têm de concordar; com a fila (localNextNonce, localPendingCount) só a diferença que as transações em trânsito explicam], baseFeePerGas (mediana de 2), priorityFees (p25/50/75 do feeHistory, mediana de 2), gasEstimate (a menor de 2), l1DataFee? (obrigatório OP/Base via getL1FeeUpperBound), nativeBalance, destinationHasCode. `EVMTokenState`: contractHasCode, balance, allowance?. USDT: estimar approve com state override de allowance 0.

Tetos de taxa (EVMFeeProfile.for) escolhidos pelo agente, revisar: ETH 500 gwei (tip ≤10), ARB 20 (tip 0), Base/OP 20 (≤2), Polygon 10.000 (25 a 2.000), BNB 1 (0,05 a 1), AVAX 2.000 (≤100). Gas = estimativa × 1,2; nativo simples = 21.000. Legado só BNB.
Fora: EIP-191, access list, cancelar/substituir, decodificar RLP de provedor, ENS, allowlists concretas de routers.
