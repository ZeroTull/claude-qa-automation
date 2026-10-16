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
  if out="$(env -u QA_DUMP_PINS "$REPO/tests/validate.sh" "$copy")"; then
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
if env -u QA_DUMP_PINS "$REPO/tests/validate.sh" "$REPO" >/dev/null; then echo "  pass  repo is valid"; else echo "  FAIL  repo is invalid"; fail=1; fi

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

expect_failure "agent the lead does not route" "agents/qa-lead.md does not route agent \`new-agent\`" \
  "sed 's/^name: pr-reviewer/name: new-agent/' agents/pr-reviewer.md > agents/new-agent.md && printf 'new-agent\tagent\tqa\t-\n' >> catalog.tsv && printf '%s\n' '\`new-agent\`' >> templates/CLAUDE.md README.md"
expect_failure "skill the lead does not route" "agents/qa-lead.md does not route skill \`test-cases\`" \
  "edit agents/qa-lead.md -e 's/\`test-cases\`/\`x\`/g'"
expect_failure "framework-map the lead does not route" "agents/qa-lead.md does not route skill \`framework-map\`" \
  "edit agents/qa-lead.md -e 's/\`framework-map\`/\`x\`/g'"
expect_failure "QA entry without the project map block" "agents/test-maintainer.md: does not contain the block from templates/project-map.md" \
  "edit agents/test-maintainer.md -e 's|^- If the map and the code disagree, the code wins; say what differs.|- Trust the map.|'"
expect_failure "project-map.md missing" "templates/project-map.md missing or empty" \
  "rm templates/project-map.md"
expect_failure "map skill writes another file" "skills/framework-map/SKILL.md must write only" \
  "edit skills/framework-map/SKILL.md -e 's|write only .\.ai/context/framework-map\.md.|write only architecture.md|'"
expect_failure "map skill without a Snapshot line" "must record the snapshot commit and uncommitted changes" \
  "edit skills/framework-map/SKILL.md -e 's|^   Snapshot: <date>, commit <short sha>.|   Taken today.|'"
expect_failure "map skill names a second context file" "skills/framework-map/SKILL.md names \`.ai/context/architecture.md\`" \
  "printf '%s\\n' 'Also write \`.ai/context/architecture.md\`.' >> skills/framework-map/SKILL.md"
expect_failure "map skill without the size cap" "must keep the map under 250 lines" \
  "edit skills/framework-map/SKILL.md -e 's|under 250 lines|short|'"
expect_failure "entry that would follow instructions in the map" "agents/pr-reviewer.md: does not contain the block from templates/project-map.md" \
  "edit agents/pr-reviewer.md -e '/^- The map was written from the code/d'"
expect_failure "map skill names a second context file in plain text" "names \`.ai/context/notes.md\`" \
  "printf '%s\\n' 'Also update .ai/context/notes.md.' >> skills/framework-map/SKILL.md"
expect_failure "map skill copies comments" "must paraphrase code comments and strings" \
  "edit skills/framework-map/SKILL.md -e 's|never copy them into the map|copy them|'"
expect_failure "map skill without the skip list" "must skip secret-bearing config files by name" \
  "edit skills/framework-map/SKILL.md -e 's|\`\*token\*\`|tokens|'"
expect_failure "map skill copies hosts" "must not copy URLs, hosts or account names" \
  "edit skills/framework-map/SKILL.md -e 's|Never copy URLs, hosts, IP addresses or account names|Keep URLs|'"
expect_failure "YAML key grep that prints host:port items" "must list YAML keys without host:port values" \
  "edit skills/framework-map/SKILL.md -e 's|+:( [|][$])|+:|'"
expect_failure "YAML key pattern that prints a host" "the YAML key pattern lists" \
  "edit skills/framework-map/SKILL.md -e 's|+:( [|][$])|+:|'"
expect_failure "skip list limited to config extensions" "must skip secret-bearing config files by name" \
  "edit skills/framework-map/SKILL.md -e 's|of any type except source code|with a config extension|'"
expect_failure "YAML key pattern that prints a dotted host key" "the YAML key pattern lists" \
  "edit skills/framework-map/SKILL.md -e 's|\[A-Za-z0-9_-\]+:( |[A-Za-z0-9_.-]+:( |'"
expect_failure "host key printed as-is" "must write a host key as <host key>" \
  "edit skills/framework-map/SKILL.md -e 's|If a key is itself a host or URL|If a key is named|'"
expect_failure "quoted-key note dropped" "must note that quoted or dotted YAML keys may be missed" \
  "edit skills/framework-map/SKILL.md -e 's|Quoted or dotted YAML keys may be missed|Keys are listed|'"
expect_failure "host-name key note dropped" "must say not to repeat host-name keys" \
  "edit skills/framework-map/SKILL.md -e 's|The grep can still show a key that is a host name|Keys are safe|'"
expect_failure "agents read another map file" "templates/project-map.md must name" \
  "edit templates/project-map.md -e 's|framework-map\.md|map.md|'"
expect_failure "diagnoser that rules out the product" "must not rule out a product defect for timeouts or reruns without evidence" \
  "edit agents/ci-failure-diagnoser.md -e 's|Until the evidence rules the product out|Always|'"
expect_failure "diagnoser that picks one cause" "must list every plausible cause when the evidence is inconclusive" \
  "edit agents/ci-failure-diagnoser.md -e 's|list every plausible one, ranked|pick the likeliest|'"
expect_failure "diagnoser without other causes" "must report other possible causes" \
  "edit agents/ci-failure-diagnoser.md -e 's|^## Other Possible Causes|## Notes|'"
expect_failure "triager without product defects" "must recognise intermittent product defects" \
  "edit agents/flaky-test-triager.md -e 's|^- [*][*]Intermittent product defect (confirmed, case 3):[*][*]|- Other:|'"
expect_failure "triager that calls flaky too early" "must rule out a product cause before calling a test flaky" \
  "edit agents/flaky-test-triager.md -e 's|^Do not call a test genuinely flaky until a product cause is ruled out|Call it flaky|'"
expect_failure "diagnoser that dismisses a timeout" "must not call a timeout 'not a code defect' without evidence" \
  "edit agents/ci-failure-diagnoser.md -e 's|Do not call it \"not a code defect\" without that evidence|Treat it as flaky|'"
expect_failure "diagnoser without the suspected label" "must label timeouts as suspected flaky with the product not ruled out" \
  "edit agents/ci-failure-diagnoser.md -e 's|suspected flaky/environment (product not ruled out)|flaky-environment|'"
expect_failure "diagnoser without a product defect label" "must have a label for confirmed pre-existing product defects" \
  "edit agents/ci-failure-diagnoser.md -e 's|^- [*][*]Product defect (pre-existing, confirmed):[*][*]|- Other:|'"
expect_failure "diagnoser that guesses a root cause" "must not present a guess as the root cause" \
  "edit agents/ci-failure-diagnoser.md -e 's|; if the evidence is inconclusive, say so and point to Other Possible Causes||'"
expect_failure "triager without the product defect verdict" "must offer an intermittent product defect verdict" \
  "edit agents/flaky-test-triager.md -e 's|intermittent product defect (confirmed) \\[case 3\\]|other|'"
expect_failure "triager that quarantines real bugs" "must not quarantine a test that catches a real bug" \
  "edit agents/flaky-test-triager.md -e 's|never quarantine a test that catches a real bug|quarantine it|'"
expect_failure "triager that lists product defects as known flaky" "must add only genuinely flaky tests to known-flaky-tests.md" \
  "edit agents/flaky-test-triager.md -e 's|never for an inconclusive verdict, an intermittent product defect, a regression or an environment cause|always|'"
expect_failure "triager without a confirmed/inconclusive rule" "must say when a product defect is confirmed versus inconclusive" \
  "edit agents/flaky-test-triager.md -e 's|Use intermittent product defect only when the product cause is confirmed|Decide|'"
expect_failure "agent rules on an emptied file" "agents/flaky-test-triager.md must recognise intermittent product defects" \
  "awk 'NR==1 || f<2 {print} /^---\$/{f++}' agents/flaky-test-triager.md > x.tmp && mv x.tmp agents/flaky-test-triager.md"
expect_failure "README trace with an old label" "trace example must use the diagnoser's suspected-flaky label" \
  "edit README.md -e 's|suspected flaky/environment (product not ruled out)|flaky/environment|'"
expect_failure "agent file missing" "agents/flaky-test-triager.md must recognise intermittent product defects" \
  "rm agents/flaky-test-triager.md"
expect_failure "README plan example filing any defect" "README.md plan example must file bugs only for confirmed product defects or shared-branch regressions" \
  "edit README.md -e 's|for a pre-existing confirmed product defect, or a regression from a merged change if the user chooses it|only if it is a real defect|'"
expect_failure "bug-ticket that dismisses intermittent failures" "must not dismiss intermittent failures as non-bugs" \
  "edit skills/bug-ticket/SKILL.md -e 's|An intermittent failure can still be a product defect|A flaky test is not a bug|'"
expect_failure "README without the product-defect verdict" "must describe the triager's product-defect verdict" \
  "edit README.md -e 's|an intermittent product defect (such as a race condition)|a regression|'"
expect_failure "diagnoser description with the old classes" "description must list the product-defect and suspected-flaky classes" \
  "edit agents/ci-failure-diagnoser.md -e 's|product defect (confirmed), suspected flaky/environment|flaky/environment|'"
expect_failure "triager description without product defects" "description must name the product-defect verdict" \
  "edit agents/flaky-test-triager.md -e 's|an intermittent product defect (for example a race condition) or a regression|or a regression|'"
expect_failure "diagnoser listing the product cause last" "must list the product cause first" \
  "edit agents/ci-failure-diagnoser.md -e 's|list the candidates, product first|list the candidates|'"
expect_failure "defect routing missing from an agent" "agents/qa-lead.md: does not contain the block from templates/defect-routing.md" \
  "edit agents/qa-lead.md -e 's|^5[.] [*][*]Inconclusive:[*][*]|5. Other:|'"
expect_failure "defect routing changed in one file only" "skills/bug-ticket/SKILL.md: does not contain the block from templates/defect-routing.md" \
  "edit skills/bug-ticket/SKILL.md -e 's|or the .bug-ticket. skill, and let the user choose|or file it|'"
expect_failure "defect-routing.md missing" "templates/defect-routing.md missing or empty" \
  "rm templates/defect-routing.md"
expect_failure "inconclusive that may still be filed" "agents/flaky-test-triager.md: does not contain the block from templates/defect-routing.md" \
  "edit agents/flaky-test-triager.md -e 's|Do not file a bug and do not record the test as known flaky until one is confirmed.||'"
expect_failure "diagnoser that routes on its own" "must route each cause with Defect routing" \
  "edit agents/ci-failure-diagnoser.md -e 's|Recommend the next step for each cause with Defect routing|Recommend a ticket|'"
expect_failure "triager output without the routing action" "must give the Defect routing action for a defect" \
  "edit agents/flaky-test-triager.md -e 's|the Defect routing step; name the file and commit when a change caused it|a ticket|'"
expect_failure "lead that routes defects on its own" "must route defects with Defect routing" \
  "edit agents/qa-lead.md -e 's|For a defect, offer the step from Defect routing|For a defect, offer bug-ticket|'"
expect_failure "bug-ticket that files anything" "must file only what Defect routing sends to it" \
  "edit skills/bug-ticket/SKILL.md -e 's|File only what Defect routing sends here|File anything|'"
expect_failure "test-developer that files failing requirements directly" "must route a failing requirement with Defect routing" \
  "edit skills/test-developer/SKILL.md -e 's|report it as a possible defect and route it with Defect routing|file it|'"
expect_failure "triager that only says regression" "must route regressions and product defects with Defect routing" \
  "edit agents/flaky-test-triager.md -e 's|route it with Defect routing[.]|file it.|g'"
expect_failure "route changed in the template and every copy" "templates/defect-routing.md must let the user choose how to handle a merged regression" \
  "for f in templates/defect-routing.md agents/ci-failure-diagnoser.md agents/flaky-test-triager.md agents/qa-lead.md skills/bug-ticket/SKILL.md skills/test-developer/SKILL.md; do edit \"\$f\" -e 's|or the .bug-ticket. skill, and let the user choose|or the bug-ticket skill|'; done"
expect_failure "quarantine rule dropped everywhere" "templates/defect-routing.md must forbid quarantining a test that catches a real bug" \
  "for f in templates/defect-routing.md agents/ci-failure-diagnoser.md agents/flaky-test-triager.md agents/qa-lead.md skills/bug-ticket/SKILL.md skills/test-developer/SKILL.md; do edit \"\$f\" -e '/^Never quarantine a test that catches a real bug[.]\$/d'; done"
expect_failure "another entry with a stale routing section" "skills/pr-description/SKILL.md: does not contain the block from templates/defect-routing.md" \
  "printf '\\n## Defect routing\\n\\nFile everything.\\n' >> skills/pr-description/SKILL.md"
expect_failure "routes without an order" "templates/defect-routing.md must say which route wins when several fit" \
  "for f in templates/defect-routing.md agents/ci-failure-diagnoser.md agents/flaky-test-triager.md agents/qa-lead.md skills/bug-ticket/SKILL.md skills/test-developer/SKILL.md; do edit \"\$f\" -e 's|take the first case that fits|pick a case|'; done"
expect_failure "no route for a stale test" "templates/defect-routing.md must route test defects where the product is correct" \
  "for f in templates/defect-routing.md agents/ci-failure-diagnoser.md agents/flaky-test-triager.md agents/qa-lead.md skills/bug-ticket/SKILL.md skills/test-developer/SKILL.md; do edit \"\$f\" -e 's|[*][*]Test defect, product correct[*][*]|Other|'; done"
expect_failure "CLAUDE template bug row too broad" "templates/CLAUDE.md bug-ticket row must match Defect routing" \
  "edit templates/CLAUDE.md -e 's|File a bug for a confirmed pre-existing product defect with no identifiable commit|File a bug from a failure|'"
expect_failure "triage verdicts that cannot reach config" "templates/defect-routing.md must let a triage verdict reach every other case" \
  "for f in templates/defect-routing.md agents/ci-failure-diagnoser.md agents/flaky-test-triager.md agents/qa-lead.md skills/bug-ticket/SKILL.md skills/test-developer/SKILL.md; do edit \"\$f\" -e 's|case 1, 2, 3 or 5|case 2, 3 or 5|'; done"
expect_failure "intermittent failures sent straight to a test fix" "templates/defect-routing.md must not send intermittent failures straight to a test fix" \
  "for f in templates/defect-routing.md agents/ci-failure-diagnoser.md agents/flaky-test-triager.md agents/qa-lead.md skills/bug-ticket/SKILL.md skills/test-developer/SKILL.md; do edit \"\$f\" -e 's|; an intermittent failure reaches this case only through case 4||'; done"
expect_failure "triager confirming regressions by guess" "must not treat an unconfirmed regression as a product defect" \
  "edit agents/flaky-test-triager.md -e 's| Never route an unconfirmed regression to case 3[.]||'"
expect_failure "triager without an environment verdict" "must route environment causes to case 1" \
  "edit agents/flaky-test-triager.md -e 's|(verdict: environment or pipeline config); route it with Defect routing (case 1)|(verdict: inconclusive)|'"
expect_failure "triager that quarantines freely" "must allow quarantine only as a stopgap for genuinely flaky tests" \
  "edit agents/flaky-test-triager.md -e 's|for a genuinely flaky test only, quarantine/non-blocking as a stopgap|quarantine|'"
expect_failure "diagnoser sending consistent timeouts to the triager" "must route consistent timeouts without the triager" \
  "edit agents/ci-failure-diagnoser.md -e 's| If it fails consistently rather than intermittently, it is not a case for the triager: use case 1 when a config cause is identified, case 2 when the test.s own code is the cause, otherwise case 5[.]||'"
expect_failure "unconfirmed defect sent to case 3" "templates/defect-routing.md must not send an unconfirmed defect to case 3" \
  "for f in templates/defect-routing.md agents/ci-failure-diagnoser.md agents/flaky-test-triager.md agents/qa-lead.md skills/bug-ticket/SKILL.md skills/test-developer/SKILL.md; do edit \"\$f\" -e 's|it is case 3 once the product defect is confirmed, and case 5 until then|it is case 3|'; done"
expect_failure "consistent failures sent to triage" "templates/defect-routing.md must route consistent failures without triage" \
  "for f in templates/defect-routing.md agents/ci-failure-diagnoser.md agents/flaky-test-triager.md agents/qa-lead.md skills/bug-ticket/SKILL.md skills/test-developer/SKILL.md; do edit \"\$f\" -e 's| A consistent failure skips triage: take case 1, 2 or 5, or case 3 once the product defect is confirmed[.]||'; done"
expect_failure "diagnoser sends a test's own consistent failure to case 5" "must route a consistent failure caused by the test to case 2" \
  "edit agents/ci-failure-diagnoser.md -e 's|case 2 when the test.s own code is the cause, otherwise case 5|otherwise case 5|'"
expect_failure "triager without a stale-test verdict" "must have a verdict for a stale test" \
  "edit agents/flaky-test-triager.md -e 's| (verdict: test defect, stale after an intended change)||'"
expect_failure "verdicts without routing cases" "must map every verdict to a routing case" \
  "edit agents/flaky-test-triager.md -e 's|/ inconclusive \\[case 5\\]|/ inconclusive|'"
expect_failure "flaky verdict without ruling out the product" "must rule out the product before calling a test genuinely flaky" \
  "edit agents/flaky-test-triager.md -e 's|cause identified in the test and product ruled out (case 2)|cause identified (case 2)|'"
expect_failure "safety rule that allows credential blocks" "templates/safety.md must forbid quoting credential blocks from build files" \
  "edit templates/safety.md -e 's|Never quote server, repository, distribution or credential blocks|Quote what you need|'"
expect_failure "safety rule that reads settings.xml" "templates/safety.md must forbid reading Maven settings and gradle.properties" \
  "edit templates/safety.md -e 's|Maven .settings.xml. or .settings-security.xml., .gradle.properties. or other|or other|'"
expect_failure "project settings.xml readable" "settings.example.json misses deny rules: Read(**/settings.xml)" \
  "edit settings.example.json -e '/\"Read(\\*\\*\\/settings.xml)\",/d'"
expect_failure "safety rule that quotes anything not forbidden" "templates/safety.md must quote only allow-listed build-file values" \
  "edit templates/safety.md -e 's|quote only what this list allows[.] For anything else, name the element, property or key and write .<redacted>.|quote freely|'"
expect_failure "safety rule that quotes credentials in URLs" "templates/safety.md must forbid quoting credentials inside URLs and arguments" \
  "edit templates/safety.md -e 's|, or a URL, connection string or command-line argument that contains a credential|.|'"
expect_failure "safety rule that quotes variable values" "templates/safety.md must allow variable names but not their values" \
  "edit templates/safety.md -e 's|names, not values, of environment variables and properties|environment variables and properties|'"
expect_failure "mapper that reads Maven settings" "must skip Maven settings and gradle.properties by name" \
  "edit skills/framework-map/SKILL.md -e 's|.settings.xml., .settings-security.xml., .gradle.properties., ..npmrc. and ..netrc.|.npmrc|'"
expect_failure "mapper that reads build files freely" "must read build files only as Safety allows" \
  "edit skills/framework-map/SKILL.md -e 's|From build files use only what Safety allows|From build files use anything|'"
expect_failure "diagnoser that guesses versions" "must not guess versions it may not read" \
  "edit agents/ci-failure-diagnoser.md -e 's|take the resolved version from the build log|guess the version|'"
expect_failure "Maven master password readable" "settings.example.json misses deny rules: Read(~/.m2/settings-security.xml)" \
  "edit settings.example.json -e '/settings-security[.]xml/d'"
expect_failure "safety rule that quotes argLine freely" "templates/safety.md must redact JVM -D pairs by default" \
  "edit templates/safety.md -e 's|; write every other .-D. pair as .-Dname=<redacted>.||'"
expect_failure "open-ended JVM settings list" "templates/safety.md must allow only a closed list of JVM settings" \
  "edit templates/safety.md -e 's|[.] Other standard JDK settings|, and other standard JDK settings|'"
expect_failure "JVM flags quoted wholesale" "templates/safety.md must quote only on/off and numeric JVM flags" \
  "edit templates/safety.md -e 's|.-XX. flags that only switch something on or off or set a number|any flag|'"
expect_failure "profile activation values quoted" "templates/safety.md must redact profile activation values" \
  "edit templates/safety.md -e 's|; for a .<property>. activation keep its .<name>. and write its .<value>. as .<redacted>.||'"
expect_failure "suite files outside the rule" "templates/safety.md must cover test suite files" \
  "edit templates/safety.md -e 's| and TestNG suite files (.testng[*].xml. or any XML with a .<suite>. root)||'"
expect_failure "JVM list only inside argLine" "templates/safety.md must apply the JVM list wherever the key appears" \
  "edit templates/safety.md -e 's|, wherever they appear (.argLine., .jvmArgs., .systemPropertyVariables., .jvm.config., .maven.config.)||'"
expect_failure "README calls the JVM list open" "README.md must describe the closed JVM list" \
  "edit README.md -e 's|the five JVM settings the rule names|standard JVM settings|'"
expect_failure "suite file parameters quoted" "templates/safety.md must redact suite file parameter values" \
  "edit templates/safety.md -e 's|; .<parameter>. values in suite files are redacted like any other value, for example .<parameter name=\"password\" value=\"<redacted>\"/>.||'"
expect_failure "Gradle settings outside the rule" "templates/safety.md must cover Gradle settings and version catalogs" \
  "edit templates/safety.md -e 's|.settings.gradle., .settings.gradle.kts., .gradle/libs.versions.toml., ||'"
expect_failure "maven.config -D pairs quoted" "templates/safety.md must redact -D pairs in Maven config files" \
  "edit templates/safety.md -e 's|JVM and Maven command options (.argLine., .jvmArgs., .[.]mvn/jvm.config., .[.]mvn/maven.config.)|JVM options (argLine)|'"
expect_failure "build script literals quoted" "templates/safety.md must redact string literals in build scripts" \
  "edit templates/safety.md -e 's| This includes string literals and variable assignments in build scripts (.val token = \"<redacted>\".)[.]||'"
expect_failure "free-text names quoted" "templates/safety.md must quote names only when they look like identifiers" \
  "edit templates/safety.md -e 's|quoted only when they look like identifiers|quoted|'"
expect_failure "project settings-security.xml readable" "settings.example.json misses deny rules: Read(**/settings-security.xml)" \
  "edit settings.example.json -e '/[*][*]\\/settings-security[.]xml/d'"
expect_failure "README with a partial allow-list" "README.md must point to the full build-file allow-list" \
  "edit README.md -e 's|quotes only what the allow-list in .templates/safety.md. permits|quotes only|'"
expect_failure "README promising a byte-identical merge" "README.md must say the settings merge rewrites the file" \
  "edit README.md -e 's| The file is rewritten as JSON, so its values stay the same but number spelling, escapes and line endings can change[.]||'"
expect_failure "safety rule that hides versions again" "templates/safety.md must allow the build-file details diagnosis needs" \
  "edit templates/safety.md -e 's|dependency, plugin and parent coordinates, and the Java release|dependency names|'"
expect_failure "version element quoted without a shape check" "templates/safety.md must shape-check every version value" \
  "edit templates/safety.md -e 's|version values (a .<version>. element, a .version =. setting, or a property whose name ends in .version.|version properties (|'"
expect_failure "undefined version range" "templates/safety.md must define a version range" \
  "edit templates/safety.md -e 's|a range that contains .\\[., .(., .,. or .[*]. and only digits, dots, commas, spaces|a range of digits, dots, commas, spaces|'"
expect_failure "odd version values quoted" "templates/safety.md must redact version values that do not look like versions" \
  "edit templates/safety.md -e 's| Write any other version value as .<redacted>.[.]||'"
expect_failure "open-ended version qualifiers" "templates/safety.md must allow only a closed list of version qualifiers" \
  "edit templates/safety.md -e 's|optionally followed by exactly one of|optionally followed by a qualifier such as|'"
expect_failure "digits-only versions quoted" "templates/safety.md must redact digits-only versions" \
  "edit templates/safety.md -e 's| a value of digits only is not a version and is .<redacted>.[;]||'"
expect_failure "credential-looking names undefined" "templates/safety.md must say what a credential-looking name is" \
  "edit templates/safety.md -e 's| (a known token prefix such as .ghp_., .github_pat_., .glpat-., .AKIA. or .xox., or a long run of mixed letters and digits)||'"
expect_failure "reviewer that assumes main" "agents/pr-reviewer.md must take the base branch from the PR, not assume main" \
  "edit agents/pr-reviewer.md -e 's|never assume .main.|use main|'"
expect_failure "reviewer without a default-branch fallback" "agents/pr-reviewer.md must fall back to the repo's default branch" \
  "edit agents/pr-reviewer.md -e 's|git symbolic-ref --short refs/remotes/origin/HEAD|origin/main|'"
expect_failure "reviewer that guesses the base" "agents/pr-reviewer.md must ask when the base branch is unknown" \
  "edit agents/pr-reviewer.md -e 's|stop and return a one-line request for the base branch|use main|'"
expect_failure "reviewer that may change git state silently" "agents/pr-reviewer.md must state that git fetch is the only allowed git write" \
  "edit agents/pr-reviewer.md -e 's|The one allowed exception is the .git fetch. in Phase 1, in exactly the form|Fetching is fine, for example|'"
expect_failure "reviewer that hides its base" "agents/pr-reviewer.md must report the base branch" \
  "edit agents/pr-reviewer.md -e 's|name the base branch and how you found it|review the diff|'"
expect_failure "PR description that assumes main" "skills/pr-description/SKILL.md must take the target branch from the PR, not assume main" \
  "edit skills/pr-description/SKILL.md -e 's|never assume .main.|use main|'"
expect_failure "reviewer with a double origin prefix" "agents/pr-reviewer.md must strip origin/ from the default branch" \
  "edit agents/pr-reviewer.md -e 's|prints .origin/develop., so .<base>. is .develop.|gives the base|'"
expect_failure "reviewer with any fetch form" "agents/pr-reviewer.md must restrict the fetch form" \
  "edit agents/pr-reviewer.md -e 's|Never add .--all., .--prune., .--force. or a .+. refspec, and never|Never|'"
expect_failure "reviewer without an ADO base lookup" "agents/pr-reviewer.md must name the Azure DevOps target branch command" \
  "edit agents/pr-reviewer.md -e 's|.targetRefName. without .refs/heads/.|the target|'"
expect_failure "reviewer ignoring forks" "agents/pr-reviewer.md must handle PRs from forks" \
  "edit agents/pr-reviewer.md -e 's|use that remote instead of .origin. below|use origin|'"
expect_failure "PR description with a double origin prefix" "skills/pr-description/SKILL.md must strip origin/ from the default branch" \
  "edit skills/pr-description/SKILL.md -e 's|prints .origin/develop., so .<target>. is .develop.|gives the target|'"
expect_failure "PR description without the default-branch fallback" "skills/pr-description/SKILL.md must fall back to the repo's default branch" \
  "edit skills/pr-description/SKILL.md -e 's|git symbolic-ref --short refs/remotes/origin/HEAD|origin/main|'"
expect_failure "PR description on a stale base" "skills/pr-description/SKILL.md must refresh the base before diffing" \
  "edit skills/pr-description/SKILL.md -e 's|Run .git fetch <remote> <target>:refs/remotes/<remote>/<target>. first; if that fails, say the base may be out of date[.] ||'"
expect_failure "reviewer fetching two refspecs at once" "agents/pr-reviewer.md must fetch PR branches in the allowed form" \
  "edit agents/pr-reviewer.md -e 's|fetch each branch with its own command, in the form the Rules allow|fetch both branches|'"
expect_failure "reviewer without a GitHub base lookup" "agents/pr-reviewer.md must name the GitHub target branch command" \
  "edit agents/pr-reviewer.md -e 's|.gh pr view --json baseRefName -q .baseRefName.|gh|'"
expect_failure "reviewer reading glab text output" "agents/pr-reviewer.md must name the GitLab target branch command" \
  "edit agents/pr-reviewer.md -e 's|.glab mr view -F json. (the .target_branch. field)|glab mr view|'"
expect_failure "reviewer stuck on a detached HEAD" "agents/pr-reviewer.md must handle a detached HEAD" \
  "edit agents/pr-reviewer.md -e 's| On a detached HEAD there is no branch to look up, so go to step 2[.]||'"
expect_failure "reviewer stuck when a branch has no PR" "agents/pr-reviewer.md must fall through when no PR/MR exists" \
  "edit agents/pr-reviewer.md -e 's|reports that no pull request or merge request exists for the branch|fails|'"
expect_failure "PR description stuck when a branch has no PR" "skills/pr-description/SKILL.md must fall through when no PR/MR exists" \
  "edit skills/pr-description/SKILL.md -e 's|reports that no PR/MR exists for the branch means there is none|fails means stop|'"
expect_failure "reviewer guessing after a lookup error" "agents/pr-reviewer.md must not guess the base after a lookup error" \
  "edit agents/pr-reviewer.md -e 's|means the PR target is unknown, so do not fall back to the default branch: go to step 3|is fine: say so and go to step 2|'"
expect_failure "reviewer fetching a fork PR from origin" "agents/pr-reviewer.md must use the platform diff for fork PRs" \
  "edit agents/pr-reviewer.md -e 's|For a PR from a fork, use \"Read a PR/MR\" instead|For a fork PR, fetch from origin|'"
expect_failure "PR description guessing after a lookup error" "skills/pr-description/SKILL.md must not guess the target after a lookup error" \
  "edit skills/pr-description/SKILL.md -e 's|; any other lookup error means the target is unknown, so ask||'"
expect_failure "symbolic-ref allowed in a writing form" "allows a git symbolic-ref form that can write refs" \
  "edit settings.example.json -e 's|\"Bash(git symbolic-ref --short refs/remotes/origin/HEAD)\"|\"Bash(git symbolic-ref --short refs/remotes/origin/HEAD)\", \"Bash(git symbolic-ref *)\"|'"
expect_failure "symbolic-ref not allowed" "settings.example.json must allow Bash(git symbolic-ref" \
  "edit settings.example.json -e '/git symbolic-ref --short refs.remotes.origin.HEAD/d'"
expect_failure "fetch options not denied" "settings.example.json misses deny rules: Bash(git fetch *--*)" \
  "edit settings.example.json -e '/git fetch [*]--[*]/d'"
expect_failure "fetch force refspec not denied" "settings.example.json misses deny rules: Bash(git fetch *+*)" \
  "edit settings.example.json -e '/git fetch [*][+][*]/d'"
expect_failure "reviewer reading the head owner as the base" "agents/pr-reviewer.md must find a fork's base repository from the PR URL" \
  "edit agents/pr-reviewer.md -e 's|.gh pr view --json url,isCrossRepository.|gh pr view --json headRepositoryOwner|'"
expect_failure "reviewer expecting a diff from az repos pr show" "agents/pr-reviewer.md must not expect a diff from az repos pr show" \
  "edit agents/pr-reviewer.md -e 's|; for Azure DevOps the diff comes from the MCP or the local fetch below||'"
expect_failure "short fetch options not denied" "settings.example.json misses deny rules: Bash(git fetch * -*)" \
  "edit settings.example.json -e '/git fetch [*] -[*]/d'"
expect_failure "leading fetch options not denied" "settings.example.json misses deny rules: Bash(git fetch -*)" \
  "edit settings.example.json -e '/\"Bash(git fetch -[*])\"/d'"
expect_failure "PR description fetching a fork base from origin" "skills/pr-description/SKILL.md must handle PRs from forks" \
  "edit skills/pr-description/SKILL.md -e 's|unless the PR comes from a fork whose base repository is another remote|always|'"
expect_failure "PR description without lookup commands" "skills/pr-description/SKILL.md must name the per-platform target lookups" \
  "edit skills/pr-description/SKILL.md -e 's|.glab mr view -F json. (.target_branch.)|glab|'"
expect_failure "PR description without a GitHub lookup" "skills/pr-description/SKILL.md must name the GitHub target lookup" \
  "edit skills/pr-description/SKILL.md -e 's|GitHub .gh pr view --json baseRefName -q .baseRefName.|GitHub gh|'"
expect_failure "PR description without an ADO lookup" "skills/pr-description/SKILL.md must name the Azure DevOps target lookup" \
  "edit skills/pr-description/SKILL.md -e 's|.az repos pr list --source-branch <branch> --status active --query \"\[0\][.]targetRefName\" -o tsv.|az|'"
expect_failure "PR description without a fork base lookup" "skills/pr-description/SKILL.md must say how to find a fork's base repository" \
  "edit skills/pr-description/SKILL.md -e 's|GitHub .gh pr view --json url,isCrossRepository.|GitHub|'"
expect_failure "reviewer without the set-head hint" "agents/pr-reviewer.md must say how to set a missing origin/HEAD" \
  "edit agents/pr-reviewer.md -e 's| If .origin/HEAD. is just not set, say that .git remote set-head origin -a. sets it[.]||'"
expect_failure "git remote -v not allowed" "settings.example.json must allow Bash(git remote -v)" \
  "edit settings.example.json -e '/\"Bash(git remote -v)\"/d'"
expect_failure "git remote allowed in a changing form" "allows a git remote form that can change remotes" \
  "edit settings.example.json -e 's|\"Bash(git remote -v)\"|\"Bash(git remote -v)\", \"Bash(git remote *)\"|'"
expect_failure "a pin removed without updating the count" "tests/pin-count says 140, but this script defines 139 pins" \
  "echo 140 > tests/pin-count"
expect_failure "pin count file missing" "tests/pin-count says nothing" \
  "rm tests/pin-count"
expect_failure "personal entry in the QA repo" "unknown group 'personal'" \
  "edit catalog.tsv -e 's/^pr-reviewer\tagent\tqa/pr-reviewer\tagent\tpersonal/'"
expect_failure "machine path in settings.example.json" "settings.example.json contains a machine-specific /Users/ path" \
  "edit settings.example.json -e 's|\"permissions\"|\"x\": \"/Users/me\", \"permissions\"|'"
expect_failure "third-party skill that differs from the lock" "skills/vendored differs from third-party.lock" \
  "cp -R skills/bug-ticket skills/vendored && edit skills/vendored/SKILL.md -e 's/^name: bug-ticket/name: vendored/' && printf 'vendored\tskill\tthird-party\thttps://example.com\n' >> catalog.tsv && printf '%s\n' '\`vendored\`' >> README.md && printf 'vendored\t0000\n' > third-party.lock"
expect_failure "third-party entry without a lock file" "third-party.lock missing" \
  "cp -R skills/bug-ticket skills/vendored && edit skills/vendored/SKILL.md -e 's/^name: bug-ticket/name: vendored/' && printf 'vendored\tskill\tthird-party\thttps://example.com\n' >> catalog.tsv && printf '%s\n' '\`vendored\`' >> README.md"

echo "every pinned phrase"
# Each phrase pinned in validate.sh is deleted, one at a time, in a copy of the repo; validate.sh must then fail with
# that pin's message. New pins are covered automatically.
dump_rc=0
QA_DUMP_PINS=1 "$REPO/tests/validate.sh" "$REPO" >"$TMP/pins.json" || dump_rc=$?
# Deletes pin number $1 (from $TMP/pins.json) from its file in the current directory. Called from eval'd mutations.
# shellcheck disable=SC2317,SC2329
drop_pin() {
  python3 - "$TMP/pins.json" "$1" <<'DROP'
import json, sys
path, phrase, _ = json.load(open(sys.argv[1]))[int(sys.argv[2])]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace(phrase, ""))
DROP
}
n_pins=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$TMP/pins.json" 2>/dev/null || echo 0)
# A failed or changed dump must fail here, not pass by checking fewer pins. tests/pin-count is the exact count.
expected_pins="$(tr -d '[:space:]' <"$REPO/tests/pin-count")"
if [[ $dump_rc -ne 0 || "$n_pins" != "$expected_pins" ]]; then
  echo "  FAIL  pin dump failed or lists $n_pins pins (tests/pin-count says $expected_pins)"
  fail=1
fi
assert_pins=0
for ((i = 0; i < n_pins; i++)); do
  expected=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[int(sys.argv[2])][2])' "$TMP/pins.json" "$i")
  expect_failure "pin $i: $expected" "$expected" "drop_pin $i"
  assert_pins=$((assert_pins + 1))
done
echo "  checked $assert_pins pinned phrases"

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
