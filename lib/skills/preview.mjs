#!/usr/bin/env node
// Renders a skill-preview document (read from stdin as JSON) as plain text. Called by bin/e3d-debate --preview-skills. Pure: no file or network access.
import { renderPreview } from './plan.mjs';

let text = '';
process.stdin.setEncoding('utf8');
for await (const chunk of process.stdin) text += chunk;
try { console.log(renderPreview(JSON.parse(text))); } catch (e) { console.error(`error: could not render the preview (${e.message})`); process.exit(2); }
