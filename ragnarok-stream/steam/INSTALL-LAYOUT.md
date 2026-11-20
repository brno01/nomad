# Instalar o layout do Steam Input (Ragnarok, Apex 3 via Sunshine)

Arquivo: `ragnarok-apex3.vdf` (gerado por `build_layout.py` a partir da tabela de teclas).
Controle alvo: `controller_xbox360` (o pad virtual do Sunshine com `gamepad = x360`).

> Aviso: o Steam não documenta o formato dos configs pessoais nem o `configset`.
> Tudo abaixo vem de posts de comunidade e de exemplos reais; o que não deu para
> confirmar está marcado com **INCERTO**. Não existe Steam neste ambiente de
> desenvolvimento, então nada disto foi testado no nomad ainda.

## 0. Pré-requisito: Steam Input para controles Xbox

Steam > Configurações > Controle > **Ativar Steam Input para controles Xbox**
(Settings > Controller > "Enable Steam Input for Xbox Controllers"). Sem isso o
Steam não intercepta o pad do Sunshine e nenhum layout é aplicado. Alternativa
por jogo: Propriedades do atalho > Controle > Substituir configurações >
"Ativar o Steam Input". Reinicie o Steam depois de mudar.

## 1. Onde o Steam lê (atalho não-Steam)

```
~/.local/share/Steam/steamapps/common/Steam Controller Configs/<accountid>/config/<chave>/controller_xbox360.vdf
```

- `<accountid>`: número da pasta em `~/.local/share/Steam/userdata/` (SteamID3).
- `<chave>`: para atalho não-Steam, a pasta é o **nome do atalho** como aparece
  na biblioteca, ou seja `Ragnarok (stream)` (não o appid). Evidência: o script
  de GiovanH usa `Steam Controller Configs/<STEAM_ID>/config/<SHORTCUT_NAME>/`
  para um atalho não-Steam, e relatos dizem que renomear o atalho "perde" o
  layout. **INCERTO**: se maiúsculas/minúsculas são preservadas (o exemplo do
  script usa `lutris`, minúsculo) e se há normalização de espaços/parênteses.
  Confirme criando qualquer mudança no layout pela interface e olhando o nome
  da pasta que o Steam cria.
- Nome do arquivo: `controller_<tipo>.vdf`, aqui `controller_xbox360.vdf`
  (RetroDECK lista `controller_xbox360.vdf` como o modelo do Xbox 360).

## 2. Como torná-lo o layout ativo

Há dois caminhos, do mais confiável ao mais incerto.

**A. Pasta de modelos (recomendado).** Copie o arquivo para
`~/.local/share/Steam/controller_base/templates/` (no Bazzite, `~/.steam/steam`
é um link para o mesmo lugar). Qualquer `.vdf` ali aparece na lista de
"Modelos" de qualquer jogo, inclusive não-Steam. Reinicie o Steam, abra
Propriedades do atalho "Ragnarok (stream)" > Controle > Configurar > Modelos e
escolha "Ragnarok Online - Apex 3 (stream)". O Steam grava a escolha sozinho
(inclusive o `configset`).

**B. Direto na pasta do atalho.** Copie para a pasta da seção 1. O Steam também
mantém `.../config/configset_controller_xbox360.vdf`, que diz qual config cada
chave usa (existe um `configset_controller_<tipo>.vdf` por tipo de controle; um
relato diz que apagar o trecho do app nele devolve o layout padrão). **INCERTO**:
o formato interno desse arquivo não está documentado em lugar nenhum que eu
tenha achado, por isso não o edite à mão: depois de copiar, selecione o layout
na interface (A) para o Steam atualizar o `configset`.

Com Steam fechado ao copiar, ele relê tudo ao abrir.

## 3. Itens do layout que precisam ser conferidos na interface

Abra Configurar e veja se o Steam não marcou nada como inválido:

1. Analógico esquerdo: modo "Região do mouse", raio ~30% da altura da tela,
   "devolver cursor ao desativar" **desligado**, anel externo = botão esquerdo
   do mouse (segurar). Os nomes dessas chaves no VDF são palpite (ver
   `# UNCERTAIN:` em `build_layout.py`); se vierem vazias, configure à mão.
2. LT/LB: devem aparecer como "Segurar camada de ação" para "Fileira 2" e
   "Janelas". Se o Steam mostrar o botão vazio, o token `HOLD_LAYER` está errado:
   refaça à mão e compare com o export (Configurar > engrenagem > Exportar).
3. Teclas provisórias: `Ctrl+F1..F9` (Fileira 2) e os `Alt+letra` (Janelas) -
   confirme no cliente do RO e ajuste a tabela no topo de `build_layout.py`.

## 4. Alternativa: montar à mão na interface do Steam

Propriedades do atalho > Controle > Configurar, e siga a tabela do
`build_layout.py` (seções BASE, ROW2, WINDOWS):

- Analógico esquerdo > Região do mouse; anel externo > Mouse > Botão esquerdo.
- Analógico direito > Joystick como mouse (sensibilidade moderada).
- Gatilho direito (pull total) > Mouse esquerdo; R3 > Mouse direito; L3 > Insert.
- A, B, X, Y > F1..F4; D-pad cima, direita, baixo, esquerda > F5..F8; RB > F9.
- Start > Esc; Back/View > Enter e, na mesma ativação, "Mostrar teclado na tela".
- Camadas: crie "Fileira 2" e "Janelas" (botão "Camadas de ação"); LT = "Segurar
  camada" Fileira 2, LB = "Segurar camada" Janelas; preencha cada camada pela tabela.
  Na camada Janelas, o analógico direito vira "Roda do mouse".
- Depois exporte (engrenagem > Exportar layout) e guarde o `.vdf` no repositório
  para comparar com o gerado.

## Fontes

- Estrutura dos configs (`controller_mappings` v3, grupos, presets, ativadores):
  exemplos reais em https://cdn.steamusercontent.com/ugc/1711916595917831914/11B5AF7BFCE250A8B38E0D9F75F1D954BA7F5053/
  e https://gist.github.com/Blucky87/bdff60a8d7feca5bcf82a0853db3a476 (inclui `action_layers`);
  guia (antigo) https://steamcommunity.com/sharedfiles/filedetails/?id=932405100
- Pasta e chave por nome do atalho: https://gist.github.com/GiovanH/c32d7e411e311de2a5db1f2b27248022
- `configset_controller_*.vdf` e caminho `Steam Controller Configs/<id>/config/`:
  https://steamcommunity.com/app/353370/discussions/2/695372712737073750/
- Renomear atalho perde o layout: https://steamcommunity.com/app/353370/discussions/0/3115897635597428643/
- Pasta de modelos `controller_base/templates` e `controller_xbox360.vdf`:
  https://retrodeck.readthedocs.io/en/latest/wiki_development/general/steam-input/
- Região do mouse e anel externo (conceitos da interface):
  https://partner.steamgames.com/doc/features/steam_controller/mouse_regions
- Camadas de ação: https://partner.steamgames.com/doc/features/steam_controller/action_set_layers
