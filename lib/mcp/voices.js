// Which models take part in an e3d_debate when the caller does not say.
// Default: use the client's own models through MCP sampling (e.g. Copilot in VS Code) when the client
// offers them, plus any model CLIs detected on this machine. Without sampling this is the original
// behaviour: the first two available of claude, codex, ...
export const SAMPLING_VOICES = ['mcp-sampling', 'mcp-sampling-b'];
export const CLI_ORDER = ['claude', 'codex', 'gemini', 'grok-build', 'devin', 'local'];
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

// One model arguing with itself is not a debate: warn when every voice was a sampling voice and they all resolved to one model.
export function independence(providers, samplingModels) {
  const nonSampling = providers.filter((p) => !isSampling(p));
  if (nonSampling.length) return { independent: true, warnings: [] };
  const distinct = new Set(samplingModels.map((m) => m.model));
  if (distinct.size <= 1) {
    const model = [...distinct][0] ?? 'unknown';
    return { independent: false, warnings: [`every voice resolved to the same model (${model}), so this is one model answering itself, not independent perspectives. Allow a second model family for this server (VS Code: MCP: List Servers > Configure Model Access) or add another model CLI.`] };
  }
  return { independent: true, warnings: [] };
}
