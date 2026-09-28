// Duas transferencias reais de DOT (transfer_keep_alive assinada com Ed25519) no bloco
// 21.172.670 da Polkadot Asset Hub, runtime 2005000: a extrinsic crua do bloco, o hash,
// o bloco de nascimento da era e o payload montado com o layout das extensoes de hoje,
// que o ed25519Verify do polkadot-js aceitou para as duas. Uso:
//     node extrair-reais.mjs ../../../EscaliburNetworkTests/Fixtures/leitores/polkadot/block-21172670.json
import fs from 'node:fs';
import { ApiPromise, HttpProvider } from '@polkadot/api';
import { ed25519Verify, encodeAddress, blake2AsHex, cryptoWaitReady } from '@polkadot/util-crypto';
import { u8aToHex, hexToU8a, u8aConcat } from '@polkadot/util';
await cryptoWaitReady();
const api = await ApiPromise.create({ provider: new HttpProvider('https://polkadot-asset-hub-rpc.polkadot.io'), noInitWarn: true });
const blk = JSON.parse(fs.readFileSync(process.argv[2])).result.block;
const out = [];
for (const idx of [2, 3]) {
  const raw = blk.extrinsics[idx];
  const x = api.createType('Extrinsic', raw);
  const era = x.era.asMortalEra;
  const birth = era.birth(21172670);
  const bh = (await api.rpc.chain.getBlockHash(birth)).toHex();
  const rv = await api.rpc.state.getRuntimeVersion(bh);
  const pk = x.signer.toU8a().slice(-32);
  const payload = u8aConcat(x.method.toU8a(), x.era.toU8a(), api.createType('Compact<u32>', x.nonce).toU8a(), api.createType('Compact<u128>', x.tip).toU8a(), new Uint8Array([0, 0]),
    api.createType('u32', rv.specVersion).toU8a(), api.createType('u32', rv.transactionVersion).toU8a(), api.genesisHash.toU8a(), hexToU8a(bh), new Uint8Array([0]));
  const sig = x.signature.toU8a().slice(-64);
  console.log(idx, x.method.section, x.method.method, 'signer', encodeAddress(pk, 0), 'sigtype', x.inner.signature.signature.type, 'era', x.era.toHex(), 'birth', birth.toString(), 'nonce', x.nonce.toNumber(), 'tip', x.tip.toString(), 'assetId', JSON.stringify(x.inner.signature.assetId?.toJSON?.()), 'mode', x.inner.signature.mode?.toString(), 'spec', rv.specVersion.toNumber(), 'verify', ed25519Verify(payload, sig, pk));
  out.push({ extrinsic: raw, hash: blake2AsHex(hexToU8a(raw), 256), signer: encodeAddress(pk, 0), publicKey: u8aToHex(pk), dest: x.method.args[0].toString(), amount: x.method.args[1].toString(), nonce: x.nonce.toNumber(), era: x.era.toHex(), birth: Number(birth.toString()), birthHash: bh, specVersion: rv.specVersion.toNumber(), transactionVersion: rv.transactionVersion.toNumber(), payload: u8aToHex(payload) });
}
fs.writeFileSync('reais.json', JSON.stringify(out, null, 2));
process.exit(0);
