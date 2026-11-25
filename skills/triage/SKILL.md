---
name: triage
description: "Factory triage: walk a repo's needs-shin issues with Shin one at a time, each with its stop reason and a recommended answer, then re-ready, icebox or close it; first reconcile needs-shin issues whose PR merged or that closed. Use when Shin says triage, needs-shin, or asks what the factory is waiting on. Interactive; never a factory station."
---

# Triage

Runs as: Shin's own chat, in or about one repo (the argument, else the current directory's repo). Not a station: a brief with a `factory-role:` line never runs triage; decline it.

The factory stops an issue with `sf-stop`: a `factory: stopped. <reason>` comment, `ready` swapped for `needs-shin`. Triage is the only way back. **Only triage adds `ready`, and only on Shin's answer for that issue** ("ready all of these" counts for the issues it names).

## Steps

1. **List once.** `gh issue list -R <repo> --state all --limit 1000 --json number,title,state,labels,updatedAt`, then filter with jq. Never `--label` or `--search`: they use GitHub's search API, whose small limit once blocked the factory for 26 hours. Take merged PRs the same way: `gh pr list -R <repo> --state merged --limit 200 --json number,url,headRefName,mergedAt,body`. An issue's PR is one whose branch's last path segment is `<repo-name>-<n>` or starts `<repo-name>-<n>-` (how `sf-state` matches), or whose body says `Closes #<n>`.
2. **Reconcile, without asking**, and list what you did:
   - closed issue still labelled `needs-shin`: `gh issue edit <n> -R <repo> --remove-label needs-shin`.
   - open `needs-shin` issue whose PR merged: don't change it here. It goes first in the walk, with a recommended answer of close (the merged PR did the work; a `Refs` PR may have left scope open, so check its `## Scope` against the Done when).
3. **Walk the rest**, oldest stop first, one issue per turn. For each, read the issue and comments and any open PR on its branch, then show:
   - `#<n> <title>` and its link;
   - the stop reason: the newest `factory: stopped.` comment, quoted;
   - what you found: whether the reason still holds (a dependency that has since closed, a Done when now present, a PR with review findings or a FAIL verdict), in two or three lines;
   - **Recommended:** one answer, why, and the exact change it makes. Then the other options.
   Ask with AskUserQuestion, recommended answer first. Wait for the answer before the next issue.
4. **Act on the answer:**
   - **Re-ready:** if the answer settles scope (a Done when, a decision, a `Depends on` line), first edit the issue body: put it in `## Done when`, `## Decided` or `Depends on #N`, show Shin the change, then `gh issue edit <n> -R <repo> --body-file <file>`. The body is what the next build reads. Then `gh issue edit <n> -R <repo> --remove-label needs-shin --add-label ready`. Re-readying starts a fresh attempt count. If an earlier PR is still open on the issue's branch, say so: the next Run reuses it.
   - **Icebox:** `--remove-label needs-shin --add-label icebox`.
   - **Close:** `gh issue close <n> -R <repo> --comment "<Shin's reason>"`, then remove `needs-shin`.
   - **Skip:** change nothing; it stays `needs-shin`.
   - **Worktree, after a re-ready or a close:** remove that issue's worktrees, which the stop kept for you. Run git against `<checkout>`, the main checkout of `<repo>` on this machine (the current directory only if `git remote get-url origin` there names `<repo>`; otherwise ask Shin for the path): never against another repo's. `git -C <checkout> worktree list --porcelain`, then take entries that are not the main worktree and whose branch is `<repo-name>-<n>` or `debrief-<repo-name>-<n>`. **Never a dirty one:** if `git -C <path> status --porcelain` prints anything, leave it and tell Shin its path. Otherwise `git -C <checkout> worktree remove <path>` then `git -C <checkout> branch -d <branch>` (lower-case: git refuses an unmerged branch; if it refuses, keep the branch and tell Shin which one and why). Never touch any other worktree. Icebox and skip keep the worktree.
5. **Consult picks.** From step 1's list, the open issues carrying the `consult-shin` label in step 1's JSON, each with its newest `consult-shin (provisional)` comment; low confidence and user-facing first. Show each pick; Shin answers *agree* (`--remove-label consult-shin`) or *I'd have said X* (apply X, then remove the label). Removing the label releases the merge hold.
6. **Finish** with one line per issue: `#<n>: re-readied | iceboxed | closed | skipped | reconciled | consult agreed | consult changed`, and X of N cleared.

## Rules

- Write only what step 2 and Shin's answers name: labels (including `consult-shin`), a body edit Shin saw, a close comment, and removing the issue's clean worktrees (step 4). Never post `factory:` comments or markers, and never call `sf-stop`, `sf-hold` or `sf-ship`.
- A stop that names a factory fault (a gate bug, a station that misread the issue) is not fixed by re-readying alone: recommend filing the fault on guangshinhaha/factory as well.
- Never paste issue content into an external service; issues may hold user data.
