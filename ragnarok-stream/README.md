# Ragnarok no celular (Sunshine + Moonlight, sem Steam)

Transmite o Ragnarok Online do nomad (Bazzite, KDE Plasma 6 Wayland, Intel Iris Xe) para o Galaxy S22+ (2340x1080) com Sunshine (servidor) e Moonlight (cliente). O jogo roda no Proton **fora do Steam**, via `umu-run` (umu-launcher), num prefixo dedicado; o controle virtual do Sunshine é traduzido em teclado e mouse pelo AntiMicroX. Não precisa de conta Steam nem de root.

> A versão com Steam Input (atalho não-Steam + layout `steam/ragnarok-apex3.vdf`) continua em `steam/`, **não é usada** e exige conta Steam: "alternativa com Steam Input (não usada; exige conta Steam)". Seus testes seguem rodando.

## O que cada peça faz

| Peça | Função |
|---|---|
| `umu/launch.sh` | Abre o `Ragexe_cerberus.exe` com `umu-run` (é o `cmd` do app no Sunshine, **em primeiro plano**: o script faz `exec` no `taskset`/`umu-run`, que só retornam quando o jogo fecha; é isso que faz o Sunshine encerrar a sessão e rodar os `undo`). Prefixo `~/.local/share/ragnarok-stream/pfx` (`RO_PREFIX`), `PROTONPATH=GE-Proton` (o umu baixa o GE-Proton mais recente; pode ser um caminho ou versão), `GAMEID=ragnarok-stream` (valor arbitrário: sem correções do umu-database), `STORE=none`. Ajustes portados do `iniciar-cerberus.sh`: `WINEDLLOVERRIDES=ddraw=n,b` (D7VK ao lado do exe), `WINE_CPU_TOPOLOGY=4:0,1,2,3` e `taskset` nos núcleos P (detectados com `lscpu` a cada execução), locale `pt_BR.UTF-8`, `PULSE_LATENCY_MSEC=60`, `WINEDEBUG=-all`, `DXVK_CONFIG_FILE` se existir `dxvk.conf` na pasta do jogo; diretório de trabalho = pasta do RO (`RO_DIR`, padrão `~/Desktop/RO`), mesmo exe e sem argumentos. `--dry-run` mostra env e comando. O `PULSE_SINK` do script original não foi portado (era contorno do Wine avulso). |
| `umu/bootstrap.sh` | Cria o prefixo (`umu-run wineboot -u`). **A primeira execução baixa o Steam Linux Runtime e o Proton (GBs, minutos).** Rode uma vez, em segundo plano, e espere. |
| `umu/setup-prefix.sh` | Copia a NanumGothic para o prefixo e importa, num único `.reg`, o font link, as substituições Gulim/Dotum/Batang e o DirectSound em emulação, via `umu-run regedit /S`; confere o resultado e grava um marcador. Sai com código 3 se o prefixo ainda não foi criado pelo bootstrap. |
| `umu/common.sh` | Ambiente umu e detecção dos núcleos P num só lugar (usado pelos três scripts acima). |
| `antimicrox/build_profile.py` | Gera o único perfil, `ragnarok.amgp`, a partir de tabelas declarativas (as linhas de atalhos do cliente são dados: `ROW1`, `ROW2`); `--check` confere se o arquivo no disco está atualizado. |
| `sunshine/antimicrox-start.sh` / `antimicrox-stop.sh` | O start sobe um **vigia** destacado (`setsid`, pid em `$XDG_RUNTIME_DIR/ragnarok-stream/antimicrox-watch.pid`, nunca mais de um). O Sunshine roda os `prep-cmd` ao conectar, mas o controle virtual só aparece segundos depois, quando o Moonlight manda entrada, e o AntiMicroX só aplica `--profile` aos controles que já existem ao iniciar. Por isso, a cada 1 s o vigia lê `/proc/bus/input/devices` e, sempre que o conjunto de `eventN` dos dispositivos cujo nome casa com `SUNSHINE_PAD_PATTERN` (padrão `X-?Box 360`) muda e não está vazio (o pad apareceu ou foi recriado numa reconexão), para a nossa instância e sobe uma nova do AntiMicroX (Flatpak, escondido, `--eventgen uinput`, com o perfil). O stop mata o vigia e o nosso AntiMicroX, só se a linha de comando do pid ainda for a nossa. Sempre saem com 0 e registram falhas em `LAST_ERRORS`. |
| `sunshine/vmon-start.sh` / `vmon-stop.sh` | Envolvem os helpers do Bazzite (`sunshine-start-vmon` / `sunshine-stop-vmon`) e criam o monitor virtual em tamanho reduzido: altura `RO_STREAM_HEIGHT` (padrão 720, ou a do cliente se menor), largura proporcional, ambas pares (S22+: 1560x720). **O start pode falhar a sessão** de propósito: sem monitor virtual o Sunshine capturaria o painel físico, que o `prep.sh` deixa apagado. Se o helper do Bazzite falhar depois de desligar os monitores físicos, o `vmon-start.sh` chama o `vmon-stop` sozinho (o Sunshine não roda o `undo` do comando que falhou). |
| `sunshine/ro-resolution.sh set\|restore` | Ajusta `savedata/OptionInfo.lua` do cliente para o tamanho do stream em tela cheia e depois devolve só essas chaves (WIDTH, HEIGHT, OLD_*, ISFULLSCREENMODE); outras opções mudadas no jogo ficam. O backup fica em `~/.local/state/ragnarok-stream/optioninfo.saved` (sobrevive a um reboot no meio do stream), junto com `optioninfo.orig.lua`, uma cópia byte a byte do arquivo original para recuperação manual (apagada só depois de um restore bem-sucedido). A escrita é atômica (arquivo temporário oculto na mesma pasta, depois `mv`). Como o jogo abre como comando `detached`, ele pode ainda estar rodando no `undo` e o RO regrava o arquivo ao sair: nesse caso o `restore` não mexe no arquivo e deixa **um** processo em segundo plano (pid em `waiter.pid`) esperando o jogo fechar, a cada 2 s, por até 6 h (`RO_WAIT_MAX`); se estourar, o backup fica e o erro é registrado. |
| `sunshine/prep.sh` / `undo.sh` | Escurece o painel e impede suspensão durante o stream; no `undo`, se o objeto D-Bus do painel salvo sumiu (depois do `vmon-stop` o KDE pode reexpor o painel interno com outro nome, ex.: `display0` para `display1`), usa o display interno atual; nunca falham (falhas reais do restore vão para `LAST_ERRORS`, abaixo). |
| `sunshine/install-app.sh` | Mescla o app "Ragnarok" no `apps.json` (sem tocar nos outros) e, com `--set-conf`, ajusta `sunshine.conf`: `capture = kwin`, `gamepad = x360`, `back_button_timeout = -1`, `system_tray = disabled`. Antes da primeira edição guarda `*.antes-ragnarok` (só para recuperação manual) e, ao lado do `sunshine.conf`, o estado anterior de cada chave em `sunshine.conf.ragnarok-keys`; o `--undo` devolve **só essas quatro chaves** e preserva o resto (inclusive o que você mudou na interface web). Se o app já existe, os campos que você adicionou (ex.: `image-path`) são mantidos. Arquivos inválidos abortam antes de qualquer escrita. |
| `../scripts/ragnarok-stream-install.sh` | Orquestra tudo (`--dry-run`, `--undo`, `--check`; `--skip-antimicrox/-sunshine/-prefix`). Não usa sudo. Os caminhos saem da localização do script, então a cópia implantada (`~/.local/share/ragnarok-stream` com `scripts/` e `ragnarok-stream/`) funciona sem ajuste. |

A ordem dos `prep-cmd` no app é: `prep.sh` (escurecer/inibir, ainda com o painel interno ligado para poder ler o brilho), monitor virtual, resolução do jogo, AntiMicroX. O Sunshine roda os `undo` na ordem inversa: o AntiMicroX para, a resolução volta, depois os painéis, e só então o brilho.

**Erros visíveis:** quando o `undo.sh` ou o `ro-resolution.sh` falham de verdade, eles continuam saindo com 0 (para não travar o Sunshine) mas acrescentam uma linha com data em `~/.local/state/ragnarok-stream/LAST_ERRORS`. O `ragnarok-stream-install.sh --check` falha enquanto esse arquivo existir, mostra o final dele e diz como limpar (`rm` do arquivo, depois de resolver a causa).

## Ordem das operações

1. No nomad: `ujust setup-sunshine enable-brew` e crie o login da interface web do Sunshine (`https://localhost:47990`).
2. Se o Sunshine der erro 503 na captura, aplique o ajuste do KWin (seção abaixo) e **saia e entre na sessão do KDE uma vez** para a variável valer.
3. Rode `scripts/ragnarok-stream-install.sh --dry-run` e, se estiver certo, `scripts/ragnarok-stream-install.sh`. Ele grava o drop-in do Sunshine, instala o AntiMicroX (Flatpak de usuário), confere o perfil e cria o app "Ragnarok". Reinicie o Sunshine.
4. Rode o bootstrap **uma vez e espere** (baixa GBs): `ragnarok-stream/umu/bootstrap.sh > /tmp/ragnarok-bootstrap.log 2>&1 &`.
5. Rode o instalador de novo: agora ele configura a fonte no prefixo. `scripts/ragnarok-stream-install.sh --check` confere o estado.
6. Pareie o Moonlight (PIN na interface web do Sunshine).
7. Configurações do Moonlight: resolução nativa 2340x1080 (ou 1080p), 60 fps, HEVC, 20 Mbps em casa e 10 Mbps fora. Fora de casa, adicione o host pelo IP do nomad no Tailscale (`tailscale ip -4` no nomad).
8. Para digitar no chat do jogo: um toque com **3 dedos** na tela abre o teclado do Moonlight (o botão X do controle manda Enter e abre o chat; o texto vem do teclado do Moonlight).

## Como a sessão termina (importante)

O app do Sunshine usa o jogo como `cmd` bloqueante (sem lista `detached`). Assim:

- **Fechar o Ragnarok** encerra a sessão e o Sunshine roda todos os `undo` na ordem inversa (AntiMicroX, resolução, monitor virtual, brilho/inibidor).
- **"Sair do app"** no Moonlight (Quit app) fecha o jogo e também dispara os `undo`.
- **Só desconectar** o Moonlight deixa o jogo rodando para você reconectar; o notebook continua no monitor virtual, com o painel apagado e o inibidor ativo, até você fechar o jogo ou usar "Sair do app".

## Controle: perfil do AntiMicroX

Alvo: controle Xbox 360 (SDL GameController), o que o Sunshine expõe com `gamepad = x360`. Esquema do `.amgp` lido do código do AntiMicroX (`src/xml/*`, `gamecontrollerset.cpp`; URLs no cabeçalho de `build_profile.py`). Flags usadas (`src/commandlineutility.cpp`): `--hidden`, `--profile`, `--eventgen uinput`.

O cliente usa **atalhos próprios** (`savedata/UserKeys_s.lua`): linha 1 = teclas `1`..`9`, linha 2 = Shift+`1`..`9`, linha 3 = teclado numérico 1..9; F1..F9 não estão ligadas a nada (por isso o mapeamento antigo em F1..F9 não fazia nada). O perfil segue a lógica de console: A confirma, B volta.

| | Conjunto 1 (base) | Conjunto 2 (RT segurado: resto da linha 1) | Conjunto 3 (LB segurado: linha 2) | Conjunto 4 (RB segurado: janelas) |
|---|---|---|---|---|
| Analógico esquerdo | mouse relativo | igual | igual | igual |
| Analógico direito | roda do mouse (cima/baixo) | igual | igual | igual |
| LT | botão direito do mouse (segurado) | igual | igual | igual |
| A / B / X / Y | botão esquerdo (segurado) / Esc / Enter / Insert | `5` / `6` / `7` / `8` | Shift+`5` / `6` / `7` / `8` | Alt+E / Alt+S / Alt+Q / Alt+A |
| D-pad cima/direita/baixo/esquerda | `1` / `2` / `3` / `4` | `1` / `2` / `3` / `4` | Shift+`1` / `2` / `3` / `4` | Ctrl+Tab / Alt+Z / Alt+G / Alt+U |
| RB | segurar = conjunto 4 | `9` | Shift+`9` | volta ao 1 |
| RT | segurar = conjunto 2 | volta ao 1 | (nada) | (nada) |
| LB | segurar = conjunto 3 | (nada) | volta ao 1 | (nada) |
| Start / Back | Esc / Alt+E | (nada) | (nada) | (nada) |
| L3 / R3 | (nada) | (nada) | (nada) | (nada) |

- **Segurar LT + analógico esquerdo** gira a câmera (botão direito + mouse).
- O analógico esquerdo é mouse **relativo** com a curva "Enhanced Precision" e zona morta de ~15% (`STICK_DEADZONE = 4915` de 32767). **Botão de ajuste da velocidade:** `LEFT_STICK_SPEED` em `antimicrox/build_profile.py` (padrão 25; o padrão do AntiMicroX é 50; suba para um ponteiro mais rápido). Depois de mudar: `python3 -I ragnarok-stream/antimicrox/build_profile.py`.
- O analógico direito usa só a roda vertical (zoom); esquerda/direita ficam livres de propósito, porque a roda horizontal é rápida demais no `uinput` (AntiMicroX issue #1024).
- **Sem modo Spring:** ele não move o ponteiro no KDE Wayland (AntiMicroX issue #521: o dispositivo `uinput` aparece como caneta; só saía o clique segurado).
- RT, LB e RB usam "Mudar de conjunto" no modo **enquanto segurado** (`setselectcondition = while-held`); nos conjuntos 2 a 4 o mesmo botão volta ao 1, como o próprio AntiMicroX grava.

Itens marcados `# UNCERTAIN:` no gerador: nada foi carregado num AntiMicroX real; a unidade de `mousespeedx/y` e a sensação da curva (por isso o botão de ajuste); a zona morta é em unidades brutas do eixo; os conjuntos 2 a 4 só repetem os botões listados. O `/dev/uinput` está acessível ao usuário pelas regras udev que o postinst do Sunshine instala (só isso foi assumido; o Flatpak recebe `--device=all`).

## Login automático (opcional)

O login por argumento (SSO: `-t:<senha> <usuário> ...`) **não funciona neste servidor** ("Conta nao registrada"). Por isso o login automático **digita a senha no formulário normal** com o `ydotool`.

**Como funciona.** Se existir o arquivo `~/.config/ragnarok-stream/login` (outro caminho: `RO_LOGIN_FILE`) válido e o socket do `ydotoold` existir, o `umu/launch.sh` inicia, destacado e logo antes de abrir o jogo, o `umu/autotype-login.sh` (log em `$XDG_RUNTIME_DIR/ragnarok-stream/autotype.log`). Ele relê e valida o arquivo sozinho (a senha **nunca** passa por argumento nem por variável de ambiente), e então:

1. espera até `RO_TYPE_TIMEOUT` (120 s, consulta a cada 1 s) a janela X **ativa** ter "Ragnarok" no nome (`xdotool getactivewindow getwindowname`) e existir um processo `Ragexe_cerberus`;
2. espera `RO_LOGIN_DELAY` (5 s) para o diálogo de login ser desenhado e confere de novo a janela ativa;
3. só se ainda for o Ragnarok: `printf %s "$senha" | ydotool type -d 40 -H 20 -f -` (a senha vai só pela entrada padrão) e depois `ydotool key 28:1 28:0` (Enter). Faz isso uma vez e sai.

Se a janela não estiver ativa (na conferência ou por timeout), **não digita nada** e registra "auto-login skipped: Ragnarok window not active" em `LAST_ERRORS` (o `--check` mostra). A senha nunca é impressa; o log só diz "typed N chars".

**Requisitos**
- "Memorizar" marcado no cliente, com o ID salvo: o formulário abre com o usuário preenchido e o foco no campo da **senha**, então digitar a senha + Enter faz o login.
- `ydotoold` rodando na sessão do usuário, com o socket em `$XDG_RUNTIME_DIR/.ydotool_socket` (`YDOTOOL_SOCKET` troca o caminho; sem ele o `ydotool` procura em `/tmp` e falha), e `xdotool` instalado (a janela do RO é uma janela X11 do Xwayland).
- O `ydotool` digita códigos de tecla do layout **US**: senhas só com letras e números são seguras; símbolos podem sair diferentes no ABNT2.

**Criar o arquivo** (você mesmo, no nomad; nada neste repositório o escreve nem o imprime):

```
install -d -m700 ~/.config/ragnarok-stream
install -m600 /dev/null ~/.config/ragnarok-stream/login
$EDITOR ~/.config/ragnarok-stream/login     # linha 1: usuário, linha 2: senha
```

O arquivo só é usado se for um arquivo comum (link simbólico é recusado), seu, com permissão 600 ou 400 e com as duas linhas preenchidas; caso contrário o jogo abre normalmente e o `launch.sh` registra o motivo (nunca a senha). Sem o socket do `ydotool`, também não digita nada.

**Ajuste:** se o diálogo demora a aparecer e a senha cai antes dele, aumente `RO_LOGIN_DELAY` (variável de ambiente do `launch.sh`).

**Segurança:** o arquivo guarda a senha em **texto puro** (por isso as permissões 600/400); use uma senha que você não reutiliza em outros lugares. Se a janela ativa não for o Ragnarok no momento de digitar, nada é digitado (a senha não vai parar em outro programa).

**Desligar:** `rm ~/.config/ragnarok-stream/login`. O `ragnarok-stream-install.sh --check` informa se o arquivo existe; com arquivo válido, falha se faltar o socket do `ydotool`, o `ydotool` ou o `xdotool`, e falha se o arquivo existir com permissão ou conteúdo inválidos.

## Serviço do Sunshine no Homebrew: drop-in e capabilities

- A unidade systemd de usuário do Sunshine instalado pelo Homebrew chama-se `app-dev.lizardbyte.app.Sunshine.service` (alias `sunshine.service`), **não** `homebrew.sunshine`. O instalador grava `~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/10-nomad-enhancement.conf` (arquivo versionado em `sunshine/10-nomad-enhancement.conf`) e roda `systemctl --user daemon-reload`; reinicie o Sunshine depois. Ele define `LIBVA_DRIVERS_PATH=/usr/lib64/dri` e `LIBVA_DRIVER_NAME=iHD`, porque a libva do Homebrew só procura em `/home/linuxbrew/.linuxbrew/lib/dri` (link para o keg do mesa) e o driver Intel iHD fica em `/usr/lib64/dri`; sem isso o Sunshine cai para x264 em software. Também define `ExecStopPost=-/usr/libexec/sunshine-stop-vmon` (o `-` torna a falha do helper inofensiva, a unidade não fica "failed"), o ajuste que o `ujust setup-sunshine` não aplica por mirar a unidade `homebrew.sunshine`.
- **Capabilities de arquivo:** o postinst do Homebrew roda `setcap cap_sys_admin,cap_sys_nice+p` no binário do Cellar. Isso torna o processo "AT_SECURE" e a glibc (`secure_getenv`) faz a libva **ignorar** `LIBVA_DRIVERS_PATH`. Como usamos captura KWin (não KMS), as capabilities são desnecessárias. O `ragnarok-stream-install.sh --check` falha se `getcap` mostrar algo no binário e imprime a correção: `sudo setcap -r <binário>` (o instalador nunca roda sudo). Atenção: um `brew upgrade` do sunshine, ou rodar o postinst de novo, traz as capabilities de volta; rode o `--check` depois de atualizar e remova-as outra vez.

## O "Fix Error 503" do KWin: o que se perde

Com `capture = kwin`, o Sunshine pede ao KWin protocolos Wayland privilegiados (screencast). Se aparecer o erro 503, a correção popular é iniciar a sessão com `KWIN_WAYLAND_NO_PERMISSION_CHECKS=1`. Isso **desliga as checagens de permissão do KWin para os protocolos Wayland privilegiados, para todos os aplicativos da sessão**: qualquer programa passa a poder, por exemplo, capturar a tela ou injetar entrada sem pedir autorização. É aceitável num notebook pessoal e de uso próprio, mas é um enfraquecimento real. Só aplique se o 503 aparecer.

Para desfazer: remova a variável de onde você a colocou (por exemplo uma linha em `~/.config/plasma-workspace/env/*.sh` ou em `~/.config/environment.d/*.conf`), e saia e entre na sessão de novo.

## Reverter

- `scripts/ragnarok-stream-install.sh --undo`: remove o app do Sunshine, devolve as quatro chaves do `sunshine.conf` ao estado anterior e remove o drop-in. **Não** desinstala o AntiMicroX nem apaga o prefixo (ele imprime os comandos): `flatpak uninstall --user io.github.antimicrox.antimicrox` e `rm -rf ~/.local/share/ragnarok-stream/pfx`.
- Se um stream morrer no meio e o jogo ficar em 720p: rode `ragnarok-stream/sunshine/ro-resolution.sh restore` (se ainda falhar, a cópia original está em `~/.local/state/ragnarok-stream/optioninfo.orig.lua`), `sunshine/vmon-stop.sh`, `sunshine/antimicrox-stop.sh` e `sunshine/undo.sh`.

## Testes

```
bats tests/
uv run --no-project --with pytest --with vdf pytest ragnarok-stream/tests -q
shellcheck -x scripts/*.sh ragnarok-stream/sunshine/*.sh ragnarok-stream/umu/*.sh
```
