#!/usr/bin/env python3
"""Vigia do cofre do Obsidian: roda sempre e mantém cores, tópicos e ligações do grafo corretos.

A cada ciclo (padrão 20 s) confere se algo mudou no cofre e, quando mudou e o cofre sossegou, corrige:

  1. graph.json: cores de cada projeto (nó central e, sem nó central, a pasta inteira), cores por tipo
     (tag map/<tipo>) e a cor neutra de notes/. Só toca nos grupos que são dele; os seus ficam.
  2. Notas dos projetos que o exportador e o segundo cérebro não geram: completa o que falta
     ("Pai:" e tags), sempre dentro do mesmo projeto (pessoal e trabalho nunca se ligam).
  3. Duplicatas geradas na mesma pasta (mesmo conteúdo, só mudam datas e horas): a mais antiga vai para
     archive/guardiao/<data>/ (nunca é apagada) e os links para ela passam para a que ficou.
  4. Links quebrados nessas notas: reescritos quando só existe um alvo possível no projeto.

Notas geradas (marcador "gerado por"/"gerado pelo") nunca são editadas: quem as gera as corrige.
O que não dá para corrigir sozinho vai para o relatório (~/.local/state/obsidian-guardian/report.md).

Uso: python3 -I obsidian/guardian.py [--vault CAMINHO] [--once] [--dry-run] [--report] [--interval S]
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import signal
import sys
import tempfile
import time
import tomllib
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_POLICY = HERE / "guardian.toml"
STATE_DIR = Path(os.environ.get("OBSIDIAN_GUARDIAN_STATE", Path.home() / ".local/state/obsidian-guardian"))
GENERATED_RE = re.compile(r"gerado (?:por|pelo)")
PAI_RE = re.compile(r"^Pai:\s*\[\[", re.M)
# [[alvo]], [[alvo|apelido]], [[alvo#seção]] e a forma escapada de tabelas [[alvo\|apelido]]
LINK_RE = re.compile(r"\[\[([^\]|#\\]+?)(#[^\]|\\]*)?(\\?\|[^\]]*)?\]\]")
FM_RE = re.compile(r"\A---\n(.*?)\n---[ \t]*(?:\n|\Z)", re.S)
# só datas e horas variam entre uma exportação e outra; qualquer outro número (ex.: tamanho do modelo) é conteúdo
STAMP_RE = re.compile(r"\d{1,2}/\d{1,2}/\d{4}|\d{4}-\d{2}-\d{2}|\d{1,2}:\d{2}(?::\d{2})?")
CODE_RE = re.compile(r"```.*?```|~~~.*?~~~|`[^`\n]+`", re.S)  # [[...]] dentro de código não é link
PROJECT_PROP_RE = re.compile(r'^project:\s*"?\[\[([^\]|#]+)', re.M)
TYPE_RE = re.compile(r"^type:\s*(\S+)", re.M)


def log(msg: str) -> None:
    print(f"{dt.datetime.now():%H:%M:%S} {msg}", flush=True)


# ----------------------------------------------------------------------------- política


@dataclass
class Policy:
    vault: Path
    interval: int
    quiet_polls: int
    full_every: int
    ignore: set[str]
    tag_colors: dict[str, int]
    notes_color: int
    project_colors: dict[str, int]
    central: dict[str, str]
    palette: list[int]
    hub_color: int = 0x8B8FA3
    leaf_colors: dict[str, int] = field(default_factory=dict)
    extra_groups: list[tuple[str, int]] = field(default_factory=list)
    graph_defaults: dict = field(default_factory=dict)
    taxonomy: str = ""


def hex_rgb(s: str) -> int:
    return int(s.replace(" ", "").lstrip("#"), 16)


def load_policy(path: Path, vault: str | None, interval: int | None) -> Policy:
    cfg = tomllib.loads(path.read_text(encoding="utf-8"))
    g = cfg.get("guardian", {})
    projects = cfg.get("projects", {})
    return Policy(
        vault=Path(vault or os.environ.get("OBSIDIAN_VAULT") or g.get("vault", "/var/mnt/nas/vault")),
        interval=interval or int(g.get("interval", 20)),
        quiet_polls=int(g.get("quiet_polls", 2)),
        full_every=int(g.get("full_every", 600)),
        ignore=set(g.get("ignore", [])),
        tag_colors={k: hex_rgb(v) for k, v in cfg.get("tags", {}).items()},
        notes_color=hex_rgb(g.get("notes_color", "D1D5DB")),
        project_colors={k: hex_rgb(v["color"]) for k, v in projects.items() if "color" in v},
        central={k: v["central"] for k, v in projects.items() if "central" in v},
        palette=[hex_rgb(c) for c in cfg.get("palette", {}).get("colors", [])] or [0x39FF14],
        hub_color=hex_rgb(g.get("hub_color", "8B8FA3")),
        leaf_colors={k: hex_rgb(v) for k, v in cfg.get("leaf_tags", {}).items()},
        extra_groups=[(q, hex_rgb(c)) for q, c in cfg.get("extra_groups", {}).items()],
        graph_defaults=cfg.get("graph_defaults", {}),
        taxonomy=os.path.expanduser(g.get("taxonomy", "")),
    )


# ----------------------------------------------------------------------------- cofre


@dataclass
class Project:
    slug: str
    root: str  # caminho relativo ao cofre, ex.: projects/nomad
    area: str  # pessoal | trabalho

    @property
    def key(self) -> str:
        return self.root


def find_projects(vault: Path) -> list[Project]:
    out: list[Project] = []
    base = vault / "projects"
    if base.is_dir():
        out += [Project(d.name, f"projects/{d.name}", "pessoal") for d in sorted(base.iterdir()) if d.is_dir() and not d.name.startswith(".")]
    areas = vault / "areas"
    if areas.is_dir():
        for a in sorted(areas.iterdir()):
            pj = a / "projects"
            if pj.is_dir():
                out += [Project(d.name, f"areas/{a.name}/projects/{d.name}", a.name) for d in sorted(pj.iterdir()) if d.is_dir() and not d.name.startswith(".")]
    return out


def scan(vault: Path, ignore: set[str]) -> dict[str, tuple[int, int]]:
    """rel -> (mtime_ns, tamanho) de todos os arquivos fora das pastas ignoradas."""
    files: dict[str, tuple[int, int]] = {}
    skip = ignore | {".obsidian", ".stversions", ".trash", ".lixeira", ".git", ".stfolder"}

    def walk(d: Path, rel: str) -> None:
        try:
            it = list(os.scandir(d))
        except OSError:
            return
        for e in it:
            if e.name in skip or e.name.startswith(".guardian-tmp"):
                continue
            r = f"{rel}{e.name}"
            if e.is_dir(follow_symlinks=False):
                walk(Path(e.path), r + "/")
            elif e.is_file(follow_symlinks=False):
                try:
                    st = e.stat()
                except OSError:
                    continue
                files[r] = (st.st_mtime_ns, st.st_size)

    walk(vault, "")
    return files


def fingerprint(files: dict[str, tuple[int, int]], graph: Path) -> str:
    h = hashlib.sha1()
    for r in sorted(files):
        if r.endswith(".md"):
            h.update(f"{r}\0{files[r][0]}\0{files[r][1]}\n".encode())
    try:
        st = graph.stat()
        h.update(f"graph\0{st.st_mtime_ns}\0{st.st_size}".encode())
    except OSError:
        h.update(b"graph-missing")
    return h.hexdigest()


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c)).casefold()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


class Index:
    """Resolve [[links]] como o Obsidian: caminho completo ou nome (com ou sem .md)."""

    def __init__(self, files: dict[str, tuple[int, int]]):
        self.files = files
        self.by_path = {r.lower(): r for r in files}
        self.by_name: dict[str, list[str]] = {}
        for r in files:
            name = r.rsplit("/", 1)[-1].lower()
            self.by_name.setdefault(name, []).append(r)
            if name.endswith(".md"):
                self.by_name.setdefault(name[:-3], []).append(r)

    def resolve(self, target: str) -> str | None:
        t = target.strip().lower()
        if "/" in t:
            return self.by_path.get(t) or self.by_path.get(t + ".md")
        hits = self.by_name.get(t)
        return hits[0] if hits else None


def read(vault: Path, rel: str) -> str | None:
    try:
        return (vault / rel).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def code_spans(text: str) -> list[tuple[int, int]]:
    return [m.span() for m in CODE_RE.finditer(text)]


def real_links(text: str) -> list[re.Match]:
    spans = code_spans(text)
    return [m for m in LINK_RE.finditer(text) if not any(a <= m.start() < b for a, b in spans)]


def is_generated(text: str) -> bool:
    return bool(GENERATED_RE.search("\n".join(text.split("\n", 40)[:40])))


def has_tags(fm: str) -> bool:
    if re.search(r"^tags:\s*\[\s*\S", fm, re.M) or re.search(r"^tags:\s*[^\s\[]", fm, re.M):
        return True
    return bool(re.search(r"^tags:\s*\n\s*-\s+\S", fm, re.M))


# ----------------------------------------------------------------------------- escrita segura


def atomic_write(path: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(prefix=".guardian-tmp-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def edit_note(vault: Path, rel: str, new: str, mtime_ns: int, dry: bool) -> bool:
    """Só grava se o arquivo não mudou desde a leitura (o próximo ciclo tenta de novo)."""
    p = vault / rel
    try:
        if p.stat().st_mtime_ns != mtime_ns:
            return False
    except OSError:
        return False
    if not dry:
        atomic_write(p, new)
    return True


# ----------------------------------------------------------------------------- graph.json


def desired_groups(policy: Policy, projects: list[Project], centrals: dict[str, str | None], assigned: dict[str, int]) -> list[dict]:
    """Grupos de cor que o vigia mantém, em ordem de prioridade (o primeiro que casa vale):
    central de cada projeto > hubs por tipo (tag mapa + map/<tipo>) > hub genérico > folhas por tipo > extras > pasta do projeto."""
    groups: list[dict] = []

    def add(q: str, rgb: int) -> None:
        groups.append({"query": q, "color": {"a": 1, "rgb": rgb}})

    for p in projects:
        c = centrals.get(p.key)
        if c:
            add(f'path:"{c}"', project_color(policy, p, assigned))
    for tag, rgb in policy.tag_colors.items():
        add(f"tag:#mapa tag:#map/{tag}", rgb)
    add("tag:#mapa", policy.hub_color)
    for tag, rgb in policy.leaf_colors.items():
        add(f"tag:#{tag}", rgb)
    for q, rgb in policy.extra_groups:
        add(q, rgb)
    for p in projects:
        # sem nó central a pasta inteira ganha a cor do projeto; com ele, o que sobrou (notas suas, planos, atalhos) fica neutro
        add(f'path:"{p.root}"', policy.notes_color if centrals.get(p.key) else project_color(policy, p, assigned))
    return groups


def project_color(policy: Policy, p: Project, assigned: dict[str, int]) -> int:
    if p.slug in policy.project_colors:
        return policy.project_colors[p.slug]
    if p.root not in assigned:
        used = set(policy.project_colors.values()) | set(assigned.values())
        free = [c for c in policy.palette if c not in used]
        assigned[p.root] = free[0] if free else policy.palette[len(assigned) % len(policy.palette)]
    return assigned[p.root]


def owned(query: str, projects: list[Project], policy: Policy, want: set[str]) -> bool:
    """Grupo que é do vigia (o resto é seu e fica): os que ele gera hoje e as formas antigas que gerou antes."""
    if query in want:
        return True
    if query.startswith("tag:#map/") and query[len("tag:#map/"):] in policy.tag_colors:
        return True  # forma antiga: o tipo sozinho pintava folhas também
    return any(query in (f'path:"{p.root}"', f'path:"{p.root}/notes"') or (query.startswith(f'path:"{p.root}/') and query.endswith(".md\"")) for p in projects)


def skeleton(projects: list[Project], centrals: dict[str, str | None]) -> str:
    """Busca do 'Mapa': só o esqueleto (centrais e nós map/ de cada projeto), montada a partir dos projetos que existem."""
    terms: list[str] = []
    for p in projects:
        c = centrals.get(p.key)
        terms += [f'path:"{p.root}/map"', f'path:"{p.root}/shortcuts"'] if c else [f'path:"{p.root}"']
        if c:
            terms.append(f'path:"{c}"')
    return "(" + " OR ".join(terms) + ") -path:templates -path:archive" if terms else ""


GRAPH_OPTION_KEYS = ("collapse-filter", "showTags", "showAttachments", "hideUnresolved", "showOrphans", "collapse-color-groups",
                     "collapse-display", "showArrow", "textFadeMultiplier", "nodeSizeMultiplier", "lineSizeMultiplier",
                     "collapse-forces", "centerStrength", "repelStrength", "linkStrength", "linkDistance")


def read_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    except (OSError, json.JSONDecodeError):
        return None


def fix_graph(vault: Path, policy: Policy, projects: list[Project], centrals: dict[str, str | None], assigned: dict[str, int], dry: bool) -> bool:
    path = vault / ".obsidian" / "graph.json"
    data = read_json(path)
    if data is None:
        log("graph.json ilegível: não mexo (será conferido de novo)")
        return False
    want = desired_groups(policy, projects, centrals, assigned)
    mine = [g for g in data.get("colorGroups", []) if not owned(g.get("query", ""), projects, policy, {w["query"] for w in want})]
    before = json.dumps(data, sort_keys=True)
    data["colorGroups"] = want + mine
    data["collapse-color-groups"] = False
    apply_defaults(data, policy, skeleton(projects, centrals), dry)
    if json.dumps(data, sort_keys=True) == before:
        return False
    if not dry:
        path.parent.mkdir(parents=True, exist_ok=True)
        atomic_write(path, json.dumps(data, indent=2, ensure_ascii=False))
    return True


def apply_defaults(data: dict, policy: Policy, search: str, dry: bool) -> None:
    """Busca padrão (o esqueleto) e forças pensadas para árvore. Só mexe enquanto a busca é vazia ou é a que o vigia pôs:
    o que você mudar no grafo fica (e as vistas salvas trazem a própria busca)."""
    state = read_json(STATE_DIR / "graph_defaults.json") or {}
    cur = (data.get("search") or "").strip()
    if cur in ("", state.get("search", "\0")):
        data["search"] = search
        if not dry and search != state.get("search"):
            STATE_DIR.mkdir(parents=True, exist_ok=True)
            (STATE_DIR / "graph_defaults.json").write_text(json.dumps({"search": search}), encoding="utf-8")
    for k, v in policy.graph_defaults.items():  # forças e aparência: só se ainda não foram definidas pelo vigia
        if state.get("forces") != policy.graph_defaults:
            data[k] = v
    if not dry and state.get("forces") != policy.graph_defaults:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        (STATE_DIR / "graph_defaults.json").write_text(json.dumps({"search": data.get("search", ""), "forces": policy.graph_defaults}), encoding="utf-8")


# ----------------------------------------------------------------------------- favoritos e vistas salvas

VIEWS_GROUP = "Grafo (vigia)"


def desired_views(policy: Policy, projects: list[Project], centrals: dict[str, str | None], base: dict, groups: list[dict]) -> list[dict]:
    """Vistas salvas do grafo (favoritos do tipo 'graph'): Mapa, Tudo, Conversas e uma por projeto (projeto novo ganha a sua)."""
    opts = {k: base[k] for k in GRAPH_OPTION_KEYS if k in base}
    opts["colorGroups"] = groups
    views = [("Mapa (hubs)", skeleton(projects, centrals)), ("Tudo", "-path:templates -path:archive"), ("Conversas", "tag:#conversa OR tag:#indice")]
    views += [(f"Projeto: {p.slug}" + (" (trabalho)" if p.area != "pessoal" else ""), f'path:"{p.root}"') for p in projects]
    return [{"type": "graph", "title": t, "options": {**opts, "search": q}} for t, q in views if q]


def fix_views(vault: Path, policy: Policy, projects: list[Project], centrals: dict[str, str | None], dry: bool) -> list[str]:
    bpath = vault / ".obsidian" / "bookmarks.json"
    data = read_json(bpath)
    graph = read_json(vault / ".obsidian" / "graph.json") or {}
    if data is None:
        return []
    data.setdefault("items", [])
    want = desired_views(policy, projects, centrals, graph, graph.get("colorGroups", []))
    group = next((i for i in data["items"] if i.get("type") == "group" and i.get("title") == VIEWS_GROUP), None)
    old = {i.get("title"): i for i in (group or {}).get("items", []) if i.get("type") == "graph"}
    items, changed = [], []
    for w in want:
        cur = old.get(w["title"])
        if cur and cur.get("options") == w["options"]:
            items.append(cur)
        else:
            items.append({**w, "ctime": (cur or {}).get("ctime") or int(time.time() * 1000)})
            changed.append(w["title"])
    if group is None:
        group = {"type": "group", "ctime": int(time.time() * 1000), "title": VIEWS_GROUP, "items": []}
        data["items"].append(group)
        changed.append("(grupo)")
    if [i.get("title") for i in group["items"]] != [i["title"] for i in items]:
        changed.append("(ordem)")
    group["items"] = items
    if not changed:
        return []
    if not dry:
        atomic_write(bpath, json.dumps(data, indent=2, ensure_ascii=False))
    return [f"vistas do grafo: {', '.join(changed)}"]


def fix_bookmarks(vault: Path, files: dict[str, tuple[int, int]], centrals: list[str], dry: bool) -> list[str]:
    """Favoritos de arquivo cujo caminho sumiu: se só existe uma nota com aquele nome, aponta para ela."""
    path = vault / ".obsidian" / "bookmarks.json"
    data = read_json(path)
    if not data:
        return []
    by_stem: dict[str, list[str]] = {}
    for r in [*files, *centrals]:  # as centrais entram mesmo que a listagem (cache) ainda não as mostre
        if r.endswith(".md") and r not in by_stem.get(norm(r.rsplit("/", 1)[-1][:-3]), []):
            by_stem.setdefault(norm(r.rsplit("/", 1)[-1][:-3]), []).append(r)
    done: list[str] = []

    def walk(items: list) -> None:
        for it in items:
            if it.get("type") == "file" and str(it.get("path", "")).endswith(".md") and read(vault, it["path"]) is None:
                cands = [c for c in by_stem.get(norm(it.get("title") or str(it.get("path", "")).rsplit("/", 1)[-1].removesuffix(".md")), []) if c != it["path"] and read(vault, c) is not None]
                if len(cands) == 1:
                    done.append(f"favorito {it['path']} -> {cands[0]}")
                    it["path"] = cands[0]
            if isinstance(it.get("items"), list):
                walk(it["items"])

    walk(data.get("items", []))
    if done and not dry:
        atomic_write(path, json.dumps(data, indent=2, ensure_ascii=False))
    return done


# ----------------------------------------------------------------------------- cobertura (quais nós ficam sem cor)


def group_matches(query: str, rel: str, tags: set[str]) -> bool:
    """Avalia só as formas que o vigia gera: path:"x", tag:#t e a combinação delas por espaço (E)."""
    for term in re.findall(r'path:"[^"]*"|tag:#\S+', query):
        if term.startswith("path:"):
            q = term[6:-1]
            if not (rel == q or rel.startswith(q.rstrip("/") + "/")):
                return False
        elif term[5:] not in tags:
            return False
    return True


def note_tags(text: str) -> set[str]:
    fm = FM_RE.match(text)
    if not fm:
        return set()
    m = re.search(r"^tags:\s*\[(.*?)\]", fm.group(1), re.M)
    if m:
        return {t.strip().strip("\"'") for t in m.group(1).split(",") if t.strip()}
    return set(re.findall(r"^\s*-\s+(\S+)", fm.group(1), re.M)) if re.search(r"^tags:\s*$", fm.group(1), re.M) else set()


def coverage(vault: Path, groups: list[dict], files: dict[str, tuple[int, int]]) -> tuple[dict[str, int], list[str]]:
    """(notas por grupo que as pinta, notas sem cor)."""
    per: dict[str, int] = {}
    bare: list[str] = []
    for rel in sorted(files):
        if not rel.endswith(".md") or rel.startswith(("templates/", "archive/")):
            continue
        text = read(vault, rel)
        if text is None:
            continue
        tags = note_tags(text)
        for g_ in groups:
            if group_matches(g_["query"], rel, tags):
                per[g_["query"]] = per.get(g_["query"], 0) + 1
                break
        else:
            bare.append(rel)
    return per, bare


# ----------------------------------------------------------------------------- notas


@dataclass
class Findings:
    actions: list[str] = field(default_factory=list)
    report: list[str] = field(default_factory=list)


def find_central(vault: Path, p: Project, files: dict[str, tuple[int, int]], policy: Policy) -> str | None:
    """Nota central do projeto. Candidatas em ordem (a da política, uma com o nome do projeto, a que mais
    notas apontam como Pai); só vale a que existe E abre: entradas velhas do compartilhamento de rede são listadas mas não leem."""

    def ok(rel: str) -> bool:
        # abrir direto, sem depender da listagem da pasta: o cache de diretório do cifs pode ficar velho
        # (mostra entradas que o servidor já apagou e esconde as novas) enquanto o acesso pelo nome funciona
        return read(vault, rel) is not None

    name = policy.central.get(p.slug)
    if name and ok(f"{p.root}/{name}.md"):
        return f"{p.root}/{name}.md"
    roots = [r for r in files if r.startswith(p.root + "/") and r.count("/") == p.root.count("/") + 1 and r.endswith(".md")]
    names = {norm(p.slug), norm("central " + p.slug), norm("central do " + p.slug)}
    for r in roots:  # nó de entrada com o nome do projeto (Loja.md, Central do loja.md)
        if norm(r.rsplit("/", 1)[-1][:-3]) in names and ok(r):
            return r
    best, count = None, 0
    for r in roots:
        if not ok(r):
            continue
        stem = r.rsplit("/", 1)[-1][:-3]
        n = 0
        for other in files:
            if other.startswith(p.root + "/map/") and other.endswith(".md"):
                t = read(vault, other)
                if t and re.search(rf"^Pai:\s*\[\[{re.escape(p.root + '/' + stem)}[|\]]", t, re.M):
                    n += 1
        if n > count:
            best, count = r, n
    return best


def pick_parent(vault: Path, rel: str, text: str, p: Project, central: str, index: Index, files: dict[str, tuple[int, int]]) -> str:
    """Pai de uma nota manual: a nota da propriedade project:, um irmão type: project, ou a central."""
    m = PROJECT_PROP_RE.search(text)
    if m:
        hit = index.resolve(m.group(1))
        if hit and hit.startswith(p.root + "/") and hit != rel:
            return hit
    folder = rel.rsplit("/", 1)[0]
    for other in sorted(files):
        if other.endswith(".md") and other != rel and other.rsplit("/", 1)[0] == folder:
            t = read(vault, other)
            if t and not is_generated(t):
                fm = FM_RE.match(t)
                tm = TYPE_RE.search(fm.group(1)) if fm else None
                if tm and tm.group(1) == "project":
                    return other
    return central


DEAD_PAI_RE = re.compile(r"^Pai:[ \t]*\[\[([^\]|#\\]+?)(?:\\?\|[^\]]*)?\]\]", re.M)


def fix_dead_pai(vault: Path, rel: str, text: str, mtime_ns: int, parent: str, index: Index, dry: bool) -> str | None:
    """'Pai:' que aponta para nota que não existe (mais) passa para o pai certo. Devolve o texto novo."""
    m = DEAD_PAI_RE.search(text)
    if not m:
        return None
    hit = index.resolve(m.group(1))
    if hit and (not hit.endswith(".md") or read(vault, hit) is not None):  # na listagem E abre
        return None
    alias = parent.rsplit("/", 1)[-1][:-3]
    new = text[:m.start()] + f"Pai: [[{parent[:-3]}|{alias}]]" + text[m.end():]
    return new if edit_note(vault, rel, new, mtime_ns, dry) else None


def load_taxonomy(path: str) -> dict:
    try:
        return tomllib.loads(Path(path).read_text(encoding="utf-8")) if path else {}
    except (OSError, tomllib.TOMLDecodeError):
        return {}


def normalize_tags(tags: list[str], tax: dict, allowed: tuple[str, ...] = ()) -> list[str]:
    """Igual ao brain.py (segundo cérebro): sinônimo vira a tag canônica; o que está fora do vocabulário vira topico/<nome>."""
    if not tax:
        return list(dict.fromkeys(tags))
    t = tax.get("tags", {})
    known = set(t.get("estrutura", [])) | set(t.get("topicos", [])) | set(allowed)
    aliases = tax.get("aliases", {})
    out = []
    for tag in tags:
        tag = aliases.get(tag, tag)
        out.append(tag if tag in known or tag.startswith(("map/", "topico/")) else f"topico/{tag}")
    return list(dict.fromkeys(out))


INLINE_TAGS_RE = re.compile(r"^tags:[ \t]*\[(.*?)\][ \t]*$", re.M)
STATUS_RE = re.compile(r"^status:[ \t]*(.+?)[ \t]*$", re.M)


def normalize_meta(text: str, p: Project, tax: dict) -> str | None:
    """Tags (lista na mesma linha) e status da nota manual conforme o vocabulário. Devolve o texto novo, ou None se já está certo."""
    fm_m = FM_RE.match(text)
    if not fm_m or not tax:
        return None
    fm = fm_m.group(1)
    new = fm
    m = INLINE_TAGS_RE.search(new)
    if m:
        tags = [x.strip().strip("\"'") for x in m.group(1).split(",") if x.strip()]
        norm_tags = normalize_tags(tags, tax, (p.slug,))
        if norm_tags != tags:
            new = new[:m.start()] + f"tags: [{', '.join(norm_tags)}]" + new[m.end():]
    sm = STATUS_RE.search(new)
    if sm:
        val = sm.group(1).strip("\"'")
        canon = tax.get("status", {}).get("aliases", {}).get(val.lower())
        if canon and canon != val:
            new = new[:sm.start()] + f"status: {canon}" + new[sm.end():]
    return None if new == fm else text[:fm_m.start(1)] + new + text[fm_m.end(1):]


def complete_note(vault: Path, rel: str, text: str, mtime_ns: int, p: Project, parent: str, dry: bool) -> str | None:
    """Acrescenta 'Pai:' e tags que faltam (nunca troca nada que já existe). Devolve o que fez."""
    fm_m = FM_RE.match(text)
    fm = fm_m.group(1) if fm_m else ""
    did: list[str] = []
    new_fm = fm
    if not (fm_m and has_tags(fm)):
        new_fm = (fm + "\n" if fm else "") + f"tags: [{p.slug}]"
        did.append("tags")
    body = text[fm_m.end():] if fm_m else text
    if not PAI_RE.search(text):
        alias = parent.rsplit("/", 1)[-1][:-3]
        body = f"Pai: [[{parent[:-3]}|{alias}]]\n\n" + body.lstrip("\n")
        did.append("Pai")
    if not did:
        return None
    new = f"---\n{new_fm}\n---\n{body}"
    if not edit_note(vault, rel, new, mtime_ns, dry):
        return None
    return "+".join(did)


def stale_duplicates(vault: Path, p: Project, files: dict[str, tuple[int, int]]) -> list[tuple[str, str]]:
    """(antiga, atual): notas geradas na mesma pasta com o mesmo conteúdo, exceto datas e horas."""
    groups: dict[tuple[str, str, int], list[str]] = {}
    for rel in files:
        if not rel.endswith(".md") or not rel.startswith(p.root + "/"):
            continue
        t = read(vault, rel)
        if t is None or not is_generated(t):
            continue
        key = (rel.rsplit("/", 1)[0], hashlib.sha1(STAMP_RE.sub("#", t).encode()).hexdigest(), len(t))
        groups.setdefault(key, []).append(rel)
    out = []
    for members in groups.values():
        if len(members) > 1:
            members.sort(key=lambda r: files[r][0])
            out += [(old, members[-1]) for old in members[:-1]]
    return out


def archive_note(vault: Path, rel: str, dry: bool) -> str:
    dest = Path("archive/guardiao") / dt.date.today().isoformat() / rel
    if not dry:
        (vault / dest).parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(vault / rel), str(vault / dest))
    return dest.as_posix()


def retarget_links(text: str, index: Index, p: Project, extra_gone: dict[str, str]) -> tuple[str, int]:
    """Reescreve [[links]] quebrados que só têm um alvo possível dentro do projeto (ou que apontam para uma duplicata arquivada)."""
    by_norm: dict[str, list[str]] = {}
    for r in index.files:
        if r.endswith(".md") and r.startswith(p.root + "/"):
            by_norm.setdefault(norm(r.rsplit("/", 1)[-1][:-3]), []).append(r)
    gone_by_name = {norm(old.rsplit("/", 1)[-1][:-3]): keep for old, keep in extra_gone.items()}
    n = 0

    spans = code_spans(text)

    def sub(m: re.Match) -> str:
        nonlocal n
        target = m.group(1)
        if any(a <= m.start() < b for a, b in spans) or index.resolve(target):
            return m.group(0)
        key = norm(target.rsplit("/", 1)[-1])
        new = gone_by_name.get(key)
        if not new:
            cands = by_norm.get(key, [])
            if len(cands) == 1:
                new = cands[0]
        if not new:
            return m.group(0)
        n += 1
        ref = new[:-3] if "/" in target else new.rsplit("/", 1)[-1][:-3]
        return f"[[{ref}{m.group(2) or ''}{m.group(3) or ''}]]"

    return LINK_RE.sub(sub, text), n


def check_notes(vault: Path, policy: Policy, projects: list[Project], files: dict[str, tuple[int, int]], dry: bool) -> tuple[Findings, dict[str, str | None]]:
    f = Findings()
    centrals: dict[str, str | None] = {}
    taxonomy = load_taxonomy(policy.taxonomy)
    index = Index(files)
    for p in projects:
        central = find_central(vault, p, files, policy)
        centrals[p.key] = central
        if central and central not in files:  # existe e abre, mas a listagem (cache) ainda não mostra
            try:
                st = (vault / central).stat()
                files[central] = (st.st_mtime_ns, st.st_size)
                index = Index(files)
            except OSError:
                pass
        if not central:
            f.report.append(f"- projeto `{p.root}`: sem nota central (a pasta inteira recebe a cor do projeto)")
        # 1) duplicatas geradas
        gone: dict[str, str] = {}
        for old, keep in stale_duplicates(vault, p, files):
            dest = archive_note(vault, old, dry)
            gone[old] = keep
            f.actions.append(f"duplicata: {old} -> {dest} (ficou {keep})")
        if gone:
            files = {r: v for r, v in files.items() if r not in gone}
            index = Index(files)
        # 2) notas manuais: Pai, tags, links
        for rel in sorted(files):
            if not rel.endswith(".md") or not rel.startswith(p.root + "/") or rel == central:
                continue
            text = read(vault, rel)
            if text is None or is_generated(text):
                continue
            mtime = files[rel][0]
            retargeted = 0
            if gone or LINK_RE.search(text):
                new_text, retargeted = retarget_links(text, index, p, gone)
                if retargeted and edit_note(vault, rel, new_text, mtime, dry):
                    f.actions.append(f"links: {retargeted} corrigido(s) em {rel}")
                    text = new_text
                    mtime = (vault / rel).stat().st_mtime_ns if not dry else mtime
            if central:
                parent = pick_parent(vault, rel, text, p, central, index, files)
                fixed = fix_dead_pai(vault, rel, text, mtime, parent, index, dry)
                if fixed:
                    f.actions.append(f"Pai morto corrigido: {rel} (pai: {parent})")
                    text = fixed
                    mtime = (vault / rel).stat().st_mtime_ns if not dry else mtime
                did = complete_note(vault, rel, text, mtime, p, parent, dry)
                if did:
                    f.actions.append(f"completou {did}: {rel} (pai: {parent})")
                    text = read(vault, rel) if not dry else text
                    mtime = (vault / rel).stat().st_mtime_ns if not dry else mtime
            tidy = normalize_meta(text or "", p, taxonomy) if text else None
            if tidy and edit_note(vault, rel, tidy, mtime, dry):
                f.actions.append(f"tags/status conforme o vocabulário: {rel}")
            elif not PAI_RE.search(text):
                f.report.append(f"- `{rel}`: sem 'Pai:' e o projeto não tem nota central")
    # 3) o que sobrou: links quebrados e órfãs
    for rel in sorted(files):
        if not rel.endswith(".md") or not any(rel.startswith(p.root + "/") for p in projects):
            continue
        text = read(vault, rel)
        if text is None:
            continue
        broken = sorted({m.group(1).strip() for m in real_links(text) if not index.resolve(m.group(1))})
        if broken:
            f.report.append(f"- `{rel}`: link quebrado {', '.join(f'[[{b}]]' for b in broken[:4])}")
    return f, centrals


def write_report(f: Findings, graph_changed: bool) -> None:
    """Só regrava quando o conteúdo muda (o carimbo de hora não conta)."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lines = ["## Corrigido neste ciclo"]
    if graph_changed:
        lines.append("- graph.json: cores e grupos reaplicados")
    lines += [f"- {a}" for a in f.actions] or ([] if graph_changed else ["- nada"])
    lines += ["", "## Precisa de você", *(f.report or ["- nada"]), ""]
    body = "\n".join(lines)
    path = STATE_DIR / "report.md"
    try:
        if path.read_text(encoding="utf-8").split("\n", 2)[2] == body:
            return
    except (OSError, IndexError):
        pass
    path.write_text(f"# Relatório do vigia do Obsidian ({dt.datetime.now():%d/%m/%Y %H:%M})\n\n{body}", encoding="utf-8")


# ----------------------------------------------------------------------------- ciclo


GRAPH_REPAIRS: list[float] = []
MAX_GRAPH_REPAIRS = 5


def run_pass(policy: Policy, dry: bool, assigned: dict[str, int]) -> tuple[Findings, bool]:
    vault = policy.vault
    projects = find_projects(vault)
    files = scan(vault, policy.ignore)
    f, centrals = check_notes(vault, policy, projects, files, dry)
    now = time.monotonic()
    recent = [t for t in GRAPH_REPAIRS if now - t < 600]
    GRAPH_REPAIRS[:] = recent
    if len(recent) >= MAX_GRAPH_REPAIRS and now - recent[-1] < 300:  # o Obsidian aberto regrava sem os grupos: não brigar com ele
        log(f"graph.json reparado {len(recent)}x em 10 min (Obsidian regravando?): pausa de 5 min")
        g = False
    else:
        g = fix_graph(vault, policy, projects, centrals, assigned, dry)
        if g and not dry:
            GRAPH_REPAIRS.append(now)
    f.actions += fix_bookmarks(vault, files, [c for c in centrals.values() if c], dry)
    f.actions += fix_views(vault, policy, projects, centrals, dry)
    for a in f.actions:
        log(a)
    if g:
        log("graph.json: cores e grupos reaplicados" + (" (Obsidian aberto: reabra o grafo para ver)" if obsidian_running() else ""))
    if not dry:
        write_report(f, g)
    return f, g


def obsidian_running() -> bool:
    try:
        for d in Path("/proc").iterdir():
            if d.name.isdigit() and b"/app/obsidian" in (d / "cmdline").read_bytes():
                return True
    except OSError:
        pass
    return False


def load_assigned() -> dict[str, int]:
    try:
        return json.loads((STATE_DIR / "colors.json").read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def save_assigned(a: dict[str, int]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / "colors.json").write_text(json.dumps(a, indent=2))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Vigia do cofre do Obsidian.")
    ap.add_argument("--vault")
    ap.add_argument("--policy", default=str(DEFAULT_POLICY))
    ap.add_argument("--once", action="store_true", help="um ciclo e sai")
    ap.add_argument("--dry-run", action="store_true", help="mostra o que faria, sem escrever (implica --once)")
    ap.add_argument("--report", action="store_true", help="imprime o relatório do último ciclo e sai")
    ap.add_argument("--coverage", action="store_true", help="mostra quantas notas cada grupo de cor pinta e quais ficam sem cor")
    ap.add_argument("--interval", type=int)
    a = ap.parse_args(argv)
    if a.report:
        r = STATE_DIR / "report.md"
        print(r.read_text(encoding="utf-8") if r.exists() else "sem relatório ainda")
        return 0
    policy = load_policy(Path(a.policy), a.vault, a.interval)
    assigned = load_assigned()
    if a.coverage:
        projects = find_projects(policy.vault)
        files = scan(policy.vault, policy.ignore)
        centrals = {p.key: find_central(policy.vault, p, files, policy) for p in projects}
        per, bare = coverage(policy.vault, desired_groups(policy, projects, centrals, assigned), files)
        for q, n in sorted(per.items(), key=lambda kv: -kv[1]):
            print(f"{n:>4}  {q}")
        print(f"\n{len(bare)} nota(s) sem cor" + (":" if bare else ""))
        for r in bare[:40]:
            print("  ", r)
        return 0
    once = a.once or a.dry_run
    stop = {"now": False}
    signal.signal(signal.SIGTERM, lambda *_: stop.update(now=True))
    last_fp, stable, last_full, missing_logged = "", 0, 0.0, False
    log(f"vigia: cofre {policy.vault}, ciclo de {policy.interval}s" + (" (dry-run)" if a.dry_run else ""))
    while not stop["now"]:
        if not (policy.vault / ".obsidian").is_dir():
            if not missing_logged:
                log(f"cofre indisponível em {policy.vault}: aguardando")
                missing_logged = True
            if once:
                return 1
        else:
            missing_logged = False
            files = scan(policy.vault, policy.ignore)
            fp = fingerprint(files, policy.vault / ".obsidian" / "graph.json")
            stable = stable + 1 if fp == last_fp else 0
            due = once or time.monotonic() - last_full >= policy.full_every
            if once or (fp != last_fp and stable >= 0) or due:
                # primeira leitura ou mudança: espera o cofre sossegar (exportadores escrevem várias notas) antes de agir
                if once or stable >= policy.quiet_polls or last_fp == "" or due:
                    try:
                        before = dict(assigned)
                        run_pass(policy, a.dry_run, assigned)
                        if assigned != before and not a.dry_run:
                            save_assigned(assigned)
                    except Exception as e:  # o vigia não pode cair por causa de uma nota estranha
                        log(f"erro no ciclo: {type(e).__name__}: {e}")
                    last_full = time.monotonic()
                    last_fp = fingerprint(scan(policy.vault, policy.ignore), policy.vault / ".obsidian" / "graph.json")
                    stable = 0
                else:
                    last_fp = fp
            if once:
                return 0
        time.sleep(policy.interval)
    log("vigia: encerrando")
    return 0


if __name__ == "__main__":
    sys.exit(main())
