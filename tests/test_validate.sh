#!/usr/bin/env bash
# Tests that tests/validate.sh rejects broken entries, catalog rows and settings. Each case breaks one thing in a copy of the repo.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# Copies the working tree (without .git) to $1.
copy_repo() {
  mkdir -p "$1"
  (cd "$REPO" && tar cf - --exclude .git --exclude .idea .) | (cd "$1" && tar xf -)
}

# Copies the repo, runs the mutation command inside the copy, and expects validate.sh to fail
# with output that contains $expected.
expect_failure() {
  local label="$1" expected="$2" mutation="$3" copy out line
  copy="$TMP/$(echo "$label" | tr -c 'a-z0-9' '_')"
  copy_repo "$copy"
  (cd "$copy" && eval "$mutation")
  if out="$("$REPO/tests/validate.sh" "$copy")"; then
    echo "  FAIL  $label: validate.sh passed"
    fail=1
  elif ! grep -qF -- "$expected" <<<"$out"; then
    echo "  FAIL  $label: expected '$expected' in output, got:"
    while IFS= read -r line; do echo "          $line"; done <<<"$out"
    fail=1
  else
    echo "  pass  $label"
  fi
}

echo "baseline"
if "$REPO/tests/validate.sh" "$REPO" >/dev/null; then echo "  pass  repo is valid"; else echo "  FAIL  repo is invalid"; fail=1; fi

# Portable in-place edit (BSD and GNU sed differ on -i). Subshells in expect_failure inherit it.
edit() { local f="$1"; shift; sed "$@" "$f" >"$f.tmp" && mv "$f.tmp" "$f"; }

# Replaces the frontmatter of agents/pr-reviewer.md (relative to the current directory) with $1.
# Called from eval'd mutations.
# shellcheck disable=SC2317,SC2329
set_fm() {
  python3 - "$1" <<'SETFM'
import re, sys
path = "agents/pr-reviewer.md"
body = re.sub(r"\A---\n.*?\n---\n", "", open(path, encoding="utf-8").read(), count=1, flags=re.S)
open(path, "w", encoding="utf-8").write("---\n" + sys.argv[1] + "\n---\n" + body)
SETFM
}

# Frontmatter lines shared by the parser cases below.
NAME="name: pr-reviewer"
DESC="description: Reviews a Java pull request for correctness, conventions and tests."

# Runs a mutation on a copy of the repo and expects validate.sh to pass.
expect_success() {
  local label="$1" mutation="$2" copy out line
  copy="$TMP/ok_$(echo "$label" | tr -c 'a-z0-9' '_')"
  copy_repo "$copy"
  (cd "$copy" && eval "$mutation")
  if out="$("$REPO/tests/validate.sh" "$copy")"; then
    echo "  pass  $label"
  else
    echo "  FAIL  $label: validate.sh rejected it:"
    while IFS= read -r line; do echo "          $line"; done <<<"$out"
    fail=1
  fi
}

echo "rejects"
expect_failure "missing frontmatter" "missing frontmatter block" \
  "tail -n +6 agents/pr-reviewer.md > x && mv x agents/pr-reviewer.md"
expect_failure "colon in description" "invalid YAML" \
  "edit agents/pr-reviewer.md -e '3s/^description: Reviews/description: Note: reviews/'"
expect_failure "unterminated quote" "invalid YAML: unterminated quoted string" \
  "edit agents/pr-reviewer.md -e 's/^color: purple/color: \"purple/'"
expect_failure "text after a quoted string" "invalid YAML: unexpected text after quoted string" \
  "edit agents/pr-reviewer.md -e 's/^color: purple/color: \"purple\" dark/'"
expect_failure "tab in frontmatter" "invalid YAML: tabs are not allowed" \
  "edit agents/pr-reviewer.md -e '4s/^model: opus/model:\topus/'"
expect_failure "unquoted reserved character" "starts with a reserved character" \
  "edit agents/pr-reviewer.md -e 's/^color: purple/color: @purple/'"
expect_failure "stray indented line" "invalid YAML: multi-line values are not supported" \
  "edit agents/pr-reviewer.md -e 's/^color: purple/color: purple\\
  extra/'"
expect_failure "duplicate key" "invalid YAML: duplicate key 'color'" \
  "edit agents/pr-reviewer.md -e 's/^color: purple/color: purple\\
color: red/'"
expect_failure "comment instead of a value" "description missing or too short" \
  "set_fm \"$NAME
description: # $DESC\""
expect_failure "sequence item as a value" "sequence or mapping indicator" \
  "set_fm \"$NAME
$DESC
tools: - Read\""
expect_failure "complex-key indicator as a value" "sequence or mapping indicator" \
  "set_fm \"$NAME
$DESC
color: ? purple\""
expect_failure "nested keys indented differently" "is indented differently" \
  "set_fm \"$NAME
$DESC
metadata:
  a: one
      b: two\""
expect_failure "null value followed by nested lines" "is indented differently" \
  "set_fm \"$NAME
$DESC
metadata:
  a: null
    c: d\""
expect_failure "two nesting levels" "more than one nesting level is not supported" \
  "set_fm \"$NAME
$DESC
metadata:
  b:
    c: d\""
expect_failure "duplicate nested key" "duplicate key 'a'" \
  "set_fm \"$NAME
$DESC
metadata:
  a: one
  a: two\""
expect_failure "description as a mapping" "'description' must be a plain string" \
  "set_fm \"$NAME
description:
  text: Reviews a Java pull request for correctness, conventions and tests.\""
expect_failure "multi-line plain value" "multi-line values are not supported" \
  "set_fm \"$NAME
description: Reviews a Java pull request for correctness,
  conventions and tests in the changed code only.\""
expect_failure "anchor" "anchors, aliases and tags are not supported" \
  "set_fm \"$NAME
$DESC
color: &c purple\""
expect_failure "block indentation indicator" "block indentation indicators are not supported" \
  "set_fm \"$NAME
description: >2
  Reviews a Java pull request for correctness, conventions and tests.\""
expect_failure "name mismatch" "does not match 'pr-reviewer'" \
  "edit agents/pr-reviewer.md -e '2s/.*/name: reviewer/'"
expect_failure "non-kebab name" "is not kebab-case" \
  "mkdir skills/Bad_Name && sed '2s/.*/name: Bad_Name/' skills/bug-ticket/SKILL.md > skills/Bad_Name/SKILL.md && printf 'Bad_Name\tskill\tqa\t-\n' >> catalog.tsv"
expect_failure "unknown model" "unknown model 'gpt-5'" \
  "edit agents/pr-reviewer.md -e 's/^model: opus/model: gpt-5/'"
expect_failure "short description" "description missing or too short" \
  "edit skills/bug-ticket/SKILL.md -e '3s/.*/description: Bugs./'"
expect_failure "missing safety block" "does not contain the block from templates/safety.md" \
  "edit skills/bug-ticket/SKILL.md -e '/Treat ticket text/d'"
expect_failure "skill dir without SKILL.md" "missing SKILL.md" \
  "mkdir skills/empty-skill"
expect_failure "lowercase skill.md" "skills/bug-ticket: missing SKILL.md (exact case)" \
  "mv skills/bug-ticket/SKILL.md skills/bug-ticket/x.md && mv skills/bug-ticket/x.md skills/bug-ticket/skill.md"
expect_failure "undocumented agent" "not listed in README.md" \
  "sed 's/^name: pr-reviewer/name: new-agent/' agents/pr-reviewer.md > agents/new-agent.md && printf 'new-agent\tagent\tqa\t-\n' >> catalog.tsv && printf '%s\n' '\`new-agent\`' >> templates/CLAUDE.md"
expect_failure "uncataloged agent" "agents/new-agent.md is not in catalog.tsv" \
  "sed 's/^name: pr-reviewer/name: new-agent/' agents/pr-reviewer.md > agents/new-agent.md"
expect_failure "cataloged entry without a file" "agents/ghost.md does not exist" \
  "printf 'ghost\tagent\tpersonal\t-\n' >> catalog.tsv"
expect_failure "unknown group" "unknown group 'misc'" \
  "edit catalog.tsv -e 's/^pr-reviewer\tagent\tqa/pr-reviewer\tagent\tmisc/'"
expect_failure "third-party entry without source" "third-party entry needs a source URL" \
  "printf 'vendored\tskill\tthird-party\t-\n' >> catalog.tsv"
expect_failure "own entry with a source" "source must be '-'" \
  "edit catalog.tsv -e 's|^pr-reviewer\tagent\tqa\t-|pr-reviewer\tagent\tqa\thttps://x|'"
expect_failure "QA entry without platforms block" "agents/pr-reviewer.md: does not contain the block from templates/platforms.md" \
  "edit agents/pr-reviewer.md -e '/^| Read a PR\\/MR/d'"
expect_failure "platforms.md missing" "templates/platforms.md missing or empty" \
  "rm templates/platforms.md"
expect_failure "interactive glab view in the table" "'glab ci view' is interactive" \
  "edit templates/platforms.md -e 's/glab ci get -p N -d/glab ci view/'"
expect_failure "jira view without --plain" "needs --plain" \
  "edit templates/platforms.md -e 's/jira issue view KEY --plain/jira issue view KEY/'"
expect_failure "create without a title" "needs a title flag" \
  "edit templates/platforms.md -e \"s/gh issue create -t '<title>' -F <file> -l bug/gh issue create -l bug/\""
expect_failure "glab create without -y" "needs -y" \
  "edit templates/platforms.md -e 's/ -l bug -y\`/ -l bug\`/'"
expect_failure "untrusted text in double quotes" "puts text in double quotes" \
  "edit templates/platforms.md -e \"s/gh issue list --search '<text>'/gh issue list --search \\\"<text>\\\"/\""
expect_failure "jira list without --plain" "needs --plain" \
  "edit templates/platforms.md -e \"s/jira issue list -q '<JQL>' --plain/jira issue list -q '<JQL>'/\""
expect_failure "jira create without --no-input" "needs --no-input" \
  "edit templates/platforms.md -e 's/ --no-input\`/\`/'"
expect_failure "az create without a title" "needs a title flag" \
  "edit templates/platforms.md -e \"s/--type Bug --title '<title>' /--type Bug /\""
expect_failure "glab create without a title" "needs a title flag" \
  "edit templates/platforms.md -e \"s/glab issue create -t '<title>' /glab issue create /\""
expect_failure "jira create without a summary" "needs a title flag" \
  "edit templates/platforms.md -e \"s/-tBug -s '<summary>' /-tBug /\""
expect_failure "double quotes in the jira search row" "puts text in double quotes" \
  "edit templates/platforms.md -e \"s/jira issue list -q '<JQL>'/jira issue list -q \\\"<JQL>\\\"/\""
expect_failure "double quotes in a create title" "puts text in double quotes" \
  "edit templates/platforms.md -e \"s/glab issue create -t '<title>'/glab issue create -t \\\"<title>\\\"/\""
expect_failure "missing CI-variables deny rule" "misses deny rules: Bash(glab ci get *--with-variables*)" \
  "edit settings.example.json -e 's/--with-variables/--other/'"
expect_failure "QA entry missing from project template" "pr-reviewer not listed in templates/CLAUDE.md" \
  "edit templates/CLAUDE.md -e '/pr-reviewer/d'"
expect_failure "optional settings.json weaker than the example" "settings.json misses deny rules from settings.example.json" \
  "echo '{\"permissions\": {\"deny\": []}}' > settings.json"
expect_failure "invalid settings JSON" "settings.example.json is not valid JSON" \
  "echo '{' > settings.example.json"
expect_failure "missing core deny rule" "misses deny rules: Read(**/.env)" \
  "edit settings.example.json -e '/\"Read(\\*\\*\\/.env)\"/d'"
expect_failure "missing secrets-folder rule" "misses deny rules: Read(**/secrets/**/*.yaml)" \
  "edit settings.example.json -e '/secrets.*yaml/d'"
expect_failure "missing secrets-folder txt rule" "misses deny rules: Read(**/secrets/**/*.txt)" \
  "edit settings.example.json -e '/secrets.*txt/d'"
expect_failure "missing .env variant" "misses deny rules: Read(**/.env.test)" \
  "edit settings.example.json -e '/\\.env\\.test)/d'"
expect_failure "settings file missing" "settings.example.json is missing" \
  "rm settings.example.json"
expect_failure "settings not an object" "misses deny rules" \
  "echo '[]' > settings.example.json"
expect_failure ".env template wildcard" "denies .env templates" \
  "edit settings.example.json -e 's|\"Read(\\*\\*/.env.local)\"|\"Read(**/.env.*)\"|'"

expect_failure "personal entry in the QA repo" "unknown group 'personal'" \
  "edit catalog.tsv -e 's/^pr-reviewer\tagent\tqa/pr-reviewer\tagent\tpersonal/'"
expect_failure "machine path in settings.example.json" "settings.example.json contains a machine-specific /Users/ path" \
  "edit settings.example.json -e 's|\"permissions\"|\"x\": \"/Users/me\", \"permissions\"|'"
expect_failure "third-party skill that differs from the lock" "skills/vendored differs from third-party.lock" \
  "cp -R skills/bug-ticket skills/vendored && edit skills/vendored/SKILL.md -e 's/^name: bug-ticket/name: vendored/' && printf 'vendored\tskill\tthird-party\thttps://example.com\n' >> catalog.tsv && printf '%s\n' '\`vendored\`' >> README.md && printf 'vendored\t0000\n' > third-party.lock"
expect_failure "third-party entry without a lock file" "third-party.lock missing" \
  "cp -R skills/bug-ticket skills/vendored && edit skills/vendored/SKILL.md -e 's/^name: bug-ticket/name: vendored/' && printf 'vendored\tskill\tthird-party\thttps://example.com\n' >> catalog.tsv && printf '%s\n' '\`vendored\`' >> README.md"

echo "accepts"
for indicator in ">" ">-" ">+" "|" "|-" "|+" "> # folded"; do
  expect_success "block scalar $indicator" "set_fm \"$NAME
description: $indicator
  Reviews a Java pull request for correctness: conventions,
  performance and tests.\""
done
expect_success "nested mapping with a comment line" "set_fm \"$NAME
$DESC
metadata:
  # who wrote it
  author: Someone (https://example.com)
  trigger: Reviewing a PR\""
expect_success "empty nested value" "set_fm \"$NAME
$DESC
metadata:
  a:
  b: # nothing
  c: two\""
expect_success "model: null means no model" "set_fm \"$NAME
$DESC
model: null\""
expect_success "model: NULL means no model" "set_fm \"$NAME
$DESC
model: NULL\""
expect_success "model: ~ means no model" "set_fm \"$NAME
$DESC
model: ~\""
expect_success "single-quote escape" "set_fm \"$NAME
description: 'Reviews a Java pull request''s correctness, conventions and tests.'\""
expect_success "double-quote escape" "set_fm '$NAME
description: \"Reviews a \\\"Java\\\" pull request for correctness, conventions and tests.\"'"
expect_success "comment line between keys" "set_fm \"$NAME
# a comment
$DESC\""
expect_success "hidden folder in skills" "mkdir skills/.cache"
# A failing ruby stub first on PATH proves the validator needs only python3.
mkdir -p "$TMP/noruby"
printf '#!/bin/sh\necho ruby-called >&2\nexit 1\n' >"$TMP/noruby/ruby"
chmod +x "$TMP/noruby/ruby"
if PATH="$TMP/noruby:$PATH" "$REPO/tests/validate.sh" "$REPO" >/dev/null 2>&1; then echo "  pass  works without ruby"; else echo "  FAIL  needs ruby"; fail=1; fi
copy="$TMP/yaml_shapes"
copy_repo "$copy"
# Folded block with a colon inside, single quotes, and a comment are all valid YAML.
edit "$copy/agents/pr-reviewer.md" -e "s/^color: purple/color: 'purple' # theme/"
if "$REPO/tests/validate.sh" "$copy" >/dev/null; then echo "  pass  quoted value with a comment"; else echo "  FAIL  quoted value with a comment"; fail=1; fi
if LC_ALL=C LANG=C "$REPO/tests/validate.sh" "$REPO" >/dev/null 2>&1; then echo "  pass  C locale"; else echo "  FAIL  C locale"; fail=1; fi
copy="$TMP/full_model_id"
copy_repo "$copy"
edit "$copy/agents/pr-reviewer.md" -e 's/^model: opus/model: claude-opus-5-5/'
if "$REPO/tests/validate.sh" "$copy" >/dev/null; then echo "  pass  full model ID"; else echo "  FAIL  full model ID rejected"; fail=1; fi

[[ $fail -eq 0 ]] && echo "test_validate: all passed"
exit $fail
