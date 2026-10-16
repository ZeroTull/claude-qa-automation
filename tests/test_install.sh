#!/usr/bin/env bash
# Tests install.sh in a temporary CLAUDE_HOME and project directory. Never touches the real ~/.claude.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_HOME="$TMP/home"
# Never let a test fall back to the real ~/.copilot.
export COPILOT_HOME="$TMP/copilot-default"
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
# Fixed-string and byte-wise (LC_ALL=C), so a pattern such as '\377' or a raw byte is matched literally. Only grep's
# "no match" (exit 1) counts as lacking; a grep error (exit 2) fails the assertion.
out_lacks() { local rc=0; LC_ALL=C grep -qF -- "$1" <<<"$out" || rc=$?; [[ $rc -eq 1 ]]; }

# True if file $2 does not contain $1. Called through assert.
# shellcheck disable=SC2317,SC2329
# Like out_lacks: a missing or unreadable file fails the assertion instead of passing it.
out_lacks_file() { local rc=0; LC_ALL=C grep -qF -- "$1" "$2" || rc=$?; [[ $rc -eq 1 ]]; }

# Octal permission bits of a file. GNU stat first: on Linux, "stat -f" is filesystem status and succeeds.
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

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
assert "reports missing deny rules" grep -q "lacks $n_deny deny rule(s). Run ./install.sh --settings" <<<"$out"
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
assert "says the settings check failed" grep -q "Could not check .*settings.json for the deny rules" <<<"$out"
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
chmod 644 "$CLAUDE_HOME/settings.json"
run --settings
assert "exits 0" test "$rc" = 0
assert "keeps other settings" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["theme"] == "dark" and d["permissions"]["allow"] == ["Read"]' "$CLAUDE_HOME/settings.json"
assert "adds every missing deny rule" python3 -c 'import json,sys; have=json.load(open(sys.argv[1]))["permissions"]["deny"]; want=json.load(open(sys.argv[2]))["permissions"]["deny"]; assert all(r in have for r in want)' "$CLAUDE_HOME/settings.json" "$REPO/settings.example.json"
assert "keeps an existing deny rule once" test "$(grep -c 'rm -rf' "$CLAUDE_HOME/settings.json")" = 1
assert "backs up the old settings" grep -q '"theme": "dark"' "$(latest_backup_dir)/settings.json"
assert "keeps the file mode" test "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$CLAUDE_HOME/settings.json")" = "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$(latest_backup_dir)/settings.json")"
run --settings
assert "second run reports ok" grep -q "already has every deny rule" <<<"$out"
# A strict umask makes plain cp narrow the copy (644 -> 600); -p keeps the original's bits.
mode_home="$TMP/mode-home"
mkdir -p "$mode_home"
echo '{"permissions": {"deny": []}}' >"$mode_home/settings.json"
chmod 644 "$mode_home/settings.json"
out="$(umask 077; CLAUDE_HOME="$mode_home" "$REPO/install.sh" --settings 2>&1)"
mbak="$(find "$mode_home/backups" -name settings.json | head -n 1)"
assert "a settings.json is backed up under umask 077" test -n "$mbak"
assert "the backup keeps the original's 644 under umask 077" test "$(file_mode "$mbak")" = 644
assert "a 644 settings.json gets no warning" out_lacks "writable by other users"
private="$TMP/private-home"
mkdir -p "$private"
echo '{"permissions": {"deny": []}}' >"$private/settings.json"
chmod 600 "$private/settings.json"
out="$(CLAUDE_HOME="$private" "$REPO/install.sh" --settings 2>&1)"
pbak="$(find "$private/backups" -name settings.json | head -n 1)"
assert "a 0600 settings.json backup is still 0600" test "$(file_mode "$pbak")" = 600
open_home="$TMP/open-home"
mkdir -p "$open_home"
echo '{"permissions": {"deny": []}}' >"$open_home/settings.json"
chmod 666 "$open_home/settings.json"
out="$(CLAUDE_HOME="$open_home" "$REPO/install.sh" --settings 2>&1)"
assert "warns when settings.json is writable by others" grep -q "WARNING   settings.json is writable by other users or your group" <<<"$out"
obak="$(find "$open_home/backups" -name settings.json | head -n 1)"
assert "the backup of a 666 settings.json is not writable by others" test "$(file_mode "$obak")" = 644
out="$(CLAUDE_HOME="$open_home" "$REPO/install.sh" --settings 2>&1)"
assert "warns even when every deny rule is present" grep -q "already has every deny rule" <<<"$out"
assert "the warning comes with the ok line" grep -q "WARNING   settings.json is writable by other users or your group" <<<"$out"
chmod 664 "$open_home/settings.json"
out="$(CLAUDE_HOME="$open_home" "$REPO/install.sh" --settings 2>&1)"
assert "warns when settings.json is writable by the group" grep -q "WARNING   settings.json is writable" <<<"$out"
run
assert "plain install no longer reports missing rules" out_lacks "lacks"

echo "default run explains why the settings check failed"
mkdir -p "$TMP/badjson"
printf '{not json' >"$TMP/badjson/settings.json"
out="$(CLAUDE_HOME="$TMP/badjson" "$REPO/install.sh" 2>&1)"; rc=$?
assert "exits 0" test "$rc" = 0
assert "shows the reason" grep -q "Could not check .*: .*settings.json is not valid JSON" <<<"$out"

echo "--settings on a fresh machine"
out="$(CLAUDE_HOME="$TMP/fresh" "$REPO/install.sh" --settings 2>&1)"; rc=$?
assert "exits 0" test "$rc" = 0
assert "creates settings.json with the deny rules" test "$(deny_count "$TMP/fresh/settings.json")" = "$n_deny"
assert "--settings adds no allow rules" python3 -c 'import json,sys; sys.exit(1 if json.load(open(sys.argv[1])).get("permissions",{}).get("allow") else 0)' "$TMP/fresh/settings.json"
assert "creates it readable (0644)" test "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$TMP/fresh/settings.json")" = 0o644

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

echo "--project refuses linked folders"
for d in agents skills; do
  pl="$TMP/proj-linked-$d"
  mkdir -p "$pl/.claude" "$TMP/target-$d"
  ln -s "$TMP/target-$d" "$pl/.claude/$d"
  run --project "$pl"
  assert "exits 1 for a linked .claude/$d" test "$rc" = 1
  assert "writes nothing into the linked $d folder" test -z "$(ls -A "$TMP/target-$d")"
done
pl="$TMP/proj-linked-claude"
mkdir -p "$pl" "$TMP/target-claude"
ln -s "$TMP/target-claude" "$pl/.claude"
run --project "$pl"
assert "exits 1 for a linked .claude folder" test "$rc" = 1
assert "writes nothing into the linked .claude folder" test -z "$(ls -A "$TMP/target-claude")"

echo "runs through a symlink to the script"
mkdir -p "$TMP/bin"
ln -s "$REPO/install.sh" "$TMP/bin/qa-install"
out="$(CLAUDE_HOME="$TMP/via-link" "$TMP/bin/qa-install" 2>&1)"; rc=$?
assert "exits 0" test "$rc" = 0
assert "links into the real repo" test "$(readlink "$TMP/via-link/agents/$agent")" = "$REPO/agents/$agent"

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
assert "copies the framework-map skill" test -f "$proj/.claude/skills/framework-map/SKILL.md"
assert "next steps name /framework-map" grep -q "/qa-conventions, then /framework-map" <<<"$out"
run --project "$proj"
assert "reports a complete project settings.json" grep -q "ok .*settings.json has every deny rule" <<<"$out"
echo "custom" >"$proj/.claude/settings.json"
run --project "$proj"
assert "keeps an existing settings.json" test "$(cat "$proj/.claude/settings.json")" = "custom"
assert "says an unreadable settings.json could not be checked" grep -q "could not check its deny rules" <<<"$out"
# Under umask 077 plain cp would make every copy 600 or 700; -p keeps the source's 644 and 755.
repo_copy="$TMP/repo-copy"
mkdir -p "$repo_copy"
cp -R "$REPO/." "$repo_copy/"
chmod 644 "$repo_copy/agents/$agent" "$repo_copy/skills/$skill/SKILL.md" "$repo_copy/settings.example.json" "$repo_copy/templates/CLAUDE.md"
chmod 755 "$repo_copy/skills/$skill"
proj2="$TMP/proj-modes"
mkdir -p "$proj2"
out="$(umask 077; CLAUDE_HOME="$TMP/modes-home" COPILOT_HOME="$TMP/modes-copilot" "$repo_copy/install.sh" --project "$proj2" 2>&1)"
assert "an agent copy keeps 644 under umask 077" test "$(file_mode "$proj2/.claude/agents/$agent")" = 644
assert "a skill folder copy keeps 755 under umask 077" test "$(file_mode "$proj2/.claude/skills/$skill")" = 755
assert "a skill file copy keeps 644 under umask 077" test "$(file_mode "$proj2/.claude/skills/$skill/SKILL.md")" = 644
assert "the settings.json copy keeps 644 under umask 077" test "$(file_mode "$proj2/.claude/settings.json")" = 644
assert "the CLAUDE.md copy keeps 644 under umask 077" test "$(file_mode "$proj2/CLAUDE.md")" = 644
proj6="$TMP/proj6"
mkdir -p "$proj6/.claude"
echo '{"permissions": {"deny": []}}' >"$proj6/.claude/settings.json"
chmod 644 "$proj6/.claude/settings.json"
out="$(umask 077; CLAUDE_HOME="$TMP/modes-home" COPILOT_HOME="$TMP/modes-copilot" "$REPO/install.sh" --project "$proj6" --update 2>&1)"
bak6="$(sed -n 's|.*backup: \(.*project-settings.json\)).*|\1|p' <<<"$out")"
assert "the project settings backup keeps 644 under umask 077" test "$(file_mode "$bak6")" = 644
proj3="$TMP/proj3"
mkdir -p "$proj3/.claude"
printf '{"model": "x", "permissions": {"allow": ["Bash(ls)"], "deny": ["Read(**/.env)"]}}\n' >"$proj3/.claude/settings.json"
chmod 600 "$proj3/.claude/settings.json"
run --project "$proj3"
assert "lists the project's missing deny rules" grep -q "MISSING .*settings.json lacks $((n_deny - 1)) deny rule" <<<"$out"
assert "names a missing rule" grep -qF "Read(**/settings.xml)" <<<"$out"
assert "does not change it without --update" test "$(deny_count "$proj3/.claude/settings.json")" = 1
run --project "$proj3" --update
assert "--update adds the missing deny rules" test "$(deny_count "$proj3/.claude/settings.json")" = "$n_deny"
assert "--update keeps the other settings" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["model"]=="x" and d["permissions"]["allow"]==["Bash(ls)"] else 1)' "$proj3/.claude/settings.json"
assert "--update keeps the file mode" test "$(file_mode "$proj3/.claude/settings.json")" = 600
assert "--update backs the project settings up" grep -q "backup: .*/project-settings.json" <<<"$out"
bak="$(sed -n 's|.*backup: \(.*project-settings.json\)).*|\1|p' <<<"$out")"
assert "the backup has the original rules" test "$(deny_count "$bak")" = 1
assert "no temp file is left behind" test -z "$(find "$proj3/.claude" -name '.settings.*')"
proj4="$TMP/proj4"
mkdir -p "$proj4/.claude"
printf '{\n    "permissions": {\n        "deny": []\n    }\n}\n' >"$proj4/.claude/settings.json"
run --project "$proj4" --update
assert "--update keeps a 4-space indent" grep -q '^        "deny": \[' "$proj4/.claude/settings.json"
proj5="$TMP/proj5"
mkdir -p "$proj5/.claude"
echo '[]' >"$proj5/.claude/settings.json"
run --project "$proj5" --update
assert "a wrong-shaped project settings.json is left alone" test "$(cat "$proj5/.claude/settings.json")" = "[]"
assert "says why it was not checked" grep -q "could not check its deny rules: .*settings.json has an unexpected shape" <<<"$out"
proj6="$TMP/proj6"
mkdir -p "$proj6/.claude/agents" "$proj6/.claude/skills"
echo '{"permissions": {"deny": []}}' >"$proj6/.claude/settings.json"
# The agents and skills folders stay writable; only .claude itself refuses the temp file the merge needs.
# Root ignores mode bits, so this case only runs as a normal user.
if [[ "$(id -u)" != 0 ]]; then
  chmod 500 "$proj6/.claude"
  run --project "$proj6" --update
  chmod 700 "$proj6/.claude"
  assert "a failed write is reported" grep -q "FAILED .*settings.json (could not add the deny rules; the file is unchanged)" <<<"$out"
  assert "a failed write gives a one-line reason, not a traceback" out_lacks "Traceback"
  assert "a failed write leaves the file unchanged" test "$(deny_count "$proj6/.claude/settings.json")" = 0
  assert "a failed write still finishes the install" grep -q "Next: open Claude Code" <<<"$out"
else
  echo "  skip  a failed write (needs a non-root user)"
fi
out="$(QA_FAIL_SETTINGS_WRITE=1 "$REPO/install.sh" --project "$proj6" --update 2>&1)"
assert "a failure after the temp file exists is reported" grep -q "could not write .*simulated write failure" <<<"$out"
assert "it says the deny rules were not added" grep -q "FAILED .*settings.json (could not add the deny rules; the file is unchanged)" <<<"$out"
assert "it removes the temp file" test -z "$(find "$proj6/.claude" -name '.settings.*')"
assert "it leaves the file unchanged" test "$(deny_count "$proj6/.claude/settings.json")" = 0
proj8="$TMP/proj8"
mkdir -p "$proj8/.claude"
printf '{\n\t"permissions": {\n\t\t"deny": []\n\t}\n}\n' >"$proj8/.claude/settings.json"
run --project "$proj8" --update
assert "--update keeps a tab indent" grep -q "$(printf '^\t\t"deny": \\[')" "$proj8/.claude/settings.json"
proj9="$TMP/proj9"
mkdir -p "$proj9/.claude"
echo '{"permissions": {"deny": []}}' >"$proj9/.claude/settings.json"
run --project "$proj9" --update
assert "a one-line file is written with 2 spaces" grep -q '^    "deny": \[' "$proj9/.claude/settings.json"
# A plain file where the backups folder should be makes every backup fail, for root too.
proj10="$TMP/proj10"
mkdir -p "$proj10/.claude" "$TMP/blocked-home"
echo '{"permissions": {"deny": []}}' >"$proj10/.claude/settings.json"
: >"$TMP/blocked-home/backups"
out="$(CLAUDE_HOME="$TMP/blocked-home" "$REPO/install.sh" --project "$proj10" --update 2>&1)"
assert "a failed backup is reported" grep -q "FAILED .*settings.json (could not back it up" <<<"$out"
assert "a failed backup leaves the file unchanged" test "$(deny_count "$proj10/.claude/settings.json")" = 0
assert "a failed backup still finishes the install" grep -q "Next: open Claude Code" <<<"$out"
echo '{"permissions": {"deny": []}}' >"$TMP/blocked-home/settings.json"
out="$(CLAUDE_HOME="$TMP/blocked-home" "$REPO/install.sh" --settings 2>&1)"; rc=$?
assert "--settings reports a failed backup" grep -q "could not back up settings.json" <<<"$out"
assert "--settings fails when the backup fails" test "$rc" != 0
assert "--settings leaves the file unchanged when the backup fails" test "$(deny_count "$TMP/blocked-home/settings.json")" = 0
assert "--settings leaves no temp file when the backup fails" test -z "$(find "$TMP/blocked-home" -name '.settings.*')"
mf="$TMP/merge-fail-home"
mkdir -p "$mf"
echo '{"permissions": {"deny": []}}' >"$mf/settings.json"
out="$(CLAUDE_HOME="$mf" QA_FAIL_SETTINGS_WRITE=1 "$REPO/install.sh" --settings 2>&1)"; rc=$?
assert "--settings fails when the merge fails" test "$rc" = 1
assert "--settings says the file was left unchanged" grep -q "could not add the deny rules; settings.json was left unchanged" <<<"$out"
assert "--settings leaves the file unchanged when the merge fails" test "$(deny_count "$mf/settings.json")" = 0
assert "--settings leaves no temp file when the merge fails" test -z "$(find "$mf" -name '.settings.*')"
full="$TMP/full-backups-home"
fullp="$TMP/proj-full-backups"
mkdir -p "$fullp/.claude"
echo '{"permissions": {"deny": []}}' >"$fullp/.claude/settings.json"
for i in $(seq 0 999); do mkdir -p "$full/backups/qa-20990101-000000-$(printf '%03d' "$i")"; done
out="$(CLAUDE_HOME="$full" BACKUP_STAMP=20990101-000000 "$REPO/install.sh" --project "$fullp" --update 2>&1)"; rc=$?
assert "1000 backups in one second fails only the settings step" grep -q "FAILED .*settings.json (no free backup folder" <<<"$out"
assert "it names no empty backup path" out_lacks "back it up to ,"
assert "the agents are still copied" grep -q "copied .*agents/" <<<"$out"
assert "it still finishes the install" grep -q "Next: open Claude Code" <<<"$out"
assert "it leaves the file unchanged" test "$(deny_count "$fullp/.claude/settings.json")" = 0
echo '{"permissions": {"deny": []}}' >"$full/settings.json"
out="$(CLAUDE_HOME="$full" BACKUP_STAMP=20990101-000000 "$REPO/install.sh" --settings 2>&1)"; rc=$?
assert "--settings with no free backup folder fails" test "$rc" = 1
assert "--settings says the file was left unchanged" grep -q "no free backup folder; settings.json was left unchanged" <<<"$out"
assert "--settings leaves it unchanged" test "$(deny_count "$full/settings.json")" = 0
bad="$TMP/bad-utf8-home"
mkdir -p "$bad"
printf '{"a": "\377"}\n' >"$bad/settings.json"
out="$(CLAUDE_HOME="$bad" "$REPO/install.sh" --settings 2>&1)"
assert "a non-UTF-8 settings.json gives a one-line reason" grep -q "settings.json is not UTF-8 (byte offset" <<<"$out"
assert "a non-UTF-8 settings.json is not echoed" out_lacks "0xff"
assert "a non-UTF-8 settings.json is not echoed as an escape" out_lacks '\377'
assert "a non-UTF-8 settings.json is not echoed raw" out_lacks "$(printf '\377')"
saved_out="$out"
out="leaked \\377 here"
assert "out_lacks detects a leaked escape" test "$(out_lacks '\377' && echo missed || echo found)" = found
out="leaked $(printf '\377') here"
assert "out_lacks detects a leaked raw byte" test "$(out_lacks "$(printf '\377')" && echo missed || echo found)" = found
assert "out_lacks_file fails on a missing file" test "$(out_lacks_file x "$TMP/no-such-file" 2>/dev/null && echo passed || echo failed)" = failed
out="$saved_out"
badp="$TMP/proj-bad-utf8"
mkdir -p "$badp/.claude"
printf '{"a": "\377"}\n' >"$badp/.claude/settings.json"
cp "$badp/.claude/settings.json" "$TMP/bad-utf8-copy.json"
run --project "$badp" --update
assert "--project skips a non-UTF-8 settings.json with a reason" grep -q "could not check its deny rules: .*settings.json is not UTF-8 (byte offset" <<<"$out"
assert "--project does not echo the bytes" out_lacks "0xff"
assert "--project leaves the non-UTF-8 file unchanged" cmp -s "$badp/.claude/settings.json" "$TMP/bad-utf8-copy.json"
assert "a non-UTF-8 settings.json prints no traceback" out_lacks "Traceback"
if [[ "$(id -u)" != 0 ]]; then
  unread="$TMP/unread-home"
  mkdir -p "$unread"
  echo '{"permissions": {"deny": []}}' >"$unread/settings.json"
  chmod 000 "$unread/settings.json"
  out="$(CLAUDE_HOME="$unread" "$REPO/install.sh" --settings 2>&1)"
  chmod 600 "$unread/settings.json"
  assert "an unreadable settings.json gives a one-line reason" grep -q "could not read .*settings.json" <<<"$out"
  assert "an unreadable settings.json prints no traceback" out_lacks "Traceback"
  assert "an unreadable settings.json is left unchanged" test "$(deny_count "$unread/settings.json")" = 0
else
  echo "  skip  an unreadable settings.json (needs a non-root user)"
fi
enc="$TMP/proj-enc"
mkdir -p "$enc/.claude"
printf '{"permissions": {"deny": ["\\ud800"]}}\n' >"$enc/.claude/settings.json"
run --project "$enc" --update
assert "an unwritable value gives a one-line reason" grep -q "could not write .*settings.json" <<<"$out"
assert "an unwritable value prints no traceback" out_lacks "Traceback"
assert "an unwritable value leaves no temp file" test -z "$(find "$enc/.claude" -name '.settings.*')"
assert "an unwritable value does not echo it" out_lacks "ud800"
big="$TMP/proj-big"
mkdir -p "$big/.claude"
printf '{"model": 1e400, "permissions": {"deny": []}}\n' >"$big/.claude/settings.json"
cp "$big/.claude/settings.json" "$TMP/big-copy.json"
run --project "$big" --update
assert "a number JSON cannot write back is reported" grep -q "could not write .*settings.json: a value cannot be written back as JSON" <<<"$out"
assert "it is not turned into Infinity" cmp -s "$big/.claude/settings.json" "$TMP/big-copy.json"
assert "it prints no traceback" out_lacks "Traceback"
assert "it leaves no temp file" test -z "$(find "$big/.claude" -name '.settings.*')"
empty="$TMP/proj-empty"
mkdir -p "$empty/.claude"
: >"$empty/.claude/settings.json"
run --project "$empty" --update
assert "an empty settings.json gets the deny rules" test "$(deny_count "$empty/.claude/settings.json")" = "$n_deny"
dup="$TMP/proj-dup"
mkdir -p "$dup/.claude"
printf '{"permissions": {"deny": ["Read(**/.env)"]}, "permissions": {"deny": []}}\n' >"$dup/.claude/settings.json"
cp "$dup/.claude/settings.json" "$TMP/dup-copy.json"
run --project "$dup" --update
assert "duplicate keys are reported" grep -q 'has the same key twice in one object' <<<"$out"
assert "duplicate keys are not named" out_lacks '"permissions" twice'
assert "duplicate keys leave the file unchanged" cmp -s "$dup/.claude/settings.json" "$TMP/dup-copy.json"
mkdir -p "$TMP/no-mktemp"
printf '#!/bin/sh\nexit 1\n' >"$TMP/no-mktemp/mktemp"
chmod +x "$TMP/no-mktemp/mktemp"
mk="$TMP/proj-mk"
mkdir -p "$mk/.claude"
echo '{"permissions": {"deny": []}}' >"$mk/.claude/settings.json"
out="$(PATH="$TMP/no-mktemp:$PATH" "$REPO/install.sh" --project "$mk" --update 2>&1)"; rc=$?
assert "without mktemp the project install still finishes" test "$rc" = 0
assert "without mktemp the project settings are skipped with a reason" grep -q "could not create a temp file to check its deny rules" <<<"$out"
assert "without mktemp the file is unchanged" test "$(deny_count "$mk/.claude/settings.json")" = 0
out="$(CLAUDE_HOME="$TMP/mk-home" PATH="$TMP/no-mktemp:$PATH" "$REPO/install.sh" 2>&1)"; rc=$?
assert "without mktemp the default install still finishes" test "$rc" = 0
assert "without mktemp the settings check is skipped with a reason" grep -q "Skipped the settings check: could not create a temp file" <<<"$out"
proj7="$TMP/proj7"
mkdir -p "$proj7/.claude"
echo '{"permissions": {"deny": []}}' >"$proj7/.claude/settings.json"
out="$(PATH="$TMP/stubpath:$PATH" QA_PY_STUB="$TMP/stubpath/python3" QA_OS=Darwin QA_XCODE_SELECT="$stubs/xcode-none" "$REPO/install.sh" --project "$proj7" --update 2>&1)"
assert "without python3 the project settings are skipped" grep -q "SKIP .*settings.json (exists; checking its deny rules needs python3" <<<"$out"
assert "without python3 the file is unchanged" test "$(cat "$proj7/.claude/settings.json")" = '{"permissions": {"deny": []}}'
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
assert "--update leaves an unreadable settings.json alone" test "$(cat "$proj/.claude/settings.json")" = "custom"
assert "--update keeps CLAUDE.md" test "$(cat "$proj/CLAUDE.md")" = "# existing"

echo "--copilot"
cop="$TMP/copilot"
out="$(COPILOT_HOME="$cop" CLAUDE_HOME="$TMP/claude-untouched" "$REPO/install.sh" --copilot 2>&1)"; rc=$?
assert "exits 0" test "$rc" = 0
assert "links every skill" test "$(count_links "$cop/skills")" = "$n_skills"
assert "generates every agent" test "$(find "$cop/agents" -name '*.agent.md' | wc -l | tr -d ' ')" = "$n_agents"
gen="$cop/agents/${agent%.md}.agent.md"
assert "agent is a regular file, not a link" test -f "$gen" -a ! -L "$gen"
assert "agent keeps name and description" grep -q "^name: ${agent%.md}$" "$gen"
assert "agent gets a read-only tools allowlist" grep -qx "tools: \['read', 'search', 'execute', 'web', 'todo'\]" "$gen"
assert "allowlist has no edit tool" out_lacks_file "'edit'" "$gen"
assert "drops the model field" out_lacks_file "model:" "$gen"
assert "drops the color field" out_lacks_file "color:" "$gen"
assert "drops disallowedTools" out_lacks_file "disallowedTools:" "$gen"
assert "keeps the instructions unchanged" diff <(awk 'f;/^---$/{c++; if(c==2) f=1}' "$REPO/agents/$agent") <(awk 'f;/^<!-- Generated/{f=1}' "$gen")
assert "frontmatter keeps the source description exactly" python3 - "$gen" "$REPO/agents/$agent" <<'PY'
import re, sys
fm = re.match(r"\A---\n(.*?)\n---\n", open(sys.argv[1]).read(), re.S).group(1)
lines = fm.splitlines()
assert [l.split(":")[0] for l in lines] == ["name", "description", "tools"]
desc = lines[1].split(":", 1)[1].strip()
src = re.match(r"\A---\n(.*?)\n---\n", open(sys.argv[2]).read(), re.S).group(1)
assert desc == [l for l in src.splitlines() if l.startswith("description:")][0].split(":", 1)[1].strip(), desc
PY
assert "does not touch ~/.claude" test ! -e "$TMP/claude-untouched"
assert "says how to update" grep -q "run ./install.sh --copilot again" <<<"$out"
assert "explains MCP access when no servers are named" grep -q "The specialist agents can use only the servers you name" <<<"$out"
assert "VS Code tip: no setting needed" grep -q "^VS Code:  no setting needed" <<<"$out"
assert "VS Code tip: agent dropdown" grep -q "pick an agent in the Agent dropdown" <<<"$out"
assert "VS Code tip: Configure Skills menu" grep -q "/skills opens the Configure Skills menu" <<<"$out"
assert "VS Code tip: Diagnostics" grep -q "right-click in the Chat view > Diagnostics" <<<"$out"
assert "IntelliJ tip: setting" grep -q "^IntelliJ: turn on Settings > GitHub Copilot > Chat > Agent" <<<"$out"
assert "IntelliJ tip: admin policy" grep -q "Editor preview features policy" <<<"$out"
assert "IntelliJ tip: agent dropdown" grep -q "pick an agent in the agent dropdown" <<<"$out"
assert "no undocumented reload step" out_lacks "Reload Window"
for phrase in "Configure Custom Agents" "Configure Skills" "Diagnostics" "Settings > GitHub Copilot > Chat > Agent" "Editor preview features"; do
  assert "README mentions $phrase" grep -qF "$phrase" "$REPO/README.md"
done
assert "README has no undocumented reload step" out_lacks_file "Reload Window" "$REPO/README.md"
out="$(COPILOT_HOME="$cop" "$REPO/install.sh" --copilot 2>&1)"
assert "re-run reports ok" grep -q "ok        agents/$(basename "$gen")" <<<"$out"
echo "edited" >>"$gen"
out="$(COPILOT_HOME="$cop" "$REPO/install.sh" --copilot 2>&1)"
assert "re-run updates a changed generated agent" grep -q "updated   agents/$(basename "$gen")" <<<"$out"
assert "updated agent matches the source again" out_lacks_file "edited" "$gen"
out="$(COPILOT_HOME="$cop" COPILOT_MCP_SERVERS="atlassian azure-devops" "$REPO/install.sh" --copilot 2>&1)"
assert "adds MCP servers to the allowlist" grep -qx "tools: \['read', 'search', 'execute', 'web', 'todo', 'atlassian/\*', 'azure-devops/\*'\]" "$gen"
out="$(COPILOT_HOME="$cop" COPILOT_MCP_SERVERS="mcp.dev.azure.com/sc-ado" "$REPO/install.sh" --copilot 2>&1)"; rc=$?
assert "exits 0 for a registry-style MCP server name" test "$rc" = 0
assert "accepts a registry-style MCP server name" grep -qx "tools: \['read', 'search', 'execute', 'web', 'todo', 'mcp.dev.azure.com/sc-ado/\*'\]" "$gen"
assert "no MCP hint when servers are named" out_lacks "The specialist agents can use only the servers you name"
# Literal shell syntax is the test data here.
# shellcheck disable=SC2016
for bad in "bad;name" "it's" 'a"b' 'x\y' '$(id)' 'a`b' 'a,b' 'a#b'; do
  out="$(COPILOT_HOME="$TMP/cop-reject" COPILOT_MCP_SERVERS="$bad" "$REPO/install.sh" --copilot 2>&1)"; rc=$?
  assert "rejects MCP server name $bad" test "$rc" = 1
done
assert "writes nothing for rejected names" test ! -e "$TMP/cop-reject"
out="$(COPILOT_HOME="$cop" COPILOT_MCP_SERVERS='bad;name' "$REPO/install.sh" --copilot 2>&1)"; rc=$?
assert "rejects an invalid MCP server name" test "$rc" = 1

CLAUDE_HOME="$TMP/home3-claude" "$REPO/install.sh" >/dev/null 2>&1
echo "--copilot: qa-lead can delegate, specialists stay read-only"
lead="$cop/agents/qa-lead.agent.md"
# $1 is expanded by the inner bash.
# shellcheck disable=SC2016
assert "qa-lead has no tools list (all tools, including every MCP server)" bash -c '! grep -q "^tools:" "$1"' _ "$lead"
others="$(find "$REPO/agents" -maxdepth 1 -name '*.md' ! -name qa-lead.md -exec basename {} .md \; | sort | sed "s/.*/'&'/" | paste -sd, - | sed 's/,/, /g')"
assert "qa-lead keeps Show your work" grep -q "^## Show your work$" "$lead"
for rule in "The plan is information, not approval" "A ▶ line announces a step; it does not approve one" \
  "never echo the user's raw text or anything secret" "Could not start <agent> as a subagent" \
  "the specialist cannot start as a subagent (then item 5 of Show your work applies)"; do
  assert "qa-lead Show your work: $rule" grep -qF "$rule" "$lead"
done
# The fallback paths in qa-lead must match where the installers put the agent files.
# Literal paths as written in qa-lead.md, not expanded.
# shellcheck disable=SC2088
for path in '~/.copilot/agents/<name>.agent.md' '~/.claude/agents/<name>.md' '.claude/agents/<name>.md'; do
  assert "qa-lead names fallback path $path" grep -qF "\`$path\`" "$lead"
done
assert "Copilot install writes agents to ~/.copilot/agents/<name>.agent.md" test -f "$cop/agents/pr-reviewer.agent.md"
assert "Claude install links agents to ~/.claude/agents/<name>.md" test -L "$TMP/home3-claude/agents/pr-reviewer.md"
assert "qa-lead lists every other agent as a subagent" grep -qxF "agents: [$others]" "$lead"
assert "qa-lead does not list itself" out_lacks_file "'qa-lead'" "$lead"
for f in "$cop"/agents/*.agent.md; do
  [[ "$f" == "$lead" ]] && continue
  assert "$(basename "$f") has no edit tool" out_lacks_file "'edit'" "$f"
  assert "$(basename "$f") has no agents list" out_lacks_file "agents:" "$f"
done

echo "--copilot: write access is opt-in"
src2="$TMP/src-noflag"
mkdir -p "$src2" && (cd "$REPO" && tar cf - --exclude .git .) | (cd "$src2" && tar xf -)
sed '/^disallowedTools:/d' "$src2/agents/pr-reviewer.md" >"$src2/agents/x.md" && mv "$src2/agents/x.md" "$src2/agents/pr-reviewer.md"
out="$(COPILOT_HOME="$TMP/cop-noflag" "$src2/install.sh" --copilot 2>&1)"
assert "an agent without the orchestrator marker stays read-only" out_lacks_file "'edit'" "$TMP/cop-noflag/agents/pr-reviewer.agent.md"
assert "the marker itself is not copied" out_lacks_file "# copilot: orchestrator" "$TMP/cop-noflag/agents/qa-lead.agent.md"
sed -n '/^copilot_agent() {/,/^}/p' "$src2/install.sh" >"$TMP/copilot_agent.sh"
# Variables are expanded by the inner bash.
# shellcheck disable=SC2016
(cd "$src2" && bash -c '. "$1"; REPO=.; COPILOT_TOOLS="x"; COPILOT_MARKER="m"; copilot_agent agents/qa-lead.md' _ "$TMP/copilot_agent.sh" >"$TMP/rel-lead.md")
assert "the converter ran with a relative path" grep -q "^agents: \[" "$TMP/rel-lead.md"
assert "a relative source path does not list the lead as its own subagent" out_lacks_file "'qa-lead'" "$TMP/rel-lead.md"

echo "--copilot validates before writing"
mkdir -p "$TMP/globdir" && touch "$TMP/globdir/install.sh" "$TMP/globdir/README.md"
out="$(cd "$TMP/globdir" && COPILOT_HOME="$TMP/cop-glob" COPILOT_MCP_SERVERS='*' "$REPO/install.sh" --copilot 2>&1)"; rc=$?
assert "rejects a glob as an MCP server name" test "$rc" = 1
assert "reports the literal glob, not expanded file names" grep -qF "invalid server name '*'" <<<"$out"
assert "writes nothing for an invalid MCP list" test ! -e "$TMP/cop-glob"
out="$(COPILOT_HOME="$TMP/cop-bad" COPILOT_MCP_SERVERS='ok bad;name' "$REPO/install.sh" --copilot 2>&1)"; rc=$?
assert "rejects an invalid name in a list" test "$rc" = 1
assert "writes nothing when one name is invalid" test ! -e "$TMP/cop-bad"
out="$(COPILOT_HOME="$TMP/cop-help" "$REPO/install.sh" --copilot --help 2>&1)"; rc=$?
assert "--copilot --help exits 0" test "$rc" = 0
assert "--copilot --help prints usage" grep -q -- "--copilot" <<<"$out"

echo "--copilot converts unusual sources"
src="$TMP/src-repo"
mkdir -p "$src" && (cd "$REPO" && tar cf - --exclude .git .) | (cd "$src" && tar xf -)
sed 's/$/\r/' "$src/agents/$agent" >"$src/agents/$agent.tmp" && mv "$src/agents/$agent.tmp" "$src/agents/$agent"
printf '%s\n' "---" "name: folded" "description: >" "  First line of a folded description" "  and its second line." "model: opus" "---" "" "Body." >"$src/agents/folded.md"
out="$(COPILOT_HOME="$TMP/cop-src" "$src/install.sh" --copilot 2>&1)"; rc=$?
assert "exits 0" test "$rc" = 0
crlf_gen="$TMP/cop-src/agents/${agent%.md}.agent.md"
assert "converts a CRLF source" grep -q "^name: ${agent%.md}$" "$crlf_gen"
assert "drops the carriage returns" out_lacks_file $'\r' "$crlf_gen"
assert "keeps the CRLF agent's body" diff <(awk 'f;/^---$/{c++; if(c==2) f=1}' "$REPO/agents/$agent") <(awk 'f;/^<!-- Generated/{f=1}' "$crlf_gen")
assert "keeps a folded description" grep -q "^  and its second line.$" "$TMP/cop-src/agents/folded.agent.md"
assert "drops model from the folded agent" out_lacks_file "model:" "$TMP/cop-src/agents/folded.agent.md"
printf '%s\n' "# no frontmatter" >"$src/agents/broken.md"
out="$(COPILOT_HOME="$TMP/cop-broken" "$src/install.sh" --copilot 2>&1)"; rc=$?
assert "fails on a source without frontmatter" test "$rc" = 1
assert "names the broken source" grep -q "cannot convert .*broken.md" <<<"$out"
assert "prints no usage text after the error" out_lacks "Installs the QA agents"
assert "writes nothing when a source is broken" test ! -e "$TMP/cop-broken"
printf '%s\n' "---" "name: nodesc" "---" "Body." >"$src/agents/broken.md"
out="$(COPILOT_HOME="$TMP/cop-broken" "$src/install.sh" --copilot 2>&1)"; rc=$?
assert "fails on a source without a description" test "$rc" = 1

echo "--copilot removes links to skills that left the repo"
ln -s "$REPO/skills/moved-skill" "$cop/skills/moved-skill"
out="$(COPILOT_HOME="$cop" "$REPO/install.sh" --copilot 2>&1)"
assert "removes the dead skill link" test ! -L "$cop/skills/moved-skill"
assert "reports it" grep -q "removed   skills/moved-skill (no longer in this repo" <<<"$out"
ln -s "/old/clone/skills/old-skill" "$cop/skills/old-skill"
ln -s "/old/clone/skills/${skill}" "$cop/skills/keep-me"
out="$(COPILOT_HOME="$cop" "$REPO/install.sh" --copilot 2>&1)"
assert "removes a moved clone's link to a skill no longer shipped" test ! -L "$cop/skills/old-skill"
assert "keeps a broken link whose name does not match its target" test -L "$cop/skills/keep-me"

echo "--copilot keeps foreign agents and cleans up removed ones"
cop2="$TMP/copilot2"
mkdir -p "$cop2/agents"
echo "my own agent" >"$cop2/agents/${agent%.md}.agent.md"
printf '%s\n' "---" "name: gone" "---" "<!-- Generated by claude-qa-automation/install.sh --copilot from agents/gone.md -->" >"$cop2/agents/gone.agent.md"
echo "unrelated" >"$cop2/agents/unrelated.agent.md"
out="$(COPILOT_HOME="$cop2" "$REPO/install.sh" --copilot 2>&1)"
assert "backs up a foreign agent with the same name" grep -q "backed up agents/${agent%.md}.agent.md" <<<"$out"
assert "removes a generated agent whose source is gone" test ! -e "$cop2/agents/gone.agent.md"
assert "keeps unrelated agents" test -f "$cop2/agents/unrelated.agent.md"
out="$(COPILOT_HOME="$cop2" "$REPO/install.sh" --copilot --uninstall 2>&1)"; rc=$?
assert "uninstall exits 0" test "$rc" = 0
assert "uninstall restores the foreign agent" test "$(cat "$cop2/agents/${agent%.md}.agent.md")" = "my own agent"
assert "uninstall removes the other generated agents" test -z "$(find "$cop2/agents" -name '*.agent.md' ! -name "${agent%.md}.agent.md" ! -name unrelated.agent.md)"
assert "uninstall removes the skill links" test "$(count_links "$cop2/skills")" = 0
assert "uninstall keeps unrelated agents" test -f "$cop2/agents/unrelated.agent.md"
assert "uninstall does not mention settings.json" out_lacks "settings.json"
run --copilot --settings
assert "--copilot rejects other options" test "$rc" = 1

echo "arguments"
run --help
assert "--help exits 0" test "$rc" = 0
assert "--help prints usage" grep -q -- "--settings" <<<"$out"
assert "--help prints the whole header" grep -q "the team repo's git history is their backup" <<<"$out"
assert "--help does not print the shell options line" out_lacks "set -euo pipefail"
run --bogus
assert "a bad argument prints the whole usage" grep -q "the team repo's git history is their backup" <<<"$out"
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
