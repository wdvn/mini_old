/**
 * WebMCP Browser Extension - Background Service Worker
 *
 * Handles MCP protocol communication and browser automation commands.
 * Auto-creates MCP-enabled tabs on demand.
 */

const MCP_PORT = 8765;

// Tool definitions following MCP spec
const MCP_TOOLS = [
  {
    name: "get_current_url",
    description: "Get the current URL of the active tab",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "navigate",
    description: "Navigate to a URL",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string" },
        wait_until: { type: "string", enum: ["load", "domcontentloaded", "networkidle"], default: "load" }
      },
      required: ["url"]
    }
  },
  {
    name: "get_page_content",
    description: "Get page content as text or HTML",
    inputSchema: {
      type: "object",
      properties: {
        format: { type: "string", enum: ["text", "html", "markdown"], default: "text" },
        max_length: { type: "integer", default: 10000 }
      }
    }
  },
  {
    name: "click",
    description: "Click an element by CSS selector",
    inputSchema: {
      type: "object",
      properties: {
        selector: { type: "string" },
        timeout: { type: "integer", default: 5000 }
      },
      required: ["selector"]
    }
  },
  {
    name: "fill",
    description: "Fill a form field",
    inputSchema: {
      type: "object",
      properties: {
        selector: { type: "string" },
        value: { type: "string" }
      },
      required: ["selector", "value"]
    }
  },
  {
    name: "screenshot",
    description: "Take a screenshot of the current page",
    inputSchema: {
      type: "object",
      properties: {
        full_page: { type: "boolean", default: false },
        format: { type: "string", enum: ["png", "jpeg"], default: "png" },
        quality: { type: "integer", minimum: 0, maximum: 100, default: 80 }
      }
    }
  },
  {
    name: "evaluate",
    description: "Execute JavaScript in the page context",
    inputSchema: {
      type: "object",
      properties: {
        expression: { type: "string" }
      },
      required: ["expression"]
    }
  },
  {
    name: "get_elements",
    description: "Get elements matching a CSS selector",
    inputSchema: {
      type: "object",
      properties: {
        selector: { type: "string" },
        attribute: { type: "string" }
      },
      required: ["selector"]
    }
  },
  {
    name: "list_tabs",
    description: "List all open tabs with their URLs and titles",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "switch_tab",
    description: "Switch to a tab by ID",
    inputSchema: {
      type: "object",
      properties: { tab_id: { type: "integer" } },
      required: ["tab_id"]
    }
  },
  {
    name: "create_tab",
    description: "Create a new browser tab with WebMCP auto-connected",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: "URL to navigate to (default: about:blank)" },
        wait_for_mcp: { type: "boolean", description: "Wait until content script connects to MCP server", default: true },
        timeout_ms: { type: "integer", description: "Max wait time in milliseconds", default: 15000 }
      }
    }
  }
];

// Track connected tabs: tabId -> Promise resolved when WS connected
const connectedTabs = new Map();

/**
 * Create a new tab with auto-connect capability.
 * Waits for content script to WebSocket-connect to MCP server.
 */
async function createTab(url, waitForMcp = true, timeoutMs = 15000) {
  const tab = await chrome.tabs.create({ url: url || 'about:blank' });
  console.log(`[WebMCP] Created tab ${tab.id}: ${tab.url}`);

  if (!waitForMcp) return tab;

  // Wait for content script to connect via WebSocket
  const connected = new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      connectedTabs.delete(tab.id);
      reject(new Error(`Tab ${tab.id} MCP connection timeout after ${timeoutMs}ms`));
    }, timeoutMs);

    // Listen for the tab to signal it's ready
    const listener = (message, sender, sendResponse) => {
      if (message.type === 'WEBMCP_READY' && sender.tab && sender.tab.id === tab.id) {
        clearTimeout(timer);
        chrome.runtime.onMessage.removeListener(listener);
        connectedTabs.delete(tab.id);
        resolve(tab);
      }
    };
    chrome.runtime.onMessage.addListener(listener);
  });

  return connected;
}

// Handle incoming MCP tool calls
async function handleToolCall(toolName, args) {
  // For create_tab, we handle it specially (no active tab needed)
  if (toolName === 'create_tab') {
    try {
      const tab = await createTab(args.url, args.wait_for_mcp !== false, args.timeout_ms || 15000);
      return {
        content: [{ type: 'text', text: JSON.stringify({ tab_id: tab.id, url: tab.url }) }]
      };
    } catch (error) {
      return {
        content: [{ type: 'text', text: `Error creating tab: ${error.message}` }],
        isError: true
      };
    }
  }

  // For other tools, need an active tab
  const tab = await chrome.tabs.getCurrent();
  if (!tab) return { content: [{ type: 'text', text: 'No active tab' }] };

  try {
    switch (toolName) {
      case 'get_current_url':
        return { content: [{ type: 'text', text: tab.url || 'about:blank' }] };

      case 'navigate':
        await chrome.tabs.update(tab.id, { url: args.url });
        return { content: [{ type: 'text', text: `Navigated to ${args.url}` }] };

      case 'get_page_content':
        const [result] = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: () => {
            return document.body ? document.body.innerText : '';
          }
        });
        let text = result.result;
        if (args.max_length && text.length > args.max_length) {
          text = text.substring(0, args.max_length) + '...';
        }
        return { content: [{ type: 'text', text }] };

      case 'click':
        await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (selector) => {
            const el = document.querySelector(selector);
            if (el) { el.click(); return `Clicked: ${selector}`; }
            return `Element not found: ${selector}`;
          },
          args: [args.selector]
        });
        return { content: [{ type: 'text', text: 'Click executed' }] };

      case 'fill':
        await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (selector, value) => {
            const el = document.querySelector(selector);
            if (el) { el.value = value; el.dispatchEvent(new Event('input', { bubbles: true })); return `Filled: ${selector}`; }
            return `Element not found: ${selector}`;
          },
          args: [args.selector, args.value]
        });
        return { content: [{ type: 'text', text: 'Fill executed' }] };

      case 'screenshot':
        const screenshot = await chrome.tabs.captureVisibleTab(null, {
          format: args.format || 'png',
          quality: args.quality
        });
        return { content: [{ type: 'image', data: screenshot.replace('data:image/png;base64,', ''), mimeType: 'image/png' }] };

      case 'evaluate':
        const [evalResult] = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (expr) => {
            try { return JSON.stringify(eval(expr)); } catch (e) { return `Error: ${e.message}`; }
          },
          args: [args.expression]
        });
        return { content: [{ type: 'text', text: evalResult.result }] };

      case 'get_elements':
        const [elements] = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (selector, attr) => {
            const els = document.querySelectorAll(selector);
            return Array.from(els).map(el => ({
              tag: el.tagName, id: el.id, class: el.className,
              ...(attr ? { [attr]: el.getAttribute(attr) } : {})
            }));
          },
          args: [args.selector, args.attribute]
        });
        return { content: [{ type: 'text', text: JSON.stringify(elements.result) }] };

      case 'list_tabs':
        const tabs = await chrome.tabs.query({});
        return { content: [{ type: 'text', text: JSON.stringify(tabs.map(t => ({ id: t.id, title: t.title, url: t.url }))) }] };

      case 'switch_tab':
        await chrome.tabs.update(args.tab_id, { active: true });
        return { content: [{ type: 'text', text: `Switched to tab ${args.tab_id}` }] };

      default:
        return { content: [{ type: 'text', text: `Unknown tool: ${toolName}` }] };
    }
  } catch (error) {
    return { content: [{ type: 'text', text: `Error: ${error.message}` }], isError: true };
  }
}

// Initialize MCP HTTP server for mini-agent
function startMCPServer() {
  const http = require('http');

  const server = http.createServer(async (req, res) => {
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Access-Control-Allow-Origin', '*');

    if (req.method === 'OPTIONS') { res.writeHead(200); res.end(); return; }

    // GET /mcp - MCP handshake
    if (req.url === '/mcp' && req.method === 'GET') {
      res.writeHead(200);
      res.end(JSON.stringify({
        jsonrpc: '2.0', result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'webmcp-browser', version: '2.0.0' }
        }, id: null
      }));
      return;
    }

    // GET /tools - List tools
    if (req.url === '/tools' && req.method === 'GET') {
      res.writeHead(200);
      res.end(JSON.stringify({ jsonrpc: '2.0', result: { tools: MCP_TOOLS }, id: null }));
      return;
    }

    // POST /call - Execute tool
    if (req.url === '/call' && req.method === 'POST') {
      let body = '';
      req.on('data', chunk => body += chunk);
      req.on('end', async () => {
        try {
          const { method, params } = JSON.parse(body);
          const result = await handleToolCall(method, params?.arguments || {});
          res.writeHead(200);
          res.end(JSON.stringify({ jsonrpc: '2.0', id: 1, result: { content: result.content } }));
        } catch (e) {
          res.writeHead(400);
          res.end(JSON.stringify({ error: e.message }));
        }
      });
      return;
    }

    // POST /create-tab - Notification from mcp-server to create a tab
    if (req.url === '/create-tab' && req.method === 'POST') {
      let body = '';
      req.on('data', chunk => body += chunk);
      req.on('end', () => {
        try {
          const { url, wait_for_mcp, timeout_ms } = JSON.parse(body);
          createTab(url, wait_for_mcp, timeout_ms)
            .then(tab => {
              res.writeHead(200);
              res.end(JSON.stringify({ tab_id: tab.id, url: tab.url }));
            })
            .catch(err => {
              res.writeHead(500);
              res.end(JSON.stringify({ error: err.message }));
            });
        } catch (e) {
          res.writeHead(400);
          res.end(JSON.stringify({ error: e.message }));
        }
      });
      return;
    }

    res.writeHead(404);
    res.end(JSON.stringify({ error: 'Not found' }));
  });

  server.listen(MCP_PORT, '127.0.0.1', () => {
    console.log(`[WebMCP] MCP Server running on http://127.0.0.1:${MCP_PORT}`);
    console.log(`[WebMCP] Tools: ${MCP_TOOLS.map(t => t.name).join(', ')}`);
  });
}

// Handle messages from content scripts
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'WEBMCP_READY') {
    console.log(`[WebMCP] Tab ${sender.tab?.id} is ready!`);
    // No response needed - the background already has the listener
  }
  if (message.type === 'WEBMCP_TOOL_RESULT') {
    console.log(`[WebMCP] Tool result for tab ${sender.tab?.id}:`, message.result);
  }
});

// Start on install
chrome.runtime.onInstalled.addListener(() => {
  console.log('[WebMCP] Extension installed/updated');
  startMCPServer();
});
