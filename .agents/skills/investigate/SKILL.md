# Investigate

Read this before starting a large investigation, codebase exploration, or design task.

This skill is for understanding only. Do not edit files while using it.

## Inquiry flow

1. **Frame**: State the unknown in one sentence. If the target is unclear, ask the user.
1. **Find**: Inspect the repo structure and locate candidate files with `list`, `glob`, and `grep`.
1. **Read and trace**: Read only relevant files, then follow imports, calls, or references one hop at a time. Stop when the question is answered.

## Tool selection

| Goal | Tool |
| --------------------------------------------- | ------ |
| Know what exists | `list` |
| Find files by name or pattern | `glob` |
| Find symbols, strings, config keys, or errors | `grep` |
| Inspect a known file | `read` |

Do not use `read` to discover. Do not read whole directories. Prefer targeted reads.

## External search

Use repository evidence first.

Use external search only when:

- The question depends on a third-party library, API, spec, or version not present in the repo (e.g. the FLAC specification RFC 9639, Zig standard library changes)
- The repo points to an external URL or version that must be verified

If external search is used, cite the source. Do not answer from memory.

## Notes

Keep notes minimal:

- checked: path or query
- found: one-line result
- unknown: what remains unverified

Do not paste long file contents. Refer to paths and line ranges when possible.

## Stop conditions

Stop and report current status when:

- the framed question is answered with evidence
- three consecutive tool calls return no new information
- the scope grows beyond the original question

## Handoff conditions

Hand back to the user or to the appropriate agent when:

- implementation is needed to continue
- the next step requires user choice

## Report format

End with:

- **Findings**: confirmed facts with paths or line references
- **Unknowns**: unverified points, if any
