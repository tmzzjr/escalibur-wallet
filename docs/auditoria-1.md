# Auditoria de segurança 1 (agente de segurança, 2026-09-26, main em b7bbdec)

Nenhum achado crítico alcançável (nenhum motor de envio ligado). O que pode virar crítico: o spike da senha de aplicativo (MUST 1).

Desvios do desenho: D1 revelar/exportar só com Face ID (alta); D2 envelope podia nascer com 64 MiB e senha fraca (alta); D3 furos da voz (média); D4 tempo de bloqueio e apagar-após-10 sem PIN (média); D5 lista de bloqueio do PIN sem datas (média); D6 detecção de endereço parecido incompleta e não bloqueante (média, latente); D7 revisão mostra a intenção e não o plano (média, latente); D8 segredo em String em BIP-39, 25ª palavra, PasswordCost, comparações (média); D9 menores.
Bugs: L1 consenso falha aberto com 1 provedor; L2 bloqueio por relógio de parede; L3 contador não zera com Face ID, `.wiped` sem apagar metadados; L4 limpeza da primeira instalação destrutiva com leitura falha; L5 erro do chaveiro vira "não existe" e cadastro apaga K_dev; L6 qualquer falha do Face ID destrói o slot; L7 senha de aplicativo retida no LAContext; L8 contatos sem autenticação; L9 DEK e bloco do envelope sem zerar; L10 escrita dentro de leitura e boot por Double; L11 troca de PIN pode apagar o único slot; L12 cadastro deixa slot órfão; L13 limite de 4 MB sem Content-Length; L14 miudezas.
verificar.sh: falso positivo "Segment"; `#else` no awk do embrulho; padrões faltando (WhenUnlocked sem ThisDeviceOnly, `.or`, `contentsOf:`, `.binaryTarget(`); regras 12, 15, 17, 22, 24 ausentes; sem CI.
MUST em aberto: (1) spike da senha de aplicativo em iOS 17, 18 e 26 físicos; (2) PIN para revelar, exportar e remover; (3) envelope com piso 256 MiB e senha forte; (4) BIP-39 sobre bytes; (5) datas na lista de bloqueio; (6) onboarding diz a verdade sobre ThisDeviceOnly; (7) sceneCaptureState e traços dos campos de palavra; (8) CI; (9) antes de ligar motores: L1, D6, D7, eth_chainId, simulação; (10) relay ou aviso na tela de rede; (11) fixture carteira → decifrar.py no CI.

## Estado dos achados (2026-09-26, main em 3f15b12)

| Item | Estado | Onde |
|---|---|---|
| MUST 1, spike da senha de aplicativo | Pendente, precisa de iPhone físico (iOS 17, 18, 26). O desenho deixou de depender dele: a RK vai cifrada por HKDF(AP) dentro do embrulho do SE. O simulador não aplica a senha de aplicativo, e o teste de interface confere que o PIN errado é recusado pela camada interna. | 81df923 |
| D1, revelar, exportar, remover | Feito: PIN obrigatório (`requirePIN`), Face ID não basta | 81df923 |
| D2, envelope | Feito: piso de 256 MiB no próprio `VaultFile.create`, senha com 60 bits no `Envelope.seal`, 6 palavras sorteadas como padrão | fabf0ba |
| D3, voz | Feito: voz no envelope, PIN para mudar, pausa após 3 desafios, sem cotação pede voz, comparação em tempo constante | bb9d768 |
| D4, bloqueio automático e apagar após 10 | Feito: 0, 30 ou 60 s no relógio monotônico; alongar e mudar o apagamento pedem PIN | 81df923 |
| D5, datas no PIN | Feito: DDMMAA, MMDDAA e AAMMDD (8,9% do espaço bloqueado). Revertido em 2026-09-26 por decisão do dono: não há mais lista de PINs fáceis, qualquer PIN de 6 dígitos vale (docs/seguranca.md) | 81df923 |
| D6, endereço parecido | Feito: prefixo de cada rede ignorado, contatos, todas as carteiras e histórico; só segue digitando os 6 últimos | bdff9bd |
| D7, revisão mostra o plano | Feito: `review.recipient` e `recipientTag` em todo planejador, conferidos antes de revisar e antes de assinar; envio e troca mostram o plano | bdff9bd, 345af63 |
| D8, segredo em String | Feito: BIP-39 sobre os bytes, 25ª palavra em buffer e NFKD na importação, sal em buffer, `PhraseDraft` só com as 3 palavras, `PasswordStrength` sobre os bytes, `VaultFile` só com os caminhos de buffer | 050eb1c, 283ae84 |
| D9, menores | Feito: endereços e impressão digital antes de importar, Face ID conferido ao ligar, `sceneCaptureState`, tipo do envelope importado e alternativo, receber bloqueado sem cópia, campos de palavra sem teclado esperto | 2fb3082, 3ac8b58 |
| L1 a L14 | Feitos | 81df923, bdff9bd, bb9d768, 0226636, 3f15b12 |
| verificar.sh e CI | Feitos: regras 12, 15, 17, 22 e 24, `#else`, `.binaryTarget(`, `contentsOf:`, `WhenUnlocked`, `.or`; CI roda verificador, testes e carteira → decifrar.py | 283ae84 |
| MUST 9, antes de ligar motores | Feito: L1, D6, D7, `eth_chainId` em todo caminho EVM, simulação da transação exata em dois provedores no envio de token e na troca | bdff9bd, 69a119b |
| MUST 10, IP visível aos nós | Feito como aviso na tela de redes; o relay próprio fica para quando o dono aprovar um servidor | 3ac8b58 |
| MUST 11, carteira → decifrar.py | Feito: `tools/conferir-envelope.sh` no CI | 283ae84 |
