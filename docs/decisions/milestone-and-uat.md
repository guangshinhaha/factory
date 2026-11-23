# Milestones and UAT in the factory

Date: 2026-11-20. Decided with the fable advisor (plan on #36). Issue #79.

## Decision

The factory builds no milestone or UAT code. Both ride on things it already has.

### Milestone

A milestone is a sprint goal: a GitHub milestone plus one tracking issue.

- The order lives in one place: the tracking issue body (an ordered list, with `Depends on` lines for sequencing).
- A repo points the factory at it with `factory-release-path: #N` in its CLAUDE.md (#46). `sf-state` then starts only listed `ready` issues, earliest first, and still honours `Depends on`.
- The GitHub milestone description links to the tracking issue. It holds no second copy of the order.
- `sf-state` has no milestone awareness, and gets none.
- To start the next milestone, make a new tracking issue and change the one CLAUDE.md line.

### UAT

UAT is the set of live checks only Shin can do after a milestone merges.

- `sf-act` writes `Closes #N` on every PR, so a merged issue closes and `sf-state` never sees it again. UAT does not hold anything open.
- `shinstack:uat` already handles closed issues that have no `UAT pass` comment (it reports them as closed early). Shin runs it when he returns.
- UAT hangs off the GitHub milestone, not the release-path issue. While the release-path issue is open, only its listed issues start, so holding it open for UAT would block the next milestone.
- It never blocks the next milestone: the next tracking issue starts it.

## Not building

- A `hands-on` label.
- `Refs #N` instead of `Closes #N` for UAT items.
- Milestone logic in `sf-state`.

## Open

- Nothing advances the release path by itself between milestones; a person (or the milestone skill) edits the CLAUDE.md line. A set key that cannot be resolved (missing or unreadable issue) starts nothing and says so (#71).
