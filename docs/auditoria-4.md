# Auditoria 4 (16/10/2026)

Auditoria de segurança completa pedida pelo dono, com sete revisores em paralelo sobre a main 0a66578: cofre e PIN, seed e custódia, plataforma, golpes e o que o dono assina, transações e assinatura rede por rede, rede e cadeia de suprimentos, e um revisor-chefe que conferiu e consolidou. Dois recortes (transações, e rede e cadeia de suprimentos) foram refeitos numa segunda rodada. Nenhum achado crítico nem alto. Os números de linha abaixo são do commit auditado.

## Estado dos achados

### Médios

| Item | Achado | Estado |
|---|---|---|
| A1 | Revelar as palavras, lacrar um envelope e remover carteira pediam só o PIN, mesmo com o Face ID ligado. Quem viu o PIN levava a frase. | Feito. Com o Face ID ligado, pedem o PIN e o rosto (`RootKeyVault.unlockWithPINAndBiometry`, `AuthCoordinator.Presence.pinAndBiometry`), e desligar o Face ID também. O Face ID que cai (rosto novo cadastrado) deixa isso recusado até religar, e religar começa 24 horas de espera; Face ID indisponível recusa sem apagar nada. A revisão do conserto achou dois caminhos de volta ao "só PIN" (religar por cima do slot do dono, e o Face ID indisponível derrubando o slot), fechados antes do commit. |
| C7-01 | Carteira sem cópia confirmada recebia por Ajustes > Endereços e por "Minhas carteiras" no envio. | Feito. Os dois caminhos levam a "Gravar agora". |
| C7-02 | A carteira com passphrase herdava a cópia confirmada da carteira de base, e a passphrase nunca era conferida. | Feito. Nasce sem a passphrase conferida e só recebe depois de o dono digitá-la de novo, de onde anotou (`ConfirmPassphraseView`). A revelação mostra o espaço visível e a contagem; "Esqueci o PIN" e Remover citam a passphrase. |
| C7-03 / R7-M2 | O aviso de recebimento ligava sozinho e gravava, legíveis com o iPhone bloqueado, os endereços de todas as carteiras, inclusive a com passphrase. | Feito. Uma folha diz o preço antes do pedido de permissão; carteiras com passphrase e sem cópia ficam de fora do arquivo. A consulta de uma carteira por vez, em ordem sorteada, fica para depois. |
| C7-04 | A escada de espera do PIN parava em 3 horas por tentativa: cerca de 2.900 chutes por ano. | Feito. Dobra do nono erro em diante até 7 dias: 18 chutes em 30 dias, 66 em um ano. O apagar-após-N ligado por padrão continua decisão do dono. |
| C7-05 | Envelope ou frase de outra pessoa virava a carteira ativa, com o nome escolhido pelo remetente e sem aviso; a checagem de permissões da Tron prometida não era chamada. | Feito. A conferência antes de guardar pede o aceite de que quem deu as palavras controla a carteira, lê as permissões da Tron na rede, e a carteira do envelope não passa a ser a carteira em uso sozinha; nome repetido ganha "(envelope)". |
| C7-06 | O Espelhamento do iPhone no Mac passa pela guarda de captura, e a checagem dizia que a tela estava limpa. | Feito, no que dá: não há API para saber do espelhamento. A checagem diz "sem gravação nem AirPlay" e avisa do espelhamento, a revelação pede um quarto "estou ciente", e o A1 tira a frase de quem só viu o PIN. |
| C7-07 | Endereço salvo nascia sem conferência; o sósia de uma ponta só (2+6, 0+10) passava; as carteiras só de observação contavam como conhecidas. | Feito. Salvar um endereço passa pela comparação e pede 6 caracteres digitados olhando a fonte; uma ponta com 5 ou mais já marca; observação sai dos conhecidos; o aviso diz de onde o dono conhece o outro. A regra nova pegou um sósia real de um histórico da Tron gravado nos testes. |
| M1 | O endereço M da Stellar virava a conta base G mais o ID como memo, e o caminho muxed do planejador nunca era usado. | Feito. O M vai inteiro até a transação, sem memo, e a conferência do plano compara o M com o ID. |
| M2 | Trocas fora da Ethereum vão pela fila pública: um robô de sanduíche leva até a tolerância. | Em parte. A revisão diz, nas redes sem proteção e na Solana, que não há proteção contra robôs. Relay privado nessas redes e teto menor de tolerância ficam para depois. |
| R7-M1 | A conta da Escalibur na Alchemy guarda por 10 dias o endereço e os saldos de cada consulta. | Em parte. A Política de privacidade diz isso. Tirar a Alchemy do caminho padrão, ou conta só com chave de segurança e retenção desligada, é decisão do dono. |
| R7-M3 | Não há elo verificável entre o commit auditado e o binário: o CI não barra o push e o archive sai do Mac do dono. | Aberto, para decisão do dono: exigir o check no ruleset muda o fluxo de push direto na main; o archive reproduzível num workflow de release é um trabalho próprio. |

### Baixos

| Item | Achado | Estado |
|---|---|---|
| C7-08 | A documentação pública afirmava mais do que o código fazia (escada, `kern.bootsessionuuid`, K_dev no diagrama, revelação com biometria, 60 s, widgets, QR com frase). | Feito em docs/seguranca.md. |
| C7-10 | Ligar o Face ID com o PIN que disparava o apagar-após-N deixava a sessão aberta. | Feito. |
| C7-12 | O texto da importação prometia cada letra cifrada, mas as sugestões e o teclado mostram a palavra. | Feito. Texto corrigido, e o teclado BIP-39 próprio (opcional, sempre ligado no modo reforçado e na conferência para ligá-lo), revisado antes do commit: a revisão achou a conferência ainda no teclado do sistema, a troca de palavra de outro idioma no Seguinte e textos que prometiam demais, fechados antes do commit. |
| C7-09 | Não havia folha de recuperação por rede, e a tela prometia "qualquer carteira BIP-39". | Feito. Ajustes, na carteira, "Abrir em outro app": rede por rede, os apps que abrem a mesma conta, a armadilha de cada uma e quem aceita a passphrase, sem segredo nenhum (`RecoveryGuideView`). O texto da carteira criada e o da passphrase dizem o que vale. |
| C7-13 | QR com a frase não era recusado e ia em claro para o campo do destino. | Feito, no envio e em Endereços salvos, também para o SeedQR. |
| C7-19 / R7-B3 | O widget mostrava a moeda recebida com o aviso discreto. | Feito. |
| C7-20 | Remover carteira engolia a falha do chaveiro: a carteira saía da lista e a frase podia ficar. | Feito. |
| B5 | QR ou link de pagamento descartava a tag e o memo sem avisar. | Feito: `dt`, `text` e o memo do SEP-7 vão para o campo, com a nota de onde vieram. |
| N2 | As palavras não tinham o temporizador de 60 s que a documentação prometia. | Feito. |
| R7-B1 | Número JSON sem teto de dígitos virava parsing quadrático: um provedor congelava o app. | Feito. Teto de 78 dígitos no `BigUInt(decimal:)` e no `StrictJSON` (20 em `uint64`/`int64`). |
| R7-B2 | A referência de preço das trocas podia ser um preço velho. | Feito. Só preço com menos de 2 minutos vale como referência; mais velho força duas cotações. |
| B1 | A simulação da troca na Solana vinha de um RPC só. | Feito. Dois RPCs de operadores diferentes, os dois confirmando; o limite de CU é o maior. |
| B2 | O bloco das leituras EVM concordantes vinha de um provedor só. | Feito. A menor das pontas de dois provedores, recusando diferença grande. |
| B4 | Só o vetor 1 do BIP-32 e do SLIP-10 nos testes. | Feito. Vetores 1 a 4 do BIP-32 e 1 e 2 do SLIP-10, secp256k1 e Ed25519. |
| R7-B4 / C7-22 | O `verificar.sh` só olhava `.swift` e só procurava `DebugDemo.`. | Feito. Falha fonte não-Swift fora dos dois C vendorizados, fase de script, framework fora do SDK, flag de linker, `DEBUG` fora da configuração Debug, e argumento de inicialização lido fora de `#if DEBUG`. |
| Revisão do lote | A tag de um código lido antes ficava no campo, às vezes escondida; o link cortava parâmetros em 64 caracteres (o destino M quebrava); memo ID com zero à esquerda ou caractere invisível passava; a conferência ao salvar endereço se respondia olhando a tela; Celo e X Layer sem fila pública recebiam o aviso de robôs. | Feito: a tag sai com o destino novo, nada é cortado em silêncio, tag invisível ou ambígua é recusada, o trecho a digitar fica escondido na tela, e as duas redes saíram do aviso. |
| C7-11 | Buracos na guarda de captura. | Feito: a guarda nasce sabendo se a tela está sendo gravada, fecha o teclado quando a captura começa, e cobre a criação de carteira e a frase de voz. |
| C7-14 | A calibração do envelope nunca media. | Feito: sonda com 2 passes, dividida por 2, e um teste que falha se ela lançar erro. |
| C7-15 | O campo seguro contava bytes. | Feito: conta e apaga por caractere. |
| C7-16 | Idioma da frase gravado como posição no enum. | Feito: códigos fixos, os mesmos do `decifrar.py`, com teste e um registro em português. |
| C7-17 | Colar 13 palavras preenchia as 12 primeiras. | Feito: contagem fora do padrão não preenche nada e diz quantas vieram. |
| C7-18 | O tipo `.esclbr` era só importado, com prioridade Alternate. | Feito: exportado, dono. |
| C7-21 | Segredos em memória por mais tempo. | Feito no cofre: senha do SE zerada e contextos invalidados. A frase durante a escolha da senha do envelope continua em memória. |
| B3 | Ed25519 deixava intermediários do segredo no heap. | Feito: área de trabalho fixa, zerada; o estado do SHA-512 fica como limite documentado. |
| B-4, B-8, B-10 (revisão do envio) | Link de outra rede aceito na tela de Bitcoin; frase colada em campo de endereço; nenhum teste do M até o XDR. | Feito. |
| C7-23, B-5, B-6, B-9 | Enhanced Security e pilha zerada no C; sósias de ponta curta onde a tela come o prefixo; troca só do ID num M; contas com nome da NEAR. | Em revisão, em ramos à parte. |

## Depois: o modo reforçado

O que o A1 não cobre (o PIN sozinho envia o saldo, e com o Face ID desligado o PIN abre tudo) ficou com o modo reforçado da §2.6, ligado pelo dono em Ajustes, Segurança: abrir o app, toda assinatura e ver as palavras pedem o PIN e o rosto, e o "e" é da criptografia, num slot só (`rk.and`) com duas chaves do Secure Enclave em camadas. Foi desenhado e revisado em duas rodadas pelo agente de segurança antes do commit. A revisão achou e fechou: a varredura sem trava que podia inutilizar o cofre numa troca de PIN, o "cofre perdido" declarado sem prova, a passphrase com acento que nunca conferia, a frase inteira virando texto na memória, a conferência de três palavras (agora a frase inteira, comparada pela entropia dentro do cofre), e a passphrase gravada fora de NFKD por versões anteriores, que mudaria a conta da Cardano numa restauração. O limite que fica está na doc: quem executa código no aparelho testa o PIN sem o rosto, e com o rosto do dono uma vez abre no tempo de sempre.

## Conferido e sólido

Cofre: RK aleatória embrulhada no SE com senha derivada do PIN, nenhum verificador de PIN, contador gravado antes de avaliar, chaveiro todo `WhenPasscodeSetThisDeviceOnly`, K_bio com `biometryCurrentSet`, troca de PIN atômica. Envelope: AEAD com piso de 256 MiB e erro único. As dez listas BIP-39 idênticas às oficiais. Ponte, por amostra: calldata montada e conferida no app, destinatário e depositante iguais ao dono, tetos de taxa compilados, simulação em duas fontes. Rede: só https, host exato contra o `hosts.lock`, sem redirecionamento, corte em 4 MB, consenso de duas fontes no que decide dinheiro. O código C vendorizado e as listas BIP-39 são idênticos aos de origem, byte a byte. As ações do CI estão fixadas por SHA. Os 1.383 testes do Kit passavam no commit auditado.

## O que ninguém conferiu

O que depende de aparelho: o comportamento do Espelhamento do iPhone com o Face ID, o primeiro quadro da guarda de captura, o teclado com acentos e CJK, o desempate do tipo `.esclbr`. O binário do build 3 (só o IPA do build 1 foi aberto). O processo real de archive e envio no Mac do dono.
