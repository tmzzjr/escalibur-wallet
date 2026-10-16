#!/bin/bash
# Verificacoes que valem por afirmacao publica sobre a Escalibur Wallet.
#
# Cada uma existe porque a alternativa e o app prometer num texto algo que ninguem
# confere. Aqui qualquer pessoa confere, com uma linha de shell:
#
#     ./tools/verificar.sh            as verificacoes estaticas
#     ./tools/verificar.sh --testes   e tambem os testes do nucleo (vetores oficiais)
#
# O desenho de cada regra esta em docs/seguranca.md §8.3.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

falhas=0
aviso() { echo "  ✗ $1"; falhas=$((falhas + 1)); }
ok() { echo "  ✓ $1"; }
secao() { echo; echo "$1"; }

CORE=Kit/Sources/EscaliburCore
CHAINS=Kit/Sources/EscaliburChains
KEYS=Kit/Sources/EscaliburKeys
NET=Kit/Sources/EscaliburNetwork
ENG=Kit/Sources/EscaliburEngines
APP=App/EscaliburWallet

swift_em() { find "$@" -name "*.swift" 2>/dev/null; }
# As regras de codigo leem so .swift. Estas sao as outras extensoes que o Xcode ou o
# SwiftPM compilam ou incluem; fora do C vendorizado (secao "fontes e build"), nenhuma
# pode existir.
nao_swift=( -iname "*.m" -o -iname "*.mm" -o -iname "*.c" -o -iname "*.cc" -o -iname "*.cpp" -o -iname "*.cxx" -o -iname "*.c++"
    -o -iname "*.s" -o -iname "*.asm" -o -iname "*.h" -o -iname "*.hh" -o -iname "*.hpp" -o -iname "*.hxx" -o -iname "*.inc"
    -o -iname "*.modulemap" -o -iname "*.metal" )
# Procura um padrao em codigo, ignorando linhas que sao so comentario (a regra vale
# para o que compila, nao para a explicacao de por que a regra existe).
procurar() { local padrao="$1"; shift; swift_em "$@" | xargs grep -nE "$padrao" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//'; }

echo
echo "ESCALIBUR WALLET: verificacoes"

# Caminho com espaco quebra o "find | xargs grep" das regras e deixa arquivo sem
# conferencia. Nenhum fonte pode ter espaco no caminho.
com_espaco=$(find Kit/Sources Kit/Tests App tools \( -name "*.swift" -o -name "*.py" -o -name "*.sh" -o "${nao_swift[@]}" \) 2>/dev/null | grep '[[:space:]]')
if [ -n "$com_espaco" ]; then
    echo "  ✗ arquivo com espaco no caminho escapa das regras: renomeie"
    echo "$com_espaco"
    exit 1
fi

# 1. Chaves e redes nao falam com a internet.
secao "fronteira de rede"
achados=$(procurar 'import (Network|WebKit|SafariServices|CFNetwork)\b|URLSession|URLRequest|NWConnection|NWPathMonitor|CFSocket|CFStream|getaddrinfo|\bsocket\(|WKWebView' "$CORE" "$CHAINS" "$KEYS")
[ -n "$achados" ] && { aviso "codigo de rede no nucleo, nas redes ou nas chaves"; echo "$achados"; } || ok "nucleo, redes e chaves nao tem codigo de rede"

achados=$(procurar 'NSClassFromString|NSSelectorFromString|dlopen|dlsym|objc_msgSend|\.perform\(' "$CORE" "$CHAINS" "$KEYS")
[ -n "$achados" ] && { aviso "reflexao que contornaria a fronteira"; echo "$achados"; } || ok "sem reflexao no nucleo, nas redes e nas chaves"

achados=$(swift_em "$APP" "$CORE" "$CHAINS" "$KEYS" "$ENG" | xargs grep -lE 'URLSession' 2>/dev/null)
[ -n "$achados" ] && { aviso "URLSession fora do modulo de rede"; echo "$achados"; } || ok "URLSession so no modulo de rede"

achados=$(procurar 'URLSession\.shared|AsyncImage' "$APP" "$NET" "$CORE" "$CHAINS" "$KEYS" "$ENG")
[ -n "$achados" ] && { aviso "URLSession.shared ou AsyncImage (gravam cache em disco)"; echo "$achados"; } || ok "sem URLSession.shared e sem AsyncImage"

achados=$(procurar 'import EscaliburKeys|SecureBytes|WalletSecret|RootKeyVault|WalletVault|Mnemonic|HDKey' "$NET")
[ -n "$achados" ] && { aviso "o modulo de rede enxerga segredo"; echo "$achados"; } || ok "o modulo de rede nao enxerga segredo nem chave"

achados=$(procurar 'import (Security|LocalAuthentication|EscaliburKeys)\b|SecItem[A-Z]|SecKey[A-Z]|SecAccessControl|LAContext' "$NET" "$ENG")
[ -n "$achados" ] && { aviso "rede ou motores tocam chaveiro, Secure Enclave ou biometria"; echo "$achados"; } || ok "rede e motores nao tocam chaveiro, Secure Enclave nem biometria"
deps_motores=$(awk '/name: "EscaliburEngines"/{f=1} f&&/dependencies/{print; exit}' Kit/Package.swift)
echo "$deps_motores" | grep -q 'EscaliburKeys' && aviso "EscaliburEngines depende de EscaliburKeys no Package.swift" || ok "EscaliburEngines nao depende de EscaliburKeys (o compilador garante)"
deps_rede=$(awk '/name: "EscaliburNetwork"/{f=1} f&&/dependencies/{print; exit}' Kit/Package.swift)
echo "$deps_rede" | grep -q 'EscaliburKeys' && aviso "EscaliburNetwork depende de EscaliburKeys no Package.swift" || ok "EscaliburNetwork nao depende de EscaliburKeys (o compilador garante)"

achados=$(procurar 'SecureBytes|WalletSecret|RootKeyVault|WalletVault|KeychainStore|SecureEnclaveWrapper|Signer\b|Mnemonic|HDKey|SecretStore' "$ENG")
[ -n "$achados" ] && { aviso "os motores enxergam segredo, cofre ou assinador"; echo "$achados"; } || ok "os motores so usam dado publico do modulo de chaves"

achados=$(procurar 'import (Network|WebKit|SafariServices|CFNetwork)\b|URLRequest|NWConnection|WKWebView' "$ENG")
[ -n "$achados" ] && { aviso "os motores falam com a rede sem passar pelo modulo de rede"; echo "$achados"; } || ok "os motores so falam com a rede pelo modulo de rede"

achados=$(procurar 'SigningPlan\(' "$APP" "$KEYS" "$NET" "$ENG" "$CORE")
[ -n "$achados" ] && { aviso "plano de assinatura construido fora das redes"; echo "$achados"; } || ok "plano de assinatura so nasce em EscaliburChains"

achados=$(procurar 'Secp256k1\.sign|Ed25519\.sign' "$CHAINS" "$NET" "$APP" "$ENG")
[ -n "$achados" ] && { aviso "assinatura fora do modulo de chaves"; echo "$achados"; } || ok "so o modulo de chaves assina"

# 2. Hosts travados.
secao "hosts"
hosts_atuais=$(grep -ohE 'https://[A-Za-z0-9.-]+' $(swift_em "$NET" "$ENG") "$APP/Resources/Info.plist" 2>/dev/null | sort -u)
gerar_allowed_hosts() {
    {
        echo "// Gerado por tools/verificar.sh --atualizar-hosts a partir do hosts.lock. Nao editar."
        echo "// O HTTPClient recusa qualquer host fora desta lista, em tempo de execucao."
        echo "enum AllowedHosts {"
        echo "    static let all: Set<String> = ["
        sed 's|https://||' hosts.lock | while read -r host; do echo "        \"$host\","; done
        echo "    ]"
        echo "}"
    } > "$NET/AllowedHosts.swift"
}
if [ "${1:-}" = "--atualizar-hosts" ]; then
    echo "$hosts_atuais" > hosts.lock
    gerar_allowed_hosts
    ok "hosts.lock e AllowedHosts.swift atualizados"
elif [ ! -f hosts.lock ]; then
    aviso "hosts.lock nao existe (gere com --atualizar-hosts e revise o diff)"
elif ! diff -q <(echo "$hosts_atuais") hosts.lock >/dev/null; then
    aviso "a lista de hosts mudou; revise e rode --atualizar-hosts"
    diff <(echo "$hosts_atuais") hosts.lock
else
    ok "$(wc -l < hosts.lock | tr -d ' ') hosts conferem com hosts.lock"
fi
achados=$(swift_em "$APP" "$NET" "$CORE" "$CHAINS" "$KEYS" | xargs grep -nE '"http://' 2>/dev/null)
[ -n "$achados" ] && { aviso "http sem TLS"; echo "$achados"; } || ok "nenhum http sem TLS"

if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsArbitraryLoads" "$APP/Resources/Info.plist" 2>/dev/null | grep -q true; then
    aviso "ATS com NSAllowsArbitraryLoads ligado"
elif grep -qE 'NSExceptionAllowsInsecureHTTPLoads|NSAllowsLocalNetworking' "$APP/Resources/Info.plist"; then
    aviso "ATS com excecao"
else
    ok "ATS padrao, sem excecao"
fi

# 3. Dependencias.
esperado=$(sed 's|https://||' hosts.lock 2>/dev/null | sort)
gerado=$(grep -oE '^        "[^"]+",$' "$NET/AllowedHosts.swift" 2>/dev/null | tr -d ' ",' | sort)
[ "$esperado" = "$gerado" ] && ok "o cliente HTTP recusa em tempo de execucao todo host fora do hosts.lock" || aviso "AllowedHosts.swift difere do hosts.lock (rode --atualizar-hosts)"
grep -q 'allowedHosts.contains(host)' "$NET/HTTPClient.swift" && ok "HTTPClient confere o host de toda requisicao" || aviso "HTTPClient deixou de conferir o host"

secao "dependencias"
if grep -q "XCRemoteSwiftPackageReference" EscaliburWallet.xcodeproj/project.pbxproj 2>/dev/null; then aviso "pacote remoto no projeto"; else ok "nenhum pacote remoto no projeto"; fi
if grep -q '\.package(url' Kit/Package.swift; then aviso "pacote remoto no Package.swift"; else ok "nenhum pacote remoto no Package.swift"; fi
if grep -q '\.binaryTarget(' Kit/Package.swift; then aviso "alvo binario no Package.swift"; else ok "nenhum alvo binario"; fi
achados=$(find . \( -name "*.xcframework" -o -name "*.framework" -o -name "*.a" -o -name "*.dylib" -o -name Podfile -o -name Cartfile \) -not -path "./build/*" -not -path "*/.build/*" -not -path "./.git/*" -not -path "./.claude/*" 2>/dev/null)
[ -n "$achados" ] && { aviso "binario ou gerenciador de terceiro"; echo "$achados"; } || ok "nenhum binario de terceiro"

# 3b. Fontes e build. As regras de rede, segredo e registro leem so .swift, e a pasta do
# app inteira e fonte do alvo (project.yml): um .m ou .c ali compilaria sem passar por
# nenhuma delas. O unico codigo que nao e Swift e o C vendorizado, travado por digesto.
# Um shader .metal so entra pela lista abaixo, revisado como codigo (hoje, nenhum).
secao "fontes e build"
# Caminhos separados por espaco; a lista so vale para .metal.
metal_permitidos=""
achados=$(find App Kit/Sources Kit/Tests -type f \( "${nao_swift[@]}" \) -not -path "Kit/Sources/CArgon2/*" -not -path "Kit/Sources/CSecp256k1/*" 2>/dev/null \
    | while read -r fonte; do
        [[ "$fonte" == *.metal ]] && printf '%s\n' $metal_permitidos | grep -qxF "$fonte" && continue
        echo "$fonte"
    done)
[ -n "$achados" ] && { aviso "fonte que nao e Swift fora do C vendorizado (CArgon2 e CSecp256k1)"; echo "$achados"; } \
    || ok "fora do C vendorizado (CArgon2 e CSecp256k1), todo fonte e Swift"
# Nada roda nem entra no binario por fora do fonte: fase de script de build (shell a cada
# build, com o repositorio e a rede na mao), acao de esquema, plugin do SwiftPM, framework
# ou biblioteca que nao e do SDK, flag de linker (carregaria codigo de fora). Hoje nao ha
# nenhum; o que for legitimo um dia entra aqui por nome.
pbx=EscaliburWallet.xcodeproj/project.pbxproj
achados=$( {
    grep -nE 'PBXShellScriptBuildPhase|shellScript|PBXBuildRule|OTHER_LDFLAGS|OTHER_LIBTOOLFLAGS|-Xlinker' "$pbx" | sed "s|^|$pbx:|"
    grep -nE '(lastKnownFileType|explicitFileType) = "?(wrapper\.(xc)?framework|archive\.ar|compiled\.mach-o\.dylib|sourcecode\.text-based-dylib-definition)' "$pbx" \
        | grep -v 'sourceTree = SDKROOT' | sed "s|^|$pbx:|"
    grep -nHE 'ShellScriptAction|<PreActions|<PostActions' EscaliburWallet.xcodeproj/xcshareddata/xcschemes/*.xcscheme
    grep -nE 'preBuildScripts|postCompileScripts|postBuildScripts|buildRules|buildToolPlugins|preActions|postActions|OTHER_LDFLAGS|OTHER_LIBTOOLFLAGS|-Xlinker|^[[:space:]]*- (framework|carthage|bundle):' project.yml \
        | sed 's|^|project.yml:|'
    grep -nE 'linkerSettings|unsafeFlags|\.plugin\(|plugins:|\.systemLibrary\(|linkedFramework|linkedLibrary' Kit/Package.swift | sed 's|^|Kit/Package.swift:|'
} 2>/dev/null)
[ -n "$achados" ] && { aviso "script de build, framework fora do SDK ou flag de linker no projeto"; echo "$achados"; } \
    || ok "sem fase de script, acao de esquema, plugin de build, framework fora do SDK nem flag de linker"

# 4. Codigo vendorizado travado por digesto.
secao "codigo vendorizado"
conferir_lock() {
    local lock="$1" base="$2" nome="$3"
    local divergentes=0 total=0
    while IFS= read -r linha; do
        arquivo=$(echo "$linha" | sed -n 's/^    "\([^"]*\)": "\([0-9a-f]\{64\}\)".*/\1/p')
        esperado=$(echo "$linha" | sed -n 's/^    "\([^"]*\)": "\([0-9a-f]\{64\}\)".*/\2/p')
        [ -z "$arquivo" ] && continue
        total=$((total + 1))
        atual=$(shasum -a 256 "$base/$arquivo" 2>/dev/null | cut -d' ' -f1)
        [ "$atual" != "$esperado" ] && { aviso "$nome/$arquivo nao confere"; divergentes=$((divergentes + 1)); }
    done < "$lock"
    [ "$divergentes" = "0" ] && ok "$total arquivos de $nome conferem com $lock"
}
conferir_lock secp256k1.lock Kit/Sources/CSecp256k1/upstream secp256k1
conferir_lock argon2.lock Kit/Sources/CArgon2 argon2
conferir_lock modelos.lock App/EscaliburWallet/Resources/Moeda3D "moeda 3D"
fora_do_lock=$(comm -23 <(ls App/EscaliburWallet/Resources/Moeda3D | sort) <(sed -n 's/^    "\([^"]*\)": "[0-9a-f]\{64\}".*/\1/p' modelos.lock | sort))
[ -n "$fora_do_lock" ] && { aviso "arquivo na moeda 3D fora do modelos.lock"; echo "$fora_do_lock"; } || ok "a pasta da moeda 3D so tem o que o modelos.lock lista"
divergentes=0
for idioma in $(sed -n 's/^ *"\([a-z_]*\)": "[0-9a-f]*".*/\1/p' wordlists.lock); do
    esperado=$(sed -n "s/^ *\"$idioma\": \"\([0-9a-f]*\)\".*/\1/p" wordlists.lock)
    atual=$(shasum -a 256 "$CORE/Resources/Wordlists/$idioma.txt" | cut -d' ' -f1)
    [ "$atual" != "$esperado" ] && { aviso "lista $idioma nao confere"; divergentes=$((divergentes + 1)); }
done
[ "$divergentes" = "0" ] && ok "as 10 listas BIP-39 conferem com wordlists.lock"
divergentes=0
for lista in $(sed -n 's/^ *"\([a-z-]*\)": "[0-9a-f]*".*/\1/p' forca.lock); do
    esperado=$(sed -n "s/^ *\"$lista\": \"\([0-9a-f]*\)\".*/\1/p" forca.lock)
    atual=$(shasum -a 256 "$CORE/Resources/Forca/$lista.txt" | cut -d' ' -f1)
    [ "$atual" != "$esperado" ] && { aviso "lista de forca $lista nao confere"; divergentes=$((divergentes + 1)); }
done
[ "$divergentes" = "0" ] && ok "as listas do medidor de forca conferem com forca.lock"

# 5. Registro e aleatoriedade.
# Decifrador de referencia (so para os testes, fora do app): decifrar.py e FORMATO.md
# travados por digesto. O app nao distribui decifrador para computador.
if (cd tools/referencia && shasum -a 256 -c ../../recuperacao.lock >/dev/null 2>&1); then
    ok "decifrador de referencia confere com recuperacao.lock"
else
    aviso "decifrador de referencia difere de recuperacao.lock"
fi
[ -e "$APP/Resources/Recuperacao" ] && aviso "decifrador para computador de volta no app" || ok "nenhum decifrador para computador dentro do app"

secao "registro e aleatoriedade"
achados=$(procurar '(^|[^A-Za-z0-9_.])(print|debugPrint|dump|NSLog)\(' "$APP" "$CORE" "$CHAINS" "$KEYS" "$NET")
[ -n "$achados" ] && { aviso "print/NSLog fora dos testes"; echo "$achados"; } || ok "nenhum print fora dos testes"
achados=$(procurar 'Logger\(|os_log' "$KEYS" "$CHAINS")
[ -n "$achados" ] && { aviso "logger no modulo de chaves ou de redes"; echo "$achados"; } || ok "chaves e redes nao registram nada"
achados=$(procurar '\.random\(|randomElement|shuffled\(\)|arc4random|drand48|\brand\(|SystemRandomNumberGenerator|GKRandom' "$CORE" "$CHAINS" "$KEYS" "$APP" | grep -v 'SecureBytes\.random(')
[ -n "$achados" ] && { aviso "aleatoriedade fora do SecRandomCopyBytes"; echo "$achados"; } || ok "a unica fonte de aleatoriedade e o SecRandomCopyBytes"

# 6. Chaveiro e biometria.
secao "chaveiro e biometria"
achados=$(swift_em "$APP" "$CORE" "$CHAINS" "$KEYS" "$NET" | xargs grep -lE 'SecItemAdd|SecItemUpdate|SecKeyCreateRandomKey' 2>/dev/null | grep -vE "$KEYS/(SecretStore|Enclave)\.swift")
[ -n "$achados" ] && { aviso "chamada ao chaveiro fora de SecretStore/Enclave"; echo "$achados"; } || ok "chaveiro so em SecretStore.swift e Enclave.swift"
achados=$(procurar 'AfterFirstUnlock|AccessibleAlways|kSecAttrAccessibleWhenUnlocked\b|SynchronizableAny|\.userPresence|\.devicePasscode|\.biometryAny|\.or\b|kSecAttrSynchronizable as String: kCFBooleanTrue' "$APP" "$KEYS")
[ -n "$achados" ] && { aviso "protecao fraca de chaveiro ou biometria"; echo "$achados"; } || ok "sem userPresence, devicePasscode, biometryAny, .or, AfterFirstUnlock, WhenUnlocked sem ThisDeviceOnly"
if ! grep -q 'kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly' "$KEYS/SecretStore.swift"; then aviso "WhenPasscodeSetThisDeviceOnly sumiu"; else ok "itens em WhenPasscodeSetThisDeviceOnly"; fi
# A unica excecao (simulador) precisa estar atras de targetEnvironment(simulator).
excecao=$(awk '/#if targetEnvironment\(simulator\)/{d=1} /#else|#endif/{d=0} /kSecAttrAccessibleWhenUnlockedThisDeviceOnly/{ if(!d) print FILENAME": "NR }' "$KEYS/SecretStore.swift")
[ -n "$excecao" ] && { aviso "classe de simulador fora do bloco de simulador"; echo "$excecao"; } || ok "a excecao do simulador so compila para simulador"
achados=$(awk 'FNR==1{d=0} /#if targetEnvironment\(simulator\)/{d=1} /#else|#endif/{d=0} /SimulatorWrapper\(\)|SoftwareWrapper\(\)/{ if(!d) print FILENAME": "FNR": "$0 }' $(swift_em "$APP" "$KEYS"))
[ -n "$achados" ] && { aviso "embrulho em software fora do simulador"; echo "$achados"; } || ok "embrulho em software so no simulador e nos testes"
achados=$(swift_em "$CORE" "$CHAINS" "$KEYS" "$NET" | xargs grep -nE 'class (MemoryStore|SoftwareWrapper)\b' 2>/dev/null)
[ -n "$achados" ] && { aviso "duble de teste dentro do codigo que vai para o app"; echo "$achados"; } || ok "armazenamento em memoria e embrulho em software so existem nos testes"
achados=$(swift_em "$APP" "$KEYS" | xargs grep -n 'evaluatePolicy(' 2>/dev/null | grep -v 'canEvaluatePolicy' | grep -v "$APP/Services/KeyServices.swift")
[ -n "$achados" ] && { aviso "evaluatePolicy fora do simulador (booleano nao autoriza nada)"; echo "$achados"; } || ok "nenhum booleano de biometria autoriza operacao"

# 6b. Segredo em String e comparacao de segredo. Grep com falso positivo possivel:
# cada excecao e uma linha em tools/excecoes.allow ("arquivo|trecho|por que"),
# revisada como codigo.
secao "segredo"
filtrar_excecoes() {
    local entrada
    entrada=$(cat)
    [ -z "$entrada" ] && return
    while IFS='|' read -r arquivo trecho _; do
        [ -z "$arquivo" ] || [ "${arquivo#\#}" != "$arquivo" ] && continue
        entrada=$(echo "$entrada" | grep -vF "$arquivo:" ; echo "$entrada" | grep -F "$arquivo:" | grep -vF "$trecho")
        entrada=$(echo "$entrada" | sed '/^$/d')
    done < tools/excecoes.allow
    echo "$entrada"
}
achados=$(swift_em "$APP" "$CORE" "$CHAINS" "$KEYS" "$NET" "$ENG" | xargs grep -niE '(var|let) +[A-Za-z_]*(pin|senha|password|seed|mnemonic|phrase|entropy|privatekey|secret)[A-Za-z_]* *(: *String|= *"")|@State[^=]*(pin|senha|seed|mnemonic|phrase)[A-Za-z_]* *(: *String|= *"")' 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | filtrar_excecoes)
[ -n "$achados" ] && { aviso "segredo guardado em String"; echo "$achados"; } || ok "nenhum segredo guardado em String (fora das excecoes revisadas)"
achados=$(procurar '(digest|tag|mac|hmac|secret|key)[A-Za-z_]* *[!=]=' "$KEYS" | filtrar_excecoes)
[ -n "$achados" ] && { aviso "segredo comparado com == (use Hash.constantTimeEqual)"; echo "$achados"; } || ok "segredo so comparado em tempo constante no modulo de chaves"
achados=$(procurar '(Data|String|NSData|NSString|NSArray|NSDictionary)\(contentsOf: *URL\(string' "$APP" "$CORE" "$CHAINS" "$KEYS" "$NET" "$ENG")
[ -n "$achados" ] && { aviso "leitura de URL remota fora do cliente HTTP"; echo "$achados"; } || ok "nenhuma leitura de rede por contentsOf"
achados=$(procurar '(Data|String|NSData|NSString)\(contentsOf:' "$CHAINS" "$KEYS" "$ENG")
[ -n "$achados" ] && { aviso "leitura de arquivo em redes, chaves ou motores"; echo "$achados"; } || ok "redes, chaves e motores nao leem arquivo"

# 7. Plataforma.
secao "plataforma"
grep -q 'shouldAllowExtensionPointIdentifier' "$APP/App/PlatformGuards.swift" && grep -q '\.keyboard' "$APP/App/PlatformGuards.swift" \
    && ok "teclados de terceiros bloqueados" || aviso "bloqueio de teclado de terceiro sumiu"
grep -q 'willResignActiveNotification' "$APP/App/PlatformGuards.swift" && ok "cobertura antes da foto do seletor de apps" || aviso "cobertura do seletor sumiu"
grep -q 'NSFileProtectionComplete' "$APP/Resources/EscaliburWallet.entitlements" && ok "NSFileProtectionComplete em todo o conteiner" || aviso "protecao de arquivo sumiu"
grep -q 'sceneCaptureState' "$APP/App/PlatformGuards.swift" && grep -q 'isCaptured' "$APP/App/PlatformGuards.swift" \
    && ok "tela sensivel some com gravacao, espelhamento ou captura da cena" || aviso "defesa contra captura de tela incompleta"
grep -q 'isExcludedFromBackup = true' "$APP/Services/Metadata.swift" && ok "metadados fora do backup do iCloud" || aviso "metadados podem ir para o backup"
# Protecao mais fraca que a Complete: so o marcador de instalacao, o arquivo dos
# alertas de preco (nao diz o que a carteira tem), o do aviso de recebimento (so os
# enderecos publicos), o das ordens limite abertas (so o UID de cada uma) e o do widget
# (so a moeda e o preco), que precisam abrir com o iPhone bloqueado.
achados=$(procurar 'UntilFirstUserAuthentication|completeUnlessOpen|CompleteUnlessOpen|FileProtectionType\.none|noFileProtection' "$APP" "$CORE" "$CHAINS" "$KEYS" "$NET" "$ENG" \
    | grep -vE "^$APP/(Services/KeyServices|Services/PriceAlerts|Services/ReceiptWatch|Services/LimitOrderWatch|Services/WidgetFeed)\.swift:")
[ -n "$achados" ] && { aviso "protecao de arquivo mais fraca fora das cinco excecoes"; echo "$achados"; } || ok "protecao abaixo da Complete so no marcador de instalacao, nos alertas de preco, no aviso de recebimento, nas ordens abertas e no widget"
# O widget: so o arquivo publico do preco. Quem grava nao toca cofre, chaveiro,
# metadados nem saldo; o widget nao importa o Kit, nao fala com a rede e nao le chaveiro.
widget_feed="$APP/Services/WidgetFeed.swift"
achados=$(grep -nE 'import (EscaliburKeys|EscaliburEngines|Security|LocalAuthentication)|KeyServices|RootKeyVault|SecretStore|MetadataStore|SecureBytes|AppSession|Portfolio|WalletMeta|DerivedAccount|balance|address' "$widget_feed" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*//')
[ -n "$achados" ] && { aviso "o arquivo do widget toca cofre, chaveiro, metadados, saldo ou endereco"; echo "$achados"; } || ok "o arquivo do widget so leva a moeda e o preco, sem cofre, chaveiro, metadados, saldo nem endereco"
achados=$(find App/EscaliburWidgets App/Shared -name '*.swift' | xargs grep -nE 'import (Escalibur|Security|LocalAuthentication|Network)|URLSession|URLRequest|NWConnection|SecItem|Keychain|UserDefaults' 2>/dev/null)
[ -n "$achados" ] && { aviso "o widget importa o Kit, fala com a rede ou le o chaveiro"; echo "$achados"; } || ok "o widget so le o arquivo do App Group: sem Kit, sem rede, sem chaveiro"
chaves=$(/usr/libexec/PlistBuddy -c "Print" App/EscaliburWidgets/EscaliburWidgets.entitlements | grep -E '^\s+[a-z][^ ]* = ' | awk '{print $1}' | sort | tr '\n' ' ')
grupos=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" App/EscaliburWidgets/EscaliburWidgets.entitlements 2>/dev/null | grep -c 'group.app.escalibur.wallet$')
[ "$chaves" = "com.apple.security.application-groups " ] && [ "$grupos" = "1" ] && ok "entitlements do widget: so o App Group da carteira" || aviso "entitlements do widget inesperados: $chaves"
recebimento="$APP/Services/ReceiptWatch.swift"
achados=$(grep -nE 'import (EscaliburKeys|Security|LocalAuthentication)|KeyServices|RootKeyVault|SecretStore|MetadataStore|SecureBytes|AppSession|Portfolio|WalletMeta|privateKey|mnemonic' "$recebimento" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*//')
[ -n "$achados" ] && { aviso "o aviso de recebimento toca cofre, chaveiro ou metadados"; echo "$achados"; } || ok "o aviso de recebimento (segundo plano) so le enderecos publicos e saldo, sem cofre, chaveiro nem metadados"
ordens="$APP/Services/LimitOrderWatch.swift"
achados=$(grep -nE 'import (EscaliburKeys|EscaliburEngines|Security|LocalAuthentication)|KeyServices|RootKeyVault|SecretStore|MetadataStore|SecureBytes|AppSession|Portfolio|WalletMeta|DerivedAccount|privateKey|mnemonic' "$ordens" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*//')
[ -n "$achados" ] && { aviso "o aviso das ordens limite toca cofre, chaveiro, conta ou metadados"; echo "$achados"; } || ok "o aviso das ordens limite (segundo plano) so le o UID e o andamento na CoW, sem cofre, chaveiro nem metadados"
alertas="$APP/Services/PriceAlerts.swift"
achados=$(grep -nE 'import (EscaliburKeys|Security|LocalAuthentication)|KeyServices|RootKeyVault|SecretStore|MetadataStore|SecureBytes|AppSession|Portfolio|balance' "$alertas" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*//')
[ -n "$achados" ] && { aviso "os alertas de preco tocam cofre, chaveiro, metadados ou saldo"; echo "$achados"; } || ok "os alertas de preco (segundo plano) nao tocam cofre, chaveiro, metadados nem saldo"
achados=$(swift_em "$APP" "$CORE" "$CHAINS" "$KEYS" "$NET" "$ENG" | xargs grep -nE 'UserDefaults|@AppStorage' 2>/dev/null | grep -v "^$APP/App/Preferences.swift:")
[ -n "$achados" ] && { aviso "UserDefaults fora de Preferences.swift"; echo "$achados"; } || ok "UserDefaults so em Preferences.swift"
# Manifesto de privacidade: sem ele a App Store recusa o envio (API de motivo
# obrigatorio). Sem rastreamento, sem dado coletado, e o motivo do UserDefaults.
manifesto="$APP/Resources/PrivacyInfo.xcprivacy"
if plutil -lint "$manifesto" >/dev/null 2>&1 \
    && [ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyTracking' "$manifesto" 2>/dev/null)" = "false" ] \
    && [ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyCollectedDataTypes' "$manifesto" 2>/dev/null | grep -c Dict)" = "0" ] \
    && grep -q 'NSPrivacyAccessedAPICategoryUserDefaults' "$manifesto" && grep -q 'CA92.1' "$manifesto" \
    && grep -q 'NSPrivacyAccessedAPICategorySystemBootTime' "$manifesto" && grep -q '35F9.1' "$manifesto" \
    && grep -q 'PrivacyInfo.xcprivacy' EscaliburWallet.xcodeproj/project.pbxproj; then
    ok "manifesto de privacidade: sem rastreamento, sem coleta, motivos do UserDefaults e do tempo de boot, no projeto"
else
    aviso "manifesto de privacidade ausente, invalido ou fora do projeto"
fi
chaves=$(/usr/libexec/PlistBuddy -c "Print" "$APP/Resources/EscaliburWallet.entitlements" | grep -E '^\s+[a-z][^ ]* = ' | awk '{print $1}' | sort | tr '\n' ' ')
grupos=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$APP/Resources/EscaliburWallet.entitlements" 2>/dev/null | grep -cE '^\s+group\.')
[ "$chaves" = "com.apple.developer.default-data-protection com.apple.security.application-groups " ] && [ "$grupos" = "1" ] \
    && ok "entitlements: a protecao de dados e um App Group so (o do widget)" || aviso "entitlements inesperados: $chaves"
achados=$(grep -oE 'NS[A-Za-z]+UsageDescription' "$APP/Resources/Info.plist" | sort -u | grep -vE 'NSFaceIDUsageDescription|NSCameraUsageDescription|NSMicrophoneUsageDescription|NSSpeechRecognitionUsageDescription')
[ -n "$achados" ] && { aviso "permissao fora da lista"; echo "$achados"; } || ok "permissoes: Face ID, camera, microfone e fala, nada mais"
achados=$(swift_em "$APP" | xargs grep -lE 'UIPasteboard' 2>/dev/null | grep -vE 'Receive/ReceiveSheet\.swift|NewWallet/ImportPhraseView\.swift|NewWallet/SecurityScreens\.swift')
[ -n "$achados" ] && { aviso "area de transferencia fora dos pontos conhecidos"; echo "$achados"; } || ok "area de transferencia so em tres pontos"
# A checagem do aparelho so pergunta se ha texto copiado, sem ler o conteudo.
achados=$(grep -nE 'UIPasteboard' "$APP/Features/NewWallet/SecurityScreens.swift" | grep -v 'UIPasteboard.general.hasStrings')
[ -n "$achados" ] && { aviso "a checagem do aparelho le a area de transferencia"; echo "$achados"; } || ok "a checagem do aparelho so pergunta se ha texto copiado"
# Toda copia passa por setItems, local (nao vai para o Mac) e com validade. A frase vale
# no maximo 1 minuto e so sai pela tela das palavras, depois do aviso (CopyPhraseSheet).
f="$APP/Features/Receive/ReceiveSheet.swift"
copias=$(grep -c 'UIPasteboard.general.setItems' "$f"); locais=$(grep -c '\.localOnly: true' "$f"); prazos=$(grep -c '\.expirationDate: Date().addingTimeInterval' "$f")
outras=$(grep -n 'UIPasteboard' "$f" | grep -v 'UIPasteboard.general.setItems')
[ "$copias" -gt 0 ] && [ "$copias" = "$locais" ] && [ "$copias" = "$prazos" ] && [ -z "$outras" ] \
    && ok "toda copia e local e expira" || aviso "copia sem localOnly/expiracao"
prazo=$(awk '/static func copyPhrase/,/^    }/' "$f" | grep -oE 'addingTimeInterval\([0-9]+\)' | grep -oE '[0-9]+')
chamadas=$(procurar 'Pasteboard\.copyPhrase' "$APP" | grep -v 'Receive/ReceiveSheet\.swift:')
[ -n "$prazo" ] && [ "$prazo" -le 60 ] && [ "$(echo "$chamadas" | grep -c .)" = "1" ] && echo "$chamadas" | grep -q 'NewWallet/RecordWordsView\.swift:' \
    && grep -q 'CopyPhraseSheet {' "$APP/Features/NewWallet/RecordWordsView.swift" \
    && ok "a frase so e copiada depois do aviso e some em ate 1 minuto" || { aviso "copia da frase fora do aviso ou com validade longa"; echo "$chamadas"; }
achados=$(procurar '^[[:space:]]*import +(Firebase[A-Za-z]*|Crashlytics|Sentry|Bugsnag|Amplitude|Mixpanel|Segment|AppsFlyer[A-Za-z]*|Adjust[A-Za-z]*|Branch|OneSignal|Datadog[A-Za-z]*|NewRelic|Instabug|FBSDK[A-Za-z]*|GoogleMobileAds|PostHog)\b' "$APP" "$NET" "$CORE" "$CHAINS" "$KEYS")
[ -n "$achados" ] && { aviso "SDK de terceiro"; echo "$achados"; } || ok "nenhum SDK de analise, falha ou anuncio"
achados=$(procurar 'WKWebView|SFSafariViewController|UIWebView|ASWebAuthenticationSession' "$APP")
[ -n "$achados" ] && { aviso "navegador embutido"; echo "$achados"; } || ok "sem navegador embutido"

# 8. Modo de demonstracao so em depuracao.
secao "depuracao"
head -1 "$APP/App/DebugDemo.swift" | grep -q '^#if DEBUG' && ok "DebugDemo.swift inteiro atras de #if DEBUG" || aviso "DebugDemo.swift fora de #if DEBUG"
achados=$(awk 'FNR==1{d=0} /#if DEBUG/{d=1} /#endif/{d=0} /DebugDemo\./{ if(!d) print FILENAME": "FNR }' $(swift_em "$APP" | grep -v DebugDemo.swift))
[ -n "$achados" ] && { aviso "uso de DebugDemo fora de #if DEBUG"; echo "$achados"; } || ok "nenhum uso de DebugDemo fora de #if DEBUG"
# Argumento de inicializacao so em depuracao: quem abre o app passando argumentos (Xcode,
# um atalho, um app de terceiros) mudaria o comportamento do app da loja. Mesma tecnica da
# regra acima; `#else` e `#elseif` encerram o bloco, e um `#if` aninhado tambem, o que so
# pode acusar a mais, nunca deixar passar.
achados=$(awk 'FNR==1{d=0} /^[[:space:]]*#if DEBUG/{d=1} /^[[:space:]]*#(else|elseif|endif)/{d=0}
    /(ProcessInfo\.processInfo|ProcessInfo\(\)|processInfo)\.arguments|CommandLine\.(arguments|unsafeArgv|argc)/{ if(!d && $0 !~ /^[[:space:]]*\/\//) print FILENAME": "FNR": "$0 }' \
    $(swift_em App/EscaliburWallet App/Shared App/EscaliburWidgets))
[ -n "$achados" ] && { aviso "argumento de inicializacao lido fora de #if DEBUG"; echo "$achados"; } || ok "argumentos de inicializacao so lidos dentro de #if DEBUG"
# E o DEBUG so existe na configuracao Debug do projeto: com ele no Release, todo #if DEBUG
# iria para a loja, e as duas regras acima nao protegeriam nada.
achados=$(awk '/^[[:space:]]*[0-9A-F]+ \/\* [^*]+ \*\/ = \{/{ match($0, /\/\* [^*]+ \*\//); cfg=substr($0, RSTART+3, RLENGTH-6) }
    /SWIFT_ACTIVE_COMPILATION_CONDITIONS|GCC_PREPROCESSOR_DEFINITIONS|OTHER_SWIFT_FLAGS|OTHER_CFLAGS/{f=1}
    f && /DEBUG/{ if(cfg != "Debug") print FILENAME": "NR" ("cfg"): "$0 } /;[[:space:]]*$/{f=0}' "$pbx")
[ -n "$achados" ] && { aviso "DEBUG ligado fora da configuracao Debug"; echo "$achados"; } || ok "DEBUG so na configuracao Debug (o Release nao compila nada de #if DEBUG)"

# 9. Texto que o usuario le, sem travessao.
secao "determinismo"
achados=$(grep -rnE '__DATE__|__TIME__|__TIMESTAMP__' Kit/Sources/CSecp256k1 Kit/Sources/CArgon2 2>/dev/null)
[ -n "$achados" ] && { aviso "data de compilacao no C"; echo "$achados"; } || ok "nenhuma data de compilacao no C vendorizado"
if [ -f .xcode-version ]; then
    atual=$(xcodebuild -version 2>/dev/null | head -1)
    [ "$atual" = "$(cat .xcode-version)" ] && ok "Xcode igual ao .xcode-version ($atual)" || aviso "Xcode $atual difere do .xcode-version ($(cat .xcode-version))"
else
    aviso ".xcode-version nao existe"
fi

secao "privacidade"
faltando=""
for host in $(sed 's|https://||' hosts.lock); do
    for politica in privacidade.md privacidade-en.md; do
        grep -qF "\`$host\`" "$APP/Resources/Legal/$politica" || faltando="$faltando $host($politica)"
    done
done
[ -n "$faltando" ] && aviso "host fora da Politica de privacidade:$faltando" || ok "todo host do hosts.lock esta na Politica de privacidade, em portugues e em ingles"
# Contato (diretriz 1.5 da App Store e LGPD, art. 9): o e-mail do app e o mesmo da
# pagina de suporte, dos Termos e da Politica.
email=$(grep -oE 'static let email = "[^"]+"' "$APP/Features/Settings/SupportView.swift" 2>/dev/null | sed -E 's/.*"(.*)"/\1/')
faltando=""
for arquivo in site/suporte.md "$APP/Resources/Legal/termos.md" "$APP/Resources/Legal/privacidade.md" \
    "$APP/Resources/Legal/termos-en.md" "$APP/Resources/Legal/privacidade-en.md"; do
    grep -qF "$email" "$arquivo" 2>/dev/null || faltando="$faltando $arquivo"
done
if [ -z "$email" ]; then
    aviso "e-mail de suporte ausente no app (SupportView.swift)"
elif [ -n "$faltando" ]; then
    aviso "e-mail de suporte ($email) fora de:$faltando"
else
    ok "e-mail de suporte igual no app, na pagina de suporte, nos Termos e na Politica"
fi
saida_site=$(mktemp -d)
python3 tools/gerar-site.py "$saida_site/site" >/dev/null 2>&1 && [ -f "$saida_site/site/privacidade/index.html" ] && [ -f "$saida_site/site/suporte/index.html" ] \
    && [ -f "$saida_site/site/termos/index.html" ] \
    && ok "paginas publicas (suporte, privacidade, termos) geradas dos mesmos textos do app" || aviso "tools/gerar-site.py falhou"

# O site (tools/gerar-site.py) le redes e tokens do codigo por expressao regular. Se o
# codigo mudar de forma e o leitor ficar para tras, a contagem diverge e isto falha, em
# vez de o site publicar uma lista pela metade.
secao "site"
redes_codigo=$(awk '/static let all: \[Chain\] = \[/{f=1;next} f&&/\]/{exit} f' "$CHAINS/Chain.swift" | grep -oE '\.[a-z0-9]+' | wc -l | tr -d ' ')
tokens_codigo=$(awk '/public static let tokens: \[Asset\] = \[/{f=1;next} f&&/^    \]$/{exit} f' "$CHAINS/TokenRegistry.swift" | grep -cE '^[[:space:]]*(erc20|spl|issued|Asset)\(')
contagem=$(python3 tools/gerar-site.py --contagem 2>&1)
if [ "$contagem" = "redes $redes_codigo tokens $tokens_codigo" ]; then
    ok "o site lista as $redes_codigo redes de Chain.swift e os $tokens_codigo tokens de TokenRegistry.swift"
else
    aviso "o site leu \"$contagem\", e o codigo tem $redes_codigo redes e $tokens_codigo tokens (tools/gerador_site/dados.py)"
fi
paginas_site=$(find "$saida_site/site" -name '*.html' 2>/dev/null)
if [ -z "$paginas_site" ]; then
    aviso "o site nao foi gerado"
else
    sem_csp=$(echo "$paginas_site" | xargs grep -L "content=\"default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; media-src 'self'; base-uri 'none'; form-action 'none'\"" 2>/dev/null)
    de_fora=$(echo "$paginas_site" | xargs grep -noE '(src|poster)="https?://|<link rel="(stylesheet|icon|apple-touch-icon|preload|modulepreload|manifest)"[^>]*href="https?://|<script>|<script [^>]*>[^<]|style="| on[a-z]+="' 2>/dev/null)
    de_fora="$de_fora$(grep -noE 'url\(["'"'"']?(https?:)?//|@import' "$saida_site/site/estilo.css" 2>/dev/null)"
    if [ -n "$sem_csp$de_fora" ]; then
        aviso "pagina do site sem a Content Security Policy, ou com script, estilo ou recurso de fora"; echo "$sem_csp$de_fora"
    else
        ok "todas as paginas do site com Content Security Policy, sem script em linha e sem nada carregado de outro site"
    fi
    # Codigo citado nas paginas de auditoria sai como entidade HTML: o que sobra e texto.
    achados=$(echo "$paginas_site" | xargs grep -lE '—|–' 2>/dev/null)
    [ -n "$achados" ] && { aviso "travessao nas paginas do site"; echo "$achados"; } || ok "nenhum travessao nas paginas do site"
    # O selo oficial da Apple so pode levar a um app que esta na loja.
    if grep -qE '^APP_STORE_URL = None' tools/gerar-site.py && echo "$paginas_site" | xargs grep -l 'src="[^"]*baixar-na-app-store.svg"' >/dev/null 2>&1; then
        aviso "selo da App Store no site sem o app na loja"
    else
        ok "selo da App Store so com o link do app na loja (APP_STORE_URL em tools/gerar-site.py)"
    fi
fi
rm -rf "$saida_site"

secao "texto"
achados=$(swift_em "$APP" | xargs grep -nE '"[^"]*(—|–)[^"]*"' 2>/dev/null)
[ -n "$achados" ] && { aviso "travessao em texto de interface"; echo "$achados"; } || ok "nenhum travessao em texto de interface"
# Todo texto do catalogo traduzido nos doze idiomas, com os campos certos. Texto novo entra
# pelo tools/traducao/sincronizar.sh e e traduzido antes do commit (tools/traducao/glossario.md).
if resumo=$(python3 tools/traducao/conferir.py 2>&1); then
    ok "todo texto de tela traduzido nos $(echo "$resumo" | grep -c 'traduzidos') idiomas, sem campo trocado"
else
    aviso "texto de tela sem traducao ou com traducao invalida (tools/traducao/conferir.py --resumo)"
    echo "$resumo" | grep -vE ' 0 faltando, 0 invalidos' | head -14
fi

# 10. Testes com vetores oficiais, e a fronteira conferida tambem no binario (regra 3
# de docs/seguranca.md §8.3): os objetos compilados de Chaves, Cadeias e Nucleo nao
# podem referenciar nenhum simbolo de rede. O modulo de rede e o controle: nele os
# simbolos aparecem, e a checagem que nao os achasse ali estaria cega.
if [ "${1:-}" = "--testes" ]; then
    secao "testes"
    saida=$(cd Kit && swift test 2>&1); codigo=$?
    if [ "$codigo" = "0" ]; then
        ok "testes do nucleo passam ($(echo "$saida" | grep -oE 'Test run with [0-9]+ tests' | tail -1))"
    else
        aviso "testes do nucleo falharam (saida $codigo)"
        echo "$saida" | grep -E "✘|error:|fatal error|Fatal error" | head -40
        echo "$saida" | tail -15
    fi
    proibidos='URLSession|_nw_|CFSocket|CFStream|^_socket$|^_connect$|^_getaddrinfo$'
    achados=""
    for modulo in EscaliburKeys EscaliburChains EscaliburCore; do
        n=$(nm -u Kit/.build/debug/$modulo.build/*.o 2>/dev/null | grep -cE "$proibidos")
        [ "$n" != "0" ] && achados="$achados $modulo($n)"
    done
    controle=$(nm -u Kit/.build/debug/EscaliburNetwork.build/*.o 2>/dev/null | grep -cE "$proibidos")
    if [ -n "$achados" ]; then
        aviso "simbolo de rede no binario:$achados"
    elif [ "$controle" = "0" ]; then
        aviso "checagem do binario cega: nem o modulo de rede mostrou simbolo de rede"
    else
        ok "binario de Chaves, Cadeias e Nucleo sem simbolo de rede (controle: $controle no de rede)"
    fi
fi

echo
if [ "$falhas" = "0" ]; then echo "tudo conferido."; else echo "$falhas verificacao(oes) falharam."; fi
exit "$falhas"
