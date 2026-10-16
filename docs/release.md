# Release: da tag assinada ao TestFlight

O build que vai para a Apple sai do `.github/workflows/release.yml`, num runner limpo da GitHub, a partir de uma tag assinada pelo dono, e não do Mac de ninguém. É a parte do R7-M3 (auditoria 4) que dá para fechar: um elo verificável entre o commit auditado e o arquivo enviado à Apple.

## Uma vez só

No Mac do dono, a chave que assina as tags (com senha; se houver chave de segurança física, `-t ed25519-sk` deixa a privada presa nela):

```
ssh-keygen -t ed25519 -C "thomaz@xtech.international escalibur-release" -f ~/.ssh/escalibur_release
git config gpg.format ssh
git config user.signingkey ~/.ssh/escalibur_release.pub
```

A chave pública vai, numa linha, para `.github/assinantes` (o formato está no próprio arquivo), num commit que entra na main antes da primeira tag, e é cadastrada na GitHub como chave de assinatura, para a tag aparecer como verificada.

No GitHub:
- environment `release`, com o dono como revisor obrigatório e só as tags `testflight-*` e `v*` como origem; nele, e só nele, os segredos `ASC_KEY_ID`, `ASC_ISSUER_ID` e `ASC_KEY_P8`;
- a regra da main exige o check `verificar` antes de qualquer commit entrar;
- uma regra de tags em que só o dono cria, move ou apaga `testflight-*` e `v*`.

## Assinar a tag

Cada release, num commit que já está na main:

```
git tag -s testflight-1.0.0-4 -m "TestFlight 1.0.0 (4)" <commit>
git tag -v testflight-1.0.0-4
git push origin testflight-1.0.0-4
```

- `1.0.0` tem de ser o `MARKETING_VERSION` do `project.yml` e do projeto gerado; o workflow recusa outro.
- `4` é o número do build (`CFBundleVersion`). Vale o da tag, passado ao `xcodebuild` como `CURRENT_PROJECT_VERSION=4`; o `CURRENT_PROJECT_VERSION` do `project.yml` fica para os builds locais. A App Store Connect recusa número repetido.
- `v1.0.0-N` segue o mesmo formato e o mesmo caminho, para quando houver build direto para a revisão. Mandar para a revisão um build que já está no TestFlight não precisa de tag nova.
- Depois do push, o run para no job `montar` esperando o dono aprovar o environment `release` (Actions, o run, Review deployments). Só então os segredos existem para o runner.

## O que o workflow prova

1. A tag é anotada, assinada por uma chave de `.github/assinantes` do próprio commit (`git tag -v` com `gpg.minTrustLevel=fully`), e aponta para um commit que está na main. Sem chave no arquivo, nenhum release roda.
2. Esse commit passou pelo mesmo `verificar.yml` que confere a main: o verificador, os testes do núcleo, o app em Release e o envelope.
3. O `.ipa` foi montado desse commit num runner `macos-26` limpo, com o Xcode do `.xcode-version` e o projeto do repositório, sem certificado nem chave privada de assinatura de código no runner: quem assina é a nuvem da Apple (certificado de distribuição gerenciado), acionada pela chave da API.
4. A assinatura que sai é de distribuição da equipe `2UNWMDD93S`, com os entitlements dos arquivos `.entitlements` do repositório e nada além dos que a Apple põe (`tools/conferir-entitlements.py`), sem `get-task-allow`, com o build da tag e sem nada do modo demo no binário.
5. O SHA-256 do `.ipa`, do binário principal e do binário principal sem a assinatura vai para `SHA256SUMS`, no resumo do run e no artefato `digestos-<tag>` (90 dias), com o `release.txt` (tag, commit, run, Xcode, imagem do runner).
6. Uma atestação de proveniência (SLSA, `actions/attest`) liga esses três digestos ao repositório, ao `release.yml`, ao commit e à tag. Ela é assinada pela Sigstore pública e fica registrada no log de transparência dela, que não expira com o run.
7. O arquivo enviado à App Store Connect (`altool --upload-package`) é o mesmo do digesto: o workflow confere antes de enviar.

A chave da API é uma chave de equipe (Team Key) com o papel Admin: a Apple só deixa Account Holder e Admin assinarem com certificado gerenciado pela nuvem, e chave individual não usa os endpoints de provisionamento. Admin também administra usuários, por isso ela só existe no environment `release`, que pede a aprovação do dono, e sai do runner no fim de cada passo que a usa.

## O que não prova

- **Que o app da App Store é este `.ipa`, byte a byte.** A Apple troca a assinatura pela dela, recifra o executável com FairPlay e entrega a cada aparelho uma versão afinada dos recursos (App Thinning). O usuário comum não consegue comparar nada sozinho.
- **Que o build é reproduzível.** Ninguém compilou o mesmo commit duas vezes e comparou. O workflow registra o que montou; que outro build do mesmo commit dê o mesmo executável é afirmação a conferir (docs/seguranca.md, §8.5).
- **Que o código está certo.** A atestação prova de onde o binário veio, não que ele não tem falha.
- **Que ninguém mais envia builds.** Quem tiver a chave da API, ou entrar na conta da App Store Connect, envia build de qualquer lugar. A diferença é que esse build não tem atestação nem tag assinada: build sem as duas não saiu daqui.
- **Que a chave de assinatura das tags não vazou** e que o dono não foi coagido. A regra das tags (só o dono cria `testflight-*` e `v*`) e a aprovação do environment estreitam isso; chave vazada sai de `.github/assinantes` de vez.
- **Que a lista de assinantes é a de sempre.** Ela vem do próprio commit da tag: quem põe um commit na main e aprova o environment (o dono, ou quem tiver o acesso de administrador dele) também troca a lista. A troca fica no histórico público da main, e é o primeiro arquivo que um auditor deve olhar entre duas tags.

## O que um auditor confere

- **A origem de um build:** `release.txt` e `SHA256SUMS` do run (ou o resumo dele) dizem tag, commit e digestos; `gh attestation verify`, abaixo, confere que foi este workflow, neste commit.
- **O app instalado contra o build atestado:** com um iPhone de pesquisa (jailbreak) e uma ferramenta que extrai o executável decifrado, pela metodologia do WalletScrutiny. Tirar a assinatura da cópia (`codesign --remove-signature`) e comparar o SHA-256 com a linha `EscaliburWallet.sem-assinatura`, ou passar o arquivo direto no `gh attestation verify`. Se bater, o app da loja é o executável deste run. Se não bater, a diferença tem de ficar no que a Apple e a ferramenta mexem (assinatura e o campo `cryptid`); até hoje ninguém fez essa comparação, e o primeiro resultado vai para cá.
- **O código contra o build:** compilar a tag com o mesmo Xcode (`xcodebuild archive ... CURRENT_PROJECT_VERSION=N CODE_SIGNING_ALLOWED=NO`, como no workflow) e comparar o executável com o `sem-assinatura`. Pode diferir (caminhos, ordem de ligação); sem o build duplo do §8.5, isso não está provado.
- **Fora do alcance:** os recursos afinados que cada aparelho recebe, o que a Apple faz na revisão e na distribuição, e o que acontece na conta da App Store Connect.

## Conferir uma atestação

Com o arquivo na mão (o `.ipa`, o executável, ou o `sem-assinatura` de um app decifrado):

```
gh attestation verify EscaliburWallet.sem-assinatura \
  --repo tmzzjr/escalibur-wallet \
  --signer-workflow tmzzjr/escalibur-wallet/.github/workflows/release.yml \
  --source-ref refs/tags/testflight-1.0.0-4 \
  --deny-self-hosted-runners
```

`--source-digest <commit>` amarra também o commit. Sem o arquivo, só com o digesto: `gh api repos/tmzzjr/escalibur-wallet/attestations/sha256:<digesto>` lista as atestações dele, e `gh attestation download` guarda o pacote, que depois confere com `--bundle`.

## Se o export recusar

O archive sai sem assinatura e recebe, pelo `codesign`, uma assinatura local com os entitlements do repositório, para o export da nuvem saber o que o app pede. Isso não foi testado de ponta a ponta antes do primeiro release. Se a Apple recusar esse archive, ou o `.ipa` sair com outros entitlements (o `conferir-entitlements.py` para o release antes do envio), o caminho é um certificado Apple Development de longa duração, em `.p12`, como quarto segredo do environment `release`, importado num keychain temporário só para o archive.
