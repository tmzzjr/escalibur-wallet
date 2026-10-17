# Glossário de tradução

O catálogo (`App/EscaliburWallet/Resources/Localizable.xcstrings`) tem o português do Brasil
como origem e doze idiomas: en, es, fr, de, hi, zh-Hans, ja, ko, tr, id, vi, ar. Este arquivo
fixa os termos para que a mesma coisa tenha o mesmo nome em todas as telas. Em cada idioma, o
nome é o que as grandes carteiras usam nele (Trust Wallet, MetaMask, Coinbase Wallet, OKX
Wallet), nunca uma tradução literal que ninguém usa.

## Regras

- Os campos ficam: `%@`, `%lld`, `%llu`, `%u`, `%%`. A ordem pode mudar com posição
  (`%2$@ ... %1$@`). O conferidor (`tools/traducao/conferir.py`) recusa o que não bater.
- Espaço no começo ou no fim do original fica: o texto é colado em outro.
- Sem travessão nem meia-risca, em idioma nenhum. Reescrever a frase.
- Tom: frases curtas, diretas, de produto de consumo (como a Apple escreve). Sem
  exclamação, sem "por favor" sobrando, sem jargão onde há palavra comum.
- Tratamento: informal onde o idioma usa assim em app (en "you", es "tú", fr "vous",
  de "du", tr "sen"; ja, ko e zh no registro neutro e educado de app; ar no padrão
  moderno, masculino genérico como os apps fazem).
- Não se traduz: Escalibur, Escalibur Wallet, Face ID, Touch ID, Optic ID, iPhone,
  iCloud, App Store, Secure Enclave, GitHub, nomes de rede (Bitcoin, Ethereum, BNB Chain,
  Solana, XRP Ledger, Stellar, Tron, TON, Sui, Cardano, Polkadot, NEAR, Aptos...),
  símbolos (BTC, ETH, USDT, USDC...), provedores (CoW, Across, CCTP, Circle, Velora,
  KyberSwap, LI.FI, De¹, Jupiter, Alchemy, CoinGecko), padrões (BIP-39, EIP-712,
  ERC-20, TRC-20, Token-2022, SEP-0005), formatos (`.esclbr`).
- Palavras da frase de recuperação (BIP-39) nunca aparecem no catálogo: a lista é sempre
  a do padrão, em inglês, e não se traduz.

## Termos

| Português (origem) | English | Nota |
|---|---|---|
| senha da carteira (as 12 ou 24 palavras) | recovery phrase | O app chama assim para o leigo; nos idiomas, o termo das carteiras. |
| palavras (da senha da carteira) | words | |
| PIN | PIN | |
| frase de voz / confirmação por voz | voice phrase / voice confirmation | |
| Envelope Escalibur / envelope | Escalibur Envelope / envelope | Arquivo cifrado com a senha da carteira. |
| lacrar o envelope / abrir o envelope | seal the envelope / open the envelope | |
| senha do envelope | envelope password | |
| passphrase | passphrase | A 25ª palavra do BIP-39. |
| Carteira (aba) / carteira | Wallet / wallet | |
| Mercado (aba) | Market | |
| Trocar (aba) / troca | Swap / swap | |
| Atividade (aba) | Activity | |
| Ajustes (aba) | Settings | |
| Enviar / Receber | Send / Receive | |
| ordem limite | limit order | |
| ponte (entre redes) | bridge | |
| rede | network | |
| endereço | address | |
| tag de destino (XRP) | destination tag | Nas exchanges: "Destination Tag". |
| memo | memo | |
| comentário (TON) | comment | |
| taxa da rede | network fee | |
| taxa da Escalibur | Escalibur fee | |
| cotação | quote | |
| tolerância de preço | slippage | |
| impacto no preço | price impact | |
| mínimo garantido | minimum received | |
| provedor | provider | |
| autorização (approve) / autorizar | approval / approve | |
| sem limite (autorização) | unlimited | |
| revisar / revisão | review | |
| assinar / assinado | sign / signed | |
| transmitir | broadcast | |
| confirmação (da rede) | confirmation | |
| linha de confiança (XRPL, Stellar) | trustline | |
| reserva (XRPL, Stellar) | reserve | |
| conta de token (Solana) | token account | |
| mint (Solana) | mint | |
| emissor | issuer | |
| contrato | contract | |
| golpe | scam | |
| suspeito | suspicious | |
| verificado | verified | |
| moeda custom | custom token | |
| só observar | watch-only | |
| aviso de recebimento | incoming alert | |
| alerta de preço | price alert | |
| apagar depois de PINs errados | erase after failed PINs | |
| modo reforçado | Hardened mode | PIN e Face ID juntos para tudo, pela criptografia (docs/seguranca.md §2.6) |
| saldo | balance | |
| explorador da rede | block explorer | |

## Termos fixados na tradução para o inglês (15/10/2026)

| Português (origem) | English | Nota |
|---|---|---|
| montar (o envio, a troca) | prepare | "Nada foi montado" = "Nothing was prepared" |
| Nada foi debitado / Nada saiu da conta | Nothing was debited / Nothing left the account | |
| Confira a Atividade | Check Activity | |
| conferir / não confere | check / doesn't match | |
| teto (da carteira, de segurança) | cap | "safety cap" |
| na cadeia | on-chain | |
| envio (substantivo) | transfer | Botão e aba: Send |
| recebimento | incoming transfer | |
| moeda (inclusive UTXO) | coin | "a moeda do app" (real, dólar) = the app's currency |
| cotar / Cote de novo | quote / Get a new quote | |
| vencer / prazo | expire / expiry (ordem), deadline (na cadeia) | |
| preenchida / execução parcial | filled / partial fill | |
| Sai (revisão) | You send | Linha que a conferência de segurança usa pelo papel, não pelo texto |
| Entra, no mínimo / Recebe, no mínimo | You receive, at least | |
| Chega, no mínimo | Arrives, at least | |
| Garantido (troca) | Minimum received | |
| Imediata / Limite / Ponte (modos da troca) | Instant / Limit / Bridge | |
| Rápida / Padrão (rotas da ponte) | Fast / Standard | |
| Capitalização / Oferta de moedas / Máxima histórica | Market cap / Supply / All-time high | |
| banda / energia / queimado (Tron) | bandwidth / energy / burned | |
| cunhar (CCTP) | mint | |
| Cópias (seção) / Sem cópia | Backups / No backup | |
| Grave a senha da carteira | Write down your recovery phrase | |
| frase (nas telas de voz) | phrase (voice phrase) | Fora delas, "senha da carteira" = recovery phrase |
| cofre | vault | |
| Código do iPhone | iPhone passcode | |
| Bloquear o app | Lock the app | |
| Tag de destino (Destination Tag) | Destination tag | Nos outros idiomas, manter "(Destination Tag)" |
