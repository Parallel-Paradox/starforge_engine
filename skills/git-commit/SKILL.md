---
name: git-commit
description: Write git commit messages using the Conventional Commits format. Used when the user asks for a commit.
---

# Git Commit

## Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

## Example

```
feat(base): add NonInt.from constructor

Raw construction via @enumFromInt silently accepts the reserved sentinel.
NonInt.from asserts that the value is valid, and trace and span ids are now
built through it.
```

## Rules

- type (required): feat, fix, docs, refactor, perf, test, build, ci, chore.
- scope (optional): the affected module, e.g. base, trace, ecs.
- subject (required): imperative mood, no trailing period.
- body (optional): explain why the change was made, not what the code does.
- footer (optional): issue references (Closes #123) and breaking changes.
- Breaking changes: add ! after the type/scope, and a BREAKING CHANGE: footer to describe for complex changes.
- Unless explicitly requested, do not write a Co-authored-by agent field in the footer.

## Workflow

1. Inspect the staged changes (git diff --staged) or all changes when nothing is staged.
2. If the diff mixes unrelated multiple changes, suggest splitting it into separate commits.
3. Pick the type and scope, then write the subject and, if needed, the body.

## Safety

- NEVER commit files that look like secrets (.env, credentials, private keys, tokens). Warn the user instead.
- NEVER use --no-verify unless the user explicitly asks.
