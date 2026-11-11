# nomad-enhancement

<!-- Gerado por dev-project em 2026-11-10. Mantenha curto (< 200 linhas): só o que o Claude não descobre sozinho lendo o código. -->

## Visão geral
- Área: personal
- O que é: melhorias e automações para o nomad (Bazzite, sistema imutável): scripts e dotfiles.

## Stack
Shell scripts (bash) e arquivos de configuração. Sem gerenciador de pacotes por enquanto. Ferramentas via Homebrew (`brew`); dependências pesadas em `distrobox`/contêiner. Não usar `dnf`.

## Comandos
| Ação | Comando |
|---|---|
| Lint | `shellcheck scripts/*.sh` |
| Testes | `bats tests/` |

## Estrutura
- `scripts/wifi-powersave.sh`: desliga o power save do Wi-Fi de vez (drop-in do NetworkManager em `/etc/NetworkManager/conf.d/`) e na hora (`iw`). Com ele ligado, o tráfego que chega ao nomad (tailnet, DNS do Pi-hole) esperava 30–100 ms. Aceita `--dry-run` e `--undo`.
- `scripts/dns-failover.sh`: instalado como `/usr/local/bin/nomad-dns-failover`; a cada 30 s testa o Pi-hole (`100.64.0.10`) e, após 2 falhas, roda `tailscale set --accept-dns=false`; religa quando ele volta (só o que ele mesmo desligou).
- `scripts/dns-failover-install.sh`: instala o binário e `nomad-dns-failover.{service,timer}`. Aceita `--dry-run` e `--undo`.
- `tests/`: testes `bats` (`bats tests/`).

## Contexto da rede
- O DNS da tailnet é só o Pi-hole (o Tailscale consulta todos os nameservers em paralelo, então resolvers públicos na lista furavam o bloqueio). O failover da tailnet inteira roda no GitHub Actions (repo público `brno01/tailnet-dns-failover`); o `dns-failover` daqui cobre o nomad em ~1 min.

## Convenções
- Branch padrão: `master`. Trabalhe em branches de feature.
- Scripts em bash com `set -euo pipefail`; devem ser idempotentes.
- A configuração global do Claude (settings, CLAUDE.md, skills) vive em `~/development/dotfiles`, não aqui.

## Cuidados
- Sistema imutável: mudanças no host podem não persistir ou exigir `rpm-ostree`; prefira Homebrew, distrobox ou configs em `$HOME`.
