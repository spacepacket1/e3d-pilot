# Debate

**Prompt version:** v2

**Question:** You are reviewing a code change to the e3d-pilot MCP server (Node.js, zero dependencies). It fixes findings from a QA report. Find real bugs, not style. For each finding give file, the problem, a concrete failing scenario, and a fix. Prioritize: (1) correctness of the new budget reservation (reserve before a job starts, release if it cannot start; any path where credits are spent without being counted, counted twice, or where a refused request still records usage; race conditions); (2) the usage change so a stopped debate is not charged for a synthesis call; (3) anything in the job-status changes (warnings, failure_detail, log_is_stale) that could leak secrets (redact) or break existing behavior; (4) the actor attribution change in lib/ideas/ledger.sh (shell/jq correctness); (5) new MCP prompts/get argument handling (injection or size issues); (6) anything that weakens an existing safety property (approval stays human, merge never exposed, repo allowlist). End with a recommendation: ship, or fix first, and list the must-fix items.

THE DIFF:
diff --git a/bin/e3d-mcp b/bin/e3d-mcp
index 48a7092..4f07105 100755
--- a/bin/e3d-mcp
+++ b/bin/e3d-mcp
@@ -15,6 +15,7 @@
 // E3D_MCP_MAX_CONCURRENT, E3D_MCP_TIMEOUT_SEC). Nothing here writes to a repo.
 
 import { mkdtemp, writeFile, readFile, rm, stat } from 'node:fs/promises';
+import { readFileSync } from 'node:fs';
 import { tmpdir } from 'node:os';
 import { join, resolve } from 'node:path';
 import { fileURLToPath } from 'node:url';
@@ -28,12 +29,15 @@ import { createJobs } from '../lib/mcp/jobs.js';
 import { createPipelineTools } from '../lib/mcp/pipeline-tools.js';
 import { createPipelineActions } from '../lib/mcp/pipeline-actions.js';
 import { createSampling } from '../lib/mcp/sampling.js';
+import { listPrompts, getPrompt } from '../lib/mcp/prompts.js';
 import { chooseVoices, independence, isSampling } from '../lib/mcp/voices.js';
 import { startHttpServer } from '../lib/mcp/http.js';
 import { createUsage, usageFromTranscript, worstCase, usageTool, usageHandler } from '../lib/mcp/usage.js';
 
 const HTTP_MODE = process.argv.includes('--http');
-const SERVER_INFO = { name: 'e3d-pilot', version: '0.2.0' };
+// The version comes from package.json, so a development build (0.2.0-dev.N) reports itself correctly.
+const PKG_VERSION = (() => { try { return JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8')).version; } catch { return '0.0.0-unknown'; } })();
+const SERVER_INFO = { name: 'e3d-pilot', version: PKG_VERSION };
 const SUPPORTED_PROTOCOLS = ['2025-06-18', '2025-03-26', '2024-11-05'];
 
 const envInt = (name, dflt) => {
@@ -48,6 +52,9 @@ const LIMITS = {
   timeoutMs: envInt('E3D_MCP_TIMEOUT_SEC', HTTP_MODE ? 120 : 900) * 1000,
   maxWords: 600,
   questionChars: 20000,
+  // Editors give up on a tool call after about 3 minutes. When the client's own models answer (MCP sampling), stop first,
+  // so the debate is cancelled and reported instead of running on unseen and charging calls nobody sees.
+  samplingTimeoutMs: envInt('E3D_MCP_SAMPLING_TIMEOUT_SEC', 150) * 1000,
 };
 let activeDebates = 0;
 
@@ -84,7 +91,10 @@ function parsePositions(transcript) {
 
 function renderDebate(d) {
   const label = d.consensus === 'full' ? 'FULL CONSENSUS' : d.consensus === 'majority' ? 'MAJORITY (some dissent)' : d.consensus === 'split' ? 'SPLIT' : 'CONSENSUS UNKNOWN';
+  const warn = (d.warnings ?? []);
   const lines = [
+    `REPORT THIS TO THE USER (do not drop any of it when summarizing): consensus is ${label}; dissent: ${d.dissent.present === false ? 'none' : d.dissent.summary}${warn.length ? `; warnings: ${warn.join(' | ')}` : ''}.`,
+    '',
     `# Debate verdict: ${label}`,
     `_${d.providers.join(', ')} | ${d.mode} mode | ${d.rounds_ran} round${d.rounds_ran === 1 ? '' : 's'}_`,
     '', `**Answer:** ${d.final_answer}`, '',
@@ -162,16 +172,17 @@ async function toolDebate(args, progress, ctx) {
     const tag = `debate-${Date.now().toString(36)}-${Math.random().toString(16).slice(2, 8)}`;
     const usesSampling = providers.some(isSampling) || isSampling(synthesizer);
     const samplingEnv = usesSampling ? await sampling.env(ctx.session, { tag, maxTokens: Math.min(Math.max(maxWords * 3, 300), 4000) }) : {};
+    const timeoutMs = usesSampling ? Math.min(LIMITS.timeoutMs, LIMITS.samplingTimeoutMs) : LIMITS.timeoutMs;
     const r = await run(debateBin, cliArgs, {
-      timeoutMs: LIMITS.timeoutMs,
+      timeoutMs,
       env: { ...process.env, ...samplingEnv },
       onStderr: (s) => { for (const m of s.matchAll(/^=== (.+?) ===$/gm)) progress?.(++step, m[1]); },
     });
     // Calls that actually ran are counted from the transcript, whether or not the debate succeeded.
     const transcript = await readFile(join(dir, 'out', 'transcript.md'), 'utf8').catch(() => '');
-    const spent = usageFromTranscript(transcript, question);
+    const spent = usageFromTranscript(transcript, question, { synthesized: !r.timedOut });
     const budget = spent.calls > 0 ? await usage.record(principal, spent) : await usage.snapshot(principal);
-    if (r.timedOut) return text(`error: debate timed out after ${LIMITS.timeoutMs / 1000}s`, true);
+    if (r.timedOut) return text(`error: debate timed out after ${timeoutMs / 1000}s and was stopped. ${spent.calls} model call(s) had already answered and are counted against today's budget (${budget.remaining_calls ?? 'no limit'} calls left). Try mode "quick", fewer providers, or a shorter question.`, true);
     const verdict = parseVerdict(r.out);
     if (r.code !== 0 || !verdict) return text(`error: debate failed (exit ${r.code})\n${redact(r.err.slice(-1500))}`, true);
 
@@ -253,7 +264,7 @@ async function toolIdeasList(args) {
 const TOOLS = [
   {
     name: 'e3d_debate',
-    description: 'Get a multi-model second opinion on a decision or design question. Independent AI models answer, and a synthesizer returns a final answer, a consensus level (full/majority/split), and any dissent, plus each model\'s final position. ALWAYS report the dissent and consensus level to the user -- the disagreement is the point; never present a split verdict as settled. Write a self-contained question: the models cannot see your code. mode "quick" (default): one round, usually well under a minute. mode "thorough": models also critique each other, a few minutes. Use for architectural choices, tradeoffs, and contestable judgment calls -- not for lookups or questions with an obvious answer. Spends the user\'s model credits.',
+    description: 'Use when the user asks for a second opinion, wants to compare options, or has to decide between alternatives (for example "JSON or SQLite?", "should we...", architecture or library tradeoffs). Get a multi-model second opinion on a decision or design question. Independent AI models answer, and a synthesizer returns a final answer, a consensus level (full/majority/split), and any dissent, plus each model\'s final position. ALWAYS report the dissent and consensus level to the user -- the disagreement is the point; never present a split verdict as settled. Write a self-contained question: the models cannot see your code. mode "quick" (default): one round, usually well under a minute. mode "thorough": models also critique each other, a few minutes. Use for architectural choices, tradeoffs, and contestable judgment calls -- not for lookups or questions with an obvious answer. Spends the user\'s model credits.',
     inputSchema: {
       type: 'object',
       properties: {
@@ -343,7 +354,7 @@ const sampling = createSampling({ rpc, log });
 // never advertise sampling, elicitation or roots, so the server never needs to call back into the client.
 const stdioConn = { send, session: { clientInfo: null, capabilities: {}, rootsReady: null }, principal: process.env.E3D_MCP_PRINCIPAL || 'local', rpc, hosted: false, allowed: null };
 const newHttpConn = (principal, allowed) => ({ send: () => {}, session: { clientInfo: null, capabilities: {}, rootsReady: null }, principal, rpc: null, hosted: true, allowed });
-const actions = createPipelineActions({ guard, jobs, base: pipeline });
+const actions = createPipelineActions({ guard, jobs, base: pipeline, usage });
 TOOLS.push(...pipeline.tools, ...actions.tools, usageTool);
 
 // The client's workspace folders (MCP roots) are the default set of repos the pipeline tools may touch.
@@ -379,7 +390,7 @@ async function handle(msg, conn = stdioConn) {
       const want = params?.protocolVersion;
       return reply({
         protocolVersion: SUPPORTED_PROTOCOLS.includes(want) ? want : SUPPORTED_PROTOCOLS[0],
-        capabilities: { tools: { listChanged: false } },
+        capabilities: { tools: { listChanged: false }, prompts: { listChanged: false } },
         serverInfo: SERVER_INFO,
         instructions: conn.hosted
           ? 'Use e3d_debate for contestable decisions where independent model perspectives and recorded dissent add value; always report its dissent, and never present a split verdict as settled. It uses a shared usage budget (see e3d_usage); do not use it for simple lookups.'
@@ -389,6 +400,11 @@ async function handle(msg, conn = stdioConn) {
     case 'notifications/initialized': if (!conn.hosted) session.rootsReady = refreshRoots(session); return;
     case 'notifications/roots/list_changed': if (!conn.hosted) session.rootsReady = refreshRoots(session); return;
     case 'ping': return reply({});
+    case 'prompts/list': return reply({ prompts: listPrompts(conn.allowed) });
+    case 'prompts/get': {
+      const got = getPrompt(params?.name, params?.arguments, conn.allowed);
+      return got ? reply(got) : fail(-32602, `unknown prompt: ${params?.name}`);
+    }
     case 'tools/list': return reply({ tools: conn.allowed ? TOOLS.filter((t) => conn.allowed.has(t.name)) : TOOLS });
     case 'tools/call': {
       const handler = HANDLERS[params?.name];
diff --git a/lib/ideas/ledger.sh b/lib/ideas/ledger.sh
index 094bf1f..5979538 100644
--- a/lib/ideas/ledger.sh
+++ b/lib/ideas/ledger.sh
@@ -801,10 +801,11 @@ ideas_ingest_candidate() {
     --arg workspace_path "$canonical" \
     --arg source_run_id "$source_run_id" \
     --arg source_candidate "$candidate_id" \
+    --arg actor "${E3D_PILOT_ACTOR:-system}" \
     --slurpfile candidate "$candidate_tmp" \
     '{
       schema_version:$schema,event_id:$event_id,idea_id:$idea_id,event:"idea_proposed",
-      timestamp:$timestamp,actor:"system",workspace_kind:$workspace_kind,workspace_path:$workspace_path,
+      timestamp:$timestamp,actor:$actor,workspace_kind:$workspace_kind,workspace_path:$workspace_path,
       source_run_id:$source_run_id,source_candidate:$source_candidate,candidate:$candidate[0]
   }' > "$event_tmp"
   ideas_append_event "$events_file" "$event_tmp" || { rm -f "$candidate_tmp" "$event_tmp"; ideas_release_lock "$kind" "$canonical"; return 1; }
diff --git a/lib/mcp/jobs.js b/lib/mcp/jobs.js
index 6d95c5c..85add43 100644
--- a/lib/mcp/jobs.js
+++ b/lib/mcp/jobs.js
@@ -56,6 +56,25 @@ export function createJobs({ env = process.env } = {}) {
     return hit ? hit[0] : null;
   }
 
+  // Why a draft or run was rejected, from the artifacts the CLI leaves (the job log only ends with a generic line).
+  async function failureDetail(job) {
+    if (!job.run_id) return null;
+    for (const name of ['draft-rejected.md', 'review-status.txt', 'execute-guard-violations.txt']) {
+      try {
+        const body = (await readFile(join(runDirFor(job.repo, job.run_id), name), 'utf8')).split('\n').map((l) => l.replace(/^[#>\s-]+/, '').trim()).filter(Boolean);
+        if (body.length) return `${name}: ${redact(body.slice(0, 3).join(' '))}`.slice(0, 400);
+      } catch { /* try the next artifact */ }
+    }
+    return null;
+  }
+
+  async function warningsFor(job) {
+    if (!job.run_id) return [];
+    try {
+      return (await readFile(join(runDirFor(job.repo, job.run_id), 'draft-scope-warnings.txt'), 'utf8')).split('\n').map((l) => l.trim()).filter(Boolean).map((l) => redact(l));
+    } catch { return []; }
+  }
+
   async function logLines(job) {
     try { return (await readFile(job.log_file, 'utf8')).split('\n'); } catch { return []; }
   }
@@ -80,13 +99,16 @@ export function createJobs({ env = process.env } = {}) {
     if (code === 4) return { ...out, state: 'waiting_for_human', reason: 'execute stopped for human review (diff over the ceiling or guard violation)' };
     if (code === 5) return { ...out, state: 'failed', reason: 'verification failed; nothing was published' };
     if (code === 6) return { ...out, state: 'blocked', reason: 'the independent reviewer blocked this change' };
-    return { ...out, state: 'failed', reason: lines.filter(Boolean).slice(-1)[0] ? `exited ${code}: ${redact(lines.filter(Boolean).slice(-1)[0])}` : `exited ${code}` };
+    const detail = await failureDetail(job);
+    const last = lines.filter(Boolean).slice(-1)[0];
+    return { ...out, state: 'failed', failure_detail: detail, reason: `${last ? `exited ${code}: ${redact(last)}` : `exited ${code}`}${detail ? `. Cause: ${detail}` : ''}` };
   }
 
   async function finalize(job, result) {
     Object.assign(job, result, { finished_at: new Date().toISOString() });
     if (job.kind === 'stage' && !job.run_id) job.run_id = await latestRun(job.repo);
     job.last_completed_stage = await lastCompletedStage(job.repo, job.run_id);
+    job.warnings = await warningsFor(job);
     await save(job);
     return job;
   }
diff --git a/lib/mcp/pipeline-actions.js b/lib/mcp/pipeline-actions.js
index 390a796..fc92fd7 100644
--- a/lib/mcp/pipeline-actions.js
+++ b/lib/mcp/pipeline-actions.js
@@ -15,13 +15,14 @@ import { tmpdir } from 'node:os';
 import { join } from 'node:path';
 import { run, findE3dCode } from './util.js';
 import { redact } from './redact.js';
+import { jobCost } from './usage.js';
 
 const IDEA_ID_RE = /^idea-[A-Za-z0-9]+$/;
 const envInt = (env, name, dflt) => { const n = Number.parseInt(env[name] ?? '', 10); return Number.isFinite(n) && n > 0 ? n : dflt; };
 const sha = (s) => createHash('sha256').update(s).digest('hex');
 const clip = (s, n) => (s.length > n ? `${s.slice(0, n - 1)}...` : s);
 
-export function createPipelineActions({ guard, jobs, base, env = process.env }) {
+export function createPipelineActions({ guard, jobs, base, usage = null, env = process.env }) {
   const { pilot: rawPilot, fail, ok, withRepo, draftWarnings } = base;
   const limits = {
     maxPhases: envInt(env, 'E3D_MCP_MAX_PHASES', 8),
@@ -35,6 +36,24 @@ export function createPipelineActions({ guard, jobs, base, env = process.env })
   const noteDecline = (ctx, repo, ideaId, what) => pilotAs(ctx)(['ideas', 'note', '--repo', repo, ideaId, `${what} was declined by the person in the editor`, '--actor', actorFor(ctx)], { timeoutMs: 30000 }).catch(() => {});
   const planFile = (repo, runId) => join(repo, '.e3d-pilot', 'mcp-jobs', `plan-${runId}.json`);
 
+  // Jobs that spend model credits are reserved against the caller's daily budget BEFORE they start, at a conservative
+  // estimate (see jobCost). A reservation that would break a cap refuses the job and records nothing.
+  const principalOf = (ctx) => ctx?.principal ?? 'local';
+  async function repoConfig(repo) { try { return JSON.parse(await readFile(join(repo, '.e3d-pilot', 'config.json'), 'utf8')); } catch { return {}; } }
+  const count = (v) => [].concat(v ?? []).length;
+  async function reserve(ctx, kind, shape) {
+    if (!usage) return { ok: true, cost: null, reserved: null, budget: null };
+    const cost = jobCost(kind, shape, env);
+    const r = await usage.reserve(principalOf(ctx), cost, kind);
+    return { ...r, cost };
+  }
+  const refusal = (r) => fail(`daily budget: ${r.reason}`);
+  const reservedNote = (r) => (r.reserved ? `\nReserved against today's budget: about ${r.reserved.calls} model calls and ${r.reserved.est_tokens} tokens (an estimate; remaining: ${r.budget.remaining_calls ?? 'no limit'} calls). See e3d_usage.` : '');
+  // Start a job; if it cannot start, give the reservation back so a refusal or an error costs nothing.
+  async function startReserved(ctx, r, repo, spec) {
+    try { return await jobs.start(repo, spec); } catch (e) { if (usage && r.cost) await usage.release(principalOf(ctx), r.cost).catch(() => {}); throw e; }
+  }
+
   async function ideaView(repo, ideaId) {
     if (!IDEA_ID_RE.test(ideaId ?? '')) throw new Error('idea_id must look like idea-<id>');
     const r = await pilot(['ideas', 'show', '--repo', repo, ideaId, '--json'], { timeoutMs: 30000 });
@@ -78,7 +97,7 @@ export function createPipelineActions({ guard, jobs, base, env = process.env })
   const tools = [
     {
       name: 'e3d_pilot_propose',
-      description: 'FREE (writes only to the repo\'s idea ledger; no model calls). Record a new idea for the pipeline from a decision, optionally attaching the e3d_debate result that led to it as provenance evidence. The idea starts as "proposed" and needs human approval before any code can be drafted or written.',
+      description: 'FREE (writes only to the repo\'s idea ledger; no model calls). Use when the user wants to turn a decision or idea into tracked work ("add this to the backlog", "create an idea for X"). Record a new idea for the pipeline from a decision, optionally attaching the e3d_debate result that led to it as provenance evidence. The idea starts as "proposed" and needs human approval before any code can be drafted or written.',
       inputSchema: {
         type: 'object',
         properties: {
@@ -229,10 +248,12 @@ export function createPipelineActions({ guard, jobs, base, env = process.env })
       if (args.focus && !['default', 'revenue'].includes(args.focus)) return fail('focus must be default or revenue');
       if (args.run_id && !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(args.run_id)) return fail('invalid run_id');
       const cli = ['run', '--repo', repo, '--stage', args.stage, ...(args.run_id ? ['--run-id', args.run_id] : []), ...(args.focus ? ['--focus', args.focus] : [])];
-      let job = await jobs.start(repo, { kind: 'stage', args: cli, run_id: args.run_id ?? null, label: `run --stage ${args.stage}`, extraEnv: await jobEnv(ctx) });
+      const rsv = await reserve(ctx, 'stage', {});
+      if (!rsv.ok) return refusal(rsv);
+      let job = await startReserved(ctx, rsv, repo, { kind: 'stage', args: cli, run_id: args.run_id ?? null, label: `run --stage ${args.stage}`, extraEnv: await jobEnv(ctx) });
       // discover allocates its run id a moment after starting; give it a short window so the caller gets one.
       for (let i = 0; i < 10 && !job.run_id && job.state === 'running'; i++) { await new Promise((r) => setTimeout(r, 300)); job = await jobs.refresh(job); }
-      return ok(jobView(job), `Started ${job.label} as ${job.job_id}${job.run_id ? ` (run ${job.run_id})` : ''}. Poll e3d_pilot_job_status; it may take minutes.`);
+      return ok({ ...jobView(job), reserved: rsv.reserved, budget: rsv.budget }, `Started ${job.label} as ${job.job_id}${job.run_id ? ` (run ${job.run_id})` : ''}. Poll e3d_pilot_job_status; it may take minutes.${reservedNote(rsv)}`);
     }),
 
     e3d_pilot_approve: withRepo(async (repo, args, _p, ctx) => {
@@ -284,8 +305,11 @@ export function createPipelineActions({ guard, jobs, base, env = process.env })
           ? `idea ${args.idea_id} is not approved yet. A human must approve it: e3d-pilot ideas approve --repo ${repo} ${args.idea_id}`
           : `idea ${args.idea_id} cannot start implementation from status "${idea.status}"`);
       }
-      const job = await jobs.start(repo, { kind: 'implement', args: ['ideas', 'implement', '--repo', repo, '--stop-before', 'execute', args.idea_id], idea_id: args.idea_id, label: `ideas implement --stop-before execute`, extraEnv: await jobEnv(ctx) });
-      return ok(jobView(job), `Started drafting and negotiating ${args.idea_id} as ${job.job_id}. It pauses before any code is written; poll e3d_pilot_job_status, then call e3d_pilot_code_plan.`);
+      const cfg = await repoConfig(repo);
+      const rsv = await reserve(ctx, 'implement', { negotiators: count(cfg?.providers?.negotiate) });
+      if (!rsv.ok) return refusal(rsv);
+      const job = await startReserved(ctx, rsv, repo, { kind: 'implement', args: ['ideas', 'implement', '--repo', repo, '--stop-before', 'execute', args.idea_id], idea_id: args.idea_id, label: `ideas implement --stop-before execute`, extraEnv: await jobEnv(ctx) });
+      return ok({ ...jobView(job), reserved: rsv.reserved, budget: rsv.budget }, `Started drafting and negotiating ${args.idea_id} as ${job.job_id}. It pauses before any code is written; poll e3d_pilot_job_status, then call e3d_pilot_code_plan.${reservedNote(rsv)}`);
     }),
 
     e3d_pilot_code_plan: withRepo(async (repo, args) => {
@@ -348,11 +372,14 @@ export function createPipelineActions({ guard, jobs, base, env = process.env })
       const head = (await run('git', ['-C', repo, 'rev-parse', 'HEAD'], { timeoutMs: 10000 })).out.trim();
       if (head !== plan.head) return fail('the repository HEAD moved after the plan was made; call e3d_pilot_code_plan again');
       if (plan.phases > limits.maxPhases) return fail(`the plan has ${plan.phases} phases, over the cap of ${limits.maxPhases} (E3D_MCP_MAX_PHASES)`);
-      const job = await jobs.start(repo, { kind: 'resume', args: ['ideas', 'resume', '--repo', repo, args.idea_id], run_id: paused.run_id, idea_id: args.idea_id, label: 'ideas resume (execute, review, publish)', extraEnv: await jobEnv(ctx) });
+      const cfgE = await repoConfig(repo);
+      const rsv = await reserve(ctx, 'execute', { phases: plan.phases, reviewers: count(cfgE?.providers?.review) });
+      if (!rsv.ok) return refusal(rsv);
+      const job = await startReserved(ctx, rsv, repo, { kind: 'resume', args: ['ideas', 'resume', '--repo', repo, args.idea_id], run_id: paused.run_id, idea_id: args.idea_id, label: 'ideas resume (execute, review, publish)', extraEnv: await jobEnv(ctx) });
       await rm(planFile(repo, paused.run_id), { force: true });
       const old = await jobs.pausedJobFor(repo, paused.run_id);
       if (old && old.job_id !== job.job_id) await jobs.settle(repo, old.job_id, 'resumed', `continued by ${job.job_id}`);
-      return ok(jobView(job), `Executing ${plan.phases} phase(s) as ${job.job_id}. This can take a long time; poll e3d_pilot_job_status. It ends with a draft PR for a human to review; merging stays manual.`);
+      return ok({ ...jobView(job), reserved: rsv.reserved, budget: rsv.budget }, `Executing ${plan.phases} phase(s) as ${job.job_id}. This can take a long time; poll e3d_pilot_job_status. It ends with a draft PR for a human to review; merging stays manual.${reservedNote(rsv)}`);
     }),
 
     e3d_pilot_cancel_paused: withRepo(async (repo, args, _p, ctx) => {
diff --git a/lib/mcp/pipeline-tools.js b/lib/mcp/pipeline-tools.js
index 88c3514..8b4e277 100644
--- a/lib/mcp/pipeline-tools.js
+++ b/lib/mcp/pipeline-tools.js
@@ -95,7 +95,10 @@ export function createPipelineTools({ guard, jobs, env = process.env }) {
       run_id: fresh.run_id, idea_id: fresh.idea_id ?? null, exit_code: fresh.exit_code, started_at: fresh.started_at, finished_at: fresh.finished_at,
       elapsed_sec: Math.round((ended - started) / 1000), last_completed_stage: await jobs.lastCompletedStage(fresh.repo, fresh.run_id),
       paused_before: fresh.paused_before ?? null,
-      warnings: fresh.paused_before && fresh.state === 'waiting_for_human' ? await draftWarnings(fresh.repo, fresh.run_id) : [],
+      warnings: Array.isArray(fresh.warnings) && fresh.warnings.length ? fresh.warnings : (fresh.paused_before && fresh.state === 'waiting_for_human' ? await draftWarnings(fresh.repo, fresh.run_id) : []),
+      failure_detail: fresh.failure_detail ?? null,
+      // After a cancel or resume the log still ends with the old "paused" line; say so instead of presenting it as current.
+      log_is_stale: fresh.state === 'cancelled' || fresh.state === 'resumed',
       artifacts: await availableArtifacts(fresh.repo, fresh.run_id),
       log_tail: await jobs.tail(fresh, tailLines),
       next_action: nextAction(fresh),
@@ -177,7 +180,8 @@ export function createPipelineTools({ guard, jobs, env = process.env }) {
       const view = await statusView(job, args.tail_lines ?? 40);
       const readable = [`Job ${view.job_id}: ${view.state.toUpperCase()}${view.reason ? ` (${view.reason})` : ''}`,
         `run ${view.run_id ?? '(not yet allocated)'}; last completed stage: ${view.last_completed_stage ?? 'none'}; elapsed ${view.elapsed_sec}s`,
-        view.next_action ? `Next: ${view.next_action}` : null, ...view.warnings.map((w) => `WARNING: ${w}`), '', ...view.log_tail.slice(-15)].filter((l) => l !== null).join('\n');
+        view.next_action ? `Next: ${view.next_action}` : null, ...view.warnings.map((w) => `WARNING: ${w}`), '',
+        ...(view.log_is_stale ? [`(the log below ended before this job was ${view.state}; it is history, not current state)`, ...view.log_tail.slice(-4)] : view.log_tail.slice(-15))].filter((l) => l !== null).join('\n');
       return ok(view, readable);
     }),
 
diff --git a/lib/mcp/prompts.js b/lib/mcp/prompts.js
new file mode 100644
index 0000000..4ad14ec
--- /dev/null
+++ b/lib/mcp/prompts.js
@@ -0,0 +1,43 @@
+// MCP prompts: slash-command style entry points (for example /e3d-debate in VS Code) so a person does not have to
+// know a tool's name. Each prompt only produces a message asking the agent to use a tool; it never runs anything.
+const PROMPTS = [
+  {
+    name: 'e3d-debate',
+    description: 'Get a multi-model second opinion on a decision (costs model credits).',
+    arguments: [{ name: 'question', description: 'The decision or question, with context.', required: true }],
+    tools: ['e3d_debate'],
+    build: (a) => `Use the e3d_debate tool to get a multi-model second opinion on this question, then report the answer, the consensus level, any dissent, and any warnings exactly as the tool gives them (do not drop dissent or warnings when summarizing):\n\n${a.question ?? '(no question given: ask the user what to decide)'}`,
+  },
+  {
+    name: 'e3d-propose',
+    description: 'Record an idea in a repository\'s e3d-pilot ledger as proposed (free; a human approves it later).',
+    arguments: [
+      { name: 'repo', description: 'Absolute path to the repository.', required: true },
+      { name: 'title', description: 'Short title.', required: true },
+      { name: 'rationale', description: 'What to build and why.', required: true },
+    ],
+    tools: ['e3d_pilot_propose'],
+    build: (a) => `Use the e3d_pilot_propose tool to record this idea as proposed. Do not approve it; a human approves it separately.\n\nRepository: ${a.repo ?? '(ask the user)'}\nTitle: ${a.title ?? '(ask the user)'}\nRationale: ${a.rationale ?? '(ask the user)'}`,
+  },
+  {
+    name: 'e3d-budget',
+    description: 'Show today\'s model-call budget and what is left (free).',
+    arguments: [],
+    tools: ['e3d_usage'],
+    build: () => 'Use the e3d_usage tool and tell me how many model calls and estimated tokens are used and left today, and when the budget resets.',
+  },
+];
+
+const visible = (allowed) => PROMPTS.filter((p) => !allowed || p.tools.every((t) => allowed.has(t)));
+
+export function listPrompts(allowed) {
+  return visible(allowed).map(({ name, description, arguments: args }) => ({ name, description, arguments: args }));
+}
+
+// Returns { description, messages } or null when the prompt is unknown or hidden from this connection.
+export function getPrompt(name, args, allowed) {
+  const p = visible(allowed).find((x) => x.name === name);
+  if (!p) return null;
+  const a = args && typeof args === 'object' ? Object.fromEntries(Object.entries(args).map(([k, v]) => [k, String(v).slice(0, 4000)])) : {};
+  return { description: p.description, messages: [{ role: 'user', content: { type: 'text', text: p.build(a) } }] };
+}
diff --git a/lib/mcp/usage.js b/lib/mcp/usage.js
index f857754..ccf354c 100644
--- a/lib/mcp/usage.js
+++ b/lib/mcp/usage.js
@@ -26,11 +26,11 @@ export function createUsage({ env = process.env, defaults = { calls: 0, tokens:
       const s = JSON.parse(await readFile(fileFor(principal), 'utf8'));
       if (s.day === today()) return s;
     } catch { /* first use or unreadable: start fresh */ }
-    return { day: today(), calls: 0, est_input_tokens: 0, est_output_tokens: 0, debates: 0 };
+    return { day: today(), calls: 0, est_input_tokens: 0, est_output_tokens: 0, debates: 0, jobs: 0 };
   }
   const nextResetIso = () => { const d = new Date(); return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1)).toISOString(); };
   const budgetView = (principal, s) => ({
-    principal, day: s.day, resets_at: nextResetIso(), calls_today: s.calls, calls_limit: limits.calls || null,
+    principal, day: s.day, resets_at: nextResetIso(), state_file: fileFor(principal), calls_today: s.calls, calls_limit: limits.calls || null,
     est_tokens_today: s.est_input_tokens + s.est_output_tokens, est_tokens_limit: limits.tokens || null,
     remaining_calls: limits.calls ? Math.max(limits.calls - s.calls, 0) : null,
     remaining_est_tokens: limits.tokens ? Math.max(limits.tokens - s.est_input_tokens - s.est_output_tokens, 0) : null,
@@ -41,6 +41,22 @@ export function createUsage({ env = process.env, defaults = { calls: 0, tokens:
     return next;
   };
 
+  async function persist(principal, s) {
+    await mkdir(dir, { recursive: true });
+    const file = fileFor(principal);
+    await writeFile(`${file}.tmp`, `${JSON.stringify(s)}\n`);
+    await rename(`${file}.tmp`, file);
+  }
+  function refusalFor(principal, s, budget, { calls, tokens }) {
+    if (limits.calls && s.calls + calls > limits.calls) {
+      return `this request could use up to ${calls} model calls but only ${budget.remaining_calls} of today's ${limits.calls} remain for "${principal}" (resets at 00:00 UTC; raise E3D_MCP_DAILY_CALLS)`;
+    }
+    if (limits.tokens && s.est_input_tokens + s.est_output_tokens + tokens > limits.tokens) {
+      return `this request could use about ${tokens} tokens (estimate) but only ${budget.remaining_est_tokens} of today's ${limits.tokens} remain for "${principal}" (resets at 00:00 UTC; raise E3D_MCP_DAILY_EST_TOKENS)`;
+    }
+    return null;
+  }
+
   return {
     limits, dir,
     async snapshot(principal) { return budgetView(principal, await load(principal)); },
@@ -49,24 +65,42 @@ export function createUsage({ env = process.env, defaults = { calls: 0, tokens:
     async check(principal, { calls, tokens }) {
       const s = await load(principal);
       const budget = budgetView(principal, s);
-      if (limits.calls && s.calls + calls > limits.calls) {
-        return { ok: false, budget, reason: `this request could use up to ${calls} model calls but only ${budget.remaining_calls} of today's ${limits.calls} remain for "${principal}" (resets at 00:00 UTC; raise E3D_MCP_DAILY_CALLS)` };
-      }
-      if (limits.tokens && s.est_input_tokens + s.est_output_tokens + tokens > limits.tokens) {
-        return { ok: false, budget, reason: `this request could use about ${tokens} tokens (estimate) but only ${budget.remaining_est_tokens} of today's ${limits.tokens} remain for "${principal}" (resets at 00:00 UTC; raise E3D_MCP_DAILY_EST_TOKENS)` };
-      }
-      return { ok: true, budget };
+      const reason = refusalFor(principal, s, budget, { calls, tokens });
+      return reason ? { ok: false, budget, reason } : { ok: true, budget };
     },
 
     // Records what a finished debate actually used (estimates) and returns the updated budget.
-    record(principal, { calls, inTokens, outTokens }) {
+    record(principal, { calls, inTokens, outTokens, kind = 'debate' }) {
+      return withLock(principal, async () => {
+        const s = await load(principal);
+        s.calls += calls; s.est_input_tokens += inTokens; s.est_output_tokens += outTokens;
+        if (kind === 'debate') s.debates += 1; else s.jobs = (s.jobs ?? 0) + 1;
+        await persist(principal, s);
+        return budgetView(principal, s);
+      });
+    },
+
+    // Pipeline jobs (discover/ideate, draft+negotiate, execute) spend model credits that cannot be measured from here,
+    // so they are RESERVED up front at a conservative estimate: check the caps and record the reservation in one step.
+    // Returns { ok: false, reason, budget } without recording anything when the reservation would break a cap.
+    reserve(principal, cost, kind) {
       return withLock(principal, async () => {
         const s = await load(principal);
-        s.calls += calls; s.est_input_tokens += inTokens; s.est_output_tokens += outTokens; s.debates += 1;
-        await mkdir(dir, { recursive: true });
-        const file = fileFor(principal);
-        await writeFile(`${file}.tmp`, `${JSON.stringify(s)}\n`);
-        await rename(`${file}.tmp`, file);
+        const budget = budgetView(principal, s);
+        const refusal = refusalFor(principal, s, budget, cost);
+        if (refusal) return { ok: false, budget, reason: refusal };
+        s.calls += cost.calls; s.est_input_tokens += cost.tokens; s.jobs = (s.jobs ?? 0) + 1;
+        await persist(principal, s);
+        return { ok: true, budget: budgetView(principal, s), reserved: { kind, calls: cost.calls, est_tokens: cost.tokens, estimate: true } };
+      });
+    },
+
+    // Gives back a reservation when the job could not even start.
+    release(principal, cost) {
+      return withLock(principal, async () => {
+        const s = await load(principal);
+        s.calls = Math.max(s.calls - cost.calls, 0); s.est_input_tokens = Math.max(s.est_input_tokens - cost.tokens, 0); s.jobs = Math.max((s.jobs ?? 1) - 1, 0);
+        await persist(principal, s);
         return budgetView(principal, s);
       });
     },
@@ -74,7 +108,8 @@ export function createUsage({ env = process.env, defaults = { calls: 0, tokens:
 }
 
 // What a finished debate cost, estimated from its transcript ("## Round N -- provider" sections + the synthesis).
-export function usageFromTranscript(transcript, question) {
+// `synthesized: false` (the debate was stopped before its verdict) leaves the synthesis call out, so a timeout is not billed for it.
+export function usageFromTranscript(transcript, question, { synthesized = true } = {}) {
   const q = estTokens(question.length) + 100;
   const rounds = new Map();
   for (const m of transcript.matchAll(/^## Round (\d+) -- (\S+)\n\n([\s\S]*?)(?=\n## |$(?![\s\S]))/gm)) {
@@ -94,7 +129,7 @@ export function usageFromTranscript(transcript, question) {
   }
   const fastPath = /## Synthesis \(fast path/.test(transcript);
   const synth = transcript.match(/\n## Synthesis[^\n]*\n\n([\s\S]*)$/)?.[1] ?? '';
-  if (!fastPath && calls > 0) {
+  if (!fastPath && synthesized && calls > 0) {
     calls += 1;
     inTokens += q + estTokens(transcript.length - synth.length);
     outTokens += estTokens(synth.length || 200);
@@ -110,9 +145,19 @@ export function worstCase({ providers, rounds, maxWords, questionChars }) {
   return { calls, tokens: calls * (perCallIn + answerTok) };
 }
 
+// Conservative reservation for a pipeline job. These are ESTIMATES of model invocations and tokens, not measurements:
+// a code-writing phase is one long session (about 190k tokens was observed for one phase), so a phase counts as 3 calls.
+export function jobCost(kind, { phases = 1, negotiators = 1, reviewers = 1 } = {}, env = process.env) {
+  const perPhase = Number.parseInt(env.E3D_MCP_EST_TOKENS_PER_PHASE ?? '', 10) || 200000;
+  if (kind === 'stage') return { calls: 2, tokens: 40000 };
+  if (kind === 'implement') { const calls = 1 + 2 * Math.max(negotiators, 1); return { calls, tokens: calls * 15000 }; }
+  if (kind === 'execute') return { calls: Math.max(phases, 1) * 3 + Math.max(reviewers, 1), tokens: Math.max(phases, 1) * perPhase + Math.max(reviewers, 1) * 40000 };
+  throw new Error(`unknown job kind: ${kind}`);
+}
+
 export const usageTool = {
   name: 'e3d_usage',
-  description: 'FREE. Today\'s usage and daily limits for the caller: model calls and estimated tokens used by e3d_debate, what remains, and when it resets (00:00 UTC). Numbers are estimates.',
+  description: 'FREE. Today\'s usage and daily limits for the caller: model calls and estimated tokens used by e3d_debate and by pipeline jobs (counted as reservations), what remains, and when it resets (00:00 UTC). Numbers are estimates. Use it before an expensive request when the user asks what is left.',
   inputSchema: { type: 'object', properties: {}, additionalProperties: false },
   annotations: { title: 'Usage and budget', readOnlyHint: true, openWorldHint: false },
 };
@@ -121,7 +166,7 @@ export function usageHandler(usage) {
   return async (_args, _progress, ctx) => {
     const b = await usage.snapshot(ctx?.principal ?? 'local');
     const lim = (v, unit) => (v ? `of ${v} ${unit}` : `(no daily limit)`);
-    const out = `Usage for "${b.principal}" on ${b.day} (UTC; estimates):\n  model calls: ${b.calls_today} ${lim(b.calls_limit, 'calls')}\n  tokens: ~${b.est_tokens_today} ${lim(b.est_tokens_limit, 'tokens')}`;
+    const out = `Usage for "${b.principal}" on ${b.day} (UTC; estimates):\n  model calls: ${b.calls_today} ${lim(b.calls_limit, 'calls')}\n  tokens: ~${b.est_tokens_today} ${lim(b.est_tokens_limit, 'tokens')}\n  resets at ${b.resets_at}\nThis counter covers every repository this server touches for "${b.principal}" and lives in ${b.state_file}. Pipeline jobs (discover/ideate, implement, execute) are counted as reservations at a conservative estimate, because their real spend is not measurable here.`;
     return { ...text(out), structuredContent: b };
   };
 }

**Jev pre-screen (shadow mode, informational only):** obviousness noul=0.29 (1.0 = clearly obvious, 0.0 = clearly needs debate) -- logged for calibration, does not affect whether this debate runs.

## Round 1 -- codex

Recommendation: **fix first**.

1. **`lib/mcp/pipeline-actions.js` — reservation leaks before start.** After `reserve()`, argument evaluation calls `await jobEnv(ctx)` outside `startReserved()`’s `try`. If sampling-environment setup throws, the tool returns an error but usage remains charged. Move all post-reservation preparation inside a `try/finally`, releasing unless `jobs.start` definitively succeeds.

2. **`lib/mcp/jobs.js` / `pipeline-actions.js` — release can hide a running job’s spend.** `jobs.start()` spawns the detached child before `save(job)`. If saving fails (disk full/permission error), it throws; `startReserved()` releases the reservation while the child continues consuming credits. Persist a pending job before spawning, or terminate/reap the child on every post-spawn failure before releasing.

3. **`lib/mcp/usage.js`, `bin/e3d-mcp` — budget enforcement is still racy.** Debates use unlocked `check()` followed much later by `record()`. With five calls left, a three-call debate can pass its check, then a four-call job reserves, and both run, ending at seven. Multiple server processes also bypass the in-memory lock and race on the same fixed `.tmp` file. Use durable, cross-process locking and reservation IDs for both debates and jobs; settle a debate reservation to actual usage afterward.

4. **`lib/mcp/usage.js` / `pipeline-actions.js` — stage reservations undercount configured calls.** `jobCost('stage')` always records two calls, although `providers.discover` and `providers.ideate` accept arbitrary arrays, and ideate may make an additional scoring call. Four configured discover providers spend four calls while only two remain recorded. Derive cost from stage configuration, including scoring, and reject unsupported/unbounded shapes.

5. **`bin/e3d-mcp`, `usage.js` — timeout does not prove synthesis never ran.** Passing `{synthesized: !r.timedOut}` omits synthesis whenever the wall-clock timeout fires. If synthesis started at second 149 and the process is killed at 150, that billed call is uncounted. Conversely, non-timeout failure before synthesis still fabricates a synthesis charge. Instrument the debate runner with durable “call started” records and count those, rather than inferring from process outcome.

6. **`lib/mcp/jobs.js` — new status fields can disclose secrets and exhaust responses.** `failureDetail()` and `warningsFor()` automatically expose artifact text. Existing redaction misses forms such as `AWS_SECRET_ACCESS_KEY=...` and database URLs; warnings are unlimited. Parse only safe structured reasons, strengthen redaction, and cap bytes, lines, and total output.

7. **`lib/mcp/prompts.js` — required arguments are not enforced.** `prompts/get` accepts missing required fields and arbitrary keys. Validate against each prompt’s declared arguments, reject missing/unknown/non-string values, and impose an aggregate size limit.

The ledger actor change is correctly quoted for shell and `jq`; I found no approval, merge-exposure, or repo-allowlist regression.

**Must fix:** 1–6.

## Round 1 -- claude

**Recommendation: fix first.** The budget design is sound. The must-fix items are the budget leak after a failed start, the double count on a timeout, the missing reservation for `ideas implement`, and the unvalidated `run_id`/stale-log paths.

**Must-fix**

1. **`pipeline-actions.js`, execute path: the job starts, then later steps can throw.**
   - After `startReserved`, the calls `rm(planFile)`, `jobs.pausedJobFor` and `jobs.settle` can throw. The job is already running and the reservation is correct, so nothing is double-counted. But the tool errors out and the caller retries, which reserves again.
   - The retry then hits "plan not found" or a duplicate-job guard. This is a leak only if the job's start is not idempotent.
   - Fix: wrap the post-start bookkeeping in try/catch and return success with a warning.

2. **`reserve` is made before the job-concurrency checks that `jobs.start` runs.**
   - If `jobs.start` refuses because a job is already running, it throws and is released. That path is correct.
   - If `jobs.start` returns a job in an already-failed state, for example a spawn failure recorded as `failed` instead of thrown, nothing is released. A refused or failed start then still records usage.
   - Fix: after `start`, release the reservation if `job.state` is `failed` and the job has no `started_at`, or have `start` throw on spawn failure.

3. **`usage.record` after a debate does not reconcile.**
   - Debate usage is checked with `check` before the run and recorded afterward, in separate lock holds. Two concurrent debates both pass `check` and both record, so the cap can be overshot. The cap is only approximately enforced.
   - Pipeline jobs use an atomic `reserve`, so the two paths have different guarantees. Fix: use `reserve` for debates with a worst-case cost, then adjust to the actual cost with a delta.

4. **`usageFromTranscript` with `synthesized: !r.timedOut`.**
   - On a non-timeout failure, such as exit code 1 or a parse failure, the synthesis call may have run and is billed. That case is fine.
   - On a timeout during synthesis, the synthesis call may already have been charged by the provider and is not counted. This is an undercount.
   - Separately, `calls > 0` gates `usage.record`. A timeout before any answer is recorded as zero.
   - Fix: count synthesis if the transcript has a `## Synthesis` heading, regardless of timeout.

5. **The `implement` reservation does not cover the `ideas implement` flow's actual cost.**
   - It reserves for the draft plus negotiators only. Reviewers and the draft-retry loop are not reserved.
   - The cost is `1 + 2*negotiators`. If the config lists providers elsewhere, such as `providers.draft`, those are ignored.
   - The default of 1 negotiator when the config is missing under-reserves. Fix: reserve using the real config keys, or add a safety multiplier.

6. **`failureDetail` and `warningsFor` build a path from `job.run_id`.**
   - `run_id` is validated for stage jobs. For implement and resume jobs, `run_id` comes from CLI artifacts or `paused.run_id`.
   - If `runDirFor` does not sanitize it, a `run_id` containing `../` reads arbitrary `draft-rejected.md` files.
   - Fix: re-validate against `/^[A-Za-z0-9][A-Za-z0-9._-]*$/` inside `runDirFor`.

7. **`log_is_stale` is set for `resumed` and `cancelled` states.**
   - That is correct. But `warnings` now prefers `fresh.warnings` over a live `draftWarnings` call. A job finalized before the warnings file existed returns `[]`, and the length check then falls through to `draftWarnings`.
   - This is OK, but `fresh.warnings` is written only on `finalize`. For a running job it is undefined, so it falls through. No bug.

**Should-fix**

8. **`failure_detail` redaction.** `redact` runs on the joined text before `slice(0, 400)`, so a secret cut at the boundary is already redacted. That is fine. But `review-status.txt` and `execute-guard-violations.txt` can contain file paths and diff snippets. These are partly sensitive, and `redact` only covers token patterns. Fix: restrict `failure_detail` to the first line, and cap it at 200 characters.

9. **`ledger.sh`: `--arg actor "${E3D_PILOT_ACTOR:-system}"`.**
   - jq is correct, and `--arg` quotes safely.
   - `E3D_PILOT_ACTOR` is caller-controlled. For hosted callers `jobEnv` sets it, but an ambient environment variable can spoof the actor in a stdio session.
   - The bigger issue is that nothing validates the value. A newline or a very long string goes into the ledger. Fix: validate it against `^[A-Za-z0-9:._@-]{1,64}$`, otherwise use `system`. Also confirm that approval checks never trust `actor` for authorization.

10. **`prompts/get`.**
    - Arguments are sliced to 4000 characters, which is fine. `String(v)` on an object gives `[object Object]`, which is harmless.
    - Prompt text embeds user input, and that is an injection surface by design. The mitigation is that prompts only ask the agent to call a tool.
    - Gap: there is no validation of `repo`, so the agent might call `e3d_pilot_propose` on any path. The repo allowlist still applies in `withRepo`, so it holds.
    - Gap: `required` is not enforced. Missing arguments produce "(ask the user)", which is fine.
    - Gap: the `Object.entries(args)` keys are not restricted to the declared names. Unknown keys are ignored, which is fine.

11. **Overflow in `release`.** If the day rolls over between `reserve` and `release`, `load` returns a fresh day with zeros. `release` clamps at 0, which is correct. But the release is then missed for the new day, and that is harmless.

**Safety properties:** approval stays human, because the prompts say "do not approve", and merge is not exposed. The repo allowlist is unchanged. No weakening found.

**Timeout:** `samplingTimeoutMs` defaults to 150s. A debate that times out in sampling mode is killed, and its partial calls are counted. This is fine.

## Round 2 -- codex

My prior position holds: **fix first**. Claude confirms the two central defects—non-atomic debate accounting and timeout-based synthesis inference—but understates several reservation failures.

- `lib/mcp/pipeline-actions.js`: `await jobEnv(ctx)` runs after reservation but before `startReserved()`’s protected call. If it throws, usage remains recorded although no job starts. Move all post-reservation preparation into a reservation lifecycle guarded by `try/finally`.

- `lib/mcp/jobs.js` and `pipeline-actions.js`: if `jobs.start()` spawns a child and then fails while saving metadata, `startReserved()` releases credits while the untracked child keeps spending them. Checking for a returned failed state does not solve a thrown post-spawn failure. Persist before spawn, or terminate the child before releasing.

- `lib/mcp/usage.js` and `bin/e3d-mcp`: debates still perform separate `check()` and `record()` operations. Concurrent debates/jobs can all pass the cap. In-memory locking also does not coordinate multiple server processes, and the shared `.tmp` filename creates overwrite races. Reserve worst-case debate cost atomically with durable cross-process locking and a reservation ID, then reconcile actual usage.

- `lib/mcp/usage.js`: `jobCost('stage')` always reserves two calls despite configurable provider arrays and possible scoring. Claude focuses on implement retries/configuration, which is also worth auditing, but the deterministic stage undercount is already concrete. Derive reservations from the exact execution plan.

- `bin/e3d-mcp` and `usage.js`: Claude’s proposed “count synthesis if its heading exists” is insufficient. A provider call may begin—and be billed—before the heading is written. Conversely, every non-timeout failure currently assumes synthesis occurred. Record durable call-start events in the runner and account from those.

- `lib/mcp/jobs.js`: artifact-derived warnings and failure details broaden data exposure. Redaction may miss credentials such as database URLs or `AWS_SECRET_ACCESS_KEY`, while warnings have no aggregate bound. Restrict artifacts to safe structured fields, strengthen redaction, and cap bytes/lines. Path validation for artifact-derived `run_id` should also be enforced centrally if `runDirFor()` does not already do so.

Claude’s post-start retry concern is real operationally, but it does not itself miscount unless retry can start another job. Its claim that missing prompt arguments are “fine” conflicts with MCP’s declared `required` contract; `prompts/get` should reject missing, unknown, non-string, and oversized aggregate input.

The ledger’s `--arg actor` usage is shell/jq-correct. Actor-format validation is defense-in-depth unless authorization trusts that field. No demonstrated approval, merge, or allowlist regression appears.

POSITION: Fix first; the must-fixes are reservation lifecycle integrity, atomic cross-process accounting for debates and jobs, accurate call-start accounting, configuration-derived job costs, and bounded safely redacted status artifacts.
status: revise

## Round 2 -- claude

I still recommend **fix first**. Codex and I agree on that, and on most of the substance. Having re-read the diff, I'm changing my mind on one point and adding another.

**Codex #1 is right, and I missed it.** In `pipeline-actions.js` the call is `startReserved(ctx, rsv, repo, { ..., extraEnv: await jobEnv(ctx) })`. The `await jobEnv(ctx)` is evaluated as an argument, before `startReserved` enters its `try`. If `jobEnv` throws, for example during sampling setup, the reservation was already recorded and is never released. The failure is a refused request that still records usage. This applies to all three tools: stage, implement and execute. Fix: compute `extraEnv` before `reserve`, or put everything after `reserve` in one `try/catch` that releases on any throw before the job is confirmed started.

**Codex #3 and #5 match my #3 and #4.** Debates use `check` and then `record` in separate lock holds, so two concurrent debates can both pass and overshoot the cap. Jobs use the atomic `reserve`. Fix: reserve a debate's worst case up front and settle to actual usage afterward. `synthesized: !r.timedOut` is only a heuristic. Counting synthesis when the transcript has a `## Synthesis` heading is better than inferring from the process outcome. I'd keep my fix; Codex's durable "call started" records would be more robust but are a larger change.

**Codex #4 is valid and new to me.** `jobCost('stage')` is a flat 2 calls regardless of how many providers `providers.discover` and `providers.ideate` list. My point 5 made the same under-reservation argument for `implement` and `execute`. Both fixes are the same: derive the cost from the repo config.

**Codex #2 is plausible, but I couldn't confirm it from the diff.** If `jobs.start` spawns the child and then throws on `save`, the release hides a running job's spend. My point 2 is the same family: a failed start that returns instead of throwing is never released. The fix is common to both: make `start` kill the child and throw on any post-spawn failure, or persist the job before spawning.

**Codex #6 on secrets is valid.** `failureDetail` and `warningsFor` expose artifact text through `redact`, which covers token patterns only. `review-status.txt` and guard-violation files can hold paths and diff snippets. Fix: cap warnings to N lines and a byte budget, show only the first line of `failure_detail`, and extend the redaction patterns.

**Where I disagree with Codex:**
- **#7 (prompt argument validation) is not must-fix.** Missing arguments already degrade to "ask the user". Unknown keys are ignored. Values are capped at 4000 characters each. The prompts only ask the agent to call a tool, and the repo allowlist is enforced in `withRepo`.
- **My earlier items 1 and 7 were weak.** I'm withdrawing them as must-fix.
- **The `runDirFor` path-traversal point (my 6) stays on the list.** I couldn't see `runDirFor` in the diff. Verify that it validates `run_id`, because `failureDetail` and `warningsFor` now read files through it.
- **The ledger actor.** I haven't changed my view. The jq is correct, but `E3D_PILOT_ACTOR` isn't validated, so a newline or very long value goes into the ledger. I recommend validating it against a short allowlisted pattern.

**Safety properties:** none is weakened. Approval stays human, merge is not exposed, and the allowlist is unchanged.

**Must-fix:**
1. Release the reservation if anything after `reserve` throws, including `jobEnv`.
2. Make `start` fail cleanly, and don't release while a child may still be running.
3. Reserve debates atomically and settle them to actual usage.
4. Count synthesis whenever a `## Synthesis` heading is present.
5. Size the stage, implement and execute reservations from the repo config.
6. Verify `runDirFor` validates `run_id`, and cap and redact the new status fields.

POSITION: Fix first. The budget design is sound, but the reservation leaks on `jobEnv` throws and start failures, debate budgeting is not atomic, stage and implement costs are under-reserved, and the new status fields need caps and `run_id` validation.
status: approved


## Synthesis (claude)

FINAL ANSWER: Fix first. The budget reservation leaks in two places. `await jobEnv(ctx)` is evaluated before `startReserved`'s `try`, so a throw there leaves usage recorded with no job started. `jobs.start` can also throw after the child has spawned, which releases credits while the child keeps spending them.

Debates still use a non-atomic `check()` then `record()`, so concurrent debates and jobs can overshoot the cap. `synthesized: !r.timedOut` is only a guess, and it can undercount a synthesis call that started before the kill. `jobCost` is a flat 2 calls for the stage job and ignores configured provider arrays. Implement and execute cost estimates ignore some configured roles.

The new `failure_detail` and `warnings` fields need line and byte caps and stronger redaction. `runDirFor` should validate `run_id`.

Must-fix:
- Release the reservation on any throw after `reserve`.
- Make `jobs.start` clean up and throw on post-spawn failure.
- Reserve debates atomically and settle them to actual usage.
- Account for synthesis from call-start records, or at least from the transcript, rather than from the timeout flag.
- Size job costs from the repo config.
- Cap and redact the artifact-derived status fields, and validate `run_id`.

The ledger `--arg actor` change is correct for shell and jq. Validating the actor format is optional hardening. No safety property is weakened: approval stays human, merge is not exposed, and the repo allowlist is unchanged.

CONSENSUS: majority

DISSENT: The two reviewers disagree on whether strict `prompts/get` argument validation (reject missing or unknown arguments) is must-fix. Codex says yes; Claude says no, since the repo allowlist holds and missing arguments degrade safely. The reviewers also differ on the synthesis fix: Codex wants durable call-start records, and Claude would accept a `## Synthesis` heading check.
