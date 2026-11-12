#!/usr/bin/env python3
"""Exporta a documentação do nomad para o cofre do Obsidian.

Lê os repositórios de obsidian/sources.toml (locais e por SSH, sempre pelo HEAD) e gera em
<cofre>/projects/nomad uma árvore de notas no formato do exportador do Cerberus:
Central do nomad -> map/<nó> -> notas, com "Pai:" em cada nota e tags map/<grupo>.

Só escreve quando algo mudou (commits, notas manuais, configuração ou o próprio exportador).
Notas manuais nunca são alteradas: só as que têm o marcador GENERATED_BY.

Uso: uv run --no-project python -I obsidian/export_nomad.py [--force] [--graph] [--dry-run]
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import posixpath
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

GENERATED_BY = "gerado por nomad-enhancement/obsidian/export_nomad.py"
MARKER = f"<!-- {GENERATED_BY}: não edite aqui (suas notas vão em notes/) -->"
BASE_MARKER = f"# {GENERATED_BY}: não edite aqui"
BASE = "projects/nomad"
GENERATED_DIRS = ("map", "guides", "configs", "shortcuts", "history")
CENTRAL = "Central do nomad"
EXPORT_CMD = "uv run --no-project python -I ~/development/personal/nomad-enhancement/obsidian/export_nomad.py"
UNIT_SUFFIXES = (".service", ".timer", ".path", ".socket", ".mount", ".target")
MAX_BLOB = 256 * 1024
SECRET_RE = re.compile(r"(?i)((?:password|passwd|secret|token|api[_-]?key|authkey)[\w.-]*\"?\s*[=:]\s*)(?!‹)[^\s\"',;]+")
HOME_START, HOME_END = "<!-- nomad-central -->", "<!-- /nomad-central -->"


# ----------------------------------------------------------------------------- git


def _env() -> dict[str, str]:
    env = dict(os.environ)
    env.setdefault("GIT_SSH_COMMAND", "ssh -o BatchMode=yes -o ConnectTimeout=10")
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env


def git(cwd: Path, *args: str, check: bool = True, timeout: int = 120) -> str:
    r = subprocess.run(
        ["git", "-C", str(cwd), "-c", "core.quotePath=false", *args],
        capture_output=True, env=_env(), timeout=timeout, check=False,
    )
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout.decode("utf-8", errors="replace")


def read_blobs(cwd: Path, oids: list[str]) -> dict[str, bytes]:
    if not oids:
        return {}
    r = subprocess.run(["git", "-C", str(cwd), "cat-file", "--batch"],
                       input=("\n".join(oids) + "\n").encode(), capture_output=True, check=True)
    out, pos, res = r.stdout, 0, {}
    for oid in oids:
        nl = out.index(b"\n", pos)
        header = out[pos:nl].split()
        if len(header) < 3 or header[1] == b"missing":
            pos = nl + 1
            continue
        size = int(header[2])
        res[oid] = out[nl + 1:nl + 1 + size]
        pos = nl + 1 + size + 1
    return res


@dataclass
class Commit:
    sha: str
    ts: int
    subject: str
    files: list[str]


@dataclass
class Repo:
    name: str
    location: str
    description: str = ""
    keywords: list[str] = field(default_factory=list)
    discovered: bool = False
    status: str = "ok"
    head: str = ""
    branch: str = ""
    remote: str = ""
    files: dict[str, int] = field(default_factory=dict)  # path -> size
    texts: dict[str, str] = field(default_factory=dict)
    commits: list[Commit] = field(default_factory=list)  # newest first

    @property
    def available(self) -> bool:
        return bool(self.head)


def mirror(url: str, cache: Path) -> tuple[Path, str]:
    """Clona/atualiza um espelho local de um repo remoto. Devolve (git dir, status)."""
    if not (cache / "HEAD").exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        r = subprocess.run(["git", "clone", "--mirror", "-q", url, str(cache)],
                           capture_output=True, env=_env(), timeout=600, check=False)
        if r.returncode != 0:
            return cache, "indisponível: " + _first_line(r.stderr)
        return cache, "ok"
    r = subprocess.run(["git", "-C", str(cache), "fetch", "--prune", "-q"],
                       capture_output=True, env=_env(), timeout=600, check=False)
    if r.returncode != 0:
        return cache, "desatualizado (falha no fetch: " + _first_line(r.stderr) + ")"
    # o HEAD do espelho acompanha a branch padrão do remoto
    subprocess.run(["git", "-C", str(cache), "remote", "set-head", "origin", "-a"], capture_output=True, env=_env(), check=False)
    return cache, "ok"


def _first_line(b: bytes) -> str:
    lines = [ln.strip() for ln in b.decode(errors="replace").splitlines() if ln.strip()]
    for ln in lines:  # a causa vem antes do "fatal: Could not read from remote repository"
        if not ln.lower().startswith(("fatal: could not read", "please make sure", "and the repository")):
            return ln
    return lines[0] if lines else "erro desconhecido"


def load_repo(src: dict, cache_dir: Path, discovered: bool = False) -> Repo:
    name = src["name"]
    if "url" in src:
        repo = Repo(name, src["url"])
        gdir, repo.status = mirror(src["url"], cache_dir / f"{name}.git")
        if not (gdir / "HEAD").exists():
            return _with_meta(repo, src, discovered)
    else:
        path = Path(os.path.expanduser(src["path"]))
        repo = Repo(name, str(path).replace(str(Path.home()), "~", 1))
        if not (path / ".git").exists():
            repo.status = "indisponível: não é um repositório git"
            return _with_meta(repo, src, discovered)
        gdir = path
    _with_meta(repo, src, discovered)
    repo.head = git(gdir, "rev-parse", "--verify", "-q", "HEAD^{commit}", check=False).strip()
    if not repo.head:
        repo.status = "sem commits" if repo.status == "ok" else repo.status
        return repo
    repo.branch = git(gdir, "symbolic-ref", "--short", "-q", "HEAD", check=False).strip() or "HEAD destacado"
    repo.remote = git(gdir, "config", "--get", "remote.origin.url", check=False).strip()
    if "url" in src:
        repo.remote = src["url"]
    oids: dict[str, str] = {}
    for entry in git(gdir, "ls-tree", "-r", "-l", "-z", "HEAD").split("\0"):
        if not entry:
            continue
        meta, path = entry.split("\t", 1)
        _mode, kind, oid, size = meta.split()
        if kind != "blob":
            continue
        repo.files[path] = int(size) if size != "-" else 0
        if repo.files[path] <= MAX_BLOB:
            oids[path] = oid
    blobs = read_blobs(gdir, list(oids.values()))
    for path, oid in oids.items():
        data = blobs.get(oid, b"")
        if b"\0" in data[:8192]:
            continue
        try:
            repo.texts[path] = data.decode("utf-8")
        except UnicodeDecodeError:
            pass
    log = git(gdir, "log", "--name-only", "--format=%x1e%H%x1f%ct%x1f%s", "HEAD")
    for rec in log.split("\x1e"):
        if not rec.strip():
            continue
        head, *rest = rec.split("\n")
        sha, ts, subject = head.split("\x1f", 2)
        repo.commits.append(Commit(sha, int(ts), subject.strip(), [f for f in rest if f.strip()]))
    return repo


def _with_meta(repo: Repo, src: dict, discovered: bool) -> Repo:
    repo.description = src.get("description", "")
    repo.keywords = list(src.get("keywords", []))
    repo.discovered = discovered
    return repo


def discover(cfg: dict, known: set[str]) -> list[dict]:
    found = []
    ignore = set(cfg.get("ignore", []))
    for d in cfg.get("discover", []):
        root = Path(os.path.expanduser(d))
        if not root.is_dir():
            continue
        for child in sorted(root.iterdir()):
            if child.name in known or child.name in ignore or not (child / ".git").exists():
                continue
            found.append({"name": child.name, "path": str(child)})
    return found


# ----------------------------------------------------------------------------- markdown helpers


def safe(name: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r'[\\/#|^:%\[\]*?"<>]', "-", name)).strip()


def link(rel: str, label: str | None = None, table: bool = False) -> str:
    """Wikilink por caminho completo a partir de projects/nomad (ou absoluto no cofre se começar com projects/)."""
    target = rel if rel.startswith("projects/") else f"{BASE}/{rel}"
    label = label or Path(rel).name
    return f"[[{target}{'\\|' if table else '|'}{label}]]"


def cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ").strip()


def yaml_str(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def note(title: str, *, type_: str, kind: str, tags: list[str], parent: str | None,
         body: str, fonte: str | None = None, extra: dict | None = None) -> str:
    fm = [f"title: {yaml_str(title)}", f"type: {type_}", "project: nomad", f"kind: {kind}"]
    if parent:
        fm.append(f"parent: {yaml_str(Path(parent).name)}")
    if fonte:
        fm.append(f"fonte: {yaml_str(fonte)}")
    for k, v in (extra or {}).items():
        fm.append(f"{k}: {v}")
    fm.append(f"tags: [{', '.join(['nomad', *tags])}]")
    parts = ["---", *fm, "---", MARKER]
    if parent:
        parts.append(f"Pai: {link(parent, Path(parent).name)}")
    parts.append(body.rstrip())
    return "\n".join(parts) + "\n"


def frontmatter(text: str) -> tuple[dict[str, str], str]:
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---", 4)
    if end < 0:
        return {}, text
    fm = {}
    for line in text[4:end].splitlines():
        if ":" in line and not line.startswith((" ", "-")):
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip().strip('"')
    body = text[end + 4:]
    return fm, body[1:] if body.startswith("\n") else body


def sections(md: str) -> dict[str, str]:
    out: dict[str, str] = {}
    cur = None
    for line in md.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            cur = m.group(1).lower()
            out[cur] = ""
        elif cur:
            out[cur] += line + "\n"
    return out


def table_rows(md: str) -> list[list[str]]:
    rows = []
    for line in md.splitlines():
        line = line.strip()
        if not (line.startswith("|") and line.endswith("|")):
            continue
        cells = [c.strip() for c in re.split(r"(?<!\\)\|", line[1:-1])]
        if all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
            continue
        rows.append(cells)
    return rows


def first_paragraph(md: str) -> str:
    _, body = frontmatter(md)
    para: list[str] = []
    for line in body.splitlines():
        s = line.strip()
        if s.startswith(("#", "<!--", "|", "```", ">", "=", "-" * 3)) and not para:
            continue
        if not s:
            if para:
                break
            continue
        if s.startswith(("#", "|", "```")):
            break
        para.append(s)
    return " ".join(para)[:400]


def header_comment(path: str, text: str) -> str:
    if path.endswith(UNIT_SUFFIXES):
        m = re.search(r"^Description=(.+)$", text, re.M)
        return m.group(1).strip() if m else ""
    if path.endswith(".md"):
        m = re.search(r"^#\s+(.+)$", frontmatter(text)[1], re.M)
        return m.group(1).strip() if m else ""
    if path.endswith(".py"):
        m = re.match(r'(?:\s*#.*\n)*\s*(?:"""|\'\'\')\s*(.*?)(?:\n\s*\n|"""|\'\'\')', text, re.S)
        if m:
            return " ".join(m.group(1).split())[:280]
    lines = text.splitlines()
    para: list[str] = []
    for i, line in enumerate(lines):
        s = line.strip()
        if i == 0 and s.startswith("#!"):
            continue
        if s.startswith(("#", "//")):
            t = s.lstrip("#/").strip()
            if t.lower().startswith(("shellcheck", "-*-", "vim:")):
                continue
            if not t:
                if para:
                    break
                continue
            para.append(t)
        elif not s and not para:
            continue
        else:
            break
    return _short(" ".join(para))


def _short(text: str, limit: int = 200) -> str:
    """Frases inteiras até ~limit caracteres."""
    out = ""
    for sentence in re.split(r"(?<=[.!?])\s+", text):
        if out and len(out) + len(sentence) > limit:
            break
        out = f"{out} {sentence}".strip()
    return out[:limit + 80]


def scrub(text: str) -> str:
    return SECRET_RE.sub(r"\1‹omitido›", text)


def fence(text: str, lang: str = "") -> str:
    ticks = "````" if "```" in text else "```"
    return f"{ticks}{lang}\n{text.rstrip()}\n{ticks}"


def fmt_ts(ts: float, with_year: bool = True) -> str:
    d = dt.datetime.fromtimestamp(ts).astimezone()
    return d.strftime("%d/%m/%Y %H:%M" if with_year else "%d/%m")


def https_url(remote: str) -> str:
    m = re.match(r"^git@([^:]+):(.+?)(?:\.git)?$", remote)
    if m:
        return f"https://{m.group(1)}/{m.group(2)}"
    m = re.match(r"^https?://(.+?)(?:\.git)?$", remote)
    return f"https://{m.group(1)}" if m else ""


# ----------------------------------------------------------------------------- análise


def module_of(path: str) -> str:
    return path.split("/", 1)[0] + "/" if "/" in path else "raiz"


def module_note(repo: str, module: str) -> str:
    return f"map/{safe(repo)} - {safe(module.rstrip('/'))}"


def repo_note(repo: str) -> str:
    return f"map/{safe(repo)} (repo)"


def describe_files(repo: Repo, overrides: dict[str, str]) -> dict[str, str]:
    """Descrição de arquivos e pastas (chave termina em / para pasta)."""
    desc: dict[str, str] = {}
    dirs = {posixpath.dirname(p) for p in repo.files} | {"" }
    alldirs = set()
    for d in dirs:
        while d:
            alldirs.add(d)
            d = posixpath.dirname(d)

    def resolve(base: str, ref: str) -> str | None:
        ref = ref.strip().lstrip("./")
        for cand in (posixpath.normpath(posixpath.join(base, ref)), posixpath.normpath(ref)):
            c = cand.rstrip("/")
            if c in repo.files:
                return c
            if c in alldirs:
                return c + "/"
        return None

    # README primeiro, CLAUDE.md por cima (mais específico), depois cabeçalhos só onde falta
    mds = sorted((p for p in repo.texts if posixpath.basename(p).upper() in ("README.MD", "CLAUDE.MD")),
                 key=lambda p: (posixpath.basename(p).upper() == "CLAUDE.MD", -p.count("/")))
    for md in mds:
        base = posixpath.dirname(md)
        text = repo.texts[md]
        for m in re.finditer(r"^\s*[-*]\s+`([^`]+)`[^:\n]{0,40}?:\s+(.+)$", text, re.M):
            key = resolve(base, m.group(1))
            if key:
                desc[key] = m.group(2).strip()
        for row in table_rows(text):
            m = re.fullmatch(r"`([^`]+)`", row[0]) if row else None
            if m and len(row) >= 2:
                key = resolve(base, m.group(1))
                if key and row[-1]:
                    desc.setdefault(key, row[-1])
    for path, text in repo.texts.items():
        if path not in desc:
            h = header_comment(path, text)
            if h:
                desc[path] = h
    for key, value in overrides.items():
        r, _, p = key.partition(":")
        if r == repo.name:
            desc[p] = value
    return desc


def repo_summary(repo: Repo) -> str:
    if repo.description:
        return repo.description
    claude = repo.texts.get("CLAUDE.md", "")
    m = re.search(r"^-\s*O que é:\s*(.+)$", claude, re.M)
    if m:
        return m.group(1).strip()
    for name in ("README.md", "CLAUDE.md"):
        if name in repo.texts:
            p = first_paragraph(repo.texts[name])
            if p:
                return p
    return "Sem descrição (escreva uma no CLAUDE.md ou no sources.toml)."


def repo_commands(repo: Repo) -> list[tuple[str, str]]:
    cmds = []
    for name in ("CLAUDE.md", "README.md"):
        sec = sections(repo.texts.get(name, "")).get("comandos", "")
        for row in table_rows(sec)[1:]:
            if len(row) >= 2 and row[1]:
                cmds.append((row[0], row[1].strip("`")))
        if cmds:
            break
    return cmds


def script_usages(repo: Repo) -> list[tuple[str, str]]:
    out = []
    for path, text in sorted(repo.texts.items()):
        m = re.search(r"^#\s*(?:Usage|Uso):\s*(.+)$", "\n".join(text.splitlines()[:30]), re.M)
        if m:
            out.append((path, m.group(1).strip()))
    return out


def match_files(patterns: list[str], repos: dict[str, Repo]) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for pat in patterns:
        rname, _, prefix = pat.partition(":")
        repo = repos.get(rname)
        if not repo:
            continue
        for p in repo.files:
            if p.startswith(prefix):
                out.setdefault(rname, []).append(p)
    return {k: sorted(set(v)) for k, v in out.items()}


def kw_score(title: str, text: str, keywords: list[str]) -> int:
    score = 0
    for kw in keywords:
        pat = re.compile(rf"(?<!\w){re.escape(kw)}(?!\w)", re.I)
        if pat.search(title):
            score += 5
        score += min(len(pat.findall(text)), 5)
    return score


@dataclass
class Manual:
    rel: str  # relativo a projects/nomad, sem .md
    title: str
    category: str
    fm: dict[str, str]
    text: str
    mtime: float


CATEGORIES = {
    "Decisões": "Escolhas tomadas, com contexto e como desfazer.",
    "Pesquisas": "Perguntas investigadas e o que se concluiu.",
    "Planos": "Planos de execução e projetos com objetivo.",
    "Guias": "Leia-mes dos repositórios e guias escritos à mão.",
    "Configurações": "Arquivos de configuração versionados (segredos omitidos).",
    "Suas notas": "A pasta notes/: é sua, o exportador nunca mexe lá.",
    "Histórico": "Linha do tempo dos commits e o que mudou a cada exportação.",
}


def manual_notes(vault: Path) -> list[Manual]:
    root = vault / BASE
    out = []
    if not root.is_dir():
        return out
    for p in sorted(root.rglob("*.md")):
        rel = p.relative_to(root).as_posix()
        if rel.split("/", 1)[0] in GENERATED_DIRS or rel == f"{CENTRAL}.md":
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        if GENERATED_BY in text:
            continue
        fm, _ = frontmatter(text)
        t = fm.get("type", "")
        top = rel.split("/", 1)[0]
        if top == "notes":
            cat = "Suas notas"
        elif t == "decision":
            cat = "Decisões"
        elif t == "research" or top == "research":
            cat = "Pesquisas"
        elif t == "project" or top == "plans":
            cat = "Planos"
        else:
            cat = "Guias"
        out.append(Manual(rel[:-3], p.stem, cat, fm, text, p.stat().st_mtime))
    return out


# ----------------------------------------------------------------------------- geração


@dataclass
class Ctx:
    cfg: dict
    repos: dict[str, Repo]
    manual: list[Manual]
    now: dt.datetime
    prev: dict
    system: dict[str, str]


def build(ctx: Ctx) -> dict[str, str]:
    """Gera {caminho relativo a projects/nomad: conteúdo}."""
    out: dict[str, str] = {}
    cfg, repos = ctx.cfg, ctx.repos
    overrides = cfg.get("descriptions", {})
    entities = cfg.get("entity", [])
    descs = {name: describe_files(r, overrides) for name, r in repos.items()}

    # --- notas manuais -> nós (DECISION_ENTITY/RESEARCH_ENTITY do Cerberus = [note_links])
    fixed = cfg.get("note_links", {})
    note_entities: dict[str, list[str]] = {}
    auto_linked: dict[str, list[str]] = {}
    for m in ctx.manual:
        if m.title in fixed:
            note_entities[m.rel] = list(fixed[m.title])
            continue
        scored = sorted(((kw_score(m.title, m.text, e.get("keywords", [])), e["name"]) for e in entities),
                        key=lambda x: (-x[0], x[1]))
        chosen = [n for s, n in scored if s >= 3][:3]
        note_entities[m.rel] = chosen
        if chosen:
            auto_linked[m.rel] = chosen
    note_repos: dict[str, list[str]] = {}
    for m in ctx.manual:
        hits = []
        for r in repos.values():
            # nome curto (ex.: "nomad") aparece em tudo: só conta pelas palavras-chave
            kws = [*r.keywords, *([r.name] if len(r.name) > 6 else [])]
            if kws and kw_score(m.title, m.text, kws) >= 2:
                hits.append(r.name)
        note_repos[m.rel] = sorted(hits)

    # --- serviços: units versionadas + declaradas no TOML
    services: dict[str, dict] = {}
    for r in repos.values():
        for p in r.files:
            base = posixpath.basename(p)
            if base.endswith(UNIT_SUFFIXES):
                services.setdefault(base, {"name": base, "repo": r.name, "file": p,
                                           "text": r.texts.get(p, ""), "description": header_comment(p, r.texts.get(p, ""))})
    for s in cfg.get("service", []):
        services.setdefault(s["name"], {**s, "text": ""})
        services[s["name"]].update({k: v for k, v in s.items() if v})
    service_entity: dict[str, list[str]] = {}
    for e in entities:
        files = match_files(e.get("files", []), repos)
        for sname, s in services.items():
            if s.get("file") in files.get(s.get("repo", ""), []):
                service_entity.setdefault(sname, []).append(e["name"])

    # --- Componentes / Sistema / Serviços / Repositórios / Documentação / Atalhos
    groups = [
        ("Componentes", "componentes", "Hardware em que o nomad roda e as máquinas de que ele depende."),
        ("Sistema", "sistema", "As partes do sistema: imagem, boot, rede, desktop, desenvolvimento."),
        ("Serviços", "servicos", "Units do systemd que o nomad instala, achadas nos repositórios."),
        ("Repositórios", "repos", "Código do nomad, um nó por repositório e um por pasta."),
        ("Documentação", "docs", "Tudo que foi escrito sobre o nomad, em categorias."),
        ("Atalhos", "atalhos", "Comandos, links e referências prontos para copiar e clicar."),
    ]
    for gname, gtag, gdesc in groups:
        children: list[str] = []
        if gtag in ("componentes", "sistema"):
            for e in entities:
                if e.get("group") == gtag:
                    children.append(f"- {link('map/' + safe(e['name']), e['name'])}: {_strip_links(e.get('summary', ''))}")
        elif gtag == "servicos":
            for sname in sorted(services):
                children.append(f"- {link('map/' + safe(sname), sname)}: {services[sname].get('description', '')}")
        elif gtag == "repos":
            for r in sorted(repos.values(), key=lambda r: r.name):
                if not r.discovered:
                    children.append(f"- {link(repo_note(r.name), r.name)}: {repo_summary(r)}")
            if any(r.discovered for r in repos.values()):
                children.append(f"- {link('map/Novos (classificar)', 'Novos (classificar)')}: repositórios achados sozinhos, à espera de um lugar no `sources.toml`.")
        elif gtag == "docs":
            for cat, d in CATEGORIES.items():
                children.append(f"- {link('map/' + cat, cat)}: {d}")
        elif gtag == "atalhos":
            for n, d in (("Comandos", "comandos de cada repositório e uso dos scripts"),
                         ("Links", "repositórios e painéis"), ("Referências", "onde está cada coisa")):
                children.append(f"- {link('shortcuts/' + n, n)}: {d}")
        out[f"map/{gname}.md"] = note(gname, type_="map", kind="group", tags=[f"map/{gtag}", "mapa"],
                                      parent=CENTRAL, body=f"\n{gdesc}\n\n" + "\n".join(children or ["- (nada ainda)"]))

    # --- nós de entidade
    for e in entities:
        gtag = e.get("group", "sistema")
        parent = "map/Componentes" if gtag == "componentes" else "map/Sistema"
        files = match_files(e.get("files", []), repos)
        body = [f"\n{e.get('summary', '')}"]
        if files:
            body.append("\n## Código")
            for rname, paths in files.items():
                body.append(f"\n**{rname}** ({link(repo_note(rname), 'repo')})\n")
                for p in paths[:60]:
                    d = descs[rname].get(p, "")
                    body.append(f"- `{p}` em {link(module_note(rname, module_of(p)), module_of(p).rstrip('/'))}" + (f": {d}" if d else ""))
                if len(paths) > 60:
                    body.append(f"- … e mais {len(paths) - 60} arquivos")
        svcs = [s for s, ents in service_entity.items() if e["name"] in ents]
        if svcs:
            body.append("\n## Serviços\n")
            body += [f"- {link('map/' + safe(s), s)}" for s in sorted(svcs)]
        notes_ = [m for m in ctx.manual if e["name"] in note_entities.get(m.rel, [])]
        if notes_:
            body.append("\n## Notas relacionadas\n")
            body += [f"- {link(m.rel, m.title)} ({m.category.lower()})" for m in notes_]
        out[f"map/{safe(e['name'])}.md"] = note(e["name"], type_="map", kind="component" if gtag == "componentes" else "system",
                                                tags=[f"map/{gtag}", "mapa"], parent=parent, body="\n".join(body))

    # --- serviços
    for sname, s in sorted(services.items()):
        body = [f"\n{s.get('description', '')}\n"]
        if s.get("repo") and s.get("file"):
            body.append(f"Fonte: `{s['repo']}:{s['file']}` em {link(module_note(s['repo'], module_of(s['file'])), module_of(s['file']).rstrip('/'))}")
        if s.get("scope"):
            body.append(f"Escopo: systemd de {s['scope']}")
        if s.get("check"):
            body.append(f"\nConferir: `{s['check']}`")
        if service_entity.get(sname):
            body.append("\nParte de: " + " · ".join(link("map/" + safe(n), n) for n in service_entity[sname]))
        if s.get("text"):
            body.append("\n## Unit\n\n" + fence(scrub(s["text"]), "ini"))
        out[f"map/{safe(sname)}.md"] = note(sname, type_="map", kind="service", tags=["map/servicos", "mapa"],
                                            parent="map/Serviços", body="\n".join(body))

    # --- repositórios e módulos
    # guias: (nota relativa a projects/nomad, rótulo). Arquivo que já está no cofre com o mesmo conteúdo
    # (ex.: README do /root/nomad copiado pelo obsidian/export_nomad.sh de lá) vira link para essa nota.
    copies = {_hash(m.text.strip()): m for m in ctx.manual}
    guides: dict[str, list[tuple[str, str]]] = {}
    for r in repos.values():
        for p in sorted(r.texts):
            if not p.endswith(".md") or "templates" in p.split("/")[:-1]:
                continue  # modelos não são documentação
            if (m := copies.get(_hash(r.texts[p].strip()))) is not None:
                guides.setdefault(r.name, []).append((m.rel, m.title))
                continue
            parts = p[:-3].split("/")
            stem = parts[-1]
            label = {"readme": "readme", "claude": "regras (CLAUDE.md)", "skill": "skill"}.get(stem.lower(), stem)
            gname = safe(" - ".join([r.name, *parts[:-1], label]))
            guides.setdefault(r.name, []).append((f"guides/{gname}", gname))
            _, gbody = frontmatter(r.texts[p])
            out[f"guides/{gname}.md"] = note(
                gname, type_="reference", kind="guide", tags=["guia", "map/docs"], parent="map/Guias",
                fonte=f"{r.name}:{p}",
                body=f"Fonte: `{r.name}:{p}` (commit `{r.head[:7]}`) · repositório {link(repo_note(r.name), r.name)}\n\n{gbody}")

    for r in repos.values():
        parent = "map/Novos (classificar)" if r.discovered else "map/Repositórios"
        mods: dict[str, list[str]] = {}
        for p in r.files:
            mods.setdefault(module_of(p), []).append(p)
        body = [f"\n{repo_summary(r)}\n", "| | |", "|---|---|",
                f"| Onde | `{r.location}` |", f"| Estado | {cell(r.status)} |"]
        if r.available:
            last = r.commits[0] if r.commits else None
            body += [f"| Branch | `{r.branch}` @ `{r.head[:7]}` |"]
            if last:
                body.append(f"| Último commit | {fmt_ts(last.ts)}: {cell(last.subject)} |")
            if https_url(r.remote):
                body.append(f"| Remoto | {https_url(r.remote)} |")
        stack = sections(r.texts.get("CLAUDE.md", "")).get("stack", "").strip()
        if stack:
            body.append(f"\n## Stack\n\n{stack}")
        cmds = repo_commands(r)
        if cmds:
            body.append("\n## Comandos\n\n| Ação | Comando |\n|---|---|")
            body += [f"| {cell(a)} | `{cell(c)}` |" for a, c in cmds]
        if mods:
            body.append("\n## Pastas\n")
            for mod in sorted(mods):
                d = descs[r.name].get(mod, "") if mod != "raiz" else "arquivos na raiz do repositório"
                body.append(f"- {link(module_note(r.name, mod), mod.rstrip('/'))}" + (f": {d}" if d else f" ({len(mods[mod])} arquivos)"))
        if guides.get(r.name):
            body.append("\n## Leia-mes\n")
            body += [f"- {link(rel, label)}" for rel, label in guides[r.name]]
        svcs = sorted(s for s, v in services.items() if v.get("repo") == r.name)
        if svcs:
            body.append("\n## Serviços\n")
            body += [f"- {link('map/' + safe(s), s)}" for s in svcs]
        ents = sorted({e["name"] for e in entities for pat in e.get("files", []) if pat.partition(":")[0] == r.name})
        if ents:
            body.append("\n## Faz parte de\n")
            body += [f"- {link('map/' + safe(n), n)}" for n in ents]
        rel_notes = [m for m in ctx.manual if r.name in note_repos.get(m.rel, [])]
        if rel_notes:
            body.append("\n## Notas relacionadas\n")
            body += [f"- {link(m.rel, m.title)} ({m.category.lower()})" for m in rel_notes]
        if r.commits:
            body.append("\n## Commits recentes\n")
            body += [f"- **{fmt_ts(c.ts)}** {c.subject}" for c in r.commits[:10]]
        out[f"{repo_note(r.name)}.md"] = note(r.name, type_="map", kind="repo", tags=["map/repos", "mapa"],
                                             parent=parent, fonte=r.location, body="\n".join(body))
        for mod, paths in sorted(mods.items()):
            prefix = "" if mod == "raiz" else mod
            mbody = [f"\n{descs[r.name].get(mod, '') or 'Pasta ' + mod}\n", "| Arquivo | O que é |", "|---|---|"]
            for p in sorted(paths):
                shown = p[len(prefix):] if prefix else p
                mbody.append(f"| `{cell(shown)}` | {cell(descs[r.name].get(p, ''))} |")
            pset = set(paths)
            touched = [c for c in r.commits if any(f.startswith(prefix) if prefix else f in pset for f in c.files)]
            if touched:
                mbody.append("\n## Commits que mexeram aqui\n")
                mbody += [f"- **{fmt_ts(c.ts)}** {c.subject}" for c in touched[:8]]
            out[f"{module_note(r.name, mod)}.md"] = note(
                f"{r.name} - {mod.rstrip('/')}", type_="map", kind="module", tags=["map/repos", "mapa"],
                parent=repo_note(r.name), fonte=f"{r.name}:{prefix or '/'}", body="\n".join(mbody))

    discovered = sorted(r.name for r in repos.values() if r.discovered)
    if discovered:
        out["map/Novos (classificar).md"] = note(
            "Novos (classificar)", type_="map", kind="group", tags=["map/repos", "mapa"], parent="map/Repositórios",
            body="\nRepositórios novos em `~/development/personal` que ainda não estão no `obsidian/sources.toml`. "
                 "Já estão documentados; ponha cada um no TOML (com descrição e palavras-chave) ou em `ignore`.\n\n"
                 + "\n".join(f"- {link(repo_note(n), n)}: {repo_summary(repos[n])}" for n in discovered))

    # --- Documentação: categorias
    configs = _configs(repos, services)
    for name, (fonte, text) in configs.items():
        out[f"configs/{name}.md"] = note(name, type_="reference", kind="config", tags=["config", "map/docs"],
                                         parent="map/Configurações", fonte=fonte, body=text)
    for cat, d in CATEGORIES.items():
        items: list[str] = []
        if cat == "Guias":
            items += [f"- {link(rel, label)}" for r in sorted(guides) for rel, label in guides[r] if rel.startswith("guides/")]
        if cat == "Configurações":
            items += [f"- {link('configs/' + n, n)}" for n in sorted(configs)]
        if cat == "Histórico":
            items += [f"- {link('history/Linha do tempo (commits)', 'Linha do tempo (commits)')}: um item por commit, de todos os repositórios",
                      f"- {link('history/Novidades do cofre', 'Novidades do cofre')}: o que mudou na última exportação"]
        items += [f"- {link(m.rel, m.title)}" for m in ctx.manual if m.category == cat]
        out[f"map/{cat}.md"] = note(cat, type_="map", kind="docs", tags=["map/docs", "mapa"], parent="map/Documentação",
                                    body=f"\n{d}\n\n" + "\n".join(items or ["- (nada ainda)"]))

    # --- atalhos
    cmd_lines = ["\nComandos dos repositórios (tabela **Comandos** de cada CLAUDE.md) e uso dos scripts (cabeçalho `Usage:`).\n"]
    for r in sorted(repos.values(), key=lambda r: r.name):
        cmds, uses = repo_commands(r), script_usages(r)
        if not (cmds or uses):
            continue
        cmd_lines.append(f"\n## {r.name}\n\nPasta: `{r.location}` · {link(repo_note(r.name), 'nó do repositório')}\n")
        if cmds:
            cmd_lines += ["| Ação | Comando |", "|---|---|"] + [f"| {cell(a)} | `{cell(c)}` |" for a, c in cmds]
        if uses:
            cmd_lines.append("\n| Script | Uso |\n|---|---|")
            cmd_lines += [f"| `{cell(p)}` | `{cell(u)}` |" for p, u in uses]
    cmd_lines.append("\n## Este cofre\n\n| O que | Comando |\n|---|---|")
    cmd_lines += [f"| {cell(q['what'])} | `{cell(q['cmd'])}` |" for q in cfg.get("quick", [])]
    cmd_lines.append(f"| Atualizar este vault | `{EXPORT_CMD}` |")
    out["shortcuts/Comandos.md"] = note("Comandos", type_="reference", kind="shortcuts", tags=["atalhos", "map/atalhos"],
                                        parent="map/Atalhos", body="\n".join(cmd_lines))
    links = ["\n## Repositórios\n"]
    for r in sorted(repos.values(), key=lambda r: r.name):
        u = https_url(r.remote)
        links.append(f"- **{r.name}**: " + (u if u else f"`{r.remote or r.location}`"))
    links.append("\n## Outros\n")
    for lk in cfg.get("link", []):
        links.append(f"- {link(lk['note'], lk['label']) if 'note' in lk else '[' + lk['label'] + '](' + lk['url'] + ')'}")
    out["shortcuts/Links.md"] = note("Links", type_="reference", kind="shortcuts", tags=["atalhos", "map/atalhos"],
                                     parent="map/Atalhos", body="\n".join(links))
    refs = ["\n| Repositório | Onde | Estado | HEAD |", "|---|---|---|---|"]
    for r in sorted(repos.values(), key=lambda r: r.name):
        refs.append(f"| {link(repo_note(r.name), r.name, table=True)} | `{r.location}` | {cell(r.status)} | `{r.head[:7] or '-'}` |")
    refs.append("\n## Esta documentação\n\n"
                "- Exportador: `~/development/personal/nomad-enhancement/obsidian/export_nomad.py`\n"
                "- Fontes e nós do mapa: `obsidian/sources.toml` (ajuste lá, não nas notas)\n"
                "- Estado: `~/.local/state/nomad-obsidian/state.json` · espelhos remotos: `~/.cache/nomad-obsidian/`\n"
                "- Timer: `nomad-obsidian.timer` (systemd --user, a cada 10 min)")
    out["shortcuts/Referências.md"] = note("Referências", type_="reference", kind="shortcuts", tags=["atalhos", "map/atalhos"],
                                           parent="map/Atalhos", body="\n".join(refs))

    # --- histórico
    all_commits = sorted(((c, r.name) for r in repos.values() for c in r.commits), key=lambda x: (x[0].ts, x[1]))
    tl = ["\n# Linha do tempo dos repositórios\n", "Um item por commit, de todos os repositórios do nomad, do mais antigo ao mais novo.\n"]
    tl += [f"- **{fmt_ts(c.ts)}** `{name}` {c.subject}" for c, name in all_commits]
    out["history/Linha do tempo (commits).md"] = note("Linha do tempo", type_="reference", kind="history",
                                                      tags=["historia", "map/docs"], parent="map/Histórico",
                                                      fonte="git log dos repositórios do nomad", body="\n".join(tl))

    out["indexes.base"] = _indexes_base()
    out[f"{CENTRAL}.md"] = _central(ctx, all_commits, services)
    out["history/Novidades do cofre.md"] = _novidades(ctx, out, auto_linked)
    return out


def _strip_links(s: str) -> str:
    return re.sub(r"\[\[[^\]|]+\|([^\]]+)\]\]", r"\1", s)


def _configs(repos: dict[str, Repo], services: dict[str, dict]) -> dict[str, tuple[str, str]]:
    units = [(s["repo"], s["file"], s["text"]) for s in services.values() if s.get("text")]
    drop_ins = [(r.name, p, r.texts[p]) for r in repos.values() for p in r.texts
                if posixpath.basename(posixpath.dirname(p)).endswith(".d") and p.endswith(".conf")]
    out = {}
    if units or drop_ins:
        parts = ["\nUnits e drop-ins do systemd versionados nos repositórios (segredos omitidos).\n"]
        for rname, p, text in sorted(units + drop_ins):
            parts.append(f"## {posixpath.basename(p)}\nFonte: `{rname}:{p}`\n\n{fence(scrub(text), 'ini')}\n")
        out["Systemd (units do nomad)"] = ("arquivos de unit nos repositórios", "\n".join(parts))
    orca = [(r.name, r.texts["orca.yaml"]) for r in repos.values() if "orca.yaml" in r.texts]
    if orca:
        parts = ["\nAbas que o Orca abre em cada repositório.\n"]
        for rname, text in sorted(orca):
            parts.append(f"## {rname}\n\n{fence(scrub(text), 'yaml')}\n")
        out["Orca (abas por repositório)"] = ("orca.yaml dos repositórios", "\n".join(parts))
    return out


def _indexes_base() -> str:
    def view(name: str, cond: str, cols: list[str], sort: str) -> str:
        return (f"  - type: table\n    name: {name}\n    filters:\n      and:\n        - {cond}\n"
                f"    order:\n" + "".join(f"      - {c}\n" for c in cols)
                + f"    sort:\n      - property: {sort}\n        direction: DESC\n")
    return (f"{BASE_MARKER}\nfilters:\n  and:\n    - file.inFolder(\"{BASE}\")\n    - file.ext == \"md\"\nviews:\n"
            + view("Decisões", 'type == "decision"', ["file.name", "status", "date"], "date")
            + view("Pesquisas", 'type == "research" || file.inFolder("projects/nomad/research")', ["file.name", "status", "date"], "file.mtime")
            + view("Planos", 'type == "project" || file.inFolder("projects/nomad/plans")', ["file.name", "status", "file.mtime"], "file.mtime")
            + view("Guias", 'file.inFolder("projects/nomad/guides")', ["file.name", "fonte"], "file.name"))


def _central(ctx: Ctx, all_commits: list, services: dict) -> str:
    repos = ctx.repos
    lines = ["\n# nomad\n",
             f"Central de informações do nomad: Bazzite KDE no pendrive e no notebook, com as melhorias e a configuração do dia a dia. "
             f"Exportado em {ctx.now.strftime('%d/%m/%Y %H:%M')}.\n",
             "Suas notas ficam em `notes/` (o exportador nunca mexe lá); as notas manuais que já existiam (melhorias, pesquisas, planos) "
             f"também não são tocadas, só ligadas ao mapa. O resto é regenerado dos repositórios: `{EXPORT_CMD}` (a cada 10 min se algo mudou).\n",
             "## Estado (fotografia da exportação)\n",
             "É uma foto, não ao vivo: para o estado real use os [[projects/nomad/shortcuts/Comandos|Comandos]].\n"]
    if ctx.system:
        lines.append("| Sistema | |\n|---|---|")
        lines += [f"| {cell(k)} | {cell(v)} |" for k, v in ctx.system.items()]
        lines.append("")
    lines.append("| Repositório | Branch | Último commit | Estado |\n|---|---|---|---|")
    for r in sorted(repos.values(), key=lambda r: r.name):
        last = f"{fmt_ts(r.commits[0].ts)}" if r.commits else "-"
        lines.append(f"| {link(repo_note(r.name), r.name, table=True)} | `{r.branch or '-'}` | {last} | {cell(r.status)} |")
    pend = []
    for m in ctx.manual:
        for t in re.findall(r"^\s*[-*]\s+\[ \]\s+(.+)$", m.text, re.M):
            pend.append(f"- {t.strip()} ({link(m.rel, m.title)})")
    lines.append("\n## Pendências\n")
    lines.append("Itens `- [ ]` abertos nas notas manuais. Marque `[x]` na nota e ele sai daqui na próxima exportação.\n")
    lines += pend or ["- (nenhuma)"]
    lines.append("\n## Atalhos rápidos\n")
    lines.append("Só leitura, exceto a última linha (atualiza este vault). Todos: [[projects/nomad/shortcuts/Comandos|Comandos]] · "
                 "[[projects/nomad/shortcuts/Links|Links]] · [[projects/nomad/shortcuts/Referências|Referências]].\n")
    lines.append("| O que | Comando |\n| --- | --- |")
    lines += [f"| {cell(q['what'])} | `{cell(q['cmd'])}` |" for q in ctx.cfg.get("quick", [])]
    lines.append(f"| Atualizar este vault | `{EXPORT_CMD}` |")
    lines.append("\n## O que mudou\n")
    lines.append("[[projects/nomad/history/Novidades do cofre|Novidades do cofre]]: o que entrou desde a última exportação e o que foi ligado sozinho.\n")
    lines.append("Últimos commits dos repositórios:\n")
    lines += [f"- **{fmt_ts(c.ts, False)}** `{n}` {c.subject}" for c, n in reversed(all_commits[-10:])] or ["- (nenhum)"]
    dec = sorted((m for m in ctx.manual if m.category == "Decisões"), key=lambda m: -m.mtime)[:6]
    if dec:
        lines.append("\nDecisões mexidas por último:\n")
        lines += [f"- {fmt_ts(m.mtime, False)} {link(m.rel, m.title)}" for m in dec]
    lines.append("\n## Mapa\n")
    lines.append("O grafo é uma árvore: cada nota tem um pai e lista o que contém. Para ver só o nomad no grafo, "
                 'busque `path:"projects/nomad"`; para ver a documentação inteira, limpe a busca.\n')
    lines += [f"- {link('map/' + g, g)}: {d}" for g, d in (
        ("Componentes", "hardware do nomad e as máquinas de que ele depende."),
        ("Sistema", "imagem, boot, rede, desktop e desenvolvimento."),
        ("Serviços", "units do systemd instaladas pelos repositórios."),
        ("Repositórios", "o código, por repositório e por pasta."),
        ("Documentação", "decisões, pesquisas, planos, guias, configurações e histórico."),
        ("Atalhos", "comandos, links e referências."))]
    lines.append("\n## Índices\n")
    for v in ("Decisões", "Pesquisas", "Planos", "Guias"):
        lines.append(f"### {v}\n![[{BASE}/indexes.base#{v}]]\n")
    body = "\n".join(lines)
    fm = ["---", f"title: {yaml_str('nomad')}", "type: project", "status: ativo", "area: tecnologia", "icon: LiUsb",
          "project: nomad", "kind: central", "tags: [nomad, inicio]", "---", MARKER]
    return "\n".join(fm) + body + "\n"


def _novidades(ctx: Ctx, out: dict[str, str], auto_linked: dict[str, list[str]]) -> str:
    prev_files: dict[str, str] = ctx.prev.get("files", {})
    volatile = {f"{CENTRAL}.md", "history/Novidades do cofre.md"}
    cur = {k: _hash(v) for k, v in out.items() if k not in volatile}
    new = sorted(k for k in cur if k not in prev_files)
    changed = sorted(k for k in cur if k in prev_files and prev_files[k] != cur[k])
    removed = sorted(k for k in prev_files if k not in cur and k not in volatile)
    prev_heads: dict[str, str] = ctx.prev.get("heads", {})
    when = ctx.prev.get("exported_at")

    def ln(k: str) -> str:
        return link(k[:-3], Path(k).stem) if k.endswith(".md") else f"`{k}`"

    lines = ["\n# Novidades do cofre\n",
             f"Gerada a cada exportação que muda algo (o timer roda a cada 10 min). Última: {ctx.now.strftime('%d/%m/%Y %H:%M')}.\n",
             f"## Desde a exportação anterior ({when or 'primeira exportação'})\n"]
    for title, items, fmt in (("Novas", new, ln), ("Alteradas", changed, ln), ("Removidas", removed, lambda k: f"`{k}`")):
        lines.append(f"**{title} ({len(items)})**\n")
        lines += [f"- {fmt(k)}" for k in items[:80]] or ["- (nenhuma)"]
        if len(items) > 80:
            lines.append(f"- … e mais {len(items) - 80}")
        lines.append("")
    lines.append("## Commits novos\n")
    any_commit = False
    for r in sorted(ctx.repos.values(), key=lambda r: r.name):
        old = prev_heads.get(r.name)
        if not r.commits or old == r.head:
            continue
        shas = [c.sha for c in r.commits]
        fresh = r.commits[:shas.index(old)] if old in shas else r.commits[: (10 if old is None else len(r.commits))]
        if old is None and ctx.prev:
            lines.append(f"**{r.name}** (repositório novo no mapa)\n")
        else:
            lines.append(f"**{r.name}**\n")
        lines += [f"- **{fmt_ts(c.ts)}** {c.subject}" for c in fresh[:20]]
        lines.append("")
        any_commit = True
    if not any_commit:
        lines.append("- (nenhum)\n")
    lines.append("## Ligadas automaticamente (confira)\n")
    lines.append("Notas manuais ligadas a nós do mapa pelo título e pelas palavras do texto. Se estiver errado, fixe em `[note_links]` no `obsidian/sources.toml`.\n")
    lines += [f"- {link(rel, Path(rel).name)} → {', '.join(ents)}" for rel, ents in sorted(auto_linked.items())] or ["- (nenhuma)"]
    orphans = [m for m in ctx.manual if not any(e for e in auto_linked.get(m.rel, []))
               and m.title not in ctx.cfg.get("note_links", {}) and m.category != "Suas notas"]
    lines.append("\n## Sem nó (precisam de você)\n")
    lines.append("Nenhum nó do mapa combinou (elas continuam ligadas pela categoria em Documentação). Ligue em `[note_links]` ou ponha palavras-chave no nó certo.\n")
    lines += [f"- {link(m.rel, m.title)}" for m in orphans] or ["- (nenhuma)"]
    novos = sorted(r.name for r in ctx.repos.values() if r.discovered)
    if novos:
        lines.append("\n## Repositórios sem lugar\n")
        lines += [f"- {link(repo_note(n), n)}: classifique no `sources.toml`" for n in novos]
    return note("Novidades do cofre", type_="reference", kind="history", tags=["historia", "automatico", "map/docs"],
                parent="map/Histórico", body="\n".join(lines))


def _hash(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()[:16]


# ----------------------------------------------------------------------------- escrita


def owned(path: Path) -> bool:
    try:
        return GENERATED_BY in path.read_text(encoding="utf-8", errors="replace")[:4096]
    except FileNotFoundError:
        return False


def write_outputs(root: Path, outputs: dict[str, str], prev_files: dict[str, str], dry_run: bool) -> dict[str, list[str]]:
    report: dict[str, list[str]] = {"written": [], "removed": [], "skipped": []}
    for rel, content in sorted(outputs.items()):
        path = root / rel
        if path.exists():
            if not owned(path):
                report["skipped"].append(rel)  # nota do usuário no mesmo caminho: não sobrescreve
                continue
            if path.read_text(encoding="utf-8") == content:
                continue
        report["written"].append(rel)
        if not dry_run:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_name(f".{path.name}.tmp")
            tmp.write_text(content, encoding="utf-8")
            os.replace(tmp, path)
    stale = set(prev_files) - set(outputs)
    for d in GENERATED_DIRS:
        if (root / d).is_dir():
            stale |= {p.relative_to(root).as_posix() for p in (root / d).rglob("*.md")} - set(outputs)
    for rel in sorted(stale):
        path = root / rel
        if path.exists() and owned(path):
            report["removed"].append(rel)
            if not dry_run:
                path.unlink()
    return report


def ensure_notes_readme(root: Path, dry_run: bool) -> None:
    readme = root / "notes" / "LEIA-ME.md"
    if readme.exists() or dry_run:
        return
    readme.parent.mkdir(parents=True, exist_ok=True)
    readme.write_text("# Suas notas\n\nTudo nesta pasta é seu: o exportador do nomad nunca altera nem apaga nada aqui.\n"
                      f"Volte para a [[{BASE}/{CENTRAL}|central do nomad]].\n", encoding="utf-8")


def update_home(vault: Path, dry_run: bool) -> bool:
    home = vault / "Home.md"
    if not home.exists():
        return False
    text = home.read_text(encoding="utf-8")
    block = (f"{HOME_START}\n> [!info] Central do nomad\n> [[{BASE}/{CENTRAL}|Abrir a central]] · "
             f"[[{BASE}/shortcuts/Comandos|Comandos]] · [[{BASE}/shortcuts/Links|Links]] · "
             f"[[{BASE}/shortcuts/Referências|Referências]]\n{HOME_END}")
    if HOME_START in text and HOME_END in text:
        new = re.sub(re.escape(HOME_START) + r".*?" + re.escape(HOME_END), lambda _: block, text, flags=re.S)
    else:
        lines = text.split("\n")
        idx = None
        for i, line in enumerate(lines):
            if line.strip() == "<!-- cerberus-central -->":
                idx = i + 1
                while idx < len(lines) and lines[idx].startswith(">"):
                    idx += 1
                break
        if idx is None:
            fm_end = text.find("\n---", 4) if text.startswith("---\n") else -1
            idx = text[:fm_end + 4].count("\n") + 1 if fm_end >= 0 else 0
        lines[idx:idx] = ["", *block.split("\n")]
        new = "\n".join(lines)
    if new == text:
        return False
    if not dry_run:
        home.write_text(new, encoding="utf-8")
    return True


GRAPH_SEARCH = [f'path:"{BASE}/map"', f'path:"{BASE}/shortcuts"', f'path:"{BASE}/{CENTRAL}.md"']
GRAPH_COLORS = [
    (f'path:"{BASE}/{CENTRAL}.md"', 0x2EA36B),
    (f'path:"{BASE}/notes"', 13751771),
    ("tag:#map/sistema", 0x8E6CEF),
    ("tag:#map/repos", 0xE0A030),
]


def merge_graph(vault: Path, dry_run: bool) -> bool:
    path = vault / ".obsidian" / "graph.json"
    data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    before = json.dumps(data, sort_keys=True)
    search = data.get("search", "").strip()
    if search:  # só estende uma busca que já filtra; busca vazia já mostra tudo
        missing = [s for s in GRAPH_SEARCH if s not in search]
        if missing:
            data["search"] = " OR ".join([search, *missing])
    groups = data.setdefault("colorGroups", [])
    have = {g.get("query") for g in groups}
    for q, rgb in GRAPH_COLORS:
        if q not in have:
            groups.append({"query": q, "color": {"a": 1, "rgb": rgb}})
    if json.dumps(data, sort_keys=True) == before:
        return False
    if not dry_run:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    return True


# ----------------------------------------------------------------------------- main


def system_info() -> dict[str, str]:
    info = {"Máquina": platform.node(), "Kernel": platform.release()}
    try:
        osr = dict(ln.split("=", 1) for ln in Path("/etc/os-release").read_text().splitlines() if "=" in ln)
        info["Sistema"] = f"{osr.get('NAME', '').strip('\"')} {osr.get('VERSION', '').strip('\"')}".strip()
    except OSError:
        pass
    return info


def fingerprint(cfg_text: str, repos: dict[str, Repo], manual: list[Manual], system: dict[str, str]) -> str:
    h = hashlib.sha256()
    h.update(Path(__file__).read_bytes())
    h.update(cfg_text.encode())
    h.update(json.dumps(system, sort_keys=True).encode())
    for r in sorted(repos.values(), key=lambda r: r.name):
        h.update(f"{r.name}\0{r.head}\0{r.branch}\0{r.status}\0{r.discovered}\n".encode())
    for m in manual:
        h.update(f"{m.rel}\0{_hash(m.text)}\0{int(m.mtime)}\n".encode())
    return h.hexdigest()


def main(argv: list[str] | None = None) -> int:
    xdg_state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    xdg_cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", type=Path, default=Path(__file__).with_name("sources.toml"))
    ap.add_argument("--vault", type=Path)
    ap.add_argument("--state", type=Path, default=xdg_state / "nomad-obsidian/state.json")
    ap.add_argument("--cache", type=Path, default=xdg_cache / "nomad-obsidian")
    ap.add_argument("--force", action="store_true", help="regenera mesmo sem mudança")
    ap.add_argument("--graph", action="store_true", help="mescla cores e busca do nomad no graph.json do cofre")
    ap.add_argument("--dry-run", action="store_true", help="mostra o que mudaria, sem escrever")
    ap.add_argument("--no-system", action="store_true", help="não inclui dados desta máquina (testes)")
    args = ap.parse_args(argv)

    cfg_text = args.config.read_text(encoding="utf-8")
    cfg = tomllib.loads(cfg_text)
    vault = (args.vault or Path(os.path.expanduser(cfg.get("vault", "~/Vault")))).resolve()
    if not vault.is_dir():
        print(f"cofre não encontrado: {vault}", file=sys.stderr)
        return 1
    root = vault / BASE

    if args.graph:
        print("graph.json: " + ("atualizado" if merge_graph(vault, args.dry_run) else "ok"))

    sources = list(cfg.get("source", []))
    known = {s["name"] for s in sources}
    repos: dict[str, Repo] = {}
    for s in sources:
        repos[s["name"]] = load_repo(s, args.cache)
    for s in discover(cfg, known):
        repos[s["name"]] = load_repo(s, args.cache, discovered=True)
    for r in repos.values():
        if r.status != "ok":
            print(f"{r.name}: {r.status}", file=sys.stderr)

    ensure_notes_readme(root, args.dry_run)  # antes de ler as notas: o LEIA-ME entra no mapa
    manual = manual_notes(vault)
    system = {} if args.no_system else system_info()
    prev = json.loads(args.state.read_text()) if args.state.exists() else {}
    fp = fingerprint(cfg_text, repos, manual, system)
    missing = [f for f in prev.get("files", {}) if not (root / f).exists()]
    home_changed = update_home(vault, args.dry_run)
    if home_changed:
        print("Home.md: bloco do nomad atualizado")
    if not args.force and prev.get("fingerprint") == fp and not missing:
        print("nada mudou")
        return 0

    now = dt.datetime.now().astimezone()
    outputs = build(Ctx(cfg, repos, manual, now, prev, system))
    report = write_outputs(root, outputs, prev.get("files", {}), args.dry_run)
    verb = "mudaria" if args.dry_run else "escritas"
    print(f"{len(report['written'])} notas {verb}, {len(report['removed'])} removidas, {len(outputs)} no total")
    for rel in report["skipped"]:
        print(f"pulada (nota sua no mesmo caminho): {rel}", file=sys.stderr)
    if args.dry_run:
        for rel in report["written"]:
            print(f"  ~ {rel}")
        for rel in report["removed"]:
            print(f"  - {rel}")
        return 0
    volatile = {f"{CENTRAL}.md", "history/Novidades do cofre.md"}
    state = {
        "fingerprint": fp,
        "exported_at": now.strftime("%d/%m %H:%M"),
        "heads": {r.name: r.head for r in repos.values() if r.head},
        "files": {k: _hash(v) for k, v in outputs.items() if k not in volatile},
    }
    # os voláteis também ficam na lista (para limpeza), com hash vazio
    state["files"].update({k: "" for k in volatile if k in outputs})
    args.state.parent.mkdir(parents=True, exist_ok=True)
    args.state.write_text(json.dumps(state, indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
