# Agent Skills & Custom Commands Manual

## 1. Multi-Tier Skills Architecture (RFC-031)

`mini-agent` implements the **Multi-Tier Skills Specification** ([RFC-031](rfc_031_multi_tier_skills_proposal.md)), upgrading skills from flat single-file markdown guides into structured capability packages compliant with `agentskills.io` standards.

---

## 2. Two-Tier Discovery & Precedence

Skills are organized into two distinct tiers:

| Tier | Directory Location | Scope & Precedence |
|---|---|---|
| **Global User Library** | `~/.mini/skills/<skill_name>/`<br>(or `$MINI_HOME/skills/`) | Machine-wide skills available in all sessions and projects. Initialized via `./scripts/setup_home_mini.sh`. |
| **Project Workspace Library** | `.agent/skills/<skill_name>/` | Repository-scoped skills committed directly to version control. |

> [!IMPORTANT]
> **Project Overrides Global**: If a skill with the same `name` exists in both `.agent/skills/` and `~/.mini/skills/`, the project workspace version completely replaces the global skill in the agent's prompt and tool registry.

---

## 3. Directory Hierarchy

A multi-tier skill adheres to the following directory layout:

```
<skill_name>/
├── SKILL.md                 # Required: Entrypoint guide with YAML frontmatter
├── references/              # Optional: Deep reference documents, schemas, specs
│   ├── api_spec.md
│   ├── schema.sql
│   └── architecture_diagram.svg
├── templates/               # Optional: Reusable prompt skeletons, report structures
│   ├── checklist_template.md
│   └── pull_request_template.md
└── scripts/                 # Optional: Deterministic helper scripts (sh, py, js)
    ├── validate_env.sh
    └── format_output.py
```

### Purpose of Subdirectories
- **`references/`**: Technical specifications, API reference manuals, and architecture blueprints.
- **`templates/`**: Standardized output templates, boilerplates, and prompt skeletons that the agent copies or populates.
- **`scripts/`**: Executable helper scripts that run deterministic, complex setup or verification tasks.

---

## 4. YAML Frontmatter Specification

Every `SKILL.md` must begin with YAML frontmatter:

```yaml
---
name: kubernetes-ops
description: Deploy, monitor, and troubleshoot Kubernetes clusters via kubectl and helm.
version: 1.2.0
author: Infrastructure Engineering
platforms:
  - linux
  - darwin
requires_tools:
  - bash
---

# Kubernetes Operations Playbook

## Overview
...
```

### Frontmatter Schema Fields

| Field | Type | Required? | Description |
|---|---|---|---|
| `name` | String | Yes | Alphanumeric skill identifier matching the parent folder name. |
| `description` | String | Yes | Trigger description (max 512 bytes) injected into the system prompt to guide agent tool selection. |
| `version` | String | No | Semantic version string (e.g. `1.2.0`). |
| `author` | String | No | Author or maintainer name/email. |
| `platforms` | Array | No | Supported operating systems: `linux`, `darwin`, `windows`. |
| `requires_tools` | Array | No | List of native tools required for this skill (e.g. `["bash", "file_read"]`). |

---

## 5. Sub-Resource Access & Security Sandboxing

Agents can access skill sub-resources through two complementary interfaces:

### 5.1. Via the `skills` Native Tool
```json
{
  "operation": "detail",
  "name": "kubernetes-ops",
  "file_path": "references/api_spec.md"
}
```

### 5.2. Via CodeAct JavaScript (`mini.skill`)
```javascript
// Load main guide
const guide = mini.skill("kubernetes-ops");

// Load specific sub-resource
const schema = mini.skill("kubernetes-ops", "references/api_spec.md");
console.log("Schema length:", schema.length);
```

### 5.3. Security Guarantees
- **Path Traversal Protection**: Any path containing `..`, leading `/`, or attempting to resolve outside the skill directory is strictly rejected.
- **Size Bounds**: Individual files are capped at **256 KB** (`MAX_SKILL_FILE`) to prevent context window overflow.
- **Subdirectory Whitelist**: Sub-resource traversal is restricted to `references/`, `templates/`, and `scripts/`.

---

## 6. Custom REPL Slash Commands

In addition to skills, projects and users can define interactive slash commands:

### 6.1. Workspace Slash Commands
Any markdown file located in `.agent/commands/<name>.md` becomes an interactive `/<name>` command in REPL mode:

```markdown
<!-- .agent/commands/audit.md -->
Perform a full security and logic audit on the current Git branch against origin/main.
Verify:
1. No unauthenticated API endpoints introduced
2. No sensitive secrets committed
3. All input arguments sanitized
Output findings in a table with columns: Severity, File, Description.
```

Typing `/audit` in the interactive REPL injects this structured prompt into the conversation turn.

### 6.2. Global Slash Commands
Global commands can be defined in `~/.mini/commands/<name>.md`, providing universal shortcuts across all workspaces.
