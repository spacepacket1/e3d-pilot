import { TASKS, FLAG } from './tasks.mjs';
// caught(task, answers[]): per error, did ANY of the given answer texts catch it? Returns {errId: bool}.
export function caught(task, answers) {
  const out = {};
  for (const e of task.errors) out[e.id] = answers.some((a) => FLAG.test(a) && e.all.every((re) => re.test(a)));
  return out;
}
export { TASKS };
