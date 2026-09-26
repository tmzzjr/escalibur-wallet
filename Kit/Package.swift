// swift-tools-version: 6.0
//
// O nucleo da Escalibur Wallet.
//
// Quatro modulos Swift, com fronteiras verificadas por script (tools/verificar.sh):
//
//   EscaliburCore     primitivas: buffer seguro, hashes, curvas, Argon2id, BIP-39,
//                     codificacoes e o envelope .esclbr compartilhado com o Escalibur.
//   EscaliburChains   as redes: enderecos, transacoes, validacao do que se assina.
//                     Puro: sem rede e sem chave privada. Diz O QUE assinar.
//   EscaliburKeys     chaveiro, Secure Enclave, derivacao privada e o assinador, que
//                     so aceita um plano validado por EscaliburChains.
//   EscaliburNetwork  provedores, RPC, precos, cotacoes. Nunca ve seed, chave, PIN
//                     ou senha, e nunca importa EscaliburKeys.
//
// As duas bibliotecas em C sao compiladas do fonte, dentro do repositorio, e
// travadas por digesto (secp256k1.lock, argon2.lock). Nenhum pacote remoto.
import PackageDescription

let package = Package(
    name: "EscaliburKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EscaliburCore", targets: ["EscaliburCore"]),
        .library(name: "EscaliburChains", targets: ["EscaliburChains"]),
        .library(name: "EscaliburKeys", targets: ["EscaliburKeys"]),
        .library(name: "EscaliburNetwork", targets: ["EscaliburNetwork"]),
    ],
    targets: [
        .target(
            name: "CSecp256k1",
            path: "Sources/CSecp256k1",
            exclude: ["upstream/COPYING"],
            sources: [
                "upstream/src/secp256k1.c",
                "upstream/src/precomputed_ecmult.c",
                "upstream/src/precomputed_ecmult_gen.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("ENABLE_MODULE_RECOVERY", to: "1"),
                .define("ENABLE_MODULE_EXTRAKEYS", to: "1"),
                .define("ENABLE_MODULE_SCHNORRSIG", to: "1"),
                .define("ECMULT_WINDOW_SIZE", to: "15"),
                .define("COMB_BLOCKS", to: "43"),
                .define("COMB_TEETH", to: "6"),
                .headerSearchPath("upstream"),
                .headerSearchPath("upstream/src"),
            ]
        ),
        .target(
            name: "CArgon2",
            path: "Sources/CArgon2",
            exclude: ["LICENSE.txt"],
            sources: ["argon2.c", "core.c", "encoding.c", "ref.c", "thread.c", "blake2/blake2b.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        ),
        .target(
            name: "EscaliburCore",
            dependencies: ["CSecp256k1", "CArgon2"],
            path: "Sources/EscaliburCore",
            resources: [.copy("Resources/Wordlists")]
        ),
        .target(
            name: "EscaliburChains",
            dependencies: ["EscaliburCore"],
            path: "Sources/EscaliburChains"
        ),
        .target(
            name: "EscaliburKeys",
            dependencies: ["EscaliburCore", "EscaliburChains"],
            path: "Sources/EscaliburKeys"
        ),
        .target(
            name: "EscaliburNetwork",
            dependencies: ["EscaliburCore", "EscaliburChains"],
            path: "Sources/EscaliburNetwork"
        ),
        .testTarget(
            name: "EscaliburCoreTests",
            dependencies: ["EscaliburCore"],
            path: "Tests/EscaliburCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "EscaliburChainsTests",
            dependencies: ["EscaliburChains"],
            path: "Tests/EscaliburChainsTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "EscaliburKeysTests",
            dependencies: ["EscaliburKeys"],
            path: "Tests/EscaliburKeysTests"
        ),
        .testTarget(
            name: "EscaliburNetworkTests",
            dependencies: ["EscaliburNetwork"],
            path: "Tests/EscaliburNetworkTests",
            resources: [.copy("FixturesB")]
        ),
    ]
)
