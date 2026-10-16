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
  "edit agents/flaky-test-triager.md -e 's|^- [*][*]Intermittent product defect (confirmed):[*][*]|- Other:|'"
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
  "edit agents/flaky-test-triager.md -e 's|genuinely flaky (test) / intermittent product defect (confirmed) /|genuinely flaky (test) /|'"
expect_failure "triager that quarantines real bugs" "must not quarantine a test that catches a real bug" \
  "edit agents/flaky-test-triager.md -e 's|do not quarantine a test that catches a real bug|quarantine it|'"
expect_failure "triager that lists product defects as known flaky" "must not add product defects to known-flaky-tests.md" \
  "edit agents/flaky-test-triager.md -e 's|never for an intermittent product defect or a likely regression|always|'"
expect_failure "triager without a confirmed/inconclusive rule" "must say when a product defect is confirmed versus inconclusive" \
  "edit agents/flaky-test-triager.md -e 's|Use intermittent product defect only when the product cause is confirmed|Decide|'"
expect_failure "agent rules on an emptied file" "agents/flaky-test-triager.md must recognise intermittent product defects" \
  "awk 'NR==1 || f<2 {print} /^---\$/{f++}' agents/flaky-test-triager.md > x.tmp && mv x.tmp agents/flaky-test-triager.md"
expect_failure "diagnoser that files a ticket for its own PR's bug" "must send a defect from the change under test back to its branch" \
  "edit agents/ci-failure-diagnoser.md -e 's|For a code or product defect from this change, recommend fixing it on the branch that introduced it|Recommend a ticket|'"
expect_failure "README trace with an old label" "trace example must use the diagnoser's suspected-flaky label" \
  "edit README.md -e 's|suspected flaky/environment (product not ruled out)|flaky/environment|'"
expect_failure "agent file missing" "agents/flaky-test-triager.md must recognise intermittent product defects" \
  "rm agents/flaky-test-triager.md"
expect_failure "triager that tickets its own PR's regression" "must send a regression from the change under test back to its branch" \
  "edit agents/flaky-test-triager.md -e 's|If one of those commits is in the change under test, recommend fixing it on that branch|Suggest a ticket|'"
expect_failure "lead that tickets its own PR's bug" "agents/qa-lead.md must route a defect from the change under test to a branch fix" \
  "edit agents/qa-lead.md -e 's|If it is a code or product defect from the change under test, offer the fix on the branch that introduced it|Offer bug-ticket|'"
expect_failure "README plan example filing any defect" "README.md plan example must file bugs only for confirmed product defects or shared-branch regressions" \
  "edit README.md -e 's|for a pre-existing confirmed product defect, or a regression on a shared branch if the user chooses it|only if it is a real defect|'"
expect_failure "lead without the merged-change route" "must cover a defect whose change is already merged" \
  "edit agents/qa-lead.md -e 's|if that change is already merged into a shared branch|if not|'"
expect_failure "bug-ticket that dismisses intermittent failures" "must not dismiss intermittent failures as non-bugs" \
  "edit skills/bug-ticket/SKILL.md -e 's|An intermittent failure can still be a product defect|A flaky test is not a bug|'"
expect_failure "README without the product-defect verdict" "must describe the triager's product-defect verdict" \
  "edit README.md -e 's|an intermittent product defect (such as a race condition)|a regression|'"
expect_failure "diagnoser description with the old classes" "description must list the product-defect and suspected-flaky classes" \
  "edit agents/ci-failure-diagnoser.md -e 's|product defect (confirmed), suspected flaky/environment|flaky/environment|'"
expect_failure "triager description without product defects" "description must name the product-defect verdict" \
  "edit agents/flaky-test-triager.md -e 's|an intermittent product defect (for example a race condition) or a regression|or a regression|'"
expect_failure "triager without a regression action" "must give an action for a regression" \
  "edit agents/flaky-test-triager.md -e 's|^  - regression: fix on the branch that introduced it|  - other|'"
expect_failure "triager that tickets its own PR's race" "must send a product defect from the change under test back to its branch" \
  "edit agents/flaky-test-triager.md -e 's|If the change under test introduced it, recommend fixing it on that branch|File it|'"
expect_failure "triager output without the branch-fix action" "must give a branch-fix action for a product defect from the change under test" \
  "edit agents/flaky-test-triager.md -e 's|^  - product defect from the change under test: fix on that branch|  - other|'"
expect_failure "diagnoser that tickets this change's product defect" "must file only pre-existing product defects" \
  "edit agents/ci-failure-diagnoser.md -e 's|For a pre-existing confirmed product defect, recommend|For a confirmed product defect, recommend|'"
expect_failure "diagnoser listing the product cause last" "must list the product cause first" \
  "edit agents/ci-failure-diagnoser.md -e 's|list the candidates, product first|list the candidates|'"
expect_failure "lead that tickets this change's product defect" "must offer bug-ticket only for pre-existing product defects" \
  "edit agents/qa-lead.md -e 's|If it is a pre-existing confirmed product defect, offer|If it is a confirmed product defect, offer|'"
expect_failure "bug-ticket that files this change's defect" "must not file a defect from the change under test" \
  "edit skills/bug-ticket/SKILL.md -e 's|a defect from the change under test goes back to its branch instead|any defect can be filed|'"
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
