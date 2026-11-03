import fs from 'node:fs';
import { TASKS, caught } from './score.mjs';
const D = process.argv[2];
let tot = 0, n = 0;
for (const t of TASKS) {
  const files = fs.readdirSync(D).filter((f) => f.startsWith(`${t.id}.`) && f.endsWith('.txt'));
  const per = t.errors.map((e) => files.map((f) => caught(t, [fs.readFileSync(`${D}/${f}`, 'utf8')])[e.id]));
  const rates = per.map((r) => r.filter(Boolean).length + '/' + r.length);
  per.forEach((r) => { tot += r.filter(Boolean).length; n += r.length; });
  console.log(t.id, t.title.padEnd(22), t.errors.map((e, i) => `${e.id}:${rates[i]}`).join('  '));
}
console.log(`overall single-seat catch rate: ${(100 * tot / n).toFixed(0)}% (${tot}/${n})`);
