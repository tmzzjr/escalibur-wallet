import CArgon2

/// BLAKE2b (RFC 7693), pela implementacao de referencia que ja vem vendorizada com o
/// Argon2 (`CArgon2/blake2`, travada por `argon2.lock`). Endereco da Sui, do Cardano e
/// checksum do SS58 da Polkadot usam este hash com saidas de tamanhos diferentes.
public enum Blake2b {
    /// `outputLength` de 1 a 64 bytes; `key` de 0 a 64 bytes.
    public static func hash(_ data: [UInt8], outputLength: Int, key: [UInt8] = []) -> [UInt8] {
        precondition((1...64).contains(outputLength), "BLAKE2b: saida de 1 a 64 bytes")
        precondition(key.count <= 64, "BLAKE2b: chave de ate 64 bytes")
        var out = [UInt8](repeating: 0, count: outputLength)
        let status = out.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    escalibur_blake2b(output.baseAddress, outputLength, input.baseAddress, data.count,
                                      key.isEmpty ? nil : keyBytes.baseAddress, key.count)
                }
            }
        }
        precondition(status == 0, "BLAKE2b de referencia recusou os parametros")
        return out
    }
}
