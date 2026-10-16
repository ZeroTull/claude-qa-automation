#!/usr/bin/env python3
"""Tests install.sh in temporary CLAUDE_HOME, COPILOT_HOME and project directories. Never touches the real ~/.claude.

Each test method gets its own temporary directory. Labels match the checks they replaced in the old shell tests.
Run with: python3 -m unittest discover -s tests
"""
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INSTALL = REPO / "install.sh"
IGNORE = shutil.ignore_patterns(".git", ".idea", "__pycache__")
EMPTY_DENY = '{"permissions": {"deny": []}}\n'
NON_ROOT = hasattr(os, "geteuid") and os.geteuid() != 0
# Environment variables install.sh reads as settings. A value left in a developer's shell must not leak into a test, so
# make_env drops them; tests that need one set it explicitly. test_install_knobs_are_all_listed catches a new
# ${NAME:-default} or os.environ.get("NAME") read; a bare $NAME read must be added here by hand (HOME is one).
# PATH, TMPDIR, LANG/LC_* and the like are inherited on purpose: the tests need the developer's real python3 and tools.
INSTALL_KNOBS = ("CLAUDE_HOME", "COPILOT_HOME", "HOME", "BACKUP_STAMP", "AZURE_EXTENSION_DIR", "COPILOT_MCP_SERVERS",
                 "QA_OS", "QA_PY_STUB", "QA_XCODE_SELECT", "QA_FAIL_SETTINGS_WRITE")

AGENTS = sorted(p.name for p in (REPO / "agents").glob("*.md"))
SKILLS = sorted(p.name for p in (REPO / "skills").iterdir() if p.is_dir())
AGENT, AGENT2, SKILL = AGENTS[0], AGENTS[1], SKILLS[0]
AGENT_STEM = AGENT[:-len(".md")]


def deny_count(path):
    return len(json.loads(Path(path).read_text(encoding="utf-8"))["permissions"]["deny"])


N_DENY = deny_count(REPO / "settings.example.json")


def file_mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def count_links(folder):
    if not os.path.isdir(folder):
        raise FileNotFoundError(folder)  # a missing folder must not count as "no links"
    return sum(1 for root, dirs, files in os.walk(folder) for name in dirs + files
               if os.path.islink(os.path.join(root, name)))


def copy_repo(dst):
    shutil.copytree(REPO, dst, symlinks=True, ignore=IGNORE)
    return Path(dst)


def body_after_frontmatter(text):
    """Lines after the second '---' line of a source agent."""
    lines = text.split("\n")
    closing = [i for i, line in enumerate(lines) if line == "---"][1]
    return lines[closing + 1:]


def body_after_generated_marker(text):
    """Lines after the '<!-- Generated' line of a generated Copilot agent."""
    lines = text.split("\n")
    marker = next(i for i, line in enumerate(lines) if line.startswith("<!-- Generated"))
    return lines[marker + 1:]


class Result:
    def __init__(self, proc):
        self.rc = proc.returncode
        self.raw = proc.stdout
        # surrogateescape keeps undecodable bytes visible, so a leaked raw byte can still be found.
        self.out = proc.stdout.decode("utf-8", errors="surrogateescape")


class InstallTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.home = self.tmp / "home"
        self.env = self.make_env(os.environ)
        # Per-test stubs, so the "never runs" markers start empty in every test.
        self.stubs = self.tmp / "stubs"
        self.stub_marks = self.tmp / "marks"
        self.stub_marks.mkdir()
        # az records any call, python3 always fails, xcode-none reports no Command Line Tools.
        self._stub("az", f'touch "{self.stub_marks}/az-called"\n')
        self._stub("python3", "exit 1\n")
        self._stub("xcode-none", "exit 1\n")
        self._stub("py-stub", f'touch "{self.stub_marks}/stub-called"\nexit 1\n')
        # A python3 on PATH that is the macOS stub: the installer must detect it without running it.
        self.stubpath = self.tmp / "stubpath"
        self.stubpath.mkdir()
        (self.stubpath / "python3").symlink_to(self.stubs / "py-stub")

    def make_env(self, environ):
        """The environment for install.sh: never the real ~/.claude, ~/.copilot or HOME, and no inherited settings."""
        inherited = {k: v for k, v in environ.items() if k not in INSTALL_KNOBS and not k.startswith("QA_")}
        return {**inherited, "HOME": str(self.tmp / "home-root"), "CLAUDE_HOME": str(self.home),
                "COPILOT_HOME": str(self.tmp / "copilot-default")}

    def _stub(self, name, body):
        self.write(self.stubs / name, "#!/bin/sh\n" + body, 0o755)

    # Runs install.sh and returns its exit code and combined stdout and stderr.
    def run_install(self, *args, env=None, script=INSTALL, cwd=None, umask=-1):
        proc = subprocess.run([str(script), *map(str, args)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              env={**self.env, **(env or {})}, cwd=cwd, umask=umask)
        return Result(proc)

    def macos_stub_env(self, **extra):
        return {"PATH": f"{self.stubpath}:{os.environ['PATH']}", "QA_PY_STUB": str(self.stubpath / "python3"),
                "QA_OS": "Darwin", "QA_XCODE_SELECT": str(self.stubs / "xcode-none"), **extra}

    def failing_python_env(self, **extra):
        return {"PATH": f"{self.stubs}:{os.environ['PATH']}", **extra}

    def check(self, label, condition, detail=""):
        with self.subTest(label):
            self.assertTrue(condition, detail)

    def check_out(self, label, result, pattern):
        """The output has a line matching the regex (like grep -q)."""
        self.check(label, re.search(pattern, result.out, re.M), result.out)

    def check_lacks(self, label, result, text):
        """The output does not contain the literal text (like grep -qF failing)."""
        self.check(label, text not in result.out, result.out)

    def check_file_lacks(self, label, path, text):
        # Reading a missing file raises, so a missing file fails the check instead of passing it.
        self.check(label, text not in Path(path).read_text(encoding="utf-8"))

    def write(self, path, text, mode=None):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text if isinstance(text, bytes) else text.encode("utf-8"))
        if mode is not None:
            path.chmod(mode)
        return path

    def latest_backup_dir(self, home=None):
        return sorted(p for p in ((home or self.home) / "backups").iterdir() if p.is_dir())[-1]

    @staticmethod
    def project_backup(result):
        m = re.search(r"backup: (.*project-settings\.json)\)", result.out)
        return Path(m.group(1)) if m else None

    @staticmethod
    def temp_files(folder):
        return list(Path(folder).rglob(".settings.*"))

    def test_user_install_lifecycle(self):
        # The user install, --settings, backups and uninstall share one CLAUDE_HOME, as a real user's would.
        out = self.run_install()
        self.check("exits 0", out.rc == 0)
        self.check("links every agent", count_links(self.home / "agents") == len(AGENTS))
        self.check("links every skill", count_links(self.home / "skills") == len(SKILLS))
        self.check("agent link resolves to the repo", os.readlink(self.home / "agents" / AGENT) == str(REPO / "agents" / AGENT))
        self.check("skill is readable through its link", (self.home / "skills" / SKILL / "SKILL.md").is_file())
        self.check("does not touch CLAUDE.md", not (self.home / "CLAUDE.md").exists())
        self.check("does not create settings.json", not (self.home / "settings.json").exists())
        self.check_out("reports missing deny rules", out, re.escape(f"lacks {N_DENY} deny rule(s). Run ./install.sh --settings"))
        self.check("no backup on a clean install", not (self.home / "backups").is_dir())
        self.check_out("prints dependency check", out, r"^Dependency check:")
        self.check_out("reports git as found", out, r"^  found +git$")

        # re-run is idempotent
        out = self.run_install()
        self.check("exits 0", out.rc == 0)
        self.check_out("reports existing links as ok", out, "ok .*agents/" + re.escape(AGENT))
        self.check("no new links", count_links(self.home / "agents") == len(AGENTS))

        # --settings
        settings = self.write(self.home / "settings.json",
                              '{"theme": "dark", "permissions": {"allow": ["Read"], "deny": ["Bash(rm -rf *)"]}}\n', 0o644)
        out = self.run_install("--settings")
        self.check("exits 0", out.rc == 0)
        merged = json.loads(settings.read_text())
        self.check("keeps other settings", merged["theme"] == "dark" and merged["permissions"]["allow"] == ["Read"])
        want = json.loads((REPO / "settings.example.json").read_text())["permissions"]["deny"]
        self.check("adds every missing deny rule", all(r in merged["permissions"]["deny"] for r in want))
        self.check("keeps an existing deny rule once", settings.read_text().count("rm -rf") == 1)
        backup = self.latest_backup_dir() / "settings.json"
        self.check("backs up the old settings", '"theme": "dark"' in backup.read_text())
        self.check("keeps the file mode", file_mode(settings) == file_mode(backup))
        out = self.run_install("--settings")
        self.check_out("second run reports ok", out, "already has every deny rule")
        out = self.run_install()
        self.check_lacks("plain install no longer reports missing rules", out, "lacks")

        # --settings does not write through a link
        other = self.write(self.tmp / "other-repo" / "settings.json", EMPTY_DENY, 0o666)
        settings.unlink()
        settings.symlink_to(other)
        out = self.run_install("--settings")
        self.check("exits 1", out.rc == 1)
        self.check_lacks("a link to a writable file gets no warning", out, "writable by other users")
        self.check_out("explains where to add the rules", out, "Add these deny rules in that repo instead")
        self.check("leaves the other repo's file unchanged", other.read_text() == EMPTY_DENY)
        self.check("keeps the link", settings.is_symlink())

        # backs up what it replaces
        (self.home / "agents" / AGENT).unlink()
        self.write(self.home / "agents" / AGENT, "mine\n")
        (self.home / "skills" / SKILL).unlink()
        (self.home / "skills" / SKILL).symlink_to("/tmp/elsewhere")
        out = self.run_install()
        self.check_out("reports the backup", out, "backed up agents/" + re.escape(AGENT))
        bk = self.latest_backup_dir()
        self.check("keeps the replaced file", (bk / "agents" / AGENT).read_text() == "mine\n")
        self.check("keeps a replaced foreign link", os.readlink(bk / "skills" / SKILL) == "/tmp/elsewhere")
        self.check("links the agent", os.readlink(self.home / "agents" / AGENT) == str(REPO / "agents" / AGENT))

        # replaces links left by a moved clone
        (self.home / "agents" / AGENT2).unlink()
        (self.home / "agents" / AGENT2).symlink_to(f"/old/place/agents/{AGENT2}")
        out = self.run_install()
        self.check_out("backs up the broken link", out, re.escape(f"backed up agents/{AGENT2} (was a broken link)"))
        self.check("relinks it to this repo", os.readlink(self.home / "agents" / AGENT2) == str(REPO / "agents" / AGENT2))

        # uninstall
        (self.home / "agents" / "other.md").symlink_to("/tmp/elsewhere")
        (self.home / "skills" / "synced").mkdir()
        out = self.run_install("--uninstall")
        self.check("exits 0", out.rc == 0)
        self.check("restores the backed-up agent", (self.home / "agents" / AGENT).read_text() == "mine\n")
        self.check("restores a backed-up foreign link", os.readlink(self.home / "skills" / SKILL) == "/tmp/elsewhere")
        # exists() follows links, as the shell test did: the restored broken link from the moved clone still passes.
        self.check("removes links without a backup", not os.path.exists(self.home / "agents" / AGENT2))
        self.check("keeps foreign links", (self.home / "agents" / "other.md").is_symlink())
        self.check("keeps Claude-managed folders", (self.home / "skills" / "synced").is_dir())
        self.check("leaves settings.json alone", settings.is_symlink())

    def test_dependency_check(self):
        deps = self.tmp / "deps"
        (self.tmp / "azext").mkdir()
        out = self.run_install(env=self.failing_python_env(CLAUDE_HOME=str(deps), AZURE_EXTENSION_DIR=str(self.tmp / "azext")))
        self.check("exits 0 with missing tools", out.rc == 0)
        self.check_out("reports missing azure-devops extension", out, "missing .*az azure-devops extension")
        self.check("does not run az", not (self.stub_marks / "az-called").exists())
        self.check_out("reports missing openpyxl", out, "missing .*openpyxl")
        self.check("still links when python3 cannot run", count_links(deps / "agents") == len(AGENTS))
        self.check_out("says the settings check failed", out, "Could not check .*settings.json for the deny rules")
        out = self.run_install(env=self.macos_stub_env(CLAUDE_HOME=str(deps)))
        self.check_out("reports the macOS python3 stub", out, "only the macOS stub is installed")
        self.check_out("skips the settings check on the stub", out, "Skipped the settings check: no working python3")
        self.check("never runs the stub", not (self.stub_marks / "stub-called").exists())

    def test_settings_file_modes(self):
        # A strict umask makes plain cp narrow the copy (644 -> 600); -p keeps the original's bits.
        mode_home = self.tmp / "mode-home"
        self.write(mode_home / "settings.json", EMPTY_DENY, 0o644)
        out = self.run_install("--settings", env={"CLAUDE_HOME": str(mode_home)}, umask=0o077)
        backups = list((mode_home / "backups").rglob("settings.json"))
        self.check("a settings.json is backed up under umask 077", backups)
        self.check("the backup keeps the original's 644 under umask 077", backups and file_mode(backups[0]) == 0o644)
        self.check_lacks("a 644 settings.json gets no warning", out, "writable by other users")
        private = self.tmp / "private-home"
        self.write(private / "settings.json", EMPTY_DENY, 0o600)
        self.run_install("--settings", env={"CLAUDE_HOME": str(private)})
        pbak = next((private / "backups").rglob("settings.json"))
        self.check("a 0600 settings.json backup is still 0600", file_mode(pbak) == 0o600)
        open_home = self.tmp / "open-home"
        open_settings = self.write(open_home / "settings.json", EMPTY_DENY, 0o666)
        out = self.run_install("--settings", env={"CLAUDE_HOME": str(open_home)})
        warning = "WARNING   settings.json is writable by other users or your group"
        self.check_out("warns when settings.json is writable by others", out, re.escape(warning))
        obak = next((open_home / "backups").rglob("settings.json"))
        self.check("the backup of a 666 settings.json is not writable by others", file_mode(obak) == 0o644)
        out = self.run_install("--settings", env={"CLAUDE_HOME": str(open_home)})
        self.check_out("warns even when every deny rule is present", out, "already has every deny rule")
        self.check_out("the warning is printed on the already-complete run", out, re.escape(warning))
        open_settings.chmod(0o664)
        out = self.run_install("--settings", env={"CLAUDE_HOME": str(open_home)})
        self.check_out("warns when settings.json is writable by the group", out, "WARNING   settings.json is writable")

    def test_default_run_explains_why_the_settings_check_failed(self):
        self.write(self.tmp / "badjson" / "settings.json", "{not json")
        out = self.run_install(env={"CLAUDE_HOME": str(self.tmp / "badjson")})
        self.check("exits 0", out.rc == 0)
        self.check_out("shows the reason", out, "Could not check .*: .*settings.json is not valid JSON")

    def test_settings_on_a_fresh_machine(self):
        fresh = self.tmp / "fresh"
        out = self.run_install("--settings", env={"CLAUDE_HOME": str(fresh)})
        self.check("exits 0", out.rc == 0)
        self.check_lacks("--settings on a fresh machine prints no traceback", out, "Traceback")
        self.check("creates settings.json with the deny rules", deny_count(fresh / "settings.json") == N_DENY)
        data = json.loads((fresh / "settings.json").read_text())
        self.check("--settings adds no allow rules", not data.get("permissions", {}).get("allow"))
        self.check("creates it readable (0644)", file_mode(fresh / "settings.json") == 0o644)

    def test_settings_with_broken_input_changes_nothing(self):
        broken = self.tmp / "broken"
        env = {"CLAUDE_HOME": str(broken)}
        for content in ['{not json', '[]', '{"permissions": []}', '{"permissions": {"deny": "x"}}']:
            self.write(broken / "settings.json", content)
            out = self.run_install("--settings", env=env)
            self.check(f"rejects {content}", out.rc == 1)
            self.check_out(f"explains {content}", out, "not valid JSON|unexpected shape")
            self.check(f"leaves {content} unchanged", (broken / "settings.json").read_text() == content)
        self.check("makes no backup for broken input", not (broken / "backups").is_dir())
        self.write(broken / "settings.json", '{"permissions": null}')
        self.run_install("--settings", env=env)
        self.check("treats permissions: null as empty", deny_count(broken / "settings.json") == N_DENY)
        self.write(broken / "settings.json", "{}")
        out = self.run_install("--settings", env=self.failing_python_env(**env))
        self.check("fails when python3 fails", out.rc == 1)
        self.check("leaves settings.json unchanged when python3 fails", (broken / "settings.json").read_text() == "{}")
        out = self.run_install("--settings", env=self.macos_stub_env(**env))
        self.check_out("refuses on the macOS stub", out, "needs a working python3")

    def test_two_installs_in_the_same_second_keep_separate_backups(self):
        home2 = self.tmp / "home2"
        env = {"CLAUDE_HOME": str(home2), "BACKUP_STAMP": "fixed"}
        self.write(home2 / "agents" / AGENT, "A\n")
        self.run_install(env=env)
        (home2 / "agents" / AGENT).unlink()
        self.write(home2 / "agents" / AGENT, "B\n")
        self.run_install(env=env)
        self.check("first run backs up to -000", (home2 / "backups/qa-fixed-000/agents" / AGENT).read_text() == "A\n")
        self.check("second run backs up to -001", (home2 / "backups/qa-fixed-001/agents" / AGENT).read_text() == "B\n")
        self.run_install("--uninstall", env={"CLAUDE_HOME": str(home2)})
        self.check("uninstall restores the newer one", (home2 / "agents" / AGENT).read_text() == "B\n")

    def test_refuses_linked_folders(self):
        linked = self.tmp / "linked"
        elsewhere = self.tmp / "elsewhere-agents"
        linked.mkdir()
        elsewhere.mkdir()
        (linked / "agents").symlink_to(elsewhere)
        out = self.run_install(env={"CLAUDE_HOME": str(linked)})
        self.check("exits 1", out.rc == 1)
        self.check_out("explains why", out, "agents is a link to")
        self.check("writes nothing into the linked folder", not any(elsewhere.iterdir()))
        # --project refuses linked folders
        for d in ("agents", "skills"):
            pl = self.tmp / f"proj-linked-{d}"
            target = self.tmp / f"target-{d}"
            (pl / ".claude").mkdir(parents=True)
            target.mkdir()
            (pl / ".claude" / d).symlink_to(target)
            out = self.run_install("--project", pl)
            self.check(f"exits 1 for a linked .claude/{d}", out.rc == 1)
            self.check(f"writes nothing into the linked {d} folder", not any(target.iterdir()))
        pl = self.tmp / "proj-linked-claude"
        target = self.tmp / "target-claude"
        pl.mkdir()
        target.mkdir()
        (pl / ".claude").symlink_to(target)
        out = self.run_install("--project", pl)
        self.check("exits 1 for a linked .claude folder", out.rc == 1)
        self.check("writes nothing into the linked .claude folder", not any(target.iterdir()))

    def test_runs_through_a_symlink_to_the_script(self):
        (self.tmp / "bin").mkdir()
        (self.tmp / "bin" / "qa-install").symlink_to(INSTALL)
        out = self.run_install(env={"CLAUDE_HOME": str(self.tmp / "via-link")}, script=self.tmp / "bin" / "qa-install")
        self.check("exits 0", out.rc == 0)
        self.check("links into the real repo",
                   os.readlink(self.tmp / "via-link" / "agents" / AGENT) == str(REPO / "agents" / AGENT))

    def test_project_install(self):
        proj = self.tmp / "proj"
        self.write(proj / "CLAUDE.md", "# existing\n")
        out = self.run_install("--project", proj)
        self.check("exits 0", out.rc == 0)
        copied = list((proj / ".claude" / "agents").iterdir()) + list((proj / ".claude" / "skills").iterdir())
        self.check("copies every agent and skill", len(copied) == len(AGENTS) + len(SKILLS))
        self.check("copies, does not link", not (proj / ".claude" / "agents" / AGENT).is_symlink())
        self.check("creates settings.json from the example",
                   (proj / ".claude" / "settings.json").read_bytes() == (REPO / "settings.example.json").read_bytes())
        self.check("keeps existing CLAUDE.md", (proj / "CLAUDE.md").read_text() == "# existing\n")
        self.check("copies the framework-map skill", (proj / ".claude/skills/framework-map/SKILL.md").is_file())
        self.check_out("next steps name /framework-map", out, "/qa-conventions, then /framework-map")
        out = self.run_install("--project", proj)
        self.check_out("reports a complete project settings.json", out, "ok .*settings.json has every deny rule")
        self.write(proj / ".claude" / "settings.json", "custom\n")
        out = self.run_install("--project", proj)
        self.check("keeps an existing settings.json", (proj / ".claude" / "settings.json").read_text() == "custom\n")
        self.check_out("says an unreadable settings.json could not be checked", out, "could not check its deny rules")
        with open(proj / ".claude" / "agents" / AGENT, "a") as f:
            f.write("local edit\n")
        out = self.run_install("--project", proj)
        self.check_out("reports a changed agent", out, "DIFFERS .*agents/" + re.escape(AGENT))
        self.run_install("--project", proj, "--update")
        self.check("--update replaces it",
                   (proj / ".claude/agents" / AGENT).read_bytes() == (REPO / "agents" / AGENT).read_bytes())
        self.check("--update leaves an unreadable settings.json alone",
                   (proj / ".claude" / "settings.json").read_text() == "custom\n")
        self.check("--update keeps CLAUDE.md", (proj / "CLAUDE.md").read_text() == "# existing\n")

    def test_project_update_keeps_what_this_repo_lacks(self):
        proj = self.tmp / "proj-keep"
        proj.mkdir()
        out = self.run_install("--project", proj)
        self.check_out("the summary counts every entry as added", out, rf"^  added +{len(AGENTS) + len(SKILLS)}$")
        self.check_out("the summary lists an added agent", out, rf"^ +agents/{re.escape(AGENT)}$")
        self.check_out("the summary reaches the left line", out, r"^  left +0 ")
        claude = proj / ".claude"
        skill_md = claude / "skills" / SKILL / "SKILL.md"
        self.write(claude / "skills" / SKILL / "notes.md", "team notes\n")
        self.write(claude / "agents" / "team-agent.md", "team agent\n")
        self.write(claude / "skills" / "team-skill" / "SKILL.md", "team skill\n")
        (claude / "skills" / SKILL / "outside").symlink_to(self.tmp / "nowhere")
        out = self.run_install("--project", proj)
        self.check_out("files added inside a skill alone do not make it differ", out, rf"^  ok +.*skills/{SKILL}$")
        self.check_out("reports a kept file", out, rf"^  kept +.*skills/{SKILL}/notes\.md \(not in this repo\)$")
        with open(skill_md, "a") as f:
            f.write("local edit\n")
        with open(claude / "agents" / AGENT2, "a") as f:
            f.write("local edit\n")
        out = self.run_install("--project", proj, "--update")
        self.check("exits 0", out.rc == 0, out.out)
        self.check("--update copies the repo's SKILL.md over the edited one",
                   skill_md.read_bytes() == (REPO / "skills" / SKILL / "SKILL.md").read_bytes())
        self.check("--update keeps a file added inside the skill",
                   (claude / "skills" / SKILL / "notes.md").read_text() == "team notes\n")
        self.check("--update keeps a link added inside the skill", (claude / "skills" / SKILL / "outside").is_symlink())
        self.check("--update keeps an agent this repo lacks", (claude / "agents" / "team-agent.md").read_text() == "team agent\n")
        self.check("--update keeps a skill this repo lacks",
                   (claude / "skills" / "team-skill" / "SKILL.md").read_text() == "team skill\n")
        self.check_out("the summary counts the updated entries", out, r"^  updated +2$")
        self.check_out("the summary names an updated skill", out, rf"^ +skills/{SKILL}$")
        self.check_out("the summary names an updated agent", out, rf"^ +agents/{re.escape(AGENT2)}$")
        self.check_out("the summary counts the unchanged entries", out, rf"^  unchanged +{len(AGENTS) + len(SKILLS) - 2}$")
        self.check_out("the summary counts the left entries", out, r"^  left +2 \(not in this repo, kept as they are\)$")
        self.check_out("the summary names a left agent", out, r"^ +agents/team-agent\.md$")
        self.check_out("the summary names a left skill", out, r"^ +skills/team-skill$")
        self.check_out("the summary counts the kept files", out, r"^  kept +2 ")
        self.check_out("the summary names a kept file", out, rf"^ +skills/{SKILL}/notes\.md$")
        self.check_lacks("no summary line for differs after --update", out, "  differs")
        self.check_lacks("the old remove-by-hand note is gone", out, "remove them by hand")
        with open(skill_md, "a") as f:
            f.write("local edit\n")
        out = self.run_install("--project", proj)
        self.check_out("without --update the summary lists the differing skill", out, r"^  differs +1 \(run again with --update")
        self.check("without --update the edit stays", "local edit" in skill_md.read_text())

    def test_project_update_skips_a_nested_conflict(self):
        proj = self.tmp / "proj-nested"
        proj.mkdir()
        self.run_install("--project", proj)
        skill_md = proj / ".claude" / "skills" / SKILL / "SKILL.md"
        skill_md.unlink()
        self.write(skill_md / "inner.md", "a folder where the repo has a file\n")
        out = self.run_install("--project", proj, "--update")
        self.check("exits 0", out.rc == 0, out.out)
        self.check_out("skips a skill with a nested type conflict", out,
                       rf"^  SKIP +.*skills/{SKILL} \(SKILL\.md is a symlink or a different type - remove it, then run again\)$")
        self.check("leaves the nested folder alone", (skill_md / "inner.md").is_file())
        self.check_out("the summary lists the skipped skill", out, r"^  skipped +1 \(remove or fix the path named in each, then run again\)$")
        shutil.rmtree(skill_md)
        target = self.tmp / "link-target.md"
        self.write(target, "outside\n")
        skill_md.symlink_to(target)
        out = self.run_install("--project", proj, "--update")
        self.check_out("skips a skill whose file is a link", out, rf"^  SKIP +.*skills/{SKILL} \(SKILL\.md is a symlink")
        self.check("does not write through the link", target.read_text() == "outside\n")

    def test_project_conflict_on_a_plain_run_and_in_a_repo_folder(self):
        repo_copy = copy_repo(self.tmp / "repo-nested")
        self.write(repo_copy / "skills" / SKILL / "refs" / "guide.md", "guide\n")
        proj = self.tmp / "proj-reverse"
        proj.mkdir()
        self.run_install("--project", proj, script=repo_copy / "install.sh")
        refs = proj / ".claude" / "skills" / SKILL / "refs"
        shutil.rmtree(refs)
        self.write(refs, "a file where the repo has a folder\n")
        skill_md = proj / ".claude" / "skills" / SKILL / "SKILL.md"
        with open(skill_md, "a") as f:
            f.write("local edit\n")
        out = self.run_install("--project", proj, script=repo_copy / "install.sh")
        self.check_out("a plain run skips a nested conflict too", out, rf"^  SKIP +.*skills/{SKILL} \(refs is a symlink")
        out = self.run_install("--project", proj, "--update", script=repo_copy / "install.sh")
        self.check_out("--update skips a file where the repo has a folder", out, rf"^  SKIP +.*skills/{SKILL} \(refs is a symlink")
        self.check("leaves the file in place", refs.read_text() == "a file where the repo has a folder\n")
        self.check("updates no file of a skipped skill", "local edit" in skill_md.read_text())

    def test_project_update_hidden_and_read_only_files(self):
        proj = self.tmp / "proj-hidden"
        proj.mkdir()
        self.run_install("--project", proj)
        claude = proj / ".claude"
        for junk in (claude / "agents" / ".DS_Store", claude / "skills" / ".DS_Store", claude / "skills" / SKILL / ".DS_Store"):
            self.write(junk, "finder\n")
        skill_md = claude / "skills" / SKILL / "SKILL.md"
        with open(skill_md, "a") as f:
            f.write("local edit\n")
        skill_md.chmod(0o444)
        out = self.run_install("--project", proj, "--update")
        self.check("exits 0 with a read-only file to update", out.rc == 0, out.out)
        self.check("--update replaces a read-only file",
                   skill_md.read_bytes() == (REPO / "skills" / SKILL / "SKILL.md").read_bytes())
        self.check_out("the summary is complete", out, r"^  left +0 ")
        self.check_lacks("a .DS_Store is neither left nor kept", out, ".DS_Store")
        self.check("the .DS_Store files stay", (claude / "skills" / SKILL / ".DS_Store").is_file())

    @unittest.skipUnless(NON_ROOT, "root reads and writes everything")
    def test_project_skips_what_it_cannot_read_or_write(self):
        for case, rel, mode, problem in (("a folder it cannot read", "private", 0o000, "cannot read"),
                                         ("a file it cannot read", "secret.md", 0o000, "cannot read"),
                                         ("a folder it cannot write", "refs", 0o555, "cannot write to")):
            with self.subTest(case):
                repo_copy = copy_repo(self.tmp / f"repo-{rel}")
                self.write(repo_copy / "skills" / SKILL / "refs" / "guide.md", "guide\n")
                proj = self.tmp / f"proj-{rel}"
                proj.mkdir()
                self.run_install("--project", proj, script=repo_copy / "install.sh")
                skill_dir = proj / ".claude" / "skills" / SKILL
                with open(skill_dir / "SKILL.md", "a") as f:
                    f.write("local edit\n")
                (repo_copy / "skills" / SKILL / "refs" / "new.md").write_text("new\n")
                path = skill_dir / rel
                if rel == "private":
                    self.write(path / "notes.md", "team notes\n")
                elif rel == "secret.md":
                    self.write(path, "team secret\n")
                path.chmod(mode)
                self.addCleanup(path.chmod, 0o755)
                expected = rf"^  SKIP +.*skills/{SKILL} \({problem} .*skills/{SKILL}/{re.escape(rel)} - fix its permissions\)$"
                for args in ((), ("--update",)) if problem == "cannot read" else (("--update",),):
                    out = self.run_install("--project", proj, *args, script=repo_copy / "install.sh")
                    self.check(f"{case} {args}: exits 0", out.rc == 0, out.out)
                    self.check_out(f"{case} {args}: skips the skill and names the path", out, expected)
                    self.check(f"{case} {args}: does not report it as ok or differing",
                               not re.search(rf"^  (ok|DIFFERS|updated) +.*skills/{SKILL}( |$)", out.out, re.M), out.out)
                    self.check_out(f"{case} {args}: the summary counts it as skipped", out, r"^  skipped +1 ")
                    self.check_out(f"{case} {args}: the rest still runs", out, r"^  left +0 ")
                path.chmod(0o755)
                self.check(f"{case}: updates none of its files", "local edit" in (skill_dir / "SKILL.md").read_text())
                self.check(f"{case}: writes nothing into it", not (skill_dir / "refs" / "new.md").exists())

    @unittest.skipUnless(NON_ROOT, "root reads and writes everything")
    def test_project_refuses_a_folder_it_cannot_write(self):
        for sub, mode in (("agents", 0o555), ("skills", 0o000)):
            with self.subTest(sub):
                proj = self.tmp / f"proj-locked-{sub}"
                locked = proj / ".claude" / sub
                locked.mkdir(parents=True)
                locked.chmod(mode)
                self.addCleanup(locked.chmod, 0o755)
                for args in ((), ("--update",)):
                    out = self.run_install("--project", proj, *args)
                    self.check(f"{sub} {args}: exits 1", out.rc == 1, out.out)
                    self.check_out(f"{sub} {args}: names the folder", out,
                                   rf"^error: cannot read and write .*\.claude/{sub} - fix its permissions")
                    self.check(f"{sub} {args}: copies nothing", not any((proj / ".claude" / "agents").iterdir()))
        complete = self.tmp / "proj-locked-complete"
        complete.mkdir()
        self.check("a complete install: the setup run succeeds", self.run_install("--project", complete).rc == 0)
        agents = complete / ".claude" / "agents"
        agents.chmod(0o555)
        self.addCleanup(agents.chmod, 0o755)
        out = self.run_install("--project", complete)
        self.check("a complete install in a read-only folder: still refused", out.rc == 1, out.out)
        self.check_out("a complete install in a read-only folder: names the folder", out,
                       r"^error: cannot read and write .*\.claude/agents - fix its permissions")

    def test_project_reports_a_failed_copy(self):
        # A cp that fails only for one skill, as a full disk or an I/O error would.
        fake = self.tmp / "fake-cp"
        self.write(fake / "cp", f'''#!/bin/sh
for a in "$@"; do case "$a" in */skills/{SKILL}|*/skills/{SKILL}/*) echo "cp: simulated failure" >&2; exit 1;; esac; done
exec /bin/cp "$@"
''', 0o755)
        env = {"PATH": f"{fake}:{os.environ['PATH']}"}
        proj = self.tmp / "proj-failed"
        proj.mkdir()
        out = self.run_install("--project", proj, env=env)
        self.check("a failed new copy: exits 0", out.rc == 0, out.out)
        self.check_out("a failed new copy: reports FAILED", out, rf"^  FAILED +.*skills/{SKILL} \(could not copy")
        self.check_out("a failed new copy: the summary lists it", out, rf"^  failed +1 \(see the errors above")
        self.check_out("a failed new copy: the other skills are still copied", out, rf"^  copied +.*skills/{SKILLS[1]}$")
        self.run_install("--project", proj)
        with open(proj / ".claude" / "skills" / SKILL / "SKILL.md", "a") as f:
            f.write("local edit\n")
        out = self.run_install("--project", proj, "--update", env=env)
        self.check("a failed update: exits 0", out.rc == 0, out.out)
        self.check_out("a failed update: reports FAILED", out, rf"^  FAILED +.*skills/{SKILL} \(could not copy every file")
        self.check_out("a failed update: the summary still runs to the end", out, r"^  left +0 ")

    def test_project_file_modes(self):
        # Under umask 077 plain cp would make every copy 600 or 700; -p keeps the source's 644 and 755.
        repo_copy = copy_repo(self.tmp / "repo-copy")
        for f in (f"agents/{AGENT}", f"skills/{SKILL}/SKILL.md", "settings.example.json", "templates/CLAUDE.md"):
            (repo_copy / f).chmod(0o644)
        (repo_copy / "skills" / SKILL).chmod(0o755)
        proj2 = self.tmp / "proj-modes"
        proj2.mkdir()
        self.run_install("--project", proj2, script=repo_copy / "install.sh", umask=0o077)
        self.check("an agent copy keeps 644 under umask 077", file_mode(proj2 / ".claude/agents" / AGENT) == 0o644)
        self.check("a skill folder copy keeps 755 under umask 077", file_mode(proj2 / ".claude/skills" / SKILL) == 0o755)
        self.check("a skill file copy keeps 644 under umask 077",
                   file_mode(proj2 / ".claude/skills" / SKILL / "SKILL.md") == 0o644)
        self.check("the settings.json copy keeps 644 under umask 077", file_mode(proj2 / ".claude/settings.json") == 0o644)
        self.check("the CLAUDE.md copy keeps 644 under umask 077", file_mode(proj2 / "CLAUDE.md") == 0o644)
        proj6 = self.tmp / "proj6"
        self.write(proj6 / ".claude" / "settings.json", EMPTY_DENY, 0o644)
        out = self.run_install("--project", proj6, "--update", umask=0o077)
        bak6 = self.project_backup(out)
        self.check("the project settings backup keeps 644 under umask 077", bak6 and file_mode(bak6) == 0o644, out.out)
        proj_open = self.tmp / "proj-open"
        self.write(proj_open / ".claude" / "settings.json", EMPTY_DENY, 0o666)
        out = self.run_install("--project", proj_open, "--update")
        bak_open = self.project_backup(out)
        self.check("the project settings backup of a 666 file is not writable by others",
                   bak_open and file_mode(bak_open) == 0o644, out.out)

    def test_project_settings_update(self):
        proj3 = self.tmp / "proj3"
        settings = self.write(proj3 / ".claude" / "settings.json",
                              '{"model": "x", "permissions": {"allow": ["Bash(ls)"], "deny": ["Read(**/.env)"]}}\n', 0o600)
        out = self.run_install("--project", proj3)
        self.check_out("lists the project's missing deny rules", out, f"MISSING .*settings.json lacks {N_DENY - 1} deny rule")
        self.check("names a missing rule", "Read(**/settings.xml)" in out.out)
        self.check("does not change it without --update", deny_count(settings) == 1)
        out = self.run_install("--project", proj3, "--update")
        self.check("--update adds the missing deny rules", deny_count(settings) == N_DENY)
        d = json.loads(settings.read_text())
        self.check("--update keeps the other settings", d["model"] == "x" and d["permissions"]["allow"] == ["Bash(ls)"])
        self.check("--update keeps the file mode", file_mode(settings) == 0o600)
        self.check_out("--update backs the project settings up", out, "backup: .*/project-settings.json")
        bak = self.project_backup(out)
        self.check("the backup has the original rules", bak and deny_count(bak) == 1)
        self.check("no temp file is left behind", not self.temp_files(proj3 / ".claude"))
        proj4 = self.tmp / "proj4"
        self.write(proj4 / ".claude/settings.json", '{\n    "permissions": {\n        "deny": []\n    }\n}\n')
        self.run_install("--project", proj4, "--update")
        self.check("--update keeps a 4-space indent",
                   re.search(r'^        "deny": \[', (proj4 / ".claude/settings.json").read_text(), re.M))
        proj5 = self.tmp / "proj5"
        self.write(proj5 / ".claude/settings.json", "[]\n")
        out = self.run_install("--project", proj5, "--update")
        self.check("a wrong-shaped project settings.json is left alone", (proj5 / ".claude/settings.json").read_text() == "[]\n")
        self.check_out("says why it was not checked", out,
                       "could not check its deny rules: .*settings.json has an unexpected shape")
        proj8 = self.tmp / "proj8"
        self.write(proj8 / ".claude/settings.json", '{\n\t"permissions": {\n\t\t"deny": []\n\t}\n}\n')
        self.run_install("--project", proj8, "--update")
        self.check("--update keeps a tab indent", re.search(r'^\t\t"deny": \[', (proj8 / ".claude/settings.json").read_text(), re.M))
        proj9 = self.tmp / "proj9"
        self.write(proj9 / ".claude/settings.json", EMPTY_DENY)
        self.run_install("--project", proj9, "--update")
        self.check("a one-line file is written with 2 spaces",
                   re.search(r'^    "deny": \[', (proj9 / ".claude/settings.json").read_text(), re.M))
        empty = self.tmp / "proj-empty"
        self.write(empty / ".claude/settings.json", "")
        self.run_install("--project", empty, "--update")
        self.check("an empty settings.json gets the deny rules", deny_count(empty / ".claude/settings.json") == N_DENY)

    @unittest.skipUnless(NON_ROOT, "root ignores mode bits")
    def test_project_settings_failed_write(self):
        # The agents and skills folders stay writable; only .claude itself refuses the temp file the merge needs.
        proj6 = self.tmp / "proj6"
        self.write(proj6 / ".claude/settings.json", EMPTY_DENY)
        (proj6 / ".claude/agents").mkdir()
        (proj6 / ".claude/skills").mkdir()
        (proj6 / ".claude").chmod(0o500)
        try:
            out = self.run_install("--project", proj6, "--update")
        finally:
            (proj6 / ".claude").chmod(0o700)
        self.check_out("a failed write is reported", out,
                       "FAILED .*" + re.escape("settings.json (could not add the deny rules; the file is unchanged)"))
        self.check_lacks("a failed write gives a one-line reason, not a traceback", out, "Traceback")
        self.check("a failed write leaves the file unchanged", deny_count(proj6 / ".claude/settings.json") == 0)
        self.check_out("a failed write still finishes the install", out, "Next: open Claude Code")

    def test_settings_write_and_backup_failures(self):
        proj6 = self.tmp / "proj6"
        self.write(proj6 / ".claude/settings.json", EMPTY_DENY)
        out = self.run_install("--project", proj6, "--update", env={"QA_FAIL_SETTINGS_WRITE": "1"})
        self.check_out("a failure after the temp file exists is reported", out, "could not write .*simulated write failure")
        self.check_out("it says the deny rules were not added", out,
                       "FAILED .*" + re.escape("settings.json (could not add the deny rules; the file is unchanged)"))
        self.check("it removes the temp file", not self.temp_files(proj6 / ".claude"))
        self.check("it leaves the file unchanged", deny_count(proj6 / ".claude/settings.json") == 0)
        # A plain file where the backups folder should be makes every backup fail, for root too.
        proj10 = self.tmp / "proj10"
        blocked = self.tmp / "blocked-home"
        self.write(proj10 / ".claude/settings.json", EMPTY_DENY)
        self.write(blocked / "backups", "")
        out = self.run_install("--project", proj10, "--update", env={"CLAUDE_HOME": str(blocked)})
        self.check_out("a failed backup is reported", out, "FAILED .*" + re.escape("settings.json (could not back it up"))
        self.check("a failed backup leaves the file unchanged", deny_count(proj10 / ".claude/settings.json") == 0)
        self.check_out("a failed backup still finishes the install", out, "Next: open Claude Code")
        self.write(blocked / "settings.json", EMPTY_DENY)
        out = self.run_install("--settings", env={"CLAUDE_HOME": str(blocked)})
        self.check_out("--settings reports a failed backup", out, "could not back up settings.json")
        self.check("--settings fails when the backup fails", out.rc != 0)
        self.check("--settings leaves the file unchanged when the backup fails", deny_count(blocked / "settings.json") == 0)
        self.check("--settings leaves no temp file when the backup fails", not self.temp_files(blocked))
        mf = self.tmp / "merge-fail-home"
        self.write(mf / "settings.json", EMPTY_DENY)
        out = self.run_install("--settings", env={"CLAUDE_HOME": str(mf), "QA_FAIL_SETTINGS_WRITE": "1"})
        self.check("--settings fails when the merge fails", out.rc == 1)
        self.check_out("--settings says the file was left unchanged", out,
                       re.escape("could not add the deny rules; settings.json was left unchanged"))
        self.check("--settings leaves the file unchanged when the merge fails", deny_count(mf / "settings.json") == 0)
        self.check("--settings leaves no temp file when the merge fails", not self.temp_files(mf))

    def test_no_free_backup_folder(self):
        full = self.tmp / "full-backups-home"
        fullp = self.tmp / "proj-full-backups"
        self.write(fullp / ".claude/settings.json", EMPTY_DENY)
        for i in range(1000):
            (full / "backups" / f"qa-20990101-000000-{i:03d}").mkdir(parents=True)
        env = {"CLAUDE_HOME": str(full), "BACKUP_STAMP": "20990101-000000"}
        out = self.run_install("--project", fullp, "--update", env=env)
        self.check_out("1000 backups in one second fails only the settings step", out,
                       "FAILED .*" + re.escape("settings.json (no free backup folder"))
        self.check_lacks("it names no empty backup path", out, "back it up to ,")
        self.check_out("the agents are still copied", out, "copied .*agents/")
        self.check_out("it still finishes the install", out, "Next: open Claude Code")
        self.check("it leaves the file unchanged", deny_count(fullp / ".claude/settings.json") == 0)
        self.write(full / "settings.json", EMPTY_DENY)
        out = self.run_install("--settings", env=env)
        self.check("--settings with no free backup folder fails", out.rc == 1)
        self.check_out("--settings says the file was left unchanged", out,
                       "no free backup folder; settings.json was left unchanged")
        self.check("--settings leaves it unchanged", deny_count(full / "settings.json") == 0)

    def test_unreadable_and_unusual_settings(self):
        bad = self.tmp / "bad-utf8-home"
        self.write(bad / "settings.json", b'{"a": "\xff"}\n')
        out = self.run_install("--settings", env={"CLAUDE_HOME": str(bad)})
        self.check_out("a non-UTF-8 settings.json gives a one-line reason", out,
                       re.escape("settings.json is not UTF-8 (byte offset"))
        self.check_lacks("a non-UTF-8 settings.json is not echoed", out, "0xff")
        self.check_lacks("a non-UTF-8 settings.json is not echoed as an escape", out, "\\377")
        self.check("a non-UTF-8 settings.json is not echoed raw", b"\xff" not in out.raw)
        badp = self.tmp / "proj-bad-utf8"
        original = b'{"a": "\xff"}\n'
        self.write(badp / ".claude/settings.json", original)
        out = self.run_install("--project", badp, "--update")
        self.check_out("--project skips a non-UTF-8 settings.json with a reason", out,
                       "could not check its deny rules: .*" + re.escape("settings.json is not UTF-8 (byte offset"))
        self.check_lacks("--project does not echo the bytes", out, "0xff")
        self.check("--project leaves the non-UTF-8 file unchanged", (badp / ".claude/settings.json").read_bytes() == original)
        self.check_lacks("a non-UTF-8 settings.json prints no traceback", out, "Traceback")
        enc = self.tmp / "proj-enc"
        self.write(enc / ".claude/settings.json", '{"permissions": {"deny": ["\\ud800"]}}\n')
        out = self.run_install("--project", enc, "--update")
        self.check_out("an unwritable value gives a one-line reason", out, "could not write .*settings.json")
        self.check_lacks("an unwritable value prints no traceback", out, "Traceback")
        self.check("an unwritable value leaves no temp file", not self.temp_files(enc / ".claude"))
        self.check_lacks("an unwritable value does not echo it", out, "ud800")
        big = self.tmp / "proj-big"
        big_text = '{"model": 1e400, "permissions": {"deny": []}}\n'
        self.write(big / ".claude/settings.json", big_text)
        out = self.run_install("--project", big, "--update")
        self.check_out("a number JSON cannot write back is reported", out,
                       "could not write .*settings.json: a value cannot be written back as JSON")
        self.check("it is not turned into Infinity", (big / ".claude/settings.json").read_text() == big_text)
        self.check_lacks("it prints no traceback", out, "Traceback")
        self.check("it leaves no temp file", not self.temp_files(big / ".claude"))
        dup = self.tmp / "proj-dup"
        dup_text = '{"permissions": {"deny": ["Read(**/.env)"]}, "permissions": {"deny": []}}\n'
        self.write(dup / ".claude/settings.json", dup_text)
        out = self.run_install("--project", dup, "--update")
        self.check_out("duplicate keys are reported", out, "has the same key twice in one object")
        self.check_lacks("duplicate keys are not named", out, '"permissions" twice')
        self.check("duplicate keys leave the file unchanged", (dup / ".claude/settings.json").read_text() == dup_text)

    @unittest.skipUnless(NON_ROOT, "root ignores mode bits")
    def test_unreadable_settings_json(self):
        unread = self.tmp / "unread-home"
        settings = self.write(unread / "settings.json", EMPTY_DENY, 0o000)
        try:
            out = self.run_install("--settings", env={"CLAUDE_HOME": str(unread)})
        finally:
            settings.chmod(0o600)
        self.check_out("an unreadable settings.json gives a one-line reason", out, "could not read .*settings.json")
        self.check_lacks("an unreadable settings.json prints no traceback", out, "Traceback")
        self.check("an unreadable settings.json is left unchanged", deny_count(settings) == 0)

    def test_missing_mktemp_or_python3(self):
        no_mktemp = self.tmp / "no-mktemp"
        self.write(no_mktemp / "mktemp", "#!/bin/sh\nexit 1\n", 0o755)
        path = {"PATH": f"{no_mktemp}:{os.environ['PATH']}"}
        mk = self.tmp / "proj-mk"
        self.write(mk / ".claude/settings.json", EMPTY_DENY)
        out = self.run_install("--project", mk, "--update", env=path)
        self.check("without mktemp the project install still finishes", out.rc == 0)
        self.check_out("without mktemp the project settings are skipped with a reason", out,
                       "could not create a temp file to check its deny rules")
        self.check("without mktemp the file is unchanged", deny_count(mk / ".claude/settings.json") == 0)
        out = self.run_install(env={**path, "CLAUDE_HOME": str(self.tmp / "mk-home")})
        self.check("without mktemp the default install still finishes", out.rc == 0)
        self.check_out("without mktemp the settings check is skipped with a reason", out,
                       "Skipped the settings check: could not create a temp file")
        proj7 = self.tmp / "proj7"
        self.write(proj7 / ".claude/settings.json", EMPTY_DENY)
        out = self.run_install("--project", proj7, "--update", env=self.macos_stub_env())
        self.check_out("without python3 the project settings are skipped", out,
                       "SKIP .*" + re.escape("settings.json (exists; checking its deny rules needs python3"))
        self.check("without python3 the file is unchanged", (proj7 / ".claude/settings.json").read_text() == EMPTY_DENY)
        proj2 = self.tmp / "proj2"
        (proj2 / ".claude").mkdir(parents=True)
        (proj2 / ".claude/settings.json").symlink_to(self.tmp / "proj2-target.json")
        out = self.run_install("--project", proj2)
        self.check_out("skips a dangling settings.json link", out, "SKIP .*" + re.escape("settings.json (is a symlink"))
        self.check("does not create the link target", not (self.tmp / "proj2-target.json").exists())

    def copilot_install(self, cop, **env):
        return self.run_install("--copilot", env={"COPILOT_HOME": str(cop), **env})

    def test_copilot(self):
        cop = self.tmp / "copilot"
        out = self.copilot_install(cop, CLAUDE_HOME=str(self.tmp / "claude-untouched"))
        self.check("exits 0", out.rc == 0)
        self.check("links every skill", count_links(cop / "skills") == len(SKILLS))
        self.check("generates every agent", len(list((cop / "agents").rglob("*.agent.md"))) == len(AGENTS))
        gen = cop / "agents" / f"{AGENT_STEM}.agent.md"
        self.check("agent is a regular file, not a link", gen.is_file() and not gen.is_symlink())
        gen_text = gen.read_text(encoding="utf-8")
        self.check("agent keeps name and description", re.search(rf"^name: {re.escape(AGENT_STEM)}$", gen_text, re.M))
        self.check("agent gets a read-only tools allowlist",
                   "tools: ['read', 'search', 'execute', 'web', 'todo']" in gen_text.split("\n"))
        self.check_file_lacks("allowlist has no edit tool", gen, "'edit'")
        self.check_file_lacks("drops the model field", gen, "model:")
        self.check_file_lacks("drops the color field", gen, "color:")
        self.check_file_lacks("drops disallowedTools", gen, "disallowedTools:")
        source = (REPO / "agents" / AGENT).read_text(encoding="utf-8")
        self.check("keeps the instructions unchanged",
                   body_after_frontmatter(source) == body_after_generated_marker(gen_text))
        fm = re.match(r"\A---\n(.*?)\n---\n", gen_text, re.S).group(1).splitlines()
        src_fm = re.match(r"\A---\n(.*?)\n---\n", source, re.S).group(1).splitlines()
        src_desc = next(line for line in src_fm if line.startswith("description:")).split(":", 1)[1].strip()
        self.check("frontmatter keeps the source description exactly",
                   [line.split(":")[0] for line in fm] == ["name", "description", "tools"]
                   and fm[1].split(":", 1)[1].strip() == src_desc)
        self.check("does not touch ~/.claude", not (self.tmp / "claude-untouched").exists())
        self.check_out("says how to update", out, re.escape("run ./install.sh --copilot again"))
        self.check_out("explains MCP access when no servers are named", out,
                       "The specialist agents can use only the servers you name")
        self.check_out("VS Code tip: no setting needed", out, "^VS Code:  no setting needed")
        self.check_out("VS Code tip: agent dropdown", out, "pick an agent in the Agent dropdown")
        self.check_out("VS Code tip: Configure Skills menu", out, "/skills opens the Configure Skills menu")
        self.check_out("VS Code tip: Diagnostics", out, re.escape("right-click in the Chat view > Diagnostics"))
        self.check_out("IntelliJ tip: setting", out, re.escape("IntelliJ: turn on Settings > GitHub Copilot > Chat > Agent"))
        self.check_out("IntelliJ tip: admin policy", out, "Editor preview features policy")
        self.check_out("IntelliJ tip: agent dropdown", out, "pick an agent in the agent dropdown")
        self.check_lacks("no undocumented reload step", out, "Reload Window")
        readme = (REPO / "README.md").read_text(encoding="utf-8")
        for phrase in ("Configure Custom Agents", "Configure Skills", "Diagnostics",
                       "Settings > GitHub Copilot > Chat > Agent", "Editor preview features"):
            self.check(f"README mentions {phrase}", phrase in readme)
        self.check("README has no undocumented reload step", "Reload Window" not in readme)
        out = self.copilot_install(cop)
        self.check_out("re-run reports ok", out, re.escape(f"ok        agents/{gen.name}"))
        with open(gen, "a") as f:
            f.write("edited\n")
        out = self.copilot_install(cop)
        self.check_out("re-run updates a changed generated agent", out, re.escape(f"updated   agents/{gen.name}"))
        self.check_file_lacks("updated agent matches the source again", gen, "edited")
        self.copilot_install(cop, COPILOT_MCP_SERVERS="atlassian azure-devops")
        self.check("adds MCP servers to the allowlist",
                   "tools: ['read', 'search', 'execute', 'web', 'todo', 'atlassian/*', 'azure-devops/*']"
                   in gen.read_text().split("\n"))
        out = self.copilot_install(cop, COPILOT_MCP_SERVERS="mcp.dev.azure.com/sc-ado")
        self.check("exits 0 for a registry-style MCP server name", out.rc == 0)
        self.check("accepts a registry-style MCP server name",
                   "tools: ['read', 'search', 'execute', 'web', 'todo', 'mcp.dev.azure.com/sc-ado/*']"
                   in gen.read_text().split("\n"))
        self.check_lacks("no MCP hint when servers are named", out, "The specialist agents can use only the servers you name")
        for bad in ("bad;name", "it's", 'a"b', "x\\y", "$(id)", "a`b", "a,b", "a#b"):
            out = self.copilot_install(self.tmp / "cop-reject", COPILOT_MCP_SERVERS=bad)
            self.check(f"rejects MCP server name {bad}", out.rc == 1)
        self.check("writes nothing for rejected names", not (self.tmp / "cop-reject").exists())
        out = self.copilot_install(cop, COPILOT_MCP_SERVERS="bad;name")
        self.check("rejects an invalid MCP server name", out.rc == 1)

    def test_copilot_lead_delegates_and_specialists_stay_read_only(self):
        cop = self.tmp / "copilot"
        self.copilot_install(cop)
        claude_home = self.tmp / "home3-claude"
        self.run_install(env={"CLAUDE_HOME": str(claude_home)})
        lead = cop / "agents" / "qa-lead.agent.md"
        lead_text = lead.read_text(encoding="utf-8")
        lead_lines = lead_text.split("\n")
        self.check("qa-lead has no tools list (all tools, including every MCP server)",
                   not any(line.startswith("tools:") for line in lead_lines))
        self.check("qa-lead keeps Show your work", "## Show your work" in lead_lines)
        for rule in ("The plan is information, not approval", "A ▶ line announces a step; it does not approve one",
                     "never echo the user's raw text or anything secret", "Could not start <agent> as a subagent",
                     "the specialist cannot start as a subagent (then item 5 of Show your work applies)"):
            self.check(f"qa-lead Show your work: {rule}", rule in lead_text)
        # The fallback paths in qa-lead must match where the installers put the agent files.
        for path in ("~/.copilot/agents/<name>.agent.md", "~/.claude/agents/<name>.md", ".claude/agents/<name>.md"):
            self.check(f"qa-lead names fallback path {path}", f"`{path}`" in lead_text)
        self.check("Copilot install writes agents to ~/.copilot/agents/<name>.agent.md",
                   (cop / "agents/pr-reviewer.agent.md").is_file())
        self.check("Claude install links agents to ~/.claude/agents/<name>.md",
                   (claude_home / "agents/pr-reviewer.md").is_symlink())
        others = ", ".join(f"'{a[:-len('.md')]}'" for a in AGENTS if a != "qa-lead.md")
        self.check("qa-lead lists every other agent as a subagent", f"agents: [{others}]" in lead_lines)
        self.check_file_lacks("qa-lead does not list itself", lead, "'qa-lead'")
        for f in sorted((cop / "agents").glob("*.agent.md")):
            if f == lead:
                continue
            self.check_file_lacks(f"{f.name} has no edit tool", f, "'edit'")
            self.check_file_lacks(f"{f.name} has no agents list", f, "agents:")

    def test_copilot_write_access_is_opt_in(self):
        src2 = copy_repo(self.tmp / "src-noflag")
        reviewer = src2 / "agents/pr-reviewer.md"
        reviewer.write_text("".join(line for line in reviewer.read_text().splitlines(keepends=True)
                                    if not line.startswith("disallowedTools:")))
        self.run_install("--copilot", env={"COPILOT_HOME": str(self.tmp / "cop-noflag")}, script=src2 / "install.sh")
        self.check_file_lacks("an agent without the orchestrator marker stays read-only",
                              self.tmp / "cop-noflag/agents/pr-reviewer.agent.md", "'edit'")
        self.check_file_lacks("the marker itself is not copied", self.tmp / "cop-noflag/agents/qa-lead.agent.md",
                              "# copilot: orchestrator")
        # Runs the converter function on its own with a relative source path.
        fn = re.search(r"^copilot_agent\(\) \{\n.*?^\}\n", (src2 / "install.sh").read_text(), re.M | re.S).group(0)
        (self.tmp / "copilot_agent.sh").write_text(fn)
        rel = subprocess.run(["bash", "-c", '. "$1"; REPO=.; COPILOT_TOOLS="x"; COPILOT_MARKER="m"; '
                              "copilot_agent agents/qa-lead.md", "_", str(self.tmp / "copilot_agent.sh")],
                             cwd=src2, env=self.env, capture_output=True, text=True)
        self.check("the converter ran with a relative path", re.search(r"^agents: \[", rel.stdout, re.M), rel.stderr)
        self.check("a relative source path does not list the lead as its own subagent", "'qa-lead'" not in rel.stdout)

    def test_copilot_validates_before_writing(self):
        globdir = self.tmp / "globdir"
        self.write(globdir / "install.sh", "")
        self.write(globdir / "README.md", "")
        out = self.run_install("--copilot", env={"COPILOT_HOME": str(self.tmp / "cop-glob"), "COPILOT_MCP_SERVERS": "*"},
                               cwd=globdir)
        self.check("rejects a glob as an MCP server name", out.rc == 1)
        self.check("reports the literal glob, not expanded file names", "invalid server name '*'" in out.out)
        self.check("writes nothing for an invalid MCP list", not (self.tmp / "cop-glob").exists())
        out = self.copilot_install(self.tmp / "cop-bad", COPILOT_MCP_SERVERS="ok bad;name")
        self.check("rejects an invalid name in a list", out.rc == 1)
        self.check("writes nothing when one name is invalid", not (self.tmp / "cop-bad").exists())
        out = self.run_install("--copilot", "--help", env={"COPILOT_HOME": str(self.tmp / "cop-help")})
        self.check("--copilot --help exits 0", out.rc == 0)
        self.check("--copilot --help prints usage", "--copilot" in out.out)

    def test_copilot_converts_unusual_sources(self):
        src = copy_repo(self.tmp / "src-repo")
        crlf = src / "agents" / AGENT
        crlf.write_bytes(crlf.read_bytes().replace(b"\n", b"\r\n"))
        self.write(src / "agents/folded.md", "---\nname: folded\ndescription: >\n  First line of a folded description\n"
                                             "  and its second line.\nmodel: opus\n---\n\nBody.\n")
        cop_src = self.tmp / "cop-src"
        out = self.run_install("--copilot", env={"COPILOT_HOME": str(cop_src)}, script=src / "install.sh")
        self.check("exits 0", out.rc == 0)
        crlf_gen = cop_src / "agents" / f"{AGENT_STEM}.agent.md"
        with open(crlf_gen, encoding="utf-8", newline="") as f:  # newline="" keeps any \r visible
            crlf_text = f.read()
        self.check("converts a CRLF source", re.search(rf"^name: {re.escape(AGENT_STEM)}$", crlf_text, re.M))
        self.check("drops the carriage returns", "\r" not in crlf_text)
        source = (REPO / "agents" / AGENT).read_text(encoding="utf-8")
        self.check("keeps the CRLF agent's body", body_after_frontmatter(source) == body_after_generated_marker(crlf_text))
        folded = (cop_src / "agents/folded.agent.md").read_text()
        self.check("keeps a folded description", "  and its second line." in folded.split("\n"))
        self.check("drops model from the folded agent", "model:" not in folded)
        self.write(src / "agents/broken.md", "# no frontmatter\n")
        cop_broken = self.tmp / "cop-broken"
        out = self.run_install("--copilot", env={"COPILOT_HOME": str(cop_broken)}, script=src / "install.sh")
        self.check("fails on a source without frontmatter", out.rc == 1)
        self.check_out("names the broken source", out, r"cannot convert .*broken\.md")
        self.check_lacks("prints no usage text after the error", out, "Installs the QA agents")
        self.check("writes nothing when a source is broken", not cop_broken.exists())
        self.write(src / "agents/broken.md", "---\nname: nodesc\n---\nBody.\n")
        out = self.run_install("--copilot", env={"COPILOT_HOME": str(cop_broken)}, script=src / "install.sh")
        self.check("fails on a source without a description", out.rc == 1)

    def test_copilot_removes_links_to_skills_that_left_the_repo(self):
        cop = self.tmp / "copilot"
        self.copilot_install(cop)
        (cop / "skills/moved-skill").symlink_to(REPO / "skills/moved-skill")
        out = self.copilot_install(cop)
        self.check("removes the dead skill link", not (cop / "skills/moved-skill").is_symlink())
        self.check_out("reports it", out, re.escape("removed   skills/moved-skill (no longer in this repo"))
        (cop / "skills/old-skill").symlink_to("/old/clone/skills/old-skill")
        (cop / "skills/keep-me").symlink_to(f"/old/clone/skills/{SKILL}")
        self.copilot_install(cop)
        self.check("removes a moved clone's link to a skill no longer shipped", not (cop / "skills/old-skill").is_symlink())
        self.check("keeps a broken link whose name does not match its target", (cop / "skills/keep-me").is_symlink())

    def test_copilot_keeps_foreign_agents_and_cleans_up_removed_ones(self):
        cop2 = self.tmp / "copilot2"
        own = self.write(cop2 / "agents" / f"{AGENT_STEM}.agent.md", "my own agent\n")
        self.write(cop2 / "agents/gone.agent.md",
                   "---\nname: gone\n---\n<!-- Generated by claude-qa-automation/install.sh --copilot from agents/gone.md -->\n")
        self.write(cop2 / "agents/unrelated.agent.md", "unrelated\n")
        out = self.copilot_install(cop2)
        self.check_out("backs up a foreign agent with the same name", out, re.escape(f"backed up agents/{own.name}"))
        self.check("removes a generated agent whose source is gone", not (cop2 / "agents/gone.agent.md").exists())
        self.check("keeps unrelated agents", (cop2 / "agents/unrelated.agent.md").is_file())
        out = self.run_install("--copilot", "--uninstall", env={"COPILOT_HOME": str(cop2)})
        self.check("uninstall exits 0", out.rc == 0)
        self.check("uninstall restores the foreign agent", own.read_text() == "my own agent\n")
        left = [p.name for p in (cop2 / "agents").rglob("*.agent.md") if p.name not in (own.name, "unrelated.agent.md")]
        self.check("uninstall removes the other generated agents", not left, left)
        self.check("uninstall removes the skill links", count_links(cop2 / "skills") == 0)
        self.check("uninstall keeps unrelated agents", (cop2 / "agents/unrelated.agent.md").is_file())
        self.check_lacks("uninstall does not mention settings.json", out, "settings.json")
        out = self.run_install("--copilot", "--settings")
        self.check("--copilot rejects other options", out.rc == 1)

    def test_install_knobs_are_all_listed(self):
        script = INSTALL.read_text(encoding="utf-8")
        read = set(re.findall(r"\$\{([A-Z][A-Z0-9_]*):-", script)) | set(re.findall(r'os\.environ\.get\("([A-Z0-9_]+)"', script))
        self.assertEqual(read - set(INSTALL_KNOBS), set(), "add these to INSTALL_KNOBS")

    def test_a_knob_in_the_developer_shell_does_not_leak_in(self):
        self.env = self.make_env({**os.environ, "COPILOT_MCP_SERVERS": "github"})
        cop = self.tmp / "copilot"
        out = self.copilot_install(cop)
        self.assertEqual(out.rc, 0, out.out)
        gen = (cop / "agents" / f"{AGENT_STEM}.agent.md").read_text()
        self.check("a shell COPILOT_MCP_SERVERS is ignored",
                   "tools: ['read', 'search', 'execute', 'web', 'todo']" in gen.split("\n"))

    def test_no_setting_is_inherited(self):
        own = {"HOME": "x", "CLAUDE_HOME": "x", "COPILOT_HOME": "x"}  # make_env sets these itself
        env = self.make_env({**os.environ, **{k: "leaked" for k in INSTALL_KNOBS}, "QA_FUTURE_HOOK": "leaked"})
        for name in [k for k in INSTALL_KNOBS if k not in own] + ["QA_FUTURE_HOOK"]:
            self.check(f"{name} is not inherited", name not in env)
        for name in own:
            self.check(f"{name} is the test's own", env[name] != "leaked")

    def test_check_file_lacks_fails_on_a_missing_file(self):
        with self.assertRaises(FileNotFoundError):
            self.check_file_lacks("a missing file", self.tmp / "no-such-file", "x")

    def test_arguments(self):
        out = self.run_install("--help")
        self.check("--help exits 0", out.rc == 0)
        self.check("--help prints usage", "--settings" in out.out)
        self.check("--help prints the whole header", "ends with a summary of what was added, updated and left" in out.out)
        self.check_lacks("--help does not print the shell options line", out, "set -euo pipefail")
        out = self.run_install("--bogus")
        self.check("a bad argument prints the whole usage", "ends with a summary of what was added, updated and left" in out.out)
        self.check("missing project dir exits 1", self.run_install("--project", self.tmp / "nope").rc == 1)
        self.check("extra --settings argument exits 1", self.run_install("--settings", "extra").rc == 1)
        self.check("extra --uninstall argument exits 1", self.run_install("--uninstall", "extra").rc == 1)
        self.check("unknown argument exits 1", self.run_install("extra").rc == 1)


if __name__ == "__main__":
    unittest.main()
