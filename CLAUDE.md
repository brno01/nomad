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
| Ativar o hook de segredos (uma vez por clone) | `git config core.hooksPath .githooks` (precisa de `brew install gitleaks`) |
| Instalar o vigia do Obsidian (sempre rodando) | `scripts/guardian-install.sh` (`--dry-run`, `--undo`); relatório: `python3 -I obsidian/guardian.py --report` |
| Testes do exportador | `uv run --no-project --with pytest pytest obsidian/tests` |
| Exportar para o Obsidian | `uv run --no-project python -I obsidian/export_nomad.py` (`--dry-run`, `--force`) |

## Estrutura
- `scripts/wifi-powersave.sh`: desliga o power save do Wi-Fi de vez (drop-in do NetworkManager em `/etc/NetworkManager/conf.d/`) e na hora (`iw`). Com ele ligado, o tráfego que chega ao nomad (tailnet, DNS do Pi-hole) esperava 30–100 ms. Aceita `--dry-run` e `--undo`.
- `scripts/dns-failover.sh`: instalado como `/usr/local/bin/nomad-dns-failover`; a cada 30 s testa o Pi-hole (endereço em `PIHOLE_IP`, vindo de `config.local.env`) e, após 2 falhas, roda `tailscale set --accept-dns=false`; religa quando ele volta (só o que ele mesmo desligou).
- `scripts/dns-failover-install.sh`: instala o binário e `nomad-dns-failover.{service,timer}`. Aceita `--dry-run` e `--undo`.
- `obsidian/export_nomad.py`: documenta o nomad no cofre do NAS (`/var/mnt/nas/vault/projects/nomad`, o mesmo que o Obsidian abre) no mesmo formato do exportador do Cerberus: `Central do nomad` → `map/` (Componentes, Sistema, Serviços, Repositórios, Documentação, Atalhos) → notas, cada uma com `Pai:`. Lê os repos pelo HEAD (commits, não a árvore de trabalho), só escreve se algo mudou e nunca toca notas sem o marcador `gerado por`. Repos git novos em `~/development/personal` entram sozinhos em "Novos (classificar)".
- `obsidian/sources.toml`: fontes (inclusive `/root/nomad` no atheron por SSH (`ssh://atheron-nomad-git/...`, Host do `~/.ssh/config.d/tailnet.conf` do dotfiles: porta 2222, chave `nomad-export_ed25519`; url que começa com `-` é recusada), espelhado em `~/.cache/nomad-obsidian`; se a url mudar, o exportador atualiza o remote do espelho), nós do mapa, descrições fixas e ligações de notas manuais. Ajuste aqui, não nas notas geradas.
- `scripts/obsidian-install.sh`: instala `nomad-obsidian.{service,timer}` (systemd --user, a cada 10 min) e mescla as cores do nomad no `graph.json` do cofre. Aceita `--dry-run` e `--undo`.
- `obsidian/guardian.py` + `obsidian/guardian.toml`: vigia que roda sempre (`nomad-obsidian-guardian.service`, systemd --user, confere o cofre a cada 20 s e age quando ele sossega). Mantém o `graph.json`: cor de cada projeto (central), **hubs** (tag `mapa` + `map/<tipo>`) em cores fortes e **folhas** (tag de tipo: guia, pesquisa, decisao…) em tons apagados, o resto do projeto em cinza (projeto novo ganha a próxima cor da paleta; seus grupos ficam), busca padrão = só o esqueleto (centrais + `map/` + `shortcuts/`, montada dos projetos que existem; se você mudar a busca, ela fica) e forças pensadas para árvore. Mantém nos Favoritos o grupo **"Grafo (vigia)"** com vistas salvas (Mapa, Tudo, Conversas, uma por projeto) e conserta favoritos mortos. Nas notas que ninguém gera completa `Pai:` e tags (sempre dentro do mesmo projeto), troca `Pai:` morto, normaliza tags/status pelo vocabulário (`~/development/dotfiles/claude/second-brain/taxonomia.toml`: sinônimo vira a tag canônica, tag fora do vocabulário vira `topico/<nome>`), move duplicatas geradas para `archive/guardiao/<data>/` (nunca apaga) e corrige links quebrados só quando há um único alvo. Notas com o marcador "gerado por/pelo" nunca são editadas. A central de cada projeto só vale se abrir de verdade (o cache de diretório do cifs lista entradas que o servidor já apagou). Se o `graph.json` for regravado sem os grupos 5 vezes em 10 min (Obsidian aberto), ele pausa 5 min. O que não resolve sozinho vai para `~/.local/state/obsidian-guardian/report.md`; `guardian.py --coverage` mostra quantas notas cada cor pinta e quais ficam sem cor. **Cada grupo de cor tem uma cor só sua** (regra do usuário, 14/11/2026): nenhuma se repete nem se parece com outra (distância CIE Lab ≥ 20; `guardian.py --lint-colors` e testes conferem), projeto novo ganha a cor vívida mais distinta das já usadas e cada projeto tem o próprio cinza-apagado para "o resto"; a nota **"Legenda do grafo"** (cor, grupo, o que contém) é gerada da mesma lista e fica ligada ao Home. Cores, nó central de cada projeto, pastas ignoradas e aparência do grafo ficam no `guardian.toml`.
- `scripts/guardian-install.sh`: instala o serviço do vigia. Aceita `--dry-run` e `--undo`.
- `.githooks/pre-commit`: roda `gitleaks git --staged --redact` e barra o commit com segredo (falha fechado se o gitleaks não existir). Versionado; cada clone liga com `core.hooksPath`.
- `tests/`: testes `bats` (`bats tests/`); `obsidian/tests/`: pytest do exportador.

## Contexto da rede
- O DNS da tailnet é só o Pi-hole (o Tailscale consulta todos os nameservers em paralelo, então resolvers públicos na lista furavam o bloqueio). O failover da tailnet inteira roda no GitHub Actions (repo público `brno01/tailnet-dns-failover`); o `dns-failover` daqui cobre o nomad em ~1 min.

## Convenções
- Branch padrão: `master`. Trabalhe em branches de feature.
- Scripts em bash com `set -euo pipefail`; devem ser idempotentes.
- A configuração global do Claude (settings, CLAUDE.md, skills) vive em `~/development/dotfiles`, não aqui.

## Cuidados
- Sistema imutável: mudanças no host podem não persistir ou exigir `rpm-ostree`; prefira Homebrew, distrobox ou configs em `$HOME`.

## Detalhes locais
Endereços e outros fatos reais desta máquina ficam no `CLAUDE.local.md` (não versionado) e no `config.local.env` (copiado de `config.example.env`). O repositório é público: não versione nenhum dos dois.
