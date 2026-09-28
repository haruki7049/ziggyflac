# Pull Request & Commit Workflow for `ziggyflac`

This skill defines the procedures for code verification, commit creation, and pull request submission.

## 1. Mandatory Verification Steps

Before committing or opening a PR, execute the following commands and ensure all pass cleanly:

| Task | Command | Description |
| :--- | :--- | :--- |
| **Check All Formatting (treefmt)** | `treefmt --fail-on-change` | Verifies formatting across Zig, Nix, GitHub Actions, and Markdown files |
| **Format All Files (treefmt)** | `treefmt` | Auto-formats all files in the repository using treefmt |
| **Run All Tests** | `zig build test` | Executes the library unit tests |
| **Build Library** | `zig build` | Compiles and installs the static library |
| **Check Zig Formatting** | `zig fmt --check .` | Verifies Zig formatting only (usable outside the Nix shell) |
| **Nix Flake Check** | `nix flake check --all-systems` | Run when `flake.nix`/`flake.lock` change |

Keep binary FLAC test fixtures small. Confirm with the user before adding large fixtures (see `.agents/skills/irreversible/SKILL.md`).

## 2. Commit & PR Title Conventions

Use Conventional Commits style prefixes, optionally with a scope:

- `feat:` New capability or supported FLAC structure (metadata block, frame, subframe).
- `fix:` Bug fixes in parsing, decoding, or encoding logic.
- `build:` Updates to `build.zig`, `build.zig.zon`, `flake.nix`, `flake.lock`, or CI workflows.
- `refactor:` Code restructuring without changing behavior.
- `docs:` Updates to README, AGENTS.md, skills, or code documentation.
- `test:` Adding or updating unit tests or test fixtures.

**Do NOT include issue numbers (e.g., `(#24)` or `#24`) anywhere in commit messages (summary or body) or PR titles.** Issue linkage must be done exclusively in the PR description using explicit issue-closing keywords (e.g. `Closes #24`). Squash merges copy every commit message into `main`, so a closing keyword in a commit body can close the wrong issue. The ` (#N)` suffix GitHub itself appends to squash-merge summaries is the only exception.

**Language**: Write all commit messages, PR titles, PR descriptions, and repository documentation strictly in English.

## 3. PR Description Requirements

Ensure the PR description includes:

- **Summary**: Concise overview of changes.
- **Linked Issue / Closes Statement**: Always include an explicit issue-closing keyword (e.g. `Closes #16`, `Fixes #12`, or `Resolves #5`) when resolving an open issue.
- **Verification**: Explicitly list executed verification commands (`treefmt --fail-on-change`, `zig build test`, etc.) and their success status.
- **Breaking Changes**: Highlight any breaking changes to the public API.

## 4. Strict Safety & Approval Rules

- **NEVER MERGE PULL REQUESTS**: AI agents **MUST NEVER** merge PRs (including enabling auto-merge with `gh pr merge --auto`), execute `git merge` into `main`, or directly push commits to the `main` branch autonomously.
- **NEVER PROPOSE COMMITS OR PUSHES UNPROMPTED**: AI agents **MUST NEVER** prompt the user to commit or push unprompted. When instructed by the user or when preparing pull requests on topic branches, agents may execute `git commit` and `git push` directly.
- **Mandatory Human Approval**: AI agents may create branches, create commits, push topic branches, propose PRs, format code, and run test suites, but the final action of merging changes into `main` rests strictly with the human maintainer.
- **Explicit Milestone Assignment Only**: AI agents **MUST NEVER** automatically attach or set GitHub Milestones on Pull Requests or Issues unless explicitly requested or instructed by the user.
