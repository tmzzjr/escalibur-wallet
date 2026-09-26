# Escalibur Wallet: especificação da camada blockchain (v1)

**Legenda.** **[W]** = confirmado hoje (25/09/2026), em documentação ou chamando o endpoint ao vivo. **[P]** = conhecimento prévio, não reconfirmado hoje; confirmar antes de codar.

---

## 0. Achados de hoje que mudam o desenho

1. **O Escalibur não deriva a seed.** `Mnemonic.swift` só normaliza e valida checksum e wordlist. Não existe PBKDF2 em nenhum lugar do repo. O `SelfTest.bip39Vectors` testa só validade, nunca a seed de 512 bits. A 25ª palavra é gravada crua em `VaultFile` (`Array(passphrase.utf8)`), sem NFKD. As wordlists embarcadas já estão em NFKD (conferi: nenhuma das 10 listas muda com NFKD), então o lookup está consistente. [W: leitura do código]
2. **A Odos encerrou em 30/07/2026.** Fica fora da lista. [W]
3. **O Jupiter Trigger v2 (ordens limite na Solana) é custodial**, num cofre "Privy-managed custodial account". Isso é incompatível com "não custodial". [W]
4. **THORChain sofreu um exploit do GG20 TSS em 15/05/2026** (US$ 10,7M de fundos do protocolo) e ficou 5 semanas parada. Hoje a SOL está *halted*. `thornode.ninerealms.com` não resolve DNS. A doc oficial aponta o gateway da Liquify. [W]
5. **Solana.** A redução de rent está em curso: hoje são 5080 lamports/byte. Uma conta de token custa 1.488.440 lamports (antes 2.039.280) e uma conta de sistema vazia 650.240 (antes 890.880). Há mais cortes previstos para nov/2026. A **tx v1** (prefixo 0x81, 4096 bytes, sem ALT, prioridade em lamports absolutos) está ativa desde 15/09/2026. [W, rent conferido ao vivo]
6. **XRPL.** Reservas de 1 XRP de base e 0,2 XRP por objeto; taxa de 10 drops (rippled 3.3.0). [W ao vivo] O BatchV1_1 tem ativação prevista para ~29/09/2026. [W, notícia]
7. **Stellar.** Protocol 28 (visto ao vivo). A reserva de base é de 0,5 XLM. O Horizon está deprecado em favor do Stellar RPC, e o Horizon da SDF guarda só 1 ano. O RPC não faz pathfinding. [W]
8. **Endpoints keyless que morreram.** Ankr agora exige key; `polygon-rpc.com` responde "tenant disabled"; `llamarpc` devolve erro 525; o dRPC free não atende Solana nem Tron e já estourou limite na BSC. [W ao vivo]
9. **Mudanças de endpoint.** O 1inch trocou `api.1inch.dev` por `api.1inch.com` em 31/01/2026, e a key exige KYC/KYB. A OpenOcean virou De¹ (`open-api.de1.exchange`). A Uniswap cobra taxa do integrador fora da cotação. [W]
10. **O gas da L1 Ethereum está em ~0,07 gwei hoje.** Um approval exato custa centavos, então não há justificativa para approval infinito. [W ao vivo]

---

## 1. Base comum

### 1.1 Da frase à seed (o que falta no Escalibur)

- **Reusar:** `Mnemonic.canonicalize` (NFKD, sem invisíveis, minúsculas, espaço único U+0020), `Wordlist`/`WordlistStore` e o `wordlists.lock`.
- **Acrescentar:** `seed = PBKDF2-HMAC-SHA512(P = UTF8(frase canônica), S = UTF8("mnemonic" + NFKD(passphrase)), c = 2048, dkLen = 64)`, via `CCKeyDerivationPBKDF(kCCPBKDF2, …, kCCPRFHmacAlgSHA512, 2048, …)`.
- **Passphrase: só NFKD.** Sem minúsculas, sem trim, sem colapsar espaços.
  - O campo precisa de `smartQuotesType = .no`, `smartDashesType = .no`, `autocorrectionType = .no`, `autocapitalizationType = .none` e `spellCheckingType = .no`.
  - O apóstrofo curvo U+2019 que o iOS insere sozinho **não vira `'` em NFKD**. Resultado: outra carteira, válida e vazia, sem aviso.
- **Impressão digital da passphrase.** Ao entrar com a passphrase, mostre o *master fingerprint* (4 bytes do HASH160 da pubkey mestre secp256k1) e o primeiro endereço. É o único jeito de o dono notar que digitou errado.
- **SLIP-39 (Trezor Shamir).** O Escalibur só inspeciona as partes. Para importar é preciso combinar as partes, decifrar (Feistel com PBKDF2-SHA256) e usar o master secret **direto** como seed BIP-32, sem o PBKDF2 do BIP-39. [P]
- **Xaman aceita frases de "12, 16 ou 24 palavras".** [W] 16 não é tamanho BIP-39, e o Escalibur recusaria. Investigar o que é antes de suportar.

### 1.2 Derivação

- **secp256k1:** BIP-32 com chave HMAC `"Bitcoin seed"`. Serve BTC, EVM, XRPL (via BIP-44) e Tron. Se IL ≥ n ou a chave der 0, pula o índice.
- **Ed25519:** SLIP-10 com chave `"ed25519 seed"`, só derivação hardened. Serve Solana e Stellar. O IL de 32 bytes é a chave privada RFC 8032 (a "seed" Ed25519).

### 1.3 Assinatura por rede

| Rede | Curva | Algoritmo e formato | Nonce |
|---|---|---|---|
| BTC segwit v0 / legado | secp256k1 | ECDSA DER + byte de sighash, low-S | RFC 6979 (libsecp) |
| BTC Taproot | secp256k1 | Schnorr BIP-340 de 64 bytes, chave tweakada BIP-86 | aux_rand de 32 bytes do CSPRNG |
| EVM | secp256k1 | ECDSA recuperável (módulo recovery), low-S (EIP-2) | RFC 6979 |
| Tron | secp256k1 | ECDSA recuperável, 65 bytes r‖s‖v | RFC 6979 |
| XRPL | secp256k1 ou Ed25519 | ECDSA DER low-S (RequireFullyCanonicalSig), ou Ed25519 | RFC 6979 / CryptoKit |
| Solana, Stellar | Ed25519 | PureEdDSA 64 bytes | CryptoKit (aleatorizado) |

### 1.4 A assinatura Ed25519 aleatorizada do CryptoKit é problema?

Para validade, não. A assinatura aleatorizada verifica como qualquer Ed25519 e sai com S canônico. [W: a implementação da Apple é aleatorizada, portanto não determinística como o RFC 8032] O que ela muda:

- **Solana:** o id da tx é a primeira assinatura. Reassinar a mesma mensagem gera outro id. A rede deduplica por hash da mensagem, então não executa duas vezes. [W] **Regra:** assinar uma vez, persistir os bytes e retransmitir os mesmos bytes.
- **XRPL Ed25519:** o hash da tx inclui a assinatura, mesmo efeito. O `Sequence` impede execução dupla. Mesma regra.
- **Stellar:** o hash exclui a assinatura. Nenhum efeito.
- **Testes:** não dá para usar os vetores de *assinatura* do RFC 8032 byte a byte. Teste três coisas: derivação da pubkey (conhecida), verificação de assinaturas conhecidas e verify(sign(m)).
- **Segurança:** assinatura com ruído não piora nada e resiste melhor a ataque de falha.

### 1.5 Primitivas a escrever no repo, e uma armadilha

- A lista: Keccak-256, RIPEMD-160, Base58/Base58Check (dois alfabetos), Bech32/Bech32m, CRC16-XModem, RLP, XDR, codec binário da XRPL, protobuf mínimo (Tron) e compact-u16 da Solana.
- **Keccak-256 ≠ SHA3-256.** `keccak256("") = c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`, enquanto `sha3_256("") = a7ffc6f8…434a`. É o erro mais comum.
- CRC16-XModem(`"123456789"`) = `0x31C3`.

### 1.6 Custódia nesta camada: perda e vazamento

**Perda:**
- Importar com o caminho errado mostra saldo zero, e o dono conclui que perdeu.
  - Varrer todos os esquemas da §2.7.
  - Gravar qual esquema foi achado em cada rede.
  - Exportar uma "folha de recuperação" com rede, caminho, índices e script type.
- O mapa de derivação da Escalibur Wallet tem que ser documentado e reconstruível em qualquer carteira BIP-39. Só caminhos padrão, nada proprietário.

**Vazamento:**
- **Seed e chaves** só existem em claro durante derivação e assinatura, em `SecureBytes`, zerados ao fim de cada *plano de assinatura*. Nunca mantenha chave derivada entre planos.
- **xpub** nunca vai a terceiro (nada de endpoints "por xpub").
- **Consultar todos os endereços no mesmo provedor** a partir do mesmo IP liga o conjunto, o que equivale a vazar o xpub. Mitigações: permitir nó próprio (Esplora, Electrum, RPC), consultar com jitter e não carregar identificador de conta.
- **Log, analytics, crash report:** nenhum em código de chave, nem em build de debug. Tx assinada é pública, mas quote, address book e cache de saldo são patrimônio: ficam cifrados no aparelho e fora de log.

---

## 2. Especificação por rede

### 2.1 Bitcoin

**Derivação e descoberta**
- **Esquemas:**
  - BIP-84 `m/84'/0'/a'/c/i` (bc1q) é o padrão da Wallet.
  - BIP-86 `m/86'/0'/a'/c/i` (bc1p): recebimento e gasto.
  - BIP-49 `m/49'/0'/a'/c/i` (3…) e BIP-44 `m/44'/0'/a'/c/i` (1…): só para import.
- **Descoberta:** para cada tipo, contas a' = 0,1,… Varre a cadeia 0 (recebimento) **e a cadeia 1 (troco)**, com gap 20 em cada. Uma conta sem nenhuma tx encerra aquele tipo. Deixe o dono aumentar o gap manualmente.

**Assinatura e endereço**
- Assinatura v0: ECDSA com SIGHASH_ALL.
- Taproot key-path: `t = TaggedHash("TapTweak", Px)`, `Q = P + tG`, Schnorr com SIGHASH_DEFAULT (0x00).
- Endereço: bech32 para v0 (BIP-173), bech32m para v1 (BIP-350), Base58Check para 1…/3….
  - Validar HRP `bc`, versão e tamanho (v0: 20 ou 32 bytes; v1: 32).
  - Recusar versão ≥ 2 (recomendação).

**Serialização e o que se assina**
- Serialização BIP-144 (marker 0x00, flag 0x01).
- **v0:** `dSHA256(version‖hashPrevouts‖hashSequence‖outpoint‖scriptCode‖amount‖nSequence‖hashOutputs‖locktime‖sighashType)`.
  - scriptCode de P2WPKH: `0x1976a914{H160}88ac`.
- **Taproot:** `TaggedHash("TapSighash", 0x00‖SigMsg)`, com os valores e scriptPubKeys de **todos** os prevouts.
- **P2PKH legado:** o sighash não compromete o valor do input.
- RBF por nSequence `0xfffffffd`. Locktime na altura atual, contra fee sniping. [P]

**Taxa**
- `GET mempool.space/api/v1/fees/precise`. Hoje: fastest 1, halfHour 0,644, hour 0,347, economy 0,2, minimum 0,1 sat/vB. [W ao vivo]
- O minrelay padrão caiu para 0,1 sat/vB no Core 29.1/30. [W] Nós antigos ainda pedem 1, então abaixo de 1 a propagação não é garantida. Use 1 como piso por padrão.
- vsize por input [P]: P2WPKH ~68, P2TR ~57,5, P2SH-P2WPKH ~91, P2PKH ~148.
- **Na v1 (código):** teto compilado por rede (`UTXORules.maxFeeRate`: 500 sat/vB no Bitcoin, 200 lit/vB no Litecoin, 10 DOGE/kB no Dogecoin), nunca derivado das fontes. Duas fontes de taxa, no máximo 3x distantes (perto do piso a comparação parte de 5x o piso); cada nível é o menor de duas ou a mediana de três (`UTXOFeeConsensus`). Aviso de taxa acima de 1% do valor. O troco só vai para índice que dois provedores veem sem histórico.

**Armadilhas**
- **Dust** (dustrelayfee de 3 sat/vB [W]): P2PKH 546, P2SH 540, P2WPKH 294, P2TR/P2WSH 330 sats. [P] Troco abaixo do dust vira taxa, e a tela tem que mostrar.
- **Troco** vai para endereço novo da cadeia 1. Importar sem varrer a cadeia 1 faz o saldo "sumir".
- **Input P2PKH:** baixe a tx anterior inteira e confira se o txid bate. Sem isso, um servidor mentindo sobre o valor faz a Wallet pagar taxa enorme.
- **Full-RBF é padrão:** 0-conf de entrada não é pagamento.
- **UTXOs de 330 ou 546 sats** podem carregar inscrição ou runa. Não gastar automaticamente UTXO ≤ 1.000 sats (coin control).
- **Envio:** fazer broadcast em ≥ 2 provedores.

**Provedores**

| Provedor | URL | Situação hoje |
|---|---|---|
| mempool.space | `https://mempool.space/api` | [W] ~10 rps |
| Blockstream | `https://blockstream.info/api` (Esplora) | [W]; há API paga com key, 500k req/mês grátis [W] |
| Contingência comunitária | `mempool.emzy.de/api`, `mempool.ninja/api` | [W ao vivo] |

**Vetores:** BIP-32 (vetores 1 a 5), BIP-39 (vectors.json do Trezor, passphrase "TREZOR"), BIP-84/86/49, exemplos do BIP-143, `bip-0340/test-vectors.csv`, `bip-0341/wallet-test-vectors.json`, válidos e inválidos do BIP-173/350, `key_io_valid.json` e `base58_encode_decode.json` do Bitcoin Core.
- Âncoras [P]: "abandon×11 about" em `m/84'/0'/0'/0/0` dá `bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu`, e em `m/86'/0'/0'/0/0` dá `bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr`.

### 2.2 EVM (Ethereum 1, Arbitrum 42161, Base 8453, OP 10, Polygon 137, BNB 56, Avalanche C 43114)

`eth_chainId` confirmado ao vivo em todas. [W]

**Derivação e descoberta**
- Um endereço serve para todas as redes (coin type 60).
- **Caminhos:**
  - `m/44'/60'/0'/0/i`: MetaMask, Trezor, Trust e Exodus (Trust e Exodus usam i = 0). [Exodus W; demais P]
  - `m/44'/60'/i'/0/0`: Ledger Live. [P]
  - `m/44'/60'/0'/i`: Ledger legado (MEW/MyCrypto). [P]
  - O Phantom declara EVM em `m/44'/60'/0'/0/i` e, quando há atividade, `m/44'/60'/1'/0/i` e `m/44'/60'/2'/0/i`. [W, mas a tabela é estranha; conferir]
- **Descoberta:** gap 5 por esquema. Uma conta é ativa se tiver nonce > 0 em qualquer das 7 redes, ou saldo nativo, ou saldo em token da lista curada. Nonce 0 com token recebido passa despercebido se só olhar nonce.

**Assinatura e endereço**
- Endereço: `keccak256(pub64)[12:]`, com checksum EIP-55. Entrada toda em minúsculas não tem checksum: exija confirmação extra.

**Transações e o que se assina**
- **Tipo 2:** assina `keccak256(0x02‖rlp([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList]))`. Transmite `0x02‖rlp([…, yParity, r, s])`.
- **Legado EIP-155:** assina `keccak256(rlp([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]))`, com `v = recid + 35 + 2·chainId`.
- **EIP-712:** `keccak256(0x1901‖domainSeparator‖hashStruct)`.
- **EIP-191:** prefixo `"\x19Ethereum Signed Message:\n" + len`.
- **Proibido na v1:**
  - Tipo 4 / EIP-7702. Numa amostra, 63% das autorizações estavam ligadas a contratos maliciosos. [W]
  - `eth_sign` cru.
  - `setApprovalForAll`.

**Taxa**
- `eth_feeHistory(10, [25, 50, 75])` e baseFee do próximo bloco.
- `maxFee = 2·baseFee + tip`.
- `gasLimit = estimateGas × 1,2`, com teto de 16.777.216 (EIP-7825, Fusaka). [W]
- **Por rede, hoje ao vivo:**
  - Ethereum: baseFee ~0,07 gwei.
  - Arbitrum: ~0,02 gwei; tip ignorado; o estimateGas já inclui a parcela L1. [P]
  - Base: 0,005 gwei; OP e Base cobram **taxa L1 de dados à parte** (GasPriceOracle `0x420000000000000000000000000000000000000F`, `getL1Fee`/`getL1FeeUpperBound`). [P] Esquecer disso dá "saldo insuficiente" ao enviar o máximo.
  - Polygon: baseFee ~245 gwei; tip mínimo de 25 gwei. [W]
  - Avalanche: ~0,04 gwei.
  - **BNB:** baseFee = 0 e tip de 0,05 gwei. [W ao vivo; mínimo de 0,05 gwei W] Aceita tipo 2 com maxFee = maxPriority = gasPrice [P]; manter legado como fallback.

**Armadilhas**
- **Nonce:** *pending* em 2 RPCs. **Na v1 (código):** sem a fila local do app (`PendingNonceQueue`), os dois têm de concordar; com ela, cada fonte entre o primeiro nonce em trânsito e o próximo da fila, e vale o da fila. Nunca "o maior com folga". Substituição exige +10% em maxFee **e** em tip. [P] Cancelar = self-send de 0 com o mesmo nonce.
- **Taxa na v1 (código):** baseFee e gorjetas pela mediana de 2 RPCs; `gasLimit` = a menor de 2 estimativas × 1,2; teto por rede em `EVMFeeProfile` (BNB: 1 gwei).
- **chainId:** validar o `eth_chainId` de todo RPC antes de usar.
- **Tokens fee-on-transfer e rebasing:** fee-on-transfer com parâmetro de taxa do integrador faz o swap do 1inch falhar sempre. [W]
- **USDT na mainnet** exige `approve(0)` antes de mudar uma allowance não-zero. [P]
- **Permit/Permit2 off-chain** é tão perigoso quanto approval.
- **Envenenamento de endereço:** transferências de 0 vindas de sósias no histórico.
- **Mesmo endereço em 7 redes:** exchange que só aceita Ethereum recebe em Base. Mostre a rede em destaque.
- **Tokens falsos:** lista curada por (chainId, contrato).
- **Crédito de valor alto:** usar a tag `finalized`/`safe`.
- **Histórico:** RPC não dá histórico. Precisa de indexador (Blockscout público ou Etherscan v2 com key). [P]

**Provedores** [todos W ao vivo]

| Rede | Oficial | Contingência 1 | Contingência 2 |
|---|---|---|---|
| Ethereum | `cloudflare-eth.com` | `ethereum-rpc.publicnode.com` | `eth.drpc.org`, `1rpc.io/eth` |
| Arbitrum | `arb1.arbitrum.io/rpc` | `arbitrum-one-rpc.publicnode.com` | `arbitrum.drpc.org`, `1rpc.io/arb` |
| Base | `mainnet.base.org` | `base-rpc.publicnode.com` | `base.drpc.org`, `1rpc.io/base` |
| OP | `mainnet.optimism.io` | `optimism-rpc.publicnode.com` | `optimism.drpc.org`, `1rpc.io/op` |
| Polygon | (`polygon-rpc.com` morto) | `polygon-bor-rpc.publicnode.com` | `polygon.drpc.org`, `1rpc.io/matic` |
| BNB | `bsc-dataseed.bnbchain.org` | `bsc-rpc.publicnode.com` | `1rpc.io/bnb` (drpc com rate-limit) |
| Avalanche | `api.avax.network/ext/bc/C/rpc` | `avalanche-c-chain-rpc.publicnode.com` | `avalanche.drpc.org`, `1rpc.io/avax/c` |

Swaps na Ethereum: broadcast por RPC com proteção de MEV (Flashbots Protect, MEV Blocker). [P]

**Vetores:** EIP-55 e EIP-155 (exemplos dentro das EIPs), EIP-712 (exemplo "Mail"), `ethereum/tests` (TransactionTests e RLPTests).
- Âncora [P]: "abandon×11 about" em `m/44'/60'/0'/0/0` dá `0x9858EfFD232B4033E47d90003D41EC34EcaEda94`.

### 2.3 Solana

**Derivação (SLIP-10 Ed25519), por ordem de varredura**
1. `m/44'/501'/i'/0'`: padrão do Phantom, do Exodus e do Solflare atual. [W]
2. `m/44'/501'/i'`: Ledger Live e **padrão do Trust**, que só mostra o `/0'` se houver saldo. Também o Solflare legado. [W]
3. `m/44'/501'`: raiz do solana-keygen com `?key=` vazio. [P]
4. Seed direta: o solana-keygen padrão usa `seed[0..32]`, sem caminho. [P]
5. `m/501'/i'/0/0`: o antigo caminho do Sollet, marcado como deprecated pelo Phantom. [W o caminho; o algoritmo, provavelmente BIP-32 secp256k1 com a chave usada como seed Ed25519, é P] Validar contra vetor gerado pelo próprio Phantom antes de habilitar.

- Descoberta: gap 5 por esquema. Ativo = lamports > 0, ou `getSignaturesForAddress(limit 1)` não vazio, ou tem contas de token.

**Assinatura e endereço**
- Ed25519 sobre os bytes da mensagem; `signature[0]` é o id da tx.
- Endereço: Base58 de 32 bytes, **sem checksum**. Um erro de digitação continua sendo endereço válido.

**Formatos de tx**
- **Legado:** `compact(sigs)‖msg`. A msg é header(3)‖compact(chaves)‖blockhash(32)‖compact(instruções).
- **v0:** prefixo 0x80 e ALTs no final da mensagem.
- **v1 (desde 15/09/2026):** [W]
  - prefixo 0x81, até 4096 bytes, sem ALT, máximo de 64 contas;
  - CU limit, *loaded-accounts* e prioridade vão no header, e a prioridade é em **lamports absolutos**;
  - o padrão é zero, então tem que ser definido explicitamente;
  - a mensagem vem antes das assinaturas; enviar em base64.
- **Validade:** blockhash vale ~150 blocos (~60 a 90 s). [P] **Na v1 (código):** "venceu, pode enviar de novo" só quando a altura finalizada de dois RPCs passou do `lastValidBlockHeight` com 150 blocos de folga e o histórico dos dois não conhece a assinatura. Destino, conta de token do destino e mint são lidos de dois RPCs que concordam.
- Sinalizar tx cuja primeira instrução é `AdvanceNonceAccount`: nonce durável, tática de drainer.

**Taxa**
- 5000 lamports por assinatura [P], mais prioridade.
- Estimar: `simulateTransaction` para ler `unitsConsumed × 1,1`, e `getRecentPrioritizationFees(contas graváveis)` no percentil 50 a 75.
- **Pôr teto na prioridade.** Um provedor malicioso pode drenar SOL com prioridade absurda.

**Armadilhas**
- **Rent é dinâmico:** usar sempre `getMinimumBalanceForRentExemption`. Deixar sobra abaixo do mínimo falha.
- **ATA inexistente:** criar com `createAssociatedTokenAccountIdempotent`; o remetente paga o rent.
- **Dono cola o endereço de uma conta de token em vez da carteira:** se a Wallet derivar a ATA dessa ATA, os fundos ficam presos. Se o dono do destino é o Token Program, tratar como conta de token (conferir mint) ou recusar.
- **Token-2022:** ler as extensões do mint e avisar ou recusar. A pior é *permanent delegate* (o emissor move seus tokens); também transfer fee, transfer hook, default frozen e non-transferable.
- **Mints falsos:** lista curada.
- **ATA fechada:** o próximo envio a recria e alguém paga o rent de novo.

**Provedores**

| Provedor | Situação |
|---|---|
| `api.mainnet.solana.com` | [W] 100 req/10 s/IP; "não para produção" |
| `solana-rpc.publicnode.com` | [W ao vivo] |
| `solana-mainnet.gateway.tatum.io` | [W ao vivo; limites desconhecidos] |
| Produção | free tier com key (Helius, QuickNode, Alchemy) via proxy [P]; `/tx/v1/submit` da Jupiter como broadcaster extra [W] |

**Vetores:** SLIP-10 (Ed25519), RFC 8032 (pubkey e verificação), fixtures do solana-sdk e do web3.js. Gerar vetores de cada esquema em CI com implementação de referência (não embarcada).

### 2.4 XRP Ledger

**Derivação e formatos de segredo**
- `m/44'/144'/a'/0/0`: Ledger Live. [P]
- `m/44'/144'/0'/0/i`: Trust, Exodus e import de mnemônica no Xaman. [P]
- **Family seed** (`s…`, Base58 alfabeto Ripple, versão 0x21, 16 bytes). **Não é BIP-32.** [P]
  - secp256k1: `root = SHA512Half(seed‖seq)` até dar escalar válido; a chave da conta é `root + SHA512Half(rootPub‖0‖seq)`.
  - `sEd…`: `priv = SHA512Half(seed)` e pubkey prefixada com 0xED.
- **Secret Numbers** do Xaman (XLS-12): 8 blocos de 6 dígitos (5 de valor 0 a 65535 e 1 verificador) dão 16 bytes, que viram family seed secp256k1. [P]
- Descoberta: gap 3 a 5 via `account_info`.

**Assinatura**
- secp256k1: ECDSA DER low-S sobre `SHA512Half(0x53545800 "STX\0" ‖ campos de assinatura)`.
- Ed25519: assina `STX\0‖campos` direto.
- Multisig: prefixo `"SMT\0"` (0x534D5400) e accountID do signatário no final.
- Hash da tx: `SHA512Half("TXN\0" 0x54584E00 ‖ tx assinada)`.

**Endereço**
- `accountID = RIPEMD160(SHA256(pub33 ou 0xED‖pub32))`.
- Base58Check com versão 0x00, alfabeto `rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz`, checksum de 4 bytes (dSHA256).
- **X-address (XLS-5d)** [P]: `[0x05, 0x44]` (mainnet) ‖ accountID ‖ flag ‖ tag u32 LE ‖ 4 bytes zero. Decodificar e preencher a `DestinationTag`. Se o dono colar um X-address e digitar outra tag, recusar.

**Serialização**
- Campos ordenados por (type code, field code).
- Sempre incluir `LastLedgerSequence` = atual + 20. **Na v1 (código):** "atual" é o ledger validado em que dois servidores leram a conta; o `server_info` de um servidor a mais de 10 ledgers dele é recusado.
- `NetworkID` só em redes com ID > 1024.
- Na API v2 o JSON mostra `DeliverMax`, mas o campo binário continua `Amount`. [P]

**Taxa**
- Hoje: `fee` ao vivo `base_fee` 10, `open_ledger_fee` 10 drops. [W]
- Usar `max(open_ledger_fee, 10) × 1,2`, com teto (ex.: 1.000 drops). A taxa é queimada.

**Armadilhas**
- **Reserva:** 1 XRP mais 0,2 XRP por objeto (trustline, offer, escrow, ticket, NFT page, check, signer list…). [W] Saldo gastável = saldo − reserva.
- **Conta nova** precisa receber ≥ 1 XRP. [P]
- **`lsfRequireDestTag` (0x00020000)** no destino: bloquear envio sem tag. [P] Também checar `lsfDepositAuth` e `lsfDisallowXRP`.
- **Trustline** é necessária para receber token.
- **Emissor falso:** qualquer um emite "USD". Lista curada e domínio verificado.
- **Recursos do emissor:** TransferRate, freeze e clawback.
- **Pagamento parcial:** para exibir entradas, usar sempre `meta.delivered_amount`, nunca `Amount`. [P]
- **Batch** pode ser ativado em ~29/09. Não depender dele na v1.

**Provedores** [W ao vivo]
- `xrplcluster.com` / `xrpl.ws` (InFTF, histórico completo, CORS).
- `s1.ripple.com:51234` e `s2.ripple.com:51234` (s2 com histórico completo).
- `honeycluster.io` (Clio).
- Usar WebSocket para `subscribe`.

**Vetores:** fixtures do `ripple-binary-codec` (codec-fixtures, data-driven-tests, x-codec-fixtures), `ripple-keypairs` `api.json`, `ripple-address-codec` e xrpl-secret-numbers. [P]

### 2.5 Stellar

**Derivação e descoberta**
- SEP-0005: `m/44'/148'/i'` (SLIP-10). Lobstr (12 ou 24 palavras) [W], Ledger, Trust e Exodus em i = 0. [P]
- Também importar chave secreta `S…`.
- Descoberta: gap 5 via `/accounts/{G}` (404 significa que não existe).

**Assinatura**
- Ed25519 sobre `SHA256(networkId ‖ int32(2) ENVELOPE_TYPE_TX ‖ XDR(Transaction))`.
- `networkId = SHA256("Public Global Stellar Network ; September 2015")`. [W ao vivo]
- `DecoratedSignature{hint = 4 últimos bytes da pubkey, sig}`.

**Endereço (StrKey)**
- `base32(versão‖payload‖CRC16-XModem LE)`: G (6<<3), S (18<<3), M (12<<3).
- **Armadilha de implementação:** no StrKey `M` o payload é pubkey‖id (u64 BE), mas no XDR `MuxedAccount.med25519` o id vem **antes**. [P]

**Tx**
- `Transaction{sourceAccount, fee = base × nOps, seqNum = seq + 1, cond (timeBounds com maxTime = agora + 180 s), memo, operations ≤ 100}`.
- Fee bump (tipo 5) para destravar tx presa.

**Taxa**
- 100 stroops por operação [W ao vivo]. Surge acima de 1000 ops por ledger. [W]
- `/fee_stats` hoje: mode 100, max 90.342, capacidade 0,8. [W]

**Armadilhas**
- **Reserva:** 0,5 XLM [W ao vivo, 5.000.000 stroops]. Mínimo = (2 + subentradas) × 0,5, então conta nova precisa de ≥ 1 XLM.
- **Destino inexistente:** `Payment` falha. Usar `CreateAccount`, que só leva XLM e ≥ 1. [P]
- **Ativo não-nativo** para quem não tem trustline falha. Alternativa: claimable balance.
- **Memo:** TEXT (≤ 28 bytes), ID (u64), HASH ou RETURN; o tipo errado perde o depósito.
  - Se o destino tem `config.memo_required = 1` (SEP-29), bloquear envio sem memo. [W]
  - M-address com memo ID ao mesmo tempo: recusar.
- **Ativo falso:** código mais emissor; verificar `home_domain` e o `stellar.toml`.
- **Flags do emissor:** AUTH_REQUIRED e clawback.
- **Ofertas abertas** travam saldo (*liabilities*).

**Provedores**

| Provedor | URL | Situação |
|---|---|---|
| Horizon da SDF | `horizon.stellar.org` | [W ao vivo] só 1 ano de histórico |
| Horizon da LOBSTR | `horizon.stellar.lobstr.co` | [W ao vivo] |
| Stellar RPC | `mainnet.sorobanrpc.com`, `rpc.lightsail.network` | [W ao vivo] |
| Pagos | Blockdaemon (histórico completo), Validation Cloud, QuickNode | — |

- O RPC serve para envio e `getLedgerEntries`. **Não faz pathfinding.**

**Vetores:** SEP-0005 (inclui vetores com passphrase), SEP-0023 (StrKey válidos e inválidos), js-stellar-base (hash e assinatura), stellar-xdr. [P]

### 2.6 Tron: especificação e custo de incluir

**Especificação**
- Derivação: `m/44'/195'/0'/0/i` (TronLink, Trust); Ledger `m/44'/195'/a'/0/0`. [P]
- Endereço: `base58check(0x41 ‖ keccak256(pub64)[12:])`, que dá `T…`. [P]
- Assinatura: secp256k1 recuperável de 65 bytes sobre `txID = SHA256(protobuf(raw_data))`. [P]
- Tx: `raw{ref_block_bytes, ref_block_hash (TaPoS), expiration (60 s), contract[Transfer | TriggerSmartContract], timestamp, fee_limit}`. [P]

**Taxa** [W ao vivo, parâmetros da rede]
- Bandwidth: 600 grátis por dia, depois 1.000 sun por byte.
- Energy: 100 sun (Proposta 104, ago/2025).
- O contrato USDT está com `energy_factor` 34000, o máximo do modelo dinâmico. Isso dá ~64 a 65k de energy para destinatário que já tem USDT e ~130k para destinatário novo, ou seja ~6,5 / ~13 TRX queimados sem stake. [W]
- **Memo custa 1 TRX.**
- **Ativar conta nova custa 1 TRX** (+0,1 TRX se o remetente não tem bandwidth).

**Armadilhas**
- Dono com USDT e 0 TRX não consegue enviar. A empresa não patrocina; o app explica.
- `fee_limit` baixo dá OUT_OF_ENERGY: a tx falha e queima energy.
- **Vencimento na v1 (código):** a expiração é de 60 s a partir do maior entre a hora do bloco e o relógio; o plano é recusado com o relógio do aparelho a mais de 2 minutos do bloco. "Venceu" só pela hora do último bloco solidificado em dois provedores, nunca pelo relógio.
- **Golpe de permissão:** ao importar, compare `owner_permission`/`active_permission` com a chave derivada e bloqueie se divergir. É o golpe da "seed com USDT" compartilhada. Na v1, recusar `AccountPermissionUpdate`.
- Confusão entre TRC-20, ERC-20 e BEP-20.

**Provedores**
- `api.trongrid.io`: key `TRON-PRO-API-KEY` recomendada, ~15 QPS no free. [W]
- `tron-rpc.publicnode.com` e `api.tronstack.io`. [W ao vivo]

**Custo de incluir**
- **Reaproveita:** secp256k1, Keccak, Base58Check e BIP-32.
- **Novo:** protobuf mínimo (raw + 2 contratos, vetores do TronWeb), TaPoS, estimativa de energy (`triggerconstantcontract`/`estimateenergy`) e bandwidth, regras de ativação e memo, checagem de permissões.
- **Esforço estimado:** ~3 a 4 semanas de dev para envio e recebimento de TRX e USDT, mais ~1 semana de auditoria. Swaps somam ~2 semanas (OKX DEX tem router Tron; Chainflip, THORChain e NEAR Intents fazem cross-chain).
- **Recomendação:** incluir na v1, só TRX e USDT, se o público principal é o Brasil.

### 2.7 Caminhos para importar, consolidado

| Origem | BTC | EVM | Solana | XRP | Stellar | Tron |
|---|---|---|---|---|---|---|
| Ledger Live | 44/49/84/86, a' | `44'/60'/i'/0/0` | `44'/501'/i'` | `44'/144'/i'/0/0` | `44'/148'/i'` | `44'/195'/i'/0/0` |
| MetaMask | — | `44'/60'/0'/0/i` | — | — | — | — |
| Trust | `84'/0'/0'/0/0` | `44'/60'/0'/0/0` | `44'/501'/0'` (e `/0'` se houver saldo) | `44'/144'/0'/0/0` | `44'/148'/0'` | `44'/195'/0'/0/0` |
| Phantom | `84'`/`86'…/0/i` | `44'/60'/0'/0/i` (+1', +2') | `44'/501'/i'/0'`, `44'/501'/i'`, `501'/i'/0/0` | — | — | — |
| Solflare | — | — | `44'/501'/i'/0'`, legado `44'/501'/i'` | — | — | — |
| Xaman | — | — | — | family seed, secret numbers, BIP-39 | — | — |
| Lobstr | — | — | — | ? | SEP-5 | — |
| Exodus | `84'/0'/0'/0/0` (+44, 86) | `44'/60'/0'/0/0` | `44'/501'/i'/0'` | `44'/144'/0'/0/0` | `44'/148'/0'` | ? |

Confirmado hoje [W]: Phantom, Trust/Solana, Solflare, Exodus BTC/EVM, Lobstr SEP-5, formatos do Xaman. O resto é [P].

---

## 3. Swaps, ordens limite e combinação de provedores

### 3.1 Provedores por ecossistema

| Provedor | Endpoint | Key? | Taxa do integrador | Estado |
|---|---|---|---|---|
| 1inch Classic v6.1 | `api.1inch.com/swap/v6.1/{chainId}` | Sim, Bearer, **KYC/KYB** [W] | `fee` (% até 3) + `referrer` [P/W 3%] | `.dev` aposentado 31/01/2026 [W] |
| 0x Swap v2 | `api.0x.org/swap/allowance-holder/quote` (`0x-version: v2`) | Sim [W, testado] | `swapFeeBps` 0–1000, `swapFeeRecipient`, `swapFeeToken` [W]; 0x cobra `zeroExFee` em pares do tier Standard [W] | ativo |
| Velora (ex-ParaSwap) | `api.velora.xyz` (`/prices?version=6.2`, `/transactions`); `api.paraswap.io` ainda responde | Não [W ao vivo] | `partner`, `partnerAddress`, `partnerFeeBps` (+`isCapSurplus`, `isSurplusToUser`) [W] | sem `version=6.2` cai no v5 [W] |
| KyberSwap | `aggregator-api.kyberswap.com/{chain}/api/v1/routes` + `route/build` (`x-client-id`) | Não no legado [W ao vivo] | `feeAmount`, `isInBps`, `chargeFeeBy`, `feeReceiver` [W]; slippage em bps ≤ 2000 | ativo |
| De¹ (ex-OpenOcean) | `open-api.de1.exchange/v4/{chain}/quote` | Não [W ao vivo] | `referrer`/`referrerFee` [P] | domínio antigo atrás de Cloudflare |
| LI.FI | `li.quest/v1/quote` | Opcional: 200 req/2 h sem key, 200/min com [W] | `integrator` + `fee` (fração) [W]; **LI.FI cobra 0,25% próprio e fica com parte do seu fee** [W] | EVM, Solana, BTC, Stellar (Soroban) [W] |
| CoW Protocol | `api.cow.fi/{rede}/api/v1` | Não [W ao vivo] | `appData.metadata.partnerFee{volumeBps ≤ 100, recipient}`; CoW retém 25%; pago semanalmente em WETH na Ethereum, ≥ 0,001; **só ordens a mercado** [W] | ETH, ARB, Base, Polygon, AVAX, BNB; **não OP** (404) [W] |
| Uniswap Trading API / UniswapX | `trade-api.gateway.uniswap.org/v1` | Sim, `x-api-key` [W] | `portionBips`/`portionAmount` ligado à key, pedir à Uniswap Labs; **não vem descontado da cotação** [W] | ativo |
| OKX DEX v6 | `web3.okx.com/api/v6/dex/aggregator/*` | Sim, HMAC (`OK-ACCESS-*`) [W] | `feePercent` (≤ 3 EVM, ≤ 10 SOL), `from/toTokenReferrerWalletAddress` [W] | EVM + Solana + **Tron** [W] |
| ~~Odos~~ | — | — | — | **encerrado 30/07/2026** [W] |
| Jupiter `/order` + `/execute` | `api.jup.ag/swap/v2` | keyless 0,5 RPS; Free 1 RPS; pagos até 150 [W] | `referralAccount` + `referralFee` 50–255 bps; **Jupiter fica com 20%** [W] | Ultra não é mais mantido [W] |
| **Jupiter `/build`** (recomendado) | `api.jup.ag/swap/v2/build` + `/tx/v1/submit` | idem | `platformFeeBps` + `feeAccount`; **sem corte da Jupiter** [W] | devolve *instruções*; o app monta a tx |

**Por ecossistema:**
- **XRPL:** nativo (`path_find`, livro de ofertas e AMM XLS-30). Não tem taxa de integrador nativa.
- **Stellar:** nativo (`/paths/strict-send|receive` e `PathPayment*`), mais Soroswap, StellarBroker, Aquarius (aceita taxa de integrador) [W] e LI.FI.
- **Tron:** OKX, Chainflip, THORChain e NEAR Intents. [W]

**Chave de API num app aberto.** Key embarcada é key pública. Provedores que exigem key (1inch, 0x, OKX, Uniswap, Jupiter pago, TronGrid) passam por um **proxy burro**:
- só acrescenta a key e repassa;
- não altera payload;
- não guarda IP nem endereço;
- limita por aparelho com App Attest.

O app valida tudo como se o proxy fosse hostil.

### 3.2 O meta-agregador

**Estrutura mínima:**

```
Quote { provider, kind(.evmTx|.eip712|.solIx|.solTx|.deposit(memo)),
        amountIn, expectedOut, minOut, integratorFee, providerFee,
        networkCost{gasUnits, maxFee, l1Fee}, approval{spender, amount}?,
        routeSources[], expiresAt, raw }
```

**Fan-out**
- Tudo em paralelo. Prazo mole de 1,5 s (mostra o que chegou) e duro de 4 s.
- Circuit breaker: 3 falhas tiram o provedor por 60 s.
- Cache de 10 s. **Na v1 (código):** pela intenção exata (a calldata carrega o valor), não por faixa.

**Comparação líquida**

`líquido = valor(saída) − gas×preço − taxa L1 − approval (se faltar) − fees ainda não descontados`

- Normalizar quem reporta fee fora da cotação: Uniswap `portion`, 0x `zeroExFee`, Kyber `currency_out`, os 0,25% da LI.FI.
- Converter gas para o token de saída com **uma única** fonte de preço, igual para todos.
- Intents (CoW, UniswapX) têm gas 0 para o usuário, mas o preenchimento é incerto: ranquear pelo `minOut`.

**Honestidade da cotação:** simular o top-1 e o top-2 (§3.5). Quem simula mais de X bps abaixo do que cotou é rebaixado. **Na v1 (código):** simula a escolhida, em duas fontes, no plano; a comparação da rodada é pelo mínimo decodificado.

**Âncora do mínimo (v1, código):** o `minOut` que o provedor escreve só é aceito ancorado fora dele. Com preço de referência (CoinGecko, ou a paridade entre dois stablecoins da lista), a cotação mais de 5% pior bloqueia e acima de 2% avisa. Sem referência, pelo menos duas cotações válidas, e só é escolhida a que garante o mínimo calculado da maior estimativa entre elas (`TradeValidator.anchored`).

### 3.3 Divisão entre provedores

**Quando vale a pena**
- Impacto de preço acima de ~30 bps.
- Provedor com liquidez exclusiva (RFQ ou market makers: 0x RFQ, JupiterZ, resolvers de Fusion).
- Rota cross-chain com teto de capacidade.

Os agregadores já dividem entre DEXes internamente.

**Algoritmo**
1. Pegar os 3 melhores provedores de cotação única e cotar cada um em {25, 50, 75, 100}% do valor (12 chamadas).
2. Montar uma curva côncava por provedor: `líquido_p(x)` interpolado, com custo fixo `c_p` = gas do swap + approval extra, só se x > 0.
3. Rodar um DP em passos de 5%: `best[k][s] = max_a best[k−1][s−a] + f_k(a) − c_k·[a > 0]`.
4. Aceitar a divisão só se o ganho sobre o melhor único for ≥ max(10 bps, US$ 5), já descontado o gas extra.
5. Recotar cada perna no valor exato, validar (§3.5) e executar.

**Liquidez correlacionada.** Cotações de agregadores diferentes costumam bater nos **mesmos pools**. A perna 1 move o preço da perna 2, e a soma das frações cotadas é uma ilusão. Por isso:
- divida só quando as `routeSources` forem disjuntas;
- **recote a perna 2 depois de a perna 1 confirmar**, com um `minOut` próprio.
- **Na v1 (código):** as pernas são recotadas no plano, cada uma com o seu `minOut`, e montadas num plano só (`TradePlanner.combineSplit`), com nonces seguidos e assinadas de uma vez. A revisão diz que são transações independentes; a perna 2 não espera a 1 confirmar.

**Atomicidade**

| Rede | Atomicidade possível |
|---|---|
| EVM | **Nenhuma.** Não haverá router próprio (contrato da empresa = superfície de custódia e auditoria) nem 7702. |
| Solana | Dá para juntar instruções do `/build` num único tx v0 se couber. É atômico. |
| Stellar | Várias operações de path payment num único tx. É atômico. |
| XRPL | Sequencial até o Batch existir. |

**Se a perna 2 falha** (revert, expirou ou o preço passou do `minOut`), o dono fica com parte no token novo e o resto no antigo. Não perde nada além do gas, mas não fez o swap inteiro. Isso é dito **antes** de começar ("2 transações; se a segunda falhar você fica com ~60% em X e 40% em Y"). Depois vem a oferta de recotar. Não existe rollback.

**Plano de assinaturas.** O app mostra o plano inteiro antes de começar e pede presença do dono por tx. Assina just-in-time (cotação e nonce mudam), persiste os bytes assinados e zera a chave ao fim do plano.
- Approval exato → swap (EVM).
- Approval ao VaultRelayer + ordem EIP-712 (CoW).
- `ChangeTrust` + path payment no **mesmo** tx (Stellar, 1 assinatura).
- `TrustSet` → pagamento (XRPL).
- Criação de ATA dentro do tx (Solana).

### 3.4 Ordens limite

| Rede | Protocolo | O que se assina | Cancelar | Expiração | Taxa do integrador |
|---|---|---|---|---|---|
| ETH, ARB, Base, POL, AVAX, BNB | **CoW** | EIP-712, domain `{name "Gnosis Protocol", version "v2", chainId, verifyingContract 0x9008D19f58AAbD9eD0D60971565AA8510560ab41}`; `Order(sellToken, buyToken, receiver, sellAmount, buyAmount, uint32 validTo, bytes32 appData, feeAmount = 0, string kind, bool partiallyFillable, string sellTokenBalance, string buyTokenBalance)`. Pré-requisito: `approve(VaultRelayer 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110, exato)` [P campos; W endereços] | off-chain assinado (grátis, não garantido) ou `invalidateOrder(uid)` on-chain (garantido) [P] | `validTo` | **nenhuma** (partner fee não vale para limite) [W] |
| EVM, inclusive OP | **1inch LOP v4** | EIP-712, domain `{"1inch Aggregation Router", "6", chainId, 0x111111125421cA6dc452d289314280a0f8842A65}`; `Order(salt, maker, receiver, makerAsset, takerAsset, makingAmount, takingAmount, makerTraits)`. makerTraits = expiração (40 bits), nonce/epoch, allowedSender, flags. **Com `HAS_EXTENSION`, conferir `salt` low160 = keccak(extension)**, porque a extensão pode ter interações arbitrárias [P] | `cancelOrder(makerTraits, orderHash)` on-chain | em makerTraits | extensão de fee [P]; orderbook exige key |
| Solana | ~~Trigger v2~~ (custodial) [W] | — | — | — | — |
| Solana | Trigger v1 (programa com escrow on-chain; só recebe atualizações críticas) [W] | tx que cria a ordem e deposita no escrow | tx que fecha e devolve | na ordem | `feeBps` + `feeAccount` [W] |
| XRPL | `OfferCreate` nativo | `TakerGets`/`TakerPays`, `Expiration` (s desde 01/01/2000), flags `tfSell`/`tfPassive`/`tfImmediateOrCancel`/`tfFillOrKill`; reserva de 0,2 XRP | `OfferCancel{OfferSequence}` | `Expiration` | não há |
| Stellar | `ManageSellOffer`/`ManageBuyOffer` | preço n/d; reserva de 0,5 XLM; trava saldo | amount = 0 com o `offerID` | **não existe**: a oferta vive até cancelar, e o app tem que lembrar | não há |
| BTC / cross | THORChain `=<` (limite em fila, com TTL) [W]; Chainflip `min_price` + `retry_duration` [W] | memo / parâmetros de refund | expira sozinho | TTL | afiliado / broker |

- **Na v1 (código):**
  - CoW: validade de 1 hora a 30 dias, ou "até cancelar" = 364 dias (o livro da CoW recusa acima de um ano: `default_max_order_validity_period` em cowprotocol/services), com a data na revisão. Cancelamento pela CoW (sem garantia) ou `invalidateOrder` (garantido). Uma ordem aberta por token vendido.
  - 1inch LOP e Solana: fora.
  - XRP Ledger: `OfferCreate` com `Expiration` opcional (sem ela, até cancelar), `OfferCancel`. **Desligado enquanto a lista curada não tiver token do XRP Ledger**, porque a DEX só troca com token da lista.
  - Stellar: só `ManageSellOffer`, sem prazo. A carteira não precisa lembrar das ofertas: o motor lista as abertas lendo as duas Horizons e cancela com os ativos lidos da rede.
  - O `TradeEngine` expõe `openOrders(account:)` e `planCancel(...)` para a tela de ordens abertas.
- **Permit2** (UniswapX, 0x-Permit2) [P]:
  - domain `{name "Permit2", chainId, verifyingContract 0x000000000022D473030F116dDEE9F6B43aC78BA3}`, sem versão.
  - `PermitTransferFrom(TokenPermissions{token, amount}, spender, nonce, deadline)`; a variante *Witness* tem spender = reactor.
  - `PermitSingle(PermitDetails{token, uint160 amount, uint48 expiration, uint48 nonce}, spender, sigDeadline)`.
  - Cancelar: `invalidateUnorderedNonces`.
  - Não usar UniswapX para limite na v1 [P].
- **Monitorar:**
  - CoW: `GET /api/v1/orders/{uid}`.
  - XRPL: `account_offers` + `subscribe`.
  - Stellar: `/accounts/{id}/offers`.
  - Push exigiria um watcher que conhece endereços. Deixar opcional e explicado.
- **Solana não custodial numa v2:** tx pré-assinada com nonce durável e `minOut` = preço limite, que um watcher só transmite. Cancelar = avançar o nonce.

### 3.5 Validações obrigatórias antes de assinar (fail-closed)

**EVM**
1. `chainId` confere; `from` é o dono; `to` ∈ allowlist[rede][provedor] e tem código.
2. Seletor ∈ allowlist de seletores do router, gerada do ABI verificado.
3. Decodificar os campos que importam:
   - 1inch: `SwapDescription` (src, dst, dstReceiver, amount, minReturn, flags).
   - Kyber: `desc` (dstReceiver, minReturnAmount, feeReceivers).
   - Velora 6.2: `GenericData` (toAmount, beneficiary) e `partnerAndFee`.
   - 0x: `exec(operator, token, amount, target, data)` com `target` = Settler atual, e `AllowedSlippage{recipient, buyToken, minAmountOut}`.
4. Conferir:
   - destinatário = dono;
   - tokens e valores = os da tela;
   - `minOut` ≥ o mínimo que o **app** calculou;
   - deadline ≤ 10 min (na v1, 20 min quando o router tem prazo; nenhum dos quatro routers da v1 tem, e a revisão diz para cancelar com o mesmo nonce);
   - recebedor da taxa = endereço da empresa **e** bps = configurado.
5. `value` = 0 para venda de token, = amountIn para venda do nativo. Taxa nativa de bridge só se estiver declarada e aparecer na tela.
6. Ignorar gas e gasPrice sugeridos pelo provedor; estimar por conta própria.
7. **Simular** com `eth_simulateV1` + `traceTransfers`:
   - o token vendido do dono cai ≤ amountIn;
   - o token comprado sobe ≥ `minOut`;
   - nenhum outro ativo se move;
   - nenhum `Approval` novo.

   Drainers detectam simulação, então isto é a segunda camada, não a única.
8. **Approval:** `approve(spender_allowlist, valor exato)`. Nunca infinito por padrão. Tela de revogação, inclusive de routers que morreram (Odos).
9. **EIP-712 de terceiros:**
   - `verifyingContract` na allowlist e `chainId` conferido;
   - `primaryType` conhecido;
   - receiver = dono;
   - valores iguais aos da tela;
   - prazos limitados;
   - **CoW: recusar `appData` com `hooks`.**

**Allowlist [W]**

| Provedor | `to` | spender |
|---|---|---|
| 1inch | `0x111111125421cA6dc452d289314280a0f8842A65` | mesmo |
| 0x | AllowanceHolder `0x0000000000001fF3684f28c67538d4D072C22734` | mesmo. Settler via registry `0x00000000000004533Fe15556B1E086BB1A72cEae.ownerOf(2)`, lido de 2 RPCs; hoje na Ethereum é `0x666fEdd4CDD4E890A5AD20e7b60975409435a64a` [W ao vivo]. Aceitar `prev()` durante o dwell |
| Velora 6.2 | `0x6a000f20005980200259b80c5102003040001068` | mesmo |
| Kyber | `0x6131B5fae19EA4f9D964eAc0408E4408b66337b5` | mesmo |
| LI.FI | Diamond `0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE` (algumas redes diferem) | `estimate.approvalAddress` ∈ allowlist |
| CoW | Settlement `0x9008D1…ab41` | VaultRelayer `0xC92E8b…e0110` |
| UniswapX | ETH V2 `0x00000011F84B9aa48e5f8aA8B9897600006289Be`; Base Priority `0x000000001Ec5656dcdB24D90DFa42742738De729`; Base V3 `0x000000008a8330B5d1F43A62Bf4C673A49f27ba0` | Permit2 |
| OKX (router / approve) | ETH `0x8feab81d…b4f6` / `0x40aA958d…bcD7f`; ARB `0x09f94b5f…c849` / `0x70cBb871…2F58`; Base `0x67d03631…81df` / `0x57df6092…114E`; OP `0x1f5b4312…24d0` / `0x68D6B739…4812`; POL `0x3c482919…d41c` / `0x3B869173…4e31`; BNB `0x5994814f…4dec` / `0x2c34A2Fb…cDD6`; AVAX `0xab96dcfa…dd0a` / `0x40aA958d…bcD7f`; SOL `proVF4pMXVaYqmy4NjniPh4pqKNfMmsihgd4wdkCX3u`; Tron `TTWd2hBK…m8N4` / `THRAE2Vh…1XL8` | — |
| THORChain (EVM) | lido em runtime de `inbound_addresses` em 2 fontes e comparado com a allowlist. Hoje: ETH `0xD37BbE5744D730a1d98d8DC97c42F0Ca46aD7146`, BSC `0xb30ec53f…f56b`, BASE/AVAX `0x00dc6100…f1d4` [W ao vivo] | router |

- A allowlist vive **no binário**. A config remota só pode **desligar** provedor, nunca acrescentar endereço.
- **Na v1 (código):** só Velora, KyberSwap, LI.FI e De¹ (`TradeAllowlist`) e a CoW. 1inch, 0x, UniswapX e OKX exigem key e ficam de fora.

**Solana**
1. Preferir `/build` (o app monta a tx).
2. Se vier tx pronta:
   - resolver as ALTs lendo a cadeia;
   - fee payer = dono;
   - programas no topo ∈ {Jupiter v6 `JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4` [P], OKX, Token, Token-2022, ATA, ComputeBudget, System};
   - **teto de prioridade e de tip**;
   - recusar `SetAuthority`, `Approve` a delegado estranho, `CloseAccount` com destino ≠ dono, `Transfer` de SOL a desconhecido e `AdvanceNonce`.
3. `simulateTransaction` com `accounts` das contas de token do dono e diff pré/pós. **Na v1 (código):** o dono, as duas contas da troca e as contas de token do dono nos mints da lista, que não podem perder saldo. Preço de referência do oráculo do app, com os degraus da EVM; par que não é de dois stablecoins da lista, sem referência, é recusado.

**Cross-chain**
- Endereço de destino e de refund = endereços que **o app derivou**.
- Inbound e router lidos de 2 thornodes e comparados entre si.
- Rede sem halt; amount ≥ `recommended_min_amount_in`.
- Memo parseado e conferido: destino, limite, afiliado = THORName da empresa, bps.
- Cotação com menos de 10 min; **nunca cachear inbound**. [W]

**XRPL e Stellar:** o app monta a tx. O limite é `SendMax`/`DeliverMin` ou `destMin`. Evitar `tfPartialPayment` fora de swap. **Stellar na v1 (código):** a cotação vem das duas Horizons (as duas têm de responder) e o `destMin` sai da maior; a rota só passa por XLM e ativos da lista; com preço de referência, os degraus da EVM.

### 3.6 BTC e cross-chain

| | THORChain | Chainflip | NEAR Intents 1Click | LI.FI |
|---|---|---|---|---|
| Nossas redes | BTC, ETH, BSC, BASE, AVAX, XRP, TRON; SOL *halted* hoje [W ao vivo] | BTC, ETH, ARB, SOL, BSC, **TRON** (TRX, USDT) [W] | BTC, XRP, Stellar, Tron, SOL, EVMs (197 tokens) [W ao vivo] | EVM, SOL, BTC |
| Endpoint | `gateway.liquify.com/chain/thorchain_api/thorchain/quote/swap` [W] | Broker RPC / SDK / BaaS `chainflip-broker.io` [W] | `1click.chaindefuser.com/v0/{tokens, quote, deposit/submit, status}` [W] | `li.quest` |
| Taxa do integrador | `affiliate` (THORName) + `affiliate_bps` 0–1000, paga em RUNE [W] | comissão do broker 0–1000 bps em USDC no State Chain [W] | `appFees` ≤ 500 bps no total; sem JWT soma +25 bps; com JWT divide 50/50 [W] | `fee` [W] |
| Envio | vault + memo: BTC por OP_RETURN (≤ 80 bytes) [W]; EVM por `depositWithExpiry` no router [P] | vault swap (usuário chama o vault) ou canal de depósito (**o broker paga FLIP**) [W] | endereço de depósito por cotação | tx do provedor (**em BTC não altere o tx data** [W]) |
| Risco | TSS (exploit mai/2026), halts, memo errado = perda | vaults de threshold; refund por `min_price` | confiança no operador do bridge entre depósito e liquidação [P/inferência] | bridge subjacente |

- Memo do THORChain: `=:ASSET:DEST[/REFUND]:LIM/INTERVAL/QTY:AFF:BPS`, até 5 afiliados. [W]
- **Recomendação:**
  - BTC ↔ EVM/SOL: Chainflip por vault swap e THORChain quando não estiver halted, comparando `minOut`.
  - XRP, Stellar e Tron: NEAR Intents como terceira via.
  - EVM ↔ EVM/SOL: LI.FI.

### 3.7 "Sem prejuízo para a empresa"

Regras duras:
- A empresa não custodia, não adianta gas, não patrocina energy ou gas e não garante cotação.
- A tela mostra o **mínimo garantido**, não o estimado.
- A taxa sai só pelo mecanismo nativo do protocolo, direto para um endereço da empresa por rede.

| O que pode dar errado | Como evitar |
|---|---|
| Endereço de taxa comprometido ou perdido (perde receita, não fundo do usuário) | Multisig/cold por rede, no binário, com rotação por release |
| Proxy ou provedor redireciona a taxa ou cobra mais que o mostrado | A validação confere recipient e bps (§3.5) |
| Key vazada do binário vira abuso ou ban | Proxy + App Attest; nenhuma key no app |
| Taxa cobrada em token lixo ou honeypot | Cobrar só em ativo da lista curada (`swapFeeToken`, `chargeFeeBy`, fee mint da Jupiter restrito a SOL/USDC/USDT); senão, sem taxa |
| Contas de fee na Solana custam rent (a empresa adianta uma vez) | Só 3 mints; o rent caiu |
| Canal de depósito da Chainflip pago em FLIP | Vault swap ou BaaS |
| THORName expira e a taxa se perde | Monitorar e renovar, ou usar endereço RUNE |
| Cortes dos provedores: CoW 25% (e nada em limite), Jupiter `/order` 20%, LI.FI parte + 0,25% ao usuário, 1Click 50/50 | Modelar a receita líquida; preferir o `/build` da Jupiter |
| Fee-on-transfer com taxa do integrador falha sempre | Detectar e tirar a taxa ou o provedor; simular |
| Provedor morre (Odos) ou redeploya (Settler) | Kill-switch que só desliga; fallback; revogação na UI |
| Router explorado com approvals infinitos (LI.FI jul/2024, Socket jan/2024) [P] | Approval exato |
| Regulatório: cobrar taxa por intermediar swap pode enquadrar a empresa como PSAV (Lei 14.478/2022; Res. BCB 519/520/521 em vigor desde 02/02/2026 [W]) | **Parecer jurídico antes de ligar a taxa** |

### 3.8 Veredito por ameaça (camada de assinatura e swap)

| Ameaça | Segura? | Por quê |
|---|---|---|
| Ladrão com o aparelho desbloqueado | Sim, **se** cada plano exigir presença (`.biometryCurrentSet`, sem janela de reuso) e nenhuma chave ficar em memória entre planos | Uma "sessão de swap" aberta derruba isso |
| Malware com root | Não | Lê memória na hora de assinar e troca a UI; as mitigações só estreitam a janela |
| API, proxy ou agregador malicioso | Sim, com a §3.5 fail-closed | A perda máxima fica limitada pelo `minOut` (slippage) |
| RPC mentiroso | Parcial | Nonce, saldo e allowance cruzados em 2 fontes; input legado BTC seguro só com a tx anterior verificada |
| Envenenamento de endereço / clipboard | Parcial | Solana sem checksum é o pior caso: address book e aviso de primeiro envio |
| Coerção | Parcial | Passphrase = carteira oculta. A isca precisa de saldo real porque é pública on-chain. Vale para patrimônio alto; para o resto é complexidade |
| Forense | Depende do cache | Histórico de swaps e address book revelam patrimônio sem a seed: cifrar com Keychain `ThisDeviceOnly` e não guardar cotações |

---

## 4. Em aberto, a confirmar antes de codar

- O que são as "16 palavras" do Xaman.
- Caminho BIP-39 do Xaman e da Lobstr para XRP.
- Algoritmo exato do caminho Sollet.
- Parâmetros de taxa do 1inch v6.1 (`fee`/`referrer`) e da De¹.
- Se a BSC aceita tipo 2 de forma estável.
- Endereços UniswapX V3 em ARB/AVAX/BNB.
- ID do programa do Trigger v1.
- Campos EIP-712 do CoW e do 1inch LOP no código-fonte.
- Status final do Batch da XRPL após 29/09.

**Arquivos lidos:**
- `/Users/thomazjr/projects/escalibur/Escalibur/Vault/Mnemonic.swift`
- `/Users/thomazjr/projects/escalibur/Escalibur/Vault/Wordlist.swift`
- `/Users/thomazjr/projects/escalibur/Escalibur/Vault/SLIP39.swift`
- `/Users/thomazjr/projects/escalibur/Escalibur/Crypto/SelfTest.swift`
- `/Users/thomazjr/projects/escalibur/Escalibur/Crypto/VaultFile.swift`
- `/Users/thomazjr/projects/escalibur/Escalibur/Crypto/LiveCipher.swift`
- `/Users/thomazjr/projects/escalibur/docs/formato.md`
- `/Users/thomazjr/projects/escalibur/wordlists.lock`

---

### Fontes
- [XRPL Reserves](https://xrpl.org/docs/concepts/accounts/reserves) · [XRPL Public Servers](https://xrpl.org/docs/tutorials/public-servers) · [XRPL fee](https://xrpl.org/docs/references/http-websocket-apis/public-api-methods/server-info-methods/fee) · [Batch: CryptoSlate](https://cryptoslate.com/xrpl-fixes-critical-pre-mainnet-flaw-but-client-apps-remain-at-risk/) · [Xaman: import com mnemônica](https://help.xaman.app/app/getting-started-with-xaman/importing-your-account/...with-a-mnemonic)
- [Stellar RPC providers](https://developers.stellar.org/docs/data/apis/rpc/providers) · [Horizon providers](https://developers.stellar.org/docs/data/apis/horizon/providers) · [SDF Horizon com 1 ano](https://stellar.org/blog/foundation-news/sdf-s-horizon-limiting-data-to-1-year) · [Allium: migração Horizon para RPC](https://docs.allium.so/changelog/deprecated-stellar-v1) · [Protocol 28](https://cryptoticker.io/en/stellar-xlm-price-jump-check/) · [SEP-0005](https://github.com/stellar/stellar-protocol/blob/master/ecosystem/sep-0005.md) · [SEP-0029](https://github.com/stellar/stellar-protocol/blob/master/ecosystem/sep-0029.md)
- [Solana clusters](https://solana.com/docs/references/clusters) · [Reduced rent](https://solana.com/upgrades/reduced-rent) · [Tx v1](https://xroot.dev/blog/solana-transaction-v1) · [Larger tx](https://solana.com/upgrades/larger-transaction-sizes) · [Transaction pipeline / dedup](https://solana.com/docs/core/transactions/transaction-pipeline) · [Phantom: derivation paths](https://help.phantom.com/hc/en-us/articles/12988493966227-Supported-derivation-paths-in-Phantom) · [Trust wallet-core #4446](https://github.com/trustwallet/wallet-core/issues/4446) · [Magic Eden: derivation](https://help.magiceden.io/en/articles/10113666-understanding-derivation-paths-and-compatibility-modes-in-the-magic-eden-app)
- [Exodus: derivation paths](https://www.exodus.com/support/en/articles/8598933-derivation-paths-in-exodus) · [Ripple Custody: key derivation](https://docs.ripple.com/products/custody/accounts-and-assets/accounts/account-key-derivation-and-ledger-compatibility)
- [Bitcoin Core: minrelay 0,1](https://cointelegraph.com/news/bitcoin-core-default-minimum-relay-fees-decreases-90-as-update-rolls-out) · [Spark: comparação de APIs BTC](https://www.spark.money/tools/bitcoin-api-comparison) · [mempool.space API](https://mempool.space/docs/api/rest)
- [EIP-7825 / Fusaka](https://blog.ethereum.org/2025/10/21/fusaka-gascap-update) · [BNB 0,05 gwei](https://x.com/BNBCHAIN/status/1973334261513031828) · [Polygon gas](https://docs.polygon.technology/tools/gas/polygon-gas-station) · [Chainstack: polygon-rpc](https://chainstack.com/public-polygon-rpc-complete-endpoint-catalogue/) · [EIP-7702 phishing](https://dev.to/ohmygod/the-crimeenjoyor-epidemic-how-eip-7702-delegation-phishing-drained-450k-wallets-and-how-to-detect-it-on-chain-e2g) · [NewsBTC: 7702](https://www.newsbtc.com/news/eip-7702-wallet-delegation-phishing-research/)
- [TronGrid: rate limits](https://developers.tron.network/reference/rate-limits) · [Taxas Tron 2026](https://geekvibesnation.com/tron-fees-2026-50-percent-cut/) · [Tronsave: taxas](https://blog.tronsave.io/tron-network-fees-cut-usdt-transfer-costs/)
- [1inch Classic Swap](https://business.1inch.com/portal/documentation/apis/swap/classic-swap/quick-start) · [yldfi PR #74](https://github.com/yldfi/yldfi-rs/pull/74) · [yldfi PR #81](https://github.com/yldfi/yldfi-rs/pull/81) · [1inch orderbook](https://business.1inch.com/portal/documentation/apis/orderbook/quick-start)
- [0x FAQ](https://docs.0x.org/docs/introduction/faq) · [0x-settler](https://github.com/0xProject/0x-settler)
- [Velora API v6.2](https://developers.velora.xyz/api/velora-api/velora-market-api/master/api-v6.2) · [Velora Augustus v6.2](https://help.velora.xyz/en/articles/9457461-augustus-v6-2-improved-security-trading-and-developer-experience)
- [KyberSwap EVM swaps](https://docs.kyberswap.com/developer-guide/aggregator-api/aggregator-api-specification/evm-swaps) · [De¹](https://de1.exchange/)
- [LI.FI: taxas](https://docs.li.fi/monetization-take-fees) · [LI.FI: rate limits](https://docs.li.fi/rate-limits-and-api-key) · [LI.FI: contratos](https://docs.li.fi/introduction/lifi-architecture/smart-contract-addresses) · [Vultisig #2396](https://github.com/vultisig/vultisig-sdk/issues/2396)
- [CoW: partner fee](https://docs.cow.fi/governance/fees/partner-fee) · [CoW: VaultRelayer](https://docs.cow.fi/cow-protocol/reference/contracts/core/vault-relayer)
- [Uniswap quote API](https://api-docs.uniswap.org/api-reference/swapping/quote) · [UniswapX deployments](https://developers.uniswap.org/docs/liquidity/uniswapx/deployments)
- [OKX: adicionar taxas](https://web3.okx.com/build/dev-docs/dex-api/dex-api-addfee) · [OKX: contratos](https://web3.okx.com/onchainos/dev-docs/trade/dex-smart-contract)
- [Odos: encerramento](https://crypto.news/odos-shuts-down-july-30-as-defi-aggregator-ends-all-services/)
- [Jupiter docs index](https://developers.jup.ag/docs/llms.txt) · [Jupiter order & execute](https://developers.jup.ag/docs/swap/order-and-execute.md) · [Jupiter build](https://developers.jup.ag/docs/swap/build/index.md) · [Jupiter Trigger](https://developers.jup.ag/docs/trigger/index.md) · [Jupiter planos](https://developers.jup.ag/docs/portal/plans.md)
- [THORChain quickstart](https://dev.thorchain.org/swap-guide/quickstart-guide.html) · [THORChain memos](https://dev.thorchain.org/concepts/memos.html) · [Exploit THORChain](https://www.coindesk.com/tech/2026/05/15/thorchain-halts-trading-after-usd10-million-cross-chain-exploit-rune-token-drops-12) · [Retomada](https://crypto.news/thorchain-trading-resumes-after-10-7m-exploit-and-month-long-halt/)
- [Chainflip brokers](https://docs.chainflip.io/brokers) · [Chainflip broker API](https://docs.chainflip.io/brokers/broker-api) · [Chainflip chains](https://docs.chainflip.io/protocol/supported-chains-assets/chains-assets) · [Chainflip BaaS](https://docs.chainflip-broker.io/)
- [NEAR 1Click](https://docs.near-intents.org/near-intents/integration/distribution-channels/1click-api) · [NEAR app fees](https://docs.near-intents.org/near-intents/integration/distribution-channels/1click-app-fees-calculation)
- [Swaps na Stellar](https://stellarplaybook.com/defi-on-stellar/swaps/) · [Soroswap aggregator](https://docs.soroswap.finance/01-concepts/aggregator)
- [CryptoKit Curve25519](https://developer.apple.com/documentation/cryptokit/curve25519/signing) · [Assinatura EdDSA aleatorizada](https://github.com/WICG/webcrypto-secure-curves/issues/28)
- [Resoluções BCB 519/520/521: Mattos Filho](https://www.mattosfilho.com.br/unico/normas-regulamentacao-ativos-virtuais/)