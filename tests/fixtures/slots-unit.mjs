// Unit tests for lib/mcp/slots.js (run by tests/mcp-slots.sh). A fake clock and fake timers, no real waiting.
import assert from 'node:assert/strict';
import { createSlots } from '../../lib/mcp/slots.js';

function harness(opts = {}) {
  let t = 0; const timers = []; const events = []; let freed = 0;
  const slots = createSlots({
    concurrent: 2, queueMax: 3, waitMs: 1000, ...opts,
    now: () => t, onFree: () => { freed++; }, onEvent: (e) => events.push(e),
    setTimer: (fn, ms) => { const h = { fn, at: t + ms, live: true }; timers.push(h); return h; },
    clearTimer: (h) => { if (h) h.live = false; },
  });
  const advance = (ms) => { t += ms; for (const h of timers) if (h.live && h.at <= t) { h.live = false; h.fn(); } };
  return { slots, advance, events, freed: () => freed };
}
const tick = () => new Promise((r) => setImmediate(r));
let n = 0;
const ok = (msg) => { n++; console.log(`ok - ${msg}`); };

{ // free slots are granted at once; the order of waiters is first in, first out; a release hands the slot to the oldest waiter
  const { slots } = harness();
  const a = await slots.acquire(); const b = await slots.acquire();
  assert.equal(a.ok && b.ok, true); assert.equal(a.waitedMs, 0);
  assert.equal(slots.stats().active, 2);
  const order = [];
  const w1 = slots.acquire().then((r) => { order.push('w1'); return r; });
  const w2 = slots.acquire().then((r) => { order.push('w2'); return r; });
  await tick(); assert.equal(slots.stats().waiting, 2); assert.deepEqual(order, []);
  a.release(); const r1 = await w1; assert.equal(r1.ok, true); assert.deepEqual(order, ['w1']);
  assert.equal(slots.stats().active, 2, 'the slot went straight to the waiter');
  b.release(); const r2 = await w2; assert.deepEqual(order, ['w1', 'w2']);
  r1.release(); r2.release();
  assert.equal(slots.stats().active, 0);
  ok('slots are granted at once when free; waiters are served first in, first out and the slot is handed over directly');
}
{ // release is idempotent: a double release cannot free someone else's slot
  const { slots } = harness({ concurrent: 1 });
  const a = await slots.acquire(); a.release(); a.release(); a.release();
  const b = await slots.acquire(); const c = slots.tryAcquire();
  assert.equal(c, null, 'only one slot exists');
  assert.equal(slots.stats().active, 1);
  b.release();
  ok('release is idempotent per grant');
}
{ // async runs (tryAcquire) never jump ahead of a waiting caller
  const { slots } = harness({ concurrent: 1 });
  const a = await slots.acquire();
  const waiter = slots.acquire();
  await tick();
  assert.equal(slots.tryAcquire(), null);
  a.release();
  const w = await waiter; assert.equal(w.ok, true);
  assert.equal(slots.tryAcquire(), null, 'the waiter now holds the slot');
  w.release();
  assert.equal(typeof slots.tryAcquire(), 'function', 'free again');
  ok('tryAcquire (async runs) queues behind waiting callers');
}
{ // a waiter that waits too long is refused with a timeout, leaves the line, and the others keep their order
  const { slots, advance } = harness({ concurrent: 1, waitMs: 1000 });
  const a = await slots.acquire();
  const first = slots.acquire(); advance(400); const second = slots.acquire(); await tick();
  advance(700); // first (queued at 0) times out at 1000; second (queued at 400) is still waiting
  const r1 = await first; assert.equal(r1.ok, false); assert.equal(r1.reason, 'timeout'); assert.ok(r1.estimateSec >= 5);
  assert.equal(slots.stats().waiting, 1);
  a.release(); const r2 = await second; assert.equal(r2.ok, true);
  r2.release();
  ok('a waiter times out after waitMs, leaves the line, and the next waiter keeps its place');
}
{ // a full line refuses at once; waitMs 0 means the old behaviour (busy, immediately)
  const { slots } = harness({ concurrent: 1, queueMax: 2 });
  const a = await slots.acquire();
  const w1 = slots.acquire(); const w2 = slots.acquire(); await tick();
  const full = await slots.acquire();
  assert.deepEqual([full.ok, full.reason, full.waiting], [false, 'queue_full', 2]);
  a.release(); (await w1).release(); (await w2).release();
  const off = harness({ concurrent: 1, waitMs: 0 }).slots;
  const b = await off.acquire(); const refused = await off.acquire();
  assert.deepEqual([refused.ok, refused.reason], [false, 'busy']);
  b.release();
  ok('a full line refuses at once; waiting off behaves as before (busy)');
}
{ // onFree fires when capacity is left idle, not while a waiter takes the slot; estimates grow with the position and follow the run time
  const { slots, advance, freed, events } = harness({ concurrent: 2 });
  const a = await slots.acquire(); const b = await slots.acquire();
  const w = slots.acquire(); await tick();
  const before = freed();
  a.release(); await w; assert.equal(freed(), before, 'a waiter took the slot: nothing is idle');
  b.release(); assert.equal(freed(), before + 1, 'capacity is idle now');
  const c = await slots.acquire(); advance(30000); c.release();
  const e = slots.stats().avgRunMs; assert.ok(e !== null && e > 0);
  const full = harness({ concurrent: 1, queueMax: 0, waitMs: 1000 }).slots; const x = await full.acquire();
  const small = (await full.acquire()).estimateSec; x.release();
  assert.ok(small >= 5 && small <= 600);
  assert.ok(events.every((ev) => !('principal' in ev) && !('question' in ev)), 'events carry counts and durations only');
  ok('onFree fires only for idle capacity; estimates are bounded; events carry no identifying data');
}
{ // a broken logger cannot break a debate; bad settings are rejected
  const s = createSlots({ concurrent: 1, onEvent: () => { throw new Error('log failed'); } });
  const a = await s.acquire(); assert.equal(a.ok, true); a.release();
  assert.throws(() => createSlots({ concurrent: 0 }), /positive integer/);
  ok('a throwing onEvent is ignored; concurrent must be a positive integer');
}
console.log(`slots unit tests: ${n} passed`);
