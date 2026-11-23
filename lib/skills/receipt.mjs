// The skills block of a receipt (docs/skills/spec, skills phase 2 and 3; calibration spec 3.1). Added to decision-log.json only when E3D_SKILLS_V1=1 and a
// panel ran; absent otherwise, so every receipt without the flag is byte-identical to before. Holds identifiers, versions, hashes and ids for this use; no
// question, answer or skill text. Pure: it works from the catalogue the planner loaded and the experts it chose, and re-reads nothing, so what it records
// describes the bytes the panel was planned from (an expert whose folder bytes no longer match any catalogue entry gets a null definition and says so).
import { randomBytes } from 'node:crypto';
import { findSkill } from './plan.mjs';

// `use_<20 hex>`: names one use of a skill, so an outcome can later be reported against it (calibration spec section 3.1).
export const newUseId = () => `use_${randomBytes(10).toString('hex')}`;
export const newAttachmentId = () => `att_${randomBytes(8).toString('hex')}`;

// seats: [{ seat, expert, source }] in panel order. -> one entry per seat.
export function skillReceiptEntries(seats, catalogue) {
  return seats.map(({ seat, expert: e, source }) => {
    const base = { seat, hook: 'seat_prompt', scope: 'debate_seat', source, attachment_id: newAttachmentId(), use_id: newUseId(), tier: e.tier, legacy_folder_hash: e.hash };
    const hit = findSkill(catalogue, e);
    if (!hit) return { ...base, name: e.name, definition: null, reason: 'not_projectable_or_changed' };
    const d = hit.definition;
    return { ...base, id: d.id, version: d.version, definition_hash: d.definition_hash, source_format: d.provenance.source_format };
  });
}
