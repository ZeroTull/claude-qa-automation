## Defect routing

Before recommending what to do with a failure, decide where it came from:
- **From the change under test** (a code or product defect that this branch or PR introduced): fix it on that branch, naming the file and the commit. If that change is already merged into a shared branch, offer a fix-forward change (a new commit on the shared branch that corrects it) or the `bug-ticket` skill, and let the user choose.
- **Pre-existing, confirmed product defect:** the `bug-ticket` skill. Never quarantine a test that catches a real bug.
- **Suspected flaky** (timeouts, network, passes on rerun) while a product cause is not ruled out: flaky triage with the `flaky-test-triager` agent.
- **Inconclusive:** list the candidate causes, product first, each with what would confirm or rule it out. Do not file a bug and do not record the test as known flaky until one is confirmed.
