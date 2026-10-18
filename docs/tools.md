# Built-in Tools Reference

`mini-agent` includes 15 native tools implemented in Zig. In standard JSON tool-calling mode, the model receives JSON schemas and emits structured tool invocations. In CodeAct mode, the same tools are available through the `mini.*` JavaScript runtime bridge.

All tools pass through the centralized policy guard in `src/tooling/registry.zig`, which strictly enforces allowlist and blocklist rules (`MINI_TOOL_ALLOWLIST`, `MINI_TOOL_BLOCKLIST`).

---

## 1. `bash`
Executes a shell command on the host system via `/bin/sh -c` and returns combined standard output and standard error.

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
  - `rm -rf /` or root filesystem deletion.
  - Fork bombs (`:(){ :|:& };:`).
  - Direct block device manipulation (`dd if=... of=/dev/sd*`, `mkfs.*`).
  - System power operations (`shutdown`, `reboot`, `init 0`).

---

## 2. `file_read`
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
  - Binary files are automatically rejected.

---

## 3. `file_write`
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
  - Automatically creates intermediate parent directories.
  - Automatically captures a SHA-256 CAS snapshot of the previous version before modifying the file.
  - Denies writes targeting system directories (`/etc`, `/proc`, `/sys`, `/dev`).

---

## 4. `file_edit`
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

## 5. `glob`
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

## 6. `grep`
Searches text across files in a directory using literal strings or regular expressions.

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

## 7. `http_request`
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

## 8. `invoke_subagent` & `batch_invoke_subagents`
Spawns one or more isolated child subagents to execute discrete sub-tasks.

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

## 9. `artifact_write`, `artifact_read`, `artifact_list`
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

## 10. `session_diagnostics`
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

## 11. `skills`
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

## 12. `tool_search`
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

## 13. `codeact`
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
