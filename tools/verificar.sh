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
# Procura um padrao em codigo, ignorando linhas que sao so comentario (a regra vale
# para o que compila, nao para a explicacao de por que a regra existe).
procurar() { local padrao="$1"; shift; swift_em "$@" | xargs grep -nE "$padrao" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//'; }

echo
echo "ESCALIBUR WALLET: verificacoes"

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

achados=$(procurar 'SecureBytes|WalletSecret|RootKeyVault|WalletVault|KeychainStore|SecureEnclaveWrapper|Signer\b|Mnemonic|HDKey|SecretStore' "$ENG")
[ -n "$achados" ] && { aviso "os motores enxergam segredo, cofre ou assinador"; echo "$achados"; } || ok "os motores so usam dado publico do modulo de chaves"

achados=$(procurar 'import (Network|WebKit|SafariServices|CFNetwork)\b|URLRequest|NWConnection|WKWebView' "$ENG")
[ -n "$achados" ] && { aviso "os motores falam com a rede sem passar pelo modulo de rede"; echo "$achados"; } || ok "os motores so falam com a rede pelo modulo de rede"

achados=$(procurar 'Secp256k1\.sign|Ed25519\.sign' "$CHAINS" "$NET" "$APP" "$ENG")
[ -n "$achados" ] && { aviso "assinatura fora do modulo de chaves"; echo "$achados"; } || ok "so o modulo de chaves assina"

# 2. Hosts travados.
secao "hosts"
hosts_atuais=$(grep -ohE 'https://[A-Za-z0-9.-]+' $(swift_em "$NET" "$ENG") "$APP/Resources/Info.plist" 2>/dev/null | sort -u)
if [ "${1:-}" = "--atualizar-hosts" ]; then
    echo "$hosts_atuais" > hosts.lock
    ok "hosts.lock atualizado"
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
secao "dependencias"
if grep -q "XCRemoteSwiftPackageReference" EscaliburWallet.xcodeproj/project.pbxproj 2>/dev/null; then aviso "pacote remoto no projeto"; else ok "nenhum pacote remoto no projeto"; fi
if grep -q '\.package(url' Kit/Package.swift; then aviso "pacote remoto no Package.swift"; else ok "nenhum pacote remoto no Package.swift"; fi
achados=$(find . \( -name "*.xcframework" -o -name "*.framework" -o -name "*.a" -o -name "*.dylib" -o -name Podfile -o -name Cartfile \) -not -path "./build/*" -not -path "*/.build/*" -not -path "./.git/*" 2>/dev/null)
[ -n "$achados" ] && { aviso "binario ou gerenciador de terceiro"; echo "$achados"; } || ok "nenhum binario de terceiro"

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
divergentes=0
for idioma in $(sed -n 's/^ *"\([a-z_]*\)": "[0-9a-f]*".*/\1/p' wordlists.lock); do
    esperado=$(sed -n "s/^ *\"$idioma\": \"\([0-9a-f]*\)\".*/\1/p" wordlists.lock)
    atual=$(shasum -a 256 "$CORE/Resources/Wordlists/$idioma.txt" | cut -d' ' -f1)
    [ "$atual" != "$esperado" ] && { aviso "lista $idioma nao confere"; divergentes=$((divergentes + 1)); }
done
[ "$divergentes" = "0" ] && ok "as 10 listas BIP-39 conferem com wordlists.lock"

# 5. Registro e aleatoriedade.
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
achados=$(procurar 'AfterFirstUnlock|AccessibleAlways|SynchronizableAny|\.userPresence|\.devicePasscode|\.biometryAny|kSecAttrSynchronizable as String: kCFBooleanTrue' "$APP" "$KEYS")
[ -n "$achados" ] && { aviso "protecao fraca de chaveiro ou biometria"; echo "$achados"; } || ok "sem userPresence, devicePasscode, biometryAny, AfterFirstUnlock"
if ! grep -q 'kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly' "$KEYS/SecretStore.swift"; then aviso "WhenPasscodeSetThisDeviceOnly sumiu"; else ok "itens em WhenPasscodeSetThisDeviceOnly"; fi
# A unica excecao (simulador) precisa estar atras de targetEnvironment(simulator).
excecao=$(awk '/#if targetEnvironment\(simulator\)/{d=1} /#else|#endif/{d=0} /kSecAttrAccessibleWhenUnlockedThisDeviceOnly/{ if(!d) print FILENAME": "NR }' "$KEYS/SecretStore.swift")
[ -n "$excecao" ] && { aviso "classe de simulador fora do bloco de simulador"; echo "$excecao"; } || ok "a excecao do simulador so compila para simulador"
achados=$(awk 'FNR==1{d=0} /#if targetEnvironment\(simulator\)/{d=1} /#endif/{d=0} /SimulatorWrapper\(\)|SoftwareWrapper\(\)/{ if(!d) print FILENAME": "FNR": "$0 }' $(swift_em "$APP" "$KEYS"))
[ -n "$achados" ] && { aviso "embrulho em software fora do simulador"; echo "$achados"; } || ok "embrulho em software so no simulador e nos testes"
achados=$(swift_em "$CORE" "$CHAINS" "$KEYS" "$NET" | xargs grep -nE 'class (MemoryStore|SoftwareWrapper)\b' 2>/dev/null)
[ -n "$achados" ] && { aviso "duble de teste dentro do codigo que vai para o app"; echo "$achados"; } || ok "armazenamento em memoria e embrulho em software so existem nos testes"
achados=$(swift_em "$APP" "$KEYS" | xargs grep -n 'evaluatePolicy(' 2>/dev/null | grep -v 'canEvaluatePolicy' | grep -v "$APP/Services/KeyServices.swift")
[ -n "$achados" ] && { aviso "evaluatePolicy fora do simulador (booleano nao autoriza nada)"; echo "$achados"; } || ok "nenhum booleano de biometria autoriza operacao"

# 7. Plataforma.
secao "plataforma"
grep -q 'shouldAllowExtensionPointIdentifier' "$APP/App/PlatformGuards.swift" && grep -q '\.keyboard' "$APP/App/PlatformGuards.swift" \
    && ok "teclados de terceiros bloqueados" || aviso "bloqueio de teclado de terceiro sumiu"
grep -q 'willResignActiveNotification' "$APP/App/PlatformGuards.swift" && ok "cobertura antes da foto do seletor de apps" || aviso "cobertura do seletor sumiu"
grep -q 'NSFileProtectionComplete' "$APP/Resources/EscaliburWallet.entitlements" && ok "NSFileProtectionComplete em todo o conteiner" || aviso "protecao de arquivo sumiu"
chaves=$(/usr/libexec/PlistBuddy -c "Print" "$APP/Resources/EscaliburWallet.entitlements" | grep -E '^\s+[a-z]' | awk '{print $1}' | sort | tr '\n' ' ')
[ "$chaves" = "com.apple.developer.default-data-protection " ] && ok "entitlements: so a protecao de dados" || aviso "entitlements inesperados: $chaves"
achados=$(grep -oE 'NS[A-Za-z]+UsageDescription' "$APP/Resources/Info.plist" | sort -u | grep -vE 'NSFaceIDUsageDescription|NSCameraUsageDescription|NSMicrophoneUsageDescription|NSSpeechRecognitionUsageDescription')
[ -n "$achados" ] && { aviso "permissao fora da lista"; echo "$achados"; } || ok "permissoes: Face ID, camera, microfone e fala, nada mais"
achados=$(swift_em "$APP" | xargs grep -lE 'UIPasteboard' 2>/dev/null | grep -vE 'Receive/ReceiveSheet\.swift|NewWallet/ImportPhraseView\.swift')
[ -n "$achados" ] && { aviso "area de transferencia fora dos pontos conhecidos"; echo "$achados"; } || ok "area de transferencia so em dois pontos"
grep -q '\.localOnly' "$APP/Features/Receive/ReceiveSheet.swift" && grep -q '\.expirationDate' "$APP/Features/Receive/ReceiveSheet.swift" \
    && ok "endereco copiado e local e expira" || aviso "copia de endereco sem localOnly/expiracao"
achados=$(procurar '^[[:space:]]*import +(Firebase[A-Za-z]*|Crashlytics|Sentry|Bugsnag|Amplitude|Mixpanel|Segment|AppsFlyer[A-Za-z]*|Adjust[A-Za-z]*|Branch|OneSignal|Datadog[A-Za-z]*|NewRelic|Instabug|FBSDK[A-Za-z]*|GoogleMobileAds|PostHog)\b' "$APP" "$NET" "$CORE" "$CHAINS" "$KEYS")
[ -n "$achados" ] && { aviso "SDK de terceiro"; echo "$achados"; } || ok "nenhum SDK de analise, falha ou anuncio"
achados=$(procurar 'WKWebView|SFSafariViewController|UIWebView|ASWebAuthenticationSession' "$APP")
[ -n "$achados" ] && { aviso "navegador embutido"; echo "$achados"; } || ok "sem navegador embutido"

# 8. Modo de demonstracao so em depuracao.
secao "depuracao"
head -1 "$APP/App/DebugDemo.swift" | grep -q '^#if DEBUG' && ok "DebugDemo.swift inteiro atras de #if DEBUG" || aviso "DebugDemo.swift fora de #if DEBUG"
achados=$(awk 'FNR==1{d=0} /#if DEBUG/{d=1} /#endif/{d=0} /DebugDemo\./{ if(!d) print FILENAME": "FNR }' $(swift_em "$APP" | grep -v DebugDemo.swift))
[ -n "$achados" ] && { aviso "uso de DebugDemo fora de #if DEBUG"; echo "$achados"; } || ok "nenhum uso de DebugDemo fora de #if DEBUG"

# 9. Texto que o usuario le, sem travessao.
secao "texto"
achados=$(swift_em "$APP" | xargs grep -nE '"[^"]*(—|–)[^"]*"' 2>/dev/null)
[ -n "$achados" ] && { aviso "travessao em texto de interface"; echo "$achados"; } || ok "nenhum travessao em texto de interface"

# 10. Testes com vetores oficiais.
if [ "${1:-}" = "--testes" ]; then
    secao "testes"
    if (cd Kit && swift test 2>&1 | tail -1 | grep -q "passed"); then ok "testes do nucleo passam"; else aviso "testes do nucleo falharam"; fi
fi

echo
if [ "$falhas" = "0" ]; then echo "tudo conferido."; else echo "$falhas verificacao(oes) falharam."; fi
exit "$falhas"
