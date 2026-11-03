import { TASKS } from './tasks.mjs';
const t = TASKS.find((x) => x.id === process.argv[2]);
process.stdout.write(`Review the document below. List every error you can find: arithmetic mistakes, internal contradictions, unsupported conclusions, wrong units or dates, and statistical or logical flaws. For each, quote the specific figures or sentences involved and say what is wrong. Do not summarise the document.\n\n--- DOCUMENT: ${t.title} ---\n${t.doc}\n--- END ---`);
