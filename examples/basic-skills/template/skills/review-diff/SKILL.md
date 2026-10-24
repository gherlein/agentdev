---
name: review-diff
description: >-
  Use when the user wants a quick review of the pending changes before they
  commit or open a PR — e.g. "review my diff", "anything wrong with this change?",
  "look this over". Covers reading the working-tree (or staged) diff and flagging
  correctness, clarity, and obvious risk.
---

# review-diff

Give a focused review of the current changes.

1. **Read the diff.** `git diff` for unstaged work, `git diff --staged` for staged, or
   `git diff <base>...HEAD` when reviewing a branch. Read the whole change, not just
   the hunks that look interesting.
2. **Look for, in priority order:**
   - correctness bugs and broken edge cases,
   - anything unsafe (secrets, destructive commands, unvalidated input),
   - unclear names or logic that a reader would stumble on,
   - dead code, leftover debugging, or scope creep beyond the stated task.
3. **Report** findings most-important first, each as: file:line — what's wrong — why it
   matters. If the change looks good, say so and note anything worth a follow-up.
4. Keep it to real issues; don't invent nits to pad the list.
