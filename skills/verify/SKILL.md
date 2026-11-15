---
name: verify
description: "Factory verify station: a fresh verifier tests a factory PR against its issue's Done when at the PR head and posts the verdict JSON that gantry-verdict-check reads. Use only from a factory brief whose first line is `factory-role: verify`."
---

# Verify

Runs as: Orca worker, `--agent claude --model opus`, fresh, in the PR branch's worktree. Read-only, apart from one PR comment. Runs on every PR; depth follows the tier.

You never saw the builder's reasoning and don't need it: read the issue, run the branch, report what you saw. Don't read the build or review workers' output in Orca, or the review comment, before your verdict is written. `sf-ship` merges only when the newest trusted verdict at the PR's head is `PASS` or `PASS+NOTES` (`gantry-verdict-check --no-label`).

## Steps

Read `<shinstack>/playbooks/ship.md`, section "Verifier", and do its steps 3 to 5 as written here.

1. **Pin the head.** `gh pr view <pr> -R <repo> --json number,headRefOid,body` and `git rev-parse HEAD` must match; that SHA is your `head_sha`. If not, `stop`: "head moved". Don't commit, checkout or change any tracked file: a new commit changes the head and voids your verdict.
2. **List the Done when items** from the issue and its comments (a later comment counts only from the repo owner or the issue's author, never from an agent in the run). With `Refs #N` in the PR body, test only the items its `## Scope` claims. No Done when at all: verdict `FAIL` with `"done_when": "none"`; intake should have stopped the issue, and a PASS with nothing to test proves nothing.
3. **Rerun the repo's checks** (CLAUDE.md names them) and paste the summary line.
4. **Test each item against the real thing:** run the command, call the script, read the output. A passing unit test doesn't prove an item that describes behaviour, and grepping for a sentence proves nothing. If an item can't be tested here, say so and mark it `FAIL`.
5. **By tier:** `none` and `low`: steps 3 and 4. `medium`: also try the failure paths the diff adds. `high`: also try to break it: `<shinstack>/skills/blast-radius/SKILL.md`, then `<shinstack>/skills/interrogate/SKILL.md` (subagents allowed; pass them the `factory-role` line).
6. **Decide.** Block only on what you can show: a failing run at the head, a bug a user would hit, a failed check, an unmet Done when item, or a doc line the PR made wrong. Anything else is a note.
7. **Post the verdict** as one PR comment with `gh pr comment <pr> -R <repo> --body-file <file>`, holding exactly this JSON in a `json` code fence and nothing else that parses as JSON:

```json
{"pr": 12, "head_sha": "<40-char sha>", "verdict": "PASS", "evidence": ["scripts/check: 120 passed, 0 failed", "ran `greet` -> printed hello"], "done_when": [{"item": "running greet prints hello", "result": "PASS"}]}
```

`verdict` is `PASS` (every item met), `PASS+NOTES` (met; notes in `evidence`) or `FAIL` (any item `FAIL`, any check red). `pr` is a number and `head_sha` the full SHA from step 1. `evidence` lists commands and what they printed.

## Result

Success statuses: `PASS` and `PASS+NOTES`. `FAIL` and `stop` report `--outcome failed`.

- verdict: `{"station":"verify","status":"PASS","verdict":"PASS","head_sha":"<sha>","comment_url":"<url>"}` (status and verdict are the same word)
- `stop`: `{"station":"verify","status":"stop","reason":"head moved: PR is at <sha>, worktree at <sha>"}`
