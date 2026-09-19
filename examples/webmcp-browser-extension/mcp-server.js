#!/usr/bin/env node
/**
 * WebMCP MCP Server
 * Bridges mini-agent to browser automation via Chrome Extension
 */

const http = require('http');
const { v4: uuidv4 } = require('uuid');

// Tool definitions following MCP spec
const TOOLS = [
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
    description: "Navigate to a URL in the active tab",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: "URL to navigate to" },
        wait_until: {
          type: "string",
          enum: ["load", "domcontentloaded", "networkidle"],
          default: "load",
          description: "When to consider navigation succeeded"
        }
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
        format: {
          type: "string",
          enum: ["text", "html", "markdown"],
          default: "text",
          description: "Output format"
        },
        max_length: {
          type: "integer",
          default: 10000,
          description: "Maximum characters to return"
        }
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
    description: "Fill a form field with text",
    inputSchema: {
      type: "object",
      properties: {
        selector: { type: "string", description: "CSS selector of the input" },
        value: { type: "string", description: "Value to fill" }
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
        expression: { type: "string", description: "JavaScript expression" }
      },
      required: ["expression"]
    }
  },
  {
    name: "get_elements",
    description: "Get elements matching a CSS selector with their attributes",
    inputSchema: {
      type: "object",
      properties: {
        selector: { type: "string", description: "CSS selector" },
        attributes: {
          type: "array",
          items: { type: "string" },
          description: "Attributes to extract"
        }
      },
      required: ["selector"]
    }
  },
  {
    name: "list_tabs",
    description: "List all open browser tabs",
    inputSchema: {
      type: "object",
      properties: {}
    }
  },
  {
    name: "switch_tab",
    description: "Switch to a tab by index or ID",
    inputSchema: {
      type: "object",
      properties: {
        tab_id: { type: "integer", description: "Tab ID to switch to" }
      },
      required: ["tab_id"]
    }
  }
];

// MCP State
let nextRequestId = 1;
const requestHandlers = new Map();

// HTTP Server for MCP communication
const PORT = process.env.PORT || 8765;

const server = http.createServer(async (req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  // GET /mcp - Check connection
  if (req.url === '/mcp' && req.method === 'GET') {
    res.writeHead(200);
    res.end(JSON.stringify({
      jsonrpc: "2.0",
      result: {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "webmcp-browser", version: "1.0.0" }
      },
      id: null
    }));
    return;
  }

  // GET /tools - List available tools
  if (req.url === '/tools' && req.method === 'GET') {
    res.writeHead(200);
    res.end(JSON.stringify({
      jsonrpc: "2.0",
      result: { tools: TOOLS },
      id: null
    }));
    return;
  }

  // POST /call - Call a tool
  if (req.url === '/call' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      try {
        const { method, params } = JSON.parse(body);
        const requestId = uuidv4();
        
        // Register handler for response
        requestHandlers.set(requestId, { resolve: null, reject: null });
        
        // For synchronous handling, we'll use a different approach
        // In production, this would communicate with the Chrome extension
        handleToolCall(method, params?.arguments || {})
          .then(result => {
            res.writeHead(200);
            res.end(JSON.stringify({
              jsonrpc: "2.0",
              id: requestId,
              result: { content: result.content || [{ type: "text", text: result }] }
            }));
          })
          .catch(error => {
            res.writeHead(500);
            res.end(JSON.stringify({
              jsonrpc: "2.0",
              id: requestId,
              error: { code: -32000, message: error.message }
            }));
          });
        
      } catch (error) {
        res.writeHead(400);
        res.end(JSON.stringify({ error: error.message }));
      }
    });
    return;
  }

  res.writeHead(404);
  res.end(JSON.stringify({ error: "Not found" }));
});

// Handle tool calls (would communicate with Chrome extension in real impl)
async function handleToolCall(toolName, args = {}) {
  // In a real implementation, this would:
  // 1. Send request to Chrome extension via port.connect()
  // 2. Wait for response
  // 3. Return result
  
  // Mock responses for demonstration
  const mockResponses = {
    "get_current_url": "https://example.com",
    "navigate": `Navigated to ${args.url}`,
    "get_page_content": "<h1>Example Page</h1><p>This is a test page.</p>",
    "click": "Element clicked successfully",
    "fill": `Filled "${args.value}"`,
    "screenshot": "data:image/png;base64,iVBORw0KGgo...",
    "evaluate": "42",
    "get_elements": '[{"tag":"A","text":"Link 1"}]',
    "list_tabs": '[{"id":1,"title":"Tab 1","url":"https://example.com"}]',
    "switch_tab": "Switched to tab"
  };
  
  return mockResponses[toolName] || `Tool ${toolName} called`;
}

server.listen(PORT, () => {
  console.log(`WebMCP Browser Server running on http://localhost:${PORT}`);
  console.log(`Available tools: ${TOOLS.map(t => t.name).join(', ')}`);
});

process.on('SIGINT', () => {
  server.close();
  process.exit(0);
});
