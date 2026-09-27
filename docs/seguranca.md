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
- Onde: `/Users/thomazjr/projects/escalibur/Escalibur/Vault/AppLock.swift` grava `salt || Argon2id(PIN, m=64 MiB, t=3, p=1)` num item de chaveiro sem ACL.
- Como se explora:
  1. O ladrão vê o código do iPhone por cima do ombro e leva o aparelho. Esse é o golpe dominante de roubo de iPhone hoje.
  2. Com ferramenta forense ou exploit para aquela versão do iOS, extrai o item `com.thomazjr.escalibur.applock/pin` do aparelho desbloqueado.
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
- Onde: `VaultFile.open` chama `VaultContents.decode`, que usa `String(decoding:)` para a frase e para a 25ª palavra (`/Users/thomazjr/projects/escalibur/Escalibur/Crypto/VaultFile.swift`, linhas 86–101).
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
  - O app pede PIN ou biometria ao abrir. Trava ao ir para segundo plano (tolerância de no máximo 60 s) e trava na hora em `UIApplication.protectedDataWillBecomeUnavailableNotification`.
  - A biometria usa `.biometryCurrentSet`, **nunca** `.userPresence` nem `.devicePasscode`. O código do iPhone não abre nada aqui.
  - Cadastrar um rosto novo destrói o slot biométrico em vez de abri-lo.
  - A escada de atraso do PIN exige cerca de 340 anos para varrer 10^6 pela interface.
  - Revelar ou exportar a frase exige PIN.
- O que sobra: nada, sem o PIN, sem o rosto do dono e sem exploit.

**T3. Execução de código no aparelho desbloqueado (jailbreak, exploit forense, malware com privilégio)**
- Defesa:
  - Nenhum byte gravado abre fora deste Secure Enclave.
  - O PIN não tem verificador extraível, então o ataque fica preso ao próprio aparelho: 1,5 dia em média, 3 dias no pior caso.
  - A biometria continua exigindo o rosto, porque a decisão acontece no SEP.
  - As opções de valor alto (seção 2.6) sobem o custo para milhares de anos.
  - A seed só existe em memória durante a assinatura.
- O que sobra: o PIN de 6 dígitos cai em dias. Malware dentro do processo durante uma assinatura vê a seed. A interface pode ser adulterada para mostrar A e assinar B. Isso está aceito, com os números, no fim do relatório.

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
  - `verificar.sh` roda no CI e bloqueia merge.
  - Duas pessoas revisam chaves, cadeias e allowlists. Tags são assinadas.
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
PIN ─Argon2id─► AP ─(applicationPassword)─► item rk.pin = ECIES(K_dev.pub, ChaChaPoly(K_pin, RK)) ─SE(K_dev)─► ─K_pin─► RK
                AP ─HKDF(salt, "escalibur-wallet/v1/rk.pin")─► K_pin
biometria (decisão no SEP) ─────────────────► item rk.bio = ECIES(K_bio.pub, RK) ─SE(K_bio)─► RK
RK ─HKDF "escalibur-wallet/v1/index"──────────► K_idx ─► metadados.bin (xpubs, endereços, nomes, catálogo)
RK ─HKDF(salt_w, "…/v1/dek" ‖ walletID)───────► KEK_w ─► DEK_w ─HKDF(salt_s,"…/v1/seed")─► registro da seed
```

| Chave | O que é | Onde vive |
|---|---|---|
| K_dev | P-256 no SE, flags `[.privateKeyUsage]` | Secure Enclave |
| K_bio | P-256 no SE, flags `[.privateKeyUsage, .biometryCurrentSet]` | Secure Enclave; só existe com biometria ligada |
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
- `kSecPrivateKeyAttrs` com `kSecAttrIsPermanent: true`, `kSecAttrApplicationTag: "com.thomazjr.escalibur.wallet.kdev"` (ou `.kbio`) e `kSecAttrAccessControl: SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, <flags>, nil)`.

Itens de chaveiro (`kSecClassGenericPassword`):
- Atributos comuns: `kSecAttrService "com.thomazjr.escalibur.wallet"`, `kSecAttrSynchronizable: false`, `kSecUseDataProtectionKeychain: true`, e o access group do próprio app. Nenhum grupo compartilhado com extensões.
- `rk.pin`: `kSecAttrAccessControl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.applicationPassword], nil)`. Tanto gravar quanto ler usam `kSecUseAuthenticationContext` com um `LAContext` que recebeu `setCredential(AP, type: .applicationPassword)` e `interactionNotAllowed = true`.
- `rk.bio`, `seed.<uuid>` (DEK embrulhada mais o registro), `pin.kdf` (salt e parâmetros, não secretos), `pin.tentativas` e `bio.estado`: todos com `kSecAttrAccessible: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`.
- Nunca use `kSecAttrAccessible` e `kSecAttrAccessControl` no mesmo item. A classe de proteção vai dentro do `SecAccessControl`.
- **Proibido no projeto inteiro**: `.userPresence`, `.devicePasscode`, `.biometryAny`, `.or` com código do aparelho, `AfterFirstUnlock` e `Always`. O motivo: quem viu o código do iPhone passa por `.userPresence`, e com `.biometryAny` o ladrão cadastra o próprio rosto.

Arquivos:
- `Library/Application Support/Carteira/metadados.bin` com `NSFileProtectionComplete` (entitlement `com.apple.developer.default-data-protection`, como no Escalibur).
- `isExcludedFromBackup = true`, conferido com `resourceValues` como o `VaultStore` já faz.

Pré-condições para criar ou importar carteira:
- `LAContext().canEvaluatePolicy(.deviceOwnerAuthentication)` verdadeiro, ou seja, o aparelho tem código.
- `SecureEnclave.isAvailable`.

Primeira execução depois da instalação:
- O item de chaveiro sobrevive à desinstalação no iOS. Se o marcador em `UserDefaults` não existir e houver itens no chaveiro, o app apaga tudo, as chaves do SE primeiro.
- Com isso, "apagar o app apaga as carteiras" passa a ser verdade, e reinstalar para zerar o contador de tentativas também destrói o que se queria atacar.

Consequência que vai por escrito no onboarding:
- Tirar o código do iPhone destrói as carteiras deste aparelho, porque os itens `WhenPasscodeSet` são apagados.
- Trocar de iPhone exige importar de novo, pelas palavras ou pelo envelope.
- Isso é deliberado: a portabilidade é o backup do dono, não a nuvem.

### 2.4 O PIN

- A entrada vem de um teclado numérico do próprio app e vai direto para `SecureBytes`. O PIN nunca vira `String`.
- **Lista de bloqueio** na ordem de mil a três mil PINs: repetições, sequências, datas DDMMAA. É o mesmo tipo de lista que o iOS usa para o código do aparelho, estudada por Markert et al. (IEEE S&P 2020). Com poucas tentativas permitidas, é a lista que decide o jogo.
- **AP = Argon2id(PIN, salt 16 bytes do CSPRNG, m=256 MiB, p=2, t calibrado entre 2 e 4 para dar até cerca de 0,8 s).**
  - Os parâmetros ficam gravados em `pin.kdf` e são lidos de lá, o que permite migrar depois.
  - O Argon2 existe mesmo com o chaveiro fazendo a checagem porque é ele que o atacante no aparelho paga a cada chute. Sem ele, cada chute custa milissegundos e 10^6 PINs saem em horas.
- **Não existe digest de PIN em lugar nenhum.** O PIN errado é recusado pelo chaveiro e, de novo, pela camada interna. Não há comparação no código do app, então não há oráculo de tempo.
- **Camada interna (auditoria 1).** Dentro do embrulho do SE, a RK vai cifrada com ChaChaPoly sob K_pin = HKDF(AP, salt). Isso torna o desenho independente do resultado do spike abaixo: se a senha de aplicativo for só uma regra de acesso, quem copiar o item e conseguir usar o SE deste aparelho ainda precisa do PIN, e cada chute custa um Argon2id de 256 MiB. Falha de autenticação na camada interna conta como PIN errado.
- **O simulador não aplica a senha de aplicativo.** `LAContext.setCredential(_, type: .applicationPassword)` devolve `false` no simulador, e o item é gravado sem ela. Lá, só a camada interna recusa o PIN errado; o teste de interface de ponta a ponta confere isso a cada rodada. No aparelho, `false` é erro e o cadastro para.
- **Troca de PIN atômica:**
  1. Grava `rk.pin.novo` com AP e salt novos, e lê de volta para conferir.
  2. O ponto sem volta é apagar `rk.pin`. Antes dele, qualquer falha apaga o pendente e o PIN antigo continua o único.
  3. Depois dele, a troca está feita: o pendente abre com o PIN novo. A promoção a principal (gravar `rk.pin` com o PIN novo, conferir, apagar o pendente) é tentada na hora e, se falhar, concluída no próximo desbloqueio.
  - Com os dois slots presentes (crash entre os passos 1 e 2), o desbloqueio tenta os dois na mesma tentativa. O antigo abrindo desfaz a troca; o novo abrindo a conclui.
  - Uma troca nova é recusada enquanto houver uma interrompida: o desbloqueio resolve primeiro.
- **Cadastro só com resposta definitiva.** O chaveiro que não consegue responder (`probe` = desconhecido) nunca vira "não existe": `isSetUp` responde sim e o cadastro recusa. `createKey(.device)` nunca substitui a K_dev em silêncio. Sobras de um cadastro interrompido só são apagadas quando nenhum slot da RK existe.
- **Contador de tentativas.** O prazo usa só o relógio monotônico (`CLOCK_MONOTONIC_RAW`, que conta o tempo dormindo) e a identidade do boot (`kern.bootsessionuuid`). Mudar o relógio de parede não encurta nem estica a espera. Depois de reiniciar, a espera recomeça cheia; ler o contador nunca grava, quem regrava é a abertura do app e a volta ao primeiro plano. Face ID aceito zera o contador, como no iPhone.
- **Face ID recusado não apaga o atalho.** Só o cadastro de rostos diferente do gravado ao ligar, ou a K_bio que o SEP já destruiu, apagam `rk.bio`.

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
- **Desligar**: `SecItemDelete` de `rk.bio` e de K_bio. O slot do PIN não é tocado, então ligar e desligar a biometria nunca enfraquece o PIN.
- **O cadastro de rostos mudou**:
  - O SEP invalida K_bio e a decifragem falha.
  - O app compara o hash, apaga o slot e diz: "O Face ID deste iPhone mudou desde que foi ligado aqui. Entre com o PIN; depois você pode religar."
  - Religar exige o PIN. O ladrão que cadastra o próprio rosto só destrói o slot.
- **`LAContext` de cada operação**:
  - `localizedReason` descreve a ação ("Assinar envio de 0,25 ETH na Base").
  - `touchIDAuthenticationAllowableReuseDuration = 0`.
  - O `Bool` do `evaluatePolicy` **nunca** autoriza nada. Quem autoriza é o SE liberar o material de chave. O AppLock do Escalibur já acertou isso.
- Recomende ao dono ligar a Proteção de Aparelho Roubado (iOS 17.3+). Ela atrasa o cadastro de rosto novo longe de locais conhecidos.

### 2.6 Para quem guarda valor alto (SHOULD)

- **Senha alfanumérica no lugar do PIN**. Oito caracteres sorteados de [a-z0-9] levam cerca de 24 mil anos para varrer no aparelho.
- **Modo reforçado**, disponível só com backup conferido:
  - Um item `rk.and = ECIES_{K_bio}(ECIES_{K_dev}(RK))` protegido por applicationPassword(AP). Os slots só-PIN e só-biometria são apagados.
  - Tudo passa a exigir PIN **e** rosto.
  - Preço declarado: se o cadastro de rostos mudar, a restauração é pelas palavras.
- **Carteira-cofre**: a DEK daquela carteira é embrulhada por `HKDF(RK ‖ Argon2id(senha da carteira, 512 MiB, t=4, p=4))`. Quebrar o PIN no aparelho não a abre.

### 2.7 Atraso progressivo e "apagar após N erros"

- **Escada de atraso** (pode ser a do Escalibur):
  - Erros 1 e 2: 0 s. Erro 3: 5 s. Erro 4: 15 s. Erro 5: 60 s. Erro 6: 5 min. Erro 7: 15 min. Erro 8: 1 h. Do 9 em diante: 3 h.
  - O incremento é gravado com `SecItemUpdate` antes da avaliação. Se a gravação falhar, a tentativa não é avaliada.
  - Relógio de parede e relógio monotônico, com o conserto de boot da A3.
- **Apagar após 10**:
  - Opcional. Só pode ser ligado depois que o backup de todas as carteiras foi conferido.
  - Antes da 10ª tentativa, o app avisa na tela.
  - Apagar é destruição criptográfica: `SecItemDelete` de K_dev, K_bio e dos itens `rk.*` primeiro, que em milissegundos tornam inúteis todos os blobs, e depois o resto.
  - Contra quem tenta pela interface, a chance de acerto é de 1 em 100 mil para um PIN sorteado. Contra quem tem execução de código, é inútil, e isso vai escrito.
- **Sem lista de PINs fáceis** (decisão do dono, 2026-09-26): qualquer combinação de 6 dígitos vale, inclusive 111111 e 123456. O app só confere a forma. O risco fica com o dono: um PIN óbvio é o primeiro palpite de quem pega o iPhone, e contra isso sobram a escada de atraso e o apagar após erros, se ligado.

### 2.8 Força bruta no PIN: o Secure Enclave resolve?

| Atacante | Custo para varrer 10^6 PINs |
|---|---|
| Extraiu os dados e não tem o aparelho | impossível: K_dev nunca sai do SE, e nenhum blob abre em outro lugar |
| Tem o aparelho desbloqueado, tenta pela interface | ~340 anos pela escada (~170 em média); com apagar-após-10, 1 chance em 10^5 |
| Tem execução de código no aparelho desbloqueado | 10^6 × 0,8 s ÷ ~3 em paralelo ≈ **3 dias no pior caso, 1,5 em média** |
| O mesmo, com senha alfanumérica sorteada de 8 caracteres | ~24 mil anos |
| O mesmo, com modo reforçado | não há força bruta: precisa do rosto, e a decisão é no SEP |

A resposta honesta: **o SE converte ataque offline em ataque preso ao aparelho, mas não limita as tentativas de segredos do app.**
- O único limite por hardware que existe é o do código do iPhone (80 ms mais atrasos crescentes no SEP).
- Para usar esse limite, o item teria de ser `.devicePasscode`, e quem viu o código do iPhone passa por ele.
- Por isso o PIN de 6 dígitos é defesa contra T2, não contra T3.

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
- Nada de hex, `description` ou `Data` de segredo em código de produção.
- Nada de xprv em cache: só xpub e chaves públicas.

### 2.10 Quem exige o quê

| Ação | Exige |
|---|---|
| Abrir o app e ver saldos | PIN ou biometria |
| Qualquer assinatura (envio, swap, approve, ordem, cancelamento) | Autenticação nova, uma por lote revisado numa única tela. Modo reforçado: PIN e biometria |
| Revelar palavras, exportar envelope, apagar carteira | PIN (e biometria, se estiver ligada) |
| Ligar biometria, trocar PIN, mudar tempo de bloqueio, desligar reforçado ou apagar-após-N | PIN |
| Desligar biometria | sessão aberta, porque só reduz superfície |

---

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
   - LI.FI `swapTokensGeneric(..., receiver, minAmount, swapData[])`: `receiver == self`, primeiro `sendingAssetId` e `fromAmount` e último `receivingAssetId` batendo. Pontes ficam fora da v1.
   - `minOut ≥ cotação × (1 − slippage)` e maior que zero. `deadline ≤ agora + 20 min`. Taxa de integrador e destinatário da taxa iguais aos compilados (zero, ou a nossa).
6. **O ranking entre agregadores usa o `minOut` decodificado**, que é garantido na cadeia, e não o `expectedOut` cotado. Inflar o `expectedOut` é justamente como um provedor malicioso venceria a disputa.
7. Checagem de sanidade contra oráculo: pior que o preço médio da CoinGecko em mais de 2%, avisa; em mais de 5%, bloqueia (desbloquear exige PIN). Oráculo e cotação chegam pelo mesmo relay, então isso é sanidade, não garantia.
8. Gás:
   - `maxFeePerGas ≤ 2 × baseFee + prioridade`, com baseFee e prioridade pela mediana de 2 provedores e teto por chain.
   - `gasLimit ≤ estimativa × 1,3` (na v1, a menor de 2 estimativas × 1,2), também com teto.
   - Taxa acima de US$ 20 ou de 3% do valor pede confirmação extra.
   - Na mainnet Ethereum, envio por RPC privado (Flashbots Protect ou MEV Blocker) para não ser sanduichado dentro do slippage.

### 4.4 Aprovações, Permit2, EIP-2612

- Approve no **valor exato**, e só para spenders da lista.
- Tokens do tipo USDT exigem `approve(0)` antes de um novo valor. São duas transações, e as duas aparecem na tela.
- Aprovação infinita nunca é padrão. É uma opção por token, com PIN e aviso.
- Uma tela lista as aprovações vigentes (`allowance(owner, spender)` para cada spender da lista) e permite revogar.
- **A v1 não assina Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) nem EIP-2612.** Assinatura off-chain de permit é o principal vetor de dreno. Os fluxos AllowanceHolder e approve exato cobrem os três agregadores.
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
- **Stellar**: pela SEP-29, a entrada de dados `config.memo_required` igual a `"1"` na conta de destino torna o memo obrigatório. Endereços muxados `M…` carregam o ID. Destino inexistente pede `CreateAccount` com pelo menos 1 XLM.
- **EVM**: destino com código (`eth_getCode` diferente de `0x`) gera aviso. Destino igual ao contrato do próprio token, ou a um router da lista, bloqueia.
- **Solana**: destino fora da curva (PDA) ou uma conta de token no lugar de uma carteira gera aviso ou bloqueio.
- **Tron**: `fee_limit` com teto. USDT TRC-20 é `TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t`.

### 4.9 Simulação: a segunda opinião

- **EVM**: `eth_simulateV1` com `validation: true` e `traceTransfers: true` (geth 1.14.9+, suportado por Alchemy, QuickNode e Chainstack), em 2 provedores.
  - Resultado esperado: sai exatamente amountIn do token vendido (mais gás), entra pelo menos minOut do token comprado.
  - Nenhum `Approval` ou `ApprovalForAll` do usuário além do esperado.
  - Provedores divergindo, ou revert, bloqueiam.
- **Solana**: `simulateTransaction` com `accounts` das contas de token do usuário.
- **XRPL**: `simulate` (rippled 2.4.0+).
- **Stellar clássica**: só validação local.
- Sem simulação disponível, envio simples continua funcionando, mas swap, approve e ordem ficam bloqueados.

### 4.10 Envenenamento de endereço e área de transferência

- **No envio**, o destino é comparado com o catálogo, com todo o histórico e com os próprios endereços.
  - Se não for idêntico a nenhum, mas tiver os mesmos 4 primeiros e 4 últimos caracteres de algum (depois do prefixo), o aviso é bloqueante.
  - O aviso mostra os dois endereços lado a lado, com as diferenças destacadas.
- **No histórico**:
  - Ocultar por padrão as transferências de valor zero, o pó e os tokens fora da lista.
  - Um `Transfer` com `from == self` numa transação cujo `tx.from` não é self é marcado como falsificado.
  - Nunca oferecer "copiar endereço" a partir de uma transação recebida de um desconhecido.
- **Primeiro envio para um endereço**: aviso de que nunca houve envio para ali.
- **Tela de confirmação**: o endereço aparece inteiro, em grupos de 4, com EIP-55. Endereço com maiúsculas e minúsculas misturadas e checksum inválido é recusado.
- **Área de transferência**: no iOS, nenhum app lê a área de transferência em segundo plano. O sequestro realista acontece no computador de origem, e o Universal Clipboard traz o endereço trocado. Defesa:
  - Colar por `PasteButton`.
  - Depois de colar, pedir ao dono que confira os 6 primeiros e os 6 últimos caracteres com a fonte.
  - Preferir QR e o catálogo.

### 4.11 Identificadores de rede, compilados e conferidos

- EVM: Ethereum 1, Arbitrum 42161, Base 8453, OP 10, Polygon 137, BNB 56, Avalanche 43114, Plasma 9745, X Layer 196, Linea 59144, Unichain 130, Sonic 146, Celo 42220.
- A passphrase da Stellar.
- Tudo num arquivo travado por lock, e as mudanças passam pelo CODEOWNERS.

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
- Imagem fora de PNG ou JPEG base, ou maior que 64 KB. Logos dos tokens listados vão embutidos no app, e SVG, WebP e GIF são recusados, porque decodificação de imagem é superfície de exploit dentro do processo que assina.
- Preço: serve para exibir e para checagem de sanidade, nunca sozinho para calcular `minOut`.

### 5.5 Consenso entre provedores

- **Nonce e sequence**: 2 ou mais provedores concordando. Se divergirem, usa o registro local de envios; se ainda assim não fechar, bloqueia.
- **Saldo**: mostra quando 2 concordam; se não, mostra "divergente" com os dois valores.
- **Taxa**: mediana, com teto.
- **Recebimento "confirmado"**: 2 provedores mais N confirmações. Recibo falso é golpe comum em negociação P2P.
- **Tabelas de lookup da Solana e registro do Settler da 0x**: 2 provedores.
- **Privacidade**: consulta endereço por endereço, **nunca xpub** para provedor. Mandar a xpub entrega a carteira inteira.

### 5.6 O que nunca vai para log, nem no app nem no relay

Palavras, entropia, chaves privadas, xpub, PIN, senhas, AP, RK, DEK, endereços, valores, saldos, hashes de transação, calldata, assinaturas, IP, nomes de arquivos de envelope e respostas de API.

---

## 6. Envelope `.esclbr`

- **Tipo de arquivo**:
  - O Escalibur declara `UTExportedTypeDeclarations` para `com.thomazjr.escalibur.envelope` (extensão `esclbr`, conforme `public.data`). Hoje não declara.
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
  - "Ver palavras" exige PIN e segue a sessão de revelação do Escalibur: 3 palavras por vez, 60 s, fecha ao sair do primeiro plano, com proteção de captura, sem seleção e sem copiar.
- **Exportar**:
  - Exige PIN, mais biometria se estiver ligada.
  - Senha padrão **gerada**: 6 palavras BIP-39 do CSPRNG, 66 bits. Com os parâmetros de referência, isso custa cerca de 97 mil anos a um Estado e 9,7 milhões a crime organizado. Com 5 palavras seriam 48 anos contra um Estado.
  - Senha escolhida pelo dono: mostra a tabela de custo. Recusa se for igual ao PIN ou só dígitos com até 8 caracteres.
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
  - COULD: renderizar as palavras dentro da camada de um `UITextField` com `isSecureTextEntry`, que sai em branco na captura. Depende da hierarquia interna do UIKit; se não encontrar a camada, cai para o comportamento atual.
- **Teclados**:
  - `application(_:shouldAllowExtensionPointIdentifier:)` devolve falso para `.keyboard`.
  - Campos de frase e senha com `autocorrectionType = .no`, `spellCheckingType = .no`, `smartInsertDeleteType = .no`, `inlinePredictionType = .no` (iOS 17), `writingToolsBehavior = .none` (iOS 18), `isSecureTextEntry = true`, `textContentType = nil`.
  - Para a frase, o preferível é um seletor de palavras BIP-39 do próprio app: sem teclado do sistema, sem ditado, sem aprendizado de vocabulário.
  - PIN pelo teclado próprio.
- **Área de transferência**:
  - A frase nunca vai para a área de transferência: sem botão de copiar, com `.textSelection(.disabled)`.
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
- **Sem WebView, sem push, sem Siri, Spotlight, App Intents, widgets ou Handoff na v1.** Notificações só locais, sem valor e sem endereço.
- **Deep links e QR** (BIP-21, EIP-681):
  - Só pré-preenchem, com o selo "veio de link externo", parsing estrito e tamanho limitado.
  - Um QR com frase na tela de envio é recusado com aviso.
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
| 13 | Chaveiro num ponto só | `SecItemAdd\|SecItemUpdate\|SecKeyCreateRandomKey` só em `Chaves/Chaveiro.swift` e `Chaves/Enclave.swift`; ali, `AfterFirstUnlock\|AccessibleAlways\|kSecAttrAccessibleWhenUnlocked\b\|SynchronizableAny\|\.userPresence\|\.devicePasscode\|\.biometryAny\|\.or\b` falha, e `ThisDeviceOnly` precisa aparecer |
| 14 | Booleano não autoriza | `evaluatePolicy` fora do arquivo de disponibilidade da interface falha |
| 15 | Comparação de segredo | `(digest\|tag\|mac\|hmac\|secret\|key)\w* *[!=]=` em Chaves/ falha; o caminho é `TempoConstante.igual` |
| 16 | Área de transferência | `UIPasteboard` fora de `Plataforma/Transferencia.swift` falha; esse arquivo precisa conter `.localOnly` e `.expirationDate`; `UIPasteboard.general.string *=` falha |
| 17 | Defesas de plataforma presentes | `shouldAllowExtensionPointIdentifier` com `.keyboard`, cobertura em `willResignActiveNotification`, `sceneCaptureState` e `NSFileProtectionComplete` no entitlement |
| 18 | Entitlements | conjunto exato de chaves; `aps-environment`, `icloud-*`, `ubiquity-*` e access groups de outros falham; no build arquivado, `codesign -d --entitlements :-` sem `get-task-allow` |
| 19 | Permissões no Info.plist | lista fechada (FaceID, Câmera; Microfone e Fala só se o recurso de voz existir); `NSUserTracking\|NSLocation\|NSContacts\|NSLocalNetwork\|NSBluetooth` falha |
| 20 | Sem SDK de terceiros | `Firebase\|Crashlytics\|Sentry\|Bugsnag\|Amplitude\|Mixpanel\|Segment\|AppsFlyer\|Adjust\|Branch\|OneSignal\|Datadog\|NewRelic\|Instabug\|FBSDK\|GoogleMobileAds\|PostHog` falha |
| 21 | Sem WebView | `WKWebView\|SFSafariViewController\|UIWebView\|ASWebAuthenticationSession` falha |
| 22 | UserDefaults | `UserDefaults\|@AppStorage` só com as chaves de `Ajustes/Chaves.swift` |
| 23 | Backup | o store cria o diretório com `isExcludedFromBackup = true`, e o autoteste confere via `resourceValues` |
| 24 | Determinismo | `__DATE__\|__TIME__\|__TIMESTAMP__` no C falha; `xcodebuild -version` igual a `.xcode-version` |
| 25 | Vetores | testes unitários de BIP-39/32/84, SLIP-10, EIP-55/155/712, Keccak, RIPEMD, bech32, XRPL, strkey e Solana, mais os fixtures de envelope nos dois sentidos com `decifrar.py` |

A regra 12 e a 15 são grep com falso positivo possível. Qualquer exceção precisa de uma linha justificando num arquivo de allowlist, revisado.

**Estado em 27/09/2026** (o que o `tools/verificar.sh` e o CI conferem de fato):
- Regra 3: feita. `./tools/verificar.sh --testes` roda `nm -u` nos objetos compilados de Chaves, Cadeias e Núcleo; o módulo de rede é o controle, e a checagem que não achasse símbolo de rede nele se declara cega. O CI roda com `--testes`.
- Regra 7: ATS padrão, sem exceção, conferido. `NSPinnedDomains` não é usado: o app fala direto com provedores públicos (82 hosts em `hosts.lock`), cujos certificados trocam sem aviso; fixar a chave derrubaria redes inteiras na troca. A defesa é a lista fechada de hosts em tempo de execução (`AllowedHosts`) e o consenso de duas fontes no que decide dinheiro.
- Regra 9: travados por digesto o argon2, a secp256k1, as listas de palavras, os hosts e o kit de recuperação (`*.lock` na raiz). As listas de contratos, programas, emissores e tokens são código Swift compilado (`TradeAllowlist`, `TokenRegistry`) e passam pela revisão do repositório, não por um `allowlists.lock` à parte.
- Regra 18: o conjunto de chaves do entitlement é conferido; `get-task-allow` no build arquivado fica para o pipeline de lançamento, que ainda não existe.
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
2. Nenhum verificador de PIN gravado. Proibidos `.userPresence`, `.devicePasscode`, `.biometryAny`.
3. Contador de tentativas com `SecItemUpdate`, falhando fechado, com o conserto de boot (A2, A3). A lista de bloqueio de PIN foi retirada por decisão do dono em 26/09/2026: qualquer PIN de 6 dígitos vale (ver §2.7).
4. Autenticação nova por lote de assinatura; nada de RK ou seed em memória fora da assinatura; caminho síncrono; `verify` depois de assinar; HMAC e PBKDF2 em `SecureBytes`.
5. Intenções tipadas, sem assinatura às cegas. As recusas da 4.1, EIP-7702 incluída. Sem WalletConnect nem navegador de dapps.
6. Validação de swap (4.3) com allowlist compilada, ranking por `minOut`, approve exato, sem Permit2 nem EIP-2612 na v1.
7. `chainId` e passphrase de rede compilados, e checagem de `eth_chainId`. Tetos de taxa em todas as redes.
8. BTC confere a transação anterior. XRPL mostra `delivered_amount`, respeita `RequireDest` e reserva lida do servidor. Stellar respeita a SEP-29.
9. Detecção de envenenamento de endereço, filtro de valor zero e pó, e cópia de endereço só a partir de fontes confiáveis.
10. Módulos separados com a fronteira conferida por grep **e** por `nm`. `URLSession` efêmera sem `shared` e sem `AsyncImage`; sem redirecionamento; limites de tamanho; ATS padrão.
11. Relay com upstreams fixos e sem SSRF, sem log, endereço só no corpo, retirando cabeçalhos. O app não aceita nada da lista 5.4. **Na v1 não há relay:** o app fala direto com os provedores públicos, e o IP do dono chega a eles, o que a Política de privacidade e a tela de redes dizem.
12. Envelope: `OpeningContents` em `SecureBytes`, recusa de `slip39Share`, passphrase honrada, idioma validado, checksum, tamanho conferido antes de ler, limpeza de Inbox e tmp, mensagem única de erro, reabertura depois de exportar, fixtures nos dois sentidos com `decifrar.py`.
13. Plataforma: cobertura do snapshot, `sceneCaptureState`, teclados de terceiros bloqueados, traços dos campos, frase nunca na área de transferência, endereços com `localOnly` e expiração, nenhum SDK de terceiro, regras de log, sem WebView, sem push, exclusões de backup, limpeza do chaveiro na primeira execução.
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
- Truque da camada segura contra captura.
- `mlock` no `SecureBytes`, conferindo o retorno.
- Teclado de PIN embaralhado.
- Comandos de voz sem autoridade (seção 3).
- Lista de endereços de exchanges conhecidas para lembrar memo e tag.
- Entropia de dados físicos misturada por SHA-256 com o CSPRNG.
- Exportar envelope com isca.
- Aviso de conta Tron com permissões fora do padrão na importação.

---

## Risco residual aceito, e o que faria deixar de ser

1. **Exploit com execução de código no aparelho desbloqueado quebra o PIN de 6 dígitos em até 3 dias.**
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
7. **Biometria pode ser forçada.** O modo reforçado existe para isso.
8. **Carteiras somem se o dono tirar o código do iPhone, e não migram para um iPhone novo.**
   - É escolha deliberada: disponibilidade vem do backup do dono, não da nuvem.
   - Deixa de ser aceitável: se o onboarding não garantir o backup conferido.
9. **Coerção**: o código é aberto, e o agressor sabe que a isca existe. A defesa real é o saldo quente pequeno.

Arquivos citados:
- `/Users/thomazjr/projects/escalibur/Escalibur/Vault/AppLock.swift` (A1–A3)
- `/Users/thomazjr/projects/escalibur/Escalibur/Crypto/VaultFile.swift` (A4, A5)
- `/Users/thomazjr/projects/escalibur/Escalibur/Crypto/KeyDerivation.swift` e `/Users/thomazjr/projects/escalibur/Escalibur/Features/ShelfView.swift` (A6)
- `/Users/thomazjr/projects/escalibur/Escalibur/App/PlatformGuards.swift` (A7)
- `/Users/thomazjr/projects/escalibur/tools/verificar.sh` (base da 8.3)

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