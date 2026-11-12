"""Testes do exportador: repos git de fixture + cofre temporário.

uv run --with pytest pytest obsidian/tests
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import export_nomad as ex  # noqa: E402  (precisa do sys.path acima)

GIT_ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t", "HOME": "/nonexistent", "PATH": "/usr/bin:/bin"}


def sh(cwd: Path, *args: str) -> None:
    subprocess.run(args, cwd=cwd, check=True, capture_output=True, env=GIT_ENV)


def commit(repo: Path, files: dict[str, str], msg: str) -> None:
    for rel, content in files.items():
        p = repo / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", msg)


def init(path: Path) -> Path:
    path.mkdir(parents=True)
    sh(path, "git", "init", "-q", "-b", "master")
    return path


@pytest.fixture
def env(tmp_path: Path):
    personal = tmp_path / "personal"
    tools = init(personal / "tools")
    commit(tools, {
        "CLAUDE.md": textwrap.dedent("""\
            # tools
            ## Visão geral
            - O que é: ferramentas do nomad.
            ## Comandos
            | Ação | Comando |
            |---|---|
            | Testes | `bats tests/` |
            ## Estrutura
            - `scripts/net.sh`: liga a rede.
            """),
        "scripts/net.sh": "#!/usr/bin/env bash\n# Usage: net.sh [--undo]\nset -e\n",
        "scripts/other.sh": "#!/usr/bin/env bash\n# Faz outra coisa.\n",
        "units/tools-sync.service": "[Unit]\nDescription=Sincroniza as ferramentas\n[Service]\nEnvironment=API_TOKEN=abc123\n",
    }, "Add tools")
    bare = tmp_path / "remote.git"
    seed = init(tmp_path / "seed")
    commit(seed, {"README.md": "# pendrive\n\nO sistema do pendrive.\n", "build/make.sh": "# Monta o disco.\n"}, "Initial")
    sh(tmp_path, "git", "clone", "-q", "--bare", str(seed), str(bare))

    vault = tmp_path / "vault"
    (vault / ".obsidian").mkdir(parents=True)
    (vault / ".obsidian/graph.json").write_text(json.dumps({
        "search": 'path:"projects/cerberus/map"',
        "colorGroups": [{"query": "tag:#map/docs", "color": {"a": 1, "rgb": 1}}]}))
    (vault / "Home.md").write_text("---\ntype: home\n---\n<!-- cerberus-central -->\n> [!info] Central do Cerberus\n> links\n\n# Início\n")
    manual = vault / "projects/nomad/melhorias/Rede rápida.md"
    manual.parent.mkdir(parents=True)
    manual_text = "---\ntype: decision\n---\n# Rede rápida\n\nA rede com net.sh e a tailnet. tailnet e tailnet.\n- [ ] testar de novo\n"
    manual.write_text(manual_text)

    cfg = tmp_path / "sources.toml"
    cfg.write_text(textwrap.dedent(f"""\
        vault = "{vault}"
        discover = ["{personal}"]
        [[source]]
        name = "pendrive"
        url = "file://{bare}"
        [[source]]
        name = "tools"
        path = "{tools}"
        keywords = ["net.sh"]
        [[entity]]
        name = "Rede"
        group = "sistema"
        summary = "A rede."
        keywords = ["tailnet"]
        files = ["tools:scripts/net"]
        """))
    args = ["--config", str(cfg), "--state", str(tmp_path / "state.json"),
            "--cache", str(tmp_path / "cache"), "--no-system"]
    return {"tmp": tmp_path, "vault": vault, "root": vault / "projects/nomad", "tools": tools,
            "personal": personal, "args": args, "manual": manual, "manual_text": manual_text, "cfg": cfg}


def run(env, *extra: str) -> int:
    return ex.main([*env["args"], *extra])


def wikilinks(text: str) -> list[str]:
    return [m.split("|")[0].rstrip("\\") for m in re.findall(r"\[\[([^\]]+)\]\]", text)]


def test_tree_has_no_orphans_and_no_broken_links(env):
    assert run(env) == 0
    root, vault = env["root"], env["vault"]
    notes = {p.relative_to(vault).with_suffix("").as_posix(): p.read_text() for p in root.rglob("*.md")}
    inbound = {k: 0 for k in notes}
    for src, text in notes.items():
        for target in wikilinks(text):
            target = target.split("#")[0]
            if target.startswith("projects/nomad/") and not target.endswith(".base"):
                assert target in notes, f"link quebrado em {src}: {target}"
                if target != src:
                    inbound[target] += 1
    orphans = [k for k, n in inbound.items() if n == 0 and not k.endswith("Central do nomad")]
    assert orphans == []
    for k, text in notes.items():  # toda nota gerada tem um pai
        if ex.GENERATED_BY in text and not k.endswith("Central do nomad"):
            assert "\nPai: [[" in text, k


def test_content_from_repos(env):
    run(env)
    root = env["root"]
    mod = (root / "map/tools - scripts.md").read_text()
    assert "liga a rede." in mod and "Faz outra coisa." in mod
    assert "Pai: [[projects/nomad/map/tools (repo)|tools (repo)]]" in mod
    assert "O sistema do pendrive." in (root / "map/pendrive (repo).md").read_text()  # remoto espelhado
    svc = (root / "map/tools-sync.service.md").read_text()
    assert "Sincroniza as ferramentas" in svc and "abc123" not in svc and "‹omitido›" in svc
    rede = (root / "map/Rede.md").read_text()
    assert "scripts/net.sh" in rede and "Rede rápida" in rede
    assert "testar de novo" in (root / "Central do nomad.md").read_text()
    assert "net.sh [--undo]" in (root / "shortcuts/Comandos.md").read_text()
    assert "tags: [nomad, map/repos, mapa]" in mod


def test_manual_notes_untouched_and_second_run_writes_nothing(env, capsys):
    run(env)
    assert env["manual"].read_text() == env["manual_text"]
    mtimes = {p: p.stat().st_mtime_ns for p in env["root"].rglob("*") if p.is_file()}
    capsys.readouterr()
    run(env)
    assert "nada mudou" in capsys.readouterr().out
    assert {p: p.stat().st_mtime_ns for p in env["root"].rglob("*") if p.is_file()} == mtimes


def test_new_commit_shows_in_novidades_and_removed_module_is_deleted(env):
    run(env)
    assert (env["root"] / "map/tools - units.md").exists()
    sh(env["tools"], "git", "rm", "-q", "-r", "units")
    commit(env["tools"], {"scripts/new.sh": "# Script novo.\n"}, "Drop units, add new.sh")
    run(env)
    assert not (env["root"] / "map/tools - units.md").exists()
    nov = (env["root"] / "history/Novidades do cofre.md").read_text()
    assert "Drop units, add new.sh" in nov
    assert "tools - units" in nov  # removida


def test_uncommitted_work_is_ignored(env):
    run(env)
    (env["tools"] / "scripts/wip.sh").write_text("# rascunho\n")
    run(env)
    assert "wip.sh" not in (env["root"] / "map/tools - scripts.md").read_text()


def test_discovered_repo_goes_to_novos(env):
    run(env)
    init(env["personal"] / "brand-new")
    commit(env["personal"] / "brand-new", {"README.md": "# x\n\nProjeto novo.\n"}, "Init")
    run(env)
    novos = (env["root"] / "map/Novos (classificar).md").read_text()
    assert "brand-new" in novos
    assert "Pai: [[projects/nomad/map/Novos (classificar)" in (env["root"] / "map/brand-new (repo).md").read_text()


def test_user_file_at_generated_path_is_not_overwritten(env):
    p = env["root"] / "map/Sistema.md"
    p.parent.mkdir(parents=True)
    p.write_text("minha nota\n")
    run(env)
    assert p.read_text() == "minha nota\n"


def test_unreachable_remote_is_reported_not_fatal(env):
    cfg = env["cfg"]
    cfg.write_text(cfg.read_text().replace("file://", "file:///nonexistent"))
    assert run(env) == 0
    assert "indisponível" in (env["root"] / "Central do nomad.md").read_text()


def test_home_block_inserted_once_after_cerberus(env):
    run(env)
    run(env, "--force")
    home = (env["vault"] / "Home.md").read_text()
    assert home.count(ex.HOME_START) == 1
    assert home.index("cerberus-central") < home.index(ex.HOME_START) < home.index("# Início")


def test_graph_merge_keeps_existing_groups(env):
    run(env, "--graph")
    g = json.loads((env["vault"] / ".obsidian/graph.json").read_text())
    queries = [c["query"] for c in g["colorGroups"]]
    assert queries[0] == "tag:#map/docs"
    assert 'path:"projects/nomad/Central do nomad.md"' in queries
    assert g["search"].startswith('path:"projects/cerberus/map" OR ')
    assert 'path:"projects/nomad/map"' in g["search"]
    before = (env["vault"] / ".obsidian/graph.json").read_text()
    ex.merge_graph(env["vault"], dry_run=False)
    assert (env["vault"] / ".obsidian/graph.json").read_text() == before


def test_dry_run_writes_nothing(env):
    run(env, "--dry-run")
    assert not (env["root"] / "map").exists()
    assert not (env["tmp"] / "state.json").exists()


def test_vault_copy_of_repo_doc_is_linked_not_duplicated(env):
    copy = env["root"] / "tools regras.md"  # como o export_nomad.sh do /root/nomad faz com o README
    copy.write_text((env["tools"] / "CLAUDE.md").read_text())
    run(env)
    assert not (env["root"] / "guides/tools - regras (CLAUDE.md).md").exists()
    assert "[[projects/nomad/tools regras|tools regras]]" in (env["root"] / "map/tools (repo).md").read_text()
    assert copy.read_text() == (env["tools"] / "CLAUDE.md").read_text()
