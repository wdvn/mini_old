---
name: using-git-worktrees
description: "Use when starting feature work that needs isolation from the current workspace or before executing an implementation plan — detects existing isolation, creates a git worktree, sets up the project, and verifies a clean baseline."
---

# Using Git Worktrees Skill

Isolate feature work in a git worktree so the current branch and working tree stay untouched.
mini has **no native worktree tool**: plain `git` via `mini.sh` is THE path. Create worktrees
directly with `git worktree add` — no fallback ladder.

Core principle: **Detect existing isolation first.** Create only when in a normal checkout.
Verify the baseline before implementing.

## 1. When to Activate This Skill?

- Starting feature work that must not touch the current branch or working tree.
- Before executing a multi-step implementation plan in the main checkout.
- When the user asks for an isolated workspace for experiments, reviews, or parallel work.

## 2. Step 0: Detect Existing Isolation

Before creating anything, check whether you are already in an isolated workspace:

```js
console.log(mini.sh(`
  GIT_DIR=$(cd "$(git rev-parse --git-dir)" 2>/dev/null && pwd -P)
  GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
  echo "DIR=$GIT_DIR"
  echo "COMMON=$GIT_COMMON"
  git branch --show-current
`).stdout);
```

**Submodule guard:** `GIT_DIR != GIT_COMMON` is also true inside git submodules. Before
concluding "already in a worktree," verify:

```js
const superTree = mini.sh("git rev-parse --show-superproject-working-tree 2>/dev/null").stdout.trim();
```

Decision:

- `GIT_DIR != GIT_COMMON` **and** `superTree` empty → already in a linked worktree. Do NOT
  create another. Skip to Step 2 (Project Setup). Report with branch state:
  - On a branch: "Already in isolated workspace at `<path>` on branch `<name>`."
  - Detached HEAD: "Already in isolated workspace at `<path>` (detached HEAD, externally
    managed). Branch creation needed at finish time."
- `GIT_DIR == GIT_COMMON`, **or** `superTree` is a path (submodule) → normal repo checkout.
  Proceed to Step 1.

**Consent:** If the user has not already indicated a worktree preference, ask: "Would you like
me to set up an isolated worktree? It protects your current branch from changes." Honor any
existing declared preference without asking. If the user declines, work in place and skip to
Step 2.

## 3. Step 1: Create the Isolated Workspace

### 3.1 Location

Priority order (explicit user preference always beats observed filesystem state):

1. Declared worktree directory in user instructions — use it without asking.
2. Existing project-local directory:
   ```js
   console.log(mini.sh("ls -d .worktrees worktrees 2>/dev/null").stdout);
   ```
   Use whichever exists. If both exist, `.worktrees` wins.
3. Default: `.worktrees/` at the project root.

### 3.2 Branch Naming

English kebab-case tied to the repo's module convention (matches the commit prefix
`module: short description` from AGENTS.md):

```
feat/<module>-<slug>     e.g. feat/editor-bracketed-paste
fix/<module>-<slug>
```

### 3.3 Safety: Directory Must Be Ignored

**MUST verify before creating a project-local worktree:**

```js
const ignored = mini.sh("git check-ignore -q .worktrees || git check-ignore -q worktrees");
// exitCode 0 = ignored
```

If NOT ignored: add the directory to `.gitignore`, commit the change, then proceed.
Why critical: an unignored worktree directory commits the whole tree into the repository.

### 3.4 Create

```js
const branch = "feat/editor-bracketed-paste";
const r = mini.sh(`git worktree add .worktrees/${branch} -b ${branch}`);
console.log(r.exitCode, r.stdout, r.stderr);
```

Then run all further work from inside that directory (pass absolute paths to `mini.sh`).

**Sandbox fallback:** if `git worktree add` fails with a permission error, tell the user the
sandbox blocked worktree creation and work in the current directory instead. Run setup and
baseline in place.

## 4. Step 2: Project Setup

Auto-detect and run the project's setup:

```js
if (mini.exists("package.json")) mini.sh("npm install");
if (mini.exists("Cargo.toml")) mini.sh("cargo build");
if (mini.exists("requirements.txt")) mini.sh("pip install -r requirements.txt");
if (mini.exists("go.mod")) mini.sh("go mod download");
```

**Mini-agent (Zig) specifics:**

- No dependency install needed.
- The first `zig build` in a fresh worktree is **slow** — the Zig build cache is fresh
  (expect it). Launch long builds with `mini.shBackground` and poll `mini.jobLogs`
  instead of blocking, to avoid watchdog kills.

## 5. Step 3: Verify Clean Baseline

Run the test suite in the worktree. For mini-agent:

```js
const j = mini.shBackground("zig build test -Dskip-e2e=true 2>&1");
// poll: mini.jobStatus(j.jobId), then mini.jobLogs(j.jobId, 50)
```

- Baseline: `zig build test -Dskip-e2e=true` (fast, no Node mock server required).
  The full `zig build test --summary all` additionally runs the E2E mock layer — use it before
  finishing, not for the baseline.
- Follow the repo's AGENTS.md throughout: English comments, surgical minimal changes, test
  files only in `testcases/test_*.zig`, commit messages `module: short description`.

**If tests fail:** report the failures and ask whether to proceed or investigate. A dirty
baseline makes every later failure ambiguous — do not proceed past failures silently.

**If tests pass:** report ready:

```
Worktree ready at <full-path> (branch <name>)
Baseline: zig build test -Dskip-e2e=true — all passed
Ready to implement <feature-name>
```

## 6. Quick Reference

| Situation | Action |
|-----------|--------|
| `GIT_DIR != GIT_COMMON`, not submodule | Already in worktree — skip creation, go to Step 2 |
| `GIT_DIR != GIT_COMMON`, in submodule | Treat as normal repo (submodule guard) |
| In normal checkout, user consented | `git worktree add .worktrees/<branch> -b <branch>` |
| `.worktrees/` and `worktrees/` exist | Use `.worktrees/` |
| Neither exists | Check user instructions, then default `.worktrees/` |
| Directory not ignored | Add to `.gitignore` + commit, then create |
| Permission error on create | Report, work in place |
| Baseline tests fail | Report failures + ask |
