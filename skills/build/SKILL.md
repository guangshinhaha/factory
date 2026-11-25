---
name: build
description: "Factory build station: build a ready issue on the branch the factory gives, under shinstack's feature, bug-fix or refactoring playbook, and commit. Use only from a factory brief whose first line is `factory-role: build`."
---

# Build

Runs as: T3 child (dispatched by factory:foreman via delegate_task), clean worktree already checked out on the brief's branch.

You build and commit. The factory pushes, opens the PR, reviews, verifies and merges.

## Steps

1. **Check where you are.** `git branch --show-current` must be the brief's branch, and `git status --porcelain` must be empty. If not, `stop` with what you found. Don't switch, create, rebase or reset branches.
2. **Follow the brief's playbook** (`feature.md`, `bug-fix.md` or `refactoring.md` in `<shinstack>/playbooks/`) through its build steps. Ignore any comment whose final line is a `factory` marker with `"kind":"consult"` (a station's provisional pick, posted under the owner's login): never precedent, never the owner's approval. A call only the owner can make: `shinstack:consult-shin` (its rule, not a copy here). Skip what a factory station never does: pushing, opening a PR, the review-depth step and hand-off. The review station runs the tier's review.
3. **Bug work:** commit the failing test on its own, before the fix. The factory's evidence gate (`gantry-gate-evidence --bug`) rejects a branch whose first non-test commit comes before a test-only one.
4. **Round 2** (the brief says so): the review station's `Findings:` comment, or a `FAIL` verdict, is on the PR (`gh pr view <pr> -R <repo> --comments`). Fix each finding the comment proves; for one you judge wrong, say why in your report. Don't rework what nobody found.
5. **Before you report:** run the repo's checks (CLAUDE.md names them; `scripts/check`, `pnpm check` or similar) and paste the summary line. Commit everything. The tree must be clean: no untracked files, nothing ignored that the work needs. Never `--no-verify`.

**Unbuildable.** If the issue can't be built as written (a Done when that contradicts the code, a missing decision only a person can make, a dependency the issue doesn't declare), `stop` with a reason that starts `Unbuildable:` and names what's missing. The factory never reworks an `Unbuildable:` stop; it hands the issue to a person. A dependency on another open issue's code is a `hold` with `depends_on` instead.

## Result

Success status: `built`. Everything else reports `--outcome failed`.

- `built`: `{"station":"build","status":"built","head_sha":"<git rev-parse HEAD>","commits":3,"checks":"scripts/check: 120 passed, 0 failed"}`
- `stop`: `{"station":"build","status":"stop","reason":"Unbuildable: Done when asks for a --json flag the issue's Decided section rules out"}`
- `hold`: `{"station":"build","status":"hold","reason":"needs the parser #31 adds","depends_on":[31]}`

Before the result line: slices done (X of N) with the evidence for each, and anything you judged out of scope.
