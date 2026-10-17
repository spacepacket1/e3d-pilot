// Which models take part in an e3d_debate when the caller does not say.
// Default: use the client's own models through MCP sampling (e.g. Copilot in VS Code) when the client
// offers them, plus any model CLIs detected on this machine. Without sampling this is the original
// behaviour: the first two available of claude, codex, ...
export const SAMPLING_VOICES = ['mcp-sampling', 'mcp-sampling-b'];
export const CLI_ORDER = ['claude', 'codex', 'gemini', 'grok-build', 'devin', 'local', 'bedrock', 'azure-openai', 'anthropic-api', 'openai-api'];
export const isSampling = (name) => SAMPLING_VOICES.includes(name);

const envList = (v) => (v || '').split(',').map((s) => s.trim()).filter(Boolean);

// known: [{name, available}] from `providers list`; samplingOn: the client supports sampling.
export function chooseVoices({ known, samplingOn, env = process.env, max }) {
  const cli = CLI_ORDER.filter((n) => known.some((k) => k.name === n && k.available));
  const pinned = envList(env.E3D_MCP_PROVIDERS);
  const want = max ?? (Number.parseInt(env.E3D_MCP_AUTO_VOICES ?? '', 10) || (samplingOn ? 3 : 2));
  let providers;
  let selection;
  let note;
  if (pinned.length) {
    providers = pinned;
    selection = 'pinned';
    note = 'pinned by E3D_MCP_PROVIDERS';
  } else if (samplingOn) {
    providers = ['mcp-sampling', ...cli].slice(0, want);
    if (providers.length < 2) providers.push('mcp-sampling-b');
    selection = 'auto';
    note = cli.length
      ? `your client's own models (via MCP sampling) plus detected: ${providers.filter((p) => !isSampling(p)).join(', ')}`
      : "your client's own models only (via MCP sampling), two model families if the client allows";
  } else {
    providers = cli.slice(0, want);
    selection = 'auto';
    note = providers.length ? `detected on this machine: ${providers.join(', ')}` : 'no model providers detected';
  }
  // The synthesizer writes the final verdict. Prefer the client's own model when sampling is on, else claude, else the first voice.
  const claudeUp = known.some((k) => k.name === 'claude' && k.available);
  const synthesizer = providers.includes('mcp-sampling') ? 'mcp-sampling' : (claudeUp ? 'claude' : providers[0]);
  return { providers, synthesizer, selection, note };
}

// Which vendor family a model name or provider belongs to. Voices from the same family (for example Copilot's
// Claude and the claude CLI) are not independent perspectives even though they are separate calls.
export function modelFamily(name) {
  const n = String(name || '').toLowerCase();
  if (/claude|sonnet|opus|haiku|anthropic/.test(n)) return 'anthropic';
  if (/gpt|codex|openai|(^|[^a-z])o\d/.test(n)) return 'openai';
  if (/gemini|google/.test(n)) return 'google';
  if (/grok|xai/.test(n)) return 'xai';
  return null;
}
const PROVIDER_FAMILY = { claude: 'anthropic', codex: 'openai', gemini: 'google', 'grok-build': 'xai', devin: 'anthropic', 'anthropic-api': 'anthropic', 'openai-api': 'openai', 'azure-openai': 'openai' };

// One model arguing with itself is not a debate. Each voice is identified by its vendor family when known,
// else by its exact model name (sampling voices) or provider name. Fewer than two distinct identities = not independent;
// two or more voices from one family is reported as a diversity warning.
export function independence(providers, samplingModels) {
  const modelOf = new Map();
  for (const m of samplingModels) if (!modelOf.has(m.provider)) modelOf.set(m.provider, m.model);
  const voices = providers.map((p) => {
    if (isSampling(p)) {
      const model = modelOf.get(p);
      const family = modelFamily(model);
      return { provider: p, family, key: family ? `family:${family}` : `model:${model ?? p}`, label: model ?? p };
    }
    const family = PROVIDER_FAMILY[p] ?? null;
    return { provider: p, family, key: family ? `family:${family}` : `provider:${p}`, label: p };
  });
  const distinct = new Set(voices.map((v) => v.key));
  const families = [...new Set(voices.map((v) => v.family).filter(Boolean))];
  const warnings = [];
  if (distinct.size < 2) {
    const what = voices[0]?.family ? `the ${voices[0].family} family (${voices.map((v) => v.label).join(', ')})` : `the same model (${voices[0]?.label ?? 'unknown'})`;
    warnings.push(`every voice resolved to ${what}, so this is one model answering itself, not independent perspectives. Allow a second model family for this server (VS Code: MCP: List Servers > Configure Model Access) or add another model CLI.`);
    return { independent: false, warnings, families };
  }
  const count = {};
  for (const v of voices) if (v.family) count[v.family] = (count[v.family] ?? 0) + 1;
  for (const [fam, n] of Object.entries(count)) {
    if (n > 1) warnings.push(`${n} of ${voices.length} voices are ${fam} models (${voices.filter((v) => v.family === fam).map((v) => v.label).join(', ')}); their views may overlap.`);
  }
  return { independent: true, warnings, families };
}
