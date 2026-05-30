# How to verify a commit in a clean checkout

This guide verifies that the current `HEAD` commit passes tests without relying on uncommitted files.

## Prerequisites

- Clean or intentionally managed working tree.
- `zig build test` available in this repository.

## Steps

1. Create a temporary worktree from current `HEAD`:
   ```bash
   git worktree add /tmp/x HEAD
   ```
2. Run tests in that clean checkout:
   ```bash
   cd /tmp/x
   zig build test
   ```
3. Return to your main checkout:
   ```bash
   cd -
   ```
4. Remove the temporary worktree:
   ```bash
   git worktree remove --force /tmp/x
   ```

## Result

You have verified the commit against committed files only.
