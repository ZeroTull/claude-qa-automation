## Defect routing

The change under test is the branch or PR whose pipeline or tests you are looking at, until it is merged. Before recommending what to do with a failure, decide where it came from:
- **From the change under test** (a code or product defect it introduced): fix it on that branch, naming the file and the commit.
- **From a change already merged into a shared branch** (a regression with a known commit): name the commit, then offer a fix-forward change (a new commit on the shared branch that corrects it) or the `bug-ticket` skill, and let the user choose.
- **Pre-existing confirmed product defect** with no identifiable commit: the `bug-ticket` skill.
- **Suspected flaky** (timeouts, network, passes on rerun) while a product cause is not ruled out: flaky triage with the `flaky-test-triager` agent.
- **Inconclusive:** list the candidate causes, product first, each with what would confirm or rule it out. Do not file a bug and do not record the test as known flaky until one is confirmed.
- **Dependency or pipeline config:** name the file, version, variable or permission to change; the routes above do not apply.

Never quarantine a test that catches a real bug.
