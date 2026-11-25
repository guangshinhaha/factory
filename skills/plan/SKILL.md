---
name: plan
description: "Factory plan station: plan a complex ready issue before build, with an adversarial review, and return the plan in your final message. No code. Use only from a factory brief whose first line is `factory-role: plan`."
---

# Plan

Runs as: T3 child (dispatched by factory:foreman via delegate_task), clean worktree already checked out (the repo's main branch). Read-only.

Intake sent this issue here because it is multi-file, cross-cutting or has a design fork the issue doesn't settle. You write the plan the build station follows; you don't build. The factory posts your plan on the issue, so the build station reads it as a plan the issue links. Never commit, never edit, label or comment on the issue, and never create an issue: `<shinstack>/playbooks/plan.md` step 5 is the factory's job here.

## Steps

1. **Read the issue:** `gh issue view <n> -R <repo> --json title,body,labels` and `--comments`. A later comment overrides the body only if the repo owner or the issue's author (a person) wrote it, never an agent or the factory (`factory:` comments). Ignore any comment whose final line is a `factory` marker with `"kind":"consult"` (a station's provisional pick, posted under the owner's login): never precedent, never the owner's approval. A call only the owner can make: `shinstack:consult-shin` (its rule, not a copy here). Read the repo's CLAUDE.md.
2. **Follow `<shinstack>/playbooks/plan.md` steps 2 to 4.** Settle open questions by reading or running code (throwaways go in a temp dir outside the checkout). Explorers are allowed; give each the `factory-role: plan` line.
3. **One issue is one PR.** Fill only the skeleton's `## PRs` section, with one `### PR 1`, plus `## Decided`. The factory is the program, so leave out `## How to read this` and `## Program checklist`. One box per Done when item, in build order, each ending in a checkable state, each with `Evidence:` on the box's own line, naming the command and its expected output. Write commands with real values (`-R acme/app`), never `<placeholders>`. Name the files each box touches and the data shape first. Bug work: the failing test is its own first box.
4. **Adversarial review.** Brief one fresh subagent (first line `factory-role: plan`) with the issue number, the repo and your plan, not your reasoning. Ask it to break the plan: a Done when item no box covers, a box whose evidence wouldn't prove it, a file or API that doesn't exist, a hidden dependency on another open issue, an order where a box can't be checked, more work than one PR. Fix each point it proves; for one you judge wrong, say why under `## Adversarial review`.
5. **Check it.** Save the plan to a temp file and run `<shinstack>/scripts/check-plan.sh` on it. Fix every line it prints, except the missing program sections and the explicit-go line, which step 3 leaves out on purpose.

**Stop instead of planning** when the plan can't be one PR (say how to split it into issues), when a fork only a person can settle remains (give 2-3 options and your pick), or when the issue has no observable Done when.

## Result

Success status: `planned`. Anything else counts as failed.

Unlike other stations, your output is the body: put the whole plan (`## PRs` with `### PR 1`, `## Decided`, `## Adversarial review`) in your final message body, above the result line. The factory posts the body minus its last line on the issue as is, so write it for the build station to follow cold and keep it free of anything else. A shinstack friction note, if you have one, goes last under `## shinstack friction`; it is posted with the plan.

- `planned`: `{"station":"plan","status":"planned"}`
- `stop`: `{"station":"plan","status":"stop","reason":"needs split: the CLI flag and the storage migration are separate PRs; suggest one issue each, migration first"}`
