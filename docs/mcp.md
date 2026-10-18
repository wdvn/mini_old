# Model Context Protocol (MCP) Manual

## 1. Overview

`mini-agent` integrates as a **Model Context Protocol (MCP) Client**, connecting to external tool providers via JSON-RPC 2.0 over standard input and output (stdio).

This integration allows the agent to consume rich ecosystems of specialized external servers (such as database query engines, browser automation, cloud APIs, and filesystem servers) without modifying `mini-agent` source code.

```
┌────────────────────────────────────────────────────────┐
│ mini-agent (Core)                                      │
│  - Tool Registry & Dispatcher (src/tooling/registry.zig│
│  - Policy Allowlist & Blocklist Guard                  │
└───────────────────────────┬────────────────────────────┘
                            │ stdio (JSON-RPC 2.0)
            ┌───────────────┴───────────────┐
            ▼                               ▼
┌───────────────────────┐       ┌───────────────────────┐
│ MCP Server: filesystem│       │ MCP Server: database  │
│ (@modelcontextprotocol│       │ (mcp_server_sqlite)   │
│  /server-filesystem)  │       │                       │
└───────────────────────┘       └───────────────────────┘
```

---

## 2. Configuration (`mcp.json`)

MCP servers are configured via a JSON file. By default, `mini-agent` reads:
```
~/.mini/mcp.json
```
You can point to an alternate configuration file using the `MINI_MCP_CONFIG` environment variable or the `--mcp-config <path>` CLI flag.

### 2.1. `mcp.json` Schema

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/projects"],
      "env": {
        "DEBUG": "false"
      }
    },
    "database": {
      "command": "python3",
      "args": ["-m", "mcp_server_sqlite", "--db-path", "/home/user/app.db"],
      "env": {
        "SQLITE_TIMEOUT": "5000"
      }
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "$GITHUB_TOKEN"
      }
    }
  }
}
```

### 2.2. Configuration Fields
- **`command`** (`string`, required): Executable to launch (e.g. `npx`, `python3`, `docker`).
- **`args`** (`array of strings`, optional): Command-line arguments passed to the server process.
- **`env`** (`object`, optional): Environment variables injected into the server process. Supports variable expansion and `$VAR` placeholders.

---

## 3. Tool Discovery & Namespace Prefixing

Upon startup:
1. `mini-agent` spawns each configured MCP server process over stdio.
2. Sends the `initialize` handshake and queries `tools/list`.
3. Discovered tools are dynamically registered in the tool registry with a namespaced prefix:
   ```
   <server_name>__<tool_name>
   ```
   *Examples*:
   - Server `filesystem` providing `read_file` $\to$ `filesystem__read_file`
   - Server `database` providing `query` $\to$ `database__query`
   - Server `github` providing `create_issue` $\to$ `github__create_issue`

---

## 4. Security & Policy Enforcement

External MCP tools are first-class participants in `mini-agent`'s security model:

- **Policy Filtering**: All MCP tools respect `MINI_TOOL_ALLOWLIST` and `MINI_TOOL_BLOCKLIST`.
  ```bash
  # Allow only specific MCP tools alongside native shell
  MINI_TOOL_ALLOWLIST=bash,filesystem__read_file,database__query mini-agent
  ```
- **Disabling MCP**: To run `mini-agent` in completely isolated mode without spawning external server processes, pass the `--no-mcp` CLI flag:
  ```bash
  mini-agent --no-mcp -e "Audit the local files"
  ```

---

## 5. Lifecycle Hooks & Observability

MCP communication dispatches events to configured lifecycle hooks (`MINI_HOOK_COMMAND`):

- **`OnRequest`**: Emitted before a `tools/call` JSON-RPC request is sent to an MCP server.
- **`OnNotification`**: Emitted when an MCP server sends an asynchronous notification.
- **`OnError`**: Emitted if an MCP server crashes, times out, or returns a protocol error.

Hook scripts receive:
- Environment variables: `MINI_MCP_SERVER`, `MINI_MCP_METHOD`, `MINI_ERROR_MESSAGE`.
- Complete event payload via `stdin` in JSON format.
