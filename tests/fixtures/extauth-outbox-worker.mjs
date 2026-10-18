// A separate deliverer process for the outbox tests (tests/fixtures/extauth-outbox-test.mjs).
//   node extauth-outbox-worker.mjs flush       wait for $OUTBOX_GO to exist, flush once, print { delivered, retried, dead }
//   node extauth-outbox-worker.mjs start       start() only (no flush call), wait until the outbox is empty, print stats
//   node extauth-outbox-worker.mjs start-only  start() and nothing else: the timer must not keep the process alive
// Environment: STUB_URL, SVC_TOKEN, OUTBOX_STATE, OUTBOX_GO, WORKER_LOG.
import { appendFileSync, existsSync } from 'node:fs';
import { createExternalAuth } from '../../lib/mcp/external-auth.js';
import { createOutbox } from '../../lib/mcp/outbox.js';

const E = process.env;
const log = (line) => { if (E.WORKER_LOG) appendFileSync(E.WORKER_LOG, `${line}\n`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const auth = createExternalAuth({ url: E.STUB_URL, serviceToken: E.SVC_TOKEN, env: {}, log });
const outbox = createOutbox({ dir: E.OUTBOX_STATE, auth, log, env: {} });
auth.attachOutbox(outbox);

const mode = process.argv[2];
if (mode === 'flush') {
  for (let i = 0; i < 400 && !existsSync(E.OUTBOX_GO); i++) await sleep(5);
  const r = await outbox.flush();
  process.stdout.write(`${JSON.stringify({ pid: process.pid, delivered: r.delivered, retried: r.retried, dead: r.dead })}\n`);
} else if (mode === 'start') {
  outbox.start();
  let s;
  for (let i = 0; i < 200; i++) {
    s = await outbox.stats();
    if (s.pending + s.claimed === 0) break;
    await sleep(50);
  }
  process.stdout.write(`${JSON.stringify({ pending: s.pending, claimed: s.claimed, dead: s.dead, delivered: s.counters.delivered })}\n`);
} else if (mode === 'start-only') {
  outbox.start();
} else {
  console.error(`unknown mode ${mode}`);
  process.exit(2);
}
