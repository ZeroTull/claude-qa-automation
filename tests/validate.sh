#!/usr/bin/env bash
# Checks that every agent, skill and command is cataloged, loadable by Claude Code, documented,
# and that our own entries carry the safety rules. Also checks both settings files.
# Usage: tests/validate.sh [repo-dir]   (defaults to this repo)
# Needs only python3 (standard library). Runs as one process so the whole check stays fast.
set -uo pipefail

REPO="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"

# -X utf8: read files as UTF-8 even under LANG=C (the entries contain non-ASCII characters).
exec python3 -X utf8 - "$REPO" <<'PYTHON'
import hashlib
import json
import os
import re
import sys

repo = sys.argv[1]
# Catalog groups this repo may contain. claude-dev allows personal and third-party instead.
ALLOWED_GROUPS = ("qa", "third-party")
errors = []
err = errors.append


def rel(path):
    return os.path.relpath(path, repo)


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


# ── frontmatter ──────────────────────────────────────────────────────────────
# A strict parser for the YAML subset that agent and skill frontmatter uses:
#   - top-level `key: value`, where value is plain, "double-quoted" or 'single-quoted', with an optional # comment
#   - folded (>, >-, >+) and literal (|, |-, |+) block scalars
#   - one level of nested `key: value` mappings, all at the same indent
# Anything outside the subset is rejected with a message, never guessed, so a file that passes is unambiguous YAML.

class YamlError(Exception):
    pass


KEY = re.compile(r"^([A-Za-z0-9_-]+):(?: (.*))?$")
DOUBLE = re.compile(r'"(?:[^"\\]|\\.)*"')
SINGLE = re.compile(r"'(?:[^']|'')*'")
TRAILER = re.compile(r"\s*(#.*)?")
BLOCK = re.compile(r"([>|])([+-]?)(\s+#.*)?")


def is_comment(line):
    return line.strip().startswith("#")


def scalar(raw, lineno):
    v = raw.strip()
    if v.startswith(('"', "'")):
        m = (DOUBLE if v[0] == '"' else SINGLE).match(v)
        if not m:
            raise YamlError(f"unterminated quoted string on line {lineno} (multi-line quoted values are not supported)")
        if not TRAILER.fullmatch(v[m.end():]):
            raise YamlError(f"unexpected text after quoted string on line {lineno}")
        if v[0] == "'":
            return m.group(0)[1:-1].replace("''", "'")
        try:
            return json.loads(m.group(0))
        except ValueError:
            raise YamlError(f"unsupported escape in double-quoted string on line {lineno}")
    v = re.sub(r"(?:^|\s)#.*$", "", v).strip()
    if v in ("", "~", "null", "Null", "NULL"):
        return None
    if re.match(r"[-?:](\s|$)", v):
        raise YamlError(f"sequence or mapping indicator on line {lineno}; quote the value")
    if ": " in v or v.endswith(":"):
        raise YamlError(f"mapping values are not allowed in this context on line {lineno}")
    if v[0] in "&*!":
        raise YamlError(f"anchors, aliases and tags are not supported (line {lineno})")
    if v[0] in "[]{}%@`|>,":
        raise YamlError(f"plain value on line {lineno} starts with a reserved character; quote it")
    return v


def nested_mapping(block, first_lineno):
    content = [(n, b) for n, b in enumerate(block, start=first_lineno) if b.strip() and not is_comment(b)]
    indent = len(content[0][1]) - len(content[0][1].lstrip(" "))
    nested = {}
    for idx, (n, b) in enumerate(content):
        if len(b) - len(b.lstrip(" ")) != indent:
            raise YamlError(f"nested line {n} is indented differently from line {content[0][0]}")
        m = KEY.match(b[indent:])
        if not m:
            raise YamlError(f"unexpected nested line {n} (only `key: value` is supported)")
        if m.group(1) in nested:
            raise YamlError(f"duplicate key '{m.group(1)}' on line {n}")
        raw = m.group(2) or ""
        deeper_next = idx + 1 < len(content) and len(content[idx + 1][1]) - len(content[idx + 1][1].lstrip(" ")) > indent
        if deeper_next and (not raw.strip() or is_comment(raw)):
            raise YamlError(f"more than one nesting level is not supported (line {content[idx + 1][0]})")
        nested[m.group(1)] = scalar(raw, n)
    return nested


def parse_frontmatter(text):
    if "\t" in text:
        raise YamlError("tabs are not allowed")
    lines = text.split("\n")
    data, i = {}, 0
    while i < len(lines):
        line, lineno = lines[i], i + 1
        if not line.strip() or is_comment(line):
            i += 1
            continue
        m = KEY.match(line)
        if not m:
            raise YamlError(f"unexpected line {lineno}: {line.strip()[:40]}")
        key, value = m.group(1), (m.group(2) or "").strip()
        if key in data:
            raise YamlError(f"duplicate key '{key}' on line {lineno}")
        i += 1
        block = []
        while i < len(lines) and (lines[i].startswith(" ") or not lines[i].strip()):
            block.append(lines[i])
            i += 1
        while block and not block[-1].strip():
            block.pop()
        has_content = any(b.strip() and not is_comment(b) for b in block)
        bm = BLOCK.fullmatch(value)
        if re.match(r"[>|][+-]?\d", value):
            raise YamlError(f"block indentation indicators are not supported (line {lineno})")
        if bm:
            if not block:
                raise YamlError(f"empty block scalar for '{key}' on line {lineno}")
            indent = min(len(b) - len(b.lstrip(" ")) for b in block if b.strip())
            body = [b[indent:] for b in block]
            data[key] = " ".join(b.strip() for b in body if b.strip()) if bm.group(1) == ">" else "\n".join(body)
        elif not value or is_comment(value):
            data[key] = nested_mapping(block, lineno + 1) if has_content else None
        else:
            if has_content:
                raise YamlError(f"multi-line values are not supported (line {lineno + 1}); use > or |")
            data[key] = scalar(value, lineno)
    return data


def check_frontmatter(file, expected):
    m = re.match(r"\A---\n(.*?)\n---\n", read(file), re.S)
    if not m:
        return err(f"{rel(file)}: missing frontmatter block")
    try:
        data = parse_frontmatter(m.group(1))
    except YamlError as e:
        return err(f"{rel(file)}: invalid YAML: {e}")
    values = {}
    for k in ("name", "description", "model"):
        v = data.get(k)
        if v is not None and not isinstance(v, str):
            return err(f"{rel(file)}: '{k}' must be a plain string")
        values[k] = re.sub(r"\s+", " ", v or "", flags=re.ASCII)
    name, desc, model = values["name"], values["description"], values["model"]
    if name != expected:
        err(f"{rel(file)}: name '{name}' does not match '{expected}'")
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name):
        err(f"{rel(file)}: name '{name}' is not kebab-case")
    if len(desc) < 40:
        err(f"{rel(file)}: description missing or too short")
    if model and not re.fullmatch(r"inherit|opus|sonnet|haiku|claude-[a-z0-9.-]+", model):
        err(f"{rel(file)}: unknown model '{model}'")


# ── helpers ──────────────────────────────────────────────────────────────────
safety = read(f"{repo}/templates/safety.md").strip()
if not safety:
    err("templates/safety.md missing or empty")
platforms = read(f"{repo}/templates/platforms.md").strip()
if not platforms:
    err("templates/platforms.md missing or empty")


def check_platform_commands(text):
    """The table's commands must run without prompts and keep untrusted text out of double quotes."""
    rows = "\n".join(line for line in text.splitlines() if line.startswith("|"))
    for c in re.findall(r"`([^`]+)`", rows):
        if c.startswith("glab ci view"):
            err(f"templates/platforms.md: '{c}' is interactive")
        if re.match(r"jira issue (view|list)\b", c) and "--plain" not in c:
            err(f"templates/platforms.md: '{c}' needs --plain (otherwise it opens a pager)")
        if re.search(r"\bcreate\b", c):
            if not re.search(r"(^| )(-t|-s|--title)( |$)", c):
                err(f"templates/platforms.md: '{c}' needs a title flag (otherwise it prompts)")
            if c.startswith("glab issue create") and " -y" not in c:
                err(f"templates/platforms.md: '{c}' needs -y (otherwise it asks to confirm)")
            if c.startswith("jira issue create") and "--no-input" not in c:
                err(f"templates/platforms.md: '{c}' needs --no-input")
        for m in re.finditer(r'"([^"]*)"', c):
            if m.group(1) != "$(cat <file>)":
                err(f"templates/platforms.md: '{c}' puts text in double quotes; use single quotes or a file")


if platforms:
    check_platform_commands(platforms)
project_map = read(f"{repo}/templates/project-map.md").strip()
if not project_map:
    err("templates/project-map.md missing or empty")
# Every agent reads the map from MAP_FILE and checks its Snapshot line, so the skill that writes it must agree.
MAP_FILE = ".ai/context/framework-map.md"
mapper = read(f"{repo}/skills/framework-map/SKILL.md")
if project_map and (f"`{MAP_FILE}`" not in project_map or "`Snapshot:`" not in project_map):
    err(f"templates/project-map.md must name `{MAP_FILE}` and its `Snapshot:` line")
if mapper and (f"write only `{MAP_FILE}`" not in mapper or "Snapshot: <date>, commit <short sha>" not in mapper):
    err(f"skills/framework-map/SKILL.md must write only `{MAP_FILE}` with a `Snapshot: <date>, commit <short sha>` line")
# The shared blocks mention conventions.md as something to read; only the skill's own text says what it writes.
own_text = mapper.replace(safety, "").replace(platforms, "") if safety and platforms else mapper
for other in sorted(set(re.findall(r"`(\.ai/context/[^`]+)`", own_text)) - {MAP_FILE}):
    err(f"skills/framework-map/SKILL.md names `{other}`; it may only write `{MAP_FILE}`")
if mapper and "under 250 lines" not in mapper:
    err("skills/framework-map/SKILL.md must keep the map under 250 lines")
readme = read(f"{repo}/README.md")
template = read(f"{repo}/templates/CLAUDE.md")


def listed(name, text):
    return re.search(r"`/?" + re.escape(name) + "`", text) is not None


def entry_file(name, kind):
    return {"agent": f"{repo}/agents/{name}.md",
            "skill": f"{repo}/skills/{name}/SKILL.md",
            "command": f"{repo}/commands/{name}.md"}[kind]


def tree_digest(directory):
    """SHA-256 over every file in a skill folder (sorted relative paths and contents), skipping git-ignored junk."""
    files = []
    for root, _, names in os.walk(directory):
        for n in names:
            path = os.path.join(root, n)
            if n == ".DS_Store" or n.endswith(".pyc") or "/__pycache__/" in path + "/":
                continue
            if not os.path.isfile(path):  # broken symlink
                continue
            files.append(path)
    parts = []
    for path in sorted(files, key=lambda p: os.path.relpath(p, directory).encode()):
        with open(path, "rb") as f:
            parts.append(os.path.relpath(path, directory).encode() + b"\0" + f.read())
    return hashlib.sha256(b"\0".join(parts)).hexdigest()


lock = {}
lock_path = f"{repo}/third-party.lock"
has_lock = os.path.exists(lock_path)
if has_lock:
    for line in read(lock_path).splitlines():
        if line and not line.startswith("#"):
            n, _, sha = line.partition("\t")
            lock[n] = sha

# ── catalog ──────────────────────────────────────────────────────────────────
cataloged, third_party = set(), []
catalog = f"{repo}/catalog.tsv"
if not os.path.exists(catalog):
    err("catalog.tsv missing")
else:
    lines = read(catalog).split("\n")
    if lines[0] != "name\tkind\tgroup\tsource":
        err("catalog.tsv: bad header")
    for line in lines[1:]:
        if not line:
            continue
        cols = line.split("\t")
        name, kind, group, source = (cols + ["", "", "", ""])[:4]
        row = f"catalog.tsv: {name}"
        if len(cols) > 4:
            err(f"{row}: more than 4 columns")
        if kind not in ("agent", "skill", "command"):
            err(f"{row}: unknown kind '{kind}'")
            continue
        if group not in ALLOWED_GROUPS:
            err(f"{row}: unknown group '{group}'")
        if group == "third-party":
            if not source.startswith("https://"):
                err(f"{row}: third-party entry needs a source URL")
            third_party.append(name)
        elif source != "-":
            err(f"{row}: source must be '-' for our own entries")
        if f"{kind}:{name}" in cataloged:
            err(f"{row}: duplicate entry")
        cataloged.add(f"{kind}:{name}")

        file = entry_file(name, kind)
        if not os.path.isfile(file):
            err(f"{row}: {rel(file)} does not exist")
            continue
        if kind != "command":
            check_frontmatter(file, name)
        if group != "third-party" and safety not in read(file):
            err(f"{rel(file)}: does not contain the block from templates/safety.md verbatim")
        if not listed(name, readme):
            err(f"{name} not listed in README.md")
        if group == "qa" and not listed(name, template):
            err(f"{name} not listed in templates/CLAUDE.md")
        if group == "qa" and platforms not in read(file):
            err(f"{rel(file)}: does not contain the block from templates/platforms.md verbatim")
        # framework-map builds the map, so it reads the old one on its own terms.
        if group == "qa" and name != "framework-map" and project_map and project_map not in read(file):
            err(f"{rel(file)}: does not contain the block from templates/project-map.md verbatim")

# The qa-lead orchestrator must route every other agent and every skill, so nothing becomes unreachable.
lead_text = read(f"{repo}/agents/qa-lead.md")
if lead_text:
    for key in sorted(cataloged):
        kind, _, name = key.partition(":")
        if kind in ("agent", "skill") and name != "qa-lead" and f"`{name}`" not in lead_text:
            err(f"agents/qa-lead.md does not route {kind} `{name}`")

# Third-party skills are vendored unchanged: their content must match third-party.lock.
if third_party and not has_lock:
    err("third-party.lock missing")
for name in third_party:
    directory = f"{repo}/skills/{name}"
    if not os.path.isdir(directory):
        continue
    actual = tree_digest(directory)
    if name not in lock:
        err(f"third-party.lock has no entry for {name} ({name}\t{actual})")
    elif lock[name] != actual:
        err(f"skills/{name} differs from third-party.lock - third-party skills must stay unchanged (now {actual})")
for name in [n for n in lock if n not in third_party]:
    err(f"third-party.lock lists {name}, which is not a third-party entry")


# Every entry on disk must be cataloged.
def listdir(path):
    """Visible entries only, like a shell glob."""
    return sorted(n for n in os.listdir(path) if not n.startswith(".")) if os.path.isdir(path) else []


entries = 0
for f in listdir(f"{repo}/agents"):
    if f.endswith(".md"):
        entries += 1
        if f"agent:{f[:-3]}" not in cataloged:
            err(f"agents/{f} is not in catalog.tsv")
for d in listdir(f"{repo}/skills"):
    if os.path.isdir(f"{repo}/skills/{d}"):
        entries += 1
        # Exact-case check: macOS finds skill.md as SKILL.md, Linux does not.
        if "SKILL.md" not in os.listdir(f"{repo}/skills/{d}"):
            err(f"skills/{d}: missing SKILL.md (exact case)")
        if f"skill:{d}" not in cataloged:
            err(f"skills/{d} is not in catalog.tsv")
for f in listdir(f"{repo}/commands"):
    if f.endswith(".md"):
        entries += 1
        if f"command:{f[:-3]}" not in cataloged:
            err(f"commands/{f} is not in catalog.tsv")


# ── settings ─────────────────────────────────────────────────────────────────
# settings.example.json: core secret rules present, committed .env templates readable.
# settings.json: valid, portable, and denies at least everything the example denies.
def load_settings(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        err(f"{os.path.basename(path)} is missing")
        return None
    except ValueError:
        err(f"{os.path.basename(path)} is not valid JSON")
        return None
    perms = data.get("permissions") if isinstance(data, dict) else None
    deny = perms.get("deny") if isinstance(perms, dict) else None
    return data, deny if isinstance(deny, list) else []


example = load_settings(f"{repo}/settings.example.json")
if example:
    deny = example[1]
    required = ["Read(**/.env)", "Read(**/.env.local)", "Read(**/.env.production)", "Read(**/.env.test)",
                "Read(**/secrets/**/*.yaml)", "Read(**/secrets/**/*.yml)", "Read(**/secrets/**/*.json)",
                "Read(**/secrets/**/*.properties)", "Read(**/secrets/**/*.env)", "Read(**/secrets/**/*.conf)",
                "Read(**/secrets/**/*.txt)",
                "Read(~/.ssh/**)", "Read(~/.azure/**)", "Read(~/.config/gh/**)", "Read(**/*.pem)",
                "Bash(glab ci get *--with-variables*)"]
    if "/Users/" in json.dumps(example[0]):
        err("settings.example.json contains a machine-specific /Users/ path")
    missing = [r for r in required if r not in deny]
    if missing:
        err(f"settings.example.json misses deny rules: {', '.join(missing)}")
    wild = [r for r in deny if re.fullmatch(r"Read\((\*\*/)?\.env\.\*\)", r)]
    if wild:
        err(f"settings.example.json denies .env templates via {', '.join(wild)}")
    # settings.json is optional: a repo that ships only agents and skills has none.
    full = load_settings(f"{repo}/settings.json") if os.path.exists(f"{repo}/settings.json") else None
    if full:
        gap = [r for r in deny if r not in full[1]]
        if gap:
            err(f"settings.json misses deny rules from settings.example.json: {', '.join(gap)}")
        if "/Users/" in json.dumps(full[0]):
            err("settings.json contains a machine-specific /Users/ path")

for e in errors:
    print(f"FAIL: {e}")
if errors:
    sys.exit(1)
print(f"validate: all checks passed ({entries} entries)")
PYTHON
