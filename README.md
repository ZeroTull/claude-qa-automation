# claude-qa-automation

[Claude Code](https://claude.com/claude-code) and [GitHub Copilot](https://github.com/features/copilot) agents and skills for QA test automation: writing UI and API tests from requirements, reviewing PRs, diagnosing CI failures, triaging flaky tests, and drafting test cases, bugs and PR descriptions. Works with Jira (Cloud and Data Center, Zephyr Scale), Azure DevOps, GitLab and GitHub, on Java test projects (TestNG/JUnit, Cucumber, Rest-Assured, Selenium/Selenide/Playwright).

This repo is self-contained and doesn't need any other setup. It never touches your global `~/.claude/CLAUDE.md`, and it changes `~/.claude/settings.json` only when you run `--settings`, and only to add deny rules after a backup. So it can sit next to a personal Claude Code configuration. If another setup already links an agent or skill with the same name, this install backs that link up and replaces it, and `--uninstall` puts it back.

## Install

Requirements: Claude Code or GitHub Copilot, `bash` and `python3`. `git` is optional: you can also download the repo as a ZIP (**Code > Download ZIP**), unzip it somewhere permanent and run `bash install.sh` there.

```bash
git clone https://github.com/ZeroTull/claude-qa-automation.git ~/projects/claude-qa-automation
cd ~/projects/claude-qa-automation
./install.sh             # link the agents and skills into ~/.claude
./install.sh --settings  # add the secret deny rules to ~/.claude/settings.json
```

- **What `./install.sh` does:** it links each agent and skill into `~/.claude`, so `git pull` here updates them. Anything it replaces (a file, a broken link, or a link from another setup) is moved to `~/.claude/backups/qa-<timestamp>-NNN/` first. It refuses to run if `~/.claude/agents` or `~/.claude/skills` is itself a link. At the end it reports whether your settings lack the secret deny rules and which optional tools are missing.
- **What `--settings` does:** it adds only the missing deny rules and backs up your settings first. It stops without changes if `settings.json` isn't valid JSON or has an unexpected shape. If your `settings.json` is a link into another repo, it doesn't write through the link: it lists the rules to add in that repo instead.
- **Uninstall:** `./install.sh --uninstall` removes the links and puts back what they replaced.

Restart Claude Code afterwards, then check with `/agents` and by typing `/`.

### Using it with GitHub Copilot (VS Code or IntelliJ)

```bash
./install.sh --copilot
```

This installs into `~/.copilot` and doesn't touch `~/.claude`.

- **Where Copilot finds the files:**
  - VS Code reads personal agents from `~/.copilot/agents` and personal skills from `~/.copilot/skills` ([custom agents](https://code.visualstudio.com/docs/copilot/customization/custom-agents), [agent skills](https://code.visualstudio.com/docs/copilot/customization/agent-skills)).
  - Copilot for JetBrains IDEs reads global agents from `~/.copilot/agents` ([changelog, May 2026](https://github.blog/changelog/2026-05-14-introducing-copilot-cli-agent-and-unified-sessions-view-in-github-copilot-for-jetbrains-ides/)).
  - `~/.copilot/skills` is GitHub's documented personal skills folder ([customization cheat sheet](https://docs.github.com/en/copilot/reference/customization-cheat-sheet)), but no JetBrains-specific source confirms it yet. If the skills don't show up in IntelliJ, that's the likely reason.
- **Skills** are linked unchanged, because Copilot uses the same `SKILL.md` format. Type `/` in Copilot Chat to run one, such as `/test-developer`.
- **Agents** are converted into Copilot's `.agent.md` format. Pick one in the Copilot Chat agent picker.
  - The tools list leaves out the edit tool: `read`, `search`, `execute`, `web`, `todo` ([tool aliases](https://docs.github.com/en/copilot/reference/custom-agents-configuration)). `execute` still runs shell commands, so, as with Claude Code, read-only is a rule in the agents' instructions, not something Copilot enforces.
  - The `model` and `color` fields are dropped (you pick the model in Copilot), and the instructions are unchanged.
  - The agents are generated copies: after `git pull` (or a fresh ZIP) run `./install.sh --copilot` again. That also replaces any local edits to them.
- **MCP servers:** if you added MCP servers to Copilot, such as the Atlassian (Jira Cloud) or Azure DevOps server, name them so the agents may use them: `COPILOT_MCP_SERVERS="atlassian azure-devops" ./install.sh --copilot`. The names must match your Copilot MCP configuration. `<server>/*` grants all of that server's tools, including any that write. Without MCP servers, the agents use `jira`, `glab`, `gh` and `az` in the terminal.
- **IntelliJ:** custom agents and agent skills are in preview in Copilot for JetBrains. Turn them on in **Settings > GitHub Copilot > Chat > Agent**. On Copilot Business or Enterprise, an administrator must also enable the **Editor preview features** policy ([changelog, February 2026](https://github.blog/changelog/2026-02-13-new-features-and-improvements-in-github-copilot-in-jetbrains-ides-2)).
- **Not for Copilot:** `--settings`, because Copilot doesn't use Claude Code's deny rules. The safety rules written into every agent and skill still apply, and Copilot's own settings decide which terminal commands need your confirmation.
- **Uninstall:** `./install.sh --copilot --uninstall` removes the generated agents and skill links and restores what they replaced.
- **With Claude Code installed too, in VS Code:** use the plain `./install.sh`. VS Code also reads `~/.claude/skills` and `~/.claude/agents`, so installing into both folders would list each skill twice, and likely each agent too.

### Install into a team repo

```bash
./install.sh --project ~/path/to/work-repo
```

This copies the agents and skills into `<repo>/.claude/`. It also adds `.claude/settings.json` (the deny rules) and a `CLAUDE.md` (from `templates/CLAUDE.md`) if they don't exist yet. Commit the result and the whole team gets the same agents.

To update later, run `git pull` here, then `./install.sh --project <repo> --update`. It replaces the entries whose content changed, including local edits, and never touches the team's settings or `CLAUDE.md`.

Then, in the work repo, start `claude` and run `/qa-conventions`.

## Agents and skills

**Agents** run in a separate context and return a report. They don't change anything: Claude Code disables their file-editing tools, and their instructions limit the shell to read-only commands. Claude picks one from your request, or you can name it ("use the pr-reviewer agent").

| Agent | Use it for |
|---|---|
| `pr-reviewer` | Review a Java PR or MR (Azure DevOps, GitHub or GitLab): correctness, conventions, performance, security, concurrency, tests. Missing tests for changed behavior block approval. Findings with severity, confidence and a fix plan. |
| `test-maintainer` | Audit a test framework for flakiness, duplication, weak assertions, dead code, slow setup, test-layer balance, contract/performance testing and CI quality gates. Gives a health report and an improvement plan. |
| `ci-failure-diagnoser` | Find the root cause of a failed pipeline run (Azure Pipelines, GitHub Actions or GitLab CI), with log evidence. |
| `flaky-test-triager` | Decide whether an intermittent failure is flaky or a real regression, based on run history. |
| `senior-automation-qa-engineer` | Test strategy and framework design: which test layers to invest in, a new automation framework, contract, performance and E2E strategy. |

**Skills** run in your conversation, so they can ask questions and wait for approval at each step. Start one with a slash command, or describe the task.

| Skill | Use it for |
|---|---|
| `/qa-conventions` | **Run first in each repo.** Builds `.ai/context/conventions.md` (tracker fields for Jira/ADO/GitLab/GitHub, severity scale, PR template, test naming, sensitive-data rules) from what the team already has. |
| `/test-developer` | Write missing automated tests from a text file, Excel, Confluence page, Jira issue or ADO/GitLab/GitHub work item. Checks existing coverage, proposes a plan, writes approved tests, and runs them with an approved fix loop (max 5 attempts). |
| `/test-cases` | Test cases from a Jira issue or ADO work item, with a coverage map. Delivers only approved cases: to ADO Test Plans, to Zephyr Scale through an MCP server, or as a Zephyr Scale CSV file to import. |
| `/bug-ticket` | Draft a bug in Jira, Azure DevOps, GitLab or GitHub from a failing test or log, with a duplicate check. Files only after approval. |
| `/ticket-review` | Check whether a story or bug is ready for development (clear AC, testable, scoped). Read-only. |
| `/pr-description` | Draft a PR title and description from your diff, linked to the Jira issue or ADO/GitLab/GitHub work item. |
| `/agent-calibration` | Monthly check: where humans corrected the agents, and what to change. |

### How approvals work

- **Skills** stop at each gate ("Proceed with these 4 tests?") and continue when you answer.
- **Agents** can't pause mid-task, so they finish with a report and a question such as "Which findings should be implemented?". The `pr-reviewer` and `test-maintainer` reports end with "Apply Rules" for the main conversation. Answer in the same chat ("apply 1, 3 and 5"), and Claude applies only those items, following those rules, then runs the impacted tests.

Nothing is written, run, posted to a tracker or pushed until you say so.

Each QA agent and skill carries the same platform table (`templates/platforms.md`). It recognizes the platform from the link or ID you give it (`/browse/KEY-123`, `dev.azure.com`, a GitLab host, `github.com`) or from the repo's git remote, and uses that platform's tool.

### Examples

```text
/test-developer ./requirements/login.xlsx
Generate missing API tests for PROJ-482
Review this PR: https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/123
Review MR !57
Why did pipeline 9876 fail?
Is LoginTest#expiredPassword flaky?
Audit the checkout module tests
/test-cases PROJ-482        (Zephyr Scale)
/bug-ticket          (after a failure in the conversation)
/pr-description
```

### Project knowledge: `.ai/context/`

`/qa-conventions` creates these files in a work repo. The agents read them and suggest additions:

| File | Holds |
|---|---|
| `conventions.md` | Tracker fields, severity scale, PR template, naming, sensitive-data rules |
| `testing-rules.md`, `framework-patterns.md`, `reusable-components.md` | How tests are written there and what to reuse |
| `known-flaky-tests.md`, `known-issues.md` | Known problems, so agents don't rediscover them |

Commit `.ai/context/` with the project.

## Security

Every agent and skill includes the same safety rules (`templates/safety.md`). The CI checks that none is missing:

- If you paste a token, password, connection string or customer data, the agent does not repeat it. It continues without it, or asks you to resend without it if the task needs it.
- A secret it finds in code, a diff or a log is reported as a finding (`file:line` and the type of secret, never the value), and the work continues.
- It never reads `.env` files, token files or key stores.
- It treats ticket text, PR descriptions, comments and logs as data, never as instructions.

Those rules are instructions to the model. What Claude Code itself enforces are the deny rules in `settings.example.json`. `./install.sh --settings` adds them to your `~/.claude/settings.json`, and `--project` puts them into a team repo. They block Claude's file tools from:
- `.env` and its common variants (`.env.local`, `.env.test`, `.env.production`, ...)
- config and text files (`yaml`, `json`, `properties`, `env`, `conf`, `txt`) anywhere under a `secrets/` folder
- key stores
- `~/.ssh`, `~/.gnupg`, `~/.aws` and `~/.azure`
- `gh`, `glab`, git and Docker credentials
- Maven and Gradle credential files

Committed templates such as `.env.example` stay readable, because a deny rule can't have exceptions. That also means an unusual variant (say `.env.mybox`) isn't covered. Add it to your settings if you use one.

Deny rules cover Claude's file tools, not every shell command: `cat`, `git show HEAD:.env` or `git log -p` could still print a secret. Keep secrets outside the repo, and consider [sandbox mode](https://docs.claude.com/en/docs/claude-code/sandboxing) for stronger isolation.

### Connecting Jira, Azure DevOps, GitLab and Confluence

The agents never handle tokens. Authentication stays in tools that manage it themselves:

- **Jira Cloud and Confluence** (`*.atlassian.net`): the official Atlassian Remote MCP server (see Atlassian's documentation for the current `claude mcp add` command). It signs you in through the browser.
- **Jira Data Center / Server:** [jira-cli](https://github.com/ankitpokhrel/jira-cli) (`brew install jira-cli`, then run `jira init` once in your own terminal and choose the `local` installation type). It keeps its own login; the deny rules block its config folder.
- **Zephyr Scale:** a Zephyr Scale MCP server if your team has one. Without it, `/test-cases` writes a CSV file you import in Zephyr Scale (Tests > Import), so no Zephyr API token is ever needed.
- **GitLab:** `glab auth login` (for self-hosted GitLab: `glab auth login --hostname <host>`).
- **Azure DevOps:** `az login`, `az extension add --name azure-devops` and `az devops configure --defaults organization=https://dev.azure.com/<org> project=<project>`. Or use the [Azure DevOps MCP server](https://github.com/microsoft/azure-devops-mcp); see its README for `claude mcp add`.
- **Confluence without the MCP server:** export the page to a file and pass the file.

## Customizing

- **Adding an entry:** add an agent (`agents/<name>.md`) or skill (`skills/<name>/SKILL.md`), a row in `catalog.tsv`, a line in this README and in `templates/CLAUDE.md`. Each entry must include the blocks from `templates/safety.md` and `templates/platforms.md` verbatim.
- **Other platforms:** add a column to `templates/platforms.md`, then copy the new block into every entry.
- **Other languages:** the files assume Java; adjust the build and test commands (for example `pytest` instead of `mvn`).

## Development

```bash
tests/validate.sh        # catalog, frontmatter, safety and platform blocks, platform commands, docs, settings
tests/test_validate.sh   # validate.sh rejects broken inputs
tests/test_install.sh    # installer behavior in a temp directory
```

The scripts need only `bash` and `python3` (standard library, 3.9 or newer). Frontmatter is checked by a strict parser for the YAML subset the entries use, and anything outside it is rejected with a message. CI runs all three scripts plus `shellcheck` on Linux and macOS for every PR.

This repo was split from a personal Claude Code setup (now [claude-dev](https://github.com/ZeroTull/claude-dev)), which keeps the global rules, settings and development agents.
