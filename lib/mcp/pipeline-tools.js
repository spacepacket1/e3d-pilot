// MCP tools that drive the e3d-pilot pipeline. They only invoke the same CLI paths a person would
// (`e3d-pilot run`, `ideas ...`); they never reimplement stage logic or weaken a gate.
// Tool descriptions say which tools are free and which spend model credits.
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, run, text, findE3dCode } from './util.js';
import { redact } from './redact.js';

const envInt = (env, name, dflt) => { const n = Number.parseInt(env[name] ?? '', 10); return Number.isFinite(n) && n > 0 ? n : dflt; };
const RUN_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const IDEA_ID_RE = /^idea-[A-Za-z0-9]+$/;

// Artifact names a client may read -> file inside the run directory. Nothing else is reachable.
export const ARTIFACTS = {
  findings: 'findings.md',
  candidates: 'candidates.md',
  'spec-draft': 'spec-draft.md',
  'spec-final': 'spec-final.md',
  'negotiation-log': 'negotiation-log.md',
  'stage-log': 'implementation-stage-log.md',
  review: 'review-comment.md',
  'review-status': 'review-status.txt',
  'review-verify': 'review-verify-summary.md',
  'review-diff': 'review-diff.patch',
  'publish-summary': 'publish-summary.md',
};
const STATE_DIRS = ['e3d-code-state', 's2c-state', 'csr-state']; // newest name first; older runs keep the old names
const MANIFEST_COLUMNS = ['timestamp', 'spec', 'phase', 'title', 'provider', 'model', 'mode', 'dry_run', 'exit_status'];

export function createPipelineTools({ guard, jobs, env = process.env }) {
  const maxArtifactBytes = envInt(env, 'E3D_MCP_MAX_ARTIFACT_BYTES', 100000);
  const fail = (msg) => text(`error: ${msg}`, true);
  const ok = (obj, readable) => ({ content: [{ type: 'text', text: readable ?? JSON.stringify(obj, null, 2) }], structuredContent: obj });
  const pilot = (args, opts) => run(join(ROOT, 'bin/e3d-pilot'), args, opts);

  const withRepo = (fn) => async (args, progress, ctx) => {
    let repo;
    try { repo = await guard.resolveRepo(args.repo); } catch (e) { return fail(e.message); }
    try { return await fn(repo, args, progress, ctx); } catch (e) { return fail(redact(e.message)); }
  };

  async function stateDir(repo, runId) {
    for (const d of STATE_DIRS) if (existsSync(join(jobs.runDirFor(repo, runId), d))) return join(jobs.runDirFor(repo, runId), d);
    return null;
  }

  async function readManifest(repo, runId) {
    const dir = await stateDir(repo, runId);
    if (!dir) return null;
    for (const name of ['manifest.tsv']) {
      try {
        const rows = (await readFile(join(dir, name), 'utf8')).split('\n').filter(Boolean)
          .map((l) => Object.fromEntries(l.split('\t').map((v, i) => [MANIFEST_COLUMNS[i] ?? `col${i}`, v])));
        return rows.map((r) => ({ ...r, succeeded: r.exit_status === '0' && r.dry_run !== '1' }));
      } catch { /* try next */ }
    }
    return null;
  }

  async function availableArtifacts(repo, runId) {
    if (!runId) return [];
    const dir = jobs.runDirFor(repo, runId);
    const names = Object.entries(ARTIFACTS).filter(([, f]) => existsSync(join(dir, f))).map(([n]) => n);
    if (await stateDir(repo, runId)) names.push('manifest', 'phase-summary');
    return names;
  }

  function nextAction(job) {
    const cli = (c) => `e3d-pilot ${c} --repo ${job.repo}`;
    if (job.state === 'running') return 'Still running; call e3d_pilot_job_status again (optionally with wait_seconds).';
    if (job.state === 'waiting_for_human' && job.paused_before) return `Paused before ${job.paused_before}. Review the plan with e3d_pilot_code_plan, then a human decides: resume (e3d_pilot_execute) or cancel (e3d_pilot_cancel_paused).`;
    if (job.state === 'waiting_for_human' && job.idea_id) return `A human must approve the idea: ${cli('ideas approve')} ${job.idea_id} (or e3d_pilot_approve when the server operator has enabled it).`;
    if (job.state === 'waiting_for_human') return 'A human must review before this can continue; read the stage log and artifacts.';
    if (job.state === 'failed' || job.state === 'blocked') return 'Read the log tail and e3d_pilot_artifact (stage-log, review) to see why; nothing was merged or published past the failing stage.';
    return null;
  }

  async function statusView(job, tailLines) {
    const fresh = await jobs.refresh(job);
    const started = Date.parse(fresh.started_at);
    const ended = fresh.finished_at ? Date.parse(fresh.finished_at) : Date.now();
    return {
      job_id: fresh.job_id, repo: fresh.repo, kind: fresh.kind, label: fresh.label, state: fresh.state, reason: fresh.reason ?? null,
      run_id: fresh.run_id, idea_id: fresh.idea_id ?? null, exit_code: fresh.exit_code, started_at: fresh.started_at, finished_at: fresh.finished_at,
      elapsed_sec: Math.round((ended - started) / 1000), last_completed_stage: await jobs.lastCompletedStage(fresh.repo, fresh.run_id),
      paused_before: fresh.paused_before ?? null,
      artifacts: await availableArtifacts(fresh.repo, fresh.run_id),
      log_tail: await jobs.tail(fresh, tailLines),
      next_action: nextAction(fresh),
    };
  }

  const tools = [
    {
      name: 'e3d_pilot_config_check',
      description: 'FREE (no model calls). Validate a repository\'s .e3d-pilot/config.json and report whether the tools it needs (such as the e3d-code executor) are installed. Run this before starting pipeline jobs.',
      inputSchema: { type: 'object', properties: { repo: { type: 'string', description: 'Absolute path to the git repository.' } }, required: ['repo'], additionalProperties: false },
      annotations: { title: 'Check e3d-pilot config', readOnlyHint: true, openWorldHint: false },
    },
    {
      name: 'e3d_pilot_job_status',
      description: 'FREE. Status of a pipeline job: state (running, waiting_for_human, succeeded, failed, blocked), how far the run got, artifacts available, and the last log lines. Jobs survive server restarts. With no job_id or run_id it reports the repo\'s latest job. Pass wait_seconds (max 60) to wait for a running job to finish.',
      inputSchema: {
        type: 'object',
        properties: {
          repo: { type: 'string', description: 'Absolute path to the git repository.' },
          job_id: { type: 'string', description: 'A job id from a start tool.' },
          run_id: { type: 'string', description: 'Find the latest job for this run instead.' },
          tail_lines: { type: 'integer', minimum: 1, maximum: 200, description: 'Log lines to return. Default 40.' },
          wait_seconds: { type: 'integer', minimum: 0, maximum: 60, description: 'Wait up to this long for a running job to settle. Default 0.' },
        },
        required: ['repo'], additionalProperties: false,
      },
      annotations: { title: 'Pipeline job status', readOnlyHint: true, openWorldHint: false },
    },
    {
      name: 'e3d_pilot_artifact',
      description: `FREE. Read one artifact of a pipeline run, size-capped. name is one of: ${Object.keys(ARTIFACTS).join(', ')}, manifest (per-phase provider/model/exit status from e3d-code), phase-summary (needs phase), or list. The tool never reads other files.`,
      inputSchema: {
        type: 'object',
        properties: {
          repo: { type: 'string', description: 'Absolute path to the git repository.' },
          run_id: { type: 'string', description: 'The run id (from job status).' },
          name: { type: 'string', description: 'Artifact name, or "list".' },
          phase: { type: 'integer', minimum: 1, description: 'Phase number for phase-summary.' },
          max_bytes: { type: 'integer', minimum: 1000, description: `Cap on returned bytes (default 20000, maximum ${maxArtifactBytes}).` },
        },
        required: ['repo', 'run_id', 'name'], additionalProperties: false,
      },
      annotations: { title: 'Read run artifact', readOnlyHint: true, openWorldHint: false },
    },
  ];

  const handlers = {
    e3d_pilot_config_check: withRepo(async (repo) => {
      const r = await pilot(['config', 'validate', repo], { timeoutMs: 30000 });
      let cfg = null;
      try { cfg = JSON.parse(await readFile(join(repo, '.e3d-pilot', 'config.json'), 'utf8')); } catch { /* reported by validate */ }
      const backend = cfg?.providers?.execute ?? 'e3d-code';
      const needsE3dCode = backend === 'e3d-code' || backend === 's2c';
      const path = needsE3dCode ? await findE3dCode() : null;
      const result = {
        repo, valid: r.code === 0, message: redact((r.out + r.err).trim()),
        execute_backend: backend, e3d_code: { needed: needsE3dCode, found: Boolean(path), path },
        ready_to_execute: r.code === 0 && (!needsE3dCode || Boolean(path)),
      };
      return ok(result, `${result.valid ? 'Config valid.' : 'Config INVALID.'} ${result.message}\nExecute backend: ${backend}${needsE3dCode ? ` (e3d-code ${path ? `found at ${path}` : 'NOT FOUND: npm install -g e3d-code'})` : ''}`);
    }),

    e3d_pilot_job_status: withRepo(async (repo, args, progress) => {
      let job;
      if (args.job_id) job = await jobs.load(repo, args.job_id);
      else if (args.run_id) job = await jobs.findByRun(repo, args.run_id);
      else job = await jobs.latest(repo);
      if (!job) return fail('no matching job found for this repo');
      if (args.wait_seconds > 0 && job.state === 'running') job = await jobs.wait(repo, job.job_id, Math.min(args.wait_seconds, 60), progress) ?? job;
      const view = await statusView(job, args.tail_lines ?? 40);
      const readable = [`Job ${view.job_id}: ${view.state.toUpperCase()}${view.reason ? ` (${view.reason})` : ''}`,
        `run ${view.run_id ?? '(not yet allocated)'}; last completed stage: ${view.last_completed_stage ?? 'none'}; elapsed ${view.elapsed_sec}s`,
        view.next_action ? `Next: ${view.next_action}` : null, '', ...view.log_tail.slice(-15)].filter((l) => l !== null).join('\n');
      return ok(view, readable);
    }),

    e3d_pilot_artifact: withRepo(async (repo, args) => {
      if (!RUN_ID_RE.test(args.run_id)) return fail('invalid run_id');
      const runDir = jobs.runDirFor(repo, args.run_id);
      if (!existsSync(runDir)) return fail(`run not found: ${args.run_id}`);
      if (args.name === 'list') { const names = await availableArtifacts(repo, args.run_id); return ok({ run_id: args.run_id, artifacts: names }, `Available: ${names.join(', ') || 'none'}`); }

      let file;
      if (args.name === 'manifest') {
        const rows = await readManifest(repo, args.run_id);
        if (!rows) return fail('this run has no e3d-code manifest (execute has not run, or its state was not copied)');
        const body = rows.map((r) => `phase ${r.phase} ${r.title}: ${r.provider}/${r.model} exit=${r.exit_status}${r.dry_run === '1' ? ' (dry run)' : ''}`).join('\n');
        return ok({ run_id: args.run_id, phases: rows }, body);
      }
      if (args.name === 'phase-summary') {
        if (!Number.isInteger(args.phase)) return fail('phase-summary needs a phase number');
        const dir = await stateDir(repo, args.run_id);
        file = dir ? join(dir, 'summaries', `phase-${args.phase}.md`) : null;
      } else if (ARTIFACTS[args.name]) {
        file = join(runDir, ARTIFACTS[args.name]);
      } else {
        return fail(`unknown artifact "${args.name}"; use name "list" to see what exists`);
      }
      if (!file || !existsSync(file)) return fail(`artifact not available for this run: ${args.name}`);
      const cap = Math.min(args.max_bytes ?? 20000, maxArtifactBytes);
      const buf = await readFile(file);
      const truncated = buf.length > cap;
      const content = redact(buf.subarray(0, cap).toString('utf8'));
      return ok({ run_id: args.run_id, name: args.name, bytes_total: buf.length, truncated, content }, truncated ? `${content}\n\n[truncated: ${cap} of ${buf.length} bytes]` : content);
    }),
  };

  return { tools, handlers, statusView, nextAction, availableArtifacts, readManifest, pilot, fail, ok, withRepo };
}
