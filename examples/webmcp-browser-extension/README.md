# WebMCP Browser Extension

Chrome/Firefox extension that enables LLM agents (mini-agent, Claude Code, etc.) to control the browser via the Model Context Protocol (MCP).

## 🚀 Quick Start

### 1. Install the Extension

1. Open Chrome and navigate to `chrome://extensions/`
2. Enable **Developer mode** (toggle in top right)
3. Click **Load unpacked**
4. Select this folder: `examples/webmcp-browser-extension/`

### 2. Start the MCP Server

```bash
cd examples/webmcp-browser-extension
npm install uuid
node mcp-server.js
```

### 3. Configure mini-agent

Add to `~/.mini/mcp.json`:

```json
{
  "servers": {
    "browser": {
      "command": "node",
      "args": ["examples/webmcp-browser-extension/mcp-server.js"]
    }
  }
}
```

Or run mini-agent with inline config:

```bash
mini-agent --mcp-config ~/.mini/mcp.json
```

## 🛠️ Available Tools

| Tool | Description |
|------|-------------|
| `browser__get_current_url` | Get current page URL |
| `browser__navigate` | Navigate to URL |
| `browser__get_page_content` | Get page text/HTML |
| `browser__click` | Click element by selector |
| `browser__fill` | Fill form field |
| `browser__screenshot` | Take screenshot |
| `browser__evaluate` | Execute JavaScript |
| `browser__get_elements` | Find elements by selector |
| `browser__list_tabs` | List all tabs |
| `browser__switch_tab` | Switch to tab |

## 📁 Project Structure

```
webmcp-browser-extension/
├── manifest.json        # Extension manifest (Manifest V3)
├── background.js        # Service worker (MCP server)
├── content.js           # Content script (injected into pages)
├── popup.html           # Extension popup UI
├── popup.js             # Popup logic
├── mcp-server.js        # Standalone MCP server
└── README.md            # This file
```

## 🔧 How It Works

```
┌─────────────┐     MCP JSON-RPC      ┌──────────────────┐
│  mini-agent │ ───────────────────►  │  MCP Server      │
│  (Zig)      │                       │  (Node.js)       │
└─────────────┘                       └────────┬─────────┘
                                               │ Chrome
                                               │ Extension
                                               ▼
                                        ┌──────────────────┐
                                        │  Chrome Browser  │
                                        │  (Page Context)  │
                                        └──────────────────┘
```

1. **mini-agent** sends MCP tool call via HTTP
2. **MCP Server** forwards to Chrome Extension
3. **Extension** executes in page context using `chrome.scripting` API
4. Result flows back through the chain

## 🔌 Integration with Claude Code

Claude Code can connect using the same MCP config:

```json
{
  "mcpServers": {
    "browser": {
      "command": "node",
      "args": ["examples/webmcp-browser-extension/mcp-server.js"]
    }
  }
}
```

Then start Claude Code with `--chrome` flag.

## 📝 Example Usage

```javascript
// In mini-agent / Claude Code session:
browser__navigate("https://github.com")
browser__get_page_content(format="text")
browser__click(selector=".header-search-input")
browser__fill(selector=".header-search-input", value="mini-agent")
browser__click(selector="button[type='submit']")
browser__screenshot()
```

## 🧪 Testing

Test the MCP server directly:

```bash
# List tools
curl http://localhost:8765/tools

# Call a tool
curl -X POST http://localhost:8765/call \
  -H "Content-Type: application/json" \
  -d '{"method":"get_current_url","params":{}}'
```

## 🔒 Security

- Extension requires `activeTab` permission (only accesses current tab)
- All communication is local (127.0.0.1)
- No data leaves your machine

## 📄 License

MIT
