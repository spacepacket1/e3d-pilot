// The fake-vendor fixture of per_token_search_v1 (billing's docs/token-pricing-search-spec.md 22.5): the four vendors' search-capable
// APIs on 127.0.0.1, with scripted responses whose search counts and usage produce the rows that billing's report vectors consume.
//   node fake-vendor-search.mjs <request-log.jsonl> <port-file>
// Every request is logged as one JSON line {url, body}; a test counts the lines of a model to prove "one request per key".
// The model name picks the scenario (prefix a- Anthropic Messages, o- OpenAI Responses, x- xAI Responses under /xai, g- Gemini Interactions):
//   <p>-s<N>      answers after N searches (N = 0, 1, 2, 7 ...): the vendor's own counter says N, the usage includes search-result tokens
//   <p>-nocount   a 200 whose usage has no search counter and no search items (the count is unknown)
//   <p>-503       HTTP 503 (a transient vendor error: must NOT be retried)
//   <p>-hang      never answers (the client's own timeout ends it: the response is lost)
//   <p>-reset     reads the request, then destroys the socket (a transport error after the request was sent)
//   <p>-failed    a 200 with usage whose search tool reports a failure (our own checks refuse the answer; the vendor billed it)
//   a-pause       stop_reason pause_turn with text (a continuation would be a second request); a-pause-empty has no text
// Usage per scenario (fixed numbers, so rows are exact):
//   Anthropic  input 100 + 800 per search (search results included), cache write 5, cache read 3, output 40, server_tool_use.web_search_requests N
//   OpenAI     input_tokens 100 + 800 per search, output_tokens 30, total = sum; N web_search_call items
//   xAI        as OpenAI, plus server_side_tool_usage_details.web_search_calls N
//   Gemini     total_input_tokens 100, total_tool_use_tokens 800 per search, total_output_tokens 20, total_thought_tokens 10, grounding_tool_count N
// Without tools (a plain call: the synthesizer, a provider not searching) every vendor answers "Plain answer from <vendor>." with small fixed usage.
import http from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';

const [log, portFile] = process.argv.slice(2);
const URLS = (n, who) => Array.from({ length: n }, (_, i) => `https://source${i}.example.com/${who}/some/long/path/segment/number/${i}/${'x'.repeat(40)}`);
const answer = (who) => `Answer from ${who}: use the current version.\nPOSITION: ${who} position\nstatus: revise`;
const nOf = (model) => { const m = /-s(\d+)$/.exec(model); return m ? Number(m[1]) : 0; };

function anthropic(model, body, send, sock) {
  if (!body.tools) return send(200, { model, stop_reason: 'end_turn', content: [{ type: 'text', text: 'Plain answer from anthropic-api.' }], usage: { input_tokens: 20, output_tokens: 5 } });
  const n = nOf(model);
  const search = (cites) => [{ type: 'server_tool_use', id: 'srvtoolu_1', name: 'web_search', input: { query: 'q' } },
    { type: 'web_search_tool_result', tool_use_id: 'srvtoolu_1', content: cites.map((u) => ({ type: 'web_search_result', url: u, title: 't', encrypted_content: 'E', page_age: '1d' })) }];
  const text = (cites) => ({ type: 'text', text: answer('anthropic-api'), citations: cites.map((u) => ({ type: 'web_search_result_location', url: u, title: 't', cited_text: 'c', encrypted_index: 'EI' })) });
  const usage = (k) => ({ input_tokens: 100 + 800 * k, cache_creation_input_tokens: 5, cache_read_input_tokens: 3, output_tokens: 40, server_tool_use: { web_search_requests: k } });
  if (model.endsWith('-503')) return send(503, { type: 'error', error: { type: 'overloaded_error', message: 'Overloaded' } });
  if (model.endsWith('-reset')) return sock.destroy();
  if (model.endsWith('-hang')) return undefined;
  if (model === 'a-pause') return send(200, { model, stop_reason: 'pause_turn', content: [...search(URLS(1, 'a')), { type: 'text', text: 'partial answer' }], usage: usage(1) });
  if (model === 'a-pause-empty') return send(200, { model, stop_reason: 'pause_turn', content: search(URLS(1, 'a')), usage: usage(1) });
  if (model.endsWith('-failed')) return send(200, { model, stop_reason: 'end_turn', content: [{ type: 'server_tool_use', id: 's', name: 'web_search', input: { query: 'q' } }, { type: 'web_search_tool_result', tool_use_id: 's', content: { type: 'web_search_tool_result_error', error_code: 'unavailable' } }, { type: 'text', text: 'I could not search.' }], usage: usage(0) });
  if (model.endsWith('-nocount')) return send(200, { model, stop_reason: 'end_turn', content: [text([])], usage: { input_tokens: 100, output_tokens: 40 } });
  const cites = URLS(Math.max(n, 1) * 3, 'a');
  return send(200, { model, stop_reason: 'end_turn', content: [...(n ? search(cites) : []), text(n ? cites : [])], usage: usage(n) });
}

function responses(vendor, model, body, send, sock) {
  const n = nOf(model);
  const call = (i, status = 'completed') => ({ type: 'web_search_call', id: `ws_${i}`, status, action: { type: 'search', query: 'q', sources: [{ type: 'url', url: URLS(1, vendor)[0] }] } });
  const msg = (cites) => ({ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: answer(vendor), annotations: cites.map((u, i) => ({ type: 'url_citation', url: u, title: 't', start_index: 0, end_index: i })) }] });
  const usage = (k) => ({ input_tokens: 100 + 800 * k, output_tokens: 30, total_tokens: 130 + 800 * k, ...(vendor === 'xai-api' ? { server_side_tool_usage_details: { web_search_calls: k, x_search_calls: 0 } } : {}) });
  if (model.endsWith('-503')) return send(503, { error: { message: 'busy' } });
  if (model.endsWith('-reset')) return sock.destroy();
  if (model.endsWith('-hang')) return undefined;
  if (model.endsWith('-failed')) return send(200, { model, status: 'completed', output: [call(1, 'failed'), msg([])], usage: usage(1) });
  if (model.endsWith('-nocount')) return send(200, { model, status: 'completed', output: [msg([])], usage: { input_tokens: 100, output_tokens: 30, total_tokens: 130 } });
  const calls = Array.from({ length: n }, (_, i) => call(i + 1));
  return send(200, { model, status: 'completed', output: [{ type: 'reasoning', id: 'r' }, ...calls, msg(URLS(n * 3, vendor))], usage: usage(n) });
}

function gemini(model, body, send, sock) {
  const n = nOf(model);
  const out = (cites) => ({ type: 'model_output', content: [{ type: 'text', text: answer('gemini-api'), annotations: cites.map((u, i) => ({ type: 'url_citation', url: u, title: 't', start_index: 0, end_index: i })) }] });
  const steps = (k) => (k ? [{ type: 'google_search_call', arguments: { queries: Array.from({ length: k }, (_, i) => `q${i}`) } }, { type: 'google_search_result', call_id: 'g', result: [{ search_suggestions: '<div>s</div>' }] }] : []);
  if (model.endsWith('-503')) return send(503, { error: { message: 'busy' } });
  if (model.endsWith('-reset')) return sock.destroy();
  if (model.endsWith('-hang')) return undefined;
  if (model.endsWith('-failed')) return send(200, { id: 'i', model, status: 'failed', steps: [], usage: { total_input_tokens: 100, total_output_tokens: 20, total_tokens: 120 } });
  if (model.endsWith('-nocount')) return send(200, { id: 'i', model, status: 'completed', steps: [out([])], usage: { total_input_tokens: 100, total_output_tokens: 20, total_tokens: 120 } });
  return send(200, { id: 'i', model, status: 'completed', steps: [...steps(n), out(URLS(n * 3, 'g'))],
    usage: { total_input_tokens: 100, total_tool_use_tokens: 800 * n, total_output_tokens: 20, total_thought_tokens: 10, total_tokens: 130 + 800 * n, grounding_tool_count: [{ type: 'google_search', count: n }] } });
}

const chat = (vendor, model, send) => send(200, { model, choices: [{ message: { content: `Plain answer from ${vendor}.` } }], usage: { prompt_tokens: 13, completion_tokens: 5, total_tokens: 30 } });

const srv = http.createServer((req, res) => {
  let raw = '';
  req.on('data', (d) => { raw += d; });
  req.on('end', () => {
    let body = {}; try { body = JSON.parse(raw); } catch { /* a probe */ }
    appendFileSync(log, `${JSON.stringify({ url: req.url, body })}\n`);
    const send = (code, obj) => { if (res.writableEnded) return; res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
    const model = String(body.model ?? '');
    if (req.url === '/v1/messages') return anthropic(model, body, send, req.socket);
    if (req.url === '/v1/responses') return responses('openai-api', model, body, send, req.socket);
    if (req.url === '/xai/v1/responses') return responses('xai-api', model, body, send, req.socket);
    if (req.url === '/v1beta/interactions') return gemini(model, body, send, req.socket);
    if (req.url === '/v1/chat/completions') return chat('openai-api', model, send);
    if (req.url === '/xai/v1/chat/completions') return chat('xai-api', model, send);
    if (req.url === '/v1beta/openai/chat/completions') return chat('gemini-api', model, send);
    res.writeHead(200); res.end('ok');
  });
});
srv.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(srv.address().port)));
for (const s of ['SIGTERM', 'SIGINT']) process.on(s, () => { srv.close(); srv.closeAllConnections?.(); process.exit(0); });
