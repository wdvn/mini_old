/**
 * WebMCP Browser Extension - Background Service Worker
 * 
 * Handles MCP protocol communication and browser automation commands.
 * Connects to mini-agent via WebSocket or stdio.
 */

// MCP Protocol State
let mcpSocket = null;
let isConnected = false;
let pendingRequests = new Map();

// Configuration
const CONFIG = {
  mcpPort: 8765,
  reconnectInterval: 5000,
  maxMessageSize: 10 * 1024 * 1024, // 10MB
};

// MCP Tool Definitions
const MCP_TOOLS = [
  {
    name: "get_current_url",
    description: "Get the current URL of the active tab",
    inputSchema: {
      type: "object",
      properties: {}
    }
  },
  {
    name: "navigate",
    description: "Navigate to a URL",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: "URL to navigate to" },
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
        selector: { type: "string", description: "CSS selector" },
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
        expression: { type: "string", description: "JavaScript expression to evaluate" }
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
    inputSchema: {
      type: "object",
      properties: {}
    }
  },
  {
    name: "switch_tab",
    description: "Switch to a tab by ID",
    inputSchema: {
      type: "object",
      properties: {
        tab_id: { type: "integer" }
      },
      required: ["tab_id"]
    }
  }
];

// Initialize MCP server
async function initializeMCPServer() {
  try {
    const response = await fetch(`http://localhost:${CONFIG.mcpPort}/mcp`);
    if (response.ok) {
      mcpSocket = response;
      isConnected = true;
      console.log("[WebMCP] Connected to MCP server");
      
      // Send initialized notification
      sendMCPPayload({
        jsonrpc: "2.0",
        method: "notifications/initialized"
      });
    }
  } catch (error) {
    console.log("[WebMCP] MCP server not running, will retry...");
    setTimeout(initializeMCPServer, CONFIG.reconnectInterval);
  }
}

// Send MCP payload
function sendMCPPayload(payload) {
  if (!mcpSocket || !isConnected) return;
  
  try {
    // In a real implementation, this would use WebSocket or HTTP
    console.log("[WebMCP] Sending:", JSON.stringify(payload));
  } catch (error) {
    console.error("[WebMCP] Send error:", error);
  }
}

// Handle MCP tool calls
async function handleToolCall(toolName, arguments_) {
  const tab = await chrome.tabs.getCurrent();
  if (!tab) return { content: [{ type: "text", text: "No active tab" }] };
  
  try {
    switch (toolName) {
      case "get_current_url":
        return {
          content: [{ type: "text", text: tab.url || "about:blank" }]
        };
      
      case "navigate":
        const url = arguments_.url;
        await chrome.tabs.update(tab.id, { url });
        return { content: [{ type: "text", text: `Navigated to ${url}` }] };
      
      case "get_page_content":
        const [result] = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: () => {
            if (arguments_.format === "html") return document.documentElement.outerHTML;
            return document.body.innerText;
          }
        });
        let text = result.result;
        if (arguments_.max_length && text.length > arguments_.max_length) {
          text = text.substring(0, arguments_.max_length) + "...";
        }
        return { content: [{ type: "text", text }] };
      
      case "click":
        await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (selector) => {
            const el = document.querySelector(selector);
            if (el) { el.click(); return `Clicked: ${selector}`; }
            return `Element not found: ${selector}`;
          },
          args: [arguments_.selector]
        });
        return { content: [{ type: "text", text: "Click executed" }] };
      
      case "fill":
        await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (selector, value) => {
            const el = document.querySelector(selector);
            if (el) { el.value = value; el.dispatchEvent(new Event('input', { bubbles: true })); return `Filled: ${selector}`; }
            return `Element not found: ${selector}`;
          },
          args: [arguments_.selector, arguments_.value]
        });
        return { content: [{ type: "text", text: "Fill executed" }] };
      
      case "screenshot":
        const screenshot = await chrome.tabs.captureVisibleTab(null, {
          format: arguments_.format || "png",
          quality: arguments_.quality
        });
        return {
          content: [{
            type: "image",
            data: screenshot.replace("data:image/png;base64,", ""),
            mimeType: "image/png"
          }]
        };
      
      case "evaluate":
        const [evalResult] = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (expr) => {
            try {
              return JSON.stringify(eval(expr));
            } catch (e) {
              return `Error: ${e.message}`;
            }
          },
          args: [arguments_.expression]
        });
        return { content: [{ type: "text", text: evalResult.result }] };
      
      case "get_elements":
        const [elements] = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: (selector, attr) => {
            const els = document.querySelectorAll(selector);
            return Array.from(els).map(el => {
              const obj = { tag: el.tagName, id: el.id, class: el.className };
              if (attr) obj[attr] = el.getAttribute(attr);
              return obj;
            });
          },
          args: [arguments_.selector, arguments_.attribute]
        });
        return { content: [{ type: "text", text: JSON.stringify(elements.result) }] };
      
      case "list_tabs":
        const tabs = await chrome.tabs.query({});
        return {
          content: [{
            type: "text",
            text: JSON.stringify(tabs.map(t => ({ id: t.id, title: t.title, url: t.url })))
          }]
        };
      
      case "switch_tab":
        await chrome.tabs.update(arguments_.tab_id, { active: true });
        return { content: [{ type: "text", text: `Switched to tab ${arguments_.tab_id}` }] };
      
      default:
        return {
          content: [{ type: "text", text: `Unknown tool: ${toolName}` }]
        };
    }
  } catch (error) {
    return {
      content: [{ type: "text", text: `Error: ${error.message}` }],
      isError: true
    };
  }
}

// WebSocket server for MCP connection
let wss = null;

async function startMCPServer() {
  try {
    // Use a simple HTTP server approach
    const http = await import('http');
    
    const server = http.createServer(async (req, res) => {
      res.setHeader('Content-Type', 'application/json');
      
      if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
      }
      
      if (req.url === '/mcp' && req.method === 'GET') {
        // Upgrade to WebSocket (simplified)
        res.writeHead(200);
        res.end(JSON.stringify({ status: "connected" }));
        return;
      }
      
      if (req.url === '/tools' && req.method === 'GET') {
        res.writeHead(200);
        res.end(JSON.stringify({ tools: MCP_TOOLS }));
        return;
      }
      
      if (req.url === '/call' && req.method === 'POST') {
        let body = '';
        req.on('data', chunk => body += chunk);
        req.on('end', async () => {
          try {
            const { method, params } = JSON.parse(body);
            const result = await handleToolCall(method, params?.arguments || {});
            res.writeHead(200);
            res.end(JSON.stringify({ result }));
          } catch (error) {
            res.writeHead(500);
            res.end(JSON.stringify({ error: error.message }));
          }
        });
        return;
      }
      
      res.writeHead(404);
      res.end();
    });
    
    await new Promise((resolve) => {
      server.listen(CONFIG.mcpPort, '127.0.0.1', resolve);
    });
    
    console.log(`[WebMCP] MCP Server running on http://127.0.0.1:${CONFIG.mcpPort}`);
    wss = server;
    
  } catch (error) {
    console.error("[WebMCP] Failed to start server:", error);
  }
}

// Initialize
chrome.runtime.onInstalled.addListener(() => {
  console.log("[WebMCP] Extension installed");
  startMCPServer();
});

// Handle messages from content script
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'MCP_TOOL_CALL') {
    handleToolCall(message.tool, message.args).then(sendResponse);
    return true; // Async response
  }
});
