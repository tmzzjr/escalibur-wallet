# Third-party notices

Componentes de terceiros da Escalibur Wallet e as licenças deles, no texto original. A licença do repositório (`LICENSE`, tradução em `LICENSE.pt.md`) não vale para eles.

The Escalibur Wallet source code is published under the Escalibur Wallet Source-Available License (`LICENSE`). The components below are not: each keeps its own license, reproduced or identified here as published at its origin (checked on 2026-10-16). Nothing in `LICENSE` limits the rights those licenses give you over those components.

## Compiled into the app

### libsecp256k1 v0.8.0

- Where: `Kit/Sources/CSecp256k1/upstream`, locked file by file in `secp256k1.lock`.
- Origin: https://github.com/bitcoin-core/secp256k1, tag `v0.8.0`.
- License: MIT. The text below is the upstream `COPYING` at that tag, byte for byte the same as `Kit/Sources/CSecp256k1/upstream/COPYING` (SHA-256 `a735999c7e5649df6fcda6fb06ab97435851c392b1b93494ae8725f37441632f`).

```
Copyright (c) 2013 Pieter Wuille

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

### Argon2 reference implementation, with its BLAKE2b

- Where: `Kit/Sources/CArgon2`, locked file by file in `argon2.lock`. `escalibur_blake2b.c` and `include/escalibur_blake2b.h`, which only expose the bundled BLAKE2b to Swift, are Escalibur's own and fall under `LICENSE`.
- Origin: https://github.com/P-H-C/phc-winner-argon2, tag `20190702`.
- License: CC0 1.0 Universal or Apache License 2.0, at your option. The full text of both is in `Kit/Sources/CArgon2/LICENSE.txt`, byte for byte the upstream `LICENSE` at that tag (SHA-256 `220f8736a89ff51c92ef3d497f413b48e6cf1df3d6278bc909c6308c78e1718e`). Its header:

```
Argon2 reference source code package - reference C implementations

Copyright 2015
Daniel Dinu, Dmitry Khovratovich, Jean-Philippe Aumasson, and Samuel Neves

You may use this work under the terms of a Creative Commons CC0 1.0 
License/Waiver or the Apache Public License 2.0, at your option. The terms of
these licenses can be found at:

- CC0 1.0 Universal : http://creativecommons.org/publicdomain/zero/1.0
- Apache 2.0        : http://www.apache.org/licenses/LICENSE-2.0

The terms of the licenses are reproduced below.
```

### TweetNaCl, ported to Swift

- Where: the field and curve arithmetic of `Kit/Sources/EscaliburChains/Solana/Edwards25519.swift` and `Kit/Sources/EscaliburCore/Crypto/Ed25519Extended.swift`, ported line by line.
- Origin: https://tweetnacl.cr.yp.to/, by Daniel J. Bernstein, Bernard van Gastel, Wesley Janssen, Tanja Lange, Peter Schwabe and Sjaak Smetsers.
- License: public domain. The project page says: "TweetNaCl is a self-contained public-domain C library". The Swift port is Escalibur's and falls under `LICENSE`; the public-domain original stays free for anyone.

### TON wallet contract code (V4R2 and V5R1)

- Where: the compiled contract constants (`v4r2BOC`, `v5r1BOC`) in `Kit/Sources/EscaliburChains/TON/TONWallet.swift`.
- V4R2 origin: https://github.com/ton-org/ton, `src/wallets/v4/WalletContractV4.ts`. License: MIT.

```
The MIT License (MIT)

Copyright (c) 2021-2023 Whales Corp.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

- V5R1 origin: https://github.com/ton-blockchain/wallet-contract-v5, `build/wallet_v5.compiled.json` at commit `4fab977f4fae3a37c1aac216ed2b7e611a9bc2af`. License: MIT, from the `LICENSE` at that commit.

```
MIT License

Copyright (c) 2023 Tonkeeper

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### XRP Ledger binary codec definitions

- Where: the field and type table of `Kit/Sources/EscaliburChains/XRPL/XRPLDefinitions.swift`, and, for the tests only, `definitions.json`, `codec-fixtures.json`, `data-driven-tests.json` and the other files of `Kit/Tests/EscaliburChainsTests/Fixtures/xrpl`.
- Origin: https://github.com/XRPLF/xrpl.js, `packages/ripple-binary-codec` (and the `packages/xrpl` tests), commit `5c41405eb361350abc2c615491c74bb3ea6b583d`.
- License: ISC, from `packages/ripple-binary-codec/LICENSE` at that commit (`packages/xrpl` is ISC too).

```
Copyright (c) 2015 Ripple Labs Inc.

Permission to use, copy, modify, and distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

## Data shipped in the app

### BIP-39 wordlists

- Where: `Kit/Sources/EscaliburCore/Resources/Wordlists`, locked in `wordlists.lock`. The ten lists are byte for byte the same as `bip-0039/*.txt` in https://github.com/bitcoin/bips.
- License: MIT. BIP-39 (authors: Marek Palatinus, Pavol Rusnak, Aaron Voisine, Sean Bowe) declares "License: MIT" in its header and, in its Copyright section, "This BIP falls under the MIT License." It gives no separate copyright line. The MIT License terms:

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

### zxcvbn-ts dictionaries (password strength meter)

- Where: `Kit/Sources/EscaliburCore/Resources/Forca`, locked in `forca.lock`. The `LEIA-ME.txt` there says which list came from which package.
- Origin: the npm packages `@zxcvbn-ts/language-common` 4.1.3, `@zxcvbn-ts/language-pt-br` 4.1.1 and `@zxcvbn-ts/language-en` 4.1.1 (https://github.com/zxcvbn-ts/zxcvbn).
- License: MIT, from the `LICENSE.txt` of those packages, the same file as the project's `LICENSE.txt` (SHA-256 `c376f457b9569b2a88506f78fe420511a3ca3be5819b69dda405b988b784735f`).

```
Copyright (c) 2012-2016 Dan Wheeler and Dropbox, Inc.
Copyright (c) 2021 @zxcvbn-ts

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

- The common-word lists (`pt-palavras.txt`, `en-palavras.txt`) come from the `commonWords` dictionaries of the pt-br and en packages, whose `THIRD_PARTY_LICENSES.md` lists, for `commonWords.json`: "OpenSubtitles 2024 (via OPUS)", license "ODC-BY", source https://opus.nlpl.eu/, provider "Helsinki-NLP". They contain information from OpenSubtitles 2024, made available through OPUS under the Open Data Commons Attribution License (https://opendatacommons.org/licenses/by/1-0/).

### "Bit Coin" 3D model texture

- Where: `App/EscaliburWallet/Resources/Moeda3D`, locked in `modelos.lock`.
- Origin: "Bit Coin" by marcio3d (Márcio N.), https://sketchfab.com/3d-models/bit-coin-9488d7d5aa2f4c1c97774d56e1fb4aec
- License: Creative Commons Attribution 4.0 International (CC BY 4.0), https://creativecommons.org/licenses/by/4.0/ (the license Sketchfab lists for the model).
- Changes: only the base color texture is used, cut into the front, back and edge of the coin and rotated for the cylinder map; the mesh is not used. The app credits the author in its settings.

### Network, token and provider logos

- Where: `App/EscaliburWallet/Resources/Assets.xcassets/Logos`, and the copies the site generator makes from them.
- They are trademarks of their owners, downloaded through CoinGecko (`tools/baixar-logos.py`) and shown only to identify each network, token or provider. They are not covered by `LICENSE`, and `LICENSE` grants no right to them.

## On the website only

- `site/selos/baixar-na-app-store.svg` is Apple's "Download on the App Store" badge, unchanged, from Apple's marketing site, used under Apple's App Store marketing guidelines. Apple, the Apple logo and App Store are trademarks of Apple Inc.

## In the tests only (not in the app)

- `Kit/Tests/**/Fixtures*`: test vectors taken from or generated with third-party projects, and responses recorded from public APIs. The `LEIA-ME.txt` in each folder names the origin and, for copied files, the SHA-256 of the source; each file keeps the terms of its origin. Copied subsets include the `ethers.js` test cases in `Kit/Tests/EscaliburChainsTests/Fixtures/evm` (https://github.com/ethers-io/ethers.js, MIT, "Copyright (c) 2016-2025 Richard Moore") and the `xrpl.js` files listed above (ISC).
- `tools/requisitos-ci.txt` pins, by version and hash, the Python packages that the CI installs to run the reference decryptor. They are not in the repository.
