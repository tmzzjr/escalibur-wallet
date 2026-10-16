#!/usr/bin/env python3
"""Confere os entitlements de um app assinado contra os .entitlements do repositorio.

Uso: python3 -I tools/conferir-entitlements.py Payload/EscaliburWallet.app

O release.yml roda isto no app de dentro do .ipa exportado, antes dos digestos e do
envio (docs/seguranca.md, secao 8.3, regra 18). Para o app e para o widget:
- cada chave do .entitlements do repositorio esta na assinatura, com o mesmo valor;
- fora delas, so as que a Apple poe na assinatura de distribuicao, com o valor certo
  (identificador do app, equipe, beta-reports-active, get-task-allow falso e o grupo de
  chaveiro do proprio app);
- qualquer outra chave (aps-environment, icloud-*, ubiquity-*, grupo de outro app,
  get-task-allow verdadeiro) para o release.
Quem audita roda o mesmo num app exportado ou decifrado. So biblioteca padrao.
"""
import pathlib
import plistlib
import subprocess
import sys

RAIZ = pathlib.Path(__file__).resolve().parent.parent
EQUIPE = "2UNWMDD93S"
# (caminho dentro do .app, .entitlements do repositorio, bundle id)
ALVOS = [
    ("", "App/EscaliburWallet/Resources/EscaliburWallet.entitlements", "app.escalibur.wallet"),
    ("PlugIns/EscaliburWidgets.appex", "App/EscaliburWidgets/EscaliburWidgets.entitlements", "app.escalibur.wallet.widgets"),
]


def da_apple(bundle):
    """As chaves que a assinatura de distribuicao acrescenta, e o unico valor aceito."""
    return {
        "application-identifier": f"{EQUIPE}.{bundle}",
        "com.apple.developer.team-identifier": EQUIPE,
        "beta-reports-active": True,
        "get-task-allow": False,
        "keychain-access-groups": [f"{EQUIPE}.{bundle}"],
    }


def assinados(caminho):
    saida = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(caminho)],
                           capture_output=True, check=False)
    if saida.returncode != 0:
        sys.exit(f"{caminho}: codesign nao leu a assinatura ({saida.stderr.decode(errors='replace').strip()})")
    return plistlib.loads(saida.stdout) if saida.stdout.strip() else {}


def conferir(app):
    falhas = []
    for dentro, arquivo, bundle in ALVOS:
        alvo = app / dentro if dentro else app
        esperados = plistlib.loads((RAIZ / arquivo).read_bytes())
        apple = da_apple(bundle)
        atuais = assinados(alvo)
        nome = dentro or app.name
        for chave, valor in esperados.items():
            if chave not in atuais:
                falhas.append(f"{nome}: falta {chave} (esta em {arquivo})")
            elif atuais[chave] != valor:
                falhas.append(f"{nome}: {chave} = {atuais[chave]!r}, o repositorio diz {valor!r}")
        for chave, valor in atuais.items():
            if chave in esperados:
                continue
            if chave not in apple:
                falhas.append(f"{nome}: {chave} = {valor!r} nao esta em {arquivo} nem e da assinatura da Apple")
            elif valor != apple[chave]:
                falhas.append(f"{nome}: {chave} = {valor!r}, o aceito e {apple[chave]!r}")
        for chave in ("application-identifier", "com.apple.developer.team-identifier"):
            if chave not in atuais:
                falhas.append(f"{nome}: falta {chave}: nao e uma assinatura de distribuicao")
        print(f"{nome}: " + ", ".join(sorted(atuais)), flush=True)
    return falhas


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("uso: conferir-entitlements.py <EscaliburWallet.app>")
    falhas = conferir(pathlib.Path(sys.argv[1]))
    if falhas:
        print("\n".join(falhas), file=sys.stderr)
        sys.exit(f"{len(falhas)} divergencia(s) nos entitlements")
    print("entitlements do app e do widget conferem com o repositorio")
