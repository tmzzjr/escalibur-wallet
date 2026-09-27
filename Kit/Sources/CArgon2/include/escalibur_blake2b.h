#ifndef ESCALIBUR_BLAKE2B_H
#define ESCALIBUR_BLAKE2B_H
#include <stddef.h>
/* BLAKE2b de referencia (RFC 7693), de blake2/blake2b.c. outlen de 1 a 64, keylen de
   0 a 64. Devolve 0 quando deu certo. */
int escalibur_blake2b(void *out, size_t outlen, const void *in, size_t inlen, const void *key, size_t keylen);
#endif
