/* Fora do codigo vendorizado (argon2.lock nao lista este arquivo): so expoe para o
   Swift o BLAKE2b de referencia que ja vem com o Argon2, sem uma segunda
   implementacao do hash. */
#include "blake2/blake2.h"
#include "include/escalibur_blake2b.h"

int escalibur_blake2b(void *out, size_t outlen, const void *in, size_t inlen, const void *key, size_t keylen) {
    return blake2b(out, outlen, in, inlen, key, keylen);
}
