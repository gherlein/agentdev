---
name: git-commit
description: >-
  Use when the user wants to commit the current changes with a good message —
  e.g. "commit this", "make a commit", "stage and commit my work". Covers
  reviewing the diff, writing a clear conventional-style message, and committing
  only what the user intends.
---

# git-commit

Turn the working-tree changes into one clean commit.

1. **Review first.** Run `git status` and `git diff` (and `git diff --staged`) to see
   exactly what would be committed. Call out anything surprising — stray files,
   secrets, unrelated changes — before committing.
2. **Stage intentionally.** Stage the files that belong to this change. Do not blindly
   `git add -A` if unrelated edits are present; ask or stage selectively.
3. **Write the message.** A concise summary line (imperative mood, ≤72 chars), then a
   blank line and a short body explaining the *why* when it isn't obvious.
4. **Commit**, then show `git log -1 --stat` so the user can confirm what landed.
5. Never commit on a shared/default branch without the user's go-ahead, and never
   `push` unless they ask.
