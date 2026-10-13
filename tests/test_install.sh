#!/usr/bin/env bash
# Tests install.sh in a temporary CLAUDE_HOME and project directory. Never touches the real ~/.claude.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_HOME="$TMP/home"
fail=0

assert() {
  local msg="$1"; shift
  if "$@"; then echo "  pass  $msg"; else echo "  FAIL  $msg"; fail=1; fi
}

# Runs install.sh, stores stdout+stderr in $out and the exit code in $rc.
run() {
  out="$("$REPO/install.sh" "$@" 2>&1)"
  rc=$?
}

# True if the last install output does not contain $1. Called through assert.
# shellcheck disable=SC2317,SC2329
out_lacks() { ! grep -q -- "$1" <<<"$out"; }

count_links() { find "$1" -type l | wc -l | tr -d ' '; }
latest_backup_dir() { find "$CLAUDE_HOME/backups" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1; }
deny_count() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["permissions"]["deny"]))' "$1"; }

n_agents=$(find "$REPO/agents" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
n_skills=$(find "$REPO/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
n_deny=$(deny_count "$REPO/settings.example.json")
agent="$(basename "$(find "$REPO/agents" -maxdepth 1 -name '*.md' | sort | head -n 1)")"
agent2="$(basename "$(find "$REPO/agents" -maxdepth 1 -name '*.md' | sort | sed -n 2p)")"
skill="$(basename "$(find "$REPO/skills" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)")"

echo "user install"
run
assert "exits 0" test "$rc" = 0
assert "links every agent" test "$(count_links "$CLAUDE_HOME/agents")" = "$n_agents"
assert "links every skill" test "$(count_links "$CLAUDE_HOME/skills")" = "$n_skills"
assert "agent link resolves to the repo" test "$(readlink "$CLAUDE_HOME/agents/$agent")" = "$REPO/agents/$agent"
assert "skill is readable through its link" test -f "$CLAUDE_HOME/skills/$skill/SKILL.md"
assert "does not touch CLAUDE.md" test ! -e "$CLAUDE_HOME/CLAUDE.md"
assert "does not create settings.json" test ! -e "$CLAUDE_HOME/settings.json"
assert "reports missing deny rules" grep -q "lacks $n_deny secret deny rule(s). Run ./install.sh --settings" <<<"$out"
assert "no backup on a clean install" test ! -d "$CLAUDE_HOME/backups"

echo "dependency check"
assert "prints dependency check" grep -q "^Dependency check:" <<<"$out"
assert "reports git as found" grep -Eq "^  found +git$" <<<"$out"
# Stub tools: az records any call, python3 always fails, xcode-none reports no Command Line Tools.
stubs="$TMP/stubs"
mkdir -p "$stubs" "$TMP/azext"
printf '#!/bin/sh\ntouch "%s/az-called"\n' "$TMP" >"$stubs/az"
printf '#!/bin/sh\nexit 1\n' >"$stubs/python3"
printf '#!/bin/sh\nexit 1\n' >"$stubs/xcode-none"
chmod +x "$stubs"/*
out="$(CLAUDE_HOME="$TMP/deps" PATH="$stubs:$PATH" AZURE_EXTENSION_DIR="$TMP/azext" "$REPO/install.sh" 2>&1)"; rc=$?
assert "exits 0 with missing tools" test "$rc" = 0
assert "reports missing azure-devops extension" grep -q "missing .*az azure-devops extension" <<<"$out"
assert "does not run az" test ! -e "$TMP/az-called"
assert "reports missing openpyxl" grep -q "missing .*openpyxl" <<<"$out"
assert "still links when python3 cannot run" test "$(count_links "$TMP/deps/agents")" = "$n_agents"
assert "says the settings check failed" grep -q "Could not check .*settings.json for the secret deny rules" <<<"$out"
printf '#!/bin/sh\ntouch "%s/stub-called"\nexit 1\n' "$TMP" >"$stubs/py-stub"
chmod +x "$stubs/py-stub"
mkdir -p "$TMP/stubpath"
ln -s "$stubs/py-stub" "$TMP/stubpath/python3"
out="$(CLAUDE_HOME="$TMP/deps" PATH="$TMP/stubpath:$PATH" QA_PY_STUB="$TMP/stubpath/python3" QA_OS=Darwin QA_XCODE_SELECT="$stubs/xcode-none" "$REPO/install.sh" 2>&1)"
assert "reports the macOS python3 stub" grep -q "only the macOS stub is installed" <<<"$out"
assert "skips the settings check on the stub" grep -q "Skipped the settings check: no working python3" <<<"$out"
assert "never runs the stub" test ! -e "$TMP/stub-called"

echo "re-run is idempotent"
run
assert "exits 0" test "$rc" = 0
assert "reports existing links as ok" grep -q "ok .*agents/$agent" <<<"$out"
assert "no new links" test "$(count_links "$CLAUDE_HOME/agents")" = "$n_agents"

echo "--settings"
echo '{"theme": "dark", "permissions": {"allow": ["Read"], "deny": ["Bash(rm -rf *)"]}}' >"$CLAUDE_HOME/settings.json"
run --settings
assert "exits 0" test "$rc" = 0
assert "keeps other settings" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["theme"] == "dark" and d["permissions"]["allow"] == ["Read"]' "$CLAUDE_HOME/settings.json"
assert "adds every missing deny rule" python3 -c 'import json,sys; have=json.load(open(sys.argv[1]))["permissions"]["deny"]; want=json.load(open(sys.argv[2]))["permissions"]["deny"]; assert all(r in have for r in want)' "$CLAUDE_HOME/settings.json" "$REPO/settings.example.json"
assert "keeps an existing deny rule once" test "$(grep -c 'rm -rf' "$CLAUDE_HOME/settings.json")" = 1
assert "backs up the old settings" grep -q '"theme": "dark"' "$(latest_backup_dir)/settings.json"
run --settings
assert "second run reports ok" grep -q "already has every deny rule" <<<"$out"
run
assert "plain install no longer reports missing rules" out_lacks "lacks"

echo "--settings on a fresh machine"
out="$(CLAUDE_HOME="$TMP/fresh" "$REPO/install.sh" --settings 2>&1)"; rc=$?
assert "exits 0" test "$rc" = 0
assert "creates settings.json with the deny rules" test "$(deny_count "$TMP/fresh/settings.json")" = "$n_deny"

echo "--settings with broken input changes nothing"
broken="$TMP/broken"
mkdir -p "$broken"
for content in '{not json' '[]' '{"permissions": []}' '{"permissions": {"deny": "x"}}'; do
  printf '%s' "$content" >"$broken/settings.json"
  out="$(CLAUDE_HOME="$broken" "$REPO/install.sh" --settings 2>&1)"; rc=$?
  assert "rejects $content" test "$rc" = 1
  assert "explains $content" grep -Eq "not valid JSON|unexpected shape" <<<"$out"
  assert "leaves $content unchanged" test "$(cat "$broken/settings.json")" = "$content"
done
assert "makes no backup for broken input" test ! -d "$broken/backups"
printf '{"permissions": null}' >"$broken/settings.json"
out="$(CLAUDE_HOME="$broken" "$REPO/install.sh" --settings 2>&1)"; rc=$?
assert "treats permissions: null as empty" test "$(deny_count "$broken/settings.json")" = "$n_deny"
printf '{}' >"$broken/settings.json"
out="$(CLAUDE_HOME="$broken" PATH="$stubs:$PATH" "$REPO/install.sh" --settings 2>&1)"; rc=$?
assert "fails when python3 fails" test "$rc" = 1
assert "leaves settings.json unchanged when python3 fails" test "$(cat "$broken/settings.json")" = '{}'
out="$(CLAUDE_HOME="$broken" PATH="$TMP/stubpath:$PATH" QA_PY_STUB="$TMP/stubpath/python3" QA_OS=Darwin QA_XCODE_SELECT="$stubs/xcode-none" "$REPO/install.sh" --settings 2>&1)"; rc=$?
assert "refuses on the macOS stub" grep -q "needs a working python3" <<<"$out"

echo "--settings does not write through a link"
mkdir -p "$TMP/other-repo"
echo '{"permissions": {"deny": []}}' >"$TMP/other-repo/settings.json"
rm "$CLAUDE_HOME/settings.json"
ln -s "$TMP/other-repo/settings.json" "$CLAUDE_HOME/settings.json"
run --settings
assert "exits 1" test "$rc" = 1
assert "explains where to add the rules" grep -q "Add these deny rules in that repo instead" <<<"$out"
assert "leaves the other repo's file unchanged" test "$(cat "$TMP/other-repo/settings.json")" = '{"permissions": {"deny": []}}'
assert "keeps the link" test -L "$CLAUDE_HOME/settings.json"

echo "backs up what it replaces"
rm "$CLAUDE_HOME/agents/$agent"
echo "mine" >"$CLAUDE_HOME/agents/$agent"
rm "$CLAUDE_HOME/skills/$skill"
ln -s /tmp/elsewhere "$CLAUDE_HOME/skills/$skill"
run
assert "reports the backup" grep -q "backed up agents/$agent" <<<"$out"
bk="$(latest_backup_dir)"
assert "keeps the replaced file" test "$(cat "$bk/agents/$agent")" = "mine"
assert "keeps a replaced foreign link" test "$(readlink "$bk/skills/$skill")" = /tmp/elsewhere
assert "links the agent" test "$(readlink "$CLAUDE_HOME/agents/$agent")" = "$REPO/agents/$agent"

echo "two installs in the same second keep separate backups"
home2="$TMP/home2"
mkdir -p "$home2/agents"
echo A >"$home2/agents/$agent"
CLAUDE_HOME="$home2" BACKUP_STAMP=fixed "$REPO/install.sh" >/dev/null 2>&1
rm "$home2/agents/$agent"
echo B >"$home2/agents/$agent"
CLAUDE_HOME="$home2" BACKUP_STAMP=fixed "$REPO/install.sh" >/dev/null 2>&1
assert "first run backs up to -000" test "$(cat "$home2/backups/qa-fixed-000/agents/$agent")" = A
assert "second run backs up to -001" test "$(cat "$home2/backups/qa-fixed-001/agents/$agent")" = B
CLAUDE_HOME="$home2" "$REPO/install.sh" --uninstall >/dev/null 2>&1
assert "uninstall restores the newer one" test "$(cat "$home2/agents/$agent")" = B

echo "replaces links left by a moved clone"
rm "$CLAUDE_HOME/agents/$agent2"
ln -s "/old/place/agents/$agent2" "$CLAUDE_HOME/agents/$agent2"
run
assert "backs up the broken link" grep -q "backed up agents/$agent2 (was a broken link)" <<<"$out"
assert "relinks it to this repo" test "$(readlink "$CLAUDE_HOME/agents/$agent2")" = "$REPO/agents/$agent2"

echo "uninstall"
ln -s /tmp/elsewhere "$CLAUDE_HOME/agents/other.md"
mkdir -p "$CLAUDE_HOME/skills/synced"
run --uninstall
assert "exits 0" test "$rc" = 0
assert "restores the backed-up agent" test "$(cat "$CLAUDE_HOME/agents/$agent")" = "mine"
assert "restores a backed-up foreign link" test "$(readlink "$CLAUDE_HOME/skills/$skill")" = /tmp/elsewhere
assert "removes links without a backup" test ! -e "$CLAUDE_HOME/agents/$agent2"
assert "keeps foreign links" test -L "$CLAUDE_HOME/agents/other.md"
assert "keeps Claude-managed folders" test -d "$CLAUDE_HOME/skills/synced"
assert "leaves settings.json alone" test -L "$CLAUDE_HOME/settings.json"

echo "refuses a linked agents folder"
linked="$TMP/linked"
mkdir -p "$linked" "$TMP/elsewhere-agents"
ln -s "$TMP/elsewhere-agents" "$linked/agents"
out="$(CLAUDE_HOME="$linked" "$REPO/install.sh" 2>&1)"; rc=$?
assert "exits 1" test "$rc" = 1
assert "explains why" grep -q "agents is a link to" <<<"$out"
assert "writes nothing into the linked folder" test -z "$(ls -A "$TMP/elsewhere-agents")"

echo "project install"
proj="$TMP/proj"
mkdir -p "$proj"
echo "# existing" >"$proj/CLAUDE.md"
run --project "$proj"
assert "exits 0" test "$rc" = 0
assert "copies every agent and skill" test "$(find "$proj/.claude/agents" "$proj/.claude/skills" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = "$((n_agents + n_skills))"
assert "copies, does not link" test ! -L "$proj/.claude/agents/$agent"
assert "creates settings.json from the example" cmp -s "$proj/.claude/settings.json" "$REPO/settings.example.json"
assert "keeps existing CLAUDE.md" test "$(cat "$proj/CLAUDE.md")" = "# existing"
echo "custom" >"$proj/.claude/settings.json"
run --project "$proj"
assert "keeps an existing settings.json" test "$(cat "$proj/.claude/settings.json")" = "custom"
proj2="$TMP/proj2"
mkdir -p "$proj2/.claude"
ln -s "$TMP/proj2-target.json" "$proj2/.claude/settings.json"
run --project "$proj2"
assert "skips a dangling settings.json link" grep -q "SKIP .*settings.json (is a symlink" <<<"$out"
assert "does not create the link target" test ! -e "$TMP/proj2-target.json"
echo "local edit" >>"$proj/.claude/agents/$agent"
run --project "$proj"
assert "reports a changed agent" grep -q "DIFFERS .*agents/$agent" <<<"$out"
run --project "$proj" --update
assert "--update replaces it" cmp -s "$proj/.claude/agents/$agent" "$REPO/agents/$agent"
assert "--update keeps CLAUDE.md" test "$(cat "$proj/CLAUDE.md")" = "# existing"

echo "arguments"
run --help
assert "--help exits 0" test "$rc" = 0
assert "--help prints usage" grep -q -- "--settings" <<<"$out"
run --project "$TMP/nope"
assert "missing project dir exits 1" test "$rc" = 1
run --settings extra
assert "extra --settings argument exits 1" test "$rc" = 1
run --uninstall extra
assert "extra --uninstall argument exits 1" test "$rc" = 1
run extra
assert "unknown argument exits 1" test "$rc" = 1

[[ $fail -eq 0 ]] && echo "test_install: all passed"
exit $fail
