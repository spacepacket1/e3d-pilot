// The acting half of the pipeline-over-MCP tools: propose ideas, start jobs, the human gates, plan/execute.
//
// Trust model (also in the README):
//  * Gate 1 (idea approval) is a human decision. `e3d_pilot_approve` is read-only unless the server
//    operator sets E3D_MCP_ALLOW_APPROVAL=1 AND the client supports MCP elicitation, in which case the
//    human confirms in the editor's own UI. An agent cannot answer an elicitation prompt itself.
//  * Every stage still enforces approval inside the CLI (digest-bound), so these tools cannot bypass it.
//  * Merge (approve-merge / merge) is deliberately not exposed. It stays CLI-only.
//  * Code is only written by `e3d_pilot_execute`, which requires a fresh plan from `e3d_pilot_code_plan`
//    for exactly the spec that will run.
import { readFile, writeFile, mkdir, readdir, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { run, findE3dCode } from './util.js';
import { redact } from './redact.js';

const IDEA_ID_RE = /^idea-[A-Za-z0-9]+$/;
const envInt = (env, name, dflt) => { const n = Number.parseInt(env[name] ?? '', 10); return Number.isFinite(n) && n > 0 ? n : dflt; };
const sha = (s) => createHash('sha256').update(s).digest('hex');
const clip = (s, n) => (s.length > n ? `${s.slice(0, n - 1)}...` : s);

export function createPipelineActions({ guard, jobs, base, env = process.env }) {
  const { pilot, fail, ok, withRepo } = base;
  const limits = {
    maxPhases: envInt(env, 'E3D_MCP_MAX_PHASES', 8),
    planTtlMs: envInt(env, 'E3D_MCP_PLAN_TTL_SEC', 1800) * 1000,
  };
  const actorFor = (ctx) => env.E3D_MCP_ACTOR || `mcp:${ctx?.session?.clientInfo?.name ?? 'client'}`;
  const planFile = (repo, runId) => join(repo, '.e3d-pilot', 'mcp-jobs', `plan-${runId}.json`);

  async function ideaView(repo, ideaId) {
    if (!IDEA_ID_RE.test(ideaId ?? '')) throw new Error('idea_id must look like idea-<id>');
    const r = await pilot(['ideas', 'show', '--repo', repo, ideaId, '--json'], { timeoutMs: 30000 });
    if (r.code !== 0) throw new Error(`idea not found: ${ideaId}`);
    return JSON.parse(r.out);
  }

  // The run that `ideas implement --stop-before` paused for this idea: { run_id, stage } or null.
  async function pausedRun(repo, ideaId, wantRunId) {
    const dir = join(repo, '.e3d-pilot', 'runs');
    let names = [];
    try { names = await readdir(dir); } catch { return null; }
    let best = null;
    for (const name of names.sort()) {
      if (wantRunId && name !== wantRunId) continue;
      try {
        const marker = (await readFile(join(dir, name, 'paused-before.txt'), 'utf8')).split('\t');
        const link = (await readFile(join(dir, name, 'idea-link.txt'), 'utf8')).trim().split('\t');
        if (link[0] === 'repo' && link[2] === ideaId) best = { run_id: name, stage: marker[0].trim() };
      } catch { /* not a paused run for this idea */ }
    }
    return best;
  }

  // Asks the human through the client's own UI. 'unsupported' means we could not ask, so callers stay read-only.
  async function askHuman(ctx, message, field) {
    if (!ctx?.session?.capabilities?.elicitation) return 'unsupported';
    try {
      const r = await ctx.rpc.request('elicitation/create', {
        message,
        requestedSchema: { type: 'object', properties: { confirm: { type: 'boolean', title: field, description: 'Tick to confirm; decline or cancel to stop.' } }, required: ['confirm'] },
      }, 10 * 60 * 1000);
      return r?.action === 'accept' && r?.content?.confirm === true ? 'accepted' : 'declined';
    } catch (e) {
      return /method not found|-32601/i.test(`${e.code} ${e.message}`) ? 'unsupported' : 'declined';
    }
  }

  const jobView = (job) => ({ job_id: job.job_id, run_id: job.run_id, state: job.state, label: job.label, repo: job.repo, check_with: 'e3d_pilot_job_status' });

  const tools = [
    {
      name: 'e3d_pilot_propose',
      description: 'FREE (writes only to the repo\'s idea ledger; no model calls). Record a new idea for the pipeline from a decision, optionally attaching the e3d_debate result that led to it as provenance evidence. The idea starts as "proposed" and needs human approval before any code can be drafted or written.',
      inputSchema: {
        type: 'object',
        properties: {
          repo: { type: 'string', description: 'Absolute path to the git repository (must have .e3d-pilot/config.json).' },
          title: { type: 'string', maxLength: 200 },
          rationale: { type: 'string', maxLength: 4000, description: 'What to build and why; this becomes the idea summary.' },
          category: { type: 'string', maxLength: 60 },
          source: {
            type: 'object', description: 'Optional: the e3d_debate result behind this idea. Pass its fields through.',
            properties: {
              question: { type: 'string' }, final_answer: { type: 'string' }, consensus: { type: 'string' },
              dissent: { type: 'object', properties: { present: { type: ['boolean', 'null'] }, summary: { type: 'string' } } },
              providers: { type: 'array', items: { type: 'string' } },
              positions: { type: 'array', items: { type: 'object', properties: { provider: { type: 'string' }, text: { type: 'string' } } } },
            },
          },
        },
        required: ['repo', 'title', 'rationale'], additionalProperties: false,
      },
      annotations: { title: 'Propose an idea', readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    {
      name: 'e3d_pilot_start',
      description: 'SPENDS MODEL CREDITS. Start the discover or ideate stage as a background job and return immediately with a job_id (poll e3d_pilot_job_status). discover surveys the repo and writes findings; ideate turns them into ranked candidate ideas, which are recorded as "proposed" and then wait for human approval. Only these two stages are exposed here: everything after approval goes through e3d_pilot_implement.',
      inputSchema: {
        type: 'object',
        properties: {
          repo: { type: 'string', description: 'Absolute path to the git repository.' },
          stage: { type: 'string', enum: ['discover', 'ideate'] },
          run_id: { type: 'string', description: 'Optional existing run id (ideate normally resumes the latest run).' },
          focus: { type: 'string', enum: ['default', 'revenue'] },
        },
        required: ['repo', 'stage'], additionalProperties: false,
      },
      annotations: { title: 'Start discover/ideate', readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
    },
    {
      name: 'e3d_pilot_approve',
      description: 'HUMAN GATE 1. Approving an idea authorizes drafting, negotiation, code execution in an isolated worktree, review, and opening a draft PR (all spend model credits). By default this tool does NOT approve: it returns waiting_for_human with the exact CLI command for the person to run. Only if the server operator enabled approval and the client can ask the human directly does it prompt the person in the editor; an agent cannot answer that prompt.',
      inputSchema: {
        type: 'object',
        properties: { repo: { type: 'string' }, idea_id: { type: 'string' }, note: { type: 'string', maxLength: 500 } },
        required: ['repo', 'idea_id'], additionalProperties: false,
      },
      annotations: { title: 'Approve an idea (human gate)', readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    {
      name: 'e3d_pilot_reject',
      description: 'HUMAN GATE 1. Reject a proposed idea so it is never implemented. Requires a reason. Confirmed by the person in the editor when the client supports it; otherwise pass confirm_phrase "reject <idea_id>". This only stops work, so unlike approval it can be done without a prompt.',
      inputSchema: {
        type: 'object',
        properties: { repo: { type: 'string' }, idea_id: { type: 'string' }, reason: { type: 'string', maxLength: 500 }, confirm_phrase: { type: 'string' } },
        required: ['repo', 'idea_id', 'reason'], additionalProperties: false,
      },
      annotations: { title: 'Reject an idea', readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
    },
    {
      name: 'e3d_pilot_request_changes',
      description: 'HUMAN REVIEW GATE (after a draft PR exists). Send an implemented idea back for rework, with a reason; it can then be re-run with e3d_pilot_implement. Only valid for an idea whose status is implemented or approved_for_merge. Confirmed by the person in the editor when the client supports it; otherwise pass confirm_phrase "request changes <idea_id>".',
      inputSchema: {
        type: 'object',
        properties: { repo: { type: 'string' }, idea_id: { type: 'string' }, reason: { type: 'string', maxLength: 500 }, confirm_phrase: { type: 'string' } },
        required: ['repo', 'idea_id', 'reason'], additionalProperties: false,
      },
      annotations: { title: 'Request changes to an implementation', readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
    {
      name: 'e3d_pilot_implement',
      description: 'SPENDS MODEL CREDITS (drafting and negotiation only; NO code is written). For an idea a human has approved, start a background job that drafts the phased spec and has the reviewers negotiate it, then PAUSES before the execute stage. Next: e3d_pilot_code_plan to see the phases and models, then e3d_pilot_execute or e3d_pilot_cancel_paused.',
      inputSchema: { type: 'object', properties: { repo: { type: 'string' }, idea_id: { type: 'string' } }, required: ['repo', 'idea_id'], additionalProperties: false },
      annotations: { title: 'Draft and negotiate (pauses before execute)', readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
    },
    {
      name: 'e3d_pilot_code_plan',
      description: 'FREE (no model calls, writes nothing). For an implementation paused before execute, show exactly what execute would do: each phase with the runner and model e3d-code will use, the files each phase says it touches, verify commands, and the e3d-code preflight result. Returns a plan_token that e3d_pilot_execute requires. Run this and show the plan to the user before executing.',
      inputSchema: {
        type: 'object',
        properties: { repo: { type: 'string' }, idea_id: { type: 'string' }, run_id: { type: 'string', description: 'Optional: a specific paused run.' } },
        required: ['repo', 'idea_id'], additionalProperties: false,
      },
      annotations: { title: 'Preview the code-writing plan', readOnlyHint: true, openWorldHint: false },
    },
    {
      name: 'e3d_pilot_execute',
      description: 'SPENDS MODEL CREDITS AND WRITES CODE (inside an isolated git worktree on its own branch; never on your working tree). Continue a paused implementation: e3d-code writes the code phase by phase, then verification, independent review, and a draft PR. Refuses without a plan_token from a recent e3d_pilot_code_plan of the same spec. Protected paths, diff ceilings and verification still apply. Merging is never done here.',
      inputSchema: {
        type: 'object',
        properties: { repo: { type: 'string' }, idea_id: { type: 'string' }, plan_token: { type: 'string', description: 'From e3d_pilot_code_plan.' } },
        required: ['repo', 'idea_id', 'plan_token'], additionalProperties: false,
      },
      annotations: { title: 'Execute the plan (writes code)', readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
    },
    {
      name: 'e3d_pilot_cancel_paused',
      description: 'FREE. Abandon an implementation that is paused before execute (for example after reading the plan). Records it as a failed attempt with your reason, so the idea can be retried with e3d_pilot_implement. Writes no code.',
      inputSchema: { type: 'object', properties: { repo: { type: 'string' }, idea_id: { type: 'string' }, reason: { type: 'string', maxLength: 500 } }, required: ['repo', 'idea_id', 'reason'], additionalProperties: false },
      annotations: { title: 'Cancel a paused implementation', readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
    },
  ];

  const handlers = {
    e3d_pilot_propose: withRepo(async (repo, args, _p, ctx) => {
      if (!existsSync(join(repo, '.e3d-pilot', 'config.json'))) return fail('this repo has no .e3d-pilot/config.json; see e3d_pilot_config_check');
      if (!args.title?.trim() || !args.rationale?.trim()) return fail('title and rationale are required');
      const stamp = new Date().toISOString().replace(/\D/g, '').slice(0, 14);
      const runId = `mcp-propose-${stamp}`;
      const dir = await (async () => { const d = join(tmpdir(), `e3d-mcp-propose-${stamp}-${Math.random().toString(16).slice(2, 8)}`); await mkdir(d, { recursive: true }); return d; })();
      try {
        const candidate = join(dir, 'candidate.json');
        await writeFile(candidate, JSON.stringify({
          focus: 'default', title: args.title.trim(), summary: args.rationale.trim(), repos: [],
          category: args.category ?? 'mcp-proposed', scores: { attraction: 0, retention: 0, revenue: 0, effort: 'unknown' },
          dedup_rationale: 'proposed through the e3d-pilot MCP server', validation: { approvable: true, eligibility_reason: null, warnings: [] },
        }));
        const r = await pilot(['ideas', 'ingest', '--repo', repo, '--run-id', runId, '--candidate-id', 'candidate-1', '--candidate-json', candidate], { timeoutMs: 120000 });
        if (r.code !== 0) return fail(`could not record the idea: ${redact((r.err || r.out).trim().slice(-600))}`);
        const ideaId = r.out.trim().split('\n').filter(Boolean).pop();
        if (!IDEA_ID_RE.test(ideaId)) return fail(`unexpected ingest output: ${redact(r.out.slice(-300))}`);

        let evidence = null;
        if (args.source) {
          const s = args.source;
          const md = ['# Debate behind this idea', '', `**Question:** ${s.question ?? '(not provided)'}`, '',
            `**Consensus:** ${s.consensus ?? 'unknown'}${s.providers?.length ? ` (${s.providers.join(', ')})` : ''}`, '',
            `**Final answer:** ${s.final_answer ?? '(not provided)'}`, '',
            `**Dissent:** ${s.dissent?.present === false ? 'none' : (s.dissent?.summary ?? 'unknown')}`, '',
            ...(s.positions?.length ? ['## Positions', '', ...s.positions.flatMap((p) => [`**${p.provider}:**`, '', p.text, ''])] : []),
            `_Recorded through the e3d-pilot MCP server by ${actorFor(ctx)}._`, ''].join('\n');
          const rel = join('.e3d-pilot', 'debates', `${ideaId}.md`);
          await mkdir(join(repo, '.e3d-pilot', 'debates'), { recursive: true });
          await writeFile(join(repo, rel), redact(md));
          const verdict = `e3d_debate verdict (${s.consensus ?? 'unknown'}): ${clip(redact(s.final_answer ?? ''), 600)}${s.dissent?.present ? ` | dissent: ${clip(redact(s.dissent.summary ?? ''), 300)}` : ''}`;
          const n = await pilot(['ideas', 'note', '--repo', repo, '--decision', '--evidence', rel, ideaId, verdict, '--actor', actorFor(ctx)], { timeoutMs: 60000 });
          if (n.code === 0) evidence = rel;
        }
        return ok({ idea_id: ideaId, run_id: runId, status: 'proposed', evidence_ref: evidence,
          next_action: `A human must approve it before anything is drafted or written: e3d-pilot ideas approve --repo ${repo} ${ideaId}` },
        `Recorded ${ideaId} as proposed${evidence ? ` with the debate attached as evidence (${evidence}; commit that file to keep the link durable)` : ''}.\nNext: a human approves it (e3d_pilot_approve shows how), then e3d_pilot_implement.`);
      } finally { rm(dir, { recursive: true, force: true }).catch(() => {}); }
    }),

    e3d_pilot_start: withRepo(async (repo, args, _p, ctx) => {
      if (!['discover', 'ideate'].includes(args.stage)) return fail('stage must be discover or ideate (use e3d_pilot_implement after approval)');
      if (args.focus && !['default', 'revenue'].includes(args.focus)) return fail('focus must be default or revenue');
      if (args.run_id && !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(args.run_id)) return fail('invalid run_id');
      const cli = ['run', '--repo', repo, '--stage', args.stage, ...(args.run_id ? ['--run-id', args.run_id] : []), ...(args.focus ? ['--focus', args.focus] : [])];
      let job = await jobs.start(repo, { kind: 'stage', args: cli, run_id: args.run_id ?? null, label: `run --stage ${args.stage}`, extraEnv: await ctx?.samplingEnv?.(`job-${Date.now()}`) });
      // discover allocates its run id a moment after starting; give it a short window so the caller gets one.
      for (let i = 0; i < 10 && !job.run_id && job.state === 'running'; i++) { await new Promise((r) => setTimeout(r, 300)); job = await jobs.refresh(job); }
      return ok(jobView(job), `Started ${job.label} as ${job.job_id}${job.run_id ? ` (run ${job.run_id})` : ''}. Poll e3d_pilot_job_status; it may take minutes.`);
    }),

    e3d_pilot_approve: withRepo(async (repo, args, _p, ctx) => {
      const idea = await ideaView(repo, args.idea_id);
      const cmd = `e3d-pilot ideas approve --repo ${repo} ${args.idea_id} --actor <your-email>${args.note ? ` --note ${JSON.stringify(args.note)}` : ''}`;
      const waiting = (why) => ok({ idea_id: args.idea_id, outcome: 'waiting_for_human', status: idea.status, why, cli_command: cmd,
        web_ui: 'or approve it in the web dashboard: e3d-pilot web' },
      `NOT approved: waiting for a human (${why}).\nThe person can approve with:\n  ${cmd}\nIdea: ${idea.title}\nStatus: ${idea.status}`);
      if (idea.status !== 'proposed') return fail(`idea is ${idea.status}; only proposed ideas can be approved`);
      if (env.E3D_MCP_ALLOW_APPROVAL !== '1') return waiting('approval over MCP is disabled on this server (set E3D_MCP_ALLOW_APPROVAL=1 to let a person approve from the editor)');
      const answer = await askHuman(ctx,
        `Approve this idea?\n\n${idea.title}\n\n${clip(idea.summary ?? '', 600)}\n\nApproving authorizes drafting a spec, negotiating it, writing code in an isolated worktree, review, and opening a draft PR. These spend model credits. It does NOT authorize merging.`,
        'Approve implementation');
      if (answer === 'unsupported') return waiting('this editor cannot prompt you from the server');
      if (answer !== 'accepted') return ok({ idea_id: args.idea_id, outcome: 'declined', status: idea.status }, 'The person declined; the idea was not approved.');
      const r = await pilot(['ideas', 'approve', '--repo', repo, args.idea_id, '--actor', actorFor(ctx), '--note', args.note ?? 'approved from the editor via MCP elicitation'], { timeoutMs: 60000 });
      if (r.code !== 0) return fail(`approve failed: ${redact((r.err || r.out).trim().slice(-500))}`);
      return ok({ idea_id: args.idea_id, outcome: 'approved', actor: actorFor(ctx), next: 'e3d_pilot_implement' }, `Approved ${args.idea_id} (confirmed by the person in the editor). Next: e3d_pilot_implement.`);
    }),

    ...Object.fromEntries([['e3d_pilot_reject', 'reject', 'reject'], ['e3d_pilot_request_changes', 'request-changes', 'request changes']].map(([tool, verb, phrase]) => [tool,
      withRepo(async (repo, args, _p, ctx) => {
        const idea = await ideaView(repo, args.idea_id);
        const allowed = verb === 'reject' ? ['proposed'] : ['implemented', 'approved_for_merge'];
        if (!allowed.includes(idea.status)) return fail(`idea is ${idea.status}; ${phrase} only applies to ${allowed.join(' or ')} ideas`);
        const confirmed = args.confirm_phrase === `${phrase} ${args.idea_id}`;
        let ok2 = false;
        const answer = await askHuman(ctx, `${phrase[0].toUpperCase()}${phrase.slice(1)} this idea?\n\n${idea.title}\n\nReason: ${args.reason}`, `${phrase} this idea`);
        if (answer === 'accepted') ok2 = true;
        else if (answer === 'unsupported' && confirmed) ok2 = true;
        if (!ok2) {
          const cmd = `e3d-pilot ideas ${verb} --repo ${repo} ${args.idea_id} --reason ${JSON.stringify(args.reason)}`;
          return ok({ idea_id: args.idea_id, outcome: answer === 'declined' ? 'declined' : 'waiting_for_human', status: idea.status, cli_command: cmd },
            answer === 'declined' ? 'The person declined; nothing changed.' : `Not done: confirm by passing confirm_phrase "${phrase} ${args.idea_id}", or run:\n  ${cmd}`);
        }
        const r = await pilot(['ideas', verb, '--repo', repo, args.idea_id, '--reason', args.reason, '--actor', actorFor(ctx)], { timeoutMs: 60000 });
        if (r.code !== 0) return fail(`${verb} failed: ${redact((r.err || r.out).trim().slice(-500))}`);
        return ok({ idea_id: args.idea_id, outcome: verb === 'reject' ? 'rejected' : 'changes_requested' }, `Done: ${args.idea_id} ${verb === 'reject' ? 'rejected' : 'sent back for changes'}.`);
      })])),

    e3d_pilot_implement: withRepo(async (repo, args, _p, ctx) => {
      const idea = await ideaView(repo, args.idea_id);
      if (!['approved_for_implementation', 'changes_requested', 'implementation_failed'].includes(idea.status)) {
        return fail(idea.status === 'proposed'
          ? `idea ${args.idea_id} is not approved yet. A human must approve it: e3d-pilot ideas approve --repo ${repo} ${args.idea_id}`
          : `idea ${args.idea_id} cannot start implementation from status "${idea.status}"`);
      }
      const job = await jobs.start(repo, { kind: 'implement', args: ['ideas', 'implement', '--repo', repo, '--stop-before', 'execute', args.idea_id], idea_id: args.idea_id, label: `ideas implement --stop-before execute`, extraEnv: await ctx?.samplingEnv?.(`job-${Date.now()}`) });
      return ok(jobView(job), `Started drafting and negotiating ${args.idea_id} as ${job.job_id}. It pauses before any code is written; poll e3d_pilot_job_status, then call e3d_pilot_code_plan.`);
    }),

    e3d_pilot_code_plan: withRepo(async (repo, args) => {
      const paused = await pausedRun(repo, args.idea_id, args.run_id);
      if (!paused) return fail(`idea ${args.idea_id} has no implementation paused before execute (start one with e3d_pilot_implement and wait for it to pause)`);
      const runDir = jobs.runDirFor(repo, paused.run_id);
      const specFile = join(runDir, 'spec-final.md');
      if (!existsSync(specFile)) return fail('the paused run has no spec-final.md');
      const bin = await findE3dCode();
      if (!bin) return fail('e3d-code is not installed, so the plan cannot be shown: npm install -g e3d-code');
      const spec = await readFile(specFile, 'utf8');
      const opts = { cwd: repo, env: { ...env, ROOT_DIR: repo }, timeoutMs: 60000 };
      // --list and --preflight are side-effect free. --dry-run is NOT used: it writes a manifest row marking the phase completed.
      const list = await run(bin, [specFile, '--list'], opts);
      if (list.code !== 0) return fail(`e3d-code could not read the spec: ${redact((list.err || list.out).trim().slice(-500))}`);
      const pre = await run(bin, [specFile, '--preflight'], opts);

      const blocks = spec.split(/^(?=## Phase \d+ )/m).filter((b) => /^## Phase \d+ /.test(b));
      const details = Object.fromEntries(blocks.map((b) => [Number(b.match(/^## Phase (\d+)/)[1]), {
        touches: [...b.matchAll(/<!--\s*pilot:touches=(.+?)\s*-->/g)].map((m) => m[1]),
        verify: [...b.matchAll(/<!--\s*runner:verify=(.+?)\s*-->/g)].map((m) => m[1]),
      }]));
      const phases = list.out.split('\n').filter(Boolean).map((l) => {
        const [label, provider, model, ...title] = l.split('\t');
        const n = Number((label.match(/\d+/) ?? [0])[0]);
        return { phase: n, provider, model, title: title.join('\t'), touches: details[n]?.touches ?? [], verify: details[n]?.verify ?? [] };
      });
      let cfg = {};
      try { cfg = JSON.parse(await readFile(join(repo, '.e3d-pilot', 'config.json'), 'utf8')); } catch { /* validated elsewhere */ }
      const head = (await run('git', ['-C', repo, 'rev-parse', 'HEAD'], { timeoutMs: 10000 })).out.trim();
      const token = sha(`${sha(spec)}|${JSON.stringify(phases.map((p) => [p.phase, p.provider, p.model]))}|${head}`).slice(0, 24);
      await writeFile(planFile(repo, paused.run_id), JSON.stringify({ token, run_id: paused.run_id, idea_id: args.idea_id, spec_sha: sha(spec), head, created_at: Date.now(), phases: phases.length }, null, 2));
      const warnings = [];
      if (phases.length > limits.maxPhases) warnings.push(`${phases.length} phases exceeds the cap of ${limits.maxPhases} (E3D_MCP_MAX_PHASES); execute will refuse`);
      if (!phases.length) warnings.push('no phases were found in the spec');
      const reviewers = [].concat(cfg?.providers?.review ?? []);
      const result = {
        idea_id: args.idea_id, run_id: paused.run_id, paused_before: paused.stage, plan_token: token, phases, warnings,
        preflight: { ok: pre.code === 0, output: redact(pre.out.trim().split('\n').slice(-6).join('\n')) },
        protected_paths: cfg.protected_paths ?? [], max_diff_files: cfg.max_diff_files ?? null, max_diff_lines: cfg.max_diff_lines ?? null,
        credit_impact: `execute starts ${phases.length} e3d-code phase session(s) with the models above, then verification, then review by ${reviewers.length || 'the configured'} provider(s), then opens a draft PR. Nothing is merged.`,
        expires_in_sec: limits.planTtlMs / 1000,
      };
      const lines = [`Plan for ${args.idea_id} (run ${paused.run_id}), paused before ${paused.stage}:`, '',
        ...phases.map((p) => `  Phase ${p.phase}: ${p.title}\n     runs on ${p.provider}/${p.model}; touches ${p.touches.join(', ') || '(unspecified)'}${p.verify.length ? `; verifies with ${p.verify.join(' && ')}` : ''}`),
        '', result.credit_impact, `Preflight: ${result.preflight.ok ? 'ok' : 'PROBLEMS'}`, ...warnings.map((w) => `WARNING: ${w}`), '',
        `Show this to the user. To proceed: e3d_pilot_execute with plan_token ${token} (valid ${limits.planTtlMs / 60000} minutes). To stop: e3d_pilot_cancel_paused.`];
      return ok(result, lines.join('\n'));
    }),

    e3d_pilot_execute: withRepo(async (repo, args, _p, ctx) => {
      const paused = await pausedRun(repo, args.idea_id);
      if (!paused) return fail(`idea ${args.idea_id} has no implementation paused before execute`);
      let plan;
      try { plan = JSON.parse(await readFile(planFile(repo, paused.run_id), 'utf8')); } catch { return fail('no plan on record for this run: call e3d_pilot_code_plan first and show the plan to the user'); }
      if (plan.token !== args.plan_token) return fail('plan_token does not match the latest plan for this run; call e3d_pilot_code_plan again');
      if (Date.now() - plan.created_at > limits.planTtlMs) return fail('the plan has expired; call e3d_pilot_code_plan again and re-confirm with the user');
      const spec = await readFile(join(jobs.runDirFor(repo, paused.run_id), 'spec-final.md'), 'utf8');
      if (sha(spec) !== plan.spec_sha) return fail('the spec changed after the plan was made; call e3d_pilot_code_plan again');
      const head = (await run('git', ['-C', repo, 'rev-parse', 'HEAD'], { timeoutMs: 10000 })).out.trim();
      if (head !== plan.head) return fail('the repository HEAD moved after the plan was made; call e3d_pilot_code_plan again');
      if (plan.phases > limits.maxPhases) return fail(`the plan has ${plan.phases} phases, over the cap of ${limits.maxPhases} (E3D_MCP_MAX_PHASES)`);
      const job = await jobs.start(repo, { kind: 'resume', args: ['ideas', 'resume', '--repo', repo, args.idea_id], run_id: paused.run_id, idea_id: args.idea_id, label: 'ideas resume (execute, review, publish)', extraEnv: await ctx?.samplingEnv?.(`job-${Date.now()}`) });
      await rm(planFile(repo, paused.run_id), { force: true });
      return ok(jobView(job), `Executing ${plan.phases} phase(s) as ${job.job_id}. This can take a long time; poll e3d_pilot_job_status. It ends with a draft PR for a human to review; merging stays manual.`);
    }),

    e3d_pilot_cancel_paused: withRepo(async (repo, args) => {
      if (!args.reason?.trim()) return fail('reason is required');
      const paused = await pausedRun(repo, args.idea_id);
      if (!paused) return fail(`idea ${args.idea_id} has no implementation paused before execute`);
      const r = await pilot(['ideas', 'cancel-paused', '--repo', repo, '--reason', args.reason, args.idea_id], { timeoutMs: 60000 });
      if (r.code !== 0) return fail(`cancel failed: ${redact((r.err || r.out).trim().slice(-500))}`);
      await rm(planFile(repo, paused.run_id), { force: true });
      return ok({ idea_id: args.idea_id, run_id: paused.run_id, outcome: 'cancelled' }, `Cancelled the paused implementation of ${args.idea_id}. It can be retried with e3d_pilot_implement.`);
    }),
  };

  return { tools, handlers, limits };
}
