# Tools, Skills & Model Context Protocol (MCP) Manual

## 1. Built-in Tools Reference

`mini-agent` includes 15 built-in native tools. When running in standard JSON tool mode, the language model receives tool schemas and issues calls matching the specifications below. In CodeAct mode, the same tools are called via the `mini.*` JavaScript API.

---

### 1.1. `bash`
Executes a shell command on the host system and returns standard output and standard error.

- **Input Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "command": {
        "type": "string",
        "description": "Shell command line to execute"
      }
    },
    "required": ["command"]
  }
  ```
- **Execution Limits**:
  - Maximum output capture: 64 KB (head-truncated if exceeded).
  - Timeout: 120 seconds default.
- **Safety Filters**: Blocks dangerous commands matching blacklist patterns:
  - `rm -rf /` or root directory deletion.
  - Fork bombs (`:(){ :|:& };:`).
  - Direct block device manipulation (`dd if=... of=/dev/sd*`, `mkfs.*`).
  - Shutdown/reboot operations.

---

### 1.2. `file_read`
Reads content from a file with line-number indexing and pagination support.

- **Input Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "path": { "type": "string", "description": "Path to file" },
      "offset": { "type": "integer", "description": "1-indexed starting line number (default: 1)" },
      "limit": { "type": "integer", "description": "Maximum lines to read (default: 2000, max: 2000)" }
    },
    "required": ["path"]
  }
  ```
- **Constraints**:
  - Maximum file size: 10 MB.
  - Maximum lines returned per call: 2000.
  - Rejects binary files.

---

### 1.3. `file_write`
Creates a new file or overwrites an existing file with the provided content.

- **Input Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "path": { "type": "string", "description": "Target file path" },
      "content": { "type": "string", "description": "Full file content" }
    },
    "required": ["path", "content"]
  }
  ```
- **Safety & Guarantees**:
  - Automatically creates intermediate directories.
  - Automatically captures a SHA-256 CAS snapshot of the previous version before modifying the file.
  - Denies writes targeting system directories (`/etc`, `/proc`, `/sys`, `/dev`).

---

### 1.4. `file_edit`
Performs an exact string replacement within an existing file.

- **Input Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "path": { "type": "string", "description": "Target file path" },
      "old_string": { "type": "string", "description": "Unique string to replace" },
      "new_string": { "type": "string", "description": "Replacement string" }
    },
    "required": ["path", "old_string", "new_string"]
  }
  ```
- **Requirements**:
  - `old_string` must match exactly one occurrence in the target file.
  - If `old_string` is not found or occurs multiple times, the tool aborts with an error without mutating the file.

---

### 1.5. `glob`
Finds files matching wildcard patterns relative to a target directory.

- **Input Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "pattern": { "type": "string", "description": "Glob pattern (e.g., '**/*.zig')" },
      "path": { "type": "string", "description": "Directory to search (default: '.')" }
    },
    "required": ["pattern"]
  }
  ```
- **Returns**: Newline-delimited list of matching relative file paths.

---

### 1.6. `grep`
Searches text across files in a directory using literal or regex patterns.

- **Input Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "pattern": { "type": "string", "description": "Search pattern or regex" },
      "path": { "type": "string", "description": "Directory or file path (default: '.')" },
      "case_insensitive": { "type": "string", "description": "'true' or 'false'" }
    },
    "required": ["pattern"]
  }
  ```
- **Constraints**:
  - Result limit: 200 lines maximum.
  - Automatically ignores binary files and files larger than 1 MB.

---

### 1.7. `http_request`
Performs an outbound HTTP request using Zig's native `std.http.Client` (`src/lib/http_request.zig`).

- **Input Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "url": { "type": "string", "description": "Fully qualified target URL" },
      "method": { "type": "string", "enum": ["GET", "POST", "PUT", "DELETE", "HEAD"], "default": "GET" },
      "headers": { "type": "object", "description": "HTTP request headers" },
      "body": { "type": "string", "description": "Request body payload" }
    },
    "required": ["url"]
  }
  ```
- **Constraints**: Response body is capped at 30 KB. Request timeout is 30 seconds.

---

### 1.8. `invoke_subagent` & `batch_invoke_subagents`
Spawns one or more isolated child subagents to execute discrete tasks.

- **`invoke_subagent` Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "task": { "type": "string", "description": "Self-contained task description for subagent" }
    },
    "required": ["task"]
  }
  ```
- **`batch_invoke_subagents` Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "tasks": {
        "type": "array",
        "items": { "type": "string" },
        "description": "List of independent task descriptions"
      }
    },
    "required": ["tasks"]
  }
  ```

---

### 1.9. `artifact_write`, `artifact_read`, `artifact_list`
Manages session deliverables (plans, diffs, walkthroughs, diagrams) saved to disk.

- **Storage Path**: `~/.mini/artifacts/<session_id>/<name>`
- **`artifact_write` Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "name": { "type": "string", "description": "Filename of the artifact (e.g., 'plan.md')" },
      "content": { "type": "string", "description": "Markdown or document content" },
      "type": { "type": "string", "description": "MIME or format type (e.g., 'markdown', 'html')" }
    },
    "required": ["name", "content"]
  }
  ```
- Writing an artifact automatically triggers the `artifact_saved` hook for external live previews.

---

### 1.10. `session_diagnostics`
Analyzes session execution logs and health telemetry.

- **Input Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "action": { "type": "string", "enum": ["analyze_recent", "inspect_session"] },
      "limit": { "type": "integer", "description": "Number of recent sessions to inspect" },
      "session_id": { "type": "string", "description": "Specific session ID to detail" }
    },
    "required": ["action"]
  }
  ```
- **Features**: Reads `journal_*.jsonl`, classifies errors (rate limits, context overflow, 5xx outages), computes token usage distributions, and generates latency/thinking profiles.

---

### 1.11. `skills`
Discovers and inspects registered skills adhering to the Multi-Tier Skills standard.

- **Input Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "operation": { "type": "string", "enum": ["list", "detail"], "default": "list" },
      "name": { "type": "string", "description": "Skill identifier (required for 'detail')" },
      "file_path": { "type": "string", "description": "Relative path to sub-resource under references/, templates/, or scripts/" }
    }
  }
  ```

---

### 1.12. `tool_search`
Meta-tool for deferred tool discovery. When `MINI_DEFERRED_TOOLS=1`, non-core tool schemas are omitted from the initial system prompt to save context tokens. The model calls `tool_search` to discover tools matching specific keywords.

- **Input Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "query": { "type": "string", "description": "Keywords describing the capability needed" }
    },
    "required": ["query"]
  }
  ```

---

### 1.13. `codeact`
Directly evaluates an arbitrary JavaScript snippet in the embedded QuickJS engine.

- **Input Schema**:
  ```json
  {
    "type": "object",
    "properties": {
      "code": { "type": "string", "description": "JavaScript code to execute" }
    },
    "required": ["code"]
  }
  ```

---

## 2. Multi-Tier Skills Specification (RFC-031)

`mini-agent` implements the **Multi-Tier Skills Specification**, elevating skills from flat markdown files into structured capability packages.

### 2.1. Directory Hierarchy

A skill resides in either:
- **Project Workspace**: `.agent/skills/<skill_name>/`
- **Global User Directory**: `~/.mini/skills/<skill_name>/`

```
<skill_name>/
├── SKILL.md                 # Required: Main entrypoint and operational guide
├── references/              # Optional: Deep reference documents, schemas, specs
│   ├── api_spec.md
│   └── architecture_diagram.svg
├── templates/               # Optional: Reusable prompt skeletons, report structures
│   └── checklist_template.md
└── scripts/                 # Optional: Deterministic helper scripts (sh, py, js)
    └── validate_env.sh
```

### 2.2. YAML Frontmatter Schema

`SKILL.md` must begin with YAML frontmatter:

```yaml
---
name: kubernetes-ops
description: Deploy, monitor, and troubleshoot Kubernetes clusters via kubectl and helm.
version: 1.2.0
author: Infrastructure Team
platforms:
  - linux
  - darwin
requires_tools:
  - bash
---

# Kubernetes Operations Playbook
...
```

- `name`: Unique alphanumeric identifier.
- `description`: Summary indexed by the agent loop for dynamic tool/skill loading.
- `version`: Semantic version string.
- `platforms`: List of supported operating systems (`linux`, `darwin`, `windows`).
- `requires_tools`: Tools that must be permitted by policy for this skill to operate.

### 2.3. Sub-Resource Security Sandbox

When accessing sub-resources (via `skills` tool or `mini.skill(name, file_path)`):
- The path must be relative and resolve inside `references/`, `templates/`, or `scripts/`.
- Attempts to use parent traversal (`../`) or absolute paths are rejected with a security error.
- Files exceeding 256 KB are blocked from single-call loading to protect the context window.

---

## 3. Custom Slash Commands

Projects can define custom slash commands in `.agent/commands/`.

Any file matching `.agent/commands/<name>.md` becomes available as a `/<name>` command in the interactive REPL:

```markdown
<!-- .agent/commands/review.md -->
Perform a thorough code review on the git diff of the current branch against main.
Focus on:
1. Logic errors and edge cases
2. Memory safety and leak hazards
3. Adherence to project conventions
Output findings categorized as Blocker, Major, or Minor.
```

Typing `/review` in the REPL automatically injects this prompt into the conversation turn.

---

## 4. Model Context Protocol (MCP)

`mini-agent` integrates as an **MCP Client**, connecting to external tool providers over standard input/output using JSON-RPC 2.0.

### 4.1. Configuration (`mcp.json`)

Stored at `~/.mini/mcp.json` (or configured via `MINI_MCP_CONFIG`):

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/workspace"]
    },
    "database": {
      "command": "python3",
      "args": ["-m", "mcp_server_sqlite", "--db-path", "app.db"],
      "env": {
        "SQLITE_TIMEOUT": "5000"
      }
    }
  }
}
```

### 4.2. Tool Namespace & Dispatch

- Tools discovered from an MCP server are automatically prefixed as `<server>__<tool>`. For example, `filesystem__read_file` or `database__query`.
- Tool calls are routed through `src/tooling/mcp.zig`, serialized to JSON-RPC `tools/call` requests over stdio, and the response is normalized back into `proto.ToolResult`.
- All MCP calls adhere to the global allowlist/blocklist policy rules.
- Disable all MCP servers for a run using the `--no-mcp` CLI flag.
