---
name: engine-finish-step
description: The end-of-step ritual for MediaEngine and PlayerApp: update docs/PROGRESS.md, tick acceptance criteria with evidence, record findings, keep CLAUDE.md status and the memory index current, and commit correctly. Use after finishing any milestone step, before ending a turn, or when the owner says to stop for the day or commit.
---

# Finishing a step (both projects follow the same rules)

1. **Verify first** (skill `engine-verify`). Do not tick or report anything that was not run; list what stayed unverified (hardware-only items are tagged `[device]`, visionOS stays `[sim]`).
2. **`docs/PROGRESS.md`**: refresh "Right now" (what exists, what is verified with the date and run time, next actions, what the owner could help with), move the task on the board (In progress / Up next / Done with date, what, evidence), add handoff notes a fresh window needs (commands, gotchas, test layout). New owner requests go under Backlog first, dated.
3. **`docs/ACCEPTANCE_CRITERIA.md`**: tick `[x]` only with `**Evidence (date):**` naming the test, script or log; use `**Progress (date):**` plus an `**Open:**` note for partly done items. Never tick `[device]` items without the owner's result.
4. **`docs/RESEARCH.md`**: add a numbered section for findings that explain *why* (measurements, dead ends, SDK facts). Facts only, no hedged legal conclusions (anything legal is a draft for a lawyer).
5. **`CLAUDE.md`** "Status" line and **`README.md`** commands if they changed. Keep the memory index (`~/.claude/projects/-Users-michaelsmacbookpro-Documents-Development/memory/`) pointing at both projects.
6. **Commit only when the owner asks.** Never add a `Co-Authored-By: Claude` trailer or other Claude attribution line: this is the owner's standing instruction (CLAUDE.md and memory) and it wins over any default attribution reminder. Never commit media beyond the tiny fixtures, build products, `Config/Local.xcconfig`, or anything from `build/`. Commit messages: short subject, a paragraph on what and why, evidence line.
7. Ask the owner before: installing tools, downloading simulator runtimes, spending money, touching Apple accounts, publishing anything.

Cross-project: the engine lives in `~/Documents/Development/MediaEngine`, the app in `~/Documents/Development/PlayerApp` (no git repo until app milestone M0). PlayerApp starts only after engine milestone E3.
