# Privacy policy

This is a translation of the Portuguese policy. If the two differ, the Portuguese version prevails.

Escalibur Wallet is a wallet that runs entirely on your iPhone. There is no Escalibur account, sign-up or server, and the app does not ask for your email. This text says what the app keeps, where it keeps it, and who it talks to.

Escalibur Wallet is offered by X TECH A.I FUND HOLDING E PARTICIPACOES LTDA, CNPJ 64.019.520/0001-29, called Escalibur here. Contact: thomaz@xtech.international.

## What stays on your iPhone

- **The wallet keys.** They stay in the iOS keychain, tied to this device, encrypted by Secure Enclave keys and by your PIN. They are not included in the iCloud backup and do not move to another iPhone.
- **Wallet names, addresses, contacts and settings.** They stay in an encrypted file in the app, outside the backup.
- **Price alerts, if you turn them on.** The coins you marked, the rules and the last price seen stay in a separate file, outside the backup. It opens after the first unlock of the iPhone, and not only while the screen is unlocked like the rest: that is what lets the alert arrive with the screen locked. It holds no balance, address or wallet.
- **Nothing leaves the device because of the app.** The recovery phrase (the words) only leaves when you yourself seal an Escalibur envelope, encrypted with a password of its own.

## What Escalibur receives

Nothing. The app has no usage analytics, crash reporting, ads or tracking, and talks to no Escalibur server. The code is open, and an automatic check rejects any library of that kind.

## Who the app talks to

To show balances, prices and history, and to send and swap, the app talks directly to public services of each network, run by different companies. Each one sees your iPhone's IP and the addresses, amounts and transactions the app looks up or sends, and may notice that those addresses belong to the same person. A VPN hides the IP. Turning off a network you don't use in Settings stops its lookups.

With price alerts on, the iPhone checks from time to time, also with the app closed, the price of the marked coins on CoinGecko and CoinPaprika. Both see the IP and the list of those coins, nothing else.

With incoming alerts on (they come on, and you can turn them off in Settings, Incoming alerts), the iPhone checks from time to time, also with the app closed, the balance of your accounts on the same services of each network the app already uses. For that, the public addresses of the accounts and the last balance seen for each coin stay in a separate file on the iPhone, readable after the first unlock, outside the wallet's encrypted data. No key goes into it, and turning the alert off deletes the file.

With a limit order open, the iPhone asks CoW from time to time, also with the app closed, whether it was filled, to let you know. For that, the identifier of each open order (which carries the account address and the deadline, the same data CoW publishes) stays in a separate file, readable after the first unlock. The order leaves the file when it ends.

So the Receive search can find any coin, the text you type goes to CoinGecko, and when you tap a coin, the app asks which networks it exists on. CoinGecko sees the IP and what was searched, with no address or balance.

The list below is complete: the app cannot talk to any other address, and the code checks this in every version.

- **Coin prices, charts and logos:** `api.coingecko.com`, `api.coinpaprika.com`, `assets.coingecko.com`, `coin-images.coingecko.com`, `www.okx.com`
- **Charts for tokens CoinGecko does not list:** `api.geckoterminal.com`. It receives only the token contract and the network, never your address. The price from there draws the chart and does not count in the total balance.
- **Token list for BNB Chain, X Layer and Sonic:** `tokens.coingecko.com`. The same list for everyone, downloaded so the app can find tokens on these networks; the balance of each one is read from the network's own services.
- **Logos of unlisted tokens:** `raw.githubusercontent.com`, only Trust Wallet's public logo repository. GitHub sees the IP and the contract of each token whose logo the app fetches.
- **Bitcoin, Litecoin and Dogecoin:** `api.bitcore.io`, `api.blockchair.com`, `api.blockcypher.com`, `blockstream.info`, `dogecoin.atomicwallet.io`, `litecoin.atomicwallet.io`, `litecoinspace.org`, `mempool.emzy.de`, `mempool.space`
- **Ethereum, Base, Arbitrum, Optimism, Polygon, BNB Chain, Avalanche, Plasma, X Layer, Linea, Unichain, Sonic and Celo:** `196.rpc.thirdweb.com`, `1rpc.io`, `42220.rpc.thirdweb.com`, `9745.rpc.thirdweb.com`, `api-explorer.linea.build`, `api.avax.network`, `api.routescan.io`, `arb1.arbitrum.io`, `arbitrum-one-rpc.publicnode.com`, `arbitrum.blockscout.com`, `arbitrum.drpc.org`, `arbitrum.meowrpc.com`, `avalanche-c-chain-rpc.publicnode.com`, `avalanche.drpc.org`, `base-rpc.publicnode.com`, `base.blockscout.com`, `base.drpc.org`, `bsc-dataseed.bnbchain.org`, `bsc-dataseed1.defibit.io`, `bsc-dataseed1.ninicoin.io`, `bsc-mainnet.nodereal.io`, `bsc-rpc.publicnode.com`, `celo-rpc.publicnode.com`, `celo.blockscout.com`, `cloudflare-eth.com`, `eth.blockscout.com`, `eth.drpc.org`, `ethereum-rpc.publicnode.com`, `explorer.optimism.io`, `forno.celo.org`, `linea-rpc.publicnode.com`, `linea.drpc.org`, `mainnet.base.org`, `mainnet.optimism.io`, `mainnet.unichain.org`, `optimism-rpc.publicnode.com`, `optimism.drpc.org`, `plasma.gateway.tenderly.co`, `polygon-bor-rpc.publicnode.com`, `polygon.blockscout.com`, `polygon.drpc.org`, `rpc.linea.build`, `rpc.plasma.to`, `rpc.soniclabs.com`, `rpc.xlayer.tech`, `sonic-rpc.publicnode.com`, `sonic.drpc.org`, `unichain-rpc.publicnode.com`, `unichain.blockscout.com`, `unichain.drpc.org`, `xlayer.drpc.org`
- **BNB Chain history:** it comes from NodeReal (`bsc-mainnet.nodereal.io`), with a free Escalibur key, the only one in the app. The key identifies the app, not you; NodeReal sees the IP and the address looked up, like the other services of each network.
- **Protected sends on Ethereum:** `rpc.flashbots.net`, `rpc.mevblocker.io`
- **Solana:** `api.mainnet.solana.com`, `public.rpc.solanavibestation.com`, `solana-mainnet.gateway.tatum.io`, `solana-rpc.publicnode.com`
- **XRP Ledger:** `s1.ripple.com`, `s2.ripple.com`, `xrplcluster.com`
- **Stellar:** `horizon.stellar.lobstr.co`, `horizon.stellar.org`
- **Tron:** `api.trongrid.io`, `api.tronstack.io`, `tron-rpc.publicnode.com`
- **TON:** `tonapi.io`, `toncenter.com`
- **Sui:** `fullnode.mainnet.sui.io`, `graphql.mainnet.sui.io`, `rpc-mainnet.suiscan.xyz`, `sui-mainnet.nodeinfra.com`
- **Cardano:** `api.koios.rest`, `api.yoroiwallet.com`, `zero.yoroiwallet.com`
- **Polkadot:** `polkadot-asset-hub-rpc.polkadot.io`, `rpc-asset-hub-polkadot.luckyfriday.io`, `asset-hub-polkadot-rpc.n.dwellir.com`, `statemint.api.onfinality.io`, `polkadot-asset-hub-public-sidecar.parity-chains.parity.io`, `subquery-history-polkadot-ah-prod.novasama-tech.org`
- **NEAR:** `api.fastnear.com`, `free.rpc.fastnear.com`, `near.drpc.org`, `rpc.shitzuapes.xyz`, `rpc.intea.rs`, `tx.main.fastnear.com`
- **Aptos:** `aptos-rest.publicnode.com`, `rpc.sentio.xyz`, `api.mainnet.aptoslabs.com`
- **Swaps and limit orders:** `aggregator-api.kyberswap.com`, `api.cow.fi`, `api.jup.ag`, `api.velora.xyz`, `li.quest`, `open-api.de1.exchange`
- **Bridge between networks:** `iris-api.circle.com` (Circle) and `app.across.to` (Across). The quote goes without your address: only networks, coin and amount. To follow a bridge, the app sends the hash of the deposit transaction, which is public on the network.

Each of these services has its own privacy policy.

## iPhone permissions

- **Face ID:** iOS decides. The app only receives "confirmed" or "not confirmed", never your face.
- **Camera:** only to read an address QR code, on the device. No image is saved.
- **Notifications:** all local, created on the iPhone itself, and only with your permission: the app has no push token and no server sends it anything. They go out for: price alerts, with the coin and the price, or only "Price alert", as you choose; incoming alerts (on by default), only with "Coins arrived in your wallet", or with the amount and coin received, if you choose; a bridge arriving, without the amount; and limit orders, 24 hours before they expire, when they fill and when the deadline ends, without coin or amount. Never the wallet balance.
- **Microphone and speech recognition:** only if you turn on voice confirmation. Recognition runs on the device, with no Apple server; the audio is not recorded and what was said is not stored, only an encrypted fingerprint of the phrase.

## Clipboard

A copied address stays only on this device and expires by itself after 2 minutes. The wallet words can only be copied after a warning; the copy stays only on this device, never reaches your Mac and disappears after 1 minute.

## Your rights

Since Escalibur receives and keeps no data of yours through the app, there is nothing on our side to access, correct or delete. Deleting the app deletes its files on this iPhone. The encrypted keys that iOS keeps in the keychain stay on the device after removal and are deleted on the first launch if the app is installed again. To delete a wallet right away, use Settings, the wallet, Remove from this iPhone.

## Contact

Questions about this policy or about your data: thomaz@xtech.international. An email to support arrives outside the app, with your address and what you write, and is used only to reply. Never send the wallet words, the PIN or an envelope password.

## Changes

Changes to this policy come with a new version of the app and are recorded in the open source code.
