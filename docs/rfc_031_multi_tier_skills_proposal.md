# RFC-031: Multi-Tier Skills Architecture & Rich Metadata Specification

- **Status**: Implemented
- **Author**: Antigravity Pair Programming
- **Date**: 2026-10-12
- **Area**: Core / Tooling / Runtime
- **Target Version**: mini-agent v0.9+

---

## 1. Executive Summary

This RFC specifies the architecture for **Multi-Tier Skills** in `mini`, upgrading from a single-file flat model (`SKILL.md` capped at 64 KB) to a comprehensive, multi-tiered capability system compliant with `agentskills.io` standards and inspired by modern autonomous frameworks (such as Hermes Agent).

Key enhancements:
1. **Capacity Upgrade**: Increases `MAX_SKILL_FILE` limit from 64 KB to **256 KB** (providing ample capacity for rich operational guides).
2. **Multi-Tier Directory Hierarchy**: Native recognition of `references/` (deep technical specifications), `templates/` (output skeletons), and `scripts/` (deterministic helpers).
3. **Rich Metadata Schema**: Expands YAML frontmatter parsing to capture `version`, `author`, `platforms`, and `requires_tools`.
4. **Sub-Resource Traversal Tooling**: Extends the `skills` tool (`operation="detail"`) with an optional `file_path` parameter protected by strict path traversal sandboxing.
5. **CodeAct First-Class API**: Exposes `mini.skill(name, file_path?)` in the QuickJS CodeAct environment.

---

## 2. Motivation & Problem Statement

Currently in `mini`, skill discovery in `src/core/skills.zig` operates with strict constraints:
- `MAX_SKILL_FILE = 64 * 1024`: 64 KB limit blocks skills that need in-depth architecture diagrams, API schemas, or multi-step execution playbooks.
- **Flat Layout Only**: Every skill is confined to `<dir>/<name>/SKILL.md`. Storing ancillary templates, API reference docs, or auxiliary scripts requires either stuffing everything into a single Markdown file or making ad-hoc tool calls outside the skill abstraction.
- **Minimal Metadata**: Only `name` and `description` are parsed. The agent and users have no structured knowledge of author, version, target OS platforms, or tool prerequisites.
- **No Dedicated Sub-Resource Reader**: If a skill references an external file, the agent must guess paths and use raw `file_read` or `mini.read(path)`, breaking encapsulation.

---

## 3. Specification & Architectural Design

### 3.1. Directory Structure

A skill directory under `~/.mini/skills/<skill-name>/` or `.agent/skills/<skill-name>/` can adopt the multi-tier hierarchy:

```text
<skills_root>/<skill-name>/
├── SKILL.md                 # Required: Entrypoint and primary workflow guide
├── references/              # Optional: Deep reference documents, schemas, specs
│   ├── api_spec.md
│   └── database_schema.sql
├── templates/               # Optional: Reusable templates, boilerplate, prompt skeletons
│   └── rfc_template.md
└── scripts/                 # Optional: Helper scripts (sh, py, js)
    └── validate_env.sh
```

### 3.2. YAML Frontmatter Specification

`SKILL.md` frontmatter is extended with the following optional fields:

```markdown
---
name: kubernetes-ops
description: Deploy, monitor, and troubleshoot Kubernetes clusters via kubectl and helm.
version: 1.2.0
author: Infrastructure Team
platforms: linux, darwin
requires_tools: bash, http_request
---

# Workflow Instructions
...
```

Parsed fields in `SkillInfo`:
- `name`: string (must match parent directory name).
- `description`: string (max 512 bytes).
- `path`: string (absolute path to `SKILL.md`).
- `dir_path`: string (absolute path to `<skill_root>/<skill-name>`).
- `version`: optional string (e.g. `"1.0.0"`).
- `author`: optional string.
- `platforms`: optional string (e.g. `"linux, darwin"`).
- `requires_tools`: optional string (e.g. `"bash, http_request"`).
- `has_references`: boolean (true if `references/` directory exists).
- `has_templates`: boolean (true if `templates/` directory exists).
- `has_scripts`: boolean (true if `scripts/` directory exists).

### 3.3. Core Discovery & Parsing (`src/core/skills.zig`)

1. **Size Limit Update**:
   ```zig
   pub const MAX_SKILL_FILE = 256 * 1024; // 256 KB
   ```
2. **Directory Inspection**:
   When scanning `<dir_path>`, after parsing `SKILL.md`:
   - Inspect `references/`, `templates/`, `scripts/` via non-recursive directory test (`dir.openDir(io, "references", .{})`).
   - Set boolean flags `has_references`, `has_templates`, `has_scripts`.
3. **Sub-Path Sanitization & Security**:
   ```zig
   pub fn sanitizeSkillSubPath(alloc: Allocator, dir_path: []const u8, sub_path: []const u8) ![]u8
   ```
   **Security invariants**:
   - Sub-path must not contain `..` (directory traversal guard).
   - Sub-path must not begin with `/`, `\`, or drive letter `:`.
   - Sub-path must not contain null bytes `\0`.
   - Resolved path must strictly reside within `dir_path`.
   - File size must not exceed `MAX_SKILL_FILE`.

### 3.4. Tool Registry Enhancement (`src/tooling/registry.zig`)

#### Tool Definition
Update `skills` tool schema in `definitions`:
```json
{
  "name": "skills",
  "description": "Inspect available skills and tools. operation=\"list\" lists all; operation=\"detail\" with name=<skill|tool> shows content. Optional file_path loads sub-resources (references/, templates/, scripts/).",
  "input_schema_json": "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"enum\":[\"list\",\"detail\"],\"description\":\"list or detail\"},\"name\":{\"type\":\"string\",\"description\":\"Skill or tool name\"},\"file_path\":{\"type\":\"string\",\"description\":\"Optional sub-path relative to skill directory (e.g., 'references/api.md', 'templates/rfc.md')\"}},\"required\":[]}"
}
```

#### Behavior of `operation="detail"`
- If `file_path` is null / empty:
  - Reads `SKILL.md`.
  - Scans and appends a list of available sub-resources:
    ```markdown
    ## Available Sub-Resources:
    - references/api_spec.md
    - templates/rfc_template.md
    *(Use skills(operation="detail", name="<name>", file_path="<sub-path>") to view)*
    ```
- If `file_path` is provided:
  - Sanitizes `file_path` via `sanitizeSkillSubPath`.
  - Reads target file and outputs its content labeled with its relative sub-path.

### 3.5. CodeAct JS Bindings (`src/runtime/js_bindings.zig`)

Expose `mini.skill(name, file_path?)` as a first-class CodeAct API:
```javascript
// Read main SKILL.md:
const guide = mini.skill("kubernetes-ops");

// Read sub-resource:
const apiSpec = mini.skill("kubernetes-ops", "references/api_spec.md");
```

---

## 4. Error Handling & Edge Cases

| Scenario | Handling |
| :--- | :--- |
| File size > 256 KB | Returns `error.InvalidFileSize` / user-facing message `"File exceeds 256 KB limit"`. |
| Directory Traversal (`../secret`) | Sanitizer returns `error.PathTraversalDetected` $\rightarrow$ blocked immediately. |
| Sub-file does not exist | Returns `"File '<sub_path>' not found in skill '<name>'."` |
| Skill has no frontmatter | Fallback to parent directory name as `name`, empty description and metadata. |
| Empty or unreadable sub-file | Returns clear empty or read error message without crashing. |

---

## 5. Implementation Phases & Plan

1. **Phase 1: Core Skills Subsystem (`src/core/skills.zig`)**
   - Increase `MAX_SKILL_FILE = 256 * 1024`.
   - Expand `SkillInfo` with extended metadata fields and sub-directory flags.
   - Enhance `parseSkillFrontmatter` to parse `version`, `author`, `platforms`, `requires_tools`.
   - Implement `sanitizeSkillSubPath` and directory existence checkers.
   - Add unit tests for frontmatter parsing, metadata extraction, and path sanitization.
2. **Phase 2: Tool Registry Integration (`src/tooling/registry.zig`)**
   - Update `skills` input schema with `file_path`.
   - Update `readSkillFile` limit to 256 KB.
   - Implement sub-file reading in `executeSkillDetail`.
   - List available sub-resources when reading default `SKILL.md`.
   - Add unit tests for `executeSkillDetail` sub-resource reading and path traversal rejection.
3. **Phase 3: CodeAct QuickJS Binding (`src/runtime/js_bindings.zig`)**
   - Add `jsMiniSkill` binding for `mini.skill(name, file_path?)`.
   - Wire up pre/post tool use auditing hooks and permission guards.
4. **Phase 4: Integration Verification**
   - Create end-to-end testcase `testcases/test_skills_multitier.zig`.
   - Run full test suite: `zig build test-unit`.

---

## 6. Verification Criteria & Success Metrics

1. `zig build test-unit` succeeds (17/17 steps green).
2. Existing skills in `~/.mini/skills/` and `.agent/skills/` continue to load without warnings or regressions.
3. Multi-tier skills with `references/`, `templates/`, and `scripts/` correctly discover their sub-resources.
4. Path traversal attacks (`../`, `/etc/passwd`, `..\`) are strictly prevented with unit test verification.
5. `mini.skill("name", "references/file.md")` in JS CodeAct returns expected content.
