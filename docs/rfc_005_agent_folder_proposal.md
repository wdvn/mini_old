# RFC-005: `.agent/` Workspace Directory Standard for mini-agent

| Attribute | Value |
|---|---|
| RFC | 005 |
| Title | `.agent/` Directory Standard — Workspace container for agent configuration and skills |
| Status | **Implemented / Production** — `.agent/` directory (`AGENTS.md`, `skills/`, `commands/`) and skills discovery loader are fully active in production |
| Version | 0.3 — Replaced proprietary skill formats with the Agent Skills standard (agentskills.io); separated state management |
| Dependencies | RFC-004 (Adopting the AGENTS.md Standard) |
| References | No public `.agent` directory standard (verified 2026-08-22: agents.md spec, opencode, fx do not define this folder). This RFC establishes mini's internal convention. Skills follow the open [Agent Skills](https://agentskills.io/specification) standard (agentskills.io) — see §2.2. Refer to [vercel-labs/fx](https://github.com/vercel-labs/fx) dot folder structures for tool organization patterns. |
| Author | mini-agent |
| Date | 2026-08-22 |

---

## 1. Motivation

### 1.1. Current State

Previously, mini scattered agent configuration across several disjointed locations:

- **AGENTS.md** (RFC-004): Agent instructions lived at root as an isolated file.
- **Skills**: `src/core/skills.zig` loaded skills following the Agent Skills standard (agentskills.io) but only from `~/.mini/skills/` (global) — leaving teams without a project-level repository for shared skills.
- **Slash commands**: Hardcoded in `handleSlashCommand()` (src/ui/repl.zig:56) — preventing users from defining custom commands for their project.
- **Artifacts**: `src/core/artifacts.zig` were in-session only — lost on process exit, lacking durable persistence per project.

Runtime state (sessions, history, background jobs) **falls outside the scope of this RFC** — see assignments in §2.2.

### 1.2. Why an `.agent/` Directory is Needed

- **Centralized**: A single home for agent configuration and skills within the workspace.
- **Distinct from AGENTS.md**: AGENTS.md consists purely of *instructions* (guidance text, an open standard across all agents). `.agent/` contains *runtime configuration* — settings specific to mini. They complement each other rather than overlap.
- **Git-friendly**: `.agent/` contains committed assets (skills, shared team config) alongside runtime output (optionally ignored). Clearly segregated via `.agent/.gitignore`.
- **Ecosystem Consistency**: Aligns with established conventions like `.git/`, `.vscode/`, `.idea/` — root-level dot directories owned and managed by tooling.

### 1.3. Standardization Notes

**No public `.agent` directory standard currently exists** (verified: agents.md only specifies the `AGENTS.md` file; opencode uses `.opencode/`; fx avoids `.agent` folders). This is **mini's internal convention**, named `.agent` because:
- It is concise, neutral, and unbranded → easily adopted by other agents if desired.
- It sits harmoniously alongside `AGENTS.md` → agents discover `.agent/` right next to `AGENTS.md`.

Should an official community standard emerge under the same name in the future, mini will review and adapt accordingly.

---

## 2. Design

### 2.1. Directory Structure

```
.agent/
├── AGENTS.md          # Agent-runtime instructions for mini (RFC-004, open format) — committed
├── .gitignore         # Default: ignore output/ — committed
├── config.json        # Project-level configuration: model, backends, permissions — committed (no secrets)
├── skills/            # User-defined skills — committed (agentskills.io standard)
│   ├── deploy/        #   Each skill = 1 subdirectory containing at least SKILL.md
│   │   ├── SKILL.md   #     Required: YAML frontmatter (name, description) + instructions
│   │   └── scripts/   #     Optional: executable scripts
│   └── review/
│       └── SKILL.md
├── commands/          # User-defined slash commands — committed
│   └── commit.md      #   Each command = 1 markdown file → /commit
└── output/            #   Durable artifacts — NOT committed (optional)
    └── walkthrough.md
```

### 2.2. Detailed Conventions

#### Nested AGENTS.md

- `.agent/AGENTS.md`: Agent-runtime instructions (how mini operates in this repository: tool preferences, escalation rules).
- Root `AGENTS.md` remains prioritized under RFC-004 — unchanged.
- Agent reads both: root first (project-wide instructions), `.agent/` second (mini-specific runtime guidance).

#### Skills (Agent Skills Standard — agentskills.io)

Skills in `.agent/skills/` conform **strictly to the open Agent Skills specification** (verified 2026-08-22, [specification](https://agentskills.io/specification)) — identical to the global `~/.mini/skills/` layer (`src/core/skills.zig`). Mini does not invent a custom proprietary skill format.

Each skill is **a subdirectory** containing at minimum a `SKILL.md` file:

```
.agent/skills/deploy/
├── SKILL.md          # Required: YAML frontmatter + markdown instructions
├── scripts/          # Optional: executable code (bash, python, js...)
├── references/       # Optional: reference documentation (read on-demand)
└── assets/           # Optional: templates and static assets
```

`SKILL.md` requires YAML frontmatter:

```markdown
---
name: deploy
description: Deploy mini to staging servers. Use when user requests deployment or pushing builds to staging.
---
Instructions: steps the agent must perform when deploy is requested...
```

Specification Constraints (validated by mini on load):

| Field | Required | Constraints |
|---|---|---|
| `name` | Yes | 1–64 characters, lowercase `a-z 0-9` + hyphens, no leading/trailing/consecutive hyphens, **must match parent directory name** |
| `description` | Yes | 1–1024 characters, describing both *what* it does and *when to use* it |
| `license` | No | License name or bundled license file reference |
| `compatibility` | No | ≤500 characters, environment requirements (runtime, packages, network) |
| `metadata` | No | Arbitrary string-to-string key-value map |
| `allowed-tools` | No | Space-separated list of pre-approved tools (experimental) |

Differences from the v0.1 draft (which used ad-hoc `skills/<name>.md` files):
- Skills are **directory bundles** (`SKILL.md` + `scripts` + `references` + `assets`), not isolated markdown files — enabling bundled scripts and resources.
- Skill names from frontmatter **must match the directory name** — strict spec compliance.
- Reuses `parseSkillFile()` from `src/core/skills.zig` (parses `name`/`description`, falls back to folder name) — simply adding `.agent/skills/` alongside `~/.mini/skills/`.

**Progressive Disclosure** (per spec): Prompts initially inject only `name` + `description` (~50 tokens/skill, max 32 skills, description ≤512 bytes — mini's current budget); the `SKILL.md` body (<500 lines recommended) loads only when a skill is activated; `scripts/` and `references/` are read on-demand.

#### Extensible Slash Commands

- `.agent/commands/<name>.md` → Registers dynamic `/name` in the REPL, evaluated after built-in commands.
- File body serves as prompt template, supporting `$ARGUMENTS`, `$1`...`$9` placeholders.

#### Scope Demarcation with RFC-002 & RFC-003 (State & Memory)

Mini's runtime state **does not live in `.agent/`**. Division of responsibilities:

| State Category | Storage Path | Governed By |
|---|---|---|
| Raw conversation history (append-only, resume/audit) | `~/.mini/sessions/` (preserved as-is) | RFC-002 |
| Extracted memory (semantic/episodic/project_state) | `MINI_MEMACT_MEMORY_DIR` (default `~/.mini/memory/<project_hash>/`) | RFC-003 |
| Background jobs (pid, log path, status) | `~/.mini/` (preserved as-is) | — |
| Durable project artifacts | `.agent/output/` | RFC-005 (this folder) |

Rationale for separating state from `.agent/`:
- Sessions and history belong to the developer and machine, not the repository — committing them into workspaces risks leaking sensitive file contents and logs.
- RFC-003 already manages memory layouts globally by `project_hash`; adding a second state store in the workspace causes redundant discovery mechanisms.
- `.agent/` maintains a single responsibility: **shared project configuration + skills + durable output**.
- Consistent with fx: fx persists portable sessions in `~/.fx/sessions/<session-id>/` — mini similarly uses a global path (`~/.mini/`) rather than in-workspace state.

#### Commit / Ignore Separation

Default `.agent/.gitignore` (automatically created by mini on initial run):

```gitignore
output/
```

→ Teams commit `AGENTS.md`, `config.json`, `skills/`, `commands/`; runtime output remains local.

### 2.3. Discovery & Fallback

1. Search upward for `.agent/` starting from `cwd` to filesystem root (similar to `.git/` lookup).
2. If not found → implicitly create and seed default `.gitignore` (does not create AGENTS.md — RFC-004 recommends authors write this).
3. Configuration merge order: built-in defaults → `~/.config/mini/` (global) → `.agent/config.json` (project) → CLI flags.
4. Skills discovery order: `~/.mini/skills/` (global, personal user) → `.agent/skills/` (project, team shared). On `name` collision → project overrides global.

---

## 3. Roadmap

| Phase | Description | Complexity |
|---|---|---|
| 1 | Discover `.agent/` + seed `.gitignore` + inject `.agent/AGENTS.md` into system prompt | Low |
| 2 | Project-level `config.json`, merged into active `Config` | Medium |
| 3 | Skills conforming to agentskills.io: expand `loadSkills()` to scan `.agent/skills/*/SKILL.md`, enforce spec validations | Medium |
| 4 | Dynamic slash commands from `.agent/commands/` | Medium |

Phases 1-2 are completely backward compatible; Phases 3-4 modify tool `skills` behavior and REPL commands. Durable artifacts in `.agent/output/` can follow without blocking core phases.

---

## 4. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Collision with future formal standard | Clarified as mini convention; ready to rename via migration script if required |
| Users resisting new workspace dot directories | Opt-out via `agent_folder = false`; only created when writing output |
| Users mistaking `.agent/` as state/session container | Runtime state decoupled from `.agent/` (see §2.2); explicit docs and subfolder names |
| Skills markdown increases attack surface (prompt injection via skill file) | Skills only loaded from active workspace; warn when skills request sensitive tools |
| Non-conforming skills (name mismatch, oversize description) | Validation on load: warn and skip without crashing; flat YAML schema avoids heavy parser dependencies |

---

## 5. Open Questions

1. Should `.agent/config.json` support secrets (API keys) or require environment variables? Recommendation: prohibit secrets in committed configuration.
2. **Config File Format Decision**: Adopted `config.json` instead of `config.toml` to leverage standard `std.json` in Zig 0.16.0 standard library, avoiding external TOML dependencies (abiding by design rules in `AGENTS.md`).
3. Should the directory be named `.mini/` instead of `.agent/` to avoid confusion with open standards? Open for review.
