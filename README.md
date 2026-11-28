# nomad

[![ci](https://github.com/brno01/nomad/actions/workflows/ci.yml/badge.svg)](https://github.com/brno01/nomad/actions/workflows/ci.yml)
[![security](https://github.com/brno01/nomad/actions/workflows/security.yml/badge.svg)](https://github.com/brno01/nomad/actions/workflows/security.yml)

Melhorias e automações para o notebook "nomad", que roda Bazzite (sistema imutável). O repositório reúne scripts de ajuste do sistema, um exportador que documenta o nomad no Obsidian, um vigia que mantém o cofre organizado e a montagem do `ragnarok-stream` (Ragnarok Online transmitido para o celular com Sunshine e Moonlight).

## Estado
Em uso diário no nomad. Os scripts e os serviços rodam na máquina do dono; este repositório é a fonte versionada deles.

## Requisitos e instalação
- Bazzite (ou outro Linux com `systemd --user`), `bash`, `git`.
- Ferramentas de CLI pelo Homebrew; dependências pesadas em `distrobox` ou contêiner. Não use `dnf`.
- Python via `uv` (nada de `pip install` global). O exportador e o vigia usam só a biblioteca padrão; o `uv` entra para rodar os testes.
- Para desenvolver: `shellcheck`, `bats` e `gitleaks`.
- Ative o hook que barra segredos, uma vez por clone: `git config core.hooksPath .githooks`.

Os instaladores em `scripts/` aceitam `--dry-run` (mostra o que faria) e `--undo` (desfaz). Rode sempre o `--dry-run` antes.

## Uso
| O que | Comando |
|---|---|
| Desligar o power save do Wi-Fi | `scripts/wifi-powersave.sh` |
| Instalar o failover de DNS (binário, service e timer) | `scripts/dns-failover-install.sh` (lê `PIHOLE_IP` do ambiente ou do `config.local.env`, copiado de `config.example.env`) |
| Instalar o exportador do Obsidian (timer a cada 10 min) | `scripts/obsidian-install.sh` |
| Exportar para o Obsidian à mão | `uv run --no-project python -I obsidian/export_nomad.py` (`--dry-run`, `--force`) |
| Instalar o vigia do Obsidian | `scripts/guardian-install.sh` |
| Relatório do vigia | `python3 -I obsidian/guardian.py --report` |
| Instalar o Ragnarok no celular | `scripts/ragnarok-stream-install.sh` (`--check` confere o estado) |
| Instalar o S22 microscópio (Windows) | `pwsh -File windows/instalar-s22.ps1` (`-Desfazer` remove) |
| Ver a câmera do S22 ao vivo (Windows) | menu Iniciar > **S22 microscopio** (Ctrl+Alt+M), ou `s22-microscopio.ps1 [-Zoom 2] [-Lanterna] [-Gravar x.mp4] [-SemFio ip:porta] [-Parear ip:porta]` |

## Testes e CI
```bash
shellcheck scripts/*.sh
bats tests/
uv run --no-project --with pytest pytest obsidian/tests
uv run --no-project --with pytest --with vdf pytest ragnarok-stream/tests -q
pwsh -NoProfile -File windows/tests/test_s22_microscopio.ps1   # ou, sem pwsh: podman run --rm -v "$PWD:/repo:Z" -w /repo mcr.microsoft.com/powershell:lts-ubuntu-22.04 pwsh -NoProfile -File windows/tests/test_s22_microscopio.ps1
```
Estado conhecido: `obsidian/tests/test_guardian.py` falha ao importar (o `guardian.py` usa `@dataclass` num módulo carregado por `importlib` sem registro em `sys.modules`); por isso o CI roda `obsidian/tests` com `--ignore=obsidian/tests/test_guardian.py`. Os testes de `pre-commit.bats` precisam do `gitleaks` com o subcomando `git` (versão recente) e são pulados no CI.

No GitHub, todo PR e todo push na `master` rodam dois workflows:
- `ci`: shellcheck, bats, os testes Python do exportador e do `ragnarok-stream` e os testes PowerShell do `windows/`.
- `security`: segredos, dependências vulneráveis, análise estática, shellcheck e os próprios workflows. Uma falha na `master` abre uma issue `security-scan`.

O `claude` é o revisor sob demanda: comente `@claude` num PR ou numa issue, ou rode o workflow à mão para uma auditoria que abre issues. Só o dono do repositório consegue acioná-lo.

## Estrutura
- `scripts/`: instaladores e scripts do sistema (Wi-Fi, failover de DNS, exportador, vigia, ragnarok-stream).
- `obsidian/`: `export_nomad.py` (documenta o nomad no cofre, no formato do exportador do Cerberus), `sources.toml` (fontes e nós do mapa), `guardian.py` + `guardian.toml` (vigia do cofre) e `tests/`.
- `ragnarok-stream/`: perfis, scripts de Sunshine e umu, AntiMicroX e testes; veja `ragnarok-stream/README.md`.
- `tests/`: testes `bats` dos scripts.
- `windows/`: o nomad em Windows 11 (desde 24/11/2026). `s22-microscopio.ps1` mostra a câmera traseira do Galaxy S22 ao vivo pelo scrcpy (cabo USB por padrão, ou depuração sem fio; zoom com Alt+↑/↓ e lanterna com Alt+T na janela) e `instalar-s22.ps1` instala o lançador e o atalho. O S22/S22+ não tem lente macro (foco mínimo de uns 10 cm): para aumento de verdade, use uma lente de clipe. No S22, uma vez: Opções do desenvolvedor > Depuração USB, e aceitar "Permitir depuração USB" ao plugar.
- `docs/`: páginas de apoio (`aviso-iphone.html`).
- `.githooks/`: hook `pre-commit` com o gitleaks.

Detalhes de arquitetura e cuidados: `CLAUDE.md`.

## Segurança e cuidados
- Sistema imutável: mudanças no host podem não persistir; prefira Homebrew, distrobox ou configurações em `$HOME`.
- Scripts em bash com `set -euo pipefail` e idempotentes.
- O hook `pre-commit` barra segredos e falha fechado se o `gitleaks` não existir.
- O exportador só escreve em notas com o marcador `gerado por`; ajuste o `sources.toml`, não as notas geradas.

## Licença
[MIT](LICENSE)
