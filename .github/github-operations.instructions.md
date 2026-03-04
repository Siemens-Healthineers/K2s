---
applyTo: "**"
---

<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# GitHub Operations: Always Require User Confirmation

**CRITICAL — applies to every GitHub operation without exception.**

Before executing ANY GitHub operation — regardless of how basic, trivial, read-only, or routine it appears — you MUST stop and explicitly ask the user for confirmation. There are no exceptions to this rule.

## Operations that ALWAYS require explicit user confirmation

This includes but is not limited to:

**Read operations (still require confirmation):**
- Fetching repository details, file contents, branch lists, commit history
- Searching repositories, issues, pull requests, users, or code
- Reading issue details, PR details, review comments
- Getting release information, tags, team members

**Write operations (require confirmation):**
- Creating, updating, or deleting files in any repository
- Creating or updating branches
- Creating, updating, or merging pull requests
- Creating, updating, or closing issues
- Adding comments to issues or pull requests
- Adding review comments or submitting reviews
- Pushing files or creating commits
- Creating repositories or forks
- Assigning Copilot to issues
- Creating pull requests with Copilot
- Any other mutation of GitHub resources

## Required confirmation format

Before any GitHub operation, you MUST:

1. **State exactly what you are about to do** — include the operation type, target repository/owner, and any parameters (branch, file path, commit message, PR title, etc.).
2. **Ask explicitly**: "Do you want me to proceed?"
3. **Wait for an affirmative response** before invoking any GitHub tool.
4. **Never assume consent** based on prior context, prior confirmations, or the apparent triviality of the operation.

## Example (correct behavior)

> I am about to read the list of branches in `siemens-healthineers/K2s`. Do you want me to proceed?

> I am about to create a pull request in `siemens-healthineers/K2s` from branch `feature/x` to `main` with title "Fix Y". Do you want me to proceed?

## Prohibited behavior

- Do NOT chain GitHub operations; confirm each one individually.
- Do NOT skip confirmation because you already confirmed a related operation.
- Do NOT consider any GitHub operation "too simple" to warrant confirmation.
- Do NOT proceed if the user's response is ambiguous — ask again for a clear yes/no.
