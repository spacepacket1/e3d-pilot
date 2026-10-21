// A fake model vendor for the token pricing tests: Anthropic Messages (/v1/messages) and OpenAI chat completions
// (/v1/chat/completions, also Gemini's and xAI's OpenAI-compatible shape). No network beyond 127.0.0.1.
//   node fake-vendor.mjs <request-log.jsonl> <port-file>
// The model name picks the behaviour: *-429 (HTTP 429), *-500, *-nousage (a 200 with no usage), *-empty (a 200 with no content but billed
// usage), *-hang (never answers). Anything else answers FAKE_ANSWER (default "Four.") with fixed usage:
//   Anthropic: input 11 + cache_creation 5 + cache_read 3, output 7
//   OpenAI-compatible: prompt 13, completion 5, total 30 (12 reasoning tokens that completion_tokens does not include)
import http from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';

const [log, portFile] = process.argv.slice(2);
const answer = process.env.FAKE_ANSWER || 'Four.';
const srv = http.createServer((req, res) => {
  let raw = '';
  req.on('data', (d) => { raw += d; });
  req.on('end', () => {
    let body = {};
    try { body = JSON.parse(raw); } catch { /* a probe */ }
    appendFileSync(log, `${JSON.stringify({ url: req.url, body })}\n`);
    const model = String(body.model ?? '');
    const send = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
    if (model.endsWith('-hang')) return; // the client's own timeout ends it
    if (model.endsWith('-429')) return send(429, { error: { message: 'Rate limit exceeded' } });
    if (model.endsWith('-500')) return send(500, { error: { message: 'boom' } });
    const text = model.endsWith('-empty') ? '' : answer;
    if (req.url === '/v1/messages') {
      const usage = model.endsWith('-nousage') ? undefined : { input_tokens: 11, cache_creation_input_tokens: 5, cache_read_input_tokens: 3, output_tokens: 7 };
      return send(200, { model: `${model}-20261001`, content: text ? [{ type: 'text', text }] : [], ...(usage ? { usage } : {}) });
    }
    if (req.url.endsWith('/chat/completions')) {
      const usage = model.endsWith('-nousage') ? undefined : { prompt_tokens: 13, completion_tokens: 5, total_tokens: 30 };
      return send(200, { model: `${model}-20261001`, choices: [{ message: { content: text } }], ...(usage ? { usage } : {}) });
    }
    res.writeHead(404); res.end('not found');
  });
});
srv.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(srv.address().port)));
for (const s of ['SIGTERM', 'SIGINT']) process.on(s, () => { srv.close(); srv.closeAllConnections?.(); process.exit(0); });
