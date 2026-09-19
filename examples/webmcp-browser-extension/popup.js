/**
 * WebMCP Browser Extension - Popup Script
 */

function saveConfig() {
  const port = document.getElementById('mcp-port').value;
  const url = document.getElementById('mcp-url').value;
  
  chrome.storage.local.set({
    mcpPort: port,
    mcpUrl: url
  }, () => {
    alert('Configuration saved!');
  });
}

// Load saved config on startup
chrome.storage.local.get(['mcpPort', 'mcpUrl'], (data) => {
  if (data.mcpPort) {
    document.getElementById('mcp-port').value = data.mcpPort;
  }
  if (data.mcpUrl) {
    document.getElementById('mcp-url').value = data.mcpUrl;
  }
});
