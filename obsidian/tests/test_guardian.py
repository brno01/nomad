"""Vigia do Obsidian: cores do graph.json, notas completadas, duplicatas e links, tudo num cofre descartável.

uv run --no-project --with pytest pytest obsidian/tests
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path

import pytest

SPEC = importlib.util.spec_from_file_location("guardian", Path(__file__).resolve().parents[1] / "guardian.py")
g = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(g)
POLICY = Path(__file__).resolve().parents[1] / "guardian.toml"
GEN = "<!-- gerado por nomad-enhancement/obsidian/export_nomad.py: não edite aqui -->"


def put(vault: Path, rel: str, text: str, mtime: int | None = None) -> Path:
    p = vault / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")
    if mtime:
        os.utime(p, (mtime, mtime))
    return p


@pytest.fixture
def vault(tmp_path, monkeypatch):
    monkeypatch.setattr(g, "STATE_DIR", tmp_path / "state")
    monkeypatch.setattr(g, "GRAPH_REPAIRS", [])  # o limite de reparos é estado do processo: cada teste começa zerado
    v = tmp_path / "vault"
    (v / ".obsidian").mkdir(parents=True)
    put(v, "projects/nomad/Central do nomad.md", f"---\ntags: [nomad]\n---\n{GEN}\n# Central\n")
    put(v, "projects/nomad/map/Guias.md", f"---\ntags: [map/docs]\n---\n{GEN}\nPai: [[projects/nomad/Central do nomad|Central]]\n")
    return v


def policy(vault: Path) -> "g.Policy":
    return g.load_policy(POLICY, str(vault), 1)


def run(vault: Path, dry: bool = False):
    return g.run_pass(policy(vault), dry, {})


def graph(vault: Path) -> dict:
    return json.loads((vault / ".obsidian/graph.json").read_text())


def test_graph_colors_projects_types_and_keeps_user_groups(vault):
    put(vault, "projects/cerberus/Cerberus.md", f"{GEN}\n# Cerberus\n")
    put(vault, "projects/novo/notes/a.md", "# a\n")  # projeto novo, sem nó central
    (vault / ".obsidian/graph.json").write_text(json.dumps({"colorGroups": [{"query": "tag:#meu", "color": {"a": 1, "rgb": 123}}], "showTags": False}))
    run(vault)
    groups = {x["query"]: x["color"]["rgb"] for x in graph(vault)["colorGroups"]}
    assert groups['path:"projects/nomad/Central do nomad.md"'] == 0x39FF14  # verde fluorescente
    assert groups['path:"projects/cerberus/Cerberus.md"'] == 0xFFFFFF
    assert groups["tag:#mapa tag:#map/servicos"] == 0x38BDF8  # hub por tipo
    assert "tag:#map/servicos" not in groups  # forma antiga (pintava folhas também) some
    assert groups['path:"projects/novo"'] == 0x00F0FF  # primeira cor da paleta
    assert groups["tag:#meu"] == 123  # grupo do usuário preservado
    assert graph(vault)["showTags"] is False


def test_graph_is_idempotent_and_repairs_when_obsidian_drops_groups(vault):
    run(vault)
    first = (vault / ".obsidian/graph.json").read_text()
    mtime = (vault / ".obsidian/graph.json").stat().st_mtime_ns
    _, changed = run(vault)
    assert not changed and (vault / ".obsidian/graph.json").stat().st_mtime_ns == mtime
    data = json.loads(first)
    data["colorGroups"] = []  # o Obsidian regravou sem os grupos
    (vault / ".obsidian/graph.json").write_text(json.dumps(data))
    _, changed = run(vault)
    assert changed and graph(vault)["colorGroups"]


def test_new_project_color_is_stable_across_runs(vault):
    put(vault, "projects/novo/notes/a.md", "# a\n")
    assigned: dict[str, int] = {}
    g.run_pass(policy(vault), False, assigned)
    put(vault, "projects/outro/notes/b.md", "# b\n")
    g.run_pass(policy(vault), False, assigned)
    groups = {x["query"]: x["color"]["rgb"] for x in graph(vault)["colorGroups"]}
    assert groups['path:"projects/novo"'] == 0x00F0FF and groups['path:"projects/outro"'] == 0xFF2BD6


def test_completes_pai_and_tags_without_touching_what_exists(vault):
    put(vault, "projects/nomad/melhorias/Melhorias do nomad.md", "---\ntype: project\ntags: [projeto, nomad]\n---\n# Melhorias\n")
    put(vault, "projects/nomad/melhorias/Wine.md", '---\ntype: decision\nproject: "[[Melhorias do nomad]]"\ntags: [decisao]\n---\n# Wine\ncorpo\n')
    put(vault, "projects/nomad/build.md", "# build\ntexto\n")
    f, _ = run(vault)
    wine = (vault / "projects/nomad/melhorias/Wine.md").read_text()
    assert "Pai: [[projects/nomad/melhorias/Melhorias do nomad|Melhorias do nomad]]" in wine
    assert "tags: [decisao]" in wine and "corpo" in wine and wine.count("tags:") == 1
    build = (vault / "projects/nomad/build.md").read_text()
    assert build.startswith("---\ntags: [nomad]\n---\nPai: [[projects/nomad/Central do nomad|Central do nomad]]\n\n# build")
    assert (vault / "projects/nomad/melhorias/Melhorias do nomad.md").read_text().count("Pai:") == 1
    f2, _ = run(vault)
    assert not f2.actions  # segunda passada não muda nada


def test_generated_notes_are_never_edited(vault):
    p = put(vault, "projects/nomad/map/Solta.md", f"{GEN}\n# sem pai\n")
    before = p.read_text()
    run(vault)
    assert p.read_text() == before


def test_parent_stays_inside_the_same_project_and_account(vault):
    put(vault, "areas/trabalho/projects/loja/Loja.md", f"{GEN}\n# Loja\n")
    put(vault, "areas/trabalho/projects/loja/notes/x.md", "# x\n")
    run(vault)
    x = (vault / "areas/trabalho/projects/loja/notes/x.md").read_text()
    assert "Pai: [[areas/trabalho/projects/loja/" in x and "projects/nomad" not in x


def test_dry_run_writes_nothing(vault):
    put(vault, "projects/nomad/build.md", "# build\n")
    f, changed = run(vault, dry=True)
    assert f.actions and changed
    assert (vault / "projects/nomad/build.md").read_text() == "# build\n"
    assert not (vault / ".obsidian/graph.json").exists()


def test_stale_generated_duplicate_is_archived_and_links_follow(vault):
    old = put(vault, "projects/nomad/Central Nomad.md", f"{GEN}\nExportado em 13/11/2026 11:22.\n# Central\n", mtime=1_000_000)
    put(vault, "projects/nomad/Central do nomad.md", f"{GEN}\nExportado em 14/11/2026 03:36.\n# Central\n", mtime=2_000_000)
    put(vault, "projects/nomad/notes/LEIA-ME.md", "Volte para a [[Central Nomad|central]].\n")
    f, _ = run(vault)
    assert not old.exists()
    archived = list((vault / "archive/guardiao").rglob("Central Nomad.md"))
    assert len(archived) == 1  # movida, nunca apagada
    leia = (vault / "projects/nomad/notes/LEIA-ME.md").read_text()
    assert "[[Central do nomad|central]]" in leia


def test_generated_notes_that_differ_in_other_numbers_are_not_duplicates(vault):
    put(vault, "projects/nomad/map/qwen3-1.7b.md", f"{GEN}\nmodelo de 1.7 bilhões\n", mtime=1)
    put(vault, "projects/nomad/map/qwen3-0.6b.md", f"{GEN}\nmodelo de 0.6 bilhões\n", mtime=2)
    f, _ = run(vault)
    assert not any("duplicata" in a for a in f.actions)
    assert (vault / "projects/nomad/map/qwen3-1.7b.md").exists()


def test_broken_link_fixed_only_when_target_is_unique(vault):
    put(vault, "projects/nomad/map/Documentação no Obsidian.md", f"{GEN}\nPai: [[projects/nomad/Central do nomad|c]]\n")
    put(vault, "projects/nomad/notes/a.md", "Veja [[documentacao no obsidian]] e [[não existe]].\n")
    f, _ = run(vault)
    a = (vault / "projects/nomad/notes/a.md").read_text()
    assert "[[Documentação no Obsidian]]" in a and "[[não existe]]" in a
    assert any("não existe" in r for r in f.report)


def test_table_escaped_pipe_link_is_not_broken(vault):
    put(vault, "projects/nomad/map/Atalhos.md", f"{GEN}\n| a | [[projects/nomad/Central do nomad\\|Central]] |\n")
    f, _ = run(vault)
    assert not any("link quebrado" in r for r in f.report)


def test_policy_ignores_attachments_and_daily(vault):
    put(vault, "daily/2026/11/2026-11-14.md", "# hoje\n")
    files = g.scan(vault, policy(vault).ignore)
    assert not any(r.startswith("daily/") for r in files)


def test_cycle_survives_missing_vault_and_fingerprint_changes(vault):
    files = g.scan(vault, set())
    fp1 = g.fingerprint(files, vault / ".obsidian/graph.json")
    put(vault, "projects/nomad/novo.md", "# novo\n")
    fp2 = g.fingerprint(g.scan(vault, set()), vault / ".obsidian/graph.json")
    assert fp1 != fp2
    assert g.main(["--vault", str(vault / "nao-existe"), "--once"]) == 1


def test_links_inside_code_are_ignored(vault):
    put(vault, "projects/nomad/notes/c.md", "Veja `[[nota]]` e\n```\n[[\"10.0.0.1\", 25565]]\n```\n")
    f, _ = run(vault)
    assert not any("link quebrado" in r for r in f.report)


def test_central_can_be_a_path_inside_the_project(vault):
    put(vault, "projects/cerberus/shortcuts/Cerberus.md", f"{GEN}\n# Cerberus\n")
    put(vault, "projects/cerberus/notes/x.md", "# x\n")
    pol = policy(vault)
    pol.central["cerberus"] = "shortcuts/Cerberus"  # central em subpasta, definida na política
    g.run_pass(pol, False, {})
    assert "Pai: [[projects/cerberus/shortcuts/Cerberus|Cerberus]]" in (vault / "projects/cerberus/notes/x.md").read_text()
    groups = {x["query"] for x in graph(vault)["colorGroups"]}
    assert 'path:"projects/cerberus/shortcuts/Cerberus.md"' in groups


def test_central_ignores_listed_but_unreadable_entry(vault, monkeypatch):
    put(vault, "projects/cerberus/Cerberus.md", f"{GEN}\n# Cerberus\n")
    put(vault, "projects/cerberus/shortcuts/Cerberus.md", f"{GEN}\n# velho\n")
    put(vault, "projects/cerberus/notes/x.md", "# x\n")
    pol = policy(vault)
    pol.central["cerberus"] = "shortcuts/Cerberus"  # configuração velha
    files = g.scan(vault, pol.ignore)
    real_read = g.read
    monkeypatch.setattr(g, "read", lambda v, rel: None if rel.endswith("shortcuts/Cerberus.md") else real_read(v, rel))  # entrada SMB velha
    p = [x for x in g.find_projects(vault) if x.slug == "cerberus"][0]
    assert g.find_central(vault, p, files, pol) == "projects/cerberus/Cerberus.md"


def test_dead_pai_is_repaired_and_bookmark_follows(vault):
    put(vault, "projects/cerberus/Cerberus.md", f"{GEN}\n# Cerberus\n")
    put(vault, "projects/cerberus/notes/x.md", "---\ntags: [cerberus]\n---\nPai: [[projects/cerberus/shortcuts/Cerberus|Cerberus]]\n\n# x\n")
    put(vault, "projects/cerberus/notes/y.md", "---\ntags: [cerberus]\n---\nPai: [[nota sumida|nota]]\n\n# y\n")
    (vault / ".obsidian/bookmarks.json").write_text(json.dumps({"items": [{"type": "file", "path": "projects/cerberus/shortcuts/Cerberus.md", "title": "Cerberus"}]}))
    f, _ = run(vault)
    assert "Pai: [[projects/cerberus/Cerberus" in (vault / "projects/cerberus/notes/x.md").read_text()
    assert "Pai: [[projects/cerberus/Cerberus|Cerberus]]" in (vault / "projects/cerberus/notes/y.md").read_text()
    assert json.loads((vault / ".obsidian/bookmarks.json").read_text())["items"][0]["path"] == "projects/cerberus/Cerberus.md"
    f2, _ = run(vault)
    assert not f2.actions


def test_central_found_by_direct_open_when_directory_listing_is_stale(vault, monkeypatch):
    put(vault, "projects/cerberus/Cerberus.md", f"{GEN}\n# Cerberus\n")
    put(vault, "projects/cerberus/notes/x.md", "# x\n")
    pol = policy(vault)
    real_scan = g.scan
    monkeypatch.setattr(g, "scan", lambda v, ig: {r: m for r, m in real_scan(v, ig).items() if r != "projects/cerberus/Cerberus.md"})  # listagem velha
    g.run_pass(pol, False, {})
    assert "Pai: [[projects/cerberus/Cerberus|Cerberus]]" in (vault / "projects/cerberus/notes/x.md").read_text()


def test_pai_and_bookmark_pointing_to_listed_but_unreadable_note_are_repaired(vault, monkeypatch):
    put(vault, "projects/cerberus/Cerberus.md", f"{GEN}\n# Cerberus\n")
    put(vault, "projects/cerberus/shortcuts/Cerberus.md", f"{GEN}\n# velho (entrada de cache)\n")
    put(vault, "projects/cerberus/notes/x.md", "---\ntags: [cerberus]\n---\nPai: [[projects/cerberus/shortcuts/Cerberus|Cerberus]]\n\n# x\n")
    (vault / ".obsidian/bookmarks.json").write_text(json.dumps({"items": [{"type": "file", "path": "projects/cerberus/shortcuts/Cerberus.md", "title": "Cerberus"}]}))
    real_read = g.read
    monkeypatch.setattr(g, "read", lambda v, rel: None if rel.endswith("shortcuts/Cerberus.md") else real_read(v, rel))
    run(vault)
    assert "Pai: [[projects/cerberus/Cerberus|Cerberus]]" in (vault / "projects/cerberus/notes/x.md").read_text()
    assert json.loads((vault / ".obsidian/bookmarks.json").read_text())["items"][0]["path"] == "projects/cerberus/Cerberus.md"


def _hub_and_leaf(vault):
    put(vault, "projects/nomad/map/Serviços.md", f"---\ntags: [nomad, mapa, map/servicos]\n---\n{GEN}\nPai: [[projects/nomad/Central do nomad|c]]\n")
    put(vault, "projects/nomad/guides/g.md", f"---\ntags: [nomad, guia, map/docs]\n---\n{GEN}\nPai: [[projects/nomad/map/Serviços|s]]\n")
    put(vault, "projects/nomad/build.md", "# build\n")


def test_hub_and_leaf_get_different_colors_and_nothing_is_left_uncolored(vault):
    _hub_and_leaf(vault)
    run(vault)
    pol = policy(vault)
    projects = g.find_projects(vault)
    files = g.scan(vault, pol.ignore)
    centrals = {p.key: g.find_central(vault, p, files, pol) for p in projects}
    groups = g.desired_groups(pol, projects, centrals, {})
    per, bare = g.coverage(vault, groups, files)
    assert per["tag:#mapa tag:#map/servicos"] == 1 and per["tag:#guia"] == 1  # hub e folha: grupos (cores) diferentes
    assert not bare, bare


def test_default_search_is_the_skeleton_and_user_changes_stick(vault):
    _hub_and_leaf(vault)
    run(vault)
    search = graph(vault)["search"]
    assert 'path:"projects/nomad/map"' in search and 'path:"projects/nomad/Central do nomad.md"' in search and "-path:templates" in search
    data = graph(vault)
    data["search"] = "tag:#minha"  # você mudou a busca no Obsidian
    (vault / ".obsidian/graph.json").write_text(json.dumps(data))
    run(vault)
    assert graph(vault)["search"] == "tag:#minha"
    assert graph(vault)["linkDistance"] == 90  # forças aplicadas uma vez


def test_saved_views_are_created_stay_stable_and_follow_new_projects(vault):
    _hub_and_leaf(vault)
    (vault / ".obsidian/bookmarks.json").write_text(json.dumps({"items": [{"type": "file", "path": "projects/nomad/build.md", "title": "build", "ctime": 1}]}))
    run(vault)
    items = json.loads((vault / ".obsidian/bookmarks.json").read_text())["items"]
    assert items[0]["title"] == "build"  # favorito seu preservado
    grp = next(i for i in items if i["type"] == "group")
    titles = [i["title"] for i in grp["items"]]
    assert titles[:3] == ["Mapa (hubs)", "Tudo", "Conversas"] and "Projeto: nomad" in titles
    assert all(i["type"] == "graph" and i["options"]["colorGroups"] for i in grp["items"])
    before = (vault / ".obsidian/bookmarks.json").read_text()
    f, _ = run(vault)
    assert (vault / ".obsidian/bookmarks.json").read_text() == before and not f.actions
    put(vault, "projects/novo/notes/a.md", "# a\n")
    run(vault)
    grp = next(i for i in json.loads((vault / ".obsidian/bookmarks.json").read_text())["items"] if i["type"] == "group")
    assert "Projeto: novo" in [i["title"] for i in grp["items"]]


def test_manual_note_tags_and_status_follow_the_vocabulary(vault, tmp_path):
    tax = tmp_path / "taxonomia.toml"
    tax.write_text('[tags]\nestrutura = ["decisao", "nomad"]\ntopicos = ["claude-code"]\n[aliases]\n"claude code" = "claude-code"\n[status.aliases]\n"em andamento" = "em-andamento"\n')
    put(vault, "projects/nomad/notes/a.md", "---\nstatus: em andamento\ntags: [decisao, nomad, wine, claude code]\n---\nPai: [[projects/nomad/Central do nomad|c]]\n\ncorpo\n")
    pol = policy(vault)
    pol.taxonomy = str(tax)
    g.run_pass(pol, False, {})
    a = (vault / "projects/nomad/notes/a.md").read_text()
    assert "tags: [decisao, nomad, topico/wine, claude-code]" in a and "status: em-andamento" in a and "corpo" in a
    f, _ = g.run_pass(pol, False, {})
    assert not f.actions  # idempotente
    pol.taxonomy = str(tmp_path / "nao-existe.toml")  # sem vocabulário, não mexe
    put(vault, "projects/nomad/notes/b.md", "---\ntags: [qualquer]\n---\nPai: [[projects/nomad/Central do nomad|c]]\n")
    g.run_pass(pol, False, {})
    assert "tags: [qualquer]" in (vault / "projects/nomad/notes/b.md").read_text()


def test_graph_repairs_are_rate_limited_when_something_keeps_rewriting_it(vault, monkeypatch):
    monkeypatch.setattr(g, "GRAPH_REPAIRS", [])
    for _ in range(g.MAX_GRAPH_REPAIRS):
        (vault / ".obsidian/graph.json").write_text(json.dumps({"colorGroups": []}))  # regravado sem os grupos
        _, changed = run(vault)
        assert changed
    (vault / ".obsidian/graph.json").write_text(json.dumps({"colorGroups": []}))
    _, changed = run(vault)
    assert not changed and graph(vault)["colorGroups"] == []  # pausado: não repara de novo
