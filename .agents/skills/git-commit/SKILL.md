# Git Commit Policy & Conventions

Read this to understand the commit policy and message conventions for `ziggyflac`.

## Prohibition on Unprompted Commit/Push Proposals

- **Execution is allowed**: When instructed by the user, or when creating and updating pull requests on topic branches, AI agents may execute `git commit` and `git push` directly.
- **Do NOT propose or prompt for commits or pushes**: AI agents must never prompt the user to commit or push unprompted, nor ask for confirmation (e.g., do NOT ask "Would you like me to commit and push?").
- **Do NOT include unprompted commit message proposals**: Do NOT append "Proposed commit message" or commit/push suggestion sections at the end of a response unless explicitly asked by the user.
- **NEVER push directly to `main`**: All commits and pushes must strictly target topic branches. Merging into `main` rests exclusively with the human maintainer.

## Commit Message Conventions

Follow the repository convention (see `.agents/skills/pr-workflow/SKILL.md`):

- Use Conventional Commits style prefixes (`feat:`, `fix:`, `build:`, `refactor:`, `docs:`, `test:`), optionally with a scope such as `build(flake.lock):`.
- English, imperative mood, short summary, under 72 characters, no trailing period.
- **Do NOT include issue numbers (e.g., `(#24)` or `#24`) in the commit summary.** Issue linkage must be done exclusively in the PR description using explicit issue-closing keywords (e.g. `Closes #24`).

Examples:

- `feat(flacontainer): parse the STREAMINFO block`
- `fix: reject a stream without the fLaC marker`
- `build(flake.lock): nix flake update`
