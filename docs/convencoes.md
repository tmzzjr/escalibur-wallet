# Convenções de código da Escalibur Wallet

Vale para qualquer pessoa ou agente que escreva código neste repositório.

## Módulos (Kit/Package.swift)

| Módulo | Pode | Não pode |
|---|---|---|
| `EscaliburCore` | primitivas: `SecureBytes`, hashes, curvas, Argon2id, BIP-39, codificações, envelope `.esclbr` | rede; `print`; aleatoriedade fora de `SecRandomCopyBytes` |
| `EscaliburChains` | endereços, transações, serialização, validação do que se assina, `SigningPlan` | rede; chave privada; `SecureBytes` com segredo; chamar `Secp256k1.sign*` ou `Ed25519.sign` |
| `EscaliburKeys` | chaveiro, Secure Enclave, `HDKey`, assinador | rede; logger |
| `EscaliburNetwork` | `URLSession` efêmera, provedores, RPC, preços | importar `EscaliburKeys`; ver `SecureBytes`, frase, PIN, senha |

## O contrato de assinatura (EscaliburChains/Signing.swift)

1. Cada rede tem um tipo que conforma a `SignableTransaction`:
   - `signingRequests` diz, na ordem, o que precisa ser assinado: caminho, curva, esquema, payload calculado **localmente** e a chave pública esperada.
   - `assemble(with:)` recebe as assinaturas na mesma ordem e devolve `SignedTransaction` (bytes crus, forma de transmissão, id).
2. Nenhuma rede assina. O assinador (`EscaliburKeys`) deriva a chave, confere a chave pública esperada, assina, **verifica** a assinatura e devolve.
3. Transações só chegam ao assinador dentro de um `SigningPlan`, cujo inicializador é `package`. Cada família expõe funções públicas de planejamento (`plan...`) que recebem a intenção do dono e o estado da rede (dados públicos, vindos de fora) e **validam antes de montar**: tetos de taxa, reservas, dust, tag/memo obrigatórios, destino válido e diferente de armadilhas conhecidas.
4. O estado da rede (saldo, nonce, UTXOs, taxa, sequence, blockhash) entra como struct de dados puros, definida pela família. `EscaliburNetwork` preenche esses structs; `EscaliburChains` nunca busca nada.

## Testes

- Swift Testing (`import Testing`), um arquivo por família em `Kit/Tests/EscaliburChainsTests/`.
- **Todo formato binário tem vetor oficial**: fixtures da implementação de referência da rede (ripple-binary-codec, js-stellar-base, solana-web3.js, TronWeb, tonweb/ton-core, bitcoin BIPs, ethereum/tests). O comentário do teste cita a fonte (repo e arquivo). Fixtures grandes vão em `Kit/Tests/EscaliburChainsTests/Fixtures/<familia>/`.
- Ed25519 do CryptoKit é aleatorizado: compare a **mensagem** assinada byte a byte e verifique a assinatura; não compare assinatura Ed25519 com vetor.
- Para testar assinatura de ponta a ponta sem `EscaliburKeys`, use chaves de teste conhecidas dentro do teste (ex.: a chave privada do vetor) chamando `Secp256k1`/`Ed25519` do Core no próprio teste. Nunca em código de produção de `EscaliburChains`.
- `swift test --filter <NomeDaSuite>` roda só a sua parte.

## Estilo

- Identificadores em inglês; comentários e textos em português, no tom do Escalibur: explicam **por que**, citam o risco concreto que a linha evita.
- Nenhum texto que o usuário lê com travessão (— ou –).
- Sem `print`, `NSLog`, `dump` fora de testes.
- Sem dependência remota, sem framework binário. Código de terceiro só vendorizado com lock de SHA-256.
- Valores monetários sempre `BigUInt` nas unidades da rede (satoshi, wei, lamport, drop, stroop, sun, nanoton). Nunca `Double` em transação.
- Constantes de segurança (chainId, passphrase de rede, endereços de contrato, programas permitidos) são literais compilados, com comentário da fonte, e nunca vêm de resposta de rede.
