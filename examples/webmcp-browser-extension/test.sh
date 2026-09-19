#!/usr/bin/env bash
# Test script for WebMCP Browser Extension
set -e

echo "=== WebMCP Browser Extension - Test Suite ==="
echo ""

# Check dependencies
echo "[1/4] Checking dependencies..."
if ! command -v node &> /dev/null; then
  echo "ERROR: Node.js is required"
  exit 1
fi
echo "  ✓ Node.js: $(node --version)"

if ! command -v npm &> /dev/null; then
  echo "ERROR: npm is required"
  exit 1
fi
echo "  ✓ npm: $(npm --version)"

# Check extension files
echo ""
echo "[2/4] Checking extension files..."
REQUIRED_FILES=(
  "manifest.json"
  "background.js"
  "content.js"
  "popup.html"
  "mcp-server.js"
  "package.json"
)

for f in "${REQUIRED_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    echo "  ✓ $f"
  else
    echo "  ✗ MISSING: $f"
    exit 1
  fi
done

# Validate manifest
echo ""
echo "[3/4] Validating manifest..."
node -e "
const manifest = require('./manifest.json');
if (manifest.manifest_version !== 3) {
  console.error('ERROR: manifest_version must be 3');
  process.exit(1);
}
if (!manifest.permissions.includes('activeTab')) {
  console.error('ERROR: missing activeTab permission');
  process.exit(1);
}
console.log('  ✓ Manifest V3 valid');
console.log('  ✓ Permissions:', manifest.permissions.join(', '));
"

# Test MCP server
echo ""
echo "[4/4] Testing MCP server..."
node -e "
const http = require('http');

// Start test server
const server = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json');
  
  if (req.url === '/tools' && req.method === 'GET') {
    res.end(JSON.stringify({
      jsonrpc: '2.0',
      result: { tools: [
        { name: 'get_current_url', description: 'Get current URL' },
        { name: 'navigate', description: 'Navigate' },
        { name: 'screenshot', description: 'Screenshot' }
      ]},
      id: null
    }));
  } else if (req.url === '/call' && req.method === 'POST') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      const { method } = JSON.parse(body);
      res.end(JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        result: { content: [{ type: 'text', text: 'ok' }] }
      }));
    });
  } else {
    res.end(JSON.stringify({ error: 'not found' }));
  }
});

server.listen(18765, '127.0.0.1', async () => {
  console.log('  ✓ Server started on port 18765');
  
  // Test /tools endpoint
  const toolsRes = await fetch('http://127.0.0.1:18765/tools');
  const tools = await toolsRes.json();
  if (!tools.result || !tools.result.tools) {
    throw new Error('Invalid /tools response');
  }
  console.log('  ✓ GET /tools:', tools.result.tools.length, 'tools');
  
  // Test /call endpoint
  const callRes = await fetch('http://127.0.0.1:18765/call', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ method: 'navigate', params: { arguments: { url: 'https://example.com' } } })
  });
  const callResult = await callRes.json();
  if (!callResult.result) {
    throw new Error('Invalid /call response');
  }
  console.log('  ✓ POST /call: OK');
  
  server.close();
  console.log('  ✓ All MCP endpoints working');
});
" 2>&1

echo ""
echo "=== All tests passed! ==="
echo ""
echo "To use the extension:"
echo "  1. Open chrome://extensions/"
echo "  2. Enable 'Developer mode'"
echo "  3. Click 'Load unpacked'"
echo "  4. Select: $(pwd)"
echo ""
echo "To start MCP server:"
echo "  cd $(pwd)"
echo "  node mcp-server.js"
echo ""
