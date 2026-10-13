#!/usr/bin/env bash
# Installs the QA agents and skills for Claude Code.
#   ./install.sh                             link the agents and skills into ~/.claude (git pull here updates them)
#   ./install.sh --settings                  add this repo's secret deny rules to ~/.claude/settings.json
#   ./install.sh --project <path> [--update] copy the agents and skills into <path>/.claude for a team
#   ./install.sh --uninstall                 remove the links and restore what they replaced
# It never touches ~/.claude/CLAUDE.md, and changes settings.json only with --settings (after a backup).
# Anything the user install replaces is moved to ~/.claude/backups/qa-<timestamp>-NNN/ first.
set -euo pipefail

# Resolve the script's real location, so running it through a symlink still finds the repo.
SELF="${BASH_SOURCE[0]}"
while [[ -L "$SELF" ]]; do
  target="$(readlink "$SELF")"
  [[ "$target" == /* ]] || target="$(dirname "$SELF")/$target"
  SELF="$target"
done
REPO="$(cd "$(dirname "$SELF")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
BACKUP_DIR=""

usage() {
  local code="${1:-0}"
  if [[ "$code" -eq 0 ]]; then
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  else
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2
  fi
  exit "$code"
}

die() {
  echo "error: $*" >&2
  usage 1
}

# Sets this run's backup folder on first use: qa-<stamp>-NNN, the first free NNN, so backups never
# overwrite each other and sort oldest to newest. BACKUP_STAMP exists so tests can force a collision.
init_backup_dir() {
  [[ -z "$BACKUP_DIR" ]] || return 0
  local base i=0
  base="$CLAUDE_HOME/backups/qa-${BACKUP_STAMP:-$(date +%Y%m%d-%H%M%S)}"
  while :; do
    BACKUP_DIR="$(printf '%s-%03d' "$base" "$i")"
    [[ -e "$BACKUP_DIR" ]] || return 0
    i=$((i + 1))
    if [[ $i -gt 999 ]]; then
      echo "error: more than 1000 backups for one second in $CLAUDE_HOME/backups" >&2
      exit 1
    fi
  done
}

# True for a broken link that points at <something>/<dir>/<name> where <dir>/<name> matches the link's own
# location, i.e. a link left behind by an earlier install from a clone that has since moved.
is_stale_link() {
  local dest="$1" target
  [[ -L "$dest" && ! -e "$dest" ]] || return 1
  target="$(readlink "$dest")"
  [[ "$(basename "$target")" == "$(basename "$dest")" ]] || return 1
  [[ "$(basename "$(dirname "$target")")" == "$(basename "$(dirname "$dest")")" ]]
}

# Links $CLAUDE_HOME/<rel> to $REPO/<rel>. Whatever was there (a file, a folder, a link from another repo or a
# broken link) is moved to the backup folder first, so --uninstall can put it back.
link_one() {
  local rel="$1" src="$REPO/$1" dest="$CLAUDE_HOME/$1" note=""
  if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    echo "  ok        $rel"
    return
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    if is_stale_link "$dest"; then
      note=" (was a broken link)"
    elif [[ -L "$dest" ]]; then
      note=" (was a link to $(readlink "$dest"))"
    fi
    init_backup_dir
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    mv "$dest" "$BACKUP_DIR/$rel"
    echo "  backed up $rel$note"
  else
    echo "  linked    $rel"
  fi
  mkdir -p "$(dirname "$dest")"
  ln -s "$src" "$dest"
}

# Refuses to install into an agents or skills folder under <base> that is itself a link, because the entries
# would land inside whatever that folder points to.
check_target_dirs() {
  local base="$1" d
  for d in agents skills; do
    if [[ -L "$base/$d" ]]; then
      echo "error: $base/$d is a link to $(readlink "$base/$d"); installing would write into it." >&2
      echo "       Replace it with a real folder first." >&2
      exit 1
    fi
  done
}

# Prints every path the user install links, relative to the repo.
user_entries() {
  local f
  for f in "$REPO"/agents/*.md "$REPO"/skills/*/; do
    [[ -e "$f" ]] || continue
    f="${f%/}"
    echo "${f#"$REPO"/}"
  done
}

kind() { if [[ -d "$1" ]]; then echo dir; else echo file; fi; }

copy_one() {
  local src="$1" dest="$2" update="$3"
  if [[ -L "$dest" ]]; then
    echo "  SKIP      $dest (is a symlink - remove it to install a copy)"
  elif [[ -e "$dest" && "$(kind "$src")" != "$(kind "$dest")" ]]; then
    echo "  SKIP      $dest (exists as a different type - remove it to install)"
  elif [[ ! -e "$dest" ]]; then
    cp -R "$src" "$dest"
    echo "  copied    $dest"
  elif diff -rq "$src" "$dest" >/dev/null 2>&1; then
    echo "  ok        $dest"
  elif [[ "$update" == yes ]]; then
    rm -rf "$dest"
    cp -R "$src" "$dest"
    echo "  updated   $dest (local edits and added files replaced)"
  else
    echo "  DIFFERS   $dest (--update replaces it, including local edits)"
  fi
}

copy_if_absent() {
  local src="$1" dest="$2" hint="$3"
  if [[ -L "$dest" ]]; then
    echo "  SKIP      $dest (is a symlink - remove it to install a copy)"
  elif [[ -e "$dest" ]]; then
    echo "  SKIP      $dest (exists - $hint)"
  else
    cp "$src" "$dest"
    echo "  copied    $dest"
  fi
}

# True if a usable python3 is available. On macOS without Command Line Tools, /usr/bin/python3 is a stub that
# opens an install dialog, so it is never run. The QA_* variables exist so tests can simulate that machine.
have_python3() {
  local py
  py="$(command -v python3 || true)"
  [[ -n "$py" ]] || return 1
  if [[ "$py" == "${QA_PY_STUB:-/usr/bin/python3}" && "${QA_OS:-$(uname -s)}" == Darwin ]] &&
    ! "${QA_XCODE_SELECT:-xcode-select}" -p >/dev/null 2>&1; then
    return 1
  fi
}

# settings_tool <check|merge>: check prints the deny rules from settings.example.json that ~/.claude/settings.json
# lacks, one per line; merge adds them. Both fail with a one-line reason if settings.json can't be read or has an
# unexpected shape, and merge writes atomically.
settings_tool() {
  python3 - "$1" "$REPO/settings.example.json" "$CLAUDE_HOME/settings.json" <<'PY'
import json, os, stat, sys, tempfile
mode, example, target = sys.argv[1:4]

def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)

with open(example, encoding="utf-8") as f:
    want = json.load(f)["permissions"]["deny"]
data = {}
if os.path.exists(target):
    try:
        with open(target, encoding="utf-8") as f:
            data = json.load(f)
    except ValueError as e:
        fail(f"settings.json is not valid JSON ({e})")
if not isinstance(data, dict):
    fail("settings.json has an unexpected shape: the top level is not an object")
perms = data.get("permissions")
if perms is None:
    perms = {}
if not isinstance(perms, dict):
    fail("settings.json has an unexpected shape at permissions")
deny = perms.get("deny")
if deny is None:
    deny = []
if not isinstance(deny, list):
    fail("settings.json has an unexpected shape at permissions.deny")
missing = [r for r in want if r not in deny]
if mode == "check":
    print("\n".join(missing))
    sys.exit(0)
data["permissions"] = perms
perms["deny"] = deny + missing
folder = os.path.dirname(target) or "."
fd, tmp = tempfile.mkstemp(dir=folder, prefix=".settings.", suffix=".json")
# mkstemp creates the file as 0600; keep the existing file's permissions (or the usual 0644 for a new one).
os.chmod(tmp, stat.S_IMODE(os.stat(target).st_mode) if os.path.exists(target) else 0o644)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, target)
PY
}

# Adds the missing deny rules to ~/.claude/settings.json (backed up first). Refuses to write through a link,
# because then the file belongs to another repo and the rules belong there.
merge_settings() {
  local target="$CLAUDE_HOME/settings.json" missing
  if ! have_python3; then
    echo "error: --settings needs a working python3" >&2
    return 1
  fi
  if ! missing="$(settings_tool check)"; then
    echo "error: settings.json was left unchanged" >&2
    return 1
  fi
  if [[ -z "$missing" ]]; then
    echo "  ok        settings.json already has every deny rule from settings.example.json"
    return
  fi
  if [[ -L "$target" ]]; then
    echo "  SKIP      settings.json is a link to $(readlink "$target")"
    echo "            Add these deny rules in that repo instead:"
    while IFS= read -r r; do echo "              $r"; done <<<"$missing"
    return 1
  fi
  mkdir -p "$CLAUDE_HOME"
  if [[ -e "$target" ]]; then
    init_backup_dir
    mkdir -p "$BACKUP_DIR"
    cp "$target" "$BACKUP_DIR/settings.json"
    echo "  backed up settings.json"
  fi
  settings_tool merge
  echo "  added     $(wc -l <<<"$missing" | tr -d ' ') deny rule(s) to settings.json"
}

# Reports optional tools the agents use. Never fails the install.
check_dependencies() {
  local cmd purpose
  echo
  echo "Dependency check:"
  while IFS='|' read -r cmd purpose; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "  found     $cmd"
    else
      echo "  missing   $cmd ($purpose)"
    fi
  done <<'DEPS'
claude|Claude Code itself
git|diffs, PR reviews
python3|settings check and Excel requirements in /test-developer
gh|GitHub PRs, issues and Actions runs
glab|GitLab MRs, issues and pipelines
az|Azure DevOps work items, PRs and pipelines - or use the Azure DevOps MCP server
jira|Jira Data Center issues (jira-cli) - Jira Cloud uses the Atlassian MCP server instead
DEPS
  if command -v python3 >/dev/null 2>&1 && ! have_python3; then
    echo "  missing   python3 (only the macOS stub is installed: xcode-select --install or brew install python)"
  elif have_python3 && ! python3 -c "import openpyxl" >/dev/null 2>&1; then
    echo "  missing   openpyxl (Excel requirements in /test-developer: pip3 install --user openpyxl)"
  fi
  # Checks the extension folder instead of running az, which can be slow to start.
  local azext="${AZURE_EXTENSION_DIR:-$HOME/.azure/cliextensions}/azure-devops"
  if command -v az >/dev/null 2>&1 && [[ -z "$(ls -A "$azext" 2>/dev/null)" ]]; then
    echo "  missing   az azure-devops extension (az extension add --name azure-devops)"
  fi
}

# Prints the newest backup of <rel>, if any. Folder names sort by time under byte order (LC_ALL=C).
latest_backup() {
  local b found
  found="$(for b in "$CLAUDE_HOME"/backups/qa-*/"$1"; do
    if [[ -e "$b" || -L "$b" ]]; then printf '%s\n' "$b"; fi
  done | LC_ALL=C sort | tail -n 1)"
  [[ -n "$found" ]] && echo "$found"
}

# Removes our links and puts back the newest backup of each, so the machine returns to its state before install.
uninstall() {
  local n=0 link target rel backup
  while IFS= read -r rel; do
    link="$CLAUDE_HOME/$rel"
    [[ -L "$link" ]] || continue
    target="$(readlink "$link")"
    if [[ "$target" == "$REPO/"* ]] || is_stale_link "$link"; then
      rm "$link"
      n=$((n + 1))
      if backup="$(latest_backup "$rel")"; then
        mv "$backup" "$link"
        echo "  restored  $rel (from ${backup#"$CLAUDE_HOME"/})"
      else
        echo "  removed   $rel"
      fi
    fi
  done < <(user_entries)
  echo "Removed $n link(s). settings.json is left as is; older backups stay in $CLAUDE_HOME/backups/."
}

case "${1:-}" in
  "")
    [[ $# -eq 0 ]] || die "unexpected arguments"
    echo "Linking QA agents and skills into $CLAUDE_HOME"
    check_target_dirs "$CLAUDE_HOME"
    mkdir -p "$CLAUDE_HOME"
    while IFS= read -r rel; do
      link_one "$rel"
    done < <(user_entries)
    [[ -z "$BACKUP_DIR" ]] || echo "Replaced entries were moved to $BACKUP_DIR."
    missing=""
    if ! have_python3; then
      echo
      echo "Skipped the settings check: no working python3."
    else
      errfile="$(mktemp)"
      trap 'rm -f "$errfile"' EXIT
      if ! missing="$(settings_tool check 2>"$errfile")"; then
        echo
        echo "Could not check $CLAUDE_HOME/settings.json for the secret deny rules: $(tail -n 1 "$errfile")"
        missing=""
      fi
      rm -f "$errfile"
    fi
    if [[ -n "$missing" ]]; then
      echo
      echo "$CLAUDE_HOME/settings.json lacks $(wc -l <<<"$missing" | tr -d ' ') secret deny rule(s). Run ./install.sh --settings to add them."
    fi
    check_dependencies
    echo
    echo "Done. Restart Claude Code to pick up the agents and skills."
    ;;
  --settings)
    [[ $# -eq 1 ]] || die "--settings takes no arguments"
    merge_settings
    ;;
  --project)
    [[ -n "${2:-}" ]] || die "--project needs a directory"
    [[ -d "$2" ]] || die "not a directory: $2"
    update=no
    if [[ $# -eq 3 && "$3" == --update ]]; then
      update=yes
    elif [[ $# -gt 2 ]]; then
      die "unexpected arguments after --project $2"
    fi
    project="$(cd "$2" && pwd)"
    if [[ -L "$project/.claude" ]]; then
      echo "error: $project/.claude is a link to $(readlink "$project/.claude"); installing would write into it." >&2
      exit 1
    fi
    check_target_dirs "$project/.claude"
    mkdir -p "$project/.claude/agents" "$project/.claude/skills"
    echo "QA agents and skills -> $project/.claude"
    for f in "$REPO"/agents/*.md; do copy_one "$f" "$project/.claude/agents/$(basename "$f")" "$update"; done
    for d in "$REPO"/skills/*/; do d="${d%/}"; copy_one "$d" "$project/.claude/skills/$(basename "$d")" "$update"; done
    copy_if_absent "$REPO/settings.example.json" "$project/.claude/settings.json" "merge settings.example.json by hand"
    copy_if_absent "$REPO/templates/CLAUDE.md" "$project/CLAUDE.md" "add the sections from templates/CLAUDE.md by hand"
    check_dependencies
    echo
    echo "Note: agents or skills removed from this repo are not deleted from $project/.claude - remove them by hand."
    echo "Next: open Claude Code in $project and run /qa-conventions."
    ;;
  --uninstall)
    [[ $# -eq 1 ]] || die "--uninstall takes no arguments"
    uninstall
    ;;
  -h|--help) usage 0 ;;
  *) die "unknown option $1" ;;
esac
