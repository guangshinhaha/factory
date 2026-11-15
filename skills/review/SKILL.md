---
name: review
description: "Factory review station: a cross-model review of a factory PR at the depth its tier names, posted as one Covered/Findings PR comment. Use only from a factory brief whose first line is `factory-role: review`."
---

# Review

Runs as: Orca worker, `--agent codex --model codex-auto-review` (Orca's own Codex account; never the bare `codex` CLI login), in the PR branch's worktree. Read-only, apart from one PR comment.

You review someone else's code from a different model family. You find what is wrong and prove it; you don't fix it.

## Steps

1. **Pin the head.** `gh pr view <pr> -R <repo> --json headRefOid,baseRefName,body` and `git rev-parse HEAD` must match. If they don't, `stop`: "head moved". Don't commit, checkout or change any file.
2. **Read the contract:** the issue (brief) and the PR's `## Scope`. Read the diff: `git diff origin/<base>...HEAD` after `git fetch origin <base>`.
3. **Review at the tier's depth** (the table in `<shinstack>/playbooks/opening-a-pr.md`):
   - `none`, `low`: a low-level code review of the diff: correctness bugs a caller would hit.
   - `medium`: the same at medium depth: also behaviour across modules, error paths and the tests' reach. If the tests are thin, go a level deeper.
   - `high`: read `<shinstack>/skills/blast-radius/SKILL.md` and follow it, then `<shinstack>/skills/interrogate/SKILL.md`. Where it says to spawn adversaries and you can't, run at least two attack angles yourself.
4. **Prove each finding** with a run: a failing test, a repro script or command output (keep repros outside the worktree, in a temp dir). A finding you didn't run is a note, not a finding. Blocking means a failing run, a bug a user would hit, a broken gate or an unmet Done when item. Everything else is a note.
5. **Round 2** (the brief says so): find your round-1 comment on the PR. Check each of its findings at the new head, then review what changed since.
6. **Post one PR comment** with `gh pr comment <pr> -R <repo> --body-file <file>`:

```
factory review: round <n>, tier <tier>, head <40-char sha>

Covered: <the diff range and files you read, the depth, the kinds of problem you checked, the commands you ran>

Findings:
1. <title> (`path:line`): what breaks, the command, its output, and what the issue needs instead.

Notes:
- <non-blocking, one line each>
```

Write `Findings: none` when nothing survives. `Covered:` is required: a review that doesn't say what it covered counts as not run, and so does an empty comment. Drop `Notes:` if there are none.

## Usage limit and access

A Codex usage limit is a hold, never a skip: if a command or tool reports a Codex usage limit, post no comment and report `hold` with `provider` `codex` and the reset time in UTC (`2026-11-15T10:00:00Z`; when you can't tell, an hour from now). If Codex can't start at all (not installed, not signed in), there is no worker to report: the factory sees the failed start and posts `Codex review not run: <reason>` itself. Never post that line from here.

## Result

Success status: `clean`. Everything else reports `--outcome failed`.

- `clean`: `{"station":"review","status":"clean","head_sha":"<sha>","comment_url":"<url>","notes":2}`
- `findings`: `{"station":"review","status":"findings","head_sha":"<sha>","comment_url":"<url>","findings":3}`
- `hold`: `{"station":"review","status":"hold","provider":"codex","reset":"2026-11-15T10:00:00Z","reason":"Codex usage limit"}`
- `stop`: `{"station":"review","status":"stop","reason":"head moved: PR is at <sha>, worktree at <sha>"}`
