# Lançamento na App Store

Estado em 27/09/2026, depois da auditoria de prontidão (estaleiro). O código, os testes
e o build Release estão prontos; o que falta é embalagem, publicação e decisões do dono.

## O que ainda bloqueia

1. **Contato e política em URL pública.** A App Store Connect exige "Privacy Policy URL"
   e "Support URL", e a diretriz 1.5 pede um jeito fácil de contato. Falta:
   - um e-mail de suporte;
   - uma página pública com a política de privacidade (pode ser a do repositório
     publicado, `App/EscaliburWallet/Resources/Legal/privacidade.md`);
   - razão social, CNPJ e contato nos Termos e na Política (LGPD, art. 9), junto da
     revisão do advogado;
   - uma linha "Suporte" em Ajustes, Sobre, com o e-mail.
2. **Publicar o repositório.** O app diz que o código é aberto e o `SECURITY.md` manda
   relatar pelo GitHub. Publicar liga o CI (`.github/workflows/verificar.yml`), a
   proteção de branch e as tags assinadas (MUST 14). O decifrador já sai do app
   (Ajustes, Sobre, e a tela de envelope lacrado), então o envelope abre num computador
   mesmo antes da publicação.
3. **Spike do applicationPassword em iPhone físico** (MUST 1), segundo revisor humano
   e Termos revisados por advogado.

## Respostas para a App Store Connect

- **Criptografia:** `ITSAppUsesNonExemptEncryption = false`. A cifra de sigilo usa só o
  que vem no iOS (CryptoKit, `SecKey`); o código próprio é assinatura, hash e derivação
  de chave.
- **Etiqueta de privacidade:** "Dados não coletados". A carteira não tem servidor; o
  que vai para a rede (IP, endereços, transações) vai direto aos provedores públicos do
  `hosts.lock`, e a Política diz isso. O manifesto (`PrivacyInfo.xcprivacy`) declara o
  mesmo.
- **Disponibilidade:** desligar Mac com Apple Silicon e Vision Pro. O aviso de aparelho
  modificado procura arquivos que existem no macOS e apareceria para quem usa no Mac.
- **Diretriz 3.1.5:** o time de assinatura é pessoa jurídica, como a regra exige para
  carteiras.
- **Classificação etária e idade mínima:** decisão do dono com o advogado.

## Notas para a revisão da Apple (rascunho, em inglês)

> Escalibur Wallet is a non-custodial cryptocurrency wallet. Keys are generated and
> stored only on the device (Secure Enclave and Keychain, ThisDeviceOnly); there is no
> account, no server of ours, and no custody of user funds. The app never sends the
> recovery phrase or the PIN anywhere.
>
> Swaps and limit orders are executed by the user's own wallet against public,
> non-custodial protocols (on-chain DEX aggregators, CoW Protocol, the XRP Ledger and
> Stellar native order books). The app charges no fee; users pay only the network fee
> and the provider's spread, which is shown before signing.
>
> To review: create a wallet (Create wallet, write down the 12 words, confirm them, set
> a 6-digit PIN). Receiving shows the address and QR per network. Sending, swapping and
> limit orders require funds on a network; without funds the app shows the quote and
> stops at "insufficient balance". A screen recording of a funded send and swap is
> attached.

(O vídeo com envio e troca de verdade, numa carteira com saldo pequeno, ainda precisa
ser gravado num iPhone.)

## Regulação

Se a troca integrada enquadra a empresa como prestadora de serviços de ativos virtuais
(Lei 14.478/2022 e normas do Banco Central) é pergunta para o advogado antes do
lançamento.
