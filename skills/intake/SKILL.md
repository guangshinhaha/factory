---
name: intake
description: "Factory intake station: decide whether a ready issue can be built, at what tier, as what kind of work, and whether a plan comes first. Use only from a factory brief whose first line is `factory-role: intake`."
---

# Intake

Runs as: T3 child (dispatched by factory:foreman via delegate_task), clean worktree already checked out (the repo's main branch). Read-only.

You decide; the factory acts. Read the issue and return one decision in your result line. Never call `sf-stop` or `sf-hold`, never edit, label or comment on the issue, and never commit.

## Steps

1. **Read the issue:** `gh issue view <n> -R <repo> --json title,body,labels` and `--comments`. A later comment overrides the body only if the repo owner or the issue's author (a person) wrote it, never an agent or the factory (`factory:` comments).
2. **Done when.** Apply step 1 of the brief's playbook (`feature.md`): the issue, or a plan it links, must state something a person or a test can check when the work is done, under any heading. "Running `greet` prints hello" passes. A goal with nothing to check ("make onboarding better"), or a Done when only a sentence could satisfy ("README mentions the flag"), fails: `stop`, naming what's missing. A Decided item that the code already contradicts is also a `stop`, with the evidence.
3. **Dependencies.** A `Depends on` list is the factory's to check: it holds the issue until those close. Your job is the undeclared kind: the work needs code from another open issue that the issue doesn't list (it names a module, command or API that doesn't exist yet, and an open issue builds it). Check with `git grep` and `gh issue view`. Found: `hold`, with `depends_on` and the reason. Only for an open issue you found; a hunch is not a hold.
4. **Tier** (`none`, `low`, `medium`, `high`): a `risk:<tier>` label sets it. With no label, take it from the review table in `<shinstack>/playbooks/opening-a-pr.md`, and from the repo's own rules: CLAUDE.md, and `.github/gantry-risky-paths` (any file the work must touch that matches is `high`). Unclear: take the higher tier.
5. **Work type** from the labels: `bug` is `bug-fix`, `enhancement` is `feature`, `refactor` is `refactoring`. No label, or labels that disagree: judge from the body (broken behaviour is `bug-fix`, unchanged behaviour with new structure is `refactoring`, otherwise `feature`).
6. **Plan first?** `<shinstack>/playbooks/plan.md` step 1: skip the plan when the change is one or two files with an obvious approach. If the issue links a plan (an issue or comment with a checklist) the plan exists. Otherwise, work that is multi-file, cross-cutting or has a real design fork the issue doesn't settle is `"plan_first": true`.

## Result

Success status: `go`. Everything else reports `--outcome failed`.

- `go`: `{"station":"intake","status":"go","tier":"medium","work_type":"feature","plan_first":false}`
- `stop`: `{"station":"intake","status":"stop","reason":"no observable Done when: the issue says 'make onboarding better' and nothing a test can check"}`
- `hold`: `{"station":"intake","status":"hold","reason":"needs the sf-act command that #7 builds","depends_on":[7]}`

Before the result line, give the evidence for each call in one line: the Done when items you found, the dependency search, the label or path that set the tier.
