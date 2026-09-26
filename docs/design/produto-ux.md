Especificação completa de produto e UX da Escalibur Wallet abaixo. Não criei nenhum arquivo no projeto.

Três pontos pedem decisão sua antes de implementar:
1. **O painel de custo que o brief pede já foi tirado do Escalibur.** O commit b2e228e (12/09) removeu os painéis de custo de ataque da interface por decisão do Thomaz. Hoje o CipherField mostra só a faixa de comprimento (curta, média, longa). Por isso desenhei uma frase só, com um número só, e não a tabela de três atacantes do README.
2. **"Senha da carteira" colide com "senha do envelope".** Mantive o termo do Thomaz, mas criei um glossário fixo: a palavra "senha" nunca aparece sozinha, e o app recusa senha de envelope feita com palavras da própria frase.
3. **Valor à direita na lista de ativos contraria a skill.** A skill proíbe "tabela de número à direita". A lista de ativos estilo OKX tem valor à direita. Tratei como convenção do domínio: linha de duas alturas, sem cabeçalho de coluna e sem filete.

---

# Escalibur Wallet: produto e UX

## 0. Premissas

**A tarefa, em uma frase:** a pessoa quer mover dinheiro de verdade (enviar, trocar, receber) sem nunca mandar para o lugar errado e sem perder a única chave que existe.

**Custo do erro:** perda total e irreversível. Não existe estorno, suporte que desfaça ou "esqueci minha senha". Por isso a fricção entra só em quatro momentos: criar a cópia, revelar a frase, conferir o destino e assinar. Todo o resto sai do caminho.

**Convenções.** `{chaves}` são variáveis. Valores de exemplo: carteira "Carteira principal", total R$ 48.312,07, taxa da Escalibur 0,3% (o valor real é decisão comercial). Todo texto entre aspas é microcopy final.

### Glossário fixo (a interface nunca varia estes nomes)

| Nome na tela | O que é | Nunca chamar de |
|---|---|---|
| PIN | 6 dígitos. Destrava o app e confirma envios quando o Face ID falha | senha, senha do app |
| Senha da carteira | As 12 ou 24 palavras BIP-39. Na primeira menção de cada tela vem com o número: "a senha da carteira, as 12 palavras" | seed, frase semente, mnemônico, chave privada |
| Senha do envelope | Abre um `.esclbr`. No Escalibur ela se chama "senha do cofre", e a tela de abrir diz isso | senha, senha do cofre (aqui) |
| Envelope Escalibur | O arquivo `.esclbr` | backup, arquivo de backup |
| Tag de destino | XRP Ledger | memo, tag (sozinho) |
| Memo | Stellar | tag |
| Reserva | XRP ou XLM que a rede prende enquanto a conta existe | saldo mínimo, depósito |
| Taxa da rede | Gas, fee | gas, taxa de gás |
| Taxa da Escalibur | A taxa própria | comissão, spread |
| Tolerância de preço | Slippage | slippage, derrapagem |
| Impacto no preço | Price impact | |
| Autorização | Approve de token | approve, allowance |
| Rede | Chain | chain, blockchain |
| Trocar | Swap, sempre. Qualquer outra mudança usa "mudar" ("Mudar o PIN") | converter, swap |
| Só observar | Watch-only | somente leitura |

### Direção visual (herdada do Escalibur, só o que muda)
- **Tokens do Escalibur como estão.**
  - Fundo `#0B0B0C`, superfície `#151518`, tinta em três cinzas, vermelho `#FF4D3D`.
  - Branco é o único acento: botão principal, seleção e foco.
  - SF Pro em quatro papéis: 40 heavy com tracking -1,6 para o total, 24 bold para título, 15 para corpo, 13 para apoio.
  - Raio 12 em superfície e 14 em botão.
- **Duas cores novas, só para variação de preço.** Verde para alta e o mesmo vermelho para queda. Nenhum outro elemento usa verde. Queda e erro dividem o vermelho sem conflito: variação é sempre número com sinal, erro é sempre frase.
- **Números.** SF Pro com algarismos tabulares (`.monospacedDigit()`), para o valor não tremer ao atualizar. Isso não é fonte monoespaçada: é a mesma família do texto. SF Mono só em endereço, hash e palavras da frase.
- **Sinal negativo.** Sinal de menos (U+2212) ou hífen, nunca meia-risca. É o erro mais comum em valor negativo.
- **Listas.** Linha de 64 pt, sem filete. As seções se separam por espaço (28 pt) e por superfície.
- **Um material claro, com um significado só.** A placa cor de papel do Escalibur aparece apenas no que se confere caractere por caractere:
  - as palavras da frase;
  - o QR com o endereço em Receber;
  - o bloco destino mais tag na revisão de envio.

  A pessoa aprende em dois usos: placa clara quer dizer "confira letra por letra".
- **Logos reais embarcados no app.** Não baixar logo de CDN por endereço de contrato: o pedido conta ao CDN quais tokens a carteira tem.
  - O selo da rede tem 14 pt, fica no canto inferior direito do logo e leva um anel da cor do fundo.
  - Token sem logo ganha círculo cinza com a inicial, nunca cor sorteada.
- **Tema escuro só, na v1.**

---

## 1. Arquitetura de informação

**Tab bar com quatro abas:** Carteira · Trocar · Atividade · Ajustes.
- "Ajustes" é o termo do iOS em português.
- "Trocar" é o verbo que a pessoa usa.
- Não há aba de mercado, "Descobrir" ou dApps (ver cortes).

**A carteira selecionada vale para o app inteiro.**
- O seletor (nome com chevron) fica no topo de Carteira, Trocar e Atividade.
- Fica no topo de propósito: ele é identidade, não ação, e muda pouco.
- Estar nas três abas impede trocar a partir da carteira errada.

```
Carteira
  Detalhe do ativo  →  Detalhe da transação
  Gerenciar ativos
  [Enviar]  [Receber]  [Trocar]        (modais)
Trocar
  Agora | Ordem limite
  Ordens abertas  →  Detalhe da ordem
Atividade
  Pendentes, histórico  →  Detalhe da transação
Ajustes
  Carteiras → Carteira → Ver a senha da carteira / Guardar num envelope / Endereços / Remover
  Segurança → PIN, Face ID, Confirmação por voz, Bloquear o app, Apagar após erros, Autorizações ativas
  Contatos
  Abrir um envelope
  Moeda, Idioma, Redes, Provedores de troca
  Sobre → Taxas, Código aberto, Auditorias, Versão
```

**Como cada tela se apresenta:**
- **Tela cheia, sem fechar por gesto:**
  - criar e importar carteira;
  - gravar, confirmar e revelar a frase;
  - lacrar e abrir envelope;
  - Enviar;
  - revisão de troca e coleta de assinaturas.

  Mesma decisão do Escalibur: um deslize acidental não pode abandonar uma assinatura no meio.
- **Folha:** seletor de carteiras, Receber, escolher token, taxa, tolerância, rota, validade, filtros.
- **Push:** detalhes e telas de Ajustes.

**Entrada externa.** Um `.esclbr` aberto pelo Arquivos ou pelo AirDrop destrava o app e cai direto em V2b. Declarar o mesmo UTType do Escalibur.

---

## 2. Telas

Cada tela traz objetivo, hierarquia em ordem, ações (a primária sempre no rodapé), estados e copy.

### A. Acesso

**A1 Boas-vindas** (só na primeira abertura)
- Objetivo: dizer o que é o app e começar.
- Hierarquia: marca, título, uma frase, rodapé legal.
- Copy:
  - Título "Uma carteira que só você abre".
  - Texto "As chaves ficam neste iPhone. Sem conta e sem e-mail: a Escalibur não tem como ver, mover nem recuperar o seu saldo."
  - Botão "Começar".
  - Rodapé "Ao continuar, você aceita os Termos de uso e a Política de privacidade."
- Com jailbreak detectado (não bloqueia): "Este iPhone parece ter jailbreak. Apps de fora da App Store podem ler o que este app guarda."

**A2 Criar PIN** (reusa o LockView)
- Copy:
  - "Escolha um PIN" / "Seis dígitos para destravar o app e confirmar envios quando o Face ID falhar."
  - Depois, "Repita o PIN" / "Os mesmos seis dígitos."
- Erros:
  - "Os dois não conferem. Escolha de novo."
  - PIN da lista dos 20 mais usados: "Este PIN está entre os 20 mais usados. Escolha outro."
- Rodapé fixo: "O PIN não recupera a carteira. Se você esquecer o PIN, a senha da carteira traz tudo de volta."

**A3 Face ID**
- Copy:
  - Título "Destravar com o Face ID".
  - Texto "Destrava o app e confirma envios em 1 segundo. Se o Face ID falhar, o PIN vale."
  - Primário "Usar o Face ID". Secundário "Agora não".
- Aparelho sem biometria: a tela é pulada.
- Permissão negada: "O Face ID está desligado para a Escalibur Wallet nos Ajustes do iPhone. Enquanto isso, o PIN vale para tudo." Botão "Abrir Ajustes do iPhone".

**A4 Bloqueio**
- Hierarquia: marca, "Digite o seu PIN", pontos, teclado com tecla do Face ID, botão de texto "Esqueci o PIN". O Face ID dispara sozinho quando a tela aparece.
- Erros:
  - "PIN incorreto."
  - Do 3º erro em diante: "PIN incorreto. Mais {2} tentativas antes de uma espera de 1 minuto."
  - Em espera: "Tentativas demais. Tente de novo em {4 minutos}."
  - Com "apagar após erros" ligado, do 7º em diante: "PIN incorreto. Depois de mais {3}, as carteiras deste iPhone são apagadas."
- "Esqueci o PIN" abre uma folha:
  - Título "Não existe redefinir o PIN".
  - Texto "O PIN mora só neste iPhone. Para voltar a usar o app, apague as carteiras deste aparelho e importe de novo, com a senha de cada carteira ou com um envelope Escalibur."
  - Botão destrutivo "Apagar as carteiras deste iPhone".
  - Diálogo de confirmação: "Apagar {3} carteiras deste iPhone?" / "Sem a senha de cada carteira, o saldo delas fica inacessível para sempre." / "Apagar" / "Cancelar".

### O. Carteira nova

**O1 Adicionar carteira**
- Objetivo: escolher de onde vem a carteira.
- Hierarquia: as três importações ficam como linhas no meio, e "Criar" é o primário no rodapé, porque quem abre pela primeira vez quase sempre cria.
- Título: "Sua primeira carteira" na primeira vez, "Adicionar carteira" nas seguintes.
- Linhas:
  - "Importar com a senha da carteira" / "Você já tem 12 ou 24 palavras de outra carteira."
  - "Importar de um envelope Escalibur" / "O arquivo .esclbr e a senha do envelope."
  - "Só observar um endereço" / "Acompanhe um saldo sem poder enviar."
- Primário: "Criar carteira nova".

**O2 Antes de ver as palavras**
- Título "Antes de ver as palavras".
- Texto "A senha da carteira são {12} palavras, em ordem. Quem tiver as palavras tem o saldo. Sem elas, ninguém recupera a carteira, nem a Escalibur."
- Três fatos:
  - "Leva cerca de 2 minutos."
  - "Anote no papel, à mão. Captura de tela vai para a Fototeca e sobe para o iCloud."
  - "Aparecem 3 palavras por vez, por 60 segundos."
- Seletor "12 palavras" | "24 palavras", com a nota "12 bastam. 24 dá a mesma proteção na prática e dobra o que anotar."
- Primário "Mostrar as palavras".

**O3 Grave a senha da carteira**
- Objetivo: anotar 3 palavras.
- Hierarquia:
  - título e posição;
  - placa clara com 3 linhas (número da posição e palavra em mono grande);
  - barra de tempo dentro da placa;
  - navegação no rodapé.
- Copy:
  - Título "Grave a senha da carteira". Subtítulo "Palavras 1 a 3 de 12".
  - Na placa: "Esconde em {42} s".
  - Rodapé: secundário "Anteriores" (some na primeira página), primário "Próximas". Na última página, o primário vira "Já anotei as 12".
- Estados:
  - **Tempo esgotado:** a placa cobre as palavras com "Escondidas para ninguém ler por cima do seu ombro." e um botão "Mostrar de novo". Não pede autenticação: a carteira ainda está vazia.
  - **Tela gravada ou espelhada** (`isCaptured`): "A tela está sendo gravada ou espelhada. As palavras voltam quando isso parar."
  - **Captura detectada:** folha "Você fez uma captura de tela" / "A captura está na Fototeca e pode já ter subido para o iCloud. Apague a foto agora. Se ela já sincronizou, o mais seguro é criar outra carteira antes de receber qualquer valor." / primário "Criar outra carteira" / secundário "Já apaguei".
  - **App em segundo plano:** as palavras escondem e o tempo reinicia.
- Não existe: copiar, exportar PDF, "mostrar todas".

**O4 Confirme a senha da carteira**
- Mecânica:
  - 3 posições sorteadas (4 em 24 palavras), uma de cada terço da frase.
  - A pessoa **digita** cada palavra, com a bancada de sugestões do Escalibur.
  - Não uso chips de múltipla escolha: com 3 opções, o chute acerta 1 em 3, e o teste mede reconhecimento, não o papel.
- Copy:
  - Título "Confirme a senha da carteira". Linha "Digite a palavra 7". Progresso "1 de 3".
  - Primário "Confirmar".
  - Erro "Não é a palavra 7. Confira a posição 7 no seu papel."
  - Depois de 2 erros na mesma posição aparece o secundário "Ver as palavras de novo", que volta ao grupo dessa posição.

**O5 Carteira criada**
- Título "Carteira criada".
- Texto "Endereços prontos em {6} redes. Guarde o papel longe do iPhone: se o iPhone sumir, o papel traz a carteira de volta, aqui ou em qualquer carteira BIP-39."
- Campo "Nome da carteira", já preenchido: "Carteira principal" na primeira, depois "Carteira 2" e assim por diante.
- Secundário "Guardar também num envelope Escalibur". Primário "Ir para a carteira".

**O6 Importar com a senha da carteira** (reusa a grade e a bancada do SeedGridView)
- Copy:
  - Título "Importar com a senha da carteira".
  - Subtítulo "Digite as palavras na ordem. Cada letra vira símbolo na tela."
  - Seletor 12, 15, 18, 21, 24. Botão "Colar".
- Depois de colar: "Colado. A área de transferência foi limpa agora, mas pode já ter sincronizado com outros aparelhos Apple."
- Erros:
  - "A palavra 7 não existe na lista. Confira no papel."
  - Conferência da frase falha (bloqueia a importação): "Todas as palavras existem, mas a conferência da frase não fecha. Alguma está trocada ou fora de ordem. Confira no papel."
  - Frase válida em dois idiomas: "Esta frase vale em inglês e em francês. A escolha muda a carteira. Qual é a sua?"
- Opção avançada, recolhida: "Esta carteira usa 25ª palavra". Abre um campo cifrado, digitado duas vezes, com a nota "Com a 25ª palavra errada, a carteira abre vazia e sem aviso nenhum. Por isso ela é digitada duas vezes."
- Carteira já existente: "Esta carteira já está aqui, como {Carteira principal}." Botão "Abrir carteira".
- Primário "Importar".

**O7 Procurando saldo**
- Título "Procurando saldo".
- Subtítulo "Em {6} redes, e nos caminhos usados por Ledger, Trezor, MetaMask e Phantom."
- Uma linha por rede, com o estado dela: "Procurando" → "{R$ 1.203,00}", "Nada encontrado" ou "Não respondeu. Tentar de novo".
- Primário "Continuar", ativo desde o início, com a nota "A busca continua em segundo plano."
- Nada em rede nenhuma: "Nenhum saldo encontrado. Se esta carteira foi usada em outro app com caminho diferente, você ajusta em Ajustes, Redes."

**O8 Observar um endereço**
- Título "Observar um endereço".
- Campo "Endereço" em mono, com os botões "Colar" e "Ler QR".
- Detecção da rede, abaixo do campo:
  - "Endereço Solana"
  - "Endereço EVM: vale em Ethereum, Base, Arbitrum, Optimism, Polygon e BNB Chain."
- Campo "Nome", com o exemplo "Carteira fria".
- Nota "Desta carteira você vê saldo e histórico. Enviar e trocar ficam desligados."
- Primário "Observar".
- Erro "Não reconheci este endereço em nenhuma rede ligada. Confira se copiou inteiro."

### P. Carteira (aba)

**P1 Carteira**
- Objetivo: responder "quanto eu tenho e em quê".
- Hierarquia:
  1. Topo: seletor "Carteira principal" com chevron à esquerda e o olho de ocultar à direita. Nada mais: sem sino, sem leitor de QR, sem banner.
  2. Total "R$ 48.312,07".
  3. "+R$ 1.204,55 (+2,55%) em 24h", verde ou vermelho.
  4. Enviar, Receber, Trocar: três círculos de 56 pt com rótulo. Esta é uma tela de leitura; a confirmação de cada fluxo fica no rodapé dele.
  5. Faixa de cópia, só se a carteira não tem cópia. Não se dispensa.
  6. Rótulo "Ativos", com o botão de texto "Gerenciar" à direita.
  7. Linhas de 64 pt:
     - à esquerda, logo com selo da rede, o nome ("Ether") e, embaixo, preço e variação ("R$ 18.402,10 · +2,1%");
     - à direita, o valor ("R$ 22.082,52") e, embaixo, a quantidade ("1,2 ETH");
     - ativo em várias redes vira uma linha só, com o selo "3 redes".
  8. No fim da lista: "{2} tokens desconhecidos escondidos", que leva a Gerenciar.
- Faixa de cópia: "Esta carteira ainda não tem cópia" / "Grave as 12 palavras antes de receber. Leva 2 minutos." / "Gravar agora".
- Estados:
  - **Vazio.** A área da lista ensina o modelo mental:
    - título "Um endereço em cada rede";
    - texto "Esta carteira já tem endereço em Bitcoin, Ethereum, Base, Solana, XRP Ledger e Stellar. Receba em qualquer um para começar.";
    - fileira com os logos das redes;
    - nota "No XRP Ledger e na Stellar, a conta passa a existir no primeiro recebimento de 1 XRP ou 1 XLM, que ficam reservados pela rede.";
    - botão "Receber".

    O total mostra "R$ 0,00", sem linha de variação.
  - **Carregando pela primeira vez.** Esqueleto nas alturas finais, para nada pular. Com cache, mostra o cache na hora e atualiza por baixo. Puxar para atualizar.
  - **Erro numa rede.** Linha no topo da lista: "Não foi possível ler o saldo na Solana. Os outros estão em dia." / "Tentar de novo". A variação vira "Total sem Solana".
  - **Sem internet.** "Sem internet. Valores de hoje, 14:32."
  - **Valores ocultos.** "R$ ••••••" no total, nos valores e nas quantidades, em todas as abas.
  - **Só observar.** Selo "Só observar" ao lado do nome. Das ações, só "Receber" aparece.

**P2 Seletor de carteiras** (folha)
- Cada linha tem:
  - o glifo monocromático do Escalibur (nunca avatar colorido);
  - nome;
  - valor;
  - embaixo, "12 palavras · 6 redes", "Só observar · Solana" ou, em vermelho, "Sem cópia";
  - marca de seleção na carteira atual.
- Título "Carteiras". Botão "Editar" para renomear e reordenar. Primário "Adicionar carteira".
- Ao tocar numa carteira: a folha fecha, crossfade de 200 ms, toque háptico leve. Não há toast: o nome novo no topo é a confirmação.

**P3 Detalhe do ativo**
- Hierarquia:
  1. "Ether" com o logo.
  2. "R$ 18.402,10" e "+2,1% em 24h". Ao arrastar no gráfico, este bloco mostra o preço e a data do ponto tocado.
  3. Gráfico de linha, verde ou vermelho. Sem grade e sem eixo, só o máximo e o mínimo nas pontas.
  4. Períodos "24h", "7 dias", "30 dias", "1 ano", "Tudo". Por extenso porque "1M" é ambíguo (minuto ou mês).
  5. "Sua posição": "R$ 22.082,52" e "1,2 ETH". Com várias redes: "Ethereum 0,85 ETH · Base 0,30 ETH · Arbitrum 0,05 ETH", cada uma tocável.
  6. "Histórico de ETH": as últimas 20, com "Ver tudo em Atividade".
  7. Só para tokens: "Contrato" com o endereço em mono e "Ver no {Etherscan}".
- Rodapé: "Receber" e "Enviar" secundários, "Trocar" primário.
- Estados:
  - Gráfico carregando: linha plana cinza.
  - Sem histórico: "Sem histórico de preço para este token."
  - Sem internet: "Gráfico de hoje, 14:32."
  - Token desconhecido: "Este token não tem preço de mercado e chegou sem você pedir. Não troque nem abra sites que aparecem no nome dele: é o golpe mais comum com tokens."

**P4 Gerenciar ativos**
- Seções "Na carteira", "Escondidos por você" e "Desconhecidos", com uma chave de mostrar por linha.
- Chave "Esconder saldos abaixo de R$ 1".
- Texto da seção de desconhecidos: "Estes tokens chegaram sem você pedir. Muitos são golpe: o nome aponta para um site que pede a senha da carteira. Mostrar não tem risco. Interagir tem."

### E. Enviar (tela cheia)

**E1 Escolha o que enviar** (pulada quando se vem do detalhe do ativo)
- Busca "Buscar".
- Uma linha por ativo **por rede**, porque todo envio acontece numa rede: "USDC" / "na Base · 300,00" / "R$ 1.620,00".
- Vazio: "Nada para enviar ainda. Quando chegar saldo nesta carteira, ele aparece aqui." Botão "Receber".

**E2 Para**
- Hierarquia:
  - título "Enviar XRP", com selo da rede;
  - campo "Para";
  - botões "Colar" e "Ler QR". O "Colar" é o `PasteButton` do sistema, que não dispara o aviso de colagem;
  - "Recentes" (5) e "Contatos";
  - só em XRP e Stellar, o botão de texto recolhido "Adicionar tag de destino".
- Validação, abaixo do campo:
  - **Válido:** "Endereço do XRP Ledger". Se o endereço é conhecido, vem o nome: "Binance, endereço de depósito" ou o nome do contato. Se é novo: "Primeira vez que você envia para este endereço."
  - **Rede errada:** "Este é um endereço Ethereum. Para enviar XRP, use um endereço que começa com r."
  - **Inválido:** "Este endereço não é do XRP Ledger. Endereços do XRP Ledger começam com r e têm de 25 a 35 caracteres."
  - **Próprio:** "Este endereço é desta mesma carteira."
  - **Parecido com um recente** (envenenamento de endereço): "Este endereço começa e termina igual a um que você já usou, mas o meio é diferente. Esse é um golpe comum. Confira o endereço inteiro." O primário segue ativo, e a revisão repete o aviso.
  - **X-address:** "A tag de destino {12345} veio junto no endereço."
- Câmera negada: "Para ler o QR, o app precisa da câmera." Botões "Abrir Ajustes do iPhone" e "Colar o endereço".
- Primário "Continuar".

**E3 Tag de destino (XRP) ou Memo (Stellar)**
- **(a) A conta exige a tag.** No XRP Ledger, pela flag `RequireDest`. Na Stellar, pelo `config.memo_required` da SEP-29. Sem tag a rede recusaria o envio, então não há como pular.
  - Título "Esta conta exige tag de destino".
  - Texto "A exchange usa a tag para saber que este XRP é seu. Copie a tag da tela de depósito da exchange, a mesma onde está o endereço."
  - Campo "Tag de destino", com teclado numérico.
  - Primário "Continuar", desativado até a tag ser preenchida.
- **(b) Exchange conhecida, sem a flag.**
  - Título "Este endereço é da {Binance}".
  - Texto "Exchanges quase sempre pedem tag de destino. Sem a tag certa, o XRP chega na exchange mas não na sua conta, e recuperar leva semanas de suporte."
  - Primário "Continuar". Secundário "A exchange não pediu tag".
  - O secundário abre o diálogo "Enviar sem tag de destino?" / "Só faça isso se a tela de depósito da exchange não mostra tag nenhuma." / "Enviar sem tag" / "Voltar e preencher".
- **(c) Endereço comum.** Não há tela. Resta o botão opcional de E2.
- Erros:
  - "A tag é um número de 0 a 4.294.967.295. Confira na exchange."
  - Stellar: "O memo cabe até 28 caracteres." Memo só com dígitos vai como numérico, com a linha "Memo numérico · Mudar para texto".

**E4 Valor**
- Hierarquia:
  - valor grande ("0 XRP"), com alternância "em R$";
  - "Disponível 48,20 XRP" e "Máx";
  - linha da reserva;
  - linha da taxa;
  - primário "Revisar".
- Reserva: "1 XRP fica reservado pela rede enquanto a conta existir. Ele não pode ser enviado." O valor é lido do ledger, não é fixo no app.
- Taxa: "Taxa da rede: 0,000012 XRP, menos de R$ 0,01."
- Erros:
  - Valor acima do saldo: "Máximo: 48,20 XRP."
  - Conta de destino ainda não ativada: "Esta conta ainda não existe no XRP Ledger. Para ativá-la, o primeiro envio precisa ser de 1 XRP ou mais."
  - Token EVM sem ETH para a taxa: "A taxa na Base é paga em ETH, e você tem 0 ETH na Base." Botões "Trocar por ETH" e "Receber ETH na Base".
  - Solana, destinatário sem conta do token: "Esta pessoa ainda não tem conta de USDC na Solana. Criar custa 0,002 SOL, pago por você."
  - Bitcoin abaixo do mínimo: "A rede Bitcoin não aceita envios abaixo de {294} satoshis para este tipo de endereço."
  - Tron, conta nova: "Esta conta Tron ainda não está ativa. Ativar custa {1,1} TRX, pago por você."

**E5 Taxa** (folha; só Bitcoin e EVM, onde a escolha muda algo)
- Bitcoin:
  - "Lenta · cerca de 60 min · R$ 1,10"
  - "Normal · cerca de 20 min · R$ 2,40"
  - "Rápida · cerca de 10 min · R$ 4,80"
- EVM mostra o tempo em segundos. O padrão é "Normal".
- XRP Ledger, Stellar e Solana não têm escolha: a taxa aparece como linha fixa.

**E6 Revise o envio**
- Hierarquia:
  1. "50 XRP" e "R$ 142,10".
  2. **Placa clara** com:
     - o rótulo "Para" e o nome conhecido ("Binance");
     - o endereço inteiro em mono, em grupos de 4, com os 6 primeiros e os 6 últimos caracteres em peso maior;
     - na mesma placa e no mesmo tamanho do endereço, "Tag de destino 1234567".
  3. "Rede: XRP Ledger" · "Taxa da rede: menos de R$ 0,01" · "Chega em cerca de 4 segundos" · "De: Carteira principal".
  4. Avisos acumulados (envenenamento, primeiro envio, envio sem tag), um por linha.
- Primário com verbo e valor: "Enviar 50 XRP".
- Primeiro envio para o endereço: secundário "Mandar um teste antes", com "Envia {1 XRP} agora. Quando chegar, volte e envie o resto."
- Sem internet: o primário vira "Sem internet para enviar", desativado.

**E7 Autenticação**
- Face ID. Se falhar, folha de PIN: "Confirme com o PIN" / "Para enviar 50 XRP".
- Com a confirmação por voz ligada e o valor acima do limite, S4b vem depois.

**E8 Status**
- Enviando: "Enviando" / "No XRP Ledger leva cerca de 4 segundos."
- Enviado:
  - "Enviado" / "Confirmado no ledger 91.234.567, em 4 segundos."
  - Para exchange, soma-se "A exchange costuma levar alguns minutos para creditar."
  - Botões "Ver no XRPScan" e, se o endereço é novo, "Salvar este endereço" (guarda a tag junto). Primário "Concluir".
- Bitcoin: "Enviado. A primeira confirmação leva cerca de 10 minutos. Pode fechar o app."
- Falha, traduzida do código de erro da rede: "A rede recusou o envio: esta conta exige tag de destino. Nada saiu da sua carteira." / "Voltar e preencher a tag".

### R. Receber (folha)

**R1 Escolha o que receber**
- Lista todos os ativos suportados, não só os que têm saldo, com "Mais usados" no topo e busca.
- Ativo em várias redes abre "Por qual rede?", com a nota "O endereço é o mesmo em todas estas redes. O que importa é escolher na exchange a mesma rede que você escolher aqui."

**R2 Receber {ativo}**
- Hierarquia:
  - "Receber USDC" / "pela rede Base";
  - placa clara com o QR e, embaixo, o endereço inteiro em mono, em grupos de 4, com as pontas em peso maior;
  - o aviso da rede;
  - as ações.
- Aviso da rede, escrito como instrução:
  - EVM: "Na exchange, escolha a rede Base. Se vier por outra rede EVM, o saldo aparece naquela rede, desde que ela esteja ligada em Ajustes."
  - Bitcoin: "Envie só bitcoin, pela rede Bitcoin. Outra moeda enviada para este endereço se perde."
  - XRP: "Não precisa de tag de destino. Se a exchange pedir, marque que o endereço não tem tag."
  - Conta ainda não ativada: "Esta conta ainda não existe no XRP Ledger. O primeiro recebimento precisa ser de 1 XRP ou mais, e 1 XRP fica reservado pela rede."
  - Stellar ou XRP Ledger sem linha de confiança para o token: "Para receber USDC na Stellar, a conta precisa aceitar o USDC antes. Isso prende 0,5 XLM de reserva." Botão "Aceitar USDC".
- Primário "Copiar endereço". Secundário "Compartilhar".
- Toast depois de copiar: "Endereço copiado. Depois de colar, confira os 6 primeiros e os 6 últimos caracteres."
- **Bloqueado sem cópia:**
  - Título "Grave a senha da carteira antes de receber".
  - Texto "Esta carteira ainda não tem cópia. Se o iPhone sumir antes disso, o que chegar aqui se perde. Leva 2 minutos."
  - Primário "Gravar agora". Não há atalho para pular.

### T. Trocar (aba)

**T1 Trocar, modo Agora**
- Hierarquia:
  1. Seletor de carteira; controle segmentado "Agora" | "Ordem limite".
  2. Caixa "Você paga": token com selo da rede, valor grande e, embaixo, "Saldo: 52.310,40 USDC", "50%" e "Máx".
  3. Botão circular de inverter.
  4. Caixa "Você recebe": token, valor calculado e "≈ R$ 254.690,00".
  5. Três linhas sempre visíveis:
     - "1 ETH = 3.615,20 USDC" (um toque inverte).
     - "Melhor preço entre 6 provedores: {0x}", ou "Dividida entre 3 provedores para você receber mais", com "Ver rota".
     - "Taxas: R$ 768,10 · Escalibur 0,3% (R$ 765,00) e rede (R$ 3,10)". A taxa da Escalibur nunca vai para trás de "Detalhes".
  6. "Detalhes", recolhido: "Impacto no preço 0,08%", "Tolerância de preço 0,5% · Mudar", "Você recebe no mínimo 13,77 ETH", "Proteção contra robôs ligada".
  7. Rodapé: "Nova cotação em 12 s" e o primário.
- O primário diz o estado: "Digite um valor", "Buscando o melhor preço", "Saldo de USDC insuficiente", "Sem ETH na Base para a taxa da rede", "Revisar troca".
- Impacto no preço, em degraus:
  - Acima de 1%: a linha sai de "Detalhes" e fica à vista, em vermelho.
  - Acima de 5%: "Esta ordem move o preço em {6,8%}. Você recebe R$ {17.320} a menos do que o preço de mercado indica. Dividir em ordens menores ajuda." Mais a caixa "Entendo e quero trocar assim".
  - Acima de 15%, bloqueia: "Esta troca perderia {18%} para o impacto no preço. Divida em ordens menores ou use uma ordem limite."
- Estados:
  - Sem rota: "Nenhum provedor troca {PEPE} por {ETH} na Base agora. Tente um valor menor ou outro par."
  - Só observar: "Esta carteira só observa. Escolha outra carteira para trocar."
  - Sem internet: o primário vira "Sem internet para trocar".
- Na v1, a troca é só dentro da mesma rede. Se a pessoa escolher um token de outra rede: "Trocas entre redes ainda não estão disponíveis. Escolha um token na Base."

**T2 Escolher token** (folha)
- Busca por nome ou contrato. "Seus tokens" primeiro, depois "Populares na Base".
- Token não verificado: "Token não verificado. Qualquer pessoa cria um token com qualquer nome. Confira o contrato: {0x3f5c…a91b}." Botão "Entendo, mostrar mesmo assim".

**T3 Rota da troca** (folha)
- A regra, para a divisão não assustar: a tela principal mostra **um** número, e a divisão aparece como ganho medido.
- Título "Como a sua ordem foi dividida".
- Texto "Numa ordem de 50.000 USDC, um provedor só entregaria 13,71 ETH. Dividida entre 3, você recebe 13,84 ETH: 0,13 ETH a mais (R$ 2.390)."
- Uma linha por parte: "{Provedor} · 60% · 30.000 USDC → 8,31 ETH".
- Rodapé, conforme o caso:
  - Transação única: "Tudo acontece numa transação só. Ou executa inteira, ou nada sai da sua carteira."
  - Várias transações: "São 3 transações, uma por provedor, confirmadas com um único Face ID. Cada parte é independente: se uma não passar, você fica com o que foi trocado, e o saldo daquela parte continua na sua carteira."
- "Outras cotações": "{1inch} 13,79 ETH", "{Paraswap} 13,70 ETH".

**T4 Tolerância de preço** (folha)
- Texto "Se o preço piorar mais que isso antes de a troca executar, ela é cancelada e só a taxa da rede é cobrada."
- Opções: "Automática · 0,5%", "0,1%", "0,5%", "1%", "Outra".
- Acima de 3%: "Com {5%}, você pode receber até R$ {12.730} a menos. Tolerância alta atrai robôs que exploram essa diferença."
- Abaixo de 0,1%: "Com tolerância tão baixa, a troca tende a falhar, e a taxa da rede é cobrada mesmo assim."

**T5 Revise a troca**
- Linhas:
  - "Sai 50.000 USDC";
  - "Entra, no mínimo, 13,77 ETH" (estimado 13,84);
  - preço;
  - taxas;
  - "Autorização: exatamente 50.000 USDC · Mudar".
- Etapas, cada uma com o custo:
  - "1. Autorizar exatamente 50.000 USDC · taxa da rede R$ 1,20"
  - "2. Trocar · taxa da rede R$ 1,90"
  - Quando a autorização é por assinatura: "1. Autorizar USDC · assinatura, sem taxa da rede".
- A folha de "Mudar" a autorização oferece "Exatamente 50.000 USDC" (padrão) ou "Sem limite", com o aviso "Sem limite deixa o contrato mover todo o seu USDC, agora e no futuro, sem pedir de novo. Poupa R$ 1,20 na próxima troca."
- Nota acima do botão: "Um Face ID confirma as 2 etapas desta lista, e nada além delas."
- Primário "Trocar".
- Cotação mudou: "O preço mudou. Agora você recebe 13,81 ETH, 0,03 ETH a menos." / "Aceitar o novo preço".

**T6 Coletando as assinaturas**
- Etapas em lista vertical, cada uma com o estado em palavra: "Esperando" → "Assinado" → "Na rede, cerca de 12 s" → "Feito", ou "Não passou".
- Rodapé: "Pode sair desta tela. A troca continua e aparece em Atividade." Se a engenharia não conseguir pré-assinar a etapa 2: "Mantenha o app aberto até a etapa 2 começar."
- Primário "Fechar", que vira "Ver ETH" quando tudo termina.

**T7 Resultado**
- Sucesso: "Troca concluída" / "Você recebeu 13,84 ETH, 0,07 ETH acima do mínimo."
- Parcial: "2 de 3 partes concluídas" / "Você recebeu 9,22 ETH por 33.300 USDC. A parte 3 não passou porque o preço saiu da sua tolerância. Os 16.700 USDC continuam na sua carteira." Primário "Trocar o restante".
- Falha: "A troca não passou: o preço saiu da sua tolerância de 0,5%. Nada foi trocado. A rede cobrou R$ 1,90 pela tentativa." Se a autorização já tinha passado, acrescenta: "A autorização de USDC continua valendo, então a próxima tentativa tem uma etapa só."

### L. Ordem limite

**L1 Trocar, modo Ordem limite**
- Campos:
  1. "Você vende": 2 ETH.
  2. "Quando 1 ETH valer": o preço alvo, com "Preço atual 3.615,20 · 7,9% acima" e os atalhos "Atual", "+5%", "+10%", "+20%".
  3. "Você recebe": 7.776,60 USDC, com "Já descontada a taxa da Escalibur de 0,3%, cobrada só se executar".
  4. "Vale por": "7 dias". Abre folha com "1 hora", "1 dia", "7 dias", "30 dias".
- Onde fica o dinheiro:
  - EVM (ordem assinada): "Os 2 ETH continuam na sua carteira até a ordem executar. Se você gastar antes, a ordem para."
  - Solana: "Os 2 SOL ficam reservados no contrato da ordem até ela executar ou você cancelar."
- Preço alvo abaixo do atual numa venda: "Este preço está 8% abaixo do atual. A ordem executaria logo, pior que trocar agora." Botão "Trocar agora".
- Primário "Revisar ordem".

**L2 Revise a ordem**
- Linhas:
  - "Vende 2 ETH"
  - "Recebe no mínimo 7.776,60 USDC"
  - "Preço alvo 1 ETH = 3.900 USDC, 7,9% acima do atual"
  - "Vale até 2 de outubro, 14:05"
  - "Criar não tem taxa da rede"
- Etapas em EVM:
  - "1. Converter 2 ETH em WETH, 1 para 1 · R$ 1,40"
  - "2. Autorizar exatamente 2 WETH · R$ 1,20"
  - "3. Assinar a ordem · sem taxa da rede"

  ETH nativo não entra em ordem assinada, e a pessoa precisa ver a conversão antes de assinar.
- Primário "Criar ordem". Depois vem T6.
- Resultado: "Ordem aberta" / "Executa se 1 ETH chegar a 3.900 USDC até 2 de outubro, 14:05."

**L3 Ordens abertas** (linha "Ordens abertas · 2" em Trocar; as ordens também aparecem em Pendentes na Atividade)
- Linha: "Vender 2 ETH por USDC" / "a 3.900 USDC · vence em 6 dias", com o estado à direita.
- Vazio: "Nenhuma ordem aberta" / "Uma ordem limite troca sozinha quando o preço chega ao valor que você escolheu, e vale até a data que você marcar." / "Criar ordem limite".

**L4 Detalhe da ordem**
- Hierarquia: estado; distância do alvo; quanto já executou; preço alvo; validade; criação; provedor.
- Estados:
  - "Aberta" / "Falta o ETH subir 7,9%"
  - "Executada em parte" / "0,8 de 2 ETH, 40%"
  - "Executada" / "Recebeu 7.801,20 USDC"
  - "Expirada" / "Venceu em 2 de outubro sem executar. Nada saiu da sua carteira." Com parte executada: "0,8 ETH executados. O resto voltou a ficar livre."
  - "Cancelando" / "Aguardando a rede, cerca de 12 s"
  - "Cancelada"
  - "Parada: falta saldo" / "A carteira tem 1,2 WETH e a ordem precisa de 2. Ela volta a valer se o saldo voltar."
- Rodapé destrutivo "Cancelar ordem".
- Diálogo, conforme o tipo de ordem:
  - Cancelar exige transação: "Cancelar esta ordem?" / "Cancelar custa R$ 2,10 de taxa da rede. A parte já executada, 0,8 ETH, não volta."
  - Cancelar não exige transação: "Cancelar não tem custo. Se a ordem estiver executando neste instante, essa parte ainda pode ser concluída."
  - Botões "Cancelar ordem" / "Manter".

### H. Atividade (aba)

**H1 Atividade**
- Topo: seletor de carteira e filtro (tipo e rede).
- "Pendentes" primeiro, depois os grupos por data: "Hoje", "Ontem", "23 de setembro".
- Linha:
  - logo do ativo com uma pequena seta de direção;
  - "Enviado · XRP" / "Para rN7n…Q4xk · 14:02";
  - à direita, "−50 XRP" / "R$ 142,10".
  - Pendente: "Aguardando 1 de 2 confirmações". Falha: "Falhou", em vermelho.
- Fim da lista: "{3} recebimentos suspeitos escondidos". São envios de valor zero vindos de endereços parecidos com os seus.
- Estados:
  - Vazio: "Nada aconteceu nesta carteira ainda" / "Envios, recebimentos, trocas e ordens aparecem aqui, com o status de cada um." / "Receber".
  - Erro: "Não foi possível ler o histórico da Solana." / "Tentar de novo".
  - Sem internet: "Sem internet. Histórico até hoje, 14:32."

**H2 Detalhe da transação**
- Conteúdo:
  - valor e estado;
  - linha do tempo ("Enviado 14:02:10", "Entrou no bloco 14:02:14", "Confirmado");
  - Para, Tag, Rede, Taxa;
  - hash em mono, com "Copiar";
  - "Ver no {Etherscan}".
- Bitcoin parado: "Está demorando mais que o previsto." Botão "Acelerar", que abre "Acelerar este envio" / "Paga mais R$ 3,20 de taxa para chegar em cerca de 10 minutos." / "Acelerar".
- EVM parado: botões "Acelerar" e "Cancelar envio". O cancelamento explica: "Para cancelar, o app manda no lugar dele um envio de 0 ETH para você mesmo. Custa R$ 2,40 de taxa e só funciona se o envio ainda não entrou num bloco."

### S. Ajustes (aba)

**S1 Ajustes**
- Primeiro grupo, sem rótulo: "Carteiras · 3", "Segurança", "Contatos", "Abrir um envelope".
- "Preferências": "Moeda · Real (R$)", "Idioma · Português (Brasil)", "Redes · 6 ligadas", "Provedores de troca · 6 ligados".
- "Sobre": "Taxas", "Código aberto", "Auditorias", "Versão 1.0 (142)".

**S2 Carteira**
- Nome editável e tipo ("12 palavras", "Importada de envelope", "Só observar").
- "Cópias":
  - "Papel · confirmado em 25/09" ou, em vermelho, "Papel · não confirmado";
  - "Envelope Escalibur · lacrado e testado em 25/09".
- "Última vez que a senha da carteira foi exibida: hoje, 14:02".
- Ações: "Ver a senha da carteira", "Guardar num envelope Escalibur", "Endereços" (em mono, copiáveis).
- Rodapé destrutivo "Remover deste iPhone". Pede autenticação e depois:
  - "Remover {Carteira principal} deste iPhone?" / "O saldo continua na blockchain. Sem a senha da carteira ou um envelope, você não volta a acessá-lo."
  - Sem cópia confirmada e com saldo: "Esta carteira não tem cópia confirmada. Removida, o saldo de R$ {1.203,00} fica inacessível para sempre." Primário "Gravar a senha antes". Destrutivo "Remover mesmo assim".

**S3 Segurança**
- "Mudar o PIN".
- "Face ID" (chave).
- "Confirmação por voz · Desligada".
- "Bloquear o app · Depois de 1 minuto". Opções: "Ao sair do app", "Depois de 1 minuto", "Depois de 5 minutos", "Depois de 15 minutos".
- "Apagar depois de 10 PINs errados", **desligada por padrão**.
  - Nota: "Depois de 10 PINs errados, este iPhone apaga as carteiras. Só a senha de cada carteira ou um envelope traz de volta."
  - Só liga se todas as carteiras têm cópia confirmada. Se não: "Confirme a cópia de {Carteira 2} antes de ligar."
- Linha fixa, sem chave: "Todo envio, troca e ordem pede Face ID ou PIN."
- "Autorizações ativas · 4".

**S4 Confirmação por voz** (camada adicional; o papel final é da segurança)
- Regra: a voz vem **depois** do Face ID ou do PIN, nunca no lugar deles.
- Tela inicial:
  - Título "Confirmação por voz".
  - Texto "Uma segunda confirmação depois do Face ID ou do PIN, nas operações que você escolher."
  - Só se o processamento for mesmo local: "A sua voz é processada neste iPhone e não sai dele."
  - Primário "Gravar a minha voz".
- Gravação: "Leia em voz alta: {sete lagos azuis}", 3 frases, com um medidor de nível simples.
- Com a voz ligada, as opções:
  - "Pedir em envios acima de R$ {5.000}"
  - "Pedir para ver a senha da carteira"
  - "Pedir para lacrar envelope"
- **S4b, dentro dos fluxos:**
  - "Diga: {cinco pontes claras}". As palavras são sorteadas a cada vez, para uma gravação antiga não funcionar.
  - Falha: "Não reconheci. Fale de novo, perto do iPhone."
  - A saída "Não consigo falar agora" fica a definir pela segurança. Sugestão: espera de 10 minutos e PIN de novo.
- Microfone negado: "Para usar a voz, o app precisa do microfone." / "Abrir Ajustes do iPhone".

**S5 Autorizações ativas**
- Linha: token, contrato ou provedor, rede, e o limite: "Sem limite" em vermelho ou "Até 5.000 USDC".
- "Revogar" leva a uma revisão com a taxa, e depois à autenticação.
- Vazio: "Nenhum contrato pode mover tokens desta carteira."

**S6 Contatos**
- Guarda nome, endereço, rede e, quando houver, a tag ou o memo junto.
- Vazio: "Salve os endereços para onde você envia sempre, com a tag de destino junto quando houver."

**S7 Redes**
- Uma chave por rede, com o nó: "Nó · Escalibur" ou "Nó · Meu nó".
- Texto: "Para ler saldos, o app consulta um nó de cada rede. Esse nó vê os seus endereços e o seu IP. Com o seu próprio nó, ninguém mais vê."

**S8 Provedores de troca**
- Uma chave por provedor.
- Texto: "A Escalibur compara estes provedores em toda cotação. A taxa da Escalibur, de {0,3%}, e a do provedor já estão dentro do valor que você recebe."
- Chave "Proteção contra robôs", ligada, com a nota "Envia as trocas na Ethereum por um canal privado, para robôs não passarem na sua frente."

**S9 Moeda e idioma**
- Moeda: "Real (R$)" ou "Dólar americano (US$)".
- Idioma: "Português (Brasil)" ou "English".

**S10 Sobre**
- Taxas: "A Escalibur cobra {0,3%} sobre cada troca e cada ordem limite executada. Enviar e receber não têm taxa da Escalibur, só a da rede."
- Código aberto: o link do repositório e "Esta versão: 1.0, build 142, commit {a1b2c3d}."
- Auditorias: "{Empresa}, {mês de ano}." / "Ler o relatório". Só publicar o que existir de fato.

**Notificações** (pedido opcional, depois do primeiro recebimento, nunca no onboarding)
- "Avisar quando chegar saldo?" / "Para avisar, um servidor da Escalibur precisa conhecer os endereços desta carteira. Sem isso, você vê quando abrir o app." / "Avisar" / "Agora não".

### V. Envelope Escalibur

**V1 Lacrar** (a partir de O5 ou S2; começa com Face ID ou PIN)

**V1a Crie a senha do envelope**
- Título "Crie a senha do envelope".
- Texto "Só ela abre o envelope, em qualquer aparelho. Não é o PIN e não pode ser a senha da carteira. Não existe redefinir."
- Campo: o CipherField.
- Abaixo do campo, uma frase com um número, recalculada a cada tecla: "Com este arquivo nas mãos, o crime organizado levaria {485 anos} para adivinhar esta senha."
  - Campo vazio: "Digite para ver quanto custa adivinhar."
  - Referências da tabela do README: 4 palavras sorteadas dão 485 anos, 5 dão 3,7 milhões de anos, `Bitcoin2024!` dá 1 hora, 6 dígitos dão 4 segundos.
- Botão de texto "Sugerir 5 palavras sorteadas".
- Abaixo de 1 ano, a frase fica vermelha e ganha: "Para um arquivo que pode ir para a nuvem, use 5 palavras sorteadas."
- Senha com palavras da própria frase, bloqueia: "Esta senha usa palavras da própria carteira. Quem achar o papel abre o envelope. Escolha outra."
- Primário "Continuar".

**Sugerir 5 palavras** (folha)
- Placa clara com as 5 palavras em mono.
- "Adivinhar: 3,7 milhões de anos para o crime organizado."
- "Anote em outro lugar, longe do papel da senha da carteira."
- Primário "Usar estas palavras". A pessoa repete a senha mesmo assim em V1b.
- As palavras saem da mesma lista usada na conta do README, para o número bater.

**V1b Repita a senha do envelope**
- Erro: "As duas não conferem. Digite a senha do envelope de novo."
- Linha "Nome dentro do envelope: {Carteira principal} · Mudar", com a nota "O nome fica cifrado. O arquivo não diz de quem é."
- Primário "Lacrar envelope".

**V1c Lacrando**
- "Lacrando. Leva cerca de {3} segundos neste iPhone." O número vem da calibração do Argon2 no aparelho.

**V1d Envelope lacrado**
- Texto "O arquivo se chama envelope-7F3A.esclbr e não diz de quem é nem o que guarda. Guarde o arquivo e a senha em lugares diferentes: quem tiver os dois tem a carteira."
- Primário "Salvar ou enviar o arquivo".
- Secundário "Testar o envelope agora", que roda V2 e termina em "Confere. O envelope abre com esta senha e guarda as palavras desta carteira."
- Rodapé "Abre no app Escalibur, aqui, ou no decifrador aberto num computador."
- Nota de engenharia: o arquivo sai no formato v1, com quatro compartimentos, e o teste de ida e volta com o `decifrar.py` vale aqui também.

**V2 Abrir** (de O1, de Ajustes, ou de um arquivo vindo do Arquivos ou do AirDrop)

**V2a** Seletor de arquivos do sistema, filtrado por `.esclbr`.

**V2b Senha do envelope**
- O nome do arquivo no topo.
- Título "Senha do envelope".
- Texto "A senha escolhida quando o envelope foi lacrado. No app Escalibur, é a senha do cofre."
- Primário "Abrir envelope".

**V2c Abrindo**
- "Abrindo. Leva cerca de {3} segundos, e cada tentativa custa o mesmo para quem tentar adivinhar."

**Erros de V2**
- **Senha errada.** A mensagem é sempre a mesma: "Não abriu. Confira a senha, com maiúsculas, acentos e espaços, e tente de novo." A senha da isca abre a isca, como no Escalibur, sem nenhum sinal diferente.
- **Não é envelope:** "Este arquivo não é um envelope Escalibur. Envelopes terminam em .esclbr e têm 16.504 bytes."
- **Preso a outro aparelho.** Aparece antes de pedir a senha, porque o cabeçalho já diz: "Este envelope foi lacrado preso ao iPhone que o criou e só abre no app Escalibur daquele aparelho."
- **Memória:** "Este envelope exige {1.024} MiB por tentativa, e este iPhone não consegue reservar tanto agora. Feche outros apps e tente de novo. A senha não chegou a ser testada."
- **Danificado:** "Este envelope está danificado e não abre. Se você tem outra cópia do arquivo, use a outra."

**V2d Envelope aberto**
- Título: o nome guardado dentro do envelope.
- Subtítulo "24 palavras, lista em português" e, se houver, "Com 25ª palavra".
- Primário "Importar esta carteira". Leva a O7, com a cópia marcada "Envelope Escalibur".
- Secundário "Só ver as palavras". Leva a X2, e nada fica guardado ao fechar.
- Parte SLIP-39: "Este envelope guarda uma parte SLIP-39. Uma parte sozinha não abre carteira, e esta versão ainda não junta partes." Só o secundário aparece.
- Carteira já importada: "Esta carteira já está aqui, como {Carteira principal}." / "Abrir carteira".

### X. Revelar a senha da carteira

**X1 Antes de ver**
- Título "Ninguém da Escalibur vai pedir estas palavras".
- Texto "Suporte, gerente de exchange, recuperação de conta: quem pede a senha da carteira está tentando roubar o saldo. Veja sozinho, longe de câmeras."
- Primário "Ver as palavras". Depois vêm Face ID ou PIN, e a voz se ela estiver ligada para isso.

**X2 Placa**
- A mesma de O3, com fundo preto e nada fora da placa.
- "Senha da carteira" / "{Carteira principal} · palavras 1 a 3 de 12".
- 60 s por grupo. Botões "Anteriores" e "Próximas"; no último grupo, "Fechar".
- Se houver 25ª palavra, ela vem num grupo final: "25ª palavra" / "Sem ela, as palavras acima abrem uma carteira diferente e vazia."
- Ao fechar, o app grava o horário que aparece em S2.

### G. Estados globais
- **Sem internet:** "Sem internet. {Valores} de hoje, 14:32." Ver e receber continuam funcionando. Enviar, trocar e ordem dizem no próprio botão: "Sem internet para {enviar}".
- **Nó fora do ar:** o aviso é por rede, nunca a tela inteira.
- **Atualização obrigatória por falha de segurança:** "Esta versão tem uma falha corrigida na 1.0.3. Atualize para voltar a enviar." / "Atualizar" / "Ver o que mudou". Ver e receber continuam.
- **Troca de apps:** a tela aparece sempre coberta pela marca.

---

## 3. Fluxos críticos

**3.1 Da primeira abertura à carteira protegida**
Tarefa: ter a chave num papel. Se errar: a carteira só existe no iPhone.
1. A1 "Começar".
2. A2: PIN e repetição. O PIN vem antes de a frase existir.
3. A3: Face ID.
4. O1 "Criar carteira nova".
5. O2: 12 palavras e "Mostrar as palavras".
6. O3: 4 grupos de 3 palavras e "Já anotei as 12".
7. O4: 3 posições digitadas.
8. O5: nome e "Ir para a carteira". Opcionalmente, V1 e volta.
9. P1 vazia, que ensina, com Receber liberado.

Se a pessoa sair em O3 ou O4, a carteira fica marcada "Sem cópia" e Receber fica bloqueado.

**3.2 Importar por envelope**
Tarefa: trazer a carteira do Escalibur. Se errar: nada se perde, mas senha errada repetida vira desistência.
1. O1 "Importar de um envelope Escalibur", ou o arquivo aberto direto.
2. V2a. O erro de arquivo aparece aqui, antes da senha.
3. V2b "Abrir envelope".
4. V2c, cerca de 3 s.
5. V2d "Importar esta carteira".
6. O7, com o nome vindo do envelope.
7. P1 da carteira nova, já selecionada, com Receber liberado.

**3.3 Enviar XRP para exchange com tag de destino**
Tarefa: o XRP chegar na conta da pessoa na exchange. Se errar: chega na exchange e não na conta, e recuperar leva semanas.
1. P3 do XRP, "Enviar".
2. E2: colar o endereço. O app reconhece a exchange e lê a flag `RequireDest`.
3. E3 (a): digitar a tag.
4. E4: valor, com a linha da reserva. "Revisar".
5. E6: placa com endereço e tag no mesmo tamanho. Por ser o primeiro envio, aparece "Mandar um teste antes".
6. E7: Face ID.
7. E8: "Enviado". "Salvar este endereço" guarda a tag junto, e na próxima vez o contato preenche os dois.

**3.4 Swap com aprovação**
Tarefa: trocar 50.000 USDC por ETH pelo melhor preço. Se errar: receber menos, ou deixar uma autorização sem limite aberta para sempre.
1. Trocar, modo "Agora": USDC para ETH, 50.000.
2. T1 mostra "Dividida entre 3 provedores para você receber mais". T3 é opcional.
3. "Revisar troca".
4. T5: 2 etapas e autorização exata. "Trocar".
5. Um Face ID.
6. T6, etapa por etapa.
7. T7.

Se a cotação mudar no meio, o app pede aceite e nova autenticação.

**3.5 Ordem limite**
Tarefa: vender 2 ETH a 3.900 USDC. Se errar: alvo do lado errado executa na hora e pior; ou o ETH é gasto e a ordem para em silêncio.
1. Trocar, modo "Ordem limite".
2. L1: 2 ETH, "+10%" com ajuste, 7 dias.
3. L2: 3 etapas.
4. Face ID, T6, "Ordem aberta".
5. L3 e L4 para acompanhar e cancelar, com o custo dito antes.
6. Se o ETH for gasto, a ordem vira "Parada: falta saldo", em Pendentes.

**3.6 Trocar de carteira**
Tarefa: ver ou mexer em outra carteira. Se errar: enviar da carteira errada.
1. Tocar no nome da carteira, no topo de qualquer uma das três abas.
2. P2: tocar na outra carteira.
3. Crossfade e toque háptico. As três abas passam a mostrar a nova carteira.
4. A proteção contra o erro: o nome no topo de toda aba e "De: {carteira}" em toda revisão. Dentro de fluxos em tela cheia não se troca de carteira.

**3.7 Revelar a senha da carteira**
Tarefa: ver as palavras. Se errar: alguém as vê.
1. Ajustes, Carteiras, a carteira, "Ver a senha da carteira".
2. X1 "Ver as palavras".
3. Face ID ou PIN.
4. X2: 3 palavras por vez, 60 s por grupo.
5. "Fechar" grava o horário.

---

## 4. A OKX: o que copiar e o que não

**Copiar**
- Linha densa: logo com selo da rede; nome e preço à esquerda; valor e quantidade à direita; sem caixa em volta.
- Base monocromática, com verde e vermelho só para variação.
- Olho de ocultar que vale no app inteiro.
- Ações rápidas logo abaixo do total.
- Detalhe do ativo numa rolagem só.
- Um ativo somado entre várias redes, com a divisão no detalhe.
- Troca em duas caixas, com o botão de inverter, "50%" e "Máx", e a contagem da próxima cotação.
- Rota com o percentual de cada provedor e as outras cotações.
- Gestão de autorizações com revogar.
- Agenda de endereços e recentes.

**Não copiar**
- Banners, campanhas, bolinhas vermelhas, Earn e ofertas. Numa carteira que pede confiança, promoção parece isca.
- A chave Exchange/Carteira e a grade de 8 atalhos. Aqui são 3 ações.
- Autorização "Unlimited" vendida como conveniência. A própria ajuda da OKX apresenta assim. Aqui o padrão é o valor exato, e o custo de "sem limite" vem escrito.
- Jargão cru: Gas, Slippage, Nonce, Price impact.
- Velas, livro de ofertas e gráfico de 1 minuto.
- Navegador de dApps, "Descobrir" e tokens em alta: a maior superfície de golpe de uma carteira.
- Aviso crítico em cinza de 11 pt. Aqui o aviso tem o tamanho do dado que ele protege.
- Modo de troca por intenção, pontes e vários modos de ordem na v1.

---

## 5. Decisões de segurança (fricção certa no lugar certo)

1. **Três segredos, três nomes fixos,** e "senha" nunca aparece sozinha. O app bloqueia senha de envelope feita com palavras da frase.
2. **Receber fica bloqueado até a cópia estar confirmada.** Criar a carteira continua rápido; a fricção entra no momento em que a falta de cópia começa a custar dinheiro. Carteira importada já nasce com cópia.
3. **Conferência digitada,** não por chips: 3 posições, uma por terço da frase.
4. **Frase na tela com limites:**
   - 3 palavras por vez, 60 s por grupo;
   - escondida durante gravação, espelhamento e segundo plano;
   - captura de tela detectada vira instrução do que fazer;
   - nunca existe botão de copiar a frase.
5. **Revelar pede autenticação e um aviso de golpe,** e deixa rastro com data e hora. Não uso checklist de caixinhas: todo mundo marca sem ler.
6. **Toda assinatura pede Face ID ou PIN, sem chave para desligar.**
   - Um Face ID cobre exatamente as etapas listadas na revisão.
   - Se a cotação mudar ou surgir etapa nova, a autenticação se repete.
   - Não há "deslize para confirmar": o Face ID já é o gesto deliberado, e dois gestos ensinam a pessoa a passar direto.
7. **Destino conferível:**
   - endereço inteiro na placa, com as pontas em peso maior;
   - aviso de primeiro envio e a opção "Mandar um teste antes";
   - detecção de endereço parecido com um recente;
   - recebimentos suspeitos de valor zero escondidos.
8. **Tag e memo seguem a regra da própria rede** (`RequireDest`, SEP-29). Para exchange conhecida sem a flag, seguir sem tag exige confirmação explícita. Na revisão, a tag tem o tamanho do endereço.
9. **Autorização exata por padrão,** com a tela de autorizações ativas para revogar.
10. **Impacto no preço em degraus:** à vista acima de 1%, confirmação acima de 5%, bloqueio acima de 15%.
11. **PIN com espera progressiva sempre.** Apagar após 10 erros fica desligado por padrão e só liga com todas as carteiras com cópia confirmada.
12. **Bloqueio automático em 1 minuto por padrão;** o app aparece sempre coberto na troca de apps.
13. **Voz como camada depois do Face ID ou do PIN,** com desafio de palavras sorteadas.
14. **Privacidade dita como fato:** logos embarcados, nó próprio opcional, e a frase da notificação que explica o servidor.
15. **Token desconhecido escondido,** com aviso no detalhe e na escolha de token.

---

## 6. O que eu cortaria

- **Aba de mercado, tokens em alta, navegador de dApps e WalletConnect.** WalletConnect entra na v2, com simulação de transação.
- **NFTs, comprar com cartão, staking e Earn.**
- **Troca entre redes e pontes.**
- **Velas, gráfico de 1 hora e gráfico do portfólio na Carteira.**
- **Mais de uma conta por rede.**
- **Escolha de taxa em XRP Ledger, Stellar e Solana.**
- **Tipo de endereço Bitcoin** (fica SegWit nativo) **e valor embutido no QR.**
- **Carteira isca por PIN de coação.** Já existe no Escalibur.
- **Tema claro e inversão das cores de alta e queda.**
- **Adicionar token por contrato na Carteira.** Fica só na busca da troca, com aviso.
- **Tron, se não houver demanda.** Traz ativação, energia e largura de banda: três conceitos novos para a pessoa.

---

## 7. Decisões que ficam com o Thomaz

1. "Senha da carteira" como nome da frase. A alternativa é "as 12 palavras" em todo lugar.
2. Receber bloqueado sem cópia, sem atalho. Recomendo manter.
3. Bloqueio da troca acima de 15% de impacto no preço. Recomendo manter.
4. Atacante de referência na frase de custo da senha do envelope. Recomendo "crime organizado".
5. O valor da taxa da Escalibur, e se na ordem limite ela é cobrada só na execução (desenhei assim).
6. A saída da voz quando a pessoa não pode falar.
7. Tron na v1.

Fontes sobre a OKX:
- [OKX DEX user guide (app)](https://web3.okx.com/help/okx-dex-user-guide-app): dá a opção "Unlimited" na aprovação como forma de evitar aprovações futuras.
- [OKX DEX FAQs](https://web3.okx.com/help/okx-dex-faqs): a ordem é dividida entre vários DEXs quando isso rende mais.

Arquivos do Escalibur usados como base, em /Users/thomazjr/projects/escalibur:
- `README.md` (tabela de custo da senha)
- `docs/custodia.md`
- `docs/formato.md` (compartimentos, vínculo com o aparelho, 25ª palavra, SLIP-39)
- `Escalibur/Features/LockView.swift`, `ShelfView.swift`, `SealVaultView.swift`, `OpenVaultView.swift`, `SeedGridView.swift`, `CipherField.swift`
- `Escalibur/Design/Palette.swift`, `Typography.swift`