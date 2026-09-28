# Escalibur Wallet

Carteira cripto não custodial para iPhone. SwiftUI nativo, código aberto, feita para ser auditada.

As chaves ficam no iPhone do dono. Não existe conta, e-mail nem servidor que guarde senha. A Escalibur não tem como ver, mover nem recuperar o saldo de ninguém.

## Redes

Bitcoin, Litecoin, Dogecoin, Ethereum, Base, Arbitrum, Optimism, Polygon, BNB Chain, Avalanche, Plasma, X Layer, Linea, Unichain, Sonic, Celo, Solana, XRP Ledger, Stellar, Tron, TON, Sui, Cardano, Polkadot, NEAR e Aptos. Cada carteira é uma frase BIP-39, derivada pelos caminhos padrão de cada rede. Por isso a mesma frase abre a carteira em Ledger, Trust Wallet, MetaMask, Phantom, Xaman, Lobstr, Tonkeeper, Slush, Eternl, Yoroi, Lace, MyNearWallet e Petra. Na Polkadot a conta é a da Trust Wallet (ed25519); Polkadot.js, Nova, Talisman e Ledger derivam outra. Em Sui, Cardano, Polkadot, NEAR e Aptos o envio é só da moeda nativa; o que cada uma deixa de fora está em `docs/redes/`.

Enviar funciona em todas, e ver o histórico em todas menos BNB Chain, X Layer e Sonic (sem indexador público sem chave). Trocar funciona nas redes EVM (menos Avalanche, X Layer e Celo), Solana, XRP Ledger (XRP e RLUSD, pelo livro da própria rede) e Stellar; ordem limite pela CoW na Ethereum, Arbitrum, Base, Polygon, BNB Chain, Plasma e Linea, e nativa no XRP Ledger e na Stellar, com prazo ou até cancelar, e tela de ordens abertas para cancelar. O que cada rede faz e onde para está em [`docs/redes/motores.md`](docs/redes/motores.md).

## O que este app promete, e o que não promete

Não existe "impenetrável", e a palavra não aparece no app. O que existe é custo, e cada defesa diz quanto custa quebrá-la e onde ela para. O modelo de ameaça completo, com os riscos aceitos e os números, está em [`docs/seguranca.md`](docs/seguranca.md).

- **A frase nunca sai do aparelho em claro.** Cifrada, ela só sai por ação explícita do dono, num envelope com senha própria.
- **Não existe verificador de PIN gravado em lugar nenhum.** A chave raiz vai cifrada por uma chave derivada do PIN (Argon2id de 256 MiB), dentro de um embrulho que só abre neste Secure Enclave, num item do chaveiro protegido também pela senha de aplicativo. Se a senha de aplicativo for só uma regra de acesso (o teste em iPhone físico ainda está pendente), a camada derivada do PIN continua valendo sozinha. Face ID usa `biometryCurrentSet`: cadastrar outro rosto destrói o atalho em vez de abri-lo.
- **Uma chave por carteira.** A chave raiz desembrulha só a chave da carteira que vai assinar. Guarda-se a entropia, não as palavras.
- **Nada é assinado às cegas.** A rede monta a transação e diz o que assinar. O assinador aceita apenas um plano que passou pela validação: destino, valor, taxa com teto, tag e memo exigidos pela própria rede, e calldata decodificada contra uma allowlist compilada. A assinatura é verificada antes de sair.
- **Nenhum provedor decide nada.** `chainId`, passphrase de rede, contratos de token, routers e emissores são constantes compiladas. Nonce e sequence exigem dois provedores concordando.

## O envelope Escalibur

A carteira lacra e abre o mesmo arquivo `.esclbr` do app [Escalibur](../escalibur): Argon2id, ChaCha20-Poly1305, quatro compartimentos e formato aberto. Um envelope lacrado aqui abre no Escalibur e no decifrador de referência em Python. Um envelope lacrado por outro programa, escrito só a partir da especificação (`tools/lacrar-referencia.py`), abre aqui. Os testes conferem os dois sentidos.

## Construir e conferir

```
cd Kit && swift test                 # mais de 900 testes: vetores oficiais de cada rede e respostas gravadas dos provedores
./tools/verificar.sh --testes        # as afirmações acima, conferidas por script
xcodegen generate                    # gera EscaliburWallet.xcodeproj a partir de project.yml
xcodebuild -project EscaliburWallet.xcodeproj -scheme EscaliburWallet -sdk iphonesimulator build
```

`ESCALIBUR_REDE=1 swift test` roda também os testes contra os nós reais: saldos, preços, e a lista de tokens conferida na própria cadeia.

## Estrutura

```
Kit/                         o núcleo, em Swift Package, testado no Mac
  Sources/CSecp256k1         libsecp256k1 v0.8.0 do bitcoin-core, do fonte, travada em secp256k1.lock
  Sources/CArgon2            Argon2 de referência, do fonte, travado em argon2.lock
  Sources/EscaliburCore      buffer seguro, hashes, curvas, BIP-39, codificações, envelope
  Sources/EscaliburChains    endereços, transações e validação de cada rede. Sem rede, sem chave
  Sources/EscaliburKeys      chaveiro, Secure Enclave, derivação e o assinador
  Sources/EscaliburNetwork   provedores com contingência, preços, saldos. Nunca vê segredo
App/EscaliburWallet          o app SwiftUI
docs/                        segurança, blockchain, produto, sistema visual, uma página por rede
tools/verificar.sh           as verificações que valem por afirmação pública
```

## Dependências

Nenhuma remota. Todo código de terceiro está no repositório, compilado do fonte e travado por digesto: libsecp256k1 (MIT) e Argon2 (CC0/Apache 2.0). Keccak, SHA3-256, BLAKE2b (a referência que vem com o Argon2), Ed25519 com chave estendida (porte do TweetNaCl, para a Cardano), RIPEMD-160, Bech32, BCS, Borsh, SCALE, CBOR, RLP, XDR, protobuf, células da TON e o codec binário do XRP Ledger foram escritos aqui, e cada um tem os vetores oficiais nos testes.
