# Agent Guidelines for `ziggyflac`

This document defines context, architectural principles, conventions, and non-negotiable safety rules for AI agents working on the `ziggyflac` repository.

______________________________________________________________________

## 1. Project Overview & Architecture

`ziggyflac` is a Zig library to handle the FLAC (Free Lossless Audio Codec) file format.

- **Architectural Principles & Scope**:
  - **Layered Design**: The low-level container layer (`flacontainer`) parses and writes the raw FLAC structure (the `fLaC` marker, metadata blocks, audio frames) without interpreting audio. The high-level layer (`ziggyflac`) builds on it to provide decoding/encoding of samples.
  - **Pure Zig**: Keep the codebase free of C toolchains and C library dependencies (e.g. `libFLAC`) to guarantee seamless cross-compilation.
  - **No External Zig Dependencies**: `build.zig.zon` keeps `dependencies = .{}` unless the user explicitly asks otherwise.
  - **Explicit over Implicit**: Never silently accept malformed input. Return precise errors for invalid markers, block types, sizes, and CRC mismatches.
  - **Spec Fidelity**: Follow the FLAC specification (RFC 9639). Reference the relevant section in doc comments when implementing a structure.
- **Development Environment**: Managed with Nix (`flake.nix`), `direnv`, and `treefmt-nix` for formatting Zig, Nix, GitHub Actions, Markdown, and shell scripts. `treefmt` is available on `PATH` inside `nix develop` (or via direnv) through the default devShell's `inputsFrom`.
- **Target Language Version**: Zig `0.16.0` (`minimum_zig_version` in `build.zig.zon`).
- **Directory Structure**:
  - `modules/flacontainer/flacontainer.zig`: Entry point of the `flacontainer` module (low-level FLAC container structure, e.g. `constants.marker`).
  - `modules/flacontainer/flacontainer/metadata.zig`: Metadata block definitions (`BlockHeader`, etc.).
  - `modules/flacontainer/flacontainer/audio.zig`: Audio frame definitions.
  - `modules/ziggyflac/ziggyflac.zig`: Entry point of the high-level `ziggyflac` module.
  - `build.zig` & `build.zig.zon`: Build definition and package metadata. Steps: `zig build` (static libraries `ziggyflac` and `flacontainer`), `zig build test`.
  - `flake.nix`, `shell.nix`, `default.nix`: Nix development shell and package configurations.

______________________________________________________________________

## 2. Strict Safety & Operational Rules (Always Enforced)

- **NEVER AUTO-MERGE TO MAIN**: AI agents **MUST NEVER** merge PRs, execute `git merge`, or directly push commits to the `main` branch autonomously.
- **NEVER PROPOSE COMMITS OR PUSHES UNPROMPTED**: AI agents **MUST NEVER** prompt the user to commit or push, nor propose commit messages unprompted. When instructed by the user or when creating/updating pull requests on topic branches, agents may execute `git commit` and `git push` directly without seeking confirmation.
- **Mandatory Human Approval**: AI agents may create branches, create commits, push topic branches, propose PRs, format code, and run test suites, but the final action of merging changes into `main` rests strictly with the human maintainer.
- **Dedicated Branches**: Always work on a dedicated branch (e.g. `feat/stream-info`, `fix/block-size`). Do not commit directly to `main`.
- **Verification Before Submitting**: All changes must pass `treefmt --fail-on-change`, `zig build`, and `zig build test`.
- **Evidence First**: Base all answers and actions on actual file contents and command output. Never speculate or assume.
- **Non-Destructive**: Never perform irreversible actions (file deletions, hard resets, remote push, force push) without explicit user approval.
- **Targeted Edits**: Make minimal, logical changes strictly necessary for the request. Do not modify unrelated files.
- **No Unsolicited Actions on Other Branches/PRs**: Never modify, rebase, or resolve conflicts on PRs or branches without explicit user instructions.
- **English-Only Documentation**: All repository documentation, code comments, commit messages, and PR descriptions must be written strictly in English.
- **Explicit Milestone Assignment Only**: AI agents **MUST NEVER** automatically attach or set GitHub Milestones on Pull Requests or Issues unless explicitly requested by the user.

______________________________________________________________________

## 3. Status Assessment Workflow

When asked to check status, assess the situation, or understand workspace context:

1. **Local Git State**: Inspect working tree (`git status -s -b`) and recent commits (`git log -n 5 --oneline`).
1. **GitHub PRs (always display)**: List **all** open PRs (`gh pr list`) and check the current branch's PR (`gh pr status`). Never skip this step, even when the local state is clean.
1. **GitHub Issues (always display)**: List **all** open issues (`gh issue list`). Never skip this step.
1. **Environment Health**: Verify formatting, build, and test status (`treefmt --fail-on-change`, `zig build`, `zig build test`). Note that `treefmt` rewrites files even when it fails; report any resulting working tree changes.
1. **Synthesis**: Report a concise, structured status covering local state, remote GitHub state, and environment health. The report **must** include the open PR and Issue lists (number, title, and state), or explicitly state that there are none.

______________________________________________________________________

## 4. Mandatory Commands & Verification Workflow

Before marking any task as complete, AI agents **MUST** execute the relevant commands below and verify clean execution:

| Task | Command | Description |
| :--- | :--- | :--- |
| **Check Formatting** | `treefmt --fail-on-change` | Verifies formatting of all Zig, Nix, Markdown, Actions, and shell files |
| **Format Code** | `treefmt` | Auto-formats all files in the repository |
| **Check Zig Formatting** | `zig fmt --check .` | Verifies Zig formatting only (usable outside the Nix shell) |
| **Build Library** | `zig build` | Builds the `ziggyflac` and `flacontainer` static libraries |
| **Run All Tests** | `zig build test` | Runs the tests of both modules |

______________________________________________________________________

## 5. Coding & Documentation Guidelines

### Formatting & Code Style

- **Formatter**: Always run `treefmt` (or at least `zig fmt .`) before finishing changes.
- **Naming Conventions**:
  - `camelCase` for functions and variables.
  - `PascalCase` for structs, unions, enums, and type-generating functions.
  - `snake_case` for enum fields and namespace-like constants (matching existing code such as `BlockHeader.stream_info` and `constants.marker`).
- **Indentation**: 4 spaces (enforced automatically by `zig fmt`).
- **Comments**: All comments (`///`, `//!`, `//`) MUST be in English.

### Memory Management & Safety

- **Deallocation**: Any type that allocates memory **must** provide a `deinit()` method.
- **Ownership**: Document buffer ownership clearly in function doc comments.
- **Leak Checking**: Always test dynamic allocations with `std.testing.allocator`.
- **Resource Cleanup**: Use `defer` and `errdefer` appropriately to ensure proper cleanup on early returns or errors.

### Testing

- Place unit tests next to the code they test, and reference submodules from the module root with `std.testing.refAllDecls` so their tests run.
- **No Symptom Swallowing**: Fix root causes of failing tests; never comment out assertions or swallow error returns.
- Keep binary FLAC test fixtures small. If large fixtures become necessary, discuss Git LFS with the user before adding them.

______________________________________________________________________

## 6. Git & Pull Request Conventions

- **Conventional Commits**: Use conventional commit prefixes (`feat:`, `fix:`, `refactor:`, `docs:`, `build:`, `test:`, `perf:`), optionally with a scope (e.g. `feat(flacontainer):`, `build(flake.lock):`). Pull request titles follow the same format.
- **PR Creation**: Create PRs using `gh pr create`. Reference issues in the body using standard keywords (e.g. `Closes #1`).
- **PR Merge Prohibition**: **NEVER MERGE Pull Requests.** PRs must remain open for maintainer review unless the user explicitly commands the agent to merge a specific PR.
- **Labels**: When creating Issues or Pull Requests with `gh`, assign relevant existing labels (e.g. `feat`, `fix`, `docs`) if the repository has them. Do not create new labels without user approval.
- **Versioning**: Use Semantic Versioning **without** a `v` prefix (e.g. `0.1.0`). `version` in `build.zig.zon` is the single source of truth. Never create a tag or a release by hand, and only prepare a version bump when the user asks for it.

______________________________________________________________________

## 7. Workspace Skills

Detailed runbooks and procedural workflows are maintained as workspace skills under `.agents/skills/`:

| Trigger / Context | Skill to Read | Purpose |
| :--- | :--- | :--- |
| Deep investigation, complex code search | [`investigate`](.agents/skills/investigate/SKILL.md) | Non-destructive investigation guidelines |
| Commit conventions & policies | [`git-commit`](.agents/skills/git-commit/SKILL.md) | Commit conventions and prohibition of unprompted commit/push proposals |
| Deleting files, overwriting, git push/reset | [`irreversible`](.agents/skills/irreversible/SKILL.md) | Pre-checks and confirmation prompts |
| Testing, verifying builds or behavior | [`verify`](.agents/skills/verify/SKILL.md) | Minimal, high-signal verification steps |
| Bumping `flake.lock`, Zig version, or adding FLAC test fixtures | [`update-dependencies`](.agents/skills/update-dependencies/SKILL.md) | Procedures for Nix input updates, Zig version bumps, and test fixtures |
| Preparing PRs, formatting, pre-submission checks | [`pr-workflow`](.agents/skills/pr-workflow/SKILL.md) | Verification command table, commit rules, and PR requirements |
| "Fresh eyes" sweep for issues not already tracked, sanity-checking a batch of fixes | [`fresh-eyes-audit`](.agents/skills/fresh-eyes-audit/SKILL.md) | Parallel, context-free repo audits to surface gaps a single continuously-informed reviewer would miss |
