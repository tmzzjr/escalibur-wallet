// A ponte para o libsecp256k1 do bitcoin-core, compilado do fonte junto com o app.
//
// Os arquivos em ../upstream sao copia byte a byte da tag v0.8.0 e estao travados
// por digesto em secp256k1.lock. Nenhum binario de terceiro fica entre a seed do
// dono e a assinatura.
#include "../upstream/include/secp256k1.h"
#include "../upstream/include/secp256k1_recovery.h"
#include "../upstream/include/secp256k1_extrakeys.h"
#include "../upstream/include/secp256k1_schnorrsig.h"
