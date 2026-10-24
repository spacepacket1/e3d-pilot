// A stateful fake model vendor for tests/seat-reliability.sh: Anthropic Messages (/v1/messages, with or without the search tool) and
// OpenAI-compatible chat completions (/v1/chat/completions, also Gemini's and xAI's shape), on 127.0.0.1 only.
//   node seat-fake.mjs <request-log.jsonl> <port-file>
// The model name picks the behaviour. A call is a "round" call or a "synth" call (the synthesis prompt says "Below is the full
// transcript"); each (endpoint, model, kind) has its own call counter, so a scenario can fail the first call and answer the second.
//   <anything>      answers
//   *-nt1           the first call of each kind: 200 with no text (all output tokens spent on thinking); then answers
//   *-ntall         every call: 200 with no text
//   *-ntsynth       synthesis calls: 200 with no text (every time); round calls answer
//   *-ntsynth1      the first synthesis call: no text; then answers
//   *-ntsearch      a call WITH the search tool: 200 with no text (it did run one search); a call without it answers
//   *-trunc         a call WITH the search tool: only a preamble before the search, then thinking until max_tokens (stop_reason max_tokens, output over the cap)
//   *-e400          HTTP 400 (every call)      *-e429  HTTP 429 (every call)
// POST /reset clears the counters. Every request is logged: {url, model, kind, n (this kind's call number), max_tokens, tools}.
import http from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';

const [log, portFile] = process.argv.slice(2);
const counts = new Map();
const ROUND = (who) => `Answer from ${who}.\nACTION: act\nAGREES_WITH: none\nPOSITION: ${who} position\nstatus: revise`;
const SYNTH = (who) => `FINAL ANSWER: verdict written by ${who}.\nCONSENSUS: majority\nDISSENT: none`;
const srv = http.createServer((req, res) => {
  let raw = '';
  req.on('data', (d) => { raw += d; });
  req.on('end', () => {
    if (req.url === '/reset') { counts.clear(); res.writeHead(200); return res.end('reset'); }
    let body = {};
    try { body = JSON.parse(raw); } catch { /* a probe */ }
    const model = String(body.model ?? '');
    const prompt = JSON.stringify(body.messages ?? body.input ?? '');
    const kind = /Below is the full transcript/.test(prompt) ? 'synth' : 'round';
    const key = `${req.url}|${model}|${kind}`;
    const n = (counts.get(key) ?? 0) + 1;
    counts.set(key, n);
    appendFileSync(log, `${JSON.stringify({ url: req.url, model, kind, n, max_tokens: body.max_tokens ?? body.max_completion_tokens ?? null, tools: body.tools ? body.tools.length : 0 })}\n`);
    const send = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
    if (!body.model) { res.writeHead(200); return res.end('ok'); } // a reachability probe
    if (model.endsWith('-e400')) return send(400, { error: { message: 'bad request' } });
    if (model.endsWith('-e429')) return send(429, { error: { message: 'Rate limit exceeded' } });
    const noText = model.endsWith('-ntall') || (model.endsWith('-ntsearch') && Boolean(body.tools))
      || model.endsWith('-ntall') || (model.endsWith('-nt1') && n === 1) || (kind === 'synth' && (model.endsWith('-ntsynth') || (model.endsWith('-ntsynth1') && n === 1)));
    const vendor = req.url === '/v1/messages' ? 'anthropic-api' : req.url.startsWith('/v1/chat') ? 'openai-api' : 'other';
    const text = kind === 'synth' ? SYNTH(vendor) : ROUND(vendor);
    const limit = body.max_tokens ?? body.max_completion_tokens ?? 100;
    if (req.url === '/v1/messages') {
      if (model.endsWith('-trunc') && body.tools) return send(200, { model, stop_reason: 'max_tokens', content: [{ type: 'text', text: "I'll check the current release." }, { type: 'server_tool_use', id: 's', name: 'web_search', input: { query: 'q' } }, { type: 'web_search_tool_result', tool_use_id: 's', content: [{ type: 'web_search_result', url: 'https://example.com/a', title: 'a', encrypted_content: 'x' }] }, { type: 'thinking', thinking: '...' }], usage: { input_tokens: 3000, output_tokens: limit + 80, server_tool_use: { web_search_requests: 1 } } });
      if (noText) return send(200, { model, stop_reason: 'max_tokens', content: [{ type: 'thinking', thinking: '...' }], usage: { input_tokens: 20, output_tokens: limit, ...(body.tools ? { server_tool_use: { web_search_requests: 1 } } : {}) } });
      return send(200, { model, stop_reason: 'end_turn', content: [{ type: 'text', text }], usage: { input_tokens: 20, output_tokens: 8, ...(body.tools ? { server_tool_use: { web_search_requests: 1 } } : {}) } });
    }
    if (req.url.endsWith('/chat/completions')) {
      if (noText) return send(200, { model, choices: [{ message: { content: '' } }], usage: { prompt_tokens: 20, completion_tokens: limit, total_tokens: 20 + limit } });
      return send(200, { model, choices: [{ message: { content: text } }], usage: { prompt_tokens: 20, completion_tokens: 8, total_tokens: 28 } });
    }
    res.writeHead(404); res.end('not found');
  });
});
srv.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(srv.address().port)));
for (const s of ['SIGTERM', 'SIGINT']) process.on(s, () => { srv.close(); srv.closeAllConnections?.(); process.exit(0); });
