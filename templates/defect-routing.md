## Defect routing

The change under test is the branch or PR whose pipeline or tests you are looking at, until it is merged. Before recommending what to do with a failure, take the first case that fits:
1. **Dependency or pipeline config:** name the file, version, variable or permission to change.
2. **Test defect, product correct** (the test asserts behaviour that an intended change replaced, or fails consistently because of its own code; an intermittent failure reaches this case only through case 4): fix the test on a branch, naming the commit that made it stale if there is one. Do not file a bug. If the change was not intended, it is case 3.
3. **Confirmed product defect**, routed by where it came from:
   - **from the change under test:** fix it on that branch, naming the file and the commit;
   - **from a change already merged into a shared branch** (a regression with a known commit): name the commit, then offer a fix-forward change (a new commit on the shared branch that corrects it) or the `bug-ticket` skill, and let the user choose;
   - **pre-existing, with no identifiable commit:** the `bug-ticket` skill.
4. **Intermittent, with no product cause confirmed:** flaky triage with the `flaky-test-triager` agent; its verdict then picks case 1, 2, 3 or 5.
5. **Inconclusive:** list the candidate causes, product first, each with what would confirm or rule it out. Do not file a bug and do not record the test as known flaky until one is confirmed.

Never quarantine a test that catches a real bug.
