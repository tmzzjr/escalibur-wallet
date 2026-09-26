import Foundation

/// Gerado por tools/vendor_wordlists.py. Nao edite a mao.
///
/// Uma wordlist adulterada por um byte e uma carteira diferente, e o app abriria
/// a carteira errada sem nenhum sinal. Por isso a lista embarcada e conferida
/// contra estes digestos toda vez que e carregada, e uma divergencia impede o app
/// de abrir qualquer cofre em vez de degradar.
public enum WordlistDigest {
    public static let sha256: [BIP39Language: String] = [
        .english: "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda",
        .japanese: "2eed0aef492291e061633d7ad8117f1a2b03eb80a29d0e4e3117ac2528d05ffd",
        .chineseSimplified: "5c5942792bd8340cb8b27cd592f1015edf56a8c5b26276ee18a482428e7c5726",
        .chineseTraditional: "417b26b3d8500a4ae3d59717d7011952db6fc2fb84b807f3f94ac734e89c1b5f",
        .french: "ebc3959ab7801a1df6bac4fa7d970652f1df76b683cd2f4003c941c63d517e59",
        .italian: "d392c49fdb700a24cd1fceb237c1f65dcc128f6b34a8aacb58b59384b5c648c2",
        .korean: "9e95f86c167de88f450f0aaf89e87f6624a57f973c67b516e338e8e8b8897f60",
        .spanish: "46846a5a0139d1e3cb77293e521c2865f7bcdb82c44e8d0a06a2cd0ecba48c0b",
        .czech: "7e80e161c3e93d9554c2efb78d4e3cebf8fc727e9c52e03b83b94406bdcc95fc",
        .portuguese: "2685e9c194c82ae67e10ba59d9ea5345a23dc093e92276fc5361f6667d79cd3f",
    ]

    /// A lista de 1024 palavras do SLIP-39, que nao pertence a idioma nenhum.
    public static let slip39 = "bcc4555340332d169718aed8bf31dd9d5248cb7da6e5d355140ef4f1e601eec3"
}
