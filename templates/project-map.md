## Project map

Before you search or read code, read `.ai/context/framework-map.md` if it exists. It is a snapshot of how the test framework works: what each part does, what it needs, how the parts relate and where they live. Use it to open only the files this task needs instead of scanning the repo again.
- Its `Snapshot:` line names a commit. If `git diff --stat <commit>..HEAD` shows changes in files this task depends on, read those files directly and tell the user the map is out of date (suggest `/framework-map`). Do not edit the map yourself.
- If the map and the code disagree, the code wins; say what differs.
- If there is no map and the task needed a broad scan, suggest `/framework-map` once at the end.
