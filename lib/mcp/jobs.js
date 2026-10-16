// Async job engine for long-running pipeline work. Each job is a detached process (so it survives the MCP
// server restarting) whose state lives in <repo>/.e3d-pilot/mcp-jobs/<job_id>.{json,log,exit}. The server
// never blocks a tools/call on a stage: it starts a job, returns, and callers poll job status.
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, readdir, rename } from 'node:fs/promises';
import { openSync, closeSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { ROOT } from './util.js';
import { redact } from './redact.js';

const envInt = (env, name, dflt) => { const n = Number.parseInt(env[name] ?? '', 10); return Number.isFinite(n) && n > 0 ? n : dflt; };

// Stage artifacts, latest stage first, used to report how far a run got.
const STAGE_ARTIFACTS = [['publish', 'publish-backend.out'], ['review', 'review-status.txt'], ['execute', 'execute-worktree.txt'],
  ['negotiate', 'spec-final.md'], ['draft', 'spec-draft.md'], ['ideate', 'candidates.md'], ['discover', 'findings.md']];

export function createJobs({ env = process.env } = {}) {
  const limits = {
    maxActive: envInt(env, 'E3D_MCP_MAX_JOBS', 2),
    timeoutMs: envInt(env, 'E3D_MCP_JOB_TIMEOUT_SEC', 3600) * 1000,
  };
  const knownRepos = new Set();

  const dirFor = (repo) => join(repo, '.e3d-pilot', 'mcp-jobs');
  const runDirFor = (repo, runId) => join(repo, '.e3d-pilot', 'runs', runId);
  const pidAlive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } };

  async function save(job) {
    await mkdir(dirFor(job.repo), { recursive: true });
    const file = join(dirFor(job.repo), `${job.job_id}.json`);
    await writeFile(`${file}.tmp`, `${JSON.stringify(job, null, 2)}\n`);
    await rename(`${file}.tmp`, file);
  }

  async function load(repo, jobId) {
    if (!/^job-[a-z0-9-]+$/.test(jobId)) return null;
    try { return JSON.parse(await readFile(join(dirFor(repo), `${jobId}.json`), 'utf8')); } catch { return null; }
  }

  async function list(repo) {
    let names = [];
    try { names = (await readdir(dirFor(repo))).filter((n) => n.endsWith('.json')); } catch { return []; }
    const jobs = (await Promise.all(names.map((n) => load(repo, n.replace(/\.json$/, ''))))).filter(Boolean);
    return jobs.sort((a, b) => a.started_at.localeCompare(b.started_at));
  }

  async function latestRun(repo) {
    try { return (await readFile(join(repo, '.e3d-pilot', 'latest-run'), 'utf8')).trim(); } catch { return null; }
  }

  async function lastCompletedStage(repo, runId) {
    if (!runId) return null;
    const dir = runDirFor(repo, runId);
    const hit = STAGE_ARTIFACTS.find(([, file]) => existsSync(join(dir, file)));
    return hit ? hit[0] : null;
  }

  async function logLines(job) {
    try { return (await readFile(job.log_file, 'utf8')).split('\n'); } catch { return []; }
  }

  // Turns a finished process into a job state. Exit codes are the CLI's own: 3 negotiate needs human,
  // 4 execute needs human, 5 verify failed, 6 reviewer blocked.
  async function classify(job, code) {
    const lines = await logLines(job);
    const joined = lines.join('\n');
    const out = { exit_code: code };
    if (code === 0) {
      if (/^ideas: paused /m.test(joined)) {
        const m = joined.match(/^ideas: paused \S+ run=(\S+) before=(\S+)/m);
        return { ...out, state: 'waiting_for_human', reason: `paused before ${m?.[2] ?? 'execute'}: review the plan, then resume or cancel`, paused_before: m?.[2] ?? 'execute', run_id: m?.[1] ?? job.run_id };
      }
      const pending = joined.match(/^pilot: pending-approval idea=(\S+) status=(\S+)/m);
      if (pending) return { ...out, state: 'waiting_for_human', reason: `idea ${pending[1]} needs human approval (status: ${pending[2]})`, idea_id: pending[1] };
      if (/stopping before|nothing to do/.test(joined)) return { ...out, state: 'succeeded', reason: lines.filter((l) => /stopping before|nothing to do/.test(l)).pop() };
      return { ...out, state: 'succeeded' };
    }
    if (code === 3) return { ...out, state: 'waiting_for_human', reason: 'negotiation could not settle; a human must review the draft' };
    if (code === 4) return { ...out, state: 'waiting_for_human', reason: 'execute stopped for human review (diff over the ceiling or guard violation)' };
    if (code === 5) return { ...out, state: 'failed', reason: 'verification failed; nothing was published' };
    if (code === 6) return { ...out, state: 'blocked', reason: 'the independent reviewer blocked this change' };
    return { ...out, state: 'failed', reason: lines.filter(Boolean).slice(-1)[0] ? `exited ${code}: ${redact(lines.filter(Boolean).slice(-1)[0])}` : `exited ${code}` };
  }

  async function finalize(job, result) {
    Object.assign(job, result, { finished_at: new Date().toISOString() });
    if (job.kind === 'stage' && !job.run_id) job.run_id = await latestRun(job.repo);
    job.last_completed_stage = await lastCompletedStage(job.repo, job.run_id);
    await save(job);
    return job;
  }

  // Brings a stored job up to date: finished? timed out? vanished?
  async function refresh(job) {
    if (job.state !== 'running') return job;
    if (!job.run_id) {
      const latest = await latestRun(job.repo);
      if (latest && latest !== job.latest_run_before) { job.run_id = latest; await save(job); }
    }
    if (existsSync(job.exit_file)) {
      const code = Number.parseInt((await readFile(job.exit_file, 'utf8')).trim(), 10);
      return finalize(job, await classify(job, Number.isFinite(code) ? code : 1));
    }
    if (!pidAlive(job.pid)) return finalize(job, { state: 'failed', exit_code: null, reason: 'the job process ended without reporting an exit code (machine or server restarted?)' });
    if (Date.now() - Date.parse(job.started_at) > (job.timeout_ms ?? limits.timeoutMs)) {
      try { process.kill(-job.pid, 'SIGTERM'); } catch { /* already gone */ }
      return finalize(job, { state: 'failed', exit_code: null, reason: `timed out after ${Math.round((job.timeout_ms ?? limits.timeoutMs) / 1000)}s and was stopped` });
    }
    return job;
  }

  async function activeAcrossRepos() {
    let n = 0;
    for (const repo of knownRepos) for (const j of await list(repo)) if ((await refresh(j)).state === 'running') n++;
    return n;
  }

  return {
    limits,
    list, load, refresh,
    async latest(repo) { const all = await list(repo); return all.length ? all[all.length - 1] : null; },
    async findByRun(repo, runId) { return (await list(repo)).filter((j) => j.run_id === runId).pop() ?? null; },

    // Starts `bin/e3d-pilot <args>` as a detached job. One running job per repo; E3D_MCP_MAX_JOBS across repos.
    async start(repo, { kind, args, run_id = null, idea_id = null, label, extraEnv = {} }) {
      knownRepos.add(repo);
      for (const j of await list(repo)) {
        const fresh = await refresh(j);
        if (fresh.state === 'running') throw new Error(`a job is already running in this repo (${fresh.job_id}: ${fresh.label}); wait for it or check e3d_pilot_job_status`);
      }
      if (await activeAcrossRepos() >= limits.maxActive) throw new Error(`${limits.maxActive} jobs are already running; wait for one to finish (E3D_MCP_MAX_JOBS)`);

      const job_id = `job-${new Date().toISOString().replace(/\D/g, '').slice(0, 14)}-${randomBytes(3).toString('hex')}`;
      const dir = dirFor(repo);
      await mkdir(dir, { recursive: true });
      const log_file = join(dir, `${job_id}.log`);
      const exit_file = join(dir, `${job_id}.exit`);
      const job = {
        job_id, repo, kind, label, args, run_id, idea_id, state: 'running', started_at: new Date().toISOString(), finished_at: null,
        timeout_ms: limits.timeoutMs, latest_run_before: await latestRun(repo), log_file, exit_file, pid: null, exit_code: null,
      };
      const fd = openSync(log_file, 'a');
      // The wrapper records the real exit code, so the result is recoverable even if this server is gone.
      const child = spawn('sh', ['-c', '"$@"; c=$?; printf "%s" "$c" > "$E3D_JOB_EXIT"', 'job', join(ROOT, 'bin/e3d-pilot'), ...args], {
        cwd: repo, env: { ...env, ...extraEnv, E3D_JOB_EXIT: exit_file }, detached: true, stdio: ['ignore', fd, fd],
      });
      child.unref();
      closeSync(fd);
      job.pid = child.pid;
      await save(job);
      return job;
    },

    // Waits up to `seconds` for a running job to settle, reporting progress from its log.
    async wait(repo, jobId, seconds, onProgress) {
      const deadline = Date.now() + seconds * 1000;
      let job = await load(repo, jobId);
      let tick = 0;
      while (job && (job = await refresh(job)).state === 'running' && Date.now() < deadline) {
        const last = (await logLines(job)).filter(Boolean).slice(-1)[0];
        onProgress?.(++tick, last ? redact(last).slice(0, 160) : 'running');
        await new Promise((r) => setTimeout(r, 1500));
      }
      return job;
    },

    async tail(job, n = 40) {
      const lines = (await logLines(job)).filter((l) => l.length);
      return lines.slice(-Math.min(Math.max(n, 1), 200)).map((l) => redact(l).slice(0, 400));
    },
    lastCompletedStage,
    runDirFor,
  };
}
