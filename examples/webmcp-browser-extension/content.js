/**
 * WebMCP Browser Extension - Content Script
 * 
 * Injected into every page to provide browser automation capabilities.
 * Exposes functions to the page context for LLM interaction.
 */

// WebMCP Runtime
class WebMCPRuntime {
  constructor() {
    this.version = '1.0.0';
    this.tools = new Map();
    this.prompts = new Map();
    this.resources = new Map();
    this.isConnected = false;
    this.token = null;
    
    // Register default browser tools
    this._registerDefaults();
    
    // Initialize widget
    this._initWidget();
  }
  
  _registerDefaults() {
    // Get current page info
    this.registerTool('get_page_info', 'Get information about the current page', {
      type: 'object',
      properties: {}
    }, () => {
      return {
        content: [{
          type: 'text',
          text: JSON.stringify({
            url: window.location.href,
            title: document.title,
            domain: window.location.hostname,
            length: document.body ? document.body.innerText.length : 0
          })
        }]
      };
    });
    
    // Get page text
    this.registerTool('get_text', 'Extract text content from the page', {
      type: 'object',
      properties: {
        selector: { type: 'string', description: 'CSS selector to extract from' }
      }
    }, (args) => {
      const selector = args.selector || 'body';
      const el = document.querySelector(selector);
      return {
        content: [{
          type: 'text',
          text: el ? el.innerText : 'Element not found'
        }]
      };
    });
    
    // Find elements
    this.registerTool('find_elements', 'Find elements on the page', {
      type: 'object',
      properties: {
        selector: { type: 'string' },
        limit: { type: 'integer', default: 10 }
      },
      required: ['selector']
    }, (args) => {
      const elements = document.querySelectorAll(args.selector);
      const results = [];
      elements.forEach((el, i) => {
        if (i >= args.limit) return;
        results.push({
          index: i,
          tag: el.tagName,
          id: el.id,
          text: el.innerText?.substring(0, 100)
        });
      });
      return {
        content: [{
          type: 'text',
          text: JSON.stringify(results)
        }]
      };
    });
    
    // Click element
    this.registerTool('click_element', 'Click an element by selector', {
      type: 'object',
      properties: {
        selector: { type: 'string' },
        wait: { type: 'integer', default: 0 }
      },
      required: ['selector']
    }, (args) => {
      const el = document.querySelector(args.selector);
      if (!el) {
        return { content: [{ type: 'text', text: 'Element not found' }] };
      }
      el.click();
      if (args.wait > 0) {
        return { content: [{ type: 'text', text: `Clicked, waiting ${args.wait}ms` }] };
      }
      return { content: [{ type: 'text', text: 'Clicked successfully' }] };
    });
    
    // Fill form field
    this.registerTool('fill_field', 'Fill a form field', {
      type: 'object',
      properties: {
        selector: { type: 'string' },
        value: { type: 'string' }
      },
      required: ['selector', 'value']
    }, (args) => {
      const el = document.querySelector(args.selector);
      if (!el) {
        return { content: [{ type: 'text', text: 'Element not found' }] };
      }
      el.value = args.value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      return { content: [{ type: 'text', text: `Filled "${args.value}"` }] };
    });
    
    // Get links
    this.registerTool('get_links', 'Get all links on the page', {
      type: 'object',
      properties: {
        limit: { type: 'integer', default: 50 }
      }
    }, (args) => {
      const links = document.querySelectorAll('a[href]');
      const results = [];
      links.forEach((a, i) => {
        if (i >= args.limit) return;
        results.push({
          text: a.innerText?.trim(),
          href: a.href
        });
      });
      return {
        content: [{
          type: 'text',
          text: JSON.stringify(results)
        }]
      };
    });
  }
  
  /**
   * Register a custom MCP tool
   */
  registerTool(name, description, schema, handler) {
    this.tools.set(name, { description, schema, handler });
    this._updateWidget();
    return this;
  }
  
  /**
   * Register a prompt template
   */
  registerPrompt(name, description, parameters, handler) {
    this.prompts.set(name, { description, parameters, handler });
    return this;
  }
  
  /**
   * Register a resource
   */
  registerResource(name, description, uriTemplate, handler) {
    this.resources.set(name, { description, uriTemplate, handler });
    return this;
  }
  
  /**
   * Initialize the WebMCP widget UI
   */
  _initWidget() {
    // Check if widget already exists
    if (document.getElementById('webmcp-widget')) return;
    
    const widget = document.createElement('div');
    widget.id = 'webmcp-widget';
    widget.innerHTML = `
      <style>
        #webmcp-widget {
          position: fixed;
          bottom: 20px;
          right: 20px;
          z-index: 2147483647;
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        }
        #webmcp-button {
          width: 40px;
          height: 40px;
          border-radius: 8px;
          background: #007bff;
          color: white;
          border: none;
          cursor: pointer;
          display: flex;
          align-items: center;
          justify-content: center;
          font-size: 20px;
          box-shadow: 0 2px 10px rgba(0,0,0,0.2);
          transition: transform 0.2s;
        }
        #webmcp-button:hover {
          transform: scale(1.1);
        }
        #webmcp-panel {
          display: none;
          position: absolute;
          bottom: 50px;
          right: 0;
          width: 320px;
          background: white;
          border-radius: 12px;
          box-shadow: 0 4px 20px rgba(0,0,0,0.15);
          padding: 16px;
        }
        #webmcp-panel.open {
          display: block;
        }
        #webmcp-panel h3 {
          margin: 0 0 12px 0;
          font-size: 16px;
          color: #333;
        }
        #webmcp-status {
          display: flex;
          align-items: center;
          gap: 8px;
          padding: 8px;
          background: #f5f5f5;
          border-radius: 6px;
          margin-bottom: 12px;
          font-size: 12px;
        }
        .status-dot {
          width: 8px;
          height: 8px;
          border-radius: 50%;
          background: #ccc;
        }
        .status-dot.connected {
          background: #22c55e;
        }
        #webmcp-tools {
          max-height: 300px;
          overflow-y: auto;
          font-size: 12px;
        }
        .tool-item {
          padding: 8px;
          border-bottom: 1px solid #eee;
        }
        .tool-item:last-child {
          border-bottom: none;
        }
        .tool-name {
          font-weight: 600;
          color: #007bff;
        }
        .tool-desc {
          color: #666;
          margin-top: 2px;
        }
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
  
  /**
   * Update widget with current tools
   */
  _updateWidget() {
    const toolsEl = document.getElementById('webmcp-tools');
    if (!toolsEl) return;
    
    let html = '<strong>Available Tools:</strong><br>';
    for (const [name, tool] of this.tools) {
      html += `
        <div class="tool-item">
          <div class="tool-name">${name}</div>
          <div class="tool-desc">${tool.description}</div>
        </div>
      `;
    }
    toolsEl.innerHTML = html;
  }
  
  /**
   * Toggle panel visibility
   */
  togglePanel() {
    const panel = document.getElementById('webmcp-panel');
    if (panel) {
      panel.classList.toggle('open');
    }
  }
  
  /**
   * Handle MCP tool call from background
   */
  async callTool(name, args) {
    const tool = this.tools.get(name);
    if (!tool) {
      return {
        content: [{ type: 'text', text: `Tool not found: ${name}` }],
        isError: true
      };
    }
    
    try {
      const result = await tool.handler(args);
      return result;
    } catch (error) {
      return {
        content: [{ type: 'text', text: `Error: ${error.message}` }],
        isError: true
      };
    }
  }
  
  /**
   * Post message to background script
   */
  postMessage(type, data) {
    chrome.runtime.sendMessage({ type, ...data });
  }
}

// Initialize WebMCP runtime
window.webMCP = new WebMCPRuntime();

// Listen for messages from background
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'MCP_TOOL_CALL') {
    webMCP.callTool(message.tool, message.args).then(sendResponse);
    return true;
  }
});
