// swift-tools-version: 6.0
//
// O nucleo da Escalibur Wallet.
//
// Dois modulos Swift, com uma fronteira que e verificada por script:
//
//   EscaliburCore     chaves, assinatura, codificacao das redes, envelope .esclbr.
//                     Nao tem codigo de rede. Nada que sai daqui toca a internet.
//   EscaliburNetwork  provedores, RPC, precos, cotacoes de swap. Nunca ve seed,
//                     chave privada, PIN ou senha: recebe e devolve dados publicos.
//
// As duas bibliotecas em C sao compiladas do fonte, dentro do repositorio, e
// travadas por digesto (secp256k1.lock, argon2.lock). Nenhum pacote remoto.
import PackageDescription

let package = Package(
    name: "EscaliburKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EscaliburCore", targets: ["EscaliburCore"]),
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
            name: "EscaliburNetwork",
            dependencies: ["EscaliburCore"],
            path: "Sources/EscaliburNetwork"
        ),
        .testTarget(
            name: "EscaliburCoreTests",
            dependencies: ["EscaliburCore"],
            path: "Tests/EscaliburCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "EscaliburNetworkTests",
            dependencies: ["EscaliburNetwork"],
            path: "Tests/EscaliburNetworkTests"
        ),
    ]
)
