# Política de privacidade

A Escalibur Wallet é uma carteira que roda inteira no seu iPhone. Não existe conta, cadastro, e-mail nem servidor da Escalibur. Este texto diz o que o app guarda, onde guarda, e com quem ele fala.

## O que fica no seu iPhone

- **As chaves das carteiras.** Ficam no chaveiro do iOS, presas a este aparelho, cifradas por chaves do Secure Enclave e pelo seu PIN. Não entram no backup do iCloud e não passam para outro iPhone.
- **Nomes das carteiras, endereços, contatos e ajustes.** Ficam num arquivo cifrado no app, fora do backup.
- **Nada sai do aparelho por conta do app.** A senha da carteira (as palavras) só sai quando você mesmo lacra um envelope Escalibur, cifrado com uma senha só dele.

## O que a Escalibur recebe

Nada. O app não tem análise de uso, relatório de falhas, anúncios nem rastreamento, e não fala com nenhum servidor da Escalibur. O código é aberto, e uma verificação automática recusa qualquer biblioteca desse tipo.

## Com quem o app fala

Para mostrar saldos, preços e histórico, e para enviar e trocar, o app fala direto com serviços públicos de cada rede, de empresas diferentes. Cada um vê o IP do seu iPhone e os endereços, valores e transações que o app consulta ou envia, e pode perceber que esses endereços são da mesma pessoa. Uma VPN esconde o IP. Desligar em Ajustes uma rede que você não usa para as consultas dela.

A lista abaixo é completa: o app não consegue falar com nenhum outro endereço, e o código confere isso a cada versão.

- **Preços e gráficos:** `api.coingecko.com`, `api.coinpaprika.com`, `www.okx.com`
- **Bitcoin, Litecoin e Dogecoin:** `api.blockchair.com`, `api.blockcypher.com`, `blockstream.info`, `litecoinspace.org`, `mempool.emzy.de`, `mempool.space`
- **Ethereum, Base, Arbitrum, Optimism, Polygon, BNB Chain, Avalanche, Plasma, X Layer, Linea, Unichain, Sonic e Celo:** `196.rpc.thirdweb.com`, `1rpc.io`, `42220.rpc.thirdweb.com`, `9745.rpc.thirdweb.com`, `api-explorer.linea.build`, `api.avax.network`, `api.routescan.io`, `arb1.arbitrum.io`, `arbitrum-one-rpc.publicnode.com`, `arbitrum.blockscout.com`, `arbitrum.drpc.org`, `arbitrum.meowrpc.com`, `avalanche-c-chain-rpc.publicnode.com`, `avalanche.drpc.org`, `base-rpc.publicnode.com`, `base.blockscout.com`, `base.drpc.org`, `bsc-dataseed.bnbchain.org`, `bsc-dataseed1.defibit.io`, `bsc-dataseed1.ninicoin.io`, `bsc-rpc.publicnode.com`, `celo-rpc.publicnode.com`, `celo.blockscout.com`, `cloudflare-eth.com`, `eth.blockscout.com`, `eth.drpc.org`, `ethereum-rpc.publicnode.com`, `explorer.optimism.io`, `forno.celo.org`, `linea-rpc.publicnode.com`, `linea.drpc.org`, `mainnet.base.org`, `mainnet.optimism.io`, `mainnet.unichain.org`, `optimism-rpc.publicnode.com`, `optimism.drpc.org`, `plasma.gateway.tenderly.co`, `polygon-bor-rpc.publicnode.com`, `polygon.blockscout.com`, `polygon.drpc.org`, `rpc.linea.build`, `rpc.plasma.to`, `rpc.soniclabs.com`, `rpc.xlayer.tech`, `sonic-rpc.publicnode.com`, `sonic.drpc.org`, `unichain-rpc.publicnode.com`, `unichain.blockscout.com`, `unichain.drpc.org`, `xlayer.drpc.org`
- **Envio protegido na Ethereum:** `rpc.flashbots.net`, `rpc.mevblocker.io`
- **Solana:** `api.mainnet.solana.com`, `solana-mainnet.gateway.tatum.io`, `solana-rpc.publicnode.com`
- **XRP Ledger:** `s1.ripple.com`, `s2.ripple.com`, `xrplcluster.com`
- **Stellar:** `horizon.stellar.lobstr.co`, `horizon.stellar.org`
- **Tron:** `api.trongrid.io`, `api.tronstack.io`, `tron-rpc.publicnode.com`
- **TON:** `tonapi.io`, `toncenter.com`
- **Trocas e ordens limite:** `aggregator-api.kyberswap.com`, `api.cow.fi`, `api.jup.ag`, `api.velora.xyz`, `li.quest`, `open-api.de1.exchange`

Cada um desses serviços tem a própria política de privacidade.

## Permissões do iPhone

- **Face ID:** quem decide é o iOS. O app recebe só "confirmou" ou "não confirmou", nunca o seu rosto.
- **Câmera:** só para ler QR code de endereço, no aparelho. Nenhuma imagem é guardada.
- **Microfone e reconhecimento de fala:** só se você ligar a confirmação por voz. O reconhecimento roda no aparelho, sem servidor da Apple; o áudio não é gravado e o que foi dito não é guardado, só uma impressão cifrada da frase.

## Área de transferência

Endereço copiado fica só neste aparelho e expira sozinho. As palavras da carteira nunca podem ser copiadas pelo app.

## Seus direitos

Como a Escalibur não recebe nem guarda dado nenhum seu, não há o que consultar, corrigir ou apagar do nosso lado. Apagar o app apaga tudo o que ele guardou neste iPhone.

## Mudanças

Mudanças nesta política vêm junto com uma versão nova do app e ficam registradas no código aberto.
