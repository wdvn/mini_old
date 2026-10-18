# CodeAct Runtime & JavaScript VM Specification

## 1. Overview

The **CodeAct Runtime** is the core execution engine of `mini-agent`. In contrast to conventional AI agents that rely on isolated, single-step JSON tool calls, `mini-agent` prompts the language model to write structured JavaScript (`ES2023+`) programs inside triple-backtick ` ```js ` blocks.

These programs execute within an embedded QuickJS-ng engine linked directly into the binary. A single JavaScript snippet can perform loops, conditions, file manipulation, shell command execution, and network calls synchronously or asynchronously in a single agent turn.

---

## 2. VM Architecture & Sandbox Isolation

### 2.1. Per-Act VM Isolation

To guarantee deterministic execution and eliminate side-effects across conversation turns:
- **Shared `JSRuntime`**: The global engine allocates a single `JSRuntime` instance, sharing base memory management and garbage collection structures.
- **Independent `JSContext` per Act**: For each execution turn (Act), an isolated `JSContext` is created from the runtime.
- **Scope Contamination Prevention**: Top-level variables (`const`, `let`, `var`) and function declarations cannot collide across turns, preventing `SyntaxError: identifier already declared` failures when the model repeats variable names.
- **Context Teardown**: Upon completion of the Act, all context-specific allocations are freed, while the process manager and C-ABI state remain persistent.

### 2.2. Resource Limits & CPU Watchdog

QuickJS is configured with strict operational boundaries:
- **Memory Ceiling**: Maximum 128 MB heap allocation per runtime. Exceeding this limit throws an out-of-memory exception back to the agent loop.
- **Stack Limit**: Maximum 1 MB stack depth to prevent recursion overflow crashes.
- **CPU Burst Watchdog**: An interrupt handler checks elapsed execution time. If a script executes continuously without returning control for more than **5.0 seconds**, the VM interrupts evaluation and raises a timeout error.

### 2.3. Output Capture & Truncation

- `console.log(...)`, `console.warn(...)`, and `console.error(...)` write into an internal memory buffer.
- The output buffer is capped at **64 KB** per Act. If the buffer overflows, earlier lines are truncated with a `[... output truncated ...]` notice, prioritizing the most recent observations.

---

## 3. JavaScript API Reference (`mini.*`)

The runtime exposes the `mini` global object to the JavaScript context via C-ABI exports (`src/runtime/js_bindings.zig`).

### 3.1. Filesystem APIs

#### `mini.read(path, offset?, limit?)`
Reads lines from a file.
- **Arguments**:
  - `path` (`string`): Absolute or relative file path.
  - `offset` (`number`, optional): 1-indexed line offset to start reading from. Default: `1`.
  - `limit` (`number`, optional): Maximum number of lines to read. Default: `2000`.
- **Returns**: `string` — The formatted file content with line numbers.
- **Throws**: Error if file does not exist or exceeds the 10 MB size ceiling.
- **Example**:
  ```javascript
  const header = mini.read("src/main.zig", 1, 20);
  console.log(header);
  ```

#### `mini.write(path, content)`
Creates a new file or overwrites an existing file. Automatically creates intermediate parent directories.
- **Arguments**:
  - `path` (`string`): Target file path.
  - `content` (`string`): File content to write.
- **Returns**: `string` — Status message indicating bytes written.
- **Security**: Denies writes to `/etc`, `/proc`, `/sys`, and `/dev`. Takes a SHA-256 CAS snapshot of the existing file prior to modification.
- **Example**:
  ```javascript
  mini.write("build/output.txt", "Build completed successfully.\n");
  ```

#### `mini.patch(path, oldStr, newStr, opts?)`
Performs a surgical string replacement in a file.
- **Arguments**:
  - `path` (`string`): Target file path.
  - `oldStr` (`string`): Exact substring to find. Must be unique in the file unless options permit duplicates.
  - `newStr` (`string`): Replacement string.
  - `opts` (`object`, optional): `{ allow_multiple: boolean }`.
- **Returns**: `string` — Confirmation message indicating successful patch.
- **Throws**: Error if `oldStr` is not found or occurs multiple times when `allow_multiple` is false.
- **Example**:
  ```javascript
  mini.patch("src/main.zig", 'pub const VERSION = "1.0.0";', 'pub const VERSION = "1.1.0";');
  ```

#### `mini.exists(path)`
Checks if a file or directory exists.
- **Arguments**: `path` (`string`).
- **Returns**: `boolean`.

#### `mini.stat(path)`
Retrieves metadata for a path.
- **Arguments**: `path` (`string`).
- **Returns**: `object` — `{ exists: boolean, is_dir: boolean, is_file: boolean, size: number, mtime: number }`.

---

### 3.2. Search & Pattern Matching APIs

#### `mini.glob(pattern, basePath?)`
Finds files matching wildcard patterns (`*`, `**`, `?`).
- **Arguments**:
  - `pattern` (`string`): Glob pattern (e.g. `**/*.zig`).
  - `basePath` (`string`, optional): Starting directory. Default: `"."`.
- **Returns**: `string[]` — Array of matching file paths.
- **Example**:
  ```javascript
  const testFiles = mini.glob("testcases/test_*.zig");
  console.log(`Found ${testFiles.length} test files`);
  ```

#### `mini.grep(pattern, path?, opts?)`
Searches file contents using regular expressions or literal strings.
- **Arguments**:
  - `pattern` (`string`): Search pattern.
  - `path` (`string`, optional): Search root directory or file path. Default: `"."`.
  - `opts` (`object`, optional): `{ case_insensitive?: boolean, is_regex?: boolean, max_results?: number }`.
- **Returns**: `string` — Formatted list of matches (`path:line: content`). Capped at 200 matches.
- **Example**:
  ```javascript
  const results = mini.grep("fn executeTool", "src/");
  console.log(results);
  ```

---

### 3.3. Command & Process Management APIs

#### `mini.sh(command, opts?)`
Executes a shell command synchronously and returns the output.
- **Arguments**:
  - `command` (`string`): Shell command to execute (via `/bin/sh -c`).
  - `opts` (`object`, optional): `{ timeout_ms?: number, cwd?: string }`.
- **Returns**: `string` — Combined `stdout` and `stderr` output.
- **Security**: Commands matching dangerous patterns (e.g., `rm -rf /`, `> /dev/sd*`) are blocked by the safety filter.
- **Example**:
  ```javascript
  const gitBranch = mini.sh("git rev-parse --abbrev-ref HEAD").trim();
  console.log(`Current branch: ${gitBranch}`);
  ```

#### `mini.shStream(command, opts?)`
Executes a command and streams its output directly to the UI line editor while capturing the final output.
- **Arguments**: Same as `mini.sh`.
- **Returns**: `string` — Full combined output after command completes.

#### `mini.shBackground(command, opts?)`
Spawns a detached background job managed by the internal `ProcessManager`.
- **Arguments**:
  - `command` (`string`): Shell command to launch.
  - `opts` (`object`, optional): `{ cwd?: string }`.
- **Returns**: `string` — Unique `jobId` identifier (e.g. `job_1729281234_1`).
- **Example**:
  ```javascript
  const jobId = mini.shBackground("npm run dev");
  console.log(`Started dev server with Job ID: ${jobId}`);
  ```

#### `mini.jobStatus(jobId)`
Queries the execution status of a background job.
- **Arguments**: `jobId` (`string`).
- **Returns**: `object` — `{ id: string, running: boolean, exit_code: number | null, pid: number }`.

#### `mini.jobLogs(jobId, lines?)`
Reads the recent log output of a running or terminated background job.
- **Arguments**:
  - `jobId` (`string`).
  - `lines` (`number`, optional): Number of trailing lines to read. Default: `50`.
- **Returns**: `string` — Sliced log content.

#### `mini.jobKill(jobId, signal?)`
Sends a termination signal to a background process group.
- **Arguments**:
  - `jobId` (`string`).
  - `signal` (`number`, optional): POSIX signal number. Default: `15` (`SIGTERM`).
- **Returns**: `boolean` — `true` if signal was successfully sent.

---

### 3.4. Networking & HTTP APIs

#### `mini.http(method, url, opts?)`
Performs an HTTP request using the internal libcurl engine.
- **Arguments**:
  - `method` (`string`): `"GET" | "POST" | "PUT" | "DELETE" | "HEAD"`.
  - `url` (`string`): Fully qualified URL.
  - `opts` (`object`, optional):
    - `headers` (`object`): Key-value pairs of request headers.
    - `body` (`string`): Request payload string.
    - `timeout_secs` (`number`): Timeout in seconds. Default: `30`.
- **Returns**: `object` — `{ status: number, body: string, truncated: boolean, headers: object }`.
- **Example**:
  ```javascript
  const res = mini.http("GET", "https://api.github.com/repos/ziglang/zig/releases/latest", {
    headers: { "User-Agent": "mini-agent", "Accept": "application/json" }
  });
  if (res.status === 200) {
    const data = JSON.parse(res.body);
    console.log("Latest Zig release:", data.tag_name);
  }
  ```

---

### 3.5. Knowledge, Skills & Artifact APIs

#### `mini.skill(name, file_path?)`
Loads documentation, instructions, or sub-resources from a registered skill adhering to RFC-031.
- **Arguments**:
  - `name` (`string`): Name of the skill directory.
  - `file_path` (`string`, optional): Relative path to a sub-resource in `references/`, `templates/`, or `scripts/`.
- **Returns**: `string` — File contents of the skill guide or sub-resource.
- **Security**: Strictly prevents path traversal (`..` or absolute paths outside the skill directory).
- **Example**:
  ```javascript
  const guide = mini.skill("brainstorming");
  const spec = mini.skill("kubernetes-ops", "references/api_spec.md");
  ```

#### `mini.artifact(name, content, metadata?)`
Persists a deliverable (such as an implementation plan, architectural diagram, or report) to the session artifact store (`~/.mini/artifacts/<session_id>/`).
- **Arguments**:
  - `name` (`string`): Artifact filename (e.g. `plan.md`, `preview.html`).
  - `content` (`string`): Content of the artifact.
  - `metadata` (`object`, optional): Key-value metadata annotations.
- **Returns**: `string` — Absolute file path where the artifact is saved. Triggers the `artifact_saved` lifecycle hook for external live-preview consumers.

---

### 3.6. Cognitive Control & Environment Properties

#### `mini.setThinking(levelOrTokens)`
Dynamically adjusts reasoning and thinking latency for subsequent turns.
- **Arguments**:
  - `levelOrTokens` (`string | number`): `"low"`, `"medium"`, `"high"`, or an explicit token budget number.
- **Effect**: Updates the model configuration for the next request. Use `"low"` for exploratory or repetitive tasks, and `"high"` for architecture and root-cause analysis.

#### `mini.env(varName)`
Reads an environment variable from the active process environment.
- **Arguments**: `varName` (`string`).
- **Returns**: `string | null`.

#### `mini.workspaceRoot`
- **Type**: `string`.
- **Description**: The resolved root directory of the active workspace.

#### `mini.sessionId`
- **Type**: `string`.
- **Description**: The active session identifier.

---

## 4. Security Guards & Policy Filtering

Every `mini.*` binding is routed through the central security gate in `src/runtime/js_bindings.zig`:

1. **Policy Enforcement**:
   - `mini.sh`, `mini.shStream`, `mini.shBackground` map to the `bash` tool policy.
   - `mini.read` maps to `file_read`.
   - `mini.write` maps to `file_write`.
   - `mini.patch` maps to `file_edit`.
   - If a tool is disabled by `MINI_TOOL_ALLOWLIST` or `MINI_TOOL_BLOCKLIST`, calling the corresponding `mini.*` method immediately throws a JavaScript `TypeError` stating that the tool is blocked by policy.
2. **Duplicate Invocation Guard**:
   - Computes a fuzzy argument hash for each tool call within an Act.
   - If an identical tool call with identical arguments has already executed within the same script turn, the duplicate execution is skipped to prevent accidental runaway loops.
3. **Lifecycle Hooks**:
   - Automatically dispatches `pre-tool-use` and `post-tool-use` events to any configured monitoring hooks.
