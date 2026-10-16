#!/usr/bin/env bash
# Checks that every agent, skill and command is cataloged, loadable by Claude Code, documented,
# and that our own entries carry the safety rules. Also checks both settings files.
# Usage: tests/validate.sh [repo-dir]   (defaults to this repo)
#        tests/validate.sh --dump-pins [repo-dir]   print every pinned phrase as JSON (used by tests/test_validate.sh)
# Needs only python3 (standard library). Runs as one process so the whole check stays fast.
set -uo pipefail

MODE=check
if [[ "${1:-}" == --dump-pins ]]; then
  MODE=dump-pins
  shift
fi
REPO="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"

# -X utf8: read files as UTF-8 even under LANG=C (the entries contain non-ASCII characters).
exec python3 -X utf8 - "$REPO" "$MODE" <<'PYTHON'
import glob
from fnmatch import fnmatchcase
import hashlib
import json
import os
import re
import sys

repo = sys.argv[1]
mode = sys.argv[2]
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
# Rules the map's safety and staleness depend on; each phrase pins one rule.
MAPPER_RULES = {
    f"write only `{MAP_FILE}`": f"must write only `{MAP_FILE}`",
    "Snapshot: <date>, commit <short sha>, uncommitted changes:": "must record the snapshot commit and uncommitted changes",
    "under 250 lines": "must keep the map under 250 lines",
    "never copy them into the map": "must paraphrase code comments and strings",
    "files named `.env*`; `*secret*`, `*credential*` or `*token*` files of any type except source code": "must skip secret-bearing config files by name",
    "[A-Za-z0-9_-]+:( |$)' <file>` for YAML": "must list YAML keys without host:port values",
    "If a key is itself a host or URL, write `<host key>`": "must write a host key as <host key>",
    "Quoted or dotted YAML keys may be missed": "must note that quoted or dotted YAML keys may be missed",
    "The grep can still show a key that is a host name": "must say not to repeat host-name keys",
    "Never copy URLs, hosts, IP addresses or account names": "must not copy URLs, hosts or account names",
    "`settings.xml`, `settings-security.xml`, `gradle.properties`, `.npmrc` and `.netrc`": "must skip Maven settings and gradle.properties by name",
    "From build files use only what Safety allows": "must read build files only as Safety allows",
}
# Run the skill's YAML key pattern on a sample: it must list keys and never a host:port list item.
yaml_grep = re.search(r"`grep -oE '([^']+)' <file>` for YAML", mapper)
if mapper and yaml_grep:
    sample = ["grid:", "  hosts:", "    - selenium-hub.corp.example:4444", "    - name: chrome", "  url: http://x",
              "  nodes:", "    selenium-node.corp.example: 5555", "  local:", "    - selenium-hub:4444"]
    listed_keys = [m.group(0) for m in (re.match(yaml_grep.group(1), line) for line in sample) if m]
    if any("corp.example" in k or "selenium-hub" in k for k in listed_keys) or not any(k.strip() == "hosts:" for k in listed_keys):
        err(f"skills/framework-map/SKILL.md: the YAML key pattern lists {listed_keys}, expected keys only")
for phrase, message in MAPPER_RULES.items():
    if mapper and phrase not in mapper:
        err(f"skills/framework-map/SKILL.md {message}")
# The shared blocks mention conventions.md as something to read; only the skill's own text says what it writes.
own_text = mapper.replace(safety, "").replace(platforms, "") if safety and platforms else mapper
for other in sorted(set(re.findall(r"\.ai/context/[A-Za-z0-9_.-]*[A-Za-z0-9_-]", own_text)) - {MAP_FILE}):
    err(f"skills/framework-map/SKILL.md names `{other}`; it may only write `{MAP_FILE}`")
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

# Behaviour rules that agents depend on: each phrase pins one rule, so an edit cannot drop it silently.
AGENT_RULES = {
    "templates/safety.md": {
        "quote only what this list allows. For anything else, name the element, property or key and write `<redacted>`": "must quote only allow-listed build-file values",
        "wherever they appear (`argLine`, `jvmArgs`, `systemPropertyVariables`, `jvm.config`, `maven.config`)": "must apply the JVM list wherever the key appears",
        "JVM and Maven command options (`argLine`, `jvmArgs`, `.mvn/jvm.config`, `.mvn/maven.config`)": "must redact -D pairs in Maven config files",
        "This includes string literals and variable assignments in build scripts": "must redact string literals in build scripts",
        "quoted only when they look like identifiers": "must quote names only when they look like identifiers",
        "and TestNG suite files (`testng*.xml` or any XML with a `<suite>` root)": "must cover test suite files",
        "`<parameter>` values in suite files are redacted like any other value": "must redact suite file parameter values",
        "`settings.gradle`, `settings.gradle.kts`, `gradle/libs.versions.toml`": "must cover Gradle settings and version catalogs",
        "Never quote server, repository, distribution or credential blocks": "must forbid quoting credential blocks from build files",
        "dependency, plugin and parent coordinates, and the Java release": "must allow the build-file details diagnosis needs",
        "version values (a `<version>` element, a `version =` setting, or a property whose name ends in `version`": "must shape-check every version value",
        "a range that contains `[`, `(`, `,` or `*` and only digits, dots, commas, spaces": "must define a version range",
        "a value of digits only is not a version and is `<redacted>`": "must redact digits-only versions",
        "a known token prefix such as `ghp_`, `github_pat_`, `glpat-`, `AKIA` or `xox`": "must say what a credential-looking name is",
        "Write any other version value as `<redacted>`": "must redact version values that do not look like versions",
        "optionally followed by exactly one of `-SNAPSHOT`, `.RELEASE`, `.Final`": "must allow only a closed list of version qualifiers",
        "a URL, connection string or command-line argument that contains a credential": "must forbid quoting credentials inside URLs and arguments",
        "write every other `-D` pair as `-Dname=<redacted>`": "must redact JVM -D pairs by default",
        "`user.timezone`, `user.language`, `user.country`, `file.encoding` and `java.awt.headless`. Other standard JDK settings": "must allow only a closed list of JVM settings",
        "`-XX` flags that only switch something on or off or set a number": "must quote only on/off and numeric JVM flags",
        "for a `<property>` activation keep its `<name>` and write its `<value>` as `<redacted>`": "must redact profile activation values",
        "names, not values, of environment variables and properties": "must allow variable names but not their values",
        "Maven `settings.xml` or `settings-security.xml`, `gradle.properties`": "must forbid reading Maven settings and gradle.properties",
    },
    "agents/ci-failure-diagnoser.md": {
        "Until the evidence rules the product out": "must not rule out a product defect for timeouts or reruns without evidence",
        "list every plausible one, ranked": "must list every plausible cause when the evidence is inconclusive",
        "## Other Possible Causes": "must report other possible causes",
        "Recommend the next step for each cause with Defect routing": "must route each cause with Defect routing",
        "take the resolved version from the build log": "must not guess versions it may not read",
        "If it fails consistently rather than intermittently, it is not a case for the triager": "must route consistent timeouts without the triager",
        "case 2 when the test's own code is the cause, otherwise case 5": "must route a consistent failure caused by the test to case 2",
        "product defect (confirmed), suspected flaky/environment": "description must list the product-defect and suspected-flaky classes",
        "Do not call it \"not a code defect\" without that evidence": "must not call a timeout 'not a code defect' without evidence",
        "suspected flaky/environment (product not ruled out)": "must label timeouts as suspected flaky with the product not ruled out",
        "list the candidates, product first": "must list the product cause first",
        "**Product defect (pre-existing, confirmed):**": "must have a label for confirmed pre-existing product defects",
        "if the evidence is inconclusive, say so and point to Other Possible Causes": "must not present a guess as the root cause",
    },
    "agents/flaky-test-triager.md": {
        "**Intermittent product defect (confirmed, case 3):**": "must recognise intermittent product defects",
        "(verdict: test defect, stale after an intended change)": "must have a verdict for a stale test",
        "cause identified in the test and product ruled out (case 2)": "must rule out the product before calling a test genuinely flaky",
        "/ inconclusive [case 5]": "must map every verdict to a routing case",
        "an intermittent product defect (for example a race condition) or a regression": "description must name the product-defect verdict",
        "intermittent product defect (confirmed) [case 3]": "must offer an intermittent product defect verdict",
        "never quarantine a test that catches a real bug": "must not quarantine a test that catches a real bug",
        "the Defect routing step; name the file and commit when a change caused it": "must give the Defect routing action for a defect",
        "route it with Defect routing.": "must route regressions and product defects with Defect routing",
        "never for an inconclusive verdict, an intermittent product defect, a regression or an environment cause": "must add only genuinely flaky tests to known-flaky-tests.md",
        "Never route an unconfirmed regression to case 3": "must not treat an unconfirmed regression as a product defect",
        "(verdict: environment or pipeline config); route it with Defect routing (case 1)": "must route environment causes to case 1",
        "for a genuinely flaky test only, quarantine/non-blocking as a stopgap": "must allow quarantine only as a stopgap for genuinely flaky tests",
        "Use intermittent product defect only when the product cause is confirmed": "must say when a product defect is confirmed versus inconclusive",
        "Do not call a test genuinely flaky until a product cause is ruled out": "must rule out a product cause before calling a test flaky",
    },
    "templates/CLAUDE.md": {
        "File a bug for a confirmed pre-existing product defect with no identifiable commit": "bug-ticket row must match Defect routing",
    },
    "agents/qa-lead.md": {
        "File a bug for a confirmed pre-existing product defect with no identifiable commit": "bug-ticket row must match Defect routing",
        "For a defect, offer the step from Defect routing": "must route defects with Defect routing",
        "for a pre-existing confirmed product defect, or a regression from a merged change if the user chooses it": "plan example must file bugs only for confirmed product defects or shared-branch regressions",
    },
    "agents/senior-automation-qa-engineer.md": {
        "## Method": "must follow a method",
        "state everything else as an assumption, together with how the answer would change without it": "must mark assumptions",
        "goes into the one Next Step question; any others go under Open Questions": "must route open user questions to Next Step",
        "You cannot wait for answers during the task": "must not wait for answers",
        "other facts that would change the recommendation, for the user to confirm later": "must say what Open Questions holds",
        "point to `test-maintainer`; use the suite facts here only as input": "must leave suite audits to test-maintainer",
        "ranked by likelihood and impact, each with its evidence": "must rank risks with evidence",
        "Give 2-3 realistic options, one of which keeps the current approach": "must compare options",
        "(with no suite yet: the smallest viable start": "must handle a framework with no suite yet",
        "Choose one option, say why it beats the others": "must recommend one option",
        "For each phase: goal, concrete work, who does it": "must give a phased plan",
        "size (S: up to a day, M: up to a sprint, L: more than a sprint)": "must define phase sizes",
        "and who it goes to (`test-maintainer`": "must say where each phase goes",
        "its definition with the denominator, the data source, a baseline (or how to get it), a numeric target and a time window": "must define measurable success criteria",
        "## Context ": "must report context",
        "## Risks ": "must report risks",
        "## Options ": "must report options",
        "## Recommendation ": "must report a recommendation",
        "## Phased Plan ": "must report a phased plan",
        "## Success Criteria ": "must report success criteria",
        "## Open Questions ": "must report open questions",
        "## Next Step ": "must end with a next step",
        "the default if they agree (nothing starts without an answer)": "must say nothing starts without an answer",
        "you never start a phase yourself": "must not start work itself",
        "**Unit and integration tests:**": "must keep unit and integration guidance",
        "**Diagnosis:**": "must keep diagnosis guidance",
        "mutation testing to see whether tests catch real changes": "must keep mutation testing",
        "property-based tests for complex logic": "must keep property-based testing",
        "rollback triggers from quality signals": "must keep rollback triggers",
        "Mobile (Appium) only when the product has an app": "must scope mobile testing",
        "visual regression where the UI matters": "must keep visual regression",
        "over the last 30 days (needs reruns enabled or a rerun history)": "must define the flaky rate window and source",
        "of the N critical flows named in the Risks section": "must tie coverage to the listed risks",
        "black-box or white-box per context": "must choose black-box or white-box per context",
        "real dependencies where practical (Testcontainers)": "must prefer real dependencies where practical",
        "tests that fail for the right reason": "must keep failing-for-the-right-reason",
        "clear ownership of each layer": "must keep layer ownership",
        "coverage weighed against maintenance cost": "must weigh coverage against maintenance",
        "deterministic and independent of order and of each other": "must keep test independence",
        "**BDD:** Cucumber with Gherkin": "must keep BDD with Gherkin",
        "pagination and filtering": "must keep pagination and filtering",
        "correlating a slowdown with the code or infrastructure change behind it": "must correlate performance regressions",
        "**Tools:**": "must keep a tool list",
    },
    "agents/pr-reviewer.md": {
        "never assume `main`": "must take the base branch from the PR, not assume main",
        "git symbolic-ref --short refs/remotes/origin/HEAD": "must fall back to the repo's default branch",
        "stop and return a one-line request for the base branch": "must ask when the base branch is unknown",
        "The one allowed exception is the `git fetch` in Phase 1, in exactly the form": "must state that git fetch is the only allowed git write",
        "Never add `--all`, `--prune`, `--force` or a `+` refspec": "must restrict the fetch form",
        "The fetch is not pre-approved, so Claude may ask the user first": "must say the fetch is not pre-approved",
        "prints `origin/develop`, so `<base>` is `develop`": "must strip origin/ from the default branch",
        "`targetRefName` without `refs/heads/`": "must name the Azure DevOps target branch command",
        "use that remote instead of `origin` below": "must handle PRs from forks",
        "`gh pr view --json url,isCrossRepository`": "must find a fork's base repository from the PR URL",
        "To tell, compare the PR's base repository with the URLs in `git remote -v`": "must compare the base repository with git remote -v",
        "and `isCrossRepository` is true for a fork": "must name the fork flag",
        "`git fetch <remote> <base>:refs/remotes/<remote>/<base>`": "must fetch the base with an explicit refspec",
        "`git diff $(git merge-base HEAD <remote>/<base>)...HEAD`": "must diff against <remote>/<base>",
        "`git diff origin/<target>...origin/<source>`": "must diff a PR's target and source",
        "`az repos pr list --source-branch <branch> --status active --query \"[0].targetRefName\" -o tsv`": "must name the Azure DevOps target lookup",
        "(`gh pr diff N`, `glab mr diff N --raw`; for Azure DevOps": "must name the platform diff commands",
        "say the diff may be out of date, or use": "must say when the diff may be stale",
        "If the lookup prints nothing, or reports": "must treat empty lookup output as no PR",
        "and never run `git pull`, `checkout`, `switch`, `reset`, `merge`, `rebase` or `stash`": "must forbid git commands that change state",
        "title, source and base branch": "must show source and base branch in the overview",
        "for Azure DevOps the diff comes from the MCP or the local fetch below": "must not expect a diff from az repos pr show",
        "fetch each branch with its own command, in the form the Rules allow": "must fetch PR branches in the allowed form",
        "`gh pr view --json baseRefName -q .baseRefName`": "must name the GitHub target branch command",
        "`glab mr view -F json` (the `target_branch` field)": "must name the GitLab target branch command",
        "On a detached HEAD there is no branch to look up, so go to step 2": "must handle a detached HEAD",
        "`git remote set-head origin -a`": "must say how to set a missing origin/HEAD",
        "reports that no pull request or merge request exists for the branch": "must fall through when no PR/MR exists",
        "means the PR target is unknown, so do not fall back to the default branch: go to step 3": "must not guess the base after a lookup error",
        "For a PR from a fork, use \"Read a PR/MR\" instead": "must use the platform diff for fork PRs",
        "name the base branch and how you found it": "must report the base branch",
    },
    "skills/pr-description/SKILL.md": {
        "never assume `main`": "must take the target branch from the PR, not assume main",
        "git symbolic-ref --short refs/remotes/origin/HEAD": "must fall back to the repo's default branch",
        "prints `origin/develop`, so `<target>` is `develop`": "must strip origin/ from the default branch",
        "reports that no PR/MR exists for the branch means there is none": "must fall through when no PR/MR exists",
        "any other lookup error means the target is unknown, so ask": "must not guess the target after a lookup error",
        "Run `git fetch <remote> <target>:refs/remotes/<remote>/<target>` first; if that fails, say the base may be out of date": "must refresh the base before diffing",
        "unless the PR comes from a fork whose base repository is another remote": "must handle PRs from forks",
        "`glab mr view -F json` (`target_branch`)": "must name the per-platform target lookups",
        "GitHub `gh pr view --json baseRefName -q .baseRefName`": "must name the GitHub target lookup",
        "`az repos pr list --source-branch <branch> --status active --query \"[0].targetRefName\" -o tsv`": "must name the Azure DevOps target lookup",
        "GitHub `gh pr view --json url,isCrossRepository`": "must say how to find a fork's base repository",
        "GitLab the `web_url` from `glab mr view -F json`": "must say how GitLab finds a fork's base repository",
        "Azure DevOps the repository in the PR's details": "must say how Azure DevOps finds a fork's base repository",
        "then use that remote.": "must use the fork's base remote",
        "(compare the PR's base repository with `git remote -v`": "must compare the base repository with git remote -v",
        "`git diff $(git merge-base HEAD <remote>/<target>)...HEAD`": "must diff against <remote>/<target>",
        "`git log --oneline <remote>/<target>..HEAD`": "must list commits against <remote>/<target>",
        "a lookup that prints nothing or reports": "must treat empty lookup output as no PR",
    },
    "skills/bug-ticket/SKILL.md": {
        "An intermittent failure can still be a product defect": "must not dismiss intermittent failures as non-bugs",
        "File only what Defect routing sends here": "must file only what Defect routing sends to it",
    },
    "skills/test-developer/SKILL.md": {
        "report it as a possible defect and route it with Defect routing": "must route a failing requirement with Defect routing",
    },
    "README.md": {
        "the five JVM settings the rule names": "must describe the closed JVM list",
        "a phased plan and measurable success criteria": "must describe the strategy report",
        "we don't recommend a wildcard allow rule for it": "must not recommend a git fetch allow rule",
        "quotes only what the allow-list in `templates/safety.md` permits": "must point to the full build-file allow-list",
        "The file is rewritten as JSON, so its values stay the same": "must say the settings merge rewrites the file",
        "suspected flaky/environment (product not ruled out)": "trace example must use the diagnoser's suspected-flaky label",
        "for a pre-existing confirmed product defect, or a regression from a merged change if the user chooses it": "plan example must file bugs only for confirmed product defects or shared-branch regressions",
        "an intermittent product defect (such as a race condition)": "must describe the triager's product-defect verdict",
    },
}
# Where a failure goes is defined once, in templates/defect-routing.md. It must appear verbatim in the
# entries below, which recommend what to do with a defect, and in any other entry with a "## Defect routing"
# section, so the routes cannot drift apart. The template's key routes are pinned too, so an edit applied to
# every copy at once still has to keep them.
DEFECT_ROUTING_FILES = {"agents/ci-failure-diagnoser.md", "agents/flaky-test-triager.md", "agents/qa-lead.md",
                        "skills/bug-ticket/SKILL.md", "skills/test-developer/SKILL.md"}
for path in sorted(glob.glob(f"{repo}/agents/*.md") + glob.glob(f"{repo}/skills/*/SKILL.md")):
    if "## Defect routing" in read(path):
        DEFECT_ROUTING_FILES.add(os.path.relpath(path, repo))
DEFECT_ROUTES = {
    "The change under test is the branch or PR whose pipeline or tests you are looking at, until it is merged": "must define the change under test",
    "fix it on that branch, naming the file and the commit": "must fix a defect from the change under test on its branch",
    "name the commit, then offer a fix-forward change": "must route a regression from a merged change",
    "or the `bug-ticket` skill, and let the user choose": "must let the user choose how to handle a merged regression",
    "**pre-existing, with no identifiable commit:** the `bug-ticket` skill": "must send pre-existing product defects to bug-ticket",
    "**Intermittent, with no product cause confirmed:** flaky triage with the `flaky-test-triager` agent": "must send unconfirmed intermittent failures to the triager",
    "take the first case that fits": "must say which route wins when several fit",
    "its verdict then picks case 1, 2, 3 or 5": "must let a triage verdict reach every other case",
    "it is case 3 once the product defect is confirmed, and case 5 until then": "must not send an unconfirmed defect to case 3",
    "A consistent failure skips triage: take case 1, 2 or 5, or case 3 once the product defect is confirmed": "must route consistent failures without triage",
    "an intermittent failure reaches this case only through case 4": "must not send intermittent failures straight to a test fix",
    "**Test defect, product correct**": "must route test defects where the product is correct",
    "Do not file a bug and do not record the test as known flaky until one is confirmed": "must file nothing for an inconclusive case",
    "**Dependency or pipeline config:**": "must route dependency and pipeline config causes",
    "Never quarantine a test that catches a real bug.": "must forbid quarantining a test that catches a real bug",
}
defect_routing = read(f"{repo}/templates/defect-routing.md").strip()
if not defect_routing:
    err("templates/defect-routing.md missing or empty")
else:
    for phrase, message in DEFECT_ROUTES.items():
        if phrase not in defect_routing:
            err(f"templates/defect-routing.md {message}")
    for path in sorted(DEFECT_ROUTING_FILES):
        if defect_routing not in read(f"{repo}/{path}"):
            err(f"{path}: does not contain the block from templates/defect-routing.md verbatim")
# --dump-pins prints every pinned phrase as JSON and exits, so tests/test_validate.sh can delete each one in a copy of
# the repo and check that this script then fails with the pin's message. It is an argument, not an environment
# variable, so nothing in the environment can turn a normal run into one that checks nothing.
pins = [[p, ph, f"{p} {m}"] for p, rules in AGENT_RULES.items() for ph, m in rules.items()]
pins += [["skills/framework-map/SKILL.md", ph, f"skills/framework-map/SKILL.md {m}"] for ph, m in MAPPER_RULES.items()]
pins += [["templates/defect-routing.md", ph, f"templates/defect-routing.md {m}"] for ph, m in DEFECT_ROUTES.items()]
if mode == "dump-pins":
    print(json.dumps(pins))
    sys.exit(0)
# tests/pin-count holds the exact number of pins, so a pin removed from this script fails instead of going untested.
pin_count = read(f"{repo}/tests/pin-count").strip()
if pin_count != str(len(pins)):
    err(f"tests/pin-count says {pin_count or 'nothing'}, but this script defines {len(pins)} pins; update both together")
for path, rules in AGENT_RULES.items():
    text = read(f"{repo}/{path}")
    for phrase, message in rules.items():
        if phrase not in text:
            err(f"{path} {message}")

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
                "Read(**/settings.xml)", "Read(**/gradle.properties)", "Read(~/.m2/settings-security.xml)",
                "Read(**/settings-security.xml)", "Bash(git fetch *--*)", "Bash(git fetch *+*)",
                "Bash(git fetch * -*)", "Bash(git fetch -*)", "Bash(git fetch * * *)",
                "Bash(git fetch *:refs/heads/*)", "Bash(git fetch *:refs/tags/*)",
                "Bash(glab ci get *--with-variables*)"]
    if "/Users/" in json.dumps(example[0]):
        err("settings.example.json contains a machine-specific /Users/ path")
    allow = example[0].get("permissions", {}).get("allow", []) if isinstance(example[0], dict) else []
    if "Bash(git symbolic-ref --short refs/remotes/origin/HEAD)" not in allow:
        err("settings.example.json must allow Bash(git symbolic-ref --short refs/remotes/origin/HEAD)")
    loose = [r for r in allow if r.startswith("Bash(git symbolic-ref") and r != "Bash(git symbolic-ref --short refs/remotes/origin/HEAD)"]
    if loose:
        err(f"settings.example.json allows a git symbolic-ref form that can write refs: {', '.join(loose)}")
    if "Bash(git remote -v)" not in allow:
        err("settings.example.json must allow Bash(git remote -v)")
    wide_remote = [r for r in allow if r.startswith("Bash(git remote") and r != "Bash(git remote -v)"]
    if wide_remote:
        err(f"settings.example.json allows a git remote form that can change remotes: {', '.join(wide_remote)}")
    # The agents' one fetch form must not be denied (glob matching, an approximation of Claude Code's matcher). No
    # allow rule is recommended for it, because globs cannot model shell syntax; the deny rules are only a backstop.
    bash_deny = [r[5:-1] for r in deny if r.startswith("Bash(") and r.endswith(")")]
    if any(fnmatchcase("git fetch origin develop:refs/remotes/origin/develop", d) for d in bash_deny):
        err("settings.example.json denies the one git fetch form the agents use")
    # No allow rule may match the agents' fetch, directly or through a wider pattern such as Bash(git *).
    fetch_form = "git fetch origin develop:refs/remotes/origin/develop"
    if any(r.startswith("Bash(") and r.endswith(")") and (fnmatchcase(fetch_form, r[5:-1]) or "fetch" in r) for r in allow):
        err("settings.example.json must not pre-approve git fetch")
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
