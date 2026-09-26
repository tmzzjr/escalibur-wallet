// Gera ton-core-vectors.json com a implementacao de referencia da TON (ton-core).
//
// Reproduzir:
//   npm install @ton/core@0.63.1 @ton/ton@16.3.0 @ton/crypto@3.3.0
//   node gerar-vetores.js > ton-core-vectors.json
//
// Nada daqui roda no app nem no teste: o teste le so o JSON. O script fica ao lado
// para quem auditar poder regenerar os vetores e conferir que nao foram inventados.
const { beginCell, Cell, storeStateInit, comment } = require('@ton/core');
const { WalletContractV4, WalletContractV5R1 } = require('@ton/ton');
const { keyPairFromSeed } = require('@ton/crypto');

// Chaves privadas (seeds Ed25519) dos testes do trustwallet/wallet-core
// (rust/tw_tests/tests/chains/ton/ton_address.rs e ton_sign*.rs).
const seeds = [
  '5849481021e305dfdf9f0eaf87e07f15efec3fde8d8ed639c9fcf0bc351d998b',
  '63474e5fe9511f1526a50567ce142befc343e71a49b865ac3908f58667319cb8',
  'c38f49de2fb13223a9e7d37d5d0ffbdd89a5eb7c8b0ee4d1c299f2cefe7dc4a0',
  '3570e35f54cfb843f2cfaf2b8cae7ceeb7b32225d7dbbd86f611056d74d9073e',
];

const wallets = seeds.map((seed) => {
  const { publicKey } = keyPairFromSeed(Buffer.from(seed, 'hex'));
  const v4 = WalletContractV4.create({ workchain: 0, publicKey });
  const v5 = WalletContractV5R1.create({ workchain: 0, publicKey });
  return {
    seed,
    publicKey: publicKey.toString('hex'),
    v4r2: {
      raw: v4.address.toRawString(),
      bounceable: v4.address.toString({ bounceable: true }),
      nonBounceable: v4.address.toString({ bounceable: false }),
    },
    v5r1: {
      raw: v5.address.toRawString(),
      nonBounceable: v5.address.toString({ bounceable: false }),
    },
  };
});

// BOC do state init da primeira carteira V4R2, nas tres formas que o ton-core escreve.
const first = WalletContractV4.create({ workchain: 0, publicKey: Buffer.from(wallets[0].publicKey, 'hex') });
const stateInit = beginCell().store(storeStateInit(first.init)).endCell();
const stateInitBoc = {
  hash: stateInit.hash().toString('hex'),
  crc: stateInit.toBoc({ idx: false, crc32: true }).toString('hex'),
  plain: stateInit.toBoc({ idx: false, crc32: false }).toString('hex'),
  indexed: stateInit.toBoc({ idx: true, crc32: true }).toString('hex'),
};

// Comentarios: curto, exatamente cheio (123 bytes), um byte alem, e longo com
// caracteres de varios bytes cortados na fronteira das celulas.
const comments = [
  'test comment',
  'a'.repeat(123),
  'a'.repeat(124),
  'Pagamento de teste ção 🚀 '.repeat(12),
].map((text) => {
  const cell = comment(text);
  return { text, hash: cell.hash().toString('hex'), boc: cell.toBoc({ idx: false, crc32: true }).toString('hex') };
});

// Corpo transfer do TEP-74 com o layout do Tonkeeper
// (tonkeeper-web packages/core/src/service/ton-blockchain/encoder/jetton-encoder.ts,
// encodeTransferBody): comentario em forward_payload por referencia.
const { Address } = require('@ton/core');
const jettonBody = beginCell()
  .storeUint(0xf8a7ea5, 32)
  .storeUint(1727000000n, 64)
  .storeCoins(1234567n)
  .storeAddress(Address.parse('UQDYW_1eScJVxtitoBRksvoV9cCYo4uKGWLVNIHB1JqRRyQx'))
  .storeAddress(Address.parse(wallets[0].v4r2.nonBounceable))
  .storeMaybeRef(null)
  .storeCoins(1n)
  .storeMaybeRef(comment('deposito 12345'))
  .endCell();

console.log(JSON.stringify({
  source: 'ton-core 0.63.1, @ton/ton 16.3.0, @ton/crypto 3.3.0 (gerar-vetores.js)',
  wallets,
  stateInitBoc,
  comments,
  jettonTransferWithComment: {
    queryId: '1727000000',
    amount: '1234567',
    destination: 'UQDYW_1eScJVxtitoBRksvoV9cCYo4uKGWLVNIHB1JqRRyQx',
    responseDestination: wallets[0].v4r2.nonBounceable,
    forwardTon: '1',
    comment: 'deposito 12345',
    hash: jettonBody.hash().toString('hex'),
    boc: jettonBody.toBoc({ idx: false, crc32: true }).toString('hex'),
  },
}, null, 2));
