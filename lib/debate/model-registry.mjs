// The model registry for the OpenRouter transport (lib/providers/openrouter-models.json; docs/openrouter.md): which Pilot voices exist on that
// transport, which exact upstream model each one runs, and which model family it belongs to. A voice is not the transport and not the model:
// four voices share one adapter and one key but are four council seats, and a family, not a voice or an adapter, is what independence counts.
import { readFileSync } from 'node:fs';

export const REGISTRY_PATH = new URL('../providers/openrouter-models.json', import.meta.url);
// Families that already have a direct adapter. They are never routed through OpenRouter (owner decision 2026-11-19), so the registry refuses them:
// that also keeps "GPT direct" and "GPT through OpenRouter" from ever being counted as two independent voices.
export const DIRECT_FAMILIES = Object.freeze(['anthropic', 'openai', 'google', 'xai']);
const VOICE = /^or-[a-z0-9][a-z0-9-]{0,40}$/;
const FAMILY = /^[a-z0-9][a-z0-9-]{0,30}$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const REQUIRED = ['voice_id', 'transport', 'model_id', 'family_id', 'organization_id', 'display_name', 'capabilities', 'context_window', 'input_price', 'output_price',
  'pricing_source', 'pricing_checked_at', 'availability', 'privacy_attributes', 'enabled', 'auto_eligible'];

// The problems with a registry document, as plain strings; an empty list means it is valid.
export function validateRegistry(reg) {
  const problems = [];
  if (!reg || typeof reg !== 'object' || !Array.isArray(reg.models)) return ['the registry needs a models array'];
  const seen = new Set();
  for (const [i, m] of reg.models.entries()) {
    const at = `models[${i}]${m && m.voice_id ? ` (${m.voice_id})` : ''}`;
    if (!m || typeof m !== 'object') { problems.push(`${at}: not an object`); continue; }
    for (const k of REQUIRED) if (!(k in m)) problems.push(`${at}: missing ${k}`);
    if (typeof m.voice_id !== 'string' || !VOICE.test(m.voice_id)) problems.push(`${at}: voice_id must look like or-name`);
    else if (seen.has(m.voice_id)) problems.push(`${at}: duplicate voice_id`);
    else seen.add(m.voice_id);
    if (m.transport !== 'openrouter') problems.push(`${at}: transport must be openrouter`);
    if (typeof m.model_id === 'string' && (m.model_id.startsWith('~') || /(^|[-/])latest$/.test(m.model_id))) problems.push(`${at}: a moving alias such as latest is not a pinned model`);
    else if (typeof m.model_id !== 'string' || !/^[a-z0-9][\w.-]*\/[\w.:-]+$/i.test(m.model_id)) problems.push(`${at}: model_id must be an exact vendor/model id`);
    if (typeof m.family_id !== 'string' || !FAMILY.test(m.family_id)) problems.push(`${at}: bad family_id`);
    else if (DIRECT_FAMILIES.includes(m.family_id)) problems.push(`${at}: ${m.family_id} has a direct adapter and is never routed through OpenRouter`);
    if (!Number.isInteger(m.context_window) || m.context_window <= 0) problems.push(`${at}: context_window must be a positive integer`);
    for (const k of ['input_price', 'output_price']) if (typeof m[k] !== 'number' || !Number.isFinite(m[k]) || m[k] <= 0) problems.push(`${at}: ${k} must be a positive number (never zero or missing)`);
    if (typeof m.pricing_checked_at !== 'string' || !DATE.test(m.pricing_checked_at)) problems.push(`${at}: pricing_checked_at must be a date`);
    if (!['eligible', 'degraded', 'unavailable'].includes(m.availability)) problems.push(`${at}: bad availability`);
    if (typeof m.enabled !== 'boolean' || typeof m.auto_eligible !== 'boolean') problems.push(`${at}: enabled and auto_eligible must be booleans`);
    if (m.auto_eligible === true && m.enabled !== true) problems.push(`${at}: a disabled voice cannot be auto_eligible`);
    if (!Array.isArray(m.capabilities)) problems.push(`${at}: capabilities must be a list`);
  }
  return problems;
}

// The registry as an array of models. A missing or invalid file yields [] (never a throw): the engine must keep working without it.
export function loadRegistry(file = REGISTRY_PATH) {
  try {
    const reg = JSON.parse(readFileSync(file, 'utf8'));
    return validateRegistry(reg).length === 0 ? reg.models : [];
  } catch {
    return [];
  }
}

// { voice_id: family_id } for the enabled voices.
export function voiceFamilies(models = loadRegistry()) {
  return Object.freeze(Object.fromEntries(models.filter((m) => m.enabled).map((m) => [m.voice_id, m.family_id])));
}
