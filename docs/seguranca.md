# Escalibur Wallet: desenho de segurança da fundação

O que li: README, `docs/criptografia.md`, `docs/custodia.md`, `docs/formato.md`, `Crypto/` (SecureBytes, KeyDerivation, VaultFormat, VaultFile), `Vault/AppLock.swift`, `App/PlatformGuards.swift`, `tools/verificar.sh`, e os trechos de importação e colagem em `Features/` e em `Vault/VaultStore.swift`. Os nomes de API foram conferidos no SDK local (Xcode 26.6, iPhoneOS 26.5 SDK).

Premissa: o atacante tem o aparelho, cópia de tudo que o app grava, GPU e tempo. A palavra "impenetrável" não entra na interface nem na documentação. Cada item abaixo diz quanto custa quebrar e onde a defesa para.

Números de referência:
- PIN de 6 dígitos: 10^6 combinações.
- Envelope com os parâmetros de referência do Escalibur (512 MiB, t=4, cerca de 4 GiB de tráfego de memória por chute). Uso as mesmas taxas da tabela do README: cerca de 10^3 chutes/s para um amador com 8 GPUs, 1,2×10^5/s para crime organizado e 1,2×10^7/s para um Estado.

---

## 0. O que quebra no núcleo reaproveitado

No Escalibur de hoje nenhum destes achados é grave, porque lá o PIN não protege a frase. Copiados como estão para a carteira, vários passam a ser.

**A1. Crítico se copiado: o verificador de PIN do AppLock cai offline em minutos.**
- Onde: `escalibur/Escalibur/Vault/AppLock.swift` grava `salt || Argon2id(PIN, m=64 MiB, t=3, p=1)` num item de chaveiro sem ACL.
- Como se explora:
  1. O ladrão vê o código do iPhone por cima do ombro e leva o aparelho. Esse é o golpe dominante de roubo de iPhone hoje.
  2. Com ferramenta forense ou exploit para aquela versão do iOS, extrai o item de chaveiro do PIN do AppLock do aparelho desbloqueado.
  3. Testa 10^6 PINs a 384 MiB de tráfego cada. São cerca de 403 TB, ou seja, 7 minutos teóricos numa RTX 4090 (cerca de 1 TB/s) e em torno de meia hora na prática.
- Na carteira, com o PIN protegendo a seed desse jeito, isso entrega a seed. O conserto está na seção 2: **não pode existir verificador de PIN fora do chaveiro e do SE.**

**A2. O contador de tentativas falha aberto.**
- Onde: `unlock(with:)` faz `try? store(attempts.data, ...)`, e `store` executa `SecItemDelete` seguido de `SecItemAdd`.
- Como se explora: o ladrão, com o aparelho desbloqueado, enche o armazenamento (gravando vídeo 4K). O `SecItemAdd` falha depois do delete, o registro de atraso some, e cada tentativa volta a esperar zero.
- Conserto: o item é criado uma vez no cadastro e depois só alterado com `SecItemUpdate`. Se gravar o incremento falhar, a tentativa **não é avaliada**.

**A3. O prazo monotônico sobrevive ao reboot e tranca o dono por dias.**
- Onde: `remaining = max(wallDeadline − agora, uptimeDeadline − uptime)`. O `CLOCK_MONOTONIC_RAW` recomeça do zero a cada boot.
- Como acontece: o dono erra duas vezes (1 s de atraso) e o aparelho reinicia antes de um acerto. Pode ser o reinício por inatividade de 72 h do iOS 18.1+. Depois disso, `uptimeDeadline − uptime` vale todo o uptime anterior, e o app fica em `.throttled` por tantos dias quanto o aparelho estava ligado. Numa carteira, isso é dinheiro inacessível.
- Conserto: gravar `kern.boottime` (sysctl `KERN_BOOTTIME`) junto com o prazo. Se o boot mudou, descarte o prazo monotônico e recomece a espera cheia a partir de agora. Reiniciar então não encurta a espera e também não a congela por dias.

**A4. Abrir um envelope transforma a seed em `String`.**
- Onde: `VaultFile.open` chama `VaultContents.decode`, que usa `String(decoding:)` para a frase e para a 25ª palavra (`escalibur/Escalibur/Crypto/VaultFile.swift`, linhas 86–101).
- O lacre já tem `SealingContents` com `SecureBytes`, mas a abertura não tem o equivalente. Além disso, `SealingContents.passphrase` é `String`, e `Mnemonic.validate` recebe `String`.
- Consequência: na carteira, importar um envelope deixaria a seed no heap, sem endereço para zerar, pela vida inteira do processo.
- Conserto: criar `OpeningContents`, que decodifica o bloco direto para `SecureBytes` (frase e passphrase) e zera o `block`. A validação BIP-39 passa a trabalhar sobre bytes.

**A5. Três campos que a carteira não pode ignorar.**
- (a) `kind == .slip39Share`: uma parte SLIP-39 sozinha não restaura carteira nenhuma.
- (b) `passphrase` não vazia: se for ignorada, o resultado é uma carteira válida e vazia. O dono conclui que perdeu o dinheiro, ou pior, recebe fundos na carteira errada.
- (c) Índice de idioma desconhecido: hoje cai em `.english` sem aviso (linhas 76–78).
- Conserto: recusar `slip39Share` com mensagem própria, honrar a passphrase e recusar idioma desconhecido. Um slot que autentica mas não decodifica deve ter erro próprio, e não virar "senha errada". Essas mensagens só aparecem depois que a tag AEAD fecha, então não servem de oráculo de senha.

**A6. Um envelope hostil por AirDrop derruba o app.**
- Onde: a leitura aceita até m=1 GiB, t=16 e p=8, e `ShelfView.importVault` faz `Data(contentsOf:)` sem conferir o tamanho.
- Como se explora: um arquivo de 16.504 bytes com m=1 GiB e t=16 faz o Argon2 ser morto pelo jetsam num iPhone de 3–4 GB, ou prende a CPU por mais de um minuto sem opção de cancelar. Outro caminho: um arquivo de vários GB estoura a memória já na leitura.
- É negação de serviço, não roubo. O conserto está na seção 6.

**A7. `UIScreen.isCaptured` está marcado para depreciação.** O SDK diz "Use the sceneCaptureState in UITraitCollection instead". O `CaptureGuard` precisa migrar para `UITraitCollection.sceneCaptureState` (iOS 17+) com `registerForTraitChanges`.

---

## 1. Modelo de ameaça

**T1. Ladrão com o aparelho bloqueado (BFU, ou AFU bloqueado)**
- Defesa:
  - Tudo fica em `WhenPasscodeSetThisDeviceOnly` ou `NSFileProtectionComplete`. As chaves de classe somem cerca de 10 s depois do bloqueio.
  - A RK só existe embrulhada por chaves do Secure Enclave.
  - Nada abre sem o código do iPhone, cujo chute é limitado pelo SEP: no mínimo 80 ms por tentativa, com atrasos crescentes.
  - No iOS 18.1+, 72 h sem desbloqueio fazem o aparelho reiniciar e voltar a BFU.
- O que sobra: código do aparelho fraco somado a um exploit forense leva ao caso T3.

**T2. Ladrão com o aparelho desbloqueado, ou que viu o código do iPhone. É o caso real mais comum.**
- Defesa:
  - O app pede PIN ou biometria ao abrir. Trava ao ir para segundo plano (tolerância escolhida pelo dono: na hora, 30 s, 1 min ou 5 min; alongar pede o PIN) e trava na hora em `UIApplication.protectedDataWillBecomeUnavailableNotification`.
  - A biometria usa `.biometryCurrentSet`, **nunca** `.userPresence` nem `.devicePasscode`. O código do iPhone não abre nada aqui.
  - Cadastrar um rosto novo destrói o slot biométrico em vez de abri-lo.
  - A escada de atraso do PIN dobra do nono erro em diante, de 3 horas até 7 dias por tentativa: pela interface são 18 chutes em 30 dias e 66 em um ano (§2.7).
  - Revelar, lacrar num envelope ou remover uma carteira exige o PIN e, com o Face ID ligado, o rosto também (A1, §2.10). Quem viu só o PIN não leva a frase: para trocar o rosto ele precisa também do código do iPhone, e aí espera 24 horas (abaixo).
- O que sobra:
  - Contra PIN escolhido por gente, sem lista de bloqueio, poucos chutes ainda acertam uma parte dos donos (Markert et al., S&P 2020, tabela VI, grupos de controle): 6% dos PINs de 6 dígitos em 10 chutes, 9% em 30 e 14% em 100 (7, 12 e 18 de 127). O primeiro chute do ladrão é o código do iPhone que ele viu. Com o PIN certo, ele envia o saldo que o app mostra (envio aceita Face ID ou PIN); a frase continua pedindo o rosto.
  - Quem viu o código do iPhone e o PIN pode cadastrar o próprio rosto: o slot da biometria cai, o que pede PIN e rosto fica recusado até alguém religar o Face ID no app, e religar começa 24 horas de espera (§2.5). Depois disso, PIN e o rosto dele mostram a frase. A Proteção de Aparelho Roubado do iOS atrasa o cadastro do rosto.

**T3. Execução de código no aparelho desbloqueado (jailbreak, exploit forense, malware com privilégio)**
- Defesa:
  - Nenhum byte gravado abre fora deste Secure Enclave.
  - O PIN não tem verificador extraível, mas o sal e os parâmetros do Argon2id podem ser lidos e os 10^6 Argon2id pré-calculados numa GPU; no aparelho sobra a passagem pelo SE, cerca de 22 ms por chute. Total: 3 a 6 horas em média, 6 a 11 horas no pior caso (auditoria de 15/10/2026). Com PIN de 4 dígitos, 2 a 3 minutos em média e 4 a 6 no pior caso.
  - A biometria continua exigindo o rosto, porque a decisão acontece no SEP.
  - As opções de valor alto (seção 2.6) sobem o custo para milhares de anos.
  - A seed só existe em memória durante a assinatura.
- O que sobra: o PIN de 6 dígitos cai em horas, e o de 4 em minutos. Malware dentro do processo durante uma assinatura vê a seed. A interface pode ser adulterada para mostrar A e assinar B. Isso está aceito, com os números, no fim do relatório.

**T4. MITM (Wi-Fi hostil, perfil com CA instalada pelo usuário, CA comprometida)**
- Defesa: ATS padrão sem exceções, pinning só do relay, e principalmente nenhuma decisão de assinatura baseada em dado de rede (seções 4 e 5).
- O que sobra: SNI e DNS revelam que o app está em uso. Disponibilidade.

**T5. Provedor malicioso ou comprometido** (calldata adulterada; saldo, nonce, taxa ou UTXO falsos; preço falso)
- Defesa:
  - Calldata decodificada localmente contra a intenção do usuário e contra uma allowlist compilada.
  - Aprovação no valor exato. O `minOut` é garantido pelo contrato.
  - Simulação em 2 provedores e consenso de 2 ou mais provedores.
  - Tetos de taxa.
  - Na BTC, o valor de cada UTXO é conferido pela transação anterior.
  - Na XRPL, o recebimento mostrado é o `delivered_amount`.
- O que sobra: uma rota ruim dentro da tolerância de slippage. Negação de serviço.

**T6. Nosso relay comprometido**
- Pode tudo o que T5 pode, e ainda vê IP mais endereços consultados e pode reter broadcasts.
- Não recebe segredo, não guarda estado e não configura nada de segurança no app.
- Defesa extra: broadcast por dois caminhos e um modo "direto aos provedores".
- O que sobra: privacidade (até existir OHTTP) e perda limitada ao slippage.

**T7. Cadeia de suprimentos**
- Defesa:
  - Nenhum pacote remoto e nenhum binário de terceiro. Todo C vendorizado tem lock SHA-256 e vetores de teste.
  - `verificar.sh` roda no CI a cada push na main.
  - No GitHub, desde 14/10/2026 (pentest, M2): a main não aceita force push nem ser apagada; ações só da GitHub e fixadas por SHA (o repositório exige); varredura de segredos com bloqueio no push; relato privado de vulnerabilidade ligado.
  - Release só de tag assinada (16/10/2026, auditoria 4, R7-M3): o `.github/workflows/release.yml` confere a tag com `git tag -v` contra `.github/assinantes`, roda o `verificar.yml` no commit dela e, num runner limpo, monta, assina pela nuvem da Apple, confere os entitlements, atesta e envia o `.ipa`; os segredos da App Store Connect só existem no environment `release`, que pede a aprovação do dono. O que isso prova e o que não prova está em `docs/release.md`. Passa a valer quando o dono cadastrar a chave e criar o environment, a regra das tags e o check `verificar` obrigatório na main.
  - Ainda não: commit assinado obrigatório e segundo revisor. Um mantenedor só não passa por revisão, e um token do GitHub vazado empurra código; para virar release, ainda precisa de uma tag assinada por uma chave de `.github/assinantes`.
  - Build determinístico, com Xcode fixado.
  - A conta da App Store Connect usa chave de segurança de hardware e tem 2 administradores.
- O que sobra: uma atualização maliciosa publicada com a conta da ASC chega sozinha a quem tem atualização automática. Só terceiros verificando o binário detectam.

**T8. Phishing, envenenamento de endereço, sequestro de área de transferência, tokens falsos**
- Defesa:
  - A v1 não tem navegador de dapps nem WalletConnect.
  - Só se assinam intenções tipadas.
  - Detecção de endereço parecido; filtro de transferências de valor zero, de pó e de tokens fora da lista.
  - Colagem por `PasteButton`, com o endereço mostrado inteiro.
  - Memo e tag obrigatórios detectados pela própria rede.
  - A tela de importar diz, fixo: "ninguém do Escalibur pede suas palavras".
- O que sobra: o dono que ignora um aviso bloqueante.

**T9. Coerção física**
- Defesa honesta: pouca. Modo discreto (saldos ocultos), modo viagem (carteiras removidas do aparelho) e perfil isca opcional. Na carteira quente, só o que se entregaria.
- O que sobra: o código é aberto, então o agressor sabe que a isca existe.

---

## 2. Hierarquia de chaves e armazenamento

### 2.1 Decisões

- **Uma seed BIP-39 independente por carteira, e não uma seed mestra derivando carteiras por índice.**
  - Exportar, revelar, deixar de herança ou sacrificar como isca uma carteira não compromete as outras.
  - Carteiras importadas já são independentes, então o modelo fica uniforme.
- **Uma chave raiz (RK) por instalação e uma DEK por carteira.**
  - PIN e biometria destravam a RK. A RK desembrulha só a DEK da carteira que vai assinar.
  - Um PIN por carteira seria inviável de usar.
  - Com a DEK por carteira: trocar o PIN reembrulha 113 bytes, a opção "carteira-cofre" adiciona um fator só àquela carteira, e apagar uma carteira destrói a DEK dela.
- **O que se guarda é a entropia (16–32 bytes), o idioma e a passphrase, não as palavras.** A frase e a seed de 64 bytes são reconstruídas quando preciso.
- **Carteira nova tem 128 bits (12 palavras) por padrão; 256 bits é opcional.** 2^128 já é o nível de segurança das curvas secp256k1 e ed25519. Com 24 palavras a segurança efetiva não aumenta, e o trabalho de anotar e a chance de erro dobram.
- **Chaves públicas e endereços são derivados na criação e guardados nos metadados.** Mostrar saldo nunca toca a seed.

### 2.2 As chaves

```
PIN ─Argon2id─► AP ─(applicationPassword)─► item rk.pin = ECIES(K_slot.pub, ChaChaPoly(K_pin, RK)) ─SE(K_slot + senha)─► ─K_pin─► RK
                AP ─HKDF(salt, "escalibur-wallet/v1/rk.pin")─► K_pin
                AP ─HKDF(salt, "escalibur-wallet/v2/kpin.senha")─► senha de aplicativo da K_slot
biometria (decisão no SEP) ─────────────────► item rk.bio = ECIES(K_bio.pub, RK) ─SE(K_bio)─► RK
RK ─HKDF "escalibur-wallet/v1/index"──────────► K_idx ─► metadados.bin (xpubs, endereços, nomes, catálogo)
RK ─HKDF(salt_w, "…/v1/dek" ‖ walletID)───────► KEK_w ─► DEK_w ─HKDF(salt_s,"…/v1/seed")─► registro da seed
```

| Chave | O que é | Onde vive |
|---|---|---|
| K_slot (`kpin`, `kpin.novo`) | P-256 no SE, flags `[.privateKeyUsage, .applicationPassword]`, senha derivada do PIN; uma por slot (formato 2, §2.4) | Secure Enclave |
| K_dev | P-256 no SE, flags `[.privateKeyUsage]`, sem senha: só do formato 1, apagada quando o slot migra | Secure Enclave, até a migração |
| K_bio | P-256 no SE, flags `[.privateKeyUsage, .biometryCurrentSet]` | Secure Enclave; só existe com biometria ligada |
| `kand.bio` | P-256 no SE, flags `[.privateKeyUsage, .biometryCurrentSet]`: a camada de fora do `rk.and` que segue o cadastro de rostos (a única em "Bloquear as carteiras", a vigia em "Esperar 24 horas") | Secure Enclave; só no modo reforçado (§2.6) |
| `kand.qualquer` | P-256 no SE, flags `[.privateKeyUsage, .biometryAny]`: a camada de fora que sobrevive a um rosto novo ("Continuar normal" e "Esperar 24 horas"). Só embrulha o miolo, nunca a RK | Secure Enclave; só no modo reforçado |
| `kand.pin.a`, `kand.pin.b` | P-256 no SE, flags `[.privateKeyUsage, .applicationPassword]`, senha derivada do PIN: a camada de dentro, em duas gerações | Secure Enclave; só no modo reforçado |
| AP | Argon2id(PIN), 32 bytes | só em memória, por microssegundos |
| RK | 32 bytes do `SecRandomCopyBytes` | só embrulhada; em claro apenas durante uma operação |
| K_idx | HKDF(RK) | em memória enquanto o app está aberto; protege dado de privacidade, não segredo |
| DEK_w | 32 bytes do CSPRNG | embrulhada por KEK_w |

Cifra simétrica: o mesmo padrão do Escalibur. ChaChaPoly com subchave derivada por HKDF de um salt aleatório de 32 bytes a cada gravação, e nonce fixo em zero. O nonce nunca repete porque a chave nunca repete, e isso sobrevive a restaurar um backup antigo, que um contador não sobreviveria. O AAD de cada registro leva `walletID ‖ versão ‖ tipo`.

O embrulho ECIES usa `SecKeyCreateEncryptedData` com `.eciesEncryptionCofactorVariableIVX963SHA256AESGCM`, que o SDK marca como o algoritmo para código novo. Cada embrulho tem chave efêmera e IV derivado. É uma construção padrão, nada montado à mão.

### 2.3 Atributos exatos

Chaves no Secure Enclave, via `SecKeyCreateRandomKey`:
- `kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom`
- `kSecAttrKeySizeInBits: 256`
- `kSecAttrTokenID: kSecAttrTokenIDSecureEnclave`
- `kSecPrivateKeyAttrs` com `kSecAttrIsPermanent: true`, `kSecAttrApplicationTag: "app.escalibur.wallet.kdev"` (ou `.kbio`, `.kpin`, `.kpin.novo`, e no modo reforçado `.kand.bio`, `.kand.qualquer`, `.kand.pin.a`, `.kand.pin.b`) e `kSecAttrAccessControl: SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, <flags>, nil)`.

Itens de chaveiro (`kSecClassGenericPassword`):
- Atributos comuns: `kSecAttrService "app.escalibur.wallet"`, `kSecAttrSynchronizable: false`, `kSecUseDataProtectionKeychain: true`, e o access group do próprio app. Nenhum grupo compartilhado com extensões.
- `rk.pin`: `kSecAttrAccessControl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.applicationPassword], nil)`. Tanto gravar quanto ler usam `kSecUseAuthenticationContext` com um `LAContext` que recebeu `setCredential(AP, type: .applicationPassword)` e `interactionNotAllowed = true`.
- `rk.bio`, `rk.and` (modo reforçado, §2.6: sem senha de aplicativo de propósito), `seed.<uuid>` (DEK embrulhada mais o registro), `pin.kdf` (salt e parâmetros, não secretos), `pin.digitos` (quantos dígitos tem o PIN, não secreto), `pin.tentativas`, `bio.estado`, `and.estado`, `and.espera` (a espera de "Esperar 24 horas", §2.6), `bio.espera` e `bio.perdido` (a espera e a marca do A1, §2.5): todos com `kSecAttrAccessible: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`.
- Nunca use `kSecAttrAccessible` e `kSecAttrAccessControl` no mesmo item. A classe de proteção vai dentro do `SecAccessControl`.
- **Proibido no projeto inteiro**: `.userPresence`, `.devicePasscode`, `.biometryAny`, `.or` com código do aparelho, `AfterFirstUnlock` e `Always`. O motivo: quem viu o código do iPhone passa por `.userPresence`, e com `.biometryAny` o ladrão cadastra o próprio rosto.
- **A exceção do `.biometryAny`, uma só**: a `kand.qualquer` do modo reforçado (§2.6), na linha dela em `SecureEnclaveWrapper.flags(for:)`. Ela nunca abre nada sozinha: embrulha só o miolo, que ainda pede o PIN pela `kand.pin`, e o único embrulho com ela é o do construtor do registro. O `verificar.sh` confere as duas coisas, que o app nem a nomeia, e que nenhum outro caminho chega a uma flag assim (`.touchIDAny`, flags montadas por `rawValue`, `flags(for:)` chamada com uma chave escrita). O dublê de teste do SE recusa, e acusa em qualquer teste, embrulhar pela `kand.qualquer` algo que não seja o ECIES de uma `kand.pin`, e o `SecureEnclaveWrapper` recusa um segredo de 32 bytes (o tamanho da RK) nela. Contra quem cadastra o próprio rosto, o dono escolhe "Esperar 24 horas" ou "Bloquear as carteiras", que usam a `kand.bio` (`.biometryCurrentSet`).

Arquivos:
- `Library/Application Support/Carteira/metadados.bin` com `NSFileProtectionComplete` (entitlement `com.apple.developer.default-data-protection`, como no Escalibur).
- `isExcludedFromBackup = true`, conferido com `resourceValues` como o `VaultStore` já faz.
- Exceções com a proteção até o primeiro desbloqueio (classe C), porque a checagem em segundo plano roda com o iPhone bloqueado, e o `verificar.sh` confere que só elas existem e que nenhuma toca cofre, chaveiro ou metadados:
  - `Alertas/alertas.json`: as moedas escolhidas para alerta de preço e o último preço visto. Nada de saldo nem endereço.
  - `Recebimentos/recebimentos.json` (aviso de recebimento, oferecido a todos desde 14/10/2026 a pedido do dono): os endereços públicos das contas e o último saldo visto de cada ativo. Nenhuma chave, frase ou nome de carteira. O aviso troca a confidencialidade dos endereços com o iPhone bloqueado depois do primeiro desbloqueio pelo aviso sem servidor. Desde a auditoria 4 (C7-03), uma folha diz esse preço na primeira abertura da carteira, antes do pedido de permissão, e o dono escolhe; a permissão de notificação sozinha não vale como aceite. Carteiras com passphrase e carteiras sem cópia conferida ficam fora do arquivo: com elas nele, quem extrai os dados do aparelho acharia a carteira que o dono quis esconder. Desligar apaga o arquivo e vale para sempre. Os endereços chegam do app destravado (`ReceiptAccounts`); o arquivo do aviso nunca abre os metadados.
  - `Ordens/ordens.json` (avisos da ordem limite): o UID de cada ordem aberta da CoW, a rede e o prazo. O UID traz o endereço do dono, então o arquivo diz quais endereços são do aparelho, como o do recebimento. Serve para perguntar à CoW, com o iPhone bloqueado, se a ordem executou. A ordem sai quando termina, o arquivo some vazio, e o aviso de 24 horas antes do prazo é um alarme local, sem rede. O UID chega do app destravado (`LimitOrderWatch.track`); o arquivo nunca abre metadados nem conta.

Pré-condições para criar ou importar carteira:
- `LAContext().canEvaluatePolicy(.deviceOwnerAuthentication)` verdadeiro, ou seja, o aparelho tem código.
- `SecureEnclave.isAvailable`.

Primeira execução depois da instalação:
- O item de chaveiro sobrevive à desinstalação no iOS. Na primeira abertura depois de instalar, o app apaga o que sobrou, as chaves do SE primeiro.
- Instalação nova é a falta dos três sinais de uso ao mesmo tempo: o marcador nas preferências, o arquivo `instalacao.marca` e o arquivo de metadados (os dois arquivos fora do backup). Só se decide com os dados protegidos disponíveis.
- A conferência roda quando o app termina de abrir (antes do primeiro quadro) e, se o iPhone ainda não tinha sido desbloqueado, quando os dados protegidos ficam disponíveis. No `init` da sessão os dados protegidos ainda aparecem como indisponíveis, mesmo com o iPhone desbloqueado; até o build 3 a limpeza só rodava ali e nunca acontecia (corrigido em 16/10/2026).
- As marcas só são gravadas depois de conferir que nenhum slot da RK e nenhuma chave do SE sobrou. Se uma exclusão falhar, a próxima abertura tenta de novo.
- Com isso, "apagar o app apaga as carteiras" passa a ser verdade, e reinstalar para zerar o contador de tentativas também destrói o que se queria atacar.

Consequência que vai por escrito no onboarding:
- Tirar o código do iPhone destrói as carteiras deste aparelho, porque os itens `WhenPasscodeSet` são apagados.
- Trocar de iPhone exige importar de novo, pelas palavras ou pelo envelope.
- Isso é deliberado: a portabilidade é o backup do dono, não a nuvem.

### 2.4 O PIN

- A entrada vem de um teclado numérico do próprio app e vai direto para `SecureBytes`. O PIN nunca vira `String`.
- **4 ou 6 dígitos (escolha do dono desde 16/10/2026).** Seis é o padrão; quatro é escolhido na própria tela, que diz que quatro são mais fáceis de adivinhar.
  - O tamanho fica em `pin.digitos` (1 byte), um item por slot (`pin.digitos` e `pin.digitos.novo`), gravado antes do slot e apagado junto com ele. A tela precisa dele para fechar o PIN no último dígito sem gastar tentativa.
  - Sem o item, o PIN tem 6 dígitos: é o caso de todo slot gravado antes da escolha. Com o chaveiro mudo ou o registro ilegível, a tela aceita os dois tamanhos: fecha sozinha em 6 e mostra OK em 4. Relê o tamanho ao voltar para a frente e no primeiro dígito de cada PIN.
  - Não é segredo: o iPhone também mostra quantos pontos o código tem. Quem tem execução de código lê o tamanho, e quem tenta pela interface o vê na tela.
- **Sem lista de bloqueio** (decisão do dono, 26/09/2026; ver §2.7). Markert et al. (IEEE S&P 2020) mostram que, com poucas tentativas permitidas, é a lista que decide o jogo; sem ela, o PIN óbvio é o primeiro palpite.
- **AP = Argon2id(PIN, salt 16 bytes do CSPRNG, m=256 MiB, p=2, t calibrado entre 2 e 4 para dar até cerca de 0,8 s).**
  - Os parâmetros ficam gravados em `pin.kdf` e são lidos de lá, o que permite migrar depois.
  - O Argon2 existe mesmo com o chaveiro fazendo a checagem porque é ele que o atacante no aparelho paga a cada chute. Sem ele, cada chute custa milissegundos e 10^6 PINs saem em horas.
- **Não existe digest de PIN em lugar nenhum.** O PIN errado é recusado pelo chaveiro e, de novo, pela camada interna. Não há comparação no código do app, então não há oráculo de tempo.
- **Camada interna (auditoria 1).** Dentro do embrulho do SE, a RK vai cifrada com ChaChaPoly sob K_pin = HKDF(AP, salt). Isso torna o desenho independente do resultado do spike abaixo: se a senha de aplicativo for só uma regra de acesso, quem copiar o item e conseguir usar o SE deste aparelho ainda precisa do PIN, e cada chute custa um Argon2id de 256 MiB. Falha de autenticação na camada interna conta como PIN errado.
- **A chave do PIN no SE tem senha (formato 2, auditoria 3, A1).** A camada interna sozinha não bastava: o SE abria o embrulho sem pedir nada, e quem lesse o item e chamasse o SE uma única vez levava `ChaChaPoly(K_pin, RK)` para testar os 10^6 PINs fora do aparelho, em horas numa placa de vídeo. Agora o embrulho é feito por uma chave do SE com `.privateKeyUsage` e `.applicationPassword`, e a senha é HKDF(AP, salt, "escalibur-wallet/v2/kpin.senha"). O SE só desembrulha com o PIN certo: cada chute passa por este aparelho, um de cada vez, e paga o Argon2id antes.
  - Conferido num iPhone 13 Pro Max em 10/10/2026, com uma chave descartável (`EnclaveSpike`, só no build de teste): a senha certa abre; a errada e a falta dela são recusadas pelo próprio SE (erro do CryptoTokenKit, "dado corrompido": a senha entra na chave); 22 ms por tentativa; sem trava depois de 20 erradas (a trava é o contador do app).
  - Cada slot tem a sua chave (`kpin` e `kpin.novo`), criada junto com ele: a troca de PIN troca a chave. O registro `pin.kdf` ganha um byte de versão (26 bytes).
  - O formato 1 (`K_dev` sem senha) migra no primeiro PIN certo, pelo caminho atômico da troca de PIN com o mesmo PIN: o slot novo é gravado e conferido como pendente, o antigo só sai depois, e a `K_dev` só é apagada com o principal novo conferido. Falha no meio deixa o slot antigo abrindo. Testado de ponta a ponta no simulador, atualizando por cima de uma instalação da versão anterior.
- **O simulador não aplica a senha de aplicativo.** `LAContext.setCredential(_, type: .applicationPassword)` devolve `false` no simulador, e o item é gravado sem ela. Lá, só a camada interna recusa o PIN errado; o teste de interface de ponta a ponta confere isso a cada rodada. No aparelho, `false` é erro e o cadastro para.
- **Troca de PIN atômica:**
  1. Grava `rk.pin.novo` com AP e salt novos, e lê de volta para conferir.
  2. O ponto sem volta é apagar `rk.pin`. Antes dele, qualquer falha apaga o pendente e o PIN antigo continua o único.
  3. Depois dele, a troca está feita: o pendente abre com o PIN novo. A promoção a principal (gravar `rk.pin` com o PIN novo, conferir, apagar o pendente) é tentada na hora e, se falhar, concluída no próximo desbloqueio.
  - Com os dois slots presentes (crash entre os passos 1 e 2), o desbloqueio tenta os dois na mesma tentativa. O antigo abrindo desfaz a troca; o novo abrindo a conclui. Se os dois slots têm tamanhos diferentes, a tela fecha sozinha no maior, e o menor vai pela tecla OK, sem gastar tentativa.
  - Uma troca nova é recusada enquanto houver uma interrompida: o desbloqueio resolve primeiro.
- **Cadastro só com resposta definitiva.** O chaveiro que não consegue responder (`probe` = desconhecido) nunca vira "não existe": `isSetUp` responde sim e o cadastro recusa. `createKey(.device)` nunca substitui a K_dev em silêncio. Sobras de um cadastro interrompido só são apagadas quando nenhum slot da RK existe.
- **Contador de tentativas.** O prazo usa só o relógio monotônico (`CLOCK_MONOTONIC_RAW`, que conta o tempo dormindo) e a identidade do boot: `kern.bootsessionuuid` no Mac e no simulador; no iPhone a sandbox recusa essa leitura, e vale o instante do boot (`kern.boottime`), comparado com folga de 10 s. Mudar o relógio de parede não encurta nem estica a espera. Depois de reiniciar, a espera recomeça cheia; ler o contador nunca grava, quem regrava é a abertura do app e a volta ao primeiro plano. Face ID aceito não zera o contador (auditoria 2, B4): só o PIN certo zera.
- **Face ID recusado não apaga o atalho.** Só o cadastro de rostos diferente do gravado ao ligar, ou a K_bio que o SEP já invalidou, apagam `rk.bio` (§2.5). Face ID indisponível (tirado do app, Espelhamento do iPhone, falha passageira do sistema) não apaga nada: o que pede PIN e rosto recusa até ele voltar.

**Spike obrigatório antes de construir sobre isto.**
- O que é documentado: o header do SDK descreve `kSecAccessControlApplicationPassword` como "Application provided password for data encryption key generation. This is not a constraint but additional item encryption mechanism."
- O que não é documentado: onde a senha é processada e se há limite de tentativas.
- O DTS da Apple disse que combinar applicationPassword com biometria numa chave do SE não é suportado. Por isso o applicationPassword vai no item de chaveiro, não na chave do SE, e a biometria ganhou um slot separado.
- Testes de aceitação, em aparelho físico com iOS 17.x, 18.x e 26.x:
  1. Com a AP certa, o item é lido sem nenhuma interface.
  2. Com a AP errada, a leitura falha com `errSecAuthFailed`, sem interface.
  3. Sem credencial e com `interactionNotAllowed`, a leitura falha com `errSecInteractionNotAllowed`.
  4. Tirar o código do aparelho apaga o item.
  5. Medir o tempo de cada falha.
- **Plano B, se o spike falhar:** o PIN vira só trava do app, como no Escalibur. Assinar passa a exigir biometria (K_bio) ou uma senha alfanumérica longa, com Argon2id de 512 MiB, t=4 e p=4. Nunca 6 dígitos protegendo seed sem uma checagem por chute no SEP ou no chaveiro.

### 2.5 Biometria: ligar, desligar e o cadastro que muda

- **Ligar**:
  - Exige o PIN naquele momento, para recuperar a RK.
  - Cria K_bio e grava `rk.bio`.
  - Grava o hash de estado da biometria: `LAContext().domainState.biometry.stateHash` no iOS 18+, `evaluatedPolicyDomainState` no 17.
  - Faz uma decifragem de teste com o prompt de Face ID antes de mostrar "ligado".
- **Desligar**: pede o PIN e o rosto (A1), porque com o Face ID desligado o que pedia os dois passa a pedir só o PIN. Depois, `SecItemDelete` de `rk.bio` e de K_bio. O slot do PIN não é tocado.
- **O cadastro de rostos mudou**:
  - O SEP invalida K_bio e a decifragem falha. O app vê isso no primeiro uso do Face ID ou na abertura (slot sem a chave).
  - O app compara o hash e grava, antes de apagar o slot, a espera de 24 horas (`bio.espera`, no relógio monotônico; depois de reiniciar recomeça cheia) e a marca de perdido (`bio.perdido`, sem prazo). Se uma delas não gravar, o slot fica e o rosto continua sem abrir: nunca passa a valer só o PIN.
  - Diz: "O Face ID deste iPhone mudou desde que foi ligado aqui. Entre com o PIN; depois você pode religar."
  - Com a marca, ver as palavras, lacrar envelope, remover carteira e desligar o Face ID recusam antes de pedir o PIN e a voz, até alguém religar o Face ID. Vencer a espera não basta: nunca volta sozinho a pedir só o PIN. Abrir o app e enviar continuam pelo PIN.
  - Religar exige o PIN e confere o rosto na hora. Religar depois de uma queda, ou por cima de um slot que existe, tira a marca e começa a espera de 24 horas a partir dali. O primeiro Face ID de um cofre que nunca o teve não espera: antes dele, o PIN já abria tudo.
  - Revisão do A1 (16/10/2026): antes, com a K_bio invalidada o app mostrava o Face ID desligado, e religar sobrescrevia o slot do dono sem espera; e o Face ID indisponível derrubava o slot, que vencida a espera voltava a pedir só o PIN.
- **Face ID indisponível** (tirado do app em Ajustes do iPhone, Espelhamento do iPhone, falha passageira): nada é apagado e nada espera; o que pede PIN e rosto recusa e diz por quê.
- **`LAContext` de cada operação**:
  - `localizedReason` descreve a ação ("Assinar envio de 0,25 ETH na Base").
  - `touchIDAuthenticationAllowableReuseDuration = 0`.
  - O `Bool` do `evaluatePolicy` **nunca** autoriza nada. Quem autoriza é o SE liberar o material de chave. O AppLock do Escalibur já acertou isso.
- Recomende ao dono ligar a Proteção de Aparelho Roubado (iOS 17.3+). Ela atrasa o cadastro de rosto novo longe de locais conhecidos.

### 2.6 Para quem guarda valor alto (SHOULD)

- **Senha alfanumérica no lugar do PIN** (ainda não feita). Oito caracteres sorteados de [a-z0-9] são 36^8 chutes: a 0,82 s por chute só no iPhone, dezenas de milhares de anos; com o Argon2id pré-calculado em GPU, o limite passa a ser o SE (22 ms por chamada), cerca de 2 mil anos no pior caso.
- **Modo reforçado** (feito em 16/10/2026, `RootKeyVault.enableHardened`, `unlockHardened`; as três políticas de "Quando o Face ID mudar", por decisão do dono, também em 16/10/2026), em Ajustes, Segurança:
  - Tudo passa a exigir PIN **e** rosto: abrir o app, toda assinatura, ver as palavras. O "e" é da criptografia, não da tela.
  - O slot é um só: `rk.and = cabeçalho ‖ camadas de fora`, e cada camada de fora embrulha o mesmo miolo: `ECIES_{chave de fora}(ECIES_{kand.pin}(0x01 ‖ ChaChaPoly(K_int, RK)))`.
    - `kand.bio`: chave do SE com `.biometryCurrentSet`. Segue o cadastro de rostos: um rosto novo a destrói.
    - `kand.qualquer`: chave do SE com `.biometryAny`. Sobrevive a um rosto novo. É a única chave do projeto com essa flag, e só embrulha o miolo, nunca a RK (§2.3).
    - `kand.pin.a` ou `kand.pin.b`: chave do SE com `.applicationPassword` = HKDF(AP, sal, "escalibur-wallet/v3/kand.senha"); as duas gerações se alternam a cada troca de PIN ou de política, e o cabeçalho diz qual vale.
    - K_int = HKDF(AP, sal, "escalibur-wallet/v3/rk.and.interna"); o AAD do ChaChaPoly é `"escalibur-wallet/v4/rk.and" ‖ cabeçalho`.
    - Cabeçalho v4, 29 bytes, em claro: versão (4), dígitos, geração da chave do PIN, camadas (1 = só `kand.bio`, 2 = só `kand.qualquer`, 3 = as duas), sal (16), memória e passadas do Argon2id, faixas. Como está no AAD, trocar a política pede um registro novo (custa um Argon2id), e mexer no byte das camadas não abre nada.
    - Corpo v4: para cada camada, na ordem `kand.bio`, `kand.qualquer`, o tamanho (2 bytes) e o ECIES. Camadas que não batem com o corpo, ou valor fora de 1, 2 e 3: `.storage`, sem contar tentativa e sem a varredura tocar nas chaves de fora.
    - O v3 (28 bytes de cabeçalho, sem o byte das camadas, só a `kand.bio`) é o de antes das políticas: lido como "Bloquear as carteiras", com o AAD v3, e nunca mais gravado. Nada migra sozinho: a tela mostra "Bloquear as carteiras", e a primeira troca de PIN ou de política grava o v4.
    - São chaves em camadas, nunca uma só com as duas flags: o DTS da Apple diz que senha de aplicativo e biometria na mesma chave do SE não é suportado.
  - **"Quando o Face ID mudar"**, escolhido pelo dono:

    | Política | Camadas de fora | Rosto novo |
    |---|---|---|
    | Continuar normal (padrão) | `kand.qualquer` | um rosto novo ou a aparência alternativa abre tudo com o PIN, na hora |
    | Esperar 24 horas | `kand.qualquer` e a vigia `kand.bio` | abre o app e mostra o saldo; enviar, trocar, ver e lacrar as palavras, remover carteira, salvar endereço, criar ou importar carteira, abrir carteira com passphrase, trocar o PIN, desligar o modo, mexer na política e nos ajustes de segurança esperam 24 horas |
    | Bloquear as carteiras | `kand.bio` | as carteiras daqui não abrem mais; só as palavras de cada carteira trazem de volta |

  - **Redefinir o Face ID não tem promessa** fora da trava: não há prova no aparelho de que a `kand.qualquer` sobrevive a uma redefinição (há relato no fórum da Apple, thread 774790, de itens `biometryAny` perdidos depois de uma redefinição interrompida). A tela promete só o rosto novo e a aparência alternativa, e diz que redefinir pode fechar as carteiras daqui, e que as palavras trazem de volta. A faixa da espera não manda mais redefinir o Face ID: manda trocar o código do iPhone.
  - **Contra quem cada uma vale**, dito com honestidade na tela:
    - Contra quem não sabe o código do iPhone: as três iguais. Cadastrar um rosto pede o código.
    - Contra quem sabe o PIN do app e o código do iPhone (sem a Proteção de Aparelho Roubado, ou num lugar conhecido): "Continuar normal" leva tudo em minutos (cadastra a aparência alternativa e abre); "Esperar 24 horas" leva depois de 24 horas com o iPhone na mão; "Bloquear as carteiras" não leva nada (o cofre fecha, e o dono restaura pelas palavras).
    - Com a Proteção de Aparelho Roubado ligada e o atraso de segurança em "Sempre", cadastrar um rosto pede o rosto do dono e uma hora: as três ficam iguais. A tela recomenda deixar ligados "Exigir atenção para o Face ID" e a Proteção de Aparelho Roubado, com o atraso em "Sempre".
  - **O item `rk.and` não tem senha de aplicativo**, ao contrário do que este texto previa: ela seria um segundo jeito de testar o PIN pelo chaveiro, sem acrescentar nada. O limite honesto (revisão do modo reforçado, M1): quem executa código no aparelho testa o PIN mesmo sem o rosto, pela própria `kand.pin` (cifra qualquer coisa com a chave pública dela e tenta abrir com a senha de cada PIN candidato, 22 ms por chute no SE, depois do Argon2id pré-calculado numa GPU): 10^6 chutes em 3 a 6 horas, ou minutos com 4 dígitos. O PIN que sai assim sozinho não abre nada: sem o rosto, a camada de fora fica fechada.
  - Abrir é uma chamada só, sob a trava do cofre, e um Face ID só, sempre: o PIN fora de forma, o Face ID bloqueado ou indisponível e a chave ausente recusam sem contar; o contador sobe **antes** do rosto; o rosto que não confirma conta como tentativa (inclusive o Cancelar), para a escada e para o apagar-após-N; o PIN é avaliado depois do rosto; o contador só zera com a RK aberta. O miolo entre as camadas só existe dentro dessa chamada (em `SecureBytes` zerado; a cópia que a ponte do `CFData` do SE pode deixar ao gravar não é zerável daqui). Sem rosto cadastrado: na trava, o cofre está perdido (a `kand.bio` morreu); nas outras, `.biometryNotEnrolled`, sem contar nem apagar, e volta com um rosto cadastrado. A chave de fora da política que sumiu: `.hardenedSlotLost`, sem apagar nada. A camada de fora que o SE recusa por um erro que não vem do LocalAuthentication (`EnclaveError.failed`, a chave que existe e não serve, como depois de uma redefinição interrompida): `.hardenedFaceKeyFailed`, e o contador volta ao de antes, porque nenhum rosto foi recusado e o PIN nem foi avaliado. A mensagem do rosto que não confirmou diz, em qualquer política, que só as palavras trazem de volta se o cadastro mudou (na trava) ou se o Face ID foi redefinido (nas outras).
  - **"Esperar 24 horas", passo a passo** (`unlockHardened(pin:reason:use:)`; só a abertura do app passa `.openApp`, o resto é `.operation`):
    - O Face ID abre a `kand.qualquer`, e na mesma sessão (o `LAContext` já avaliado, agora com `interactionNotAllowed`, sem segundo Face ID) a vigia `kand.bio` abre a camada dela. Abriu o mesmo miolo (comparado em tempo constante): o mesmo cadastro. A chave da vigia não existe mais: troca. A vigia não respondeu (precisaria de interface, ou um erro que não se classifica): decide o hash `and.estado`, e diferente ou ausente conta como troca. Miolo diferente: registro adulterado, `.storage`.
    - Troca vista sem espera: grava `and.espera` (o prazo de 24 horas no relógio monotônico, que depois de reiniciar recomeça cheio, e o hash do cadastro que a começou) e confere a gravação; não gravou, zera a RK e `.storage`. Com `.operation`, zera a RK e devolve `.biometryHold`; abrindo o app, devolve a RK e o contador zera.
    - Na espera: o que não é abrir o app recusa com `.biometryHold` antes do rosto e sem contar. A tela pergunta antes do teclado (`checkHardenedAllowed`, e `checkPINAndBiometryAllowed` diz a mesma espera), e a faixa na Carteira e em Segurança diz quanto falta: 24 horas com o iPhone ligado; reiniciar ou um rosto novo recomeça a contagem.
    - Outro cadastro no meio da espera (o dono redefiniu, ou alguém cadastrou mais um rosto): a espera recomeça na hora, cheia, presa ao cadastro de agora, e a faixa passa a dizer o prazo certo. Antes, a faixa seguia com o prazo velho e, no vencimento, começava outra espera inteira.
    - Sem o hash do cadastro de agora: com a espera correndo, ela fica como está; no vencimento, nada abre (`.biometryUnavailable`, a RK zerada) e a espera não é regravada, até o hash voltar. Antes, ela recomeçava presa a cadastro nenhum, e recomeçaria de novo no vencimento seguinte.
    - Só a prova do SEP encerra uma espera vencida: a vigia que abriu o mesmo miolo. A vigia que não responde, com o hash igual ao gravado, deixa a espera vencida onde está (não bloqueia nada) e não regrava o hash.
    - Espera vencida para o mesmo cadastro que a começou: a vigia realinha. Uma `kand.bio` nova para o cadastro de agora, o mesmo miolo embrulhado por ela, o `update` do `rk.and` conferido lendo de volta, `and.estado` regravado e `and.espera` apagada, nessa ordem. A `kand.qualquer` não é tocada, então uma queda em qualquer passo termina na próxima abertura (a vigia velha, ou a nova antes do registro, continua vendo a troca, e a espera vencida realinha de novo).
    - Espera vencida e outro cadastro (um rosto cadastrado depois do prazo, sem o app aberto no meio): outra espera começa, em vez de passar pela que já venceu. O desenho original não prendia a espera a um cadastro; sem isso, quem pegasse o iPhone uma semana depois de uma troca do próprio dono, sem o app aberto desde então, passava na hora.
  - Ligar: Face ID ligado, o slot do PIN no formato 2, nenhuma troca de PIN pendente e nenhuma espera do A1 (o cofre confere), e cópia conferida de todas as carteiras (a tela confere). Na hora, a frase inteira de cada carteira (e a passphrase das que têm), digitada pela tela da importação, sem colar (a tela não tem como exigir que venha do papel e não da tela "Ver as palavras"); a entropia digitada é comparada com a guardada dentro do cofre, com a RK aberta, em tempo constante, e a passphrase em NFKD dos dois lados. A passphrase com acento gravada fora de NFKD por uma versão anterior não vale como cópia: a seed BIP-39 normaliza sozinha, mas a chave da Cardano (Icarus) usa os bytes como estão, e restaurada pelas palavras a conta da Cardano mudaria. Três palavras provavam posse, não uma cópia certa, e no modo reforçado o papel é o único caminho de volta. A política é escolhida no fluxo de ligar (padrão "Continuar normal"), e o aceite do preço só existe com "Bloquear as carteiras". O PIN e o rosto pelo slot de hoje, as chaves de fora da política criadas, o `rk.and` gravado, lido de volta e aberto de novo com PIN e rosto (na espera, a vigia junto), e só então o commit: apagar o `rk.pin`. Depois, a limpeza apaga `rk.bio`, os registros do PIN e as chaves `kpin`, `kpin.novo`, `kdev` e `kbio`.
  - Trocar a política (`setHardenedFaceChange`; o `check` das palavras é obrigatório na API, aqui e em `enableHardened`, e o app passa `{ _ in }` explícito onde a política não pede palavras): PIN e rosto (uma tentativa contada; na espera, recusa antes), as palavras de cada carteira só na ida para "Bloquear as carteiras" (com a trava, o papel é o único caminho de volta), o registro novo com a outra geração da `kand.pin`, aberto com o segundo rosto (que não conta: recusado, nada muda), e o commit pelo `update` do `rk.and`, conferido lendo de volta. As chaves de fora que o registro em vigor usa são reaproveitadas, nunca recriadas; as que faltam nascem antes do commit. Sair da trava abre pela `kand.bio`: o rosto de agora prova o mesmo cadastro. Uma chave nova que some depois do commit põe o registro antigo de volta antes de recusar.
  - **A varredura e a atomicidade**: no reforçado, a varredura da volta ao app (e do começo de cada abertura) só apaga as sobras do modo normal. As chaves do reforçado dependem do cabeçalho, e o cabeçalho em claro só vale autenticado: a geração da `kand.pin` que ele não usa, as chaves de fora que a política dele não usa ("Bloquear": `kand.qualquer`; "Continuar": `kand.bio`; "Esperar": nenhuma, nem a `kand.bio` morta, que o realinhamento recria) e a `and.espera` fora do "Esperar" só saem depois de uma abertura (o AAD da camada interna provou o cabeçalho) ou de um commit que o cofre acabou de gravar e conferir. Cabeçalho ilegível: as chaves do reforçado ficam.
    - O risco que isso fecha (revisão das três políticas, B3): antes, a varredura lia o cabeçalho sem autenticar, e trocar o byte das camadas entre 1 e 2 (o mesmo número de camadas, então a leitura aceita) fazia a simples volta ao app apagar a chave de fora em vigor, e o cofre se perdia mesmo com o byte certo de volta. Agora, mexer no cabeçalho só faz o cofre não abrir até o cabeçalho certo voltar. Quem consegue escrever no chaveiro do app continua podendo apagar o `rk.and` inteiro: isso não muda. No modo normal sem `rk.and`: `kand.bio`, `kand.qualquer`, `kand.pin.a`, `kand.pin.b`, `and.estado` e `and.espera`. Antes do commit de uma troca, o cabeçalho antigo manda; depois, o novo: em nenhum instante o registro em vigor aponta para uma chave que a varredura apaga, e uma queda em qualquer passo deixa o cofre abrindo pelo caminho de antes ou pelo novo. `wipeAll`, `discardOrphans` e `hasResidue` cobrem a `kand.qualquer` por `WrapSlot.allCases`.
  - Regra do modo: reforçado se e só se o `rk.and` existe e nenhum slot do PIN existe. Com os dois (queda no meio de ligar ou de desligar), o modo normal manda, e o PIN certo apaga o `rk.and`.
  - Desligar pede PIN e rosto (na espera, recusa antes): o slot do PIN é gravado e conferido, o Face ID volta conferido pelo rosto, e o `rk.and` sai. O Face ID volta sem a espera do A1 só quando o reforçado reconhece o cadastro: a `kand.bio` abriu ("Bloquear"), a vigia disse o mesmo ou a espera foi cumprida ("Esperar"), ou o hash é o gravado quando a política passou a valer ("Continuar"). Senão, a marca de perdido do A1 é gravada antes do slot do PIN: religar começa a espera de 24 horas, e sem religar o que pede PIN e rosto recusa. Se o segundo rosto for recusado, o modo sai mesmo assim, com o Face ID desligado e só o PIN, e a tela diz isso: o dono pediu e se autenticou com os dois. Se o slot do PIN não puder ser conferido, ele sai antes da chave dele, e o modo continua reforçado.
  - Trocar o PIN: abre com o PIN atual e o rosto (na espera, recusa antes), monta o registro novo com a outra geração da chave do PIN e as mesmas camadas de fora, abre com o PIN novo e o rosto, e só então troca o item no lugar (atômico). O PIN antigo para exatamente ali, e repor um `rk.and` antigo não traz o PIN antigo de volta.
  - O preço do bloqueio, só na tela "Bloquear as carteiras", com a animação em quatro quadros (os discos do PIN e do rosto; outro rosto entra no lugar; o cadeado fecha sobre as carteiras apagadas; o papel das palavras traz de volta; com Reduzir Movimento ou o VoiceOver, os quadros parados, um embaixo do outro) e o aceite: qualquer mudança no Face ID, inclusive as do dono (um rosto novo, a aparência alternativa, o Face ID redefinido), fecha as carteiras daqui de vez, e só as palavras trazem de volta; os nomes, os endereços salvos e os ajustes se perdem. Nada é apagado sozinho: o dono apaga e restaura pelo mesmo caminho do "Esqueci o PIN". Face ID indisponível ou bloqueado só espera.
  - **O que só o aparelho confere** (o simulador não tem Secure Enclave nem cadastro de rostos de verdade; ele simula a troca com `-rosto-novo`, que apaga a `kand.bio`):
    1. A chave `.biometryAny` continua abrindo depois de uma aparência alternativa nova, de máscara, e de "Redefinir Face ID" seguido de cadastro novo (inteiro e interrompido no meio), e depois de tirar todos os rostos e cadastrar de novo. Hoje a tela não promete a redefinição; se ela sobreviver, o texto pode prometer. E o erro que a chave devolve quando não serve: se não for `EnclaveError.failed`, a falha conta como rosto que não confirmou.
    2. A chave `.biometryCurrentSet` invalidada: o que `SecItemCopyMatching` e `SecKeyCreateDecryptedData` devolvem, e se o Face ID chega a aparecer. Hoje, só "a chave não existe" (`errSecItemNotFound`) é troca certa; qualquer outra recusa da vigia vira "não se sabe", e o hash decide. Se a chave invalidada continuar aparecendo na abertura de "Bloquear", a trava de hoje conta cada tentativa como rosto que não confirmou: corrigir pela classificação do erro.
    3. O reuso do `LAContext` da vigia sem segundo Face ID. Se o contexto não servir para a `kand.bio`, toda abertura de "Esperar" decide pelo hash (continua seguro, e mais frágil a deriva do hash).
    4. O `stateHash` (iOS 18) e o `evaluatedPolicyDomainState` (17) em cada caso: depois de reiniciar, na atualização do iOS, com a aparência alternativa e com a máscara. Um hash que muda sozinho custa uma espera de 24 horas a mais em "Esperar" e a espera do A1 ao desligar "Continuar".
    5. A ordem de um Face ID só por chamada nas três políticas, e o tempo da abertura de "Esperar" (a vigia não pode atrasar o rosto).
    6. A animação no iPhone pequeno e com o texto grande do sistema, e o VoiceOver lendo as quatro legendas em ordem.
- **Carteira-cofre**: a DEK daquela carteira é embrulhada por `HKDF(RK ‖ Argon2id(senha da carteira, 512 MiB, t=4, p=4))`. Quebrar o PIN no aparelho não a abre.

### 2.7 Atraso progressivo e "apagar após N erros"

- **Escada de atraso**:
  - Erros 1 e 2: 0 s. Erro 3: 5 s. Erro 4: 15 s. Erro 5: 60 s. Erro 6: 5 min. Erro 7: 15 min. Erro 8: 1 h. Do 9 em diante dobra: 3 h, 6 h, 12 h, 24 h, 48 h, 96 h, e 7 dias por tentativa do 15º em diante (auditoria 4, C7-04).
  - Na conta: 9 chutes na primeira hora e meia, 18 em 30 dias, 66 em um ano. Com o teto antigo de 3 horas eram cerca de 2.900 por ano.
  - O incremento é gravado com `SecItemUpdate` antes da avaliação. Se a gravação falhar, a tentativa não é avaliada.
  - Relógio de parede e relógio monotônico, com o conserto de boot da A3.
- **Apagar após 10**:
  - Opcional. Só pode ser ligado depois que o backup de todas as carteiras foi conferido.
  - Antes da 10ª tentativa, o app avisa na tela.
  - Apagar é destruição criptográfica: `SecItemDelete` de K_dev, K_bio e dos itens `rk.*` primeiro, que em milissegundos tornam inúteis todos os blobs, e depois o resto.
  - Contra quem tenta pela interface, a chance de acerto é de 1 em 100 mil para um PIN sorteado de 6 dígitos, e de 1 em mil para um de 4. Contra quem tem execução de código, é inútil, e isso vai escrito.
- **Sem lista de PINs fáceis** (decisão do dono, 2026-09-26): qualquer combinação de 4 ou 6 dígitos vale, inclusive 1111 e 123456. O app só confere a forma. O risco fica com o dono: um PIN óbvio é o primeiro palpite de quem pega o iPhone, e contra isso sobram a escada de atraso e o apagar após erros, se ligado.

### 2.8 Força bruta no PIN: o Secure Enclave resolve?

| Atacante | Custo para varrer todos os PINs |
|---|---|
| Extraiu os dados e não tem o aparelho | impossível: K_dev nunca sai do SE, e nenhum blob abre em outro lugar |
| Tem o aparelho desbloqueado, tenta pela interface | 66 chutes por ano pela escada: contra PIN sorteado de 6 dígitos, 1 chance em 15 mil por ano; com apagar-após-10, 1 em 10^5. Contra PIN escolhido por gente, ver abaixo |
| O mesmo, com PIN de 4 dígitos | 66 chutes por ano: contra PIN sorteado, 1 chance em 150 por ano; com apagar-após-10, 1 em 10^3 |
| Tem execução de código no aparelho desbloqueado | Argon2id pré-calculado em GPU + 10^6 × 22 ms no SE ≈ **6 a 11 horas no pior caso, 3 a 6 em média** |
| O mesmo, com PIN de 4 dígitos | Argon2id pré-calculado em GPU (1 a 2 min) + 10^4 × 22 ms no SE ≈ **4 a 6 minutos no pior caso, 2 a 3 em média**; sem GPU, só no iPhone, 10^4 × 0,82 s ≈ 2,3 horas |
| O mesmo, com modo reforçado, sem o rosto do dono | não abre: a camada de fora é decidida no SEP. O PIN é testável pela `kand.pin` em 10^6 × 22 ms (3 a 6 horas; 4 dígitos, minutos), mas sozinho não abre nada |
| O mesmo, com modo reforçado e o rosto do dono uma vez | o PIN cai no tempo de sempre: 10^6 × 22 ms, 3 a 6 horas em média com o Argon2id em GPU (4 dígitos: minutos). Quem consegue o rosto uma vez guarda o miolo e testa PINs contra o SE fora do contador; o iOS não tem como impedir |
| Modo reforçado, pela interface | com o PIN visto, sem o rosto e sem o código do iPhone: enganar o Face ID fica em 66 tentativas por ano, ou N com o apagar-após-N ligado. Com o PIN e o código do iPhone, cadastrar o próprio rosto: em "Continuar normal" leva tudo na hora; em "Esperar 24 horas", depois de 24 horas com o iPhone na mão; em "Bloquear as carteiras" mata o cofre (o ladrão não leva nada) |

A resposta honesta: **o SE converte ataque offline em ataque preso ao aparelho, mas não limita as tentativas de segredos do app.**
- O único limite por hardware que existe é o do código do iPhone (80 ms mais atrasos crescentes no SEP).
- Para usar esse limite, o item teria de ser `.devicePasscode`, e quem viu o código do iPhone passa por ele.
- Por isso o PIN de 6 dígitos é defesa contra T2, não contra T3. O de 4 também é só contra T2.
  - Pela interface, contra PIN escolhido por gente e sem lista de bloqueio, o tamanho quase não muda a chance (Markert et al., S&P 2020, tabela VI, grupos de controle: 231 PINs de 4 dígitos e 127 de 6): em 10 chutes, 5% dos de 4 e 6% dos de 6; em 30, 8% e 9%; em 100, 17% e 14%.
  - O preço real dos 4 dígitos está contra o PIN sorteado (10^4 em vez de 10^6) e contra quem tem execução de código: minutos em vez de horas.

### 2.9 Ciclo de vida da seed na assinatura

```
// Síncrono, numa fila própria fora do MainActor. Nenhum await entre decifrar e zerar.
assinar(lote: LoteValidado, credencial) -> [Assinatura]:
  rk  = destrancarRaiz(credencial)         ; defer rk.wipe
  dek = desembrulharDEK(rk, lote.carteira) ; rk.wipe()   ; defer dek.wipe
  reg = abrirRegistro(dek)                 ; dek.wipe()  ; defer reg.wipe   // entropia + passphrase
  s64 = PBKDF2-HMAC-SHA512(frase(reg), "mnemonic"+pass, 2048) → SecureBytes ; reg.wipe() ; defer s64.wipe
  para cada item:
     k   = derivar(s64, item.caminho)       ; defer k.wipe        // BIP-32 / SLIP-10
     sig = assinar(k, item.digestoLocal)                           // RFC 6979 + ndata do CSPRNG
     exigir verificar(sig, item.chavePublicaEsperada)              // defesa contra falha e glitch
  retorna assinaturas                                              // dado público
```

Regras:
- **Nenhum `await` enquanto um segredo está vivo.** Função assíncrona em Swift guarda as variáveis locais num contexto alocado no heap, que é liberado sem zerar.
- **HMAC e PBKDF2 pelo CommonCrypto** (`CCHmac` com `kCCHmacAlgSHA512`, `CCKeyDerivationPBKDF` com `kCCPRFHmacAlgSHA512`), escrevendo direto em `SecureBytes`. O `HashedAuthenticationCode` do CryptoKit não é zerável.
- **libsecp256k1**:
  - Contexto criado com `SECP256K1_CONTEXT_NONE` e `secp256k1_context_randomize` com 32 bytes do CSPRNG, re-randomizado depois de cada lote.
  - EVM e Tron assinam com `secp256k1_ecdsa_sign_recoverable`; BTC e XRPL com `secp256k1_ecdsa_sign` mais DER. O S baixo é garantido pela biblioteca.
  - Toda assinatura passa por `secp256k1_ecdsa_verify` antes de sair. Uma assinatura defeituosa com nonce determinístico entrega a chave.
- Ed25519 (Solana, Stellar) pelo `Curve25519.Signing` do CryptoKit, também verificado.
- Ed25519 com chave estendida (Cardano) em Swift, sobre o TweetNaCl: os temporários da curva ficam numa área de tamanho fixo, zerada com `memset_s` no fim; o estado do SHA-512 que passa por kR é do CryptoKit e não é zerável daqui (auditoria 4, B3).
- Nada de hex, `description` ou `Data` de segredo em código de produção.
- Nada de xprv em cache: só xpub e chaves públicas.

### 2.10 Quem exige o quê

| Ação | Exige |
|---|---|
| Abrir o app | PIN ou biometria. Modo reforçado (§2.6): PIN e rosto, e assim em todas as linhas abaixo que pedem PIN |
| Ligar o modo reforçado | PIN e rosto, a frase inteira de cada carteira, e o rosto de novo para conferir o modo novo |
| Desligar o modo reforçado, trocar o PIN nele, mudar "Quando o Face ID mudar" | PIN e rosto, e o rosto de novo para conferir o que entra no lugar; ir para "Bloquear as carteiras" pede também a frase inteira de cada carteira. Em "Esperar 24 horas", na espera, tudo isso e o resto, fora abrir o app, recusa antes do teclado |
| Qualquer assinatura (envio, swap, approve, ordem, cancelamento) | Autenticação nova, uma por lote revisado numa única tela: Face ID ou PIN. Modo reforçado: PIN e rosto |
| Revelar palavras, exportar envelope, remover carteira | PIN e, com a biometria ligada, o rosto também (A1, `unlockWithPINAndBiometry`). Logo depois de o Face ID cair sozinho, espera de 24 horas |
| Ligar biometria, trocar PIN, alongar o tempo de bloqueio, apagar-após-N, mudar a voz | PIN |
| Desligar biometria | PIN e rosto (A1): desligar tira o rosto do que pede os dois |

---

### 2.11 Carteira com passphrase: pedir a passphrase (16/10/2026)

"Pedir a passphrase para enviar" vem ligado em toda carteira com passphrase (`WalletMeta.passphraseToSend`, nil vale ligado). Contra quem tem o PIN, ou o PIN e o rosto do dono, a passphrase é o fator que falta.

- **Mover saldo.** Envio, troca e ponte pedem a passphrase antes do Face ID ou do PIN (`PassphraseGate`). Cancelar uma ordem não move saldo e não pede. A digitada vai para `Signer.sign(passphrase:)`, que a compara com a do cofre, as duas em NFKD e em tempo constante, antes de nascer qualquer chave: errada, nada é assinado. O parâmetro não tem valor padrão: cada chamador diz se pede.
- **Folga depois de acertar** (pedido do dono, 17/10/2026). Na folha de mover saldo, "Não pedir de novo por um tempo": 5, 10, 15 ou 20 minutos, 5 ao ligar, desligado a cada folha. Começa só depois de o assinador conferir a passphrase daquela carteira (`PassphraseGate.confirmGrace`), vale só para mover saldo naquela carteira, fica só na memória, no relógio monótono, e acaba ao travar o app (`AppSession.lock`). O Face ID ou o PIN continuam a cada assinatura. Ver a senha, criptografar e desligar o pedido sempre pedem a passphrase.
- **Ver a senha e criptografar.** Mostram a passphrase só depois de ela ser digitada e conferida dentro do mesmo fechamento do cofre. Sem isso, quem tem o PIN e o rosto lia ou exportava a passphrase.
- **Desligar.** Pede a passphrase e o PIN (nunca só o rosto), conferidos no cofre. Ligar é livre.
- **Chute.** Uma conta única de passphrases erradas para todas as portas que conferem uma (mover saldo, ver, criptografar, desligar, conferir a cópia, criar a carteira com passphrase, que reconhece a carteira que já existe). A tentativa é gravada antes da conferência; acertar zera; cancelar o PIN antes de o cofre abrir devolve a tentativa. Depois de 5 erros, espera de 1 minuto que dobra a cada erro, até 24 horas, no relógio monótono, como a da voz. Criar nunca zera a conta.
- **Limite.** Quem tem o PIN e o rosto ainda vê as palavras da carteira de sempre, e com elas pode tentar a passphrase fora do aparelho, em PBKDF2-SHA512 de 2048 rodadas: uma passphrase curta cai, uma de 5 palavras sorteadas não. A tela de criar diz para anotar longe das palavras; um medidor de força da passphrase é o próximo passo.

### 2.12 Carteira com as palavras escolhidas pelo dono (17/10/2026)

Pedido do dono. Na criação, "Prefiro escolher as minhas palavras": o dono digita as 11 primeiras (ou 23) em inglês, pelo teclado ou tocando na lista das 2048, e o app sorteia a última (`BIP39.completing`). A última palavra carrega bits livres da entropia (7 na frase de 12, 3 na de 24) e o checksum (4 ou 8): os livres saem do `SecRandomCopyBytes`, o mesmo gerador da criação comum, e o checksum sai da conta. Testado contra os vetores oficiais do BIP-39.

- **A força é a das palavras escolhidas mais os bits sorteados.** Escolha humana rende bem menos que sorteio, e a tela diz isso num aviso, com a sugestão de sortear com moeda ou dado e de pôr uma passphrase forte por cima.
- **Só na criação, nunca na importação.** Quem restaura e erra uma palavra não pode receber um "conserto" da última, que abriria outra carteira, vazia, sem aviso.
- A tela é a mesma da importação, no modo escolher: sem colar, sem rede (`HTTPClient.beginQuiet`), cifra viva nos campos, guarda contra captura, a última posição visível e travada. A lista de palavras fica atrás da mesma guarda: ela é pública, a sequência tocada não.
- Depois, o fluxo de sempre: a carteira é guardada antes de mostrar a palavra sorteada, a placa mostra as 12 e a conferência é a mesma.

## 3. Voz

**Avaliação**
- O iOS não tem verificação de locutor.
  - `SFSpeechRecognizer` e, no iOS 26, `SpeechAnalyzer`, `SpeechTranscriber` e `SpeechDetector` transcrevem e detectam fala. Não dizem **quem** fala.
  - Não existe ACL de chaveiro ou do SE por voz. Qualquer "voz confere" seria um booleano dentro do processo, que um gancho troca por verdadeiro.
  - O Face ID é diferente: a decisão acontece no SEP e o que ele libera é material de chave.
- Uma frase falada como senha é uma senha dita em voz alta, ouvida e gravável. O reconhecimento erra, o que obriga a aceitar aproximações, e a entropia cai mais ainda.
- Clonagem de voz em 2026: poucos segundos de áudio bastam (VALL-E anuncia 3 s; serviços comerciais anunciam "poucos segundos"). No Brasil, qualquer pessoa tem minutos de áudio de WhatsApp de qualquer outra.
  - Em julho de 2025, Sam Altman disse ao Federal Reserve que a IA "derrotou completamente" a autenticação por voz dos bancos.
  - A literatura ASVspoof mostra que verificação sem contramedida aceita voz sintética, e que contramedidas generalizam mal para sintetizadores novos.
- A impressão de voz é dado biométrico sensível pela LGPD (art. 5º, II, e art. 11), e o modelo seria dependência de terceiro.

**Recomendação: voz não entra como autenticação em papel nenhum.**
- Nem sozinha.
- Nem como fator adicional: um fator que um áudio de WhatsApp derrota e que é um booleano no processo não soma nada, e ainda custa disponibilidade. No dia do resfriado, o dono não move o próprio dinheiro.
- Nem para ações de baixo risco: essas já não pedem nada além do app aberto.

**Versão honesta que dá para oferecer: "Comandos de voz (não é autenticação)", escrito assim na tela.**
- Desligado por padrão. `NSMicrophoneUsageDescription` e `NSSpeechRecognitionUsageDescription` só são pedidos quando o dono liga.
- Aperta e fala: sem escuta contínua, sem palavra de ativação, microfone aberto por no máximo 5 s.
- Reconhecimento só no aparelho:
  - iOS 26+: `SpeechTranscriber`.
  - iOS 17–25: `SFSpeechRecognizer` com `supportsOnDeviceRecognition == true` e `requiresOnDeviceRecognition = true`.
  - Se o reconhecimento local não estiver disponível, o recurso fica indisponível. **Nunca** cai para o servidor da Apple.
  - O áudio não é gravado. A transcrição não é registrada em log.
- Gramática fechada: "mostrar saldo", "receber bitcoin", "enviar 0,1 ether para <contato do catálogo>".
  - Só pré-preenche a tela, e o destino vem do catálogo, nunca de um endereço ditado.
  - Revisar e assinar seguem o caminho normal, com biometria ou PIN.
- O microfone fica fisicamente desligado em toda tela que mostra ou recebe frase, PIN ou senha. Um dono que lê as palavras em voz alta enquanto anota não pode estar sendo transcrito.
- Nenhuma App Intent ou atalho da Siri que assine ou que rode a partir da tela bloqueada.

**O que o app tem hoje (14/10/2026): a frase de voz, a pedido do dono, como camada a mais.** Ela vem depois do Face ID ou do PIN, nunca no lugar deles, e a tela diz que o iPhone reconhece a frase, não a voz.
- Cada frase dita conta, e a conta é gravada nos metadados antes de conferir. Sem conseguir gravar, não confere. Nove erradas em seguida, somadas entre folhas, pausam as ações com voz por 15 minutos no relógio monótono. Antes, fechar a folha apagava as erradas e o chute ficava sem limite (desenho de voz do agente de segurança, Q1 e Q2).
- Só o microfone do próprio iPhone. Uma interface de áudio pela USB-C injetaria fala gerada, limpa. A escuta para se a entrada deixar de ser o microfone embutido (Q6).
- Reconhecer a voz da pessoa, e não só a frase, foi desenhado pelo agente de segurança em 14/10/2026 e espera decisão do dono. Um modelo de locutor roda no aparelho, mas voz clonada e gravação passam em dezenas de por cento, e o modo reforçado (PIN e Face ID juntos, §2.6) protege mais. Se entrar, entra depois de um teste com voluntários e critério de parada, e a tela diz o que ele não barra.

---

## 4. Salvaguardas na assinatura

### 4.1 Princípio: o provedor propõe, o app decide

- O módulo de chaves só aceita um `LoteValidado`, tipo com inicializador `package`/`fileprivate` que só o validador constrói.
- A tela mostra os campos **decodificados**, nunca o JSON da cotação.
- O digesto é sempre calculado localmente.
- **Recusas na v1:**
  - EVM: `eth_sign`, `personal_sign` de dados arbitrários, EIP-712 de domínio ou `primaryType` fora da lista, **autorização EIP-7702** (vetor de dreno total desde o Pectra; com `chainId 0` vale em todas as redes), `setApprovalForAll`, approve para spender fora da lista, `increaseAllowance`.
  - Solana: programa fora da lista, `SetAuthority`, `Approve` de delegado, `System Assign` na conta do usuário.
  - XRPL: `SetRegularKey`, `SignerListSet`, `AccountSet`, `AccountDelete`.
  - Stellar: `SetOptions` (signatários e pesos), `AccountMerge`.
  - Tron: `AccountPermissionUpdateContract`, o golpe do multi-sig.

### 4.2 Reautenticação: sempre, por lote

- Por que não "só acima de um valor":
  - O valor vem de um preço que o relay controla.
  - Approve, permit e troca de dono de conta não têm "valor".
  - Face ID custa cerca de 1 s.
- Approve e swap na mesma tela contam como uma autenticação.
- Um lote vale 60 s. Passou disso, recota e reconstrói.

### 4.3 Swap EVM: validação da calldata

Intenção do usuário: I = {chain, sellToken, buyToken, amountIn, slippage, destinatário = própria conta}.

1. O `chainId` da transação é constante compilada, nunca vem da API. O `eth_chainId` de cada provedor é conferido contra ela na sessão.
2. `to` precisa estar na allowlist compilada da chain. Confira cada endereço, chain por chain, no explorador e na documentação oficial ao gravar o lock:
   - 1inch AggregationRouterV6: `0x111111125421cA6dc452d289314280a0f8842A65`.
   - 0x AllowanceHolder: `0x0000000000001fF3684f28c67538d4D072C22734` nas chains Cancun (inclui as 7 alvo); `0x0000000000005E88410CcDFaDe4a5EfaE4b49562` nas Shanghai.
   - LI.FI Diamond: `0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE`.
3. `value` é igual a amountIn se o token vendido for nativo, e zero nos outros casos.
4. O seletor precisa estar na allowlist daquele router e é decodificado por ABI. **Sem decodificador, sem assinatura.**
5. Campos que precisam bater com a intenção:
   - 1inch `swap(executor, desc, data)`: `desc.srcToken`, `dstToken`, `dstReceiver == self`, `amount == amountIn`, `minReturnAmount`. O `data` do executor é opaco, e isso só é aceitável porque o router garante `minReturn` para o `dstReceiver`. Nas funções `unoswap*` o destinatário é `msg.sender`; nas `unoswapTo*`, confira `to`.
   - 0x `exec(operator, token, amount, target, data)`: `operator == target ==` o Settler atual, obtido por `ownerOf(2)` no registro `0x00000000000004533Fe15556B1E086BB1A72cEae`, com 2 ou mais RPCs concordando (a própria 0x manda nunca fixar o endereço do Settler). `token == sellToken`, `amount == amountIn`. Dentro de `execute(...)`: `slippage.recipient == self`, `buyToken`, `minAmountOut`. O approve vai para o AllowanceHolder, nunca para o Settler.
   - LI.FI `swapTokensGeneric(..., receiver, minAmount, swapData[])`: `receiver == self`, primeiro `sendingAssetId` e `fromAmount` e último `receivingAssetId` batendo. Pontes nunca passam pela LI.FI: têm caminho próprio, na seção 4.12.
   - `minOut ≥ cotação × (1 − slippage)` e maior que zero. `deadline ≤ agora + 20 min`. Taxa de integrador e destinatário da taxa iguais aos compilados (zero, ou a nossa).
6. **O ranking entre agregadores usa o `minOut` decodificado**, que é garantido na cadeia, e não o `expectedOut` cotado. Inflar o `expectedOut` é justamente como um provedor malicioso venceria a disputa.
7. Checagem de sanidade contra oráculo: pior que o preço médio da CoinGecko em mais de 2%, avisa; em mais de 5%, bloqueia (desbloquear exige PIN). Oráculo e cotação chegam pelo mesmo relay, então isso é sanidade, não garantia.
8. Gás:
   - `maxFeePerGas ≤ 2 × baseFee + prioridade`, com baseFee e prioridade pela mediana de 2 provedores e teto por chain.
   - `gasLimit ≤ estimativa × 1,3` (na v1, a menor de 2 estimativas × 1,2), também com teto.
   - Taxa acima de US$ 20 ou de 3% do valor pede confirmação extra.
   - Na mainnet Ethereum, envio por RPC privado (Flashbots Protect ou MEV Blocker) para não ser sanduichado dentro do slippage.
   - Nas L2 de sequenciador único (Arbitrum, Base, Optimism, Unichain, Linea, e Celo e X Layer desde que passaram ao OP Stack) não há fila pública para um robô ler. Nas demais (BNB, Polygon, Avalanche, Sonic, Plasma) e na Solana, a troca vai pela fila pública, e a revisão diz: "sem proteção contra robôs: o que ficar entre a estimativa e o mínimo garantido pode não chegar" (auditoria 4, M2). A CoW, já integrada em várias dessas redes, é leilão e não passa pela fila. Relay privado nessas redes fica para depois.

### 4.4 Aprovações, Permit2, EIP-2612

- Approve no **valor exato**, e só para spenders da lista.
- Tokens do tipo USDT exigem `approve(0)` antes de um novo valor. São duas transações, e as duas aparecem na tela.
- Aprovação infinita nunca é padrão. É uma opção por token, com PIN e aviso.
- Uma tela lista as aprovações vigentes (`allowance(owner, spender)` para cada spender da lista) e permite revogar.
- **A v1 não assina Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) nem EIP-2612.** Assinatura off-chain de permit é o principal vetor de dreno. Os fluxos AllowanceHolder e approve exato cobrem os agregadores.
- **Exceção estreita, na cadeia, para a Uniswap direta** (decisão do dono, 17/10/2026). O Universal Router só puxa o token pelo Permit2, então a troca pela Uniswap vendendo token tem três transações: `approve(Permit2, valor exato)` no token, `Permit2.approve(token, Universal Router, valor exato, agora + 30 min)` e a troca. Continua sem assinatura fora da cadeia:
  - a guarda (`EVMCallGuard`) só aceita o `approve(address,address,uint160,uint48)` ao Permit2 quando o plano declara exatamente aquele token, router, valor e prazo (`EVMCallPolicy.permit2Approval`); qualquer outro, e todo permit assinado, segue recusado;
  - o router é o Universal Router 2.0 da allowlist compilada, sem proxy, conferido rede a rede;
  - o prazo conta da cotação validada, para a simulação e o plano montarem a mesma chamada; a permissão que já existe é lida em duas fontes (o menor valor e o menor prazo) e só é reaproveitada se cobre o valor e vale mais 5 minutos;
  - a simulação roda as três chamadas em duas fontes, e a do Permit2 não pode tirar nada do dono nem aprovar token;
  - a calldata da troca é montada pelo app (`UniswapCalldata`) e volta pelo decodificador: só pools sem hook, ponte só pelo embrulhado, pela moeda nativa ou por stablecoin da lista, `TAKE_ALL` para quem assina, prazo de até 20 minutos conferido pelo router.
- Se um dia for habilitar:
  - Domínio montado localmente.
  - Spender da lista, token igual ao vendido, valor exato (nunca 2^160−1).
  - `expiration` e `sigDeadline` até agora + 30 min.
  - Nonce lido da cadeia com 2 ou mais provedores.
  - `PermitBatch` só com os tokens da própria operação; witness só de tipo conhecido.

### 4.5 Ordens limite

- **1inch LOP v4** (é o mesmo contrato do router v6):
  - O domínio EIP-712 é lido do contrato ao gravar o lock, via `eip712Domain()` (EIP-5267) ou pelo fonte verificado.
  - `maker == self`; `receiver` zero ou self; `makerAsset` e `takerAsset` iguais aos da intenção; `makingAmount` exato.
  - **`takingAmount` é calculado localmente a partir do preço limite digitado pelo dono**, nunca vindo da API.
  - Expiração em `makerTraits`: padrão 7 dias, máximo 30.
  - `extension` vazia. Com pre/postInteraction, predicate ou permit, recusa.
  - Hash e digesto calculados localmente. Approve exato de `makingAmount`.
- **Cancelar, dito com honestidade na tela**:
  - Tirar a ordem do livro da API não invalida a assinatura.
  - Cancelar de verdade é `cancelOrder(makerTraits, orderHash)` ou `increaseEpoch` na cadeia, ou revogar a aprovação.
  - Um registro local das ordens abertas fica nos metadados.
- **Combinação de provedores**: nunca assinar duas ordens off-chain que gastem o mesmo saldo. Uma ordem antiga e esquecida executa quando o saldo volta. No máximo uma ordem aberta por `makerAsset` por chain, a não ser que o dono confirme que a soma cabe no saldo e que a aprovação cobre só essa soma.
- **Troca imediata e em partes pela CoW** (v1, 10/10/2026). A mesma ordem EIP-712 da ordem limite, com as mesmas regras (destinatário = dono, taxa zero, venda, saldo ERC-20, appData compilado, autorização exata ao VaultRelayer, uma ordem aberta por token vendido):
  - O `buyAmount` assinado é exatamente o mínimo que a tela mostrou, tirado da cotação da CoW menos a tolerância do dono, e não é recotado no plano: o plano assina o número que o dono viu, ou recusa se a cotação venceu (60 s).
  - A cotação da CoW só vale ancorada: no máximo 5% do preço de referência, para pior ou para melhor; sem referência, junto de outra cotação e no máximo 5% acima da melhor estimativa dos agregadores. Cotação inflada não rouba nada (a ordem só não executa), mas tomaria o lugar de uma troca que executa.
  - Validade fixa e conferida na regra da mensagem tipada: 30 minutos (de uma vez) ou 1 hora (em partes). Execução parcial: cada parte sai pelo preço garantido ou melhor; o que não sair continua na carteira.
  - A conferência da tela (`PlanIntentCheck`) compara o mínimo do plano com o mínimo da execução escolhida.
- **XRPL `OfferCreate`**:
  - `Account == self`; `TakerGets` e `TakerPays` com moeda e emissor da lista compilada. Emissor falso de "USD" é golpe comum.
  - Flags só entre `tfSell`, `tfImmediateOrCancel`, `tfFillOrKill`, `tfPassive`. `Expiration` preenchido na troca; na ordem, opcional (sem ele, até o dono cancelar).
  - `LastLedgerSequence` = ledger validado em que 2 servidores leram a conta + 20. `Sequence` de 2 ou mais servidores. Taxa com teto.
  - A tela diz "você entrega X, recebe no mínimo Y".
  - A reserva de 0,2 XRP por oferta é decidida por votação dos validadores: leia de `server_info`.
- **Stellar `ManageSellOffer`**:
  - `source == self`; ativos com código e emissor da lista; preço n/d calculado localmente.
  - `timeBounds.maxTime ≤ agora + 5 min`.
  - A passphrase de rede é compilada: `"Public Global Stellar Network ; September 2015"`.

### 4.6 Solana e Jupiter

- Use `/swap-instructions` e monte a mensagem localmente. A transação pronta de `/swap` é assinatura às cegas.
- Programas permitidos:
  - `ComputeBudget111111111111111111111111111111`
  - `11111111111111111111111111111111`
  - `TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA`
  - `TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb`
  - `ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL`
  - Jupiter v6: `JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4`
- Conferências:
  - Quem paga a taxa é a própria conta; a autoridade de transferência da rota também; o destino é o ATA da própria conta.
  - `quoted_out_amount` e `slippage_bps` decodificados; `platform_fee_bps` igual a 0 (ou o nosso).
  - Tabelas de lookup de endereço resolvidas por 2 RPCs.
  - Preço de CU vezes limite de CU com teto.
  - Mint comprado em Token-2022 com PermanentDelegate ou TransferHook: bloqueia.

### 4.7 Bitcoin (BIP84)

- A PSBT é montada localmente.
- **Para cada UTXO, baixe a transação anterior inteira e confira que `txid == dSHA256(raw)`.** Valor e script saem dela, e o provedor não consegue mentir o valor para inflar a taxa.
- O troco vai para `m/84'/0'/0'/1/i`, derivado localmente e conferido como nosso antes de assinar.
- Taxa: teto compilado por rede; até 2 vezes a maior estimativa; 2 fontes no máximo 3x distantes; com 2, o menor de cada nível. Aviso acima de 1% do valor.
- Endereço de destino: bech32 ou bech32m com HRP `bc`, ou base58 com checksum.
- RBF ligado: `nSequence 0xFFFFFFFD`.
- Não misturar UTXOs de pó automaticamente.

### 4.8 Memo, tag e destinos perigosos

- **XRPL**: `account_info` validado do destino, em 2 ou mais servidores.
  - `lsfRequireDestTag` (0x00020000) faz a tag ser obrigatória. `lsfDisallowXRP` (0x00080000) gera aviso.
  - Destino inexistente só recebe a partir da reserva base, lida de `server_info` (1 XRP desde dezembro de 2024).
  - Aceite X-address, que já carrega a tag.
  - **Recebimento: mostre `meta.delivered_amount`, nunca `Amount`.** Pagamento parcial (`tfPartialPayment`) é o golpe clássico do "recebi 1.000 XRP".
- **Stellar**: pela SEP-29, a entrada de dados `config.memo_required` igual a `"1"` na conta de destino torna o memo obrigatório. Endereços muxados `M…` carregam o ID e vão inteiros até a transação (`KEY_TYPE_MUXED_ED25519`, sem memo): até a auditoria 4 o app os trocava pela conta base `G…` com o ID como memo (M1). A conferência do plano compara o `M` inteiro, ID incluído. Destino inexistente pede `CreateAccount` com pelo menos 1 XLM, e com `M` é recusado, porque o ID se perderia.
- **QR e link de pagamento**: a tag ou o memo do link (`dt` do XRP Ledger, `text` do `ton://transfer/`, `memo` do SEP-7) vai para o campo, com a nota "veio do código que você leu"; antes eram descartados (B5). Memo de hash ou de retorno, ou memo de texto só com números (que o app enviaria como memo ID), é recusado: o dono digita.
- **EVM**: destino com código (`eth_getCode` diferente de `0x`) gera aviso. Destino igual ao contrato do próprio token, ou a um router da lista, bloqueia.
- **Solana**: destino fora da curva (PDA) ou uma conta de token no lugar de uma carteira gera aviso ou bloqueio.
- **Tron**: `fee_limit` com teto. USDT TRC-20 é `TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`.

### 4.9 Simulação: a segunda opinião

- **EVM**: `eth_simulateV1` com `validation: true` e `traceTransfers: true` (geth 1.14.9+, suportado por Alchemy, QuickNode e Chainstack), em 2 provedores.
  - Resultado esperado: sai exatamente amountIn do token vendido (mais gás), entra pelo menos minOut do token comprado.
  - Nenhum `Approval` ou `ApprovalForAll` do usuário além do esperado.
  - Provedores divergindo, ou revert, bloqueiam.
- **Solana**: `simulateTransaction` com `accounts` das contas de token do usuário, em 2 RPCs de operadores diferentes; os dois precisam confirmar o efeito, e o limite de CU sai do maior consumo.
- **XRPL**: `simulate` (rippled 2.4.0+).
- **Stellar clássica**: só validação local.
- Sem simulação disponível, envio simples continua funcionando, mas swap, approve e ordem ficam bloqueados.

### 4.10 Envenenamento de endereço e área de transferência

- **No envio**, o destino é comparado com para onde a carteira já enviou (o registro do app e o histórico da rede), com os endereços salvos e com os das carteiras deste iPhone. As carteiras só de observação ficam de fora: o endereço delas não é do dono (auditoria 4, C7-07).
  - É parecido quem não é a mesma conta mas casa as pontas, depois do prefixo da rede: 3 ou mais no começo e 3 ou mais no fim, somando 7, ou 5 ou mais numa ponta só (2+6, 0+10). A ponta só pegou, num histórico real da Tron gravado nos testes, o sósia que casava 2 no começo e 5 no fim.
  - Não é parecido: a mesma conta escrita de outra forma (caixa do EIP-55, forma amigável e crua da TON), o `M` da Stellar e a conta base dele, e na Cardano dois endereços com a mesma credencial de pagamento.
  - O aviso é bloqueante: mostra os dois endereços lado a lado, diz de onde o dono conhece o outro ("Você já pagou", "Sua carteira", "Salvo como, nunca recebeu daqui"), e só segue quem digita os 6 caracteres onde os dois diferem.
  - Sem histórico legível, o primeiro envio para um endereço que não é contato nem carteira pede os 6 do meio, escondidos na tela.
- **Ao salvar um endereço**, ele vira de confiança, então passa pela mesma comparação e o dono digita 6 caracteres olhando a fonte: onde difere do parecido, com os dois lado a lado; ou, sem parecido, os 6 do meio, escondidos na tela e no endereço como foi colado, para o dono ler na fonte e não na tela que o clipper preencheu. Antes ele nascia sem conferência, e um clipper no Mac que trocasse o endereço na hora de salvar invertia o aviso de parecido.
- **No histórico**:
  - Ocultar por padrão as transferências de valor zero, o pó e os tokens fora da lista.
- **No saldo**, token fora da lista aparece em "Outros tokens", marcado como não verificado, sem preço até uma fonte confiável ter o contrato (CoinGecko por plataforma, reserva CoinPaprika por contrato; nunca pelo símbolo), e fora do total enquanto não tiver preço. O suspeito (`TokenSafety`: site ou @ no nome, isca, símbolo que imita stablecoin ou moeda nativa depois de desfazer letras cirílicas e de largura cheia, poeira chegada sem pedir, caractere invisível, lista negra da própria fonte) fica atrás de "Mostrar suspeitos" e nunca entra no total. Na EVM o indexador só diz quais contratos a conta tem: saldo e casas são relidos na rede.
- **Moeda custom** só nasce de leitura na própria rede, com dois provedores concordando nas casas decimais, e nunca com o contrato de um token da lista. No envio (EVM, Solana, Stellar), o motor relê as casas em dois provedores antes de montar, bloqueia o próprio contrato como destino e põe o aviso de não verificado na revisão; a conferência do plano (`PlanIntentCheck`), a revisão e o PIN são os mesmos. Tron, TON e XRP Ledger recusam com o motivo.
  - Um `Transfer` com `from == self` numa transação cujo `tx.from` não é self é marcado como falsificado.
  - Nunca oferecer "copiar endereço" a partir de uma transação recebida de um desconhecido.
- **Primeiro envio para um endereço**: aviso de que nunca houve envio para ali.
- **Tela de confirmação**: o endereço aparece inteiro, em grupos de 4, com EIP-55. Endereço com maiúsculas e minúsculas misturadas e checksum inválido é recusado.
- **Área de transferência**: no iOS, nenhum app lê a área de transferência em segundo plano. O sequestro realista acontece no computador de origem, e o Universal Clipboard traz o endereço trocado. Defesa:
  - Colar por `PasteButton`.
  - A conferência de 6 caracteres com a fonte vale ao salvar um endereço, com endereço parecido e no primeiro envio sem histórico. No primeiro envio com histórico e sem parecido, o app avisa que é o primeiro envio e não pede os 6: é o limite que fica.
  - Preferir QR e o catálogo.

### 4.11 Identificadores de rede, compilados e conferidos

- EVM: Ethereum 1, Arbitrum 42161, Base 8453, OP 10, Polygon 137, BNB 56, Avalanche 43114, Plasma 9745, X Layer 196, Linea 59144, Unichain 130, Sonic 146, Celo 42220.
- A passphrase da Stellar.
- Tudo num arquivo travado por lock, e as mudanças passam pelo CODEOWNERS.

### 4.12 Pontes

Revisado em 12/10/2026 com o agente de segurança, antes do código. Pontes são a parte de cripto que mais foi roubada (Ronin, Wormhole, Nomad, Multichain), e o desenho parte disso.

**Escopo da v1**
- Redes: Ethereum, Arbitrum, Base e Optimism. As quatro têm CCTP V2 rápido, SpokePool do Across, ETH nativo e simulação em dois RPCs.
- Segunda leva, 14/10/2026: Polygon, Linea, Unichain, Sonic e Plasma, cada uma com simulação em dois RPCs e as implementações lidas no slot EIP-1967 em dois RPCs.
  - USDC pelo CCTP nas cinco.
  - ETH pelo Across só na Linea e na Unichain. Na Polygon o Across entrega WETH de ponte, e na Plasma o nativo é XPL.
  - USDT0 pelo Across na Unichain e na Plasma. O USDT da Linea é de ponte, e o da Polygon ainda não tem a conferência de emissor registrada.
  - A Sonic fica só com USDC: o Across não tem SpokePool lá.
- Terceira leva, 14/10/2026: a BNB, só pelo Across, sem CCTP (`BridgeAllowlist.bnb.cctp` é nulo). Revisada pelo agente de segurança antes de ir para o app; o médio (M1) e os baixos foram corrigidos.
  - **A BNB fica fora da regra "a mesma moeda, na versão do emissor".** Lá o USDC, o USDT e o ETH são os da Binance (Binance-Peg): recibos que valem enquanto a Binance mantiver o lastro e o resgate. A tela, a lista de moedas ("Binance-Peg" no nome) e a revisão (linha "Na BNB" e aviso) dizem isso.
  - O USDC da Binance é proxy EIP-1967 com admin numa chave só (EOA); a implementação entra nos pins da rota, nos dois sentidos, lida em dois RPCs. O USDT e o ETH de lá não são proxy, mas o dono (EOA) cunha quanto quiser.
  - Lá o USDC, o USDT e o ETH são os da Binance, com 18 casas, e são os contratos que o Across entrega (`available-routes`). O SpokePool, a implementação no slot EIP-1967 e o `wrappedNativeToken()` (WBNB) foram lidos em dois RPCs; o endereço bate com o `deployed-addresses.json` do Across e com a API.
  - A comparação de valores e a taxa são feitas na unidade da origem (`BridgeAsset.rescale`, arredondando o que chega para baixo): uma cotação que entregasse mais do que saiu, ou com taxa acima do teto, é recusada com 6 de um lado e 18 do outro.
  - Na BNB o ETH é token: sai com approve exato ao SpokePool e sem `value`; para a Polygon continua fora.
  - A chegada pelo Across confere o `depositId` do FundsDeposited do próprio recibo e o `fillDeadline` assinado (pentest de 14/10/2026, B4) e, quando a moeda chega como token, o Transfer dela para o dono com o valor cheio. "Devolvido" só com o reembolso conferido na origem, em dois RPCs.
  - A chegada pelo CCTP exige, no recibo da cunhagem, o `MessageReceived` do MessageTransmitter com o nonce, o domínio de origem e o remetente da mensagem atestada. Uma cunhagem antiga de mesmo valor, devolvida por uma Iris comprometida, não conta como chegada.
  - Chegar mais do que saiu é recusado na unidade mais fina (`BridgeAsset.fits`), e rota, chamada e pedido têm de concordar antes do plano e da leitura de estado (`callMatchesRoute`).
  - Risco aceito: a custódia da Binance e as chaves únicas dos tokens. Deixa de ser aceitável se a Binance suspender saque ou resgate, se o USDC da BNB ficar mais de 1% abaixo do USDC da Circle por mais de um dia, ou se o admin ou a implementação do proxy do USDC mudarem (a ponte já para sozinha no último caso).
- Quarta leva, 17/10/2026 (pedido do dono de liberar toda moeda que der): WBTC pelo Across entre Ethereum, Arbitrum, Optimism e Polygon, as redes em que o Across entrega o mesmo contrato da lista curada (`available-routes` ao vivo). Em dois RPCs de cada uma: código igual e `decimals()` 8. Na Arbitrum é o token padrão da ponte da Arbitrum (proxy de beacon da própria Arbitrum), na Polygon o da ponte PoS: valem enquanto a ponte oficial da rede valer, como o ETH e o USDC de ponte. A Linea fica de fora (o WBTC de lá não está na lista). Teto da taxa: 0,5% ou US$ 3, com teto absoluto de 5.000 satoshis, pela mesma razão do ETH.
- Quinta leva, 17/10/2026 (pedido do dono): **USDT para a Tron pela Legacy Mesh do USDT0, a ponte da própria Tether** (LayerZero), da Ethereum e da Arbitrum, só nesse sentido (a volta exige assinar chamada de contrato na Tron e fica para depois).
  - Contratos: o `UsdtOFT` da Ethereum (`0x1F74…dFB0`) e o da Arbitrum (`0x7765…9B92`), verificados no Sourcify com match exato, sem proxy, código igual em dois RPCs; o da Tron (`TFG4w…zevLPt`). Na cadeia, em duas fontes de cada lado: `token()` o USDT do emissor (Ethereum) e o USDT0 (Arbitrum), `feeBps()` 3, `peers(30420)` o `UsdtOFT` da Tron, e na Tron `token()` o USDT TR7NH…Lj6t e os pares de volta.
  - Nada vem de API: a taxa da Tether, o que chega, a liquidez da Tron (`credits`) e a taxa de mensagem saem do próprio contrato (`quoteOFT`, `quoteSend`), por `eth_call` em duas fontes concordando (a taxa de mensagem, a maior das duas, com 10% de folga; a sobra volta ao dono pelo EndpointV2 na mesma transação).
  - O app monta o `send` e lê de volta pelo decodificador estrito: destino Tron (30420) e nenhum outro, `to` = os 20 bytes da conta Tron **da mesma carteira** (nunca digitada), `extraOptions`, `composeMsg` e `oftCmd` vazios, lzToken zero, troco para o dono, `minAmountLD` = o que o contrato cotou. Taxa maior que a cotada depois disso reverte a transação, não tira do dono.
  - Tetos: taxa da Tether até 0,1% (`USDT0Mesh.feeCapBps`), taxa de mensagem até 0,02 ETH (vista 0,0047), e o bloqueio de 5% do valor somando as duas (com o preço do ETH). Abaixo de uns 250 USDT a taxa de mensagem, fixa em ~US$ 11, já passa disso.
  - No plano: o contrato lido de novo (par, token, taxa, liquidez), approve exato ao `UsdtOFT` (zerado antes no USDT da Ethereum), simulação em duas fontes com o USDT saindo do dono, a taxa de mensagem só como `value` para o próprio `UsdtOFT` e o `OFTSent` para a Tron com o valor e o mínimo. A conta Tron da carteira tem de estar sob a chave dela (`TronReader.ownerControl`): com outra chave nas permissões, recusa.
  - Chegada: o `guid` da mensagem sai do `OFTSent` do recibo do envio (dois RPCs); a entrega na Tron é achada pelo `guid` na API de eventos da TronGrid e lida inteira no nó solidificado de dois provedores, com o `OFTReceived` desse `guid`, para a conta Tron, vindo da rede de origem, e o `Transfer` do USDT da Tron do `UsdtOFT` para a mesma conta com o mesmo valor.
  - Risco aceito: a Tether controla os `UsdtOFT` (dono pode mudar a taxa, os pares e anular mensagens) e a entrega depende da LayerZero. É a mesma confiança de quem segura USDT. A carteira para sozinha se o par ou o token mudarem, ou se a taxa passar do teto.
- A mesma moeda dos dois lados, na versão do emissor:
  - USDC só pelo CCTP V2 da Circle, que queima numa rede e cunha na outra. Não há cofre de ponte nem token embrulhado, e a única confiança nova é na Circle, que quem segura USDC já tem.
  - ETH pelo Across, entre as quatro redes.
  - USDT pelo Across, só entre Ethereum e Arbitrum (USDT0). Na Base e na Optimism o Across entrega USDT de ponte, não o do emissor.
- Fora da v1, cada um com motivo:
  - CCTP para a BNB: queima, mas não cunha. O TokenMessengerV2 da Ethereum aceita o domínio 17, e na BNB `getLocalToken` é zero para todas as origens. Uma queima para lá se perderia. A BNB entra só pelo Across.
  - Celo, Sonic e X Layer: falta CCTP ou SpokePool.
  - WBTC: nas L2 é de ponte.
  - Redes fora da EVM, salvo o USDT para a Tron pela Tether (quinta leva).
  - Ponte nativa de rollup: saque de 7 dias, prova e finalização na L1, e USDC.e em vez de USDC.

**Regras**
- Destinatário e depositante são a própria conta do dono. A conta de destino da carteira tem de ter o mesmo endereço da origem.
- Nenhuma mensagem e nenhuma chamada no destino. A única exceção é a constante de encaminhamento da Circle (`cctp-forward`, 32 bytes), com `destinationCaller` zero. Qualquer um pode enviar o resgate, mas o contrato só cunha para o `mintRecipient` atestado.
- O app monta a calldata. A Iris e a API do Across só informam taxa, prazo e limite, e a consulta de taxa vai sem endereço.
- O Across vai sem relayer exclusivo e com prazo de entrega da própria carteira: 2 h depois da cotação. Um relayer exclusivo escolhido pela API, que nunca entregasse, prenderia o depósito.
- A carteira nunca assina speed-up do Across. Ele permitiria a quem é depositante trocar destino e valor.

**Tetos**
- CCTP rápido: até 2 bps. CCTP padrão: zero. Encaminhamento: até 10 USDC.
- Across: até 0,5% do valor ou US$ 3, o que for maior; no ETH, a parte em dólar para em 0,002 ETH (o preço vem de uma fonte só; pentest de 14/10/2026, B5).
- A ponte recusa quando a taxa passa de 5% do valor.
- Por queima, até 10.000.000 USDC: o `burnLimitsPerMessage` lido nas quatro redes.

**Antes de assinar o depósito**
1. A calldata é montada de novo a partir da transferência e comparada byte a byte com a que vai ser assinada. Dono dos dois lados, ativos, redes e domínios são os compilados.
2. A implementação de cada proxy da rota, nas duas redes, é a fixada (slot EIP-1967), lida em dois RPCs:
   - TokenMessengerV2 e MessageTransmitterV2 no CCTP;
   - SpokePool no Across.
   Implementação diferente desliga a ponte até a próxima versão do app.
3. No CCTP, o destino precisa confirmar três coisas: `localDomain()` igual ao domínio pedido, `getLocalToken(domínio da origem, USDC da origem)` igual ao USDC compilado do destino, e `isBlacklisted(dono)` falso.
4. `eth_getCode(dono)` no destino é vazio em dois RPCs. Uma delegação EIP-7702 pode ser um varredor posto por quem roubou a frase, e o SpokePool entrega ETH a carteiras 7702.
5. Simulação em duas fontes:
   - sai do dono exatamente o valor, só do ativo movido;
   - nenhum Approval além do exato;
   - o contrato emite `DepositForBurn` ou `FundsDeposited` com cada campo igual ao montado.

**A chegada**
- Só conta com a entrega conferida no destino, em dois RPCs.
- No CCTP:
  - a mensagem atestada pela Circle bate campo a campo com a queima assinada (`CCTPMessage.check`);
  - o recibo da entrega tem o `Transfer` do USDC do destino para o dono, com `amount - feeExecuted`.
- No Across, o recibo da entrega tem o `FilledRelay` do SpokePool do destino com depositante, destinatário, tokens e valores do depósito, sem alteração.
- A ponte pendente fica nos metadados cifrados: a transferência assinada e o hash do depósito.

**Risco aceito**
- A Circle pode congelar USDC ou reter atestações. Reter é negação de serviço, não roubo: a queima só cunha para o dono.
- No Across, o reembolso depende do oráculo otimista da UMA.
- Um upgrade de contrato deixa a ponte desligada até a próxima versão do app.

**O que faria deixar de ser aceitável**
- Um incidente de atestação na Circle.
- Um reembolso do Across perdido.

**Pendente**
- O resgate pelo próprio app quando o encaminhamento da Circle falhar (`receiveMessage`). A mensagem tem de ser igual ao evento do próprio recibo, salvo os quatro campos que o evento emite zerados, e `usedNonces` tem de ser zero.

---

## 5. Rede

### 5.1 O módulo de rede

É o único target que usa `URLSession`, e não enxerga nenhum tipo do módulo de chaves.

Configuração:
- `URLSessionConfiguration.ephemeral`.
- `urlCache = nil`, `httpCookieStorage = nil`, `urlCredentialStorage = nil`, `httpShouldSetCookies = false`, `requestCachePolicy = .reloadIgnoringLocalCacheData`.
- `waitsForConnectivity = false`.
- `tlsMinimumSupportedProtocolVersion = .TLSv12` (TLS 1.3 no relay).
- User-Agent constante, para não entregar a versão exata do app e do iOS.

Proibições:
- `URLSession.shared` e `AsyncImage`: gravam `Cache.db` e `fsCachedData` em `Library/Caches`, e isso revela quais tokens o dono olha.
- Redirecionamento: `willPerformHTTPRedirection` devolve `nil`.

Limites:
- Resposta de até 4 MB, com cancelamento no delegate.
- A busca de Receber (`CoinCatalog`) pergunta ao CoinGecko só o texto digitado (`/search`) e, quando o dono toca numa moeda, as redes dela (`/coins/{id}`). O id vai no caminho da URL só com letras minúsculas, dígitos e hífen. O contrato de cada rede passa pela validação da moeda custom antes de virar endereço na tela; símbolo de stablecoin, de nativa ou da lista só aparece com o id da lista; o aviso público do CoinGecko vira um alerta na tela, sem o texto (que traz link).
- Timeouts: 10 s por requisição de RPC, 15 s de cotação, 30 s por recurso.
- Até 2 novas tentativas, com jitter, e só em leitura. Broadcast só reenvia os **mesmos bytes assinados**.

### 5.2 ATS e pinning

- ATS padrão, sem nenhuma exceção: nada de `NSAllowsArbitraryLoads`, `NSExceptionAllowsInsecureHTTPLoads` ou `NSAllowsLocalNetworking`.
- **Pinning só no relay**: `NSPinnedDomains` → `relay.<domínio>` com `NSIncludesSubdomains = false` e `NSPinnedCAIdentities` contendo o SPKI-SHA256 de **duas CAs independentes** (a atual e a reserva).
- Folha nunca: pelo CA/B Forum SC-081, certificados folha passam a durar 200 dias desde março de 2026 e chegam a 47 dias em 2029.
- **Provedores de terceiros não recebem pinning.** Eles trocam de CA sem aviso, o app ficaria inutilizado, e a defesa real contra eles é a validação dos dados.
- Risco de inutilizar o app: se o pin quebrar, só a rota privada cai. O dono escolhe "direto aos provedores", com o preço explicado: o provedor passa a ver o IP. Não existe kill-switch remoto, porque ele seria controle remoto.

### 5.3 O relay

- **Sem estado e sem proxy aberto.** O cliente manda um identificador de provedor mais um caminho de uma lista de permissões, e o relay mapeia para URLs base fixas. Isso fecha SSRF.
- Lista de métodos JSON-RPC permitidos (`eth_chainId`, `eth_call`, `eth_getBalance`, `eth_getTransactionCount`, `eth_estimateGas`, `eth_feeHistory`, `eth_simulateV1`, `eth_sendRawTransaction`, `eth_getTransactionReceipt`, e os equivalentes das outras redes).
- Retira IP (não repassa `X-Forwarded-For`), User-Agent, `Accept-Language` e cookies. Acrescenta a API key. Responde com `Cache-Control: no-store`.
- **Endereço nunca vai em caminho ou query, só no corpo de POST.** Toda plataforma de hospedagem (Railway, Fly, Cloudflare) grava caminho e IP nos logs HTTP.
- Sem log de corpo; métricas só por rota e status. Limite de taxa em memória, ou com Private Access Tokens (seção 9, COULD).
- O código do relay vive no mesmo repositório, e o digest da imagem publicada é divulgado.
- O que um relay comprometido consegue: perda de privacidade, perda de disponibilidade e rota ruim dentro do slippage. **Nunca perda de fundos.**

### 5.4 O que o app nunca aceita do relay nem de provedor

- `chainId`, passphrase de rede e hash de gênese.
- Allowlists de routers, spenders e programas; contratos, `decimals` e emissores de ativos listados.
- Endereços de destino.
- Digestos para assinar, e calldata que o nosso decodificador não entende.
- Taxa acima do teto.
- Tipos e domínios EIP-712.
- Links para abrir.
- Configuração ou flags que mudem segurança (não existe nenhuma).
- "Atualize para a versão X".
- Imagem fora de PNG ou JPEG base, ou maior que 160 KB (as logos da Trust Wallet têm 256 px e passam de 70 KB). Logos dos tokens listados vão embutidos no app, e SVG, WebP e GIF são recusados, porque decodificação de imagem é superfície de exploit dentro do processo que assina. A logo baixada abre pelo ImageIO só se o tipo lido no arquivo for PNG ou JPEG, com uma imagem só e até 2048 px de lado, e já reduzida a 256 px (`SafeImage`, auditoria 3, B4).
- Preço: serve para exibir e para checagem de sanidade, nunca sozinho para calcular `minOut`.

### 5.5 Consenso entre provedores

- **Nonce e sequence**: 2 ou mais provedores concordando. Se divergirem, usa o registro local de envios; se ainda assim não fechar, bloqueia.
- **Saldo**: mostra quando 2 concordam; se não, mostra "divergente" com os dois valores.
- **Taxa**: mediana, com teto.
- **Bloco das leituras EVM concordantes** (saldo, código, `balanceOf`, `allowance`, casas): a menor ponta de 2 provedores, menos o recuo da rede; pontas a mais de 3 recuos uma da outra (uns 30 s de blocos) bloqueiam.
- **Recebimento "confirmado"**: 2 provedores mais N confirmações. Recibo falso é golpe comum em negociação P2P.
- **Tabelas de lookup da Solana e registro do Settler da 0x**: 2 provedores.
- **Privacidade**: consulta endereço por endereço, **nunca xpub** para provedor. Mandar a xpub entrega a carteira inteira.

### 5.6 O que nunca vai para log, nem no app nem no relay

Palavras, entropia, chaves privadas, xpub, PIN, senhas, AP, RK, DEK, endereços, valores, saldos, hashes de transação, calldata, assinaturas, IP, nomes de arquivos de envelope e respostas de API.

---

## 6. Envelope `.esclbr`

- **Tipo de arquivo**:
  - O Escalibur declara `UTExportedTypeDeclarations` para `app.escalibur.envelope` (extensão `esclbr`, conforme `public.data`). Hoje não declara.
  - A carteira declara `UTImportedTypeDeclarations`, `CFBundleDocumentTypes` com `LSHandlerRank = Alternate` e `UIFileSharingEnabled = NO`.
- **Entrada**:
  - `fileImporter` com escopo de segurança e `onOpenURL`.
  - AirDrop e "Abrir com" deixam uma **cópia em `Documents/Inbox`**, que entra no backup do iCloud. Apague a cópia logo depois de ler e varra `Documents/Inbox` e `tmp/` a cada lançamento. O original do dono no app Arquivos não é tocado, e a tela diz isso.
- **Antes de ler**:
  - `resourceValues([.fileSizeKey, .isRegularFileKey])` precisa dar exatamente 16.504 bytes e arquivo comum.
  - A leitura é `FileHandle.read(upToCount: 16_505)`, nunca `Data(contentsOf:)`.
- **Cabeçalho**: as checagens que já existem, mais:
  - `binding == 0`; um envelope vinculado ao SE é recusado com mensagem própria.
  - `memoryKiB ≤ os_proc_available_memory() − 300 MiB` medido **na hora de abrir**.
  - Tempo estimado (m × t pela taxa calibrada) de até 10 s; acima disso, confirmação explícita.
  - Argon2 fora do MainActor.
- **Conteúdo** (depois de a tag fechar):
  - `OpeningContents` decodificando direto para `SecureBytes`.
  - Versão igual a 1; `kind == bip39` (`slip39Share` recebe mensagem própria); idioma válido.
  - 12 a 24 palavras, todas da lista, e checksum que fecha.
  - Passphrase honrada.
  - Nome e notas são texto não confiável: sem controles bidi (U+202A–202E, U+2066–2069) e sem largura zero, com tamanho limitado, e exibidos só com `Text(verbatim:)`. `Text` com interpolação vira `LocalizedStringKey` e interpreta Markdown.
- **Erro**: uma mensagem única para qualquer falha AEAD, "Não foi possível abrir com essa senha". As quatro tentativas de compartimento, sempre na mesma ordem, continuam como estão.
- **Senha do envelope**:
  - Vive só em `SecureBytes`, pelo `GhostTextField`/`CipherField` do Escalibur, com `textContentType = nil`.
  - Zerada assim que `open` retorna, com sucesso ou não. Não entra em cache para "tentar de novo".
- **Seed revelada**:
  - O padrão é **não mostrar**. A importação vai direto para o armazenamento, e a tela mostra a identidade para conferência: fingerprint BIP-32 e o primeiro endereço BTC e EVM.
  - "Ver palavras" exige PIN e, com o Face ID ligado, o rosto (A1), e segue a sessão de revelação do Escalibur: 3 palavras por vez, ou as 12 (ou 24) numa chapa só em "Ver todas de uma vez" (pedido do dono, 15/10/2026). As mesmas palavras por 60 s seguidos escondem sozinhas e voltam com um toque (N2); escondem também ao sair do primeiro plano. Proteção de captura e sem seleção. Antes, três "estou ciente"; o do Espelhamento do iPhone no Mac saiu a pedido do dono, e o aviso dele fica na checagem do aparelho (C7-06). Do toque em "Ver as palavras" até elas abrirem, a lista sai da tela. Copiar, só pelo aviso descrito em "Área de transferência".
  - A passphrase aparece com o espaço visível (␣) e a contagem de caracteres: um espaço a mais já abre outra carteira.
- **Importar** (frase ou envelope): a conferência antes de guardar mostra endereços e impressão digital, e só guarda com o aceite de que quem deu as palavras (ou o envelope e a senha) controla a carteira. Na Tron, as permissões da conta são lidas na rede (`TronReader.ownerControl`): outra chave no controle vira aviso vermelho, o golpe da "frase com saldo". A carteira de um envelope não passa a ser a carteira em uso sozinha, e nome repetido ganha "(envelope)" (auditoria 4, C7-05).
- **Exportar**:
  - Exige PIN e, com o Face ID ligado, o rosto (A1).
  - Senha padrão **gerada**: 6 palavras BIP-39 do CSPRNG, 66 bits. Com os parâmetros de referência, isso custa cerca de 97 mil anos a um Estado e 9,7 milhões a crime organizado. Com 5 palavras seriam 48 anos contra um Estado.
  - Senha escolhida pelo dono, livre, com no mínimo 4 caracteres (pedido do dono, 14/10/2026). Enquanto ele digita, a tela diz em quanto tempo a senha cai com os parâmetros reais do envelope: muito fraca (crime organizado em menos de 1 dia), fraca (até 10 anos), boa contra ladrão comum (um Estado em menos de 1.000 anos) e forte.
  - O medidor é o modelo do zxcvbn (`PasswordStrength`): palavras e senhas comuns pela posição nas listas de frequência do zxcvbn-ts (MIT, travadas em `forca.lock`), palavras BIP-39 de todos os idiomas com no máximo 11 bits, repetição, sequência, ano, data e linha de teclado quase de graça, e força bruta só no resto. O medidor anterior dava "forte" a "abandon" seis vezes e a doze pontos de exclamação (auditoria do envelope, 14/10/2026).
  - Abaixo de forte, o lacre só sai com o "sim" explícito (`Envelope.seal(acceptedRisk:)`, que só a folha de confirmação entrega). Nas faixas muito fraca e fraca, "usar mesmo assim" exige segurar o botão por 2 s. Senha só de dígitos ganha o aviso de não usar o código do iPhone nem o PIN. A senha sorteada pelo app vale a entropia exata do sorteio (66 bits) e vai das posições direto para o buffer seguro.
  - Continua recusada a senha com duas ou mais palavras da própria frase: o papel da frase abriria o envelope, e isso anula o backup.
  - Subir o Argon2 não compensa senha fraca: dobrar m × t compra 1 bit. A calibração mede na prioridade do lacre, com sonda de 128 MiB rodada duas vezes, e o piso do lacre é t = 3 (a abertura aceita t = 2 dos envelopes antigos).
  - KDF por `KDFCalibration.calibrate()`, com piso de 256 MiB. `cloudEnabled = false`, `passwordOnly`.
  - O arquivo vai para `tmp/` com `.completeFileProtection` e exclusão de backup, e é apagado quando o compartilhamento termina.
  - **Condição posterior obrigatória**: reabrir o envelope gerado com a mesma senha antes de entregá-lo, como o `plantDecoy` já faz.
- **Compatibilidade byte a byte**:
  - Fixtures nos dois sentidos: um `.esclbr` gerado pelo Escalibur e aberto pela carteira, e um exportado pela carteira e aberto pelo `decifrar.py` no CI.
  - Um `nucleo.lock` com o SHA-256 dos arquivos compartilhados, nos dois repositórios, para detectar divergência.
- **Frase pública honesta**: "A seed nunca sai do aparelho em claro. Cifrada, só por ação explícita sua, num envelope cuja senha não sai."

---

## 7. Plataforma

- **Snapshot do seletor de apps**: a cobertura opaca do `PlatformGuards` em `willResignActive`, em todas as janelas, e também quando `scenePhase` deixa de ser `.active`.
- **Captura de tela e gravação**:
  - Gravação e espelhamento: `sceneCaptureState` com `registerForTraitChanges` esconde o conteúdo.
  - Captura de tela só é notificada depois do fato, então a defesa é a janela curta.
  - Camada segura (pedido do dono, 16/10/2026): o que mostra segredo é desenhado dentro da vista em que um `UITextField` com `isSecureTextEntry` desenha o texto. O iOS deixa essa camada fora da captura de tela, da gravação, do espelhamento por AirPlay e da captura por outro app (ReplayKit), como faz com o campo de senha: na captura, o lugar sai vazio, com o que está por trás (a chapa sem as palavras). As duas defesas se somam: a guarda acima continua escondendo a tela inteira durante a gravação. Código em `Design/SecureCaptureContainer.swift` (`SecureCaptureContainer` e o modificador `.protectedFromCapture()`).
    - Onde vale: as palavras nos cartões e na chapa (`RecordWordsView`, também na revelação e no "Só ver as palavras" de um envelope) e a passphrase mostrada ali; a conferência das palavras, com o campo e as sugestões; as posições, a cifra viva e a barra de sugestões da importação e da conferência do modo reforçado; os campos de passphrase e de senha do envelope (`PasswordBox`: a cifra viva e o texto revelado ao segurar o dedo; os pontos o iOS já tirava), em importar, conferir a passphrase, carteira com passphrase, criptografar e abrir um envelope; as 6 palavras sorteadas do envelope; a frase de voz ouvida e a mostrada na conferência; e o teclado da Escalibur (`WordKeyboardInputView`), cujas teclas acesas e tecla apertada dizem a palavra.
    - Como a camada é achada, sem API privada por nome: um campo seguro novo, sem borda, sem texto de exemplo e sem botão de limpar, tem uma subview só, a que desenha o texto, do tamanho do campo, e é ela (`SecureCanvas`). Conferido no código do UIKit do iOS 17.5 e do 26.5 (os simuladores do Xcode 26.6): ao virar seguro, o campo marca a camada dessa vista; ela nasce sem toque e devolve o toque ao que está dentro dela. O 18 não foi conferido aqui. Sem a subview, a tela mostra o conteúdo como antes, só com a guarda. O `tools/verificar.sh` confere que o arquivo não usa nome de classe privada, seletor nem KVC.
    - Limite: não vale contra jailbreak (quem lê a memória do processo não precisa da tela), contra câmera apontada para a tela nem contra o teclado do iPhone, que é desenhado por outro processo, numa janela que a camada não alcança. O teclado da Escalibur é desenhado pelo app, e por isso entrou. Fica de fora o campo de corrigir a frase de voz (um `TextField` do SwiftUI com `@FocusState`, que não atravessa para o hospedeiro de dentro) e o teclado do PIN. Depende da hierarquia interna do UIKit, que a Apple pode mudar: o `CaptureShieldTests` confere a cada versão do iOS que a captura da chapa sai sem as letras, e que a mesma medida vê as letras com a camada desligada (`-sem-camada-segura`, só em depuração). O Espelhamento do iPhone no Mac segue sem garantia (abaixo), e o resultado em cada caminho de captura (tela, gravação, AirPlay, ReplayKit) se confere no aparelho.
- **Teclados**:
  - `application(_:shouldAllowExtensionPointIdentifier:)` devolve falso para `.keyboard`.
  - Campos de frase e senha com `autocorrectionType = .no`, `spellCheckingType = .no`, `smartInsertDeleteType = .no`, `inlinePredictionType = .no` (iOS 17), `writingToolsBehavior = .none` (iOS 18), `isSecureTextEntry = true`, `textContentType = nil`.
  - Teclado próprio das palavras (`WordKeyboardView`, como `inputView` do campo), opcional em Ajustes, Segurança, desligado por padrão, sempre ligado no modo reforçado e na conferência das palavras para ligá-lo (16/10/2026, fecha C7-12):
    - O teclado do iPhone não recebe as letras: sem previsão, ditado, aprendizado de vocabulário nem balão da tecla.
    - Só acendem as letras que ainda formam uma palavra das listas latinas (`WordLexicon`, no Kit). A forma sem acento é única em cada uma das seis listas, e no fim a frase digitada sem acento é resolvida no idioma em que ela fecha (`WordLexicon.resolve`).
    - O campo (`WordTextField`) recusa o ditado quando o iOS informa o modo ditado (a conferir no aparelho) e, com o teclado próprio, recusa colar e ler texto pela câmera pelo menu e qualquer letra que não forme palavra das listas latinas, venha do teclado físico ou do Mac.
    - O idioma das palavras já fechadas só ordena as sugestões, nunca apaga letra; as palavras fechadas são lidas direto dos buffers seguros, sem virar `String`.
    - O globo pergunta antes de trazer o teclado do iPhone, só para frases em japonês, chinês ou coreano.
    - Limite dito na tela: as sugestões e as teclas acesas mostram a palavra. O texto em digitação continua numa `String` do campo, como antes.
  - PIN pelo teclado próprio.
- **Rede na tela das palavras**: enquanto o formulário de importar ou conferir as palavras está aberto, o `HTTPClient` fica em silêncio (`beginQuiet`/`endQuiet`): nenhuma requisição sai, e as que estavam no ar são canceladas. A conferência da frase é toda local (checksum BIP-39 sobre as listas embarcadas). A conferência dos endereços, depois, volta a ler a rede.
- **Área de transferência**:
  - A frase só vai para a área de transferência pelo botão Copiar da chapa com todas as palavras, depois da `CopyPhraseSheet`: três "estou ciente" (qualquer app aberto pode ler a cópia; colar num site, chat ou nota pode custar o saldo; a Escalibur nunca pede as palavras) liberam o botão. A cópia é `.localOnly` (o Universal Clipboard não leva ao Mac) e expira em 60 s. Pedido do dono, 15/10/2026. Risco aceito: um app aberto dentro desse minuto lê a frase; o aviso diz isso com essas palavras. Fora desse botão, `.textSelection(.disabled)`.
  - Endereços: `UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: endereço]], options: [.localOnly: true, .expirationDate: agora + 120 s])`.
  - Colar a frase: mantém o comportamento do Escalibur (aviso e limpeza ao final).
- **Jailbreak e depurador**:
  - Só aviso. Detecção nesse caso é lombada: o atacante de T3 contorna com Frida, e um falso positivo trancaria o dono fora do próprio dinheiro.
  - Heurísticas: `/var/jb`, `/Applications/Sileo.app`, escrita fora do sandbox, imagens dyld com `frida|Substrate|libhooker|ellekit`, `DYLD_INSERT_LIBRARIES`, flag `P_TRACED` via `sysctl`.
  - Ao detectar: faixa fixa recomendando mover saldo para carteira de hardware. Nunca bloquear, nunca apagar, nunca avisar servidor.
  - `get-task-allow` falso no build de release.
- **Endurecimento (Xcode 26)**: ligar a capability Enhanced Security (`com.apple.security.hardened-process.enhanced-security-version = 1`, `platform-restrictions = 2`), o alocador por tipo, a pilha zerada (`-ftrivial-auto-var-init=zero`, importante para o C vendorizado) e os avisos de segurança do clang. Pointer authentication e MIE exigem iOS 26, arm64e e A19: ganha quem tem o hardware.
- **Logs**:
  - O módulo de chaves não tem logger nenhum.
  - Fora dele, só texto estático ou números de uma lista `.public`.
  - `.private` é redação por política: um perfil de log com dados privados, ou um sysdiagnose num aparelho configurado, revela o valor. `.sensitive` sempre redige. Mesmo assim a regra é não registrar.
  - Mensagens de `fatalError` e `precondition` vão para o relatório de crash, então nada interpolado no módulo de chaves.
- **Terceiros**: nenhum SDK de crash, analytics ou atribuição. Só os relatórios opcionais da própria Apple.
- **Sem WebView, sem push, sem Siri, Spotlight, App Intents ou Handoff na v1.** Notificações só locais; valor e moeda só se o dono ligar. Os widgets de preço existem desde 14/10/2026 e mostram só o preço de uma moeda; a moeda que acabou de entrar só aparece neles com o valor e a moeda ligados no aviso de recebimento (auditoria 4, R7-B3).
- **Deep links e QR** (BIP-21, EIP-681, `xrpl:`, `ton://transfer/`, SEP-7):
  - Só pré-preenchem, com parsing estrito e tamanho limitado.
  - Um QR com frase (12 palavras ou mais, ou o SeedQR de 48 ou 96 dígitos) é recusado no envio e em Endereços salvos, e nada dele vai para o campo (C7-13).
- **Espelhamento do iPhone no Mac**: não há API para um app saber dele (suporte da Apple). A guarda de captura vê gravação e AirPlay, não o espelhamento; a checagem do aparelho diz isso em vez de dar a tela como limpa, e a revelação pede um "estou ciente" sobre ele (C7-06).
- **Backup do iCloud**:

| Pode ir | Não pode ir |
|---|---|
| Idioma, moeda, tema (`UserDefaults`, lista fechada de chaves) e o marcador de instalação | Qualquer item do chaveiro (`ThisDeviceOnly` já impede), `metadados.bin` (excluído), `tmp/`, `Inbox`, caches, envelope exportado |

---

## 8. Auditabilidade e cadeia de suprimentos

### 8.1 Vendorização

- **libsecp256k1 v0.8.0**:
  - Tag `18f07c42218765cd46148d74d9fe575795f56dce` → commit `6e2c8bc4ecdc6e71dbe7a368f360d8d453ce435d`, de 3 de agosto de 2026. Tag assinada em PGP por Sebastian Falbesoner e marcada como verificada pelo GitHub.
  - Arquivos: `src/secp256k1.c`, `src/precomputed_ecmult.c`, `src/precomputed_ecmult_gen.c`, `include/*.h`, os headers de `src/` e o módulo `recovery`. Não habilite `silentpayments`; `extrakeys` e `schnorrsig` só quando houver Taproot.
  - Flags: `-DENABLE_MODULE_RECOVERY=1 -DECMULT_WINDOW_SIZE=15 -DECMULT_GEN_KB=86`.
  - `secp256k1.lock` guarda origem, tag, commit e o SHA-256 de cada arquivo.
  - `tools/vendorizar-secp256k1.sh` clona, roda `git verify-tag` contra o fingerprint gravado no repositório, copia os arquivos e regenera o lock. O diff do lock é o que se revisa.
  - Testes: `tests.c` do upstream no CI do macOS com os mesmos fontes; vetores Wycheproof `ecdsa_secp256k1_sha256` e a variante bitcoin (S baixo); BIP-32 vetores 1 a 5; BIP-84; EIP-155.
- **Keccak-256**: `Keccak-readable-and-compact.c` do XKCP (CC0), com `delimitedSuffix = 0x01`.
  - Autoteste: keccak256("") = `c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`.
  - Confronto cruzado: com sufixo `0x06` tem de bater com `CryptoKit.SHA3_256`, que existe no SDK do iOS 26.
- **RIPEMD-160**: `ripemd160.c` do trezor-crypto (MIT). Vetores: "" = `9c1185a5c5e9fc54612808977ee8f548b2258d31`, "abc" = `8eb208f7e05d987a9b044a8e98c6b087f15a0bfc`.
- **bech32/bech32m**: `segwit_addr.c` da referência de sipa, mais os vetores das BIPs 173 e 350.
- **Reaproveitados**: Argon2 (`argon2.lock`) e listas de palavras (`wordlists.lock`).
- **SHOULD**: descritores ERC-7730 do registro de clear-signing para os contratos da lista, também sob lock.

### 8.2 Módulos, com a fronteira verificável

- Targets separados, gerados pelo `genproj.py`:
  - `Nucleo`: o código compartilhado com o Escalibur.
  - `Chaves`: SE, chaveiro, derivação e assinatura.
  - `Cadeias`: codificação, decodificação e validação. Puro, sem rede.
  - `Rede`
  - `App`
- Dependências permitidas: `Chaves → Cadeias, Nucleo`; `Rede → Cadeias` (só tipos públicos); `App → todos`. **`Rede → Chaves` nunca.**

### 8.3 O que o `tools/verificar.sh` da carteira confere

| # | Regra | Como |
|---|---|---|
| 1 | Chaves e Cadeias não falam com a rede | `grep -rnE 'import (Network\|WebKit\|SafariServices\|CFNetwork)\|URLSession\|URLRequest\|NWConnection\|NWPathMonitor\|CFSocket\|CFStream\|getaddrinfo\|\bsocket\(\|WKWebView' Chaves/ Cadeias/` precisa vir vazio |
| 2 | Sem contornar por reflexão | `NSClassFromString\|NSSelectorFromString\|dlopen\|dlsym\|objc_msgSend\|perform\(` em Chaves/ e Cadeias/ precisa vir vazio |
| 3 | A fronteira vale também no binário | depois do build, `nm -um` na biblioteca de Chaves com `grep -E 'URLSession\|_nw_\|CFSocket\|CFStream\|_socket$\|_connect$\|_getaddrinfo'` precisa vir vazio |
| 4 | Rede só no módulo de rede | `URLSession` fora de Rede/ falha; `URLSession.shared` e `AsyncImage` em qualquer lugar falham |
| 5 | Rede não enxerga segredo | `import Chaves\|SecureBytes\|Mnemonic\|RootKey\|PrivateKey` em Rede/ falha |
| 6 | Hosts travados | a lista `grep -ohE 'https://[A-Za-z0-9.-]+'` de Rede/ e Info.plist precisa ser igual a `hosts.lock`; `"http://` em qualquer lugar falha |
| 7 | ATS | `plutil -extract NSAppTransportSecurity xml1 -o - Info.plist`: sem `NSAllowsArbitraryLoads\|NSExceptionAllowsInsecureHTTPLoads\|NSAllowsLocalNetworking`, com `NSPinnedDomains` e 2 ou mais `SPKI-SHA256-BASE64` |
| 8 | Nenhuma dependência de fora | `XCRemoteSwiftPackageReference` no pbxproj falha; `find` por `*.xcframework *.framework *.a *.dylib Podfile Cartfile Package.resolved` fora de build/ falha |
| 9 | Locks | argon2, secp256k1, keccak, ripemd160, bech32, wordlists, `allowlists.lock` (chains, routers, programas, emissores, tokens), `nucleo.lock` e o `decifrar.py` embarcado |
| 10 | Registro | `(^\|[^A-Za-z0-9_.])(print\|debugPrint\|dump\|NSLog)\(` fora de testes falha; `privacy: *\.public` fora de `tools/log-publico.allow` falha; `Logger(\|os_log` em Chaves/ falha |
| 11 | Aleatoriedade | `\.random\(\|randomElement\|shuffled\(\)\|arc4random\|drand48\|\brand\(\|SystemRandomNumberGenerator\|GKRandom` em Chaves/, Cadeias/ e Nucleo/ falha; a única fonte é `SecRandomCopyBytes` |
| 12 | Segredo em `String` | `(var\|let) +\w*(pin\|senha\|password\|seed\|mnemonic\|phrase\|entropy\|privateKey\|secret)\w* *(: *String\|= *"")` (sem diferenciar maiúsculas) e `@State.*(pin\|senha\|seed\|mnemonic)` falham |
| 13 | Chaveiro num ponto só | `SecItemAdd\|SecItemUpdate\|SecKeyCreateRandomKey` só em `Chaves/Chaveiro.swift` e `Chaves/Enclave.swift`; ali, `AfterFirstUnlock\|AccessibleAlways\|kSecAttrAccessibleWhenUnlocked\b\|SynchronizableAny\|\.userPresence\|\.devicePasscode\|\.biometryAny\|\.or\b` falha, e `ThisDeviceOnly` precisa aparecer. A exceção única do `.biometryAny` é a linha da `kand.qualquer` em `flags(for:)`, e `wrap(... .hardenedBiometryAny)` só embrulha o miolo, no construtor do registro (§2.3). `\.touchIDAny\|SecAccessControlCreateFlags\(rawValue\|flags\(for: *\.` também falham: os outros caminhos para a mesma flag |
| 14 | Booleano não autoriza | `evaluatePolicy` fora do arquivo de disponibilidade da interface falha |
| 15 | Comparação de segredo | `(digest\|tag\|mac\|hmac\|secret\|key)\w* *[!=]=` em Chaves/ falha; o caminho é `TempoConstante.igual` |
| 16 | Área de transferência | `UIPasteboard` fora de `Receive/ReceiveSheet.swift`, `ImportPhraseView.swift` e `SecurityScreens.swift` falha; toda cópia é `setItems` com `.localOnly` e `.expirationDate`; a frase vale até 60 s e só é copiada uma vez, pela `CopyPhraseSheet` de `RecordWordsView.swift` |
| 17 | Defesas de plataforma presentes | `shouldAllowExtensionPointIdentifier` com `.keyboard`, cobertura em `willResignActiveNotification`, `sceneCaptureState` e `NSFileProtectionComplete` no entitlement; a camada segura contra captura (`Design/SecureCaptureContainer.swift`, com `isSecureTextEntry = true`) sem `NSClassFromString\|NSSelectorFromString\|Selector(\|#selector\|forKey\|perform(\|dlsym\|objc_` nem nome entre aspas começando com `_` |
| 18 | Entitlements | conjunto exato de chaves; `aps-environment`, `icloud-*`, `ubiquity-*` e access groups de outros falham; no build arquivado, `codesign -d --entitlements :-` sem `get-task-allow` |
| 19 | Permissões no Info.plist | lista fechada (FaceID, Câmera; Microfone e Fala só se o recurso de voz existir); `NSUserTracking\|NSLocation\|NSContacts\|NSLocalNetwork\|NSBluetooth` falha |
| 20 | Sem SDK de terceiros | `Firebase\|Crashlytics\|Sentry\|Bugsnag\|Amplitude\|Mixpanel\|Segment\|AppsFlyer\|Adjust\|Branch\|OneSignal\|Datadog\|NewRelic\|Instabug\|FBSDK\|GoogleMobileAds\|PostHog` falha |
| 21 | Sem WebView | `WKWebView\|SFSafariViewController\|UIWebView\|ASWebAuthenticationSession` falha |
| 22 | UserDefaults | `UserDefaults\|@AppStorage` só com as chaves de `Ajustes/Chaves.swift` |
| 23 | Backup | o store cria o diretório com `isExcludedFromBackup = true`, e o autoteste confere via `resourceValues` |
| 24 | Determinismo | `__DATE__\|__TIME__\|__TIMESTAMP__` no C falha; `xcodebuild -version` igual a `.xcode-version` |
| 25 | Vetores | testes unitários de BIP-39/32/84, SLIP-10, EIP-55/155/712, Keccak, RIPEMD, bech32, XRPL, strkey e Solana, mais os fixtures de envelope nos dois sentidos com `decifrar.py` |
| 26 | Só Swift fora do C vendorizado | as regras de código leem só `.swift`, e a pasta do app inteira é fonte do alvo: `find App Kit/Sources Kit/Tests` por `*.m *.mm *.c *.cc *.cpp *.cxx *.c++ *.s *.asm *.h *.hh *.hpp *.hxx *.inc *.modulemap *.metal` fora de `Kit/Sources/CArgon2` e `Kit/Sources/CSecp256k1` falha; `.metal` só pela lista `metal_permitidos` do script (hoje vazia) |
| 27 | Build sem código de fora | no pbxproj, `PBXShellScriptBuildPhase\|shellScript\|PBXBuildRule\|OTHER_LDFLAGS\|OTHER_LIBTOOLFLAGS\|-Xlinker` falha, e framework, `.a`, `.dylib` ou `.tbd` fora de `sourceTree = SDKROOT` falha; no esquema, `ShellScriptAction\|<PreActions\|<PostActions`; no `project.yml`, `preBuildScripts\|postCompileScripts\|postBuildScripts\|buildRules\|buildToolPlugins\|preActions\|postActions\|OTHER_LDFLAGS` e dependência `framework:`, `carthage:` ou `bundle:`; no `Package.swift`, `linkerSettings\|unsafeFlags\|.plugin(\|plugins:\|.systemLibrary(` |
| 28 | Argumento de inicialização só em depuração | `ProcessInfo.processInfo.arguments\|ProcessInfo().arguments\|CommandLine.arguments\|unsafeArgv\|argc` em `App/EscaliburWallet`, `App/Shared` e `App/EscaliburWidgets` fora de `#if DEBUG` falha (o mesmo `awk` da regra do `DebugDemo`; `#else` e `#elseif` fecham o bloco) |
| 29 | `DEBUG` só na configuração Debug | no pbxproj, `DEBUG` em `SWIFT_ACTIVE_COMPILATION_CONDITIONS\|GCC_PREPROCESSOR_DEFINITIONS\|OTHER_SWIFT_FLAGS\|OTHER_CFLAGS` de outra configuração falha: com ele no Release, todo `#if DEBUG` iria para a loja e as regras 28 e a do `DebugDemo` não protegeriam nada |
| 30 | Workflows | em `.github/workflows/*.yml`, `uses:` que não seja `actions/` ou `github/` fixada por 40 hexadecimais, ou um workflow do próprio repositório, falha; `secrets.` fora de job com `environment: release`, e `secrets:` (passar segredo adiante), falham |

A regra 12 e a 15 são grep com falso positivo possível. Qualquer exceção precisa de uma linha justificando num arquivo de allowlist, revisado.

**Estado em 27/09/2026** (o que o `tools/verificar.sh` e o CI conferem de fato):
- Regra 3: feita. `./tools/verificar.sh --testes` roda `nm -u` nos objetos compilados de Chaves, Cadeias e Núcleo; o módulo de rede é o controle, e a checagem que não achasse símbolo de rede nele se declara cega. O CI roda com `--testes`.
- Regra 7: ATS padrão, sem exceção, conferido. `NSPinnedDomains` não é usado: o app fala direto com provedores públicos (82 hosts em `hosts.lock`), cujos certificados trocam sem aviso; fixar a chave derrubaria redes inteiras na troca. A defesa é a lista fechada de hosts em tempo de execução (`AllowedHosts`) e o consenso de duas fontes no que decide dinheiro.
- Regra 9: travados por digesto o argon2, a secp256k1, as listas de palavras, os hosts e o kit de recuperação (`*.lock` na raiz). As listas de contratos, programas, emissores e tokens são código Swift compilado (`TradeAllowlist`, `TokenRegistry`) e passam pela revisão do repositório, não por um `allowlists.lock` à parte.
- Regra 18: o conjunto de chaves do entitlement é conferido; no `.ipa` que vai para a Apple, o `release.yml` roda o `tools/conferir-entitlements.py`: os entitlements do repositório, só os que a assinatura de distribuição acrescenta, e `get-task-allow` falso.
- Regra 23: a exclusão do backup nos metadados é conferida no código; o autoteste em tempo de execução não existe.
- §8.5 (build reproduzível): Xcode fixado e conferido; `ZERO_AR_DATE`, mapeamento de caminhos e build duplo com atestação ainda não estão no `project.yml` nem no CI.
- CODEOWNERS existe; proteção de branch, tags assinadas e o primeiro run do CI dependem de o repositório ser publicado.

**CODEOWNERS** com 2 revisores obrigatórios para `Chaves/`, `Cadeias/`, `Nucleo/`, `*.lock`, `allowlists/`, `Info.plist` e `*.entitlements`. Proteção de branch, commits e tags assinados.

### 8.4 SECURITY.md

- Canal de contato: GitHub Private Vulnerability Reporting mais um e-mail com fingerprint PGP.
- Prazos: confirmação em 72 h, triagem em 7 dias, correção de crítico em 30, divulgação coordenada em 90.
- Porto seguro para pesquisa de boa-fé.
- Escopo: vazamento de segredo, contorno da validação de assinatura, formato do envelope, perda causada pelo relay, contorno do PIN ou da biometria.
- Fora do escopo: aparelho com jailbreak do próprio dono, coerção física, perfil de configuração instalado pelo usuário.
- Link para o modelo de ameaça, as chaves de assinatura das tags, e como conferir um build.

### 8.5 Builds reproduzíveis: o possível no iOS, dito com honestidade

- Xcode fixado em `.xcode-version`.
- `-fdebug-prefix-map=$(SRCROOT)=.` no C e `-debug-prefix-map` no Swift. `ZERO_AR_DATE=1`. Versão vem da tag, nunca da data.
- O CI compila duas vezes em runners limpos e compara os executáveis, com a assinatura removida (`codesign --remove-signature` numa cópia). Publica o SHA-256 e uma atestação de proveniência (GitHub Artifact Attestations).
- Limite declarado: o binário da App Store é recifrado pelo FairPlay. Comparar exige IPA decifrado (metodologia WalletScrutiny). O usuário comum não consegue conferir sozinho.

---

## 9. Checklist

**MUST (bloqueia o lançamento)**
1. Hierarquia K_dev, `rk.pin` com applicationPassword, K_bio com biometryCurrentSet, RK, DEK por carteira, tudo `WhenPasscodeSetThisDeviceOnly` e não sincronizável. **O spike do applicationPassword aprovado em iOS 17, 18 e 26 físicos; se reprovar, plano B.**
2. Nenhum verificador de PIN gravado. Proibidos `.userPresence`, `.devicePasscode`, `.biometryAny` (fora a `kand.qualquer` do modo reforçado, que só embrulha o miolo, §2.3).
3. Contador de tentativas com `SecItemUpdate`, falhando fechado, com o conserto de boot (A2, A3). A lista de bloqueio de PIN foi retirada por decisão do dono em 26/09/2026: qualquer PIN de 4 ou 6 dígitos vale (ver §2.7).
4. Autenticação nova por lote de assinatura; nada de RK ou seed em memória fora da assinatura; caminho síncrono; `verify` depois de assinar; HMAC e PBKDF2 em `SecureBytes`.
5. Intenções tipadas, sem assinatura às cegas. As recusas da 4.1, EIP-7702 incluída. Sem WalletConnect nem navegador de dapps.
6. Validação de swap (4.3) com allowlist compilada, ranking por `minOut`, approve exato, sem permit assinado nem EIP-2612 na v1 (a Uniswap usa a permissão exata do Permit2 na cadeia, 4.4).
7. `chainId` e passphrase de rede compilados, e checagem de `eth_chainId`. Tetos de taxa em todas as redes.
8. BTC confere a transação anterior. XRPL mostra `delivered_amount`, respeita `RequireDest` e reserva lida do servidor. Stellar respeita a SEP-29.
9. Detecção de envenenamento de endereço, filtro de valor zero e pó, e cópia de endereço só a partir de fontes confiáveis.
10. Módulos separados com a fronteira conferida por grep **e** por `nm`. `URLSession` efêmera sem `shared` e sem `AsyncImage`; sem redirecionamento; limites de tamanho; ATS padrão.
11. Relay com upstreams fixos e sem SSRF, sem log, endereço só no corpo, retirando cabeçalhos. O app não aceita nada da lista 5.4. **Na v1 não há relay:** o app fala direto com os provedores públicos, e o IP do dono chega a eles, o que a Política de privacidade e a tela de redes dizem.
12. Envelope: `OpeningContents` em `SecureBytes`, recusa de `slip39Share`, passphrase honrada, idioma validado, checksum, tamanho conferido antes de ler, limpeza de Inbox e tmp, mensagem única de erro, reabertura depois de exportar, fixtures nos dois sentidos com `decifrar.py`.
13. Plataforma: cobertura do snapshot, `sceneCaptureState`, teclados de terceiros bloqueados, traços dos campos, frase na área de transferência só depois do aviso e por 60 s, toda cópia com `localOnly` e expiração, nenhum SDK de terceiro, regras de log, sem WebView, sem push, exclusões de backup, limpeza do chaveiro na primeira execução.
14. Cadeia de suprimentos: libsecp256k1 v0.8.0, Keccak, RIPEMD-160 e bech32 vendorizados com locks e vetores; `verificar.sh` completo no CI; SECURITY.md; CODEOWNERS; tags assinadas; conta da ASC com chave de segurança de hardware.
15. Código do aparelho e SE disponíveis exigidos. Onboarding com backup conferido e com a verdade sobre `ThisDeviceOnly`.

**SHOULD**
- Senha alfanumérica no lugar do PIN, modo reforçado, carteira-cofre.
- Apagar após 10 erros, opcional.
- Simulação em 2 provedores: `eth_simulateV1`, `simulateTransaction`, `simulate` da XRPL.
- Consenso de 2+ provedores para nonce, saldo, taxa e recibo.
- `NSPinnedDomains` no relay com modo direto como alternativa.
- Descritores ERC-7730.
- Enhanced Security.
- Aviso de jailbreak.
- Camada segura contra captura nas telas de segredo (§7).
- Build duplo no CI com atestação.
- `ndata` do CSPRNG na assinatura.
- Registro de ordens com cancelamento real na cadeia.
- Logos embutidos, só PNG.
- Consulta por endereço, nunca por xpub.
- Nomes de token sanitizados e `Text(verbatim:)`.
- RPC privado na mainnet Ethereum.

**COULD**
- OHTTP (RFC 9458, com o HPKE do CryptoKit) e Private Access Tokens no relay.
- Perfil isca e modo viagem.
- `mlock` no `SecureBytes`, conferindo o retorno.
- Teclado de PIN embaralhado.
- Comandos de voz sem autoridade (seção 3).
- Lista de endereços de exchanges conhecidas para lembrar memo e tag.
- Entropia de dados físicos misturada por SHA-256 com o CSPRNG.
- Exportar envelope com isca.
- Aviso de conta Tron com permissões fora do padrão na importação.

---

## Risco residual aceito, e o que faria deixar de ser

1. **Exploit com execução de código no aparelho desbloqueado quebra o PIN de 6 dígitos em horas (6 a 11 no pior caso), e o de 4 dígitos em minutos (4 a 6 no pior caso).**
   - Aceito porque exige cadeia de exploit para o iOS atual e posse do aparelho desbloqueado.
   - Deixa de ser aceitável: com jailbreak público para a versão corrente do iOS, ou saldo acima do que o dono aceita perder. Nesses casos, modo reforçado ou senha longa passam a ser o padrão, e acima disso, carteira de hardware.
2. **Malware dentro do processo durante uma assinatura vê a seed, ou adultera a tela.**
   - Nenhuma carteira de software se defende disso.
   - Deixa de ser aceitável: quando o valor justifica carteira de hardware, e o suporte a ela é o conserto.
3. **Relay e provedores veem endereços, e o relay vê o IP.**
   - Aceito até existir OHTTP. Está escrito na tela de rede.
4. **Rota ruim dentro do slippage, com relay ou provedor comprometido.**
   - A perda tem teto na tolerância que o dono escolheu (padrão 0,5% em stablecoins, 1% no resto; acima de 3%, confirmação extra).
5. **Atualização maliciosa via conta da ASC comprometida.**
   - Só se mitiga: chave de hardware, 2 administradores, verificação de binário por terceiros.
   - Deixa de ser aceitável: se a conta tiver um administrador só.
6. **Captura de tela não é bloqueável, e as palavras reveladas são `String`.** A defesa é a janela curta.
7. **Biometria pode ser forçada.** O modo reforçado existe para isso: com ele, o rosto sozinho não abre nada. Os limites que ficam: quem executa código no aparelho testa o PIN mesmo sem o rosto (horas com 6 dígitos, minutos com 4), e com o rosto do dono uma vez abre a RK no mesmo tempo; quem tem o código do iPhone e o PIN leva tudo na hora em "Continuar normal" (o padrão, escolhido pelo dono), depois de 24 horas em "Esperar 24 horas", e em "Bloquear as carteiras" só destrói o cofre trocando o cadastro de rostos (o dono restaura pelas palavras); a Proteção de Aparelho Roubado com o atraso em "Sempre" iguala as três. Deixa de ser aceitável para saldo alto sem a senha alfanumérica no lugar do PIN (36^8 × 22 ms, cerca de 2 mil anos), ou se o dono reutiliza o PIN em outro lugar. Deixa de ser aceitável se a Apple mudar a `biometryCurrentSet` ou a `biometryAny` (testar num aparelho a cada versão grande do iOS, §2.6).
   - Fora dele, o PIN sozinho envia o saldo que o app mostra (o envio aceita Face ID ou PIN). O A1 protege a frase, não o saldo.
   - Quem tem o iPhone, o código do iPhone e o PIN leva a frase em 24 horas: cadastra o próprio rosto, religa o Face ID no app e espera. Aceito porque exige o código do iPhone, e a Proteção de Aparelho Roubado atrasa o cadastro. Deixa de ser aceitável com saldo relevante fora do alcance do Enviar (redes que o app não mostra, depósitos futuros): aí 72 horas, ou o modo reforçado.
   - Quem perde o Face ID de vez (sensor quebrado, cadastro trocado sem religar) só vê as palavras pelo papel ou pelo envelope que já tem.
8. **Carteiras somem se o dono tirar o código do iPhone, e não migram para um iPhone novo.**
   - É escolha deliberada: disponibilidade vem do backup do dono, não da nuvem.
   - Deixa de ser aceitável: se o onboarding não garantir o backup conferido.
9. **Coerção**: o código é aberto, e o agressor sabe que a isca existe. A defesa real é o saldo quente pequeno.

Arquivos citados:
- `escalibur/Escalibur/Vault/AppLock.swift` (A1–A3)
- `escalibur/Escalibur/Crypto/VaultFile.swift` (A4, A5)
- `escalibur/Escalibur/Crypto/KeyDerivation.swift` e `escalibur/Escalibur/Features/ShelfView.swift` (A6)
- `escalibur/Escalibur/App/PlatformGuards.swift` (A7)
- `escalibur/tools/verificar.sh` (base da 8.3)

**Fontes**
- [libsecp256k1 CHANGELOG](https://github.com/bitcoin-core/secp256k1/blob/master/CHANGELOG.md) · [Releases](https://github.com/bitcoin-core/secp256k1/releases)
- [0x Settler: AllowanceHolder, registro, Permit2](https://github.com/0xProject/0x-settler) · [0x FAQ](https://docs.0x.org/docs/introduction/faq)
- [1inch Router V6 no Etherscan](https://etherscan.io/address/0x111111125421ca6dc452d289314280a0f8842a65) · [1inch LOP](https://github.com/1inch/limit-order-protocol)
- [LI.FI: endereços de contratos](https://docs.li.fi/introduction/lifi-architecture/smart-contract-addresses) · [Registro ERC-7730](https://github.com/ethereum/clear-signing-erc7730-registry/pull/2955)
- [Jupiter instruction-parser](https://github.com/jup-ag/instruction-parser)
- [XRPL: reservas menores](https://xrpl.org/blog/2024/lower-reserves-are-in-effect) · [rippled 2.4.0 (simulate)](https://xrpl.org/blog/2025/rippled-2.4.0)
- [eth_simulateV1 (Alchemy)](https://www.alchemy.com/docs/chains/ethereum/ethereum-api-endpoints/eth-simulate-v-1) · [notas do eth_simulate](https://ethereum.github.io/execution-apis/docs/ethsimulatev1-notes/)
- [DTS sobre applicationPassword no SE](https://developer.apple.com/forums/thread/67881) · [SecAccessControlCreateFlags](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags)
- [Entitlements do Enhanced Security (DTS)](https://developer.apple.com/forums/thread/803529) · [Guardsquare sobre Xcode 26](https://www.guardsquare.com/blog/xcode-26-enhanced-security-for-ios-apps) · [Apple MIE](https://security.apple.com/blog/memory-integrity-enforcement/)
- [sceneCaptureState](https://developer.apple.com/documentation/uikit/uitraitcollection/scenecapturestate)
- [Altman sobre autenticação por voz (PYMNTS)](https://www.pymnts.com/news/2025/sam-altman-says-ai-has-defeated-bank-voice-id-protections/)
- [SpeechAnalyzer (Picovoice, 2026)](https://picovoice.ai/blog/ios-speech-recognition/)