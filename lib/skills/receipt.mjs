// The skills block of a receipt (docs/skills/spec, skills phase 2; calibration spec 3.1). Added to decision-log.json only when E3D_SKILLS_V1=1 and a
// panel ran; absent otherwise, so every receipt without the flag is byte-identical to before. Holds identifiers, versions, hashes and an id for this
// use; no question, answer or skill text. Pure apart from reading the expert folders it is handed (the same bytes the debate already loaded).
import { randomBytes } from 'node:crypto';
import { skillFromFolder } from './definition.mjs';

// `use_<20 hex>`: names one use of a skill, so an outcome can later be reported against it (calibration spec section 3.1).
export const newUseId = () => `use_${randomBytes(10).toString('hex')}`;

// experts: the loaded expert objects of a panel ({ name, dir, tier, hash }). -> one entry per expert, in panel order.
export function skillReceiptEntries(experts) {
  return experts.map((e) => {
    const root = e.dir.replace(/[/\\][^/\\]+$/, '');
    const r = skillFromFolder(e.dir, { root, tier: e.tier });
    // the panel was planned from these bytes; if the folder changed since, the entry says so instead of describing different bytes (read once)
    if (r.ok && r.expert.hash !== e.hash) return { name: e.name, tier: e.tier, legacy_folder_hash: e.hash, definition: null, reason: 'changed_since_load', use_id: newUseId() };
    if (!r.ok) return { name: e.name, tier: e.tier, legacy_folder_hash: e.hash, definition: null, reason: r.errors.map((x) => x.code).join(','), use_id: newUseId() };
    const d = r.definition;
    return { id: d.id, version: d.version, definition_hash: d.definition_hash, tier: e.tier, source_format: d.provenance.source_format, legacy_folder_hash: e.hash, use_id: newUseId() };
  });
}
