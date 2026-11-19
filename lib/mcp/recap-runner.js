// The recap job (docs/debate-recap.md): one call on a cheap provider that reads the stored rounds of a finished debate and answers how it moved.
// Zero dependencies beyond the engine's own modules. The hosting service owns the money (it reserves, and settles from the usage this returns); this module
// only runs the call. It is stateless apart from a short memory of recent request ids, so a retry of the same request returns the same answer instead of
// making a second paid call.
//
//   run({ requestId, debateId, provider, maxTokens, rounds }) -> { ok: true, recap, usage } | { ok: false, code, retry? }
//     code: invalid (a bad request, never retried) | not_allowed (the provider is not on E3D_MCP_RECAP_PROVIDERS) | unavailable (retry later)
//           | unusable (the provider answered but nothing in the answer could be checked; the call was made, so `usage` says what it used)
//
// Everything model-written is data: the prompt says so, the reply is checked against the stored rounds (lib/debate/recap.mjs parseRecap), and nothing
// is logged but ids, provider names and counts.
import { execFile } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { recapPrompt, parseRecap, normalizeRounds } from '../debate/recap.mjs';
import { MAX_TOKENS_ENV, vendorUsage } from '../debate/token-pricing.mjs';
import { NAME_RE } from './util.js';

export const RECAP_CAPABILITY = 'recap_v1';
export const RECAP_LIMITS = Object.freeze({ maxTokens: [64, 4096], timeoutMs: 90000, maxOutput: 262144, memory: 256, memoryMs: 15 * 60 * 1000 });
const REQUEST_ID = /^[A-Za-z0-9_.:-]{1,128}$/;
const DEBATE_ID = /^dbt_[0-9a-f]{24}$/;

// E3D_MCP_RECAP: unset, empty or 0 is off; 1 is on and needs E3D_MCP_RECAP_PROVIDERS (the providers a recap may run on, comma separated).
export function recapConfigFrom(env = process.env) {
  const raw = env.E3D_MCP_RECAP;
  if (raw === undefined || raw === '' || raw === '0') return { ok: true, on: false, providers: [], errors: [] };
  if (raw !== '1') return { ok: false, on: false, providers: [], errors: ['E3D_MCP_RECAP must be unset, 0 or 1'] };
  const providers = String(env.E3D_MCP_RECAP_PROVIDERS ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  const errors = [];
  if (providers.length === 0) errors.push('E3D_MCP_RECAP=1 needs E3D_MCP_RECAP_PROVIDERS (the providers a recap may run on)');
  if (providers.some((p) => !NAME_RE.test(p) || p.length > 64)) errors.push('E3D_MCP_RECAP_PROVIDERS must be a comma-separated list of provider names');
  if (providers.some((p) => !MAX_TOKENS_ENV[p])) errors.push('E3D_MCP_RECAP_PROVIDERS names a provider with no output-limit setting (API providers and OpenRouter voices only)');
  if (new Set(providers).size !== providers.length) errors.push('E3D_MCP_RECAP_PROVIDERS lists a provider twice');
  return { ok: errors.length === 0, on: errors.length === 0, providers, errors };
}

const execp = (file, args, opts) => new Promise((resolve) => {
  execFile(file, args, opts, (error, stdout, stderr) => resolve({ error, stdout: String(stdout ?? ''), stderr: String(stderr ?? '') }));
});

// providersDir: lib/providers; providers: the allowlist; env: the environment adapters read their keys from; log: ids and counts only.
export function createRecapRunner({ providersDir, providers, env = process.env, log = () => {}, now = Date.now, exec = execp }) {
  const recent = new Map(); // requestId -> { at, key, answer }
  const sweep = () => { const t = now(); for (const [k, v] of recent) if (t - v.at > RECAP_LIMITS.memoryMs) recent.delete(k); while (recent.size > RECAP_LIMITS.memory) recent.delete(recent.keys().next().value); };

  async function run({ requestId, debateId, provider, maxTokens, rounds }) {
    if (typeof requestId !== 'string' || !REQUEST_ID.test(requestId) || typeof debateId !== 'string' || !DEBATE_ID.test(debateId)) return { ok: false, code: 'invalid' };
    if (typeof provider !== 'string' || !providers.includes(provider)) return { ok: false, code: 'not_allowed' };
    if (!Number.isSafeInteger(maxTokens) || maxTokens < RECAP_LIMITS.maxTokens[0] || maxTokens > RECAP_LIMITS.maxTokens[1]) return { ok: false, code: 'invalid' };
    const parsed = normalizeRounds(rounds);
    if (!parsed || parsed.roundsRan < 2) return { ok: false, code: 'invalid' };
    const key = JSON.stringify([debateId, provider, maxTokens, parsed]);
    sweep();
    const prior = recent.get(requestId);
    if (prior) return prior.key === key ? prior.answer : { ok: false, code: 'invalid' }; // the same id with other fields is a mistake, never an answer
    const dir = await mkdtemp(join(tmpdir(), 'e3d-recap-'));
    try {
      const promptFile = join(dir, 'prompt.md');
      await writeFile(promptFile, recapPrompt(parsed), { mode: 0o600 });
      const limitVar = MAX_TOKENS_ENV[provider];
      const r = await exec(join(providersDir, provider), [promptFile], {
        env: { ...env, [limitVar]: String(maxTokens), E3D_PROVIDER_PER_TOKEN: '1', E3D_PILOT_CHECK: '', E3D_PILOT_DRY_RUN: '' },
        timeout: RECAP_LIMITS.timeoutMs, maxBuffer: RECAP_LIMITS.maxOutput, killSignal: 'SIGKILL',
      });
      const u = vendorUsage(r.stderr);
      const usage = u ? { input_tokens: u.input, output_tokens: u.output, model: typeof u.model === 'string' ? u.model : 'unspecified' } : null;
      if (r.error) {
        log(`recap: ${debateId} ${provider} failed`);
        // a call that reached the vendor and left a usage line is still reported, so the service can settle what it cost
        return { ok: false, code: 'unavailable', retry: true, ...(usage ? { usage } : {}) };
      }
      const recap = parseRecap(r.stdout, parsed);
      const answer = recap ? { ok: true, recap, usage } : { ok: false, code: 'unusable', usage };
      log(`recap: ${debateId} ${provider} ${recap ? `ok ${recap.entries.length} entries` : 'unusable'}`);
      recent.set(requestId, { at: now(), key, answer });
      return answer;
    } finally {
      await rm(dir, { recursive: true, force: true }).catch(() => {});
    }
  }
  return { run };
}
