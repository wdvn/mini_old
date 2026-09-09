# RFC-004: Adopting the AGENTS.md Standard for mini-agent

| Attribute | Value |
|---|---|
| RFC | 004 |
| Title | Adopting the AGENTS.md Standard (open format for coding agents) |
| Status | **Implemented / Production** |
| Version | 0.1 |
| Dependencies | None (Independent) |
| References | [agents.md](https://agents.md) — open format, 60k+ OSS projects |
| Author | mini-agent |
| Date | 2026-08-22 |

---

## 1. Motivation

### 1.1. Context

- The `mini` repo has a `README.md` intended for **human users**: installation, features, examples.
- Previously, there was no dedicated guide **specifically for coding agents** (mini-agent self-hosting, Codex, Jules, Cursor, Claude Code, etc.): build/test commands, code conventions, architectural guidelines.
- Agents had to guess or read the entire README → wasting context window, easily overlooking conventions (e.g. comment conventions, requiring proposals for external dependencies, placing test files in `testcases/test_*.zig`).

### 1.2. Why Choose AGENTS.md

| Criteria | AGENTS.md | README.md | `.cursorrules` / CLAUDE.md |
|---|---|---|---|
| Understood by many agents | ✅ Codex, Jules, Cursor, Zed, Warp, VS Code, Devin, Aider, goose... | ⚠️ Agent must self-discover | ❌ Single-agent only |
| Open format, non-proprietary | ✅ | ✅ | ❌ |
| Separation of human vs agent guidance | ✅ "README for agents" | ❌ Mixed together | ✅ |
| Directory nesting support | ✅ root + subfolder | ✅ | ⚠️ |
| No rigid schema required | ✅ Freeform Markdown | — | — |

Standard practice: place an `AGENTS.md` file in the repository root. When working in any directory, agents read the nearest `AGENTS.md` (root for the whole repo, with subfolder overrides if necessary). Content should include: **setup commands**, **code style**, **conventions**, **architectural notes**, **testing** — exactly what agents need without README fluff.

## 2. Design

### 2.1. Created File

`AGENTS.md` at root (59 lines), structured according to agents.md recommendations:

```markdown
# mini — Guide for coding agents
## Overview           → 2 lines: Zig 0.16 + CodeAct, Code-Centric architecture
## Layout src/        → core, runtime, tools, tooling, ui, backends, acp
## Build & Run        → zig build / zig build test / zig build run / scripts/build_release.sh
## Code Conventions   → doc-comment //!, no external dependencies without proposal
## Architectural Notes→ JS VM path, protocol conformance, editor upgrade, SQLite reserve
## Testing            → zig build test, manual UTF-8 testing, no real API calls
## PR / Commit        → format `module: description`, do not commit scratch/zig-cache/zig-out
```

### 2.2. Content Guidelines

- **Concise, accurate, and actionable**: each entry is a runnable command or a verifiable rule. Avoid marketing prose (that belongs in the README).
- **No redundancy with README**: only include agent-specific requirements omitted from README (comment conventions, test file paths, proposal links).
- **Cross-reference docs/**: the "open proposal before adding dependency" rule links to `docs/*_proposal.md`; editor sections link to `docs/editor_upgrade_proposal.md`.
- **Language**: English across the repository, keeping command names and paths intact.

### 2.3. Synchronization with the Proposal System

A convention recorded in AGENTS.md: *"Proposals/design docs are located in `docs/`, named in snake_case: `*_proposal.md`"* — RFC-004 follows this exact rule.

## 3. Roadmap

- [x] **Phase 0** — Create root `AGENTS.md` (done).
- [ ] **Phase 1** — Maintainer review, finalize v0.1.
- [ ] **Phase 2** (optional) — Nested `AGENTS.md` for complex subfolders as they grow (e.g. `src/runtime/AGENTS.md` detailing JS bindings), implemented only when complexity strictly demands it.
- [x] **Phase 3** (optional) — mini-agent automatically reads the target project's `AGENTS.md` when running in a user workspace (integrated into system prompt / context bootstrapping). This delivers significant value: mini both **conforms to** the standard (with its own AGENTS.md) and **consumes** the standard when working on other repositories. *Note: AGENTS.md content loaded into system prompts belongs to the **PINNED** tier per RFC-003 context model (as anticipated in RFC-003's future `MINI.md` work).*

## 4. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| AGENTS.md becomes outdated when architecture changes | Add to new RFC checklists: update AGENTS.md if build/conventions change |
| Content overlap with README causing divergence | Rule: AGENTS.md never duplicates README; if duplicate, reduce to a single reference link |
| Excessively long file wasting context | Keep < 100 lines; push extensive details to docs/*.md and link |
| agents.md standard is non-formal (freeform Markdown, no schema) | This is an intentional design choice of the standard — no validation required, keeps Markdown simple |

## 5. Out of Scope

- Defining a schema/validator for AGENTS.md — intentionally omitted by the standard.
- Integrating multiple vendor config files (.cursorrules, CLAUDE.md...) — maintain a single source of truth in AGENTS.md.
