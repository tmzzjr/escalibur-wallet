# Segurança

## Como relatar uma vulnerabilidade

Use o GitHub Private Vulnerability Reporting deste repositório. Não abra issue pública para falha de segurança.

Prazos que assumimos:
- confirmação do recebimento em 72 horas;
- triagem em 7 dias;
- correção de falha crítica em 30 dias;
- divulgação coordenada em até 90 dias.

Pesquisa de boa-fé, dentro do escopo abaixo, não será tratada como violação. Não acesse fundos de terceiros, não degrade serviços de outras pessoas e não use engenharia social contra usuários ou contra a equipe.

## Escopo

Dentro:
- vazamento de frase, entropia, chave privada, PIN ou senha de envelope;
- contorno da validação do que se assina (plano de assinatura, allowlists, decodificação de calldata);
- falhas no formato do envelope `.esclbr` ou na sua abertura;
- contorno do PIN, da biometria ou do atraso progressivo;
- perda de fundos causada por provedor ou relay comprometido além do limite da tolerância de preço escolhida.

Fora:
- aparelho com jailbreak feito pelo próprio dono;
- coerção física;
- perfil de configuração ou certificado instalado pelo próprio usuário;
- ataques que exigem execução de código dentro do processo durante uma assinatura (risco aceito e descrito em `docs/seguranca.md`).

## O que conferir

- O modelo de ameaça e os riscos aceitos: [`docs/seguranca.md`](docs/seguranca.md).
- As afirmações verificáveis por script: `./tools/verificar.sh`.
- Os vetores oficiais de cada rede: `cd Kit && swift test`.
- O código de terceiro e seus digestos: `secp256k1.lock`, `argon2.lock`, `wordlists.lock`, `hosts.lock`.

## Limite declarado sobre o binário

O binário da App Store é recifrado pela Apple (FairPlay), então o usuário comum não consegue comparar sozinho o app instalado com este código. A conferência de build reproduzível exige o IPA decifrado, pela metodologia do WalletScrutiny.
