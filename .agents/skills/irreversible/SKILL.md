# Irreversible operations

Read this before running risky, destructive, or hard-to-revert operations.

## Goal

Prevent data loss, unwanted history changes, and broad side effects.

## Treat as risky

Confirm before operations that may:

- delete or overwrite user-authored files
- change git history that has been pushed (amend, rebase, or reset of pushed commits, and the force-push that follows), or push to `main`
- delete, overwrite, or replace binary FLAC test fixtures
- affect databases, secrets, or production data
- modify files outside the repository
- apply broad formatting or auto-fixes outside the task scope
- install, remove, or upgrade dependencies

Judge deletion and overwrite risk by impact and recoverability, not by command name alone.

## Not risky (no confirmation needed)

- Ordinary pushes of new commits to a topic branch (see `.agents/skills/git-commit/SKILL.md`).

## Pre-check

Before asking for confirmation, check:

- current state, such as `git status`
- existing diff, such as `git diff`
- whether the target is tracked, generated, or user-authored
- whether a dry-run, backup, narrower target, or single-file trial is available

## Confirmation format

Ask once, using this format:

- Action:
- Impact:
- Command:

`Proceed?`

Include recovery notes in `Impact` when relevant.

## Refuse to proceed

Do not proceed if:

- the target is unclear
- the impact cannot be explained
- recovery is unknown for a hard-to-restore target
- the command affects files outside the task scope
- unrelated user changes may be overwritten

Report the current status instead.
