# Lançamento na App Store

Estado em 14/10/2026, depois da auditoria do App Store Agent. O binário, o contato, as
páginas públicas e as capturas estão prontos. O que falta é conta, formulário e decisão
do dono com o advogado.

## Pronto

- **Contato (diretriz 1.5).** Ajustes, Sobre, Suporte: o e-mail thomaz@xtech.international,
  com o botão de escrever e o aviso de que ninguém pede as palavras. O mesmo e-mail está
  na página de suporte, nos Termos e na Política; `verificar.sh` confere os quatro.
- **Empresa nos textos (LGPD, art. 9).** Termos e Política dizem X TECH A.I FUND HOLDING E
  PARTICIPACOES LTDA, CNPJ 64.019.520/0001-29 (conferido na base pública da Receita em
  14/10/2026: ativa, aberta em 11/12/2025), e o contato. A Política ganhou a seção Contato,
  que diz o que acontece com um e-mail para o suporte.
- **Site no GitHub Pages**, gerado do repositório por `tools/gerar-site.py` e publicado
  pelo `.github/workflows/site.yml` a cada push na main e de novo quando o CI termina:
  - Marketing: https://tmzzjr.github.io/escalibur-wallet/
  - Suporte: https://tmzzjr.github.io/escalibur-wallet/suporte/
  - Política de privacidade: https://tmzzjr.github.io/escalibur-wallet/privacidade/
  - Termos: https://tmzzjr.github.io/escalibur-wallet/termos/
  - Também: `/seguranca/`, `/auditoria/` (verificações, hosts, dependências travadas,
    commit e CI, código das chaves linha a linha), `/redes/` e `/novidades/`.
  - As telas em vídeo saem de `tools/gravar-site/gravar.sh` (simulador, modo demo).
  - **No dia do lançamento:** pôr o link do app em `APP_STORE_URL`, no topo de
    `tools/gerar-site.py`. O site troca "Em breve na App Store" pelo selo oficial da Apple
    (`site/selos/baixar-na-app-store.svg`, baixado do site de marketing da Apple, sem
    alteração) com o link, e liga o banner do Safari. O selo nunca aparece sem o link: o
    `verificar.sh` confere.
- **Código que a revisão olharia:** o botão de troca sem motor dizia "chega em breve"
  (diretriz 2.1) e agora diz "Troca indisponível nesta rede"; os caminhos de jailbreak
  não valem mais no Mac (davam alarme falso com `/usr/sbin/sshd`); o manifesto declara o
  tempo de boot (`35F9.1`) que a espera do PIN usa; a checagem de tela espelhada não usa
  mais `UIScreen.screens`, depreciado.
- **Repositório público**, com o CI ligado.
- **Spike da senha de aplicativo** feito num iPhone 13 Pro Max em 10/10/2026
  (`docs/auditoria-1.md`).
- **Capturas** de 6,9" (1320x2868, iPhone 17 Pro Max) e 6,3" (1206x2622, iPhone 17), da
  carteira pública de teste do BIP-39 no simulador, sem palavras na tela. Ficam em
  `build/loja/` (fora do git).

## Falta, e é com você

1. **Países e parecer do advogado (diretriz 3.1.5(iii)).** A troca, a ordem limite e a
   ponte podem fazer a Apple pedir licença de exchange por país. Antes de enviar:
   - a lista de países, com a China continental fora, e os EUA só com resposta para o
     registro de MSB;
   - um parecer escrito de que a empresa não é prestadora de serviços de ativos virtuais
     (Lei 14.478/2022 e Resoluções BCB 519, 520 e 521), porque não custodia e não executa
     nada em nome de ninguém.
   - Plano B, se a Apple insistir: uma versão sem troca, ordem limite e ponte passa pela
     3.1.5(i), que é só carteira.
2. **Conta.** Em developer.apple.com/account, Membership, confirmar que o time
   `2UNWMDD93S` é organização (a 3.1.5(i) exige). Fazer o archive sempre com esse time.
3. **App Store Connect:** criar o app com o bundle id `app.escalibur.wallet`,
   preencher com o texto abaixo, subir o build (tag assinada, `docs/release.md`) e as capturas.
4. **Disponibilidade:** desligar "iPhone and iPad Apps on Apple Silicon Macs" e "Apple
   Vision Pro" em Pricing and Availability. Se entrar na União Europeia, declarar-se
   comerciante pela DSA (endereço, telefone e e-mail ficam públicos).
5. **Vídeo para a revisão:** um envio, uma troca, uma ordem limite e uma ponte de verdade,
   com saldo pequeno, gravados no iPhone. É o que mais evita "Information Needed" (2.1).
6. **Classificação etária:** o questionário dá 4+ (respostas abaixo). Se o advogado
   preferir 18+, desde 24/02/2026 a App Store bloqueia o download no Brasil para quem não
   teve a maioridade confirmada.
7. **Painéis de parceiro:** a LI.FI e a Velora recebem `integrator=escalibur`. Cadastrar
   esse rótulo num painel que mostre transações faz a Escalibur passar a ter dado de
   usuário, e o rótulo "Dados não coletados" deixa de valer.

## Para preencher na App Store Connect

**Informações do app**
- Nome: Escalibur Wallet
- Subtítulo: Carteira cripto sem custódia
- Categoria: Finanças. Secundária: Utilitários.
- Preço: grátis, sem compra no app.
- Copyright: 2026 X TECH A.I FUND HOLDING E PARTICIPACOES LTDA
- Direitos de conteúdo: contém conteúdo de terceiros (preços do CoinGecko e logos de
  moedas). A tela Sobre credita o CoinGecko.
- URL de suporte: https://tmzzjr.github.io/escalibur-wallet/suporte/
- URL de marketing: https://tmzzjr.github.io/escalibur-wallet/
- URL da política de privacidade: https://tmzzjr.github.io/escalibur-wallet/privacidade/

**Textos**
- Palavras-chave (91 de 100): `bitcoin,ethereum,solana,usdc,cripto,carteira,autocustodia,defi,xrp,stellar,ton,troca,ponte`
- Texto promocional: As chaves ficam só no seu iPhone. Envie, receba e troque em 26 redes,
  com cada transação conferida antes de assinar. Sem conta e sem e-mail.
- Descrição: Escalibur Wallet é uma carteira de criptoativos sem custódia. As chaves ficam
  no seu iPhone, protegidas pelo Secure Enclave e pelo seu PIN, fora do backup do iCloud.
  Não existe conta, cadastro nem servidor da Escalibur. Envie e receba em Bitcoin,
  Ethereum, Solana, XRP Ledger, Stellar, TON, Tron e mais 19 redes. Troque moedas pelos
  protocolos públicos de cada rede, crie ordens limite, leve USDC, ETH e USDT entre redes
  pela ponte e receba alertas de preço e de recebimento gerados no próprio iPhone. Antes
  de assinar, o app mostra destino, valor e taxa, e confere o que será assinado. Guarde a
  senha da carteira num envelope cifrado com senha própria. O código é aberto.
  - Sem preço, sem promessa de ganho e sem nome de outra carteira (2.3.7 e 2.3.10).

**Privacidade do app:** "Não, não coletamos dados deste app". Rastreamento: não. O app não
tem servidor nem SDK de terceiros, e o manifesto não declara coleta. O e-mail de suporte
chega fora do app e não entra no rótulo.

**Criptografia:** `ITSAppUsesNonExemptEncryption = false`, já no Info.plist. A cifra é só a
do iOS (CryptoKit e Security); o código próprio é hash, assinatura e Argon2. Sem
documentação de exportação.

**Classificação etária** (tudo "Não" ou "Nenhum", resultado 4+): sem controle parental nem
verificação de idade; sem acesso irrestrito à web (os links do explorador abrem no
Safari), conteúdo gerado por usuário, rede social, mensagens ou anúncios; sem temas
maduros, médicos, sexuais ou violentos; sem jogo a dinheiro, simulado, concurso ou loot
box.

**Informações para a revisão:** desmarcar "login necessário"; contato com nome, telefone e
e-mail.

**Notas de revisão** (em inglês):

> Escalibur Wallet is a non-custodial cryptocurrency wallet published by X TECH A.I FUND
> HOLDING E PARTICIPACOES LTDA, enrolled as an organization. The interface is in
> Brazilian Portuguese.
>
> There is no account, no login and no server of ours. Keys are generated and kept only on
> this device (Secure Enclave and Keychain, ThisDeviceOnly). We never receive the recovery
> phrase, the PIN, addresses or transactions. No analytics, ads or tracking. Source code:
> https://github.com/tmzzjr/escalibur-wallet
>
> Before testing:
> 1. The device must have a passcode. Without one, the first screen explains it and keys
>    cannot be stored.
> 2. While the screen is recorded or mirrored, the recovery phrase screens are hidden
>    ("A tela está sendo gravada ou espelhada"). Stop recording to see the words.
>
> How to test:
> - Create a wallet: Começar, choose a 6-digit PIN, Criar carteira nova, write down the 12
>   words, confirm them.
> - Balances and history without funds: Ajustes, Carteiras, Adicionar carteira, "Só
>   observar um endereço", and paste the public Ethereum address
>   0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045 (watch-only, cannot send).
> - Receive shows the address and QR for each network.
> - Send and swap (tab "Trocar": Imediata, Limite, Ponte) need funds. Without funds,
>   typing an amount shows a live quote and the main button becomes "Receber". Video of a
>   real send, swap, limit order and bridge with a small funded wallet: [LINK].
> - Support contact in the app: Ajustes, Suporte.
>
> Swaps, limit orders and bridge: "Comprar" and "Vender" on the Market tab open the swap
> screen, which exchanges one crypto asset for another on-chain. There is no fiat, no card
> payment, no on-ramp, no in-app purchase and no fee charged by us. Each transaction is
> signed by the user's own key on the device and sent directly to public non-custodial
> protocols: CoW Protocol, KyberSwap, Velora, LI.FI, De1 (OpenOcean), Jupiter, the XRP
> Ledger and Stellar native order books, Circle CCTP and Across. We do not operate an
> exchange, do not hold or route user funds and receive nothing from these protocols. The
> user pays only the network fee and the protocol spread, shown before signing. No mining,
> staking, ICOs, derivatives, NFTs or rewards.
>
> Other features: price, incoming-payment and limit-order alerts are local notifications
> created on the device; background app refresh only reads public prices, balances and
> order status, and there is no push server. Optional voice confirmation uses on-device
> speech recognition only. The encrypted backup (.esclbr) is opened inside the app only.

**Se a Apple pedir a licença da 3.1.5(iii)** (em inglês):
- Countries: [lista decidida com o advogado].
- Licensing: the developer provides self-custody software and does not offer exchange
  services; legal opinion attached.
- Third-party APIs: api.cow.fi, aggregator-api.kyberswap.com, api.velora.xyz, li.quest,
  open-api.de1.exchange, api.jup.ag, iris-api.circle.com, app.across.to, and public XRPL
  and Stellar nodes.
- Who transacts: transactions occur between the user's own wallet and the on-chain
  protocol; the developer never receives or forwards the request on the user's behalf.
- Type: decentralized only. Exclusive tokens: none.
- AML/KYC: no custody and no fiat, so no customer funds or accounts; no KYC is collected.
- USA: [registro de MSB ou fora da lista].

## Play Store

Não existe app Android. Antes de qualquer formulário: o app (Kotlin, ou o núcleo em Swift
pelo SDK de Swift para Android), conta do Google Play como organização com D-U-N-S, API 36
como alvo, Android App Bundle com Play App Signing, a declaração de recursos financeiros
("software wallet": carteira sem custódia fica fora da regra de licença) e o formulário de
Segurança dos dados.
