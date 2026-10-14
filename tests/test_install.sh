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
out_lacks() { ! grep -q -- "$1" <<<"$out"; }

# True if file $2 does not contain $1. Called through assert.
# shellcheck disable=SC2317,SC2329
out_lacks_file() { ! grep -qF -- "$1" "$2"; }

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
run
assert "plain install no longer reports missing rules" out_lacks "lacks"

echo "default run explains why the settings check failed"
mkdir -p "$TMP/badjson"
printf '{not json' >"$TMP/badjson/settings.json"
out="$(CLAUDE_HOME="$TMP/badjson" "$REPO/install.sh" 2>&1)"; rc=$?
assert "exits 0" test "$rc" = 0
assert "shows the reason" grep -q "Could not check .*: settings.json is not valid JSON" <<<"$out"

echo "--settings on a fresh machine"
out="$(CLAUDE_HOME="$TMP/fresh" "$REPO/install.sh" --settings 2>&1)"; rc=$?
assert "exits 0" test "$rc" = 0
assert "creates settings.json with the deny rules" test "$(deny_count "$TMP/fresh/settings.json")" = "$n_deny"
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
assert "accepts a registry-style MCP server name" grep -qx "tools: \['read', 'search', 'execute', 'web', 'todo', 'mcp.dev.azure.com/sc-ado/\*'\]" "$gen"
assert "no MCP hint when servers are named" out_lacks "The specialist agents can use only the servers you name"
for bad in "bad;name" "it's" 'a"b' 'x\y'; do
  out="$(COPILOT_HOME="$TMP/cop-reject" COPILOT_MCP_SERVERS="$bad" "$REPO/install.sh" --copilot 2>&1)"; rc=$?
  assert "rejects MCP server name $bad" test "$rc" = 1
done
assert "writes nothing for rejected names" test ! -e "$TMP/cop-reject"
out="$(COPILOT_HOME="$cop" COPILOT_MCP_SERVERS='bad;name' "$REPO/install.sh" --copilot 2>&1)"; rc=$?
assert "rejects an invalid MCP server name" test "$rc" = 1

echo "--copilot: qa-lead can delegate, specialists stay read-only"
lead="$cop/agents/qa-lead.agent.md"
assert "qa-lead has no tools list (all tools, including every MCP server)" out_lacks_file "tools:" "$lead"
others="$(find "$REPO/agents" -maxdepth 1 -name '*.md' ! -name qa-lead.md -exec basename {} .md \; | sort | sed "s/.*/'&'/" | paste -sd, - | sed 's/,/, /g')"
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
