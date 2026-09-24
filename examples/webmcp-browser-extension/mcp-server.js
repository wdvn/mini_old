#!/usr/bin/env node
/**
 * WebMCP MCP Server
 * Bridges mini-agent to browser automation via Chrome Extension
 * 
 * Usage: node mcp-server.js [--port 8765]
 */

const http = require('http');
const { v4: uuidv4 } = require('uuid');
const url = require('url');

// Tool definitions
const TOOLS = [
  {
    name: "get_current_url",
    description: "Get the current URL of the active tab",
    inputSchema: { type: "object", properties: {} }
  },
  {
    name: "navigate",
    description: "Navigate to a URL in the active tab",
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
    description: "Fill a form field with text",
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
      properties: { expression: { type: "string" } },
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
        attributes: { type: "array", items: { type: "string" } }
      },
      required: ["selector"]
    }
  },
  {
    name: "list_tabs",
    description: "List all open browser tabs",
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
        wait_for_mcp: { type: "boolean", description: "Wait for content script to connect", default: true },
        timeout_ms: { type: "integer", description: "Max wait time in ms", default: 15000 }
      }
    }
  }
];

const PORT = process.argv.find(a => a.startsWith('--port='))?.split('=')[1] || process.env.PORT || 8765;

// Track pending tab creation requests
const tabRequests = new Map();

// HTTP Server
const server = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Access-Control-Allow-Origin', '*');

  if (req.method === 'OPTIONS') { res.writeHead(200); res.end(); return; }

  const parsed = url.parse(req.url, true);

  // GET /mcp - MCP initialization
  if (parsed.pathname === '/mcp' && req.method === 'GET') {
    res.writeHead(200);
    res.end(JSON.stringify({
      jsonrpc: "2.0",
      result: {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "webmcp-browser", version: "2.0.0" }
      },
      id: null
    }));
    return;
  }

  // GET /tools - List tools
  if (parsed.pathname === '/tools' && req.method === 'GET') {
    res.writeHead(200);
    res.end(JSON.stringify({ jsonrpc: "2.0", result: { tools: TOOLS }, id: null }));
    return;
  }

  // POST /call - Call a tool
  if (parsed.pathname === '/call' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      try {
        const { method, params, id } = JSON.parse(body);
        const requestId = id || uuidv4();
        
        // For create_tab, notify Chrome extension via localhost redirect
        if (method === 'create_tab') {
          const tabArgs = params?.arguments || {};
          
          // Try to call Chrome extension's internal endpoint
          const tabReq = http.request({
            hostname: '127.0.0.1',
            port: PORT,
            path: '/create-tab',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' }
          }, tabRes => {
            let tabBody = '';
            tabRes.on('data', chunk => tabBody += chunk);
            tabRes.on('end', () => {
              try {
                const result = JSON.parse(tabBody);
                res.writeHead(200);
                res.end(JSON.stringify({
                  jsonrpc: "2.0",
                  id: requestId,
                  result: { content: [{ type: 'text', text: JSON.stringify(result) }] }
                }));
              } catch (e) {
                res.writeHead(200);
                res.end(JSON.stringify({
                  jsonrpc: "2.0",
                  id: requestId,
                  result: { content: [{ type: 'text', text: `Tab created (check extension logs): ${tabBody}` }] }
                }));
              }
            });
          });
          
          tabReq.on('error', e => {
            // Extension not running - provide fallback
            console.log(`[WebMCP] Chrome extension not reachable at 127.0.0.1:${PORT}`);
            res.writeHead(200);
            res.end(JSON.stringify({
              jsonrpc: "2.0",
              id: requestId,
              result: {
                content: [{
                  type: 'text',
                  text: JSON.stringify({
                    warning: 'Chrome extension not running. Install and load the extension, then run: node mcp-server.js',
                    tab_id: null,
                    url: tabArgs.url || 'about:blank'
                  })
                }]
              }
            }));
          });
          
          tabReq.write(JSON.stringify({
            url: tabArgs.url,
            wait_for_mcp: tabArgs.wait_for_mcp !== false,
            timeout_ms: tabArgs.timeout_ms || 15000
          }));
          tabReq.end();
          return;
        }

        // Other tools - need active tab from Chrome
        const toolReq = http.request({
          hostname: '127.0.0.1',
          port: PORT,
          path: '/call',
          method: 'POST',
          headers: { 'Content-Type': 'application/json' }
        }, toolRes => {
          let toolBody = '';
          toolRes.on('data', chunk => toolBody += chunk);
          toolRes.on('end', () => {
            res.writeHead(200);
            res.end(JSON.stringify({
              jsonrpc: "2.0",
              id: requestId,
              result: JSON.parse(toolBody).result
            }));
          });
        });
        
        toolReq.on('error', e => {
          res.writeHead(503);
          res.end(JSON.stringify({
            jsonrpc: "2.0",
            id: requestId,
            error: { code: -32000, message: `Chrome extension not running: ${e.message}` }
          }));
        });
        
        toolReq.write(JSON.stringify({
          method,
          params: { arguments: params?.arguments || {} }
        }));
        toolReq.end();
        
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

server.listen(PORT, '127.0.0.1', () => {
  console.log(`WebMCP Browser Server running on http://127.0.0.1:${PORT}`);
  console.log(`Available tools: ${TOOLS.map(t => t.name).join(', ')}`);
  console.log('');
  console.log('To use:');
  console.log('  1. Install Chrome extension in chrome://extensions/ (Load unpacked)');
  console.log('  2. Run this server: node mcp-server.js');
  console.log('  3. Add to ~/.mini/mcp.json:');
  console.log('     { "servers": { "browser": { "command": "node", "args": ["mcp-server.js"] } } }');
});

process.on('SIGINT', () => {
  console.log('\nShutting down...');
  server.close();
  process.exit(0);
});
