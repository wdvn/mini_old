---
name: finishing-a-development-branch
description: Use when implementation is complete and the branch needs to be integrated. Verifies zig build test --summary all is green first, detects worktree vs normal checkout, presents merge / open-PR / keep-branch options with a recommendation, executes the choice, and cleans up only worktrees this workflow created.
---

# Finishing a Development Branch Skill

Workflow for completing development in `mini` (Zig): verify tests green → detect environment → present options → execute → clean up.

Core principle: **the integration decision belongs to the user.** This skill gathers evidence, recommends, and waits. It never merges, pushes, or deletes on its own initiative.

---

## 1. When to Activate This Skill?

- Implementation is complete and the user asks what to do next with the branch.
- After a green test run at the end of a feature/fix cycle, before declaring done.
- When a worktree-based session is winding down and cleanup ownership is unclear.

---

## 2. Step 1: Verify Tests Green FIRST

Run the full suite on the exact tree you are about to integrate. A green run earlier in the session does not count — code may have changed since.

```js
mini.sh("cd /home/mypc/projects/mini && zig build test --summary all")
```

- All **13/13 steps must pass**. E2E needs the Node mock server; if Node is unavailable, use `zig build test -Dskip-e2e=true` and say so in the report.
- **If tests fail**: stop and show the failures. The option menu comes only after a green suite.
- Long runs: `mini.shBackground("zig build test --summary all")` and poll `mini.jobLogs(jobId)` to avoid watchdog kills.

---

## 3. Step 2: Detect Environment (capture before any directory change)

Capture all three values **now, inside the workspace** — Step 4 changes directory and Step 5 needs these captured values:

```js
const GIT_DIR     = mini.sh('cd "$(git rev-parse --git-dir)" && pwd -P').stdout.trim();
const GIT_COMMON  = mini.sh('cd "$(git rev-parse --git-common-dir)" && pwd -P').stdout.trim();
const WORKTREE_PATH = mini.sh('git rev-parse --show-toplevel').stdout.trim();
const detached    = !mini.sh('git symbolic-ref -q HEAD').ok;
```

| State | Menu | Cleanup |
|-------|------|---------|
| `GIT_DIR == GIT_COMMON` (normal repo) | Standard 3 options | No worktree to clean up |
| `GIT_DIR != GIT_COMMON`, named branch | Standard 3 options | Provenance-based (Step 5) |
| `GIT_DIR != GIT_COMMON`, detached HEAD | Reduced 2 options (no merge) | Externally managed — leave in place |

**Determine the base branch** before presenting options — what this work forked from (named in the plan or conversation, or the branch's upstream). If unknown, ask: *"This branch split from <best guess> — is that correct?"* Confirm before merging; merging into the wrong base is expensive to undo.

---

## 4. Step 3: Present Options with a Recommendation

**Normal repo and named-branch worktree — exactly these 3 options:**

```
Implementation complete. What would you like to do?

1. Merge back to <base-branch> locally
2. Push and open a Pull/Merge Request
3. Keep the branch as-is (you handle it later)
```

**Detached HEAD — exactly these 2 options:**

```
Implementation complete. You're on a detached HEAD (externally managed workspace).

1. Push as new branch and open a PR
2. Keep as-is (you handle it later)
```

Give a one-line recommendation before the question:

- **Recommend 1** — local workflow, no remote, or single-machine with confirmed base branch.
- **Recommend 2** — remote exists and review/CI is part of the flow.
- **Recommend 3** — base branch unconfirmed or the user hinted at pausing.

Wait for the answer. Discarding work happens **only** in response to an explicit user request — never offer it unprompted.

---

## 5. Step 4: Execute the Choice

### Option 1: Merge Locally

```js
const MAIN_ROOT = mini.sh('cd "$(git rev-parse --git-common-dir)/.." && git rev-parse --show-toplevel').stdout.trim();
mini.sh(`cd "${MAIN_ROOT}" && git checkout <base-branch> && git merge <feature-branch>`);
mini.sh(`cd "${MAIN_ROOT}" && zig build test --summary all`);
```

- Merge first, verify the merged result is green, **then** delete the branch with `git branch -d <feature-branch>` (lowercase `-d`; if it refuses because the branch is unmerged, stop and report — do not switch to `-D`).
- **If tests fail on the merged result**: stop. Leave branch and worktree in place; nothing was pushed, so it is recoverable.

### Option 2: Push and Open PR

```js
mini.sh('git push -u origin <feature-branch>');
// detached HEAD: git push origin HEAD:refs/heads/<new-branch>
```

- **Commits follow the mini AGENTS.md convention**: English, `module: short description` (e.g. `editor: add word motion keybindings`). Audit branch commits before pushing; amend/reword non-conforming ones.
- Create the PR against `<base-branch>` (forge CLI if available, or the URL printed on push). Report the PR URL. **Keep the worktree** — PR feedback gets fixed there.

### Option 3: Keep As-Is

Report: `Keeping branch <name>. Worktree preserved at <path>.` No cleanup.

### Explicit discard request only

Confirm first, listing exactly what will be permanently deleted (branch, commit list, worktree path). Only the typed word `discard` authorizes deletion; then run Step 5 and `git branch -D <feature-branch>`.

---

## 6. Step 5: Clean Up the Worktree (only if this workflow created it)

Runs for Option 1 and confirmed discards. Options 2 and 3 preserve the worktree. Removal must run **from outside** the worktree, using the `GIT_DIR`/`GIT_COMMON`/`WORKTREE_PATH` values captured in Step 2 (before the directory change).

1. **`GIT_DIR == GIT_COMMON`** (normal repo, original checkout): nothing to clean up. Done.
2. **Worktree is not the original checkout** (created under `.worktrees/` or `worktrees/` by the git-worktrees workflow): this workflow owns it:

   ```js
   mini.sh(`git worktree remove "${WORKTREE_PATH}" && git worktree prune`);
   ```

   `prune` self-heals stale registrations.
3. **Any other worktree location**: the host environment owns it — leave it in place, even if it looks stale.

**If removal is refused** (`contains modified or untracked files`): the worktree holds files that exist nowhere else. **Never `--force` on your own initiative.** Show the user what is at stake:

```js
mini.sh(`git -C "${WORKTREE_PATH}" status --porcelain -uall`);
```

```
Worktree removal refused — these files were never committed:

<file list>

1. Commit them to <branch> before cleanup
2. Move them into <main repo root>
3. Delete them (unrecoverable)
```

Carry out the choice, then remove the worktree.

---

## 7. Decision Rules

- A green suite proves only the tree it ran on — re-run on the tree being integrated.
- Integration is the user's decision: present the menu and wait; never merge because it "seems obviously wanted."
- Option 1: merge + branch cleanup, no push. Option 2: push, keep worktree, no branch cleanup. Option 3: no changes at all. Discard (explicit `discard` only): force branch deletion + worktree removal.
- A rejected push means the remote moved: investigate; force-push only on the user's explicit request.
