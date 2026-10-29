// Debate execution slots with a first-in-first-out wait, so a burst waits its turn instead of being bounced and retrying at the back of the line.
//
// createSlots({ concurrent, queueMax, waitMs, onFree, onEvent }):
//   acquire()     -> Promise<{ ok: true, waitedMs, release }>              a slot, now or after waiting in line
//                  | Promise<{ ok: false, reason, waiting, estimateSec }>  reason: 'queue_full' (the line is full), 'timeout' (waited waitMs),
//                                                                          'busy' (waiting is off: waitMs is 0, the old behaviour)
//   tryAcquire()  -> release | null    a slot only if one is free AND nobody is waiting (async runs queue behind waiting callers)
//   release()     is idempotent per grant; it hands the slot straight to the oldest waiter, and calls onFree when capacity is left idle
//   stats()       -> { active, waiting, concurrent, avgRunMs }
// onEvent receives counts and durations only (never a principal or a question): { type: 'granted'|'released'|'refused', ... }.

const DEFAULT_RUN_MS = 120000;

export function createSlots({ concurrent, queueMax = 0, waitMs = 0, onFree = () => {}, onEvent = () => {}, now = Date.now, setTimer = setTimeout, clearTimer = clearTimeout } = {}) {
  if (!Number.isInteger(concurrent) || concurrent < 1) throw new Error('concurrent must be a positive integer');
  let active = 0;
  let avgRunMs = null;
  const waiters = [];

  const estimateSec = (position) => {
    const run = avgRunMs ?? DEFAULT_RUN_MS;
    return Math.min(600, Math.max(5, Math.ceil((position / concurrent) * run / 1000)));
  };
  const emit = (e) => { try { onEvent({ ...e, active, waiting: waiters.length, concurrent }); } catch { /* logging must never break a debate */ } };

  function grant(waitedMs) {
    active++;
    const startedAt = now();
    let released = false;
    emit({ type: 'granted', waitedMs });
    return function release() {
      if (released) return;
      released = true;
      active--;
      const runMs = Math.max(0, now() - startedAt);
      avgRunMs = avgRunMs === null ? runMs : Math.round(avgRunMs * 0.8 + runMs * 0.2);
      emit({ type: 'released', runMs });
      drain();
    };
  }
  function drain() {
    while (active < concurrent && waiters.length) {
      const w = waiters.shift();
      clearTimer(w.timer);
      const waited = now() - w.at;
      w.resolve({ ok: true, waitedMs: waited, release: grant(waited) });
    }
    if (active < concurrent) onFree();
  }

  function tryAcquire() {
    if (active < concurrent && waiters.length === 0) return grant(0);
    return null;
  }

  function acquire() {
    const direct = tryAcquire();
    if (direct) return Promise.resolve({ ok: true, waitedMs: 0, release: direct });
    if (waitMs <= 0 || waiters.length >= queueMax) {
      const reason = waitMs <= 0 ? 'busy' : 'queue_full';
      emit({ type: 'refused', reason });
      return Promise.resolve({ ok: false, reason, waiting: waiters.length, estimateSec: estimateSec(waiters.length + 1) });
    }
    return new Promise((resolve) => {
      const w = { at: now(), resolve, timer: null };
      w.timer = setTimer(() => {
        const i = waiters.indexOf(w);
        if (i >= 0) waiters.splice(i, 1);
        emit({ type: 'refused', reason: 'timeout', waitedMs: now() - w.at });
        resolve({ ok: false, reason: 'timeout', waiting: waiters.length, estimateSec: estimateSec(waiters.length + 1) });
      }, waitMs);
      if (typeof w.timer?.unref === 'function') w.timer.unref();
      waiters.push(w);
    });
  }

  return { acquire, tryAcquire, stats: () => ({ active, waiting: waiters.length, concurrent, avgRunMs }) };
}
