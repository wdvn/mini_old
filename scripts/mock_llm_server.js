#!/usr/bin/env node
/**
 * mock_llm_server.js — Mock LLM server (OpenAI /v1/chat/completions SSE + /v1/responses)
 * Used for mini-agent E2E tests. Select response via query param ?case=<name>
 * or via body.messages (auto-detect). Run: node scripts/mock_llm_server.js [port]
 */
const http = require('http');
const PORT = parseInt(process.argv[2] || '8399', 10);

// ---- Mock case definitions ----
const CASES = {
  // Default case: returns simple text
  simple: {
    match: () => true,
    sse: (reqBody) => ({
      id: 'mock-1', object: 'chat.completion.chunk', created: Date.now() / 1000 | 0,
      model: reqBody.model || 'mock-model',
      choices: [{ index: 0, delta: { role: 'assistant', content: 'Hello from mock LLM!' }, finish_reason: null }],
    }),
    finish: 'stop',
  },
  // Case: requests calling bash tool
  tool_call: {
    match: (b) => {
      if (!Array.isArray(b.messages)) return false;
      if (b.messages.some(m => m.role === 'tool')) return false; // already has tool result → handled by after_tool
      const lastUser = [...b.messages].reverse().find(m => m.role === 'user');
      return !!lastUser && typeof lastUser.content === 'string' && lastUser.content.toLowerCase().includes('bash');
    },
    sse: (reqBody) => ({
      id: 'mock-2', object: 'chat.completion.chunk', created: Date.now() / 1000 | 0,
      model: reqBody.model || 'mock-model',
      choices: [{ index: 0, delta: {
        role: 'assistant',
        tool_calls: [{ index: 0, id: 'call_1', type: 'function',
          function: { name: 'bash', arguments: JSON.stringify({ command: 'echo mock-tool-ok' }) } }],
      }, finish_reason: null }],
    }),
    finish: 'tool_calls',
  },
  // Case: requests calling generate_video tool
  video_call: {
    match: (b) => {
      if (!Array.isArray(b.messages)) return false;
      if (b.messages.some(m => m.role === 'tool')) return false;
      const lastUser = [...b.messages].reverse().find(m => m.role === 'user');
      return !!lastUser && typeof lastUser.content === 'string' && lastUser.content.toLowerCase().includes('generate video');
    },
    sse: (reqBody) => ({
      id: 'mock-video-call', object: 'chat.completion.chunk', created: Date.now() / 1000 | 0,
      model: reqBody.model || 'mock-model',
      choices: [{ index: 0, delta: {
        role: 'assistant',
        tool_calls: [{ index: 0, id: 'call_video_1', type: 'function',
          function: { name: 'generate_video', arguments: JSON.stringify({ prompt: 'cyberpunk drone flight', seconds: '4' }) } }],
      }, finish_reason: null }],
    }),
    finish: 'tool_calls',
  },
  // Case: vision inspection (detected by presence of image blocks)
  vision: {
    match: (b) => {
      if (Array.isArray(b.messages)) {
        for (const m of b.messages) {
          if (Array.isArray(m.content)) {
            if (m.content.some(c => c.type === 'image_url' || c.type === 'input_image' || c.type === 'image')) return true;
          }
        }
      }
      if (Array.isArray(b.input)) {
        if (b.input.some(item => item.type === 'input_image')) return true;
      }
      return false;
    },
    sse: (reqBody) => ({
      id: 'mock-vision', object: 'chat.completion.chunk', created: Date.now() / 1000 | 0,
      model: reqBody.model || 'mock-model',
      choices: [{ index: 0, delta: { role: 'assistant', content: '[Vision Verified] Image received' }, finish_reason: null }],
    }),
    finish: 'stop',
  },
  // Case: multiple content chunks (tests streaming chunk merging)
  long_text: {
    match: (b) => {
      if (!Array.isArray(b.messages)) return false;
      const lastUser = [...b.messages].reverse().find(m => m.role === 'user');
      return !!lastUser && typeof lastUser.content === 'string' && lastUser.content.toLowerCase().includes('long');
    },
    sse: (reqBody) => ({
      id: 'mock-3', object: 'chat.completion.chunk', created: Date.now() / 1000 | 0,
      model: reqBody.model || 'mock-model',
      choices: [{ index: 0, delta: { content: 'A'.repeat(500) }, finish_reason: null }],
    }),
    finish: 'stop',
  },
  // Case: after tool result, returns text (detected by role === tool)
  after_tool: {
    match: (b) => Array.isArray(b.messages) && b.messages.some(m => m.role === 'tool'),
    sse: (reqBody) => ({
      id: 'mock-4', object: 'chat.completion.chunk', created: Date.now() / 1000 | 0,
      model: reqBody.model || 'mock-model',
      choices: [{ index: 0, delta: { content: 'Tool executed: ' + (reqBody.messages.filter(m => m.role === 'tool').map(m => String(m.content)).join('|').slice(0, 50)) }, finish_reason: null }],
    }),
    finish: 'stop',
  },
};

function sseChunk(obj) { return 'data: ' + JSON.stringify(obj) + '\n\n'; }

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    let parsed = {};
    try { parsed = JSON.parse(body || '{}'); } catch {}
    const url = new URL(req.url, 'http://x');
    if (url.pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('OK\n');
      return;
    }
    if (url.pathname === '/v1/images/generations' || url.pathname === '/images/generations') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        created: Math.floor(Date.now() / 1000),
        data: [{ b64_json: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=' }],
      }));
      return;
    }
    if ((url.pathname === '/v1/videos' || url.pathname === '/videos') && req.method === 'POST') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ id: 'mock-video-99', video_id: 'mock-video-99', status: 'queued' }));
      return;
    }
    // AgnesAI compat polling endpoint: /agnesapi or /v1/agnesapi?video_id={id}&model_name={model}
    if (url.pathname === '/agnesapi' || url.pathname === '/v1/agnesapi') {
      const videoId = url.searchParams.get('video_id');
      if (videoId === 'mock-video-99') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          id: 'mock-video-99',
          status: 'completed',
          metadata: { url: 'http://127.0.0.1:' + PORT + '/v1/videos/mock-video-99/content' }
        }));
        return;
      }
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'video_id not found' }));
      return;
    }
    if (url.pathname.match(/\/videos\/mock-video-99$/)) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ id: 'mock-video-99', status: 'completed' }));
      return;
    }
    if (url.pathname.match(/\/videos\/mock-video-99\/content$/)) {
      res.writeHead(200, { 'Content-Type': 'video/mp4' });
      res.end(Buffer.from([
        0x00, 0x00, 0x00, 0x10,
        0x66, 0x74, 0x79, 0x70,
        0x69, 0x73, 0x6f, 0x6d,
        0x00, 0x00, 0x02, 0x00,
      ]));
      return;
    }
    const caseName = url.searchParams.get('case');
    let chosen = (caseName && CASES[caseName]) || null;
    if (!chosen) {
      for (const k of Object.keys(CASES)) {
        if (k !== 'simple' && CASES[k].match(parsed)) { chosen = CASES[k]; break; }
      }
    }
    if (!chosen) chosen = CASES.simple;
    // Debug logging
    console.error('[mock] ' + req.method + ' ' + req.url + ' case=' + (chosen && Object.keys(CASES).find(k => CASES[k] === chosen) || 'simple'));
    if (process.env.MOCK_DEBUG) require('fs').writeFileSync('/tmp/mock_last_request.json', body);

    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
    if (parsed.stream === false) {
      // Non-streaming response
      res.end(JSON.stringify({
        id: 'mock-ns', object: 'chat.completion', created: Date.now() / 1000 | 0,
        model: parsed.model || 'mock-model',
        choices: [{ index: 0, message: { role: 'assistant', content: 'NONSTREAM-OK' }, finish_reason: chosen.finish }],
        usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
      }));
      return;
    }
    // SSE streaming: role chunk → content chunk → finish chunk → [DONE]
    const rb = chosen.sse(parsed);
    res.write(sseChunk(rb));
    const finishChunk = { id: rb.id, object: 'chat.completion.chunk', created: rb.created, model: rb.model,
      choices: [{ index: 0, delta: {}, finish_reason: chosen.finish }] };
    res.write(sseChunk(finishChunk));
    res.write(sseChunk({ id: rb.id, object: 'chat.completion.chunk', created: rb.created, model: rb.model,
      choices: [], usage: { prompt_tokens: 12, completion_tokens: 8, total_tokens: 20 } }));
    res.end('data: [DONE]\n\n');
  });
});
server.listen(PORT, '127.0.0.1', () => console.log('[mock] listening on 127.0.0.1:' + PORT));
