# Agent Client Protocol (ACP) Server Specification

## 1. Overview

The **Agent Client Protocol (ACP)** is an open, JSON-RPC 2.0 standard over standard input and output (stdio) that allows integrated development environments (IDEs)—such as Zed AI and JetBrains—to control and interact with autonomous agents.

When invoked with `--acp`, `mini-agent` runs in ACP Server mode (`src/acp/server.zig`), transforming the binary into an external agent daemon driven by the IDE.

```bash
mini-agent --acp
```

---

## 2. Protocol Transport & Handshake

ACP uses JSON-RPC 2.0 framed with standard line-delimited JSON or `Content-Length` headers over `stdin` and `stdout`.

### 2.1. Initialization (`initialize`)

The IDE initiates communication by sending the `initialize` method:

#### Request
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "1.0",
    "clientInfo": {
      "name": "Zed",
      "version": "0.155.0"
    },
    "capabilities": {
      "streaming": true,
      "toolCalling": true
    }
  }
}
```

#### Response
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "1.0",
    "agentInfo": {
      "name": "mini-agent",
      "version": "1.0.0"
    },
    "capabilities": {
      "streaming": true,
      "modes": ["codeact", "tools", "auto"],
      "sessionPersistence": true
    }
  }
}
```

---

## 3. Session Lifecycle Methods

### 3.1. `session/new`
Creates an isolated session bounded to a workspace directory.

#### Request
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "session/new",
  "params": {
    "cwd": "/home/user/projects/web-app",
    "mcpServers": []
  }
}
```

#### Response
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "sessionId": "acp_sess_1729281234"
  }
}
```

### 3.2. `session/prompt`
Submits a user prompt to the agent and initiates the multi-turn agentic loop.

#### Request
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "session/prompt",
  "params": {
    "sessionId": "acp_sess_1729281234",
    "prompt": "Fix the failing unit tests in test/auth_test.zig"
  }
}
```

While processing the prompt, the agent emits real-time asynchronous notifications back to the IDE:

#### Streaming Notifications (`session/update`)

1. **Thinking Stream** (`agent_thought_chunk`):
   ```json
   {
     "jsonrpc": "2.0",
     "method": "session/update",
     "params": {
       "sessionId": "acp_sess_1729281234",
       "type": "agent_thought_chunk",
       "content": "Analyzing auth_test.zig failures..."
     }
   }
   ```

2. **Message Stream** (`agent_message_chunk`):
   ```json
   {
     "jsonrpc": "2.0",
     "method": "session/update",
     "params": {
       "sessionId": "acp_sess_1729281234",
       "type": "agent_message_chunk",
       "content": "I identified the root cause in token validation."
     }
   }
   ```

3. **Tool Execution** (`tool_call` & `tool_call_update`):
   ```json
   {
     "jsonrpc": "2.0",
     "method": "session/update",
     "params": {
       "sessionId": "acp_sess_1729281234",
       "type": "tool_call",
       "callId": "call_1",
       "tool": "bash",
       "input": { "command": "zig build test" },
       "status": "executing"
     }
   }
   ```

Once the turn completes, the final response is returned:
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "status": "completed",
    "finishReason": "end_turn"
  }
}
```

### 3.3. `session/cancel`
Aborts an in-progress generation or tool execution immediately.

#### Request
```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "session/cancel",
  "params": {
    "sessionId": "acp_sess_1729281234"
  }
}
```

### 3.4. `session/close`
Finalizes the session and saves context to disk.

---

## 4. IDE Integration Guides

### 4.1. Zed AI Integration

Add `mini-agent` as an external agent in your Zed configuration (`~/.config/zed/settings.json`):

```json
{
  "agent": {
    "external_agents": {
      "mini": {
        "command": "mini-agent",
        "args": ["--acp"],
        "env": {
          "OPENAI_COMPAT_URL": "https://api.openai.com/v1",
          "OPENAI_COMPAT_API_KEY": "sk-proj-...",
          "OPENAI_COMPAT_MODEL": "gpt-4o"
        }
      }
    }
  }
}
```

In Zed, open the Agent Panel and select `mini` from the agent dropdown.

### 4.2. JetBrains IDE Integration

Configure `mini-agent` in the JetBrains AI Assistant / ACP plugin settings:
1. Navigate to **Settings** $\to$ **Tools** $\to$ **Agent Client Protocol**.
2. Add a new agent with:
   - **Executable**: `/usr/local/bin/mini-agent`
   - **Arguments**: `--acp`
   - **Environment Variables**: Configure your backend API keys.
