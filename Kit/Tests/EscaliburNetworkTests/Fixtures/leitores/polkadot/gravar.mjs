// Grava as respostas da Polkadot Asset Hub para os testes do PolkadotReader, todas no
// mesmo bloco finalizado, direto do RPC da Parity (JSON-RPC por POST, sem chave), do
// sidecar da Parity e do indexador da Nova. Uso: node gravar.mjs <pasta>
import fs from 'node:fs';
import { decodeAddress, blake2AsHex } from '@polkadot/util-crypto';
import { u8aToHex } from '@polkadot/util';
const out = process.argv[2];
const RPC = 'https://polkadot-asset-hub-rpc.polkadot.io';
const dono = '1626DFYAYv5UGwSy6dz3yiGExMxxik68RqQbusnb4MCHEY6e';
const vazia = '13nN6BGAoJwd7Nw1XxeBCx5YcBXuYnL94Mh7i3xBprqVSsFk';
const key = (a) => { const id = decodeAddress(a); return '0x26aa394eea5630e07c48ae0c9558cef7b99d880ec681799c0cf30e8886371da9' + blake2AsHex(id, 128).slice(2) + u8aToHex(id).slice(2); };
async function rpc(method, params) {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  return await r.text();
}
const save = (name, text) => fs.writeFileSync(`${out}/${name}.json`, text.trim() + '\n');
const fin = JSON.parse(await rpc('chain_getFinalizedHead', [])).result;
save('finalizedHead', await rpc('chain_getFinalizedHead', []));
const header = await rpc('chain_getHeader', [fin]);
save('header', header);
const n = parseInt(JSON.parse(header).result.number, 16);
save('blockHash-referencia', await rpc('chain_getBlockHash', [n]));
save('blockHash-genese', await rpc('chain_getBlockHash', [0]));
save('runtimeVersion', await rpc('state_getRuntimeVersion', [fin]));
save('storage-dono', await rpc('state_getStorage', [key(dono), fin]));
save('storage-vazia', await rpc('state_getStorage', [key(vazia), fin]));
// A extrinsic da estimativa: a do primeiro vetor do polkadot-js (mesmo formato).
const v = JSON.parse(fs.readFileSync('vetores.json'));
const ext = Buffer.from(v.casos[0].extrinsic.slice(2), 'hex');
const len = Buffer.alloc(4); len.writeUInt32LE(ext.length);
save('query_info', await rpc('state_call', ['TransactionPaymentApi_query_info', '0x' + Buffer.concat([ext, len]).toString('hex'), fin]));
// Um bloco com transferencias reais, e o sidecar do mesmo bloco reduzido ao que o leitor le.
const bloco = 21172670;
const bh = JSON.parse(await rpc('chain_getBlockHash', [bloco])).result;
save('blockHash-21172670', await rpc('chain_getBlockHash', [bloco]));
save('block-21172670', await rpc('chain_getBlock', [bh]));
const side = await (await fetch(`https://polkadot-asset-hub-public-sidecar.parity-chains.parity.io/blocks/${bloco}?noFees=true&eventDocs=false&extrinsicDocs=false`)).json();
save('sidecar-21172670', JSON.stringify({ number: side.number, hash: side.hash, extrinsics: side.extrinsics.map((x) => ({ method: x.method, hash: x.hash, success: x.success })) }));
const nova = 'https://subquery-history-polkadot-ah-prod.novasama-tech.org';
const gql = async (body) => (await fetch(nova, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })).text();
save('historico-metadados', await gql({ query: '{ _metadata { genesisHash } }' }));
save('historico-dono', await gql({ query: 'query($a: String!) { historyElements(filter: {address: {equalTo: $a}, transfer: {isNull: false}}, orderBy: TIMESTAMP_DESC, first: 30) { nodes { id extrinsicHash timestamp transfer } } }', variables: { a: dono } }));
console.log('bloco de referencia', n, fin);
