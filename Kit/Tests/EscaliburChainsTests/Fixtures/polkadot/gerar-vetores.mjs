// Vetores da Polkadot Asset Hub pela implementacao de referencia (polkadot-js, @polkadot/api
// 17.0.1), com os metadados da rede principal lidos ao vivo (spec 2005000, transaction
// version 15). A assinatura Ed25519 do polkadot-js e deterministica (RFC 8032), entao a
// extrinsic inteira e reproduzivel; a Escalibur confere o payload byte a byte e verifica a
// assinatura, porque o CryptoKit aleatoriza a dela.
//
//     npm install @polkadot/api@17.0.1 && node gerar-vetores.mjs > vetores.json
import { ApiPromise, HttpProvider } from '@polkadot/api';
import { ed25519PairFromSeed, encodeAddress, blake2AsHex, cryptoWaitReady } from '@polkadot/util-crypto';
import { u8aToHex, hexToU8a } from "@polkadot/util";
import { ed25519Sign } from "@polkadot/util-crypto";
await cryptoWaitReady();
const api = await ApiPromise.create({ provider: new HttpProvider('https://polkadot-asset-hub-rpc.polkadot.io'), noInitWarn: true });
const genesis = api.genesisHash.toHex();
const rv = api.runtimeVersion;
const casos = [
  { seed: '70a794d4f1019c3ce002f33062f45029c4f930a56b3d20ec477f7668c6bbc37f', dest: '12q4hq1dgqHZVGzHbwZmqq1cFwatN15Visfd7YmUiMB5ZWkH', amount: '100000', nonce: 7, block: 21172670, blockHash: '0x5f95fcdd9ef0619b32fc083cb0b534fe4c35487a279985a0c66c3715a0202952' },
  { seed: '4646464646464646464646464646464646464646464646464646464646464646', dest: '13nN6BGAoJwd7Nw1XxeBCx5YcBXuYnL94Mh7i3xBprqVSsFk', amount: '12345678901234567', nonce: 131797, block: 21172670, blockHash: '0x5f95fcdd9ef0619b32fc083cb0b534fe4c35487a279985a0c66c3715a0202952' },
  // O bloco e o hash aqui sao so entrada do payload; o terceiro caso tem fase zero na era.
  { seed: 'abf8e5bdbe30c65656c0a3cbd181ff8a56294a69dfedd27982aace4a76909115', dest: '14Ztd3KJDaB9xyJtRkREtSZDdhLSbm7UUKt8Z7AwSv7q85G2', amount: '10000000000', nonce: 0, block: 21172672, blockHash: '0x5f95fcdd9ef0619b32fc083cb0b534fe4c35487a279985a0c66c3715a0202952' },
];
const out = { fonte: '@polkadot/api 17.0.1, metadados ao vivo de polkadot-asset-hub-rpc.polkadot.io', genesis, specVersion: rv.specVersion.toNumber(), transactionVersion: rv.transactionVersion.toNumber(), casos: [] };
for (const c of casos) {
  const pair = ed25519PairFromSeed(hexToU8a('0x' + c.seed));
  const signer = encodeAddress(pair.publicKey, 0);
  const call = api.tx.balances.transferKeepAlive(c.dest, c.amount);
  const era = api.createType('ExtrinsicEra', { current: c.block, period: 64 });
  const payload = api.createType('ExtrinsicPayload', {
    method: call.method.toHex(), era, nonce: c.nonce, tip: 0, assetId: null, mode: 0, metadataHash: null,
    specVersion: rv.specVersion, transactionVersion: rv.transactionVersion, genesisHash: genesis, blockHash: c.blockHash,
    version: 4, signedExtensions: api.registry.signedExtensions,
  }, { version: 4 });
  const payloadU8a = payload.toU8a({ method: true });
  // Payload acima de 256 bytes seria assinado pelo BLAKE2b-256 dele; estes cabem.
  if (payloadU8a.length > 256) throw new Error('payload longo');
  const raw = ed25519Sign(payloadU8a, pair);
  const signature = '0x00' + u8aToHex(raw).slice(2);
  const tx = api.createType('Extrinsic', call.method, { version: 4 });
  tx.addSignature(signer, signature, payload.toHex());
  out.casos.push({
    seed: c.seed, publicKey: u8aToHex(pair.publicKey), signer, dest: c.dest, amount: c.amount, nonce: c.nonce,
    blockNumber: c.block, blockHash: c.blockHash, era: era.toHex(), call: call.method.toHex(),
    payload: u8aToHex(payloadU8a), signature, extrinsic: tx.toHex(), hash: blake2AsHex(tx.toU8a(), 256),
  });
}
console.log(JSON.stringify(out, null, 2));
process.exit(0);
