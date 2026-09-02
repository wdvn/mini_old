#!/usr/bin/env node
/**
 * mock_llm_server.js — Mock LLM server (OpenAI /v1/chat/completions SSE + /v1/responses)
 * Dùng cho test E2E mini-agent. Chọn response theo query param ?case=<tên>
 * hoặc theo body.messages (auto-detect). Chạy: node scripts/mock_llm_server.js [port]
 */
const http = require('http');
const PORT = parseInt(process.argv[2] || '8399', 10);

// ---- Định nghĩa các case mock ----
const CASES = {
  // Case mặc định: trả text đơn giản
  simple: {
    match: () => true,
    sse: (reqBody) => ({
      id: 'mock-1', object: 'chat.completion.chunk', created: Date.now() / 1000 | 0,
      model: reqBody.model || 'mock-model',
      choices: [{ index: 0, delta: { role: 'assistant', content: 'Xin chào từ mock LLM!' }, finish_reason: null }],
    }),
    finish: 'stop',
  },
  // Case: yêu cầu gọi tool bash
  tool_call: {
    match: (b) => {
      if (!Array.isArray(b.messages)) return false;
      if (b.messages.some(m => m.role === 'tool')) return false; // đã có tool result → để after_tool xử lý
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
  // Case: nhiều chunk nội dung (kiểm tra stream gom lát)
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
  // Case: tool_call rồi sau tool result trả text (detect theo message role tool)
  after_tool: {
    match: (b) => Array.isArray(b.messages) && b.messages.some(m => m.role === 'tool'),
    sse: (reqBody) => ({
      id: 'mock-4', object: 'chat.completion.chunk', created: Date.now() / 1000 | 0,
      model: reqBody.model || 'mock-model',
      choices: [{ index: 0, delta: { content: 'Tool đã chạy: ' + (reqBody.messages.filter(m => m.role === 'tool').map(m => String(m.content)).join('|').slice(0, 50)) }, finish_reason: null }],
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
    const caseName = url.searchParams.get('case');
    let chosen = (caseName && CASES[caseName]) || null;
    if (!chosen) {
      for (const k of Object.keys(CASES)) {
        if (k !== 'simple' && CASES[k].match(parsed)) { chosen = CASES[k]; break; }
      }
    }
    if (!chosen) chosen = CASES.simple;
    // Log để debug
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
