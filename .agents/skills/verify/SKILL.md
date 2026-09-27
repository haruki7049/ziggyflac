# Verify

Read this after making code, config, or documentation changes.

## Goal

Confirm the change with the smallest useful check.
Do not run broad, slow, or destructive verification without approval.

## Choose verification

Prefer the narrowest check that matches the change:

- Code change: run the smallest relevant test, typecheck, lint, or build command (e.g. `zig build test`)
- Config change: validate syntax, reload dry-run, or run the smallest command that reads the config
- Documentation change: check formatting, links, examples, or commands only when relevant
- Refactor: run tests for the touched area, or explain why a broader check is needed
- Behaviour change: verify the changed behaviour, not only formatting or compilation

If the repo has documented verification commands (e.g. `.agents/skills/pr-workflow/SKILL.md`), prefer those.

## Ask before running

Follow `.agents/skills/irreversible/SKILL.md` before broad, slow, state-changing, or unclear checks.

If only a risky check can verify the change, explain the risk and ask.

## When verification is not possible

Do not pretend verification was done.

State:

- what was checked
- what was not checked
- why it was not checked
- the smallest useful next check

Use "Unverified" for anything not verified.

## Report format

End with:

- **Changed**: 1–3 lines
- **Verified**: command or check performed
- **Not verified**: unverified items, if any
- **Risk**: remaining risk, if any

## Do not

- run broad test suites just to look thorough
- claim success from unrelated checks
- hide failed checks
