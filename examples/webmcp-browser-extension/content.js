/**
 * WebMCP Browser Extension - Content Script
 *
 * Auto-connects to MCP server via WebSocket and registers browser automation tools.
 */

const MCP_PORT = 8765;
const MCP_WS_URL = `ws://127.0.0.1:${MCP_PORT}/ws`;

class WebMCPRuntime {
  constructor() {
    this.version = '2.0.0';
    this.tools = new Map();
    this.ws = null;
    this.isConnected = false;
    this.reconnectTimer = null;
    this.pendingRequests = new Map();

    this._registerDefaults();
    this._initWidget();
    this._autoConnect();
  }

  _registerDefaults() {
    // Page info
    this.registerTool('get_page_info', 'Get information about the current page', {
      type: 'object', properties: {}
    }, () => ({
      content: [{
        type: 'text',
        text: JSON.stringify({
          url: window.location.href,
          title: document.title,
          domain: window.location.hostname,
          length: document.body ? document.body.innerText.length : 0
        })
      }]
    }));

    // Text extraction
    this.registerTool('get_text', 'Extract text content from the page', {
      type: 'object', properties: {
        selector: { type: 'string', description: 'CSS selector to extract from' }
      }
    }, (args) => {
      const el = document.querySelector(args.selector || 'body');
      return { content: [{ type: 'text', text: el ? el.innerText : 'Element not found' }] };
    });

    // Find elements
    this.registerTool('find_elements', 'Find elements on the page', {
      type: 'object', properties: {
        selector: { type: 'string' },
        limit: { type: 'integer', default: 10 }
      }, required: ['selector']
    }, (args) => {
      const elements = document.querySelectorAll(args.selector);
      const results = [];
      elements.forEach((el, i) => {
        if (i >= args.limit) return;
        results.push({ index: i, tag: el.tagName, id: el.id, class: el.className, text: el.innerText?.substring(0, 100) });
      });
      return { content: [{ type: 'text', text: JSON.stringify(results) }] };
    });

    // Click
    this.registerTool('click_element', 'Click an element by selector', {
      type: 'object', properties: {
        selector: { type: 'string' },
        wait: { type: 'integer', default: 0 }
      }, required: ['selector']
    }, (args) => {
      const el = document.querySelector(args.selector);
      if (!el) return { content: [{ type: 'text', text: 'Element not found' }] };
      el.click();
      return { content: [{ type: 'text', text: args.wait > 0 ? `Clicked, waiting ${args.wait}ms` : 'Clicked successfully' }] };
    });

    // Fill
    this.registerTool('fill_field', 'Fill a form field', {
      type: 'object', properties: {
        selector: { type: 'string' },
        value: { type: 'string' }
      }, required: ['selector', 'value']
    }, (args) => {
      const el = document.querySelector(args.selector);
      if (!el) return { content: [{ type: 'text', text: 'Element not found' }] };
      el.value = args.value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return { content: [{ type: 'text', text: `Filled "${args.value}"` }] };
    });

    // Links
    this.registerTool('get_links', 'Get all links on the page', {
      type: 'object', properties: { limit: { type: 'integer', default: 50 } }
    }, (args) => {
      const links = document.querySelectorAll('a[href]');
      const results = [];
      links.forEach((a, i) => { if (i >= args.limit) return; results.push({ text: a.innerText?.trim(), href: a.href }); });
      return { content: [{ type: 'text', text: JSON.stringify(results) }] };
    });
  }

  registerTool(name, description, schema, handler) {
    this.tools.set(name, { description, schema, handler });
    this._updateWidget();
    return this;
  }

  async callTool(name, args) {
    const tool = this.tools.get(name);
    if (!tool) return { content: [{ type: 'text', text: `Tool not found: ${name}` }], isError: true };
    try {
      const result = await tool.handler(args);
      return result;
    } catch (error) {
      return { content: [{ type: 'text', text: `Error: ${error.message}` }], isError: true };
    }
  }

  // Auto-connect to MCP server via WebSocket
  _autoConnect() {
    this._connect();
  }

  _connect() {
    try {
      this.ws = new WebSocket(MCP_WS_URL);

      this.ws.onopen = () => {
        this.isConnected = true;
        console.log('[WebMCP] Content script connected to MCP server');
        this._updateWidget();

        // Notify background that this tab is ready
        chrome.runtime.sendMessage({ type: 'WEBMCP_READY' });

        // Register tools with server
        this._send({
          jsonrpc: '2.0',
          method: 'notifications/tools/register',
          params: {
            tools: Array.from(this.tools.entries()).map(([name, t]) => ({ name, description: t.description, inputSchema: t.schema }))
          }
        });
      };

      this.ws.onmessage = (event) => {
        try {
          const msg = JSON.parse(event.data);
          this._handleMessage(msg);
        } catch (e) {
          console.error('[WebMCP] Parse error:', e);
        }
      };

      this.ws.onclose = () => {
        this.isConnected = false;
        console.log('[WebMCP] WebSocket closed, reconnecting in 3s...');
        this._updateWidget();
        clearTimeout(this.reconnectTimer);
        this.reconnectTimer = setTimeout(() => this._connect(), 3000);
      };

      this.ws.onerror = (err) => {
        console.error('[WebMCP] WebSocket error:', err);
      };
    } catch (e) {
      console.error('[WebMCP] WebSocket init failed:', e);
      this.reconnectTimer = setTimeout(() => this._connect(), 3000);
    }
  }

  _send(data) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(data));
    }
  }

  _handleMessage(msg) {
    if (msg.type === 'tool_call') {
      this.callTool(msg.name, msg.args || {}).then(result => {
        this._send({ type: 'tool_result', id: msg.id, result });
      }).catch(err => {
        this._send({ type: 'tool_error', id: msg.id, error: err.message });
      });
    }
  }

  _initWidget() {
    if (document.getElementById('webmcp-widget')) return;

    const widget = document.createElement('div');
    widget.id = 'webmcp-widget';
    widget.innerHTML = `
      <style>
        #webmcp-widget { position: fixed; bottom: 20px; right: 20px; z-index: 2147483647; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }
        #webmcp-button { width: 40px; height: 40px; border-radius: 8px; background: #007bff; color: white; border: none; cursor: pointer; display: flex; align-items: center; justify-content: center; font-size: 20px; box-shadow: 0 2px 10px rgba(0,0,0,0.2); transition: transform 0.2s; }
        #webmcp-button:hover { transform: scale(1.1); }
        #webmcp-panel { display: none; position: absolute; bottom: 50px; right: 0; width: 320px; background: white; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.15); padding: 16px; }
        #webmcp-panel.open { display: block; }
        #webmcp-panel h3 { margin: 0 0 12px 0; font-size: 16px; color: #333; }
        #webmcp-status { display: flex; align-items: center; gap: 8px; padding: 8px; background: #f5f5f5; border-radius: 6px; margin-bottom: 12px; font-size: 12px; }
        .status-dot { width: 8px; height: 8px; border-radius: 50%; background: #ccc; }
        .status-dot.connected { background: #22c55e; }
        #webmcp-tools { max-height: 300px; overflow-y: auto; font-size: 12px; }
        .tool-item { padding: 8px; border-bottom: 1px solid #eee; }
        .tool-item:last-child { border-bottom: none; }
        .tool-name { font-weight: 600; color: #007bff; }
        .tool-desc { color: #666; margin-top: 2px; }
      </style>
      <button id="webmcp-button" onclick="window.webMCP.togglePanel()">🤖</button>
      <div id="webmcp-panel">
        <h3>WebMCP Browser</h3>
        <div id="webmcp-status">
          <span class="status-dot" id="status-dot"></span>
          <span id="status-text">Disconnected</span>
        </div>
        <div id="webmcp-tools"></div>
      </div>
    `;
    document.body.appendChild(widget);
    this._updateWidget();
  }

  _updateWidget() {
    const dot = document.getElementById('status-dot');
    const text = document.getElementById('status-text');
    if (dot) dot.className = `status-dot${this.isConnected ? ' connected' : ''}`;
    if (text) text.textContent = this.isConnected ? 'Connected' : 'Disconnected';

    const toolsEl = document.getElementById('webmcp-tools');
    if (!toolsEl) return;
    let html = '<strong>Tools:</strong><br>';
    for (const [name, tool] of this.tools) {
      html += `<div class="tool-item"><div class="tool-name">${name}</div><div class="tool-desc">${tool.description}</div></div>`;
    }
    toolsEl.innerHTML = html;
  }

  togglePanel() {
    const panel = document.getElementById('webmcp-panel');
    if (panel) panel.classList.toggle('open');
  }
}

// Initialize globally
window.webMCP = new WebMCPRuntime();
