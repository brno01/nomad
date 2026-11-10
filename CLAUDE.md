# melhorias-no-nomad

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
| Testes | _(definir quando existirem; sugestão: `bats tests/`)_ |

## Estrutura
_(preencher conforme o projeto crescer; sugestão: `scripts/` para os scripts, `tests/` para testes)_

## Convenções
- Branch padrão: `master`. Trabalhe em branches de feature.
- Scripts em bash com `set -euo pipefail`; devem ser idempotentes.
- A configuração global do Claude (settings, CLAUDE.md, skills) vive em `~/development/dotfiles`, não aqui.

## Cuidados
- Sistema imutável: mudanças no host podem não persistir ou exigir `rpm-ostree`; prefira Homebrew, distrobox ou configs em `$HOME`.
