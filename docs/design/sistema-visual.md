# Escalibur Wallet: sistema visual v1

Especificação do agente de UI, 2026-09-25. Fonte da verdade para `App/Design/`.
Herda do Escalibur: fundo, superfícies, tinta, laca branca, escala de espaço, raios 12/14/28,
alturas de botão, botão sem `.disabled()` com estado desligado opaco, filamento de foco.

## Mudanças em relação ao Escalibur
1. `inkMuted` #7D7D85 vira #8A8A92 (AA sobre #151518).
2. Sem vidro desenhado à mão e sem `FieldBackground`. Só o vidro do sistema (tab bar/nav no iOS 26).
3. Três matizes, só para estado: verde e vermelho de variação, âmbar de risco. Vermelho = `alarm` do irmão.
4. Teclado de PIN sem letras ABC.
5. Modo claro fora da v1: `UIUserInterfaceStyle = Dark`.

## 1. Cor
| Token | Hex | Uso |
|---|---|---|
| void | #0B0B0C | fundo de toda tela |
| body | #151518 | nível 1: cartão, sheet, campo, linha pressionada |
| rail | #1E1E22 | nível 2: cartão em sheet, ação rápida, tecla PIN, chip, segmento selecionado |
| control | #26262B | nível 3: pressionado sobre rail, chip selecionado, disco de logo ausente, fechar sheet |
| edge | #2A2A2F | contorno 1px de cartão e campo |
| edgeStrong | #3A3A40 | contorno com foco, chip selecionado, referência do gráfico |
| ink | #F5F5F6 | texto primário |
| inkSoft | #A8A8AE | secundário |
| inkMuted | #8A8A92 | terciário |
| inkDead | #434349 | desabilitado, placeholder |
| live / livePress / onLive | #F5F5F6 / #C9C9CE / #070708 | laca: CTA, foco, item selecionado |
| up / upTint | #25C28A / #0F251E | alta, recebido, confirmado |
| down / downTint / downPress | #FF4D3D / #2D1413 / #3C1816 | queda, falha, destrutivo |
| caution / cautionTint | #F5A524 / #2C210F | só risco antes de ação irreversível |

Regras: sinal + ou − obrigatório em variação (daltonismo). Enviar não é perda: "−0,5 ETH" em ink,
recebido "+0,5 ETH" em up. Variação zero em inkSoft. Âmbar só em: token não verificado, aprovação
ilimitada, impacto > 3%, backup pendente. Pressionado: laca #C9C9CE; sobre void #151518; sobre body
#1E1E22; sobre rail #2A2A2F. Desabilitado: fundo #1E1E22, texto #434349, opaco. Foco: filamento
3×20pt #F5F5F6 na borda interna esquerda + contorno #3A3A40. Logos a 100%; logo transparente ganha
disco control; logo escuro (XRP, XLM) ganha disco #E4E4E7.

## 2. Tipografia (SF Pro do sistema)
| Estilo | Tamanho/peso | Tracking | Uso |
|---|---|---|---|
| display | 40 bold tabular | −1.0 | saldo total (R$ em 24 semibold inkSoft) |
| figure | 32 bold tabular | −0.6 | preço no detalhe, campo swap, valor na revisão |
| key | 30 medium | 0 | dígito PIN |
| title | 24 bold | −0.6 | título de tela/sheet |
| heading | 20 semibold | −0.3 | seção |
| action | 17 semibold | 0 | botão, ticker no chip |
| row | 16 semibold tabular | −0.1 | título e valor de linha |
| body | 15 regular | 0 | parágrafo (lineSpacing 4) |
| note | 13 regular tabular | 0 | subtítulo, rótulo, legenda |
| label | 12 semibold | 0 | chip, segmento, badge |
| axis | 11 medium tabular | 0 | máx/mín do gráfico, data do cursor |
| mono | 16 medium monospaced | 0 | palavra da frase, endereço completo |
| monoSmall | 13 regular monospaced | 0 | endereço truncado |

`.monospacedDigit()` em todo número vivo ou em coluna. Mono só em endereço e palavra da frase.

### Formatação pt_BR
- Fiat: "R$ 1.234,56" (NBSP), "< R$ 0,01", negativo "−R$ 12,30" (U+2212).
- Preço unitário: ≥1 → 2 casas; 0,01 a 0,9999 → 4; 0,0001 a 0,0099 → 6; abaixo → zeros em subscrito "R$ 0,0₄5234".
- Cripto: truncar para baixo; lista até 6 significativos e máx 8 casas; revisão com precisão cheia até 8; stablecoin 2 casas; "< 0,00000001 BTC".
- Percentual "+2,31%"; ≥1.000% sem casas.
- Compacto (só dado de mercado): "12,3 mil", "812 mi", "45,2 bi", "2,31 tri".
- Datas: "Hoje, 14:32", "Ontem, 09:10", "23 set, 18:05", "23 set 2025", "há 2 min". 24h.
- Endereço truncado 6+4 com "…": "0x71C7…976F".

## 3. Espaço, raio, altura
Espaço: 4, 8, 12, 16, 20, 28, 40, 64. Margem lateral 20. Cartão padding 16, vão 12.
Raio: 6 badge/pill/esqueleto; 8 chip/segmento; 10 trilho comprar/vender; 12 cartão/campo/toast/chip
de token; 14 botão; 28 topo de sheet; círculo em logo/ação/tecla. Nunca pílula em CTA. `.continuous`.
Alturas: primário 56; secundário 52 (56 ao lado do primário); linha 64 (dois níveis) / 52; barra 44;
campo 48; chip de token 40; chip 32; pill 28; badge 22; ação rápida 52; tecla PIN 78.
Lista longa direto no fundo, sem cartão e sem filete. Cartão só para grupo curto (até 6 linhas).

## 4. Componentes
- Primário: laca, texto action #070708, 56, raio 14; pressionado #C9C9CE escala 0,985; desligado
  #1E1E22/#434349; carregando spinner.
- Secundário: body + contorno edge, texto ink. Terciário: texto 15 inkSoft. Destrutivo: downTint + texto down.
- CTA fixo embaixo, fundo void sólido.
- Cabeçalho de portfólio: seletor de carteira (glifo 24 + nome + chevron) | qrcode.viewfinder, gearshape.
  "Saldo total" note inkSoft + eye; saldo display; variação row colorida + "24h" note inkMuted;
  28 → ações rápidas; 40 → "Ativos" heading. Oculto: "R$ ••••••".
- Ações rápidas: Enviar, Receber, Swap, Limite. Círculo rail 52, símbolo 20 semibold, legenda label inkSoft.
- Linha de ativo 64: logo 40 + selo de rede 16 (só se não nativo); ticker row, preço note + variação;
  direita: valor fiat row, quantidade note inkSoft. Sem logo: disco control com 2 letras.
- Linha de mercado: pill de variação 72×28, raio 6, up/upTint, down/downTint. Sparkline 64×24.
- Seletor de período: 1h, 24h, 7d, 30d, 1a, Tudo. Selecionado ink sobre rail raio 8, matchedGeometry.
- Gráfico: 248pt, linha 1,5 linear, cor pela tendência, área 18%→0%, referência de abertura tracejada
  [2,3] #3A3A40, só máx/mín em axis inkMuted, ponto final 6. Cursor por long press 150ms/arrasto
  horizontal: linha 1pt #8A8A92, ponto 10 com anel void; cabeçalho vira o preço do cursor.
- Campo do swap: cartão body, "Você paga", saldo + Máx, valor figure, chip de token, "≈ R$".
  Inverter: círculo rail 36 com anel void 4. Chips 25%/50%/75%/Máx. CTA: "Digite um valor",
  "Saldo insuficiente", "Aprovar USDC", "Revisar swap".
- Cartão de cotação: "1 ETH = 12.345,67 USDC", anel de atualização 15s, expandido: taxa de rede,
  impacto (ink ≤1%, caution 1 a 3%, down >3%), recebe no mínimo, tolerância, rota.
- Sheet nativa: raio 28, fundo body, título title, fechar círculo 30 control.
- PIN: tecla 78 rail, vão 26/18, dígito key; faceid e delete.left 22 sem disco; pontos 12pt vão 16;
  erro: pontos down + sacudida 260ms.
- Toast: rail + edge, raio 12, sombra 50% r24 y8; 2,5s.
- Banner: risco cautionTint; falha downTint; neutro body.
- Badges: pendente (pulso), aberta, parcial, executada (up), cancelada/expirada (inkMuted), falhou (down).
- Comprar/Vender: trilho body 40 raio 10, segmento upTint/downTint. CTA laca "Comprar BTC".
- Vazio: sem ilustração, alinhado à esquerda. Esqueleto: blocos body com pulso 1 a 0,55 em 1,2s.
- Seletor de carteira: sheet medium "Carteiras", glifo 36, nome, saldo + endereço monoSmall.
- QR: placa laca 280, raio 14, chanfro 45° 24pt canto sup. dir., QR 232 nível H, logo da rede 48 no
  centro; endereço mono em blocos de 4, primeiros 6 e últimos 4 em ink.

## 5. Movimento e haptics
Pressionar 100ms easeOut; seleção `.snappy(0.22)`; número `.numericText` `.snappy(0.3)`; tick no
detalhe 600ms; troca de período crossfade 180ms; inverter 180° `.snappy(0.24)`; toast spring
(0.3, 0.86); assinatura concluída: check com trim 400ms. Reduzir movimento: tudo vira fade 150ms.
Haptics: PIN impact light 0.6; seleção `.selection`; copiar/inverter impact light; assinatura e
broadcast `.success`; impacto >3% ou aprovação ilimitada `.warning`; erro `.error`.

## 6. Ícones
SF Symbols monochrome. Abas: Carteira `wallet.pass` (iOS 17), Mercado `chart.line.uptrend.xyaxis`,
Trade `arrow.left.arrow.right`, Atividade `clock.arrow.circlepath`. Ações: `arrow.up`, `arrow.down`,
`arrow.left.arrow.right`, `scope`. Ícone do app: inversão do Escalibur (laca #F5F5F6 com espada #070708).

## 7. Evitar
Halo/bolha de gradiente, neon, pill sólida com texto branco, vermelho em envio, fileira de KPI,
emoji/ilustração 3D, identicon colorido, pílula, caixa alta com tracking, mono em preço, filete entre
linhas, travessão, contagem animada do saldo, confete, esqueleto com brilho, sombra em cartão,
gráfico com grade, vocabulário de template ("Dashboard", "Gas fee").
