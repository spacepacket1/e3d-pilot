import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// Every read and every mutation goes through the installed `e3d-pilot`
// binary on PATH -- the exact same entrypoint a human types at a terminal.
// This file never reimplements ledger logic (approval-digest checks,
// transition guards, etc.); it only shells out and parses/streams output.
// That keeps "one implementation, two front doors" true even more strictly
// than an in-process function call would.
//
// A "workspace" (`ws`) is either { kind: 'repo', target: <repo path> } or
// { kind: 'fleet', target: <fleet.json path> } -- the two ways e3d-pilot
// itself addresses an idea ledger (`ideas --repo <path> ...` vs
// `fleet ideas <fleet.json> ...`). Every function below dispatches on
// ws.kind rather than duplicating ledger/CLI logic per kind.

class CliError extends Error {
  constructor(message, stderr) {
    super(message);
    this.stderr = stderr;
  }
}

function run(args) {
  try {
    return execFileSync('e3d-pilot', args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  } catch (error) {
    const stderr = (error.stderr || '').toString().trim();
    throw new CliError(stderr || error.message, stderr);
  }
}

function runJson(args) {
  return JSON.parse(run(args));
}

// Builds the argv for one `ideas`/`fleet ideas` subcommand, e.g.
// ideasArgs({kind:'repo', target:'/r'}, 'show', {id:'idea-1', flags:['--json']})
//   -> ['ideas', 'show', '--repo', '/r', 'idea-1', '--json']
// ideasArgs({kind:'fleet', target:'/f.json'}, 'show', {id:'idea-1', flags:['--json']})
//   -> ['fleet', 'ideas', '/f.json', 'show', 'idea-1', '--json']
function ideasArgs(ws, subcommand, { id, flags = [] } = {}) {
  const idPart = id ? [id] : [];
  if (ws.kind === 'fleet') {
    return ['fleet', 'ideas', ws.target, subcommand, ...idPart, ...flags];
  }
  return ['ideas', subcommand, '--repo', ws.target, ...idPart, ...flags];
}

// Root directory of the ledger for this workspace: `<repo>/.e3d-pilot` or,
// for a fleet, `<dirname of fleet.json>/.e3d-pilot-fleet` (matches
// ideas_workspace_dir in lib/ideas/ledger.sh).
function workspaceDir(ws) {
  if (ws.kind === 'fleet') {
    return path.join(path.dirname(ws.target), '.e3d-pilot-fleet');
  }
  return path.join(ws.target, '.e3d-pilot');
}

export function listIdeas(ws, { status } = {}) {
  const flags = ['--json'];
  if (status) flags.push('--status', status);
  return runJson(ideasArgs(ws, 'list', { flags }));
}

export function showIdea(ws, id) {
  return runJson(ideasArgs(ws, 'show', { id, flags: ['--json'] }));
}

export function approveIdea(ws, id, actor, note) {
  const flags = [];
  if (actor) flags.push('--actor', actor);
  if (note) flags.push('--note', note);
  run(ideasArgs(ws, 'approve', { id, flags }));
}

export function rejectIdea(ws, id, reason, actor) {
  const flags = ['--reason', reason];
  if (actor) flags.push('--actor', actor);
  run(ideasArgs(ws, 'reject', { id, flags }));
}

export function requestChangesIdea(ws, id, reason, actor) {
  const flags = ['--reason', reason];
  if (actor) flags.push('--actor', actor);
  run(ideasArgs(ws, 'request-changes', { id, flags }));
}

export function approveMergeIdea(ws, id, actor, note) {
  const flags = [];
  if (actor) flags.push('--actor', actor);
  if (note) flags.push('--note', note);
  run(ideasArgs(ws, 'approve-merge', { id, flags }));
}

export function syncIdea(ws, id) {
  run(ideasArgs(ws, 'sync', { id }));
}

function ideaMarkerPath(ws, id, ext) {
  return path.join(workspaceDir(ws), `web-implement-${id}.${ext}`);
}

// Spawns `ideas implement` (or `fleet ideas implement`) detached so the HTTP
// request doesn't block for the ~30-40+ minute draft/negotiate/execute/
// review/publish pipeline. The pid+startedAt marker lets the detail page
// show "in progress since HH:MM" across page loads without the Node process
// itself needing to stay alive or track anything in memory.
export function implementIdea(ws, id) {
  const logPath = ideaMarkerPath(ws, id, 'log');
  const markerPath = ideaMarkerPath(ws, id, 'json');
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const logFd = fs.openSync(logPath, 'a');
  const child = spawn('e3d-pilot', ideasArgs(ws, 'implement', { id }), {
    detached: true,
    stdio: ['ignore', logFd, logFd]
  });
  fs.closeSync(logFd);
  child.unref();
  fs.writeFileSync(
    markerPath,
    JSON.stringify({ pid: child.pid, startedAt: new Date().toISOString() }, null, 2)
  );
}

export function implementMarker(ws, id) {
  const markerPath = ideaMarkerPath(ws, id, 'json');
  if (!fs.existsSync(markerPath)) return null;
  try {
    const marker = JSON.parse(fs.readFileSync(markerPath, 'utf8'));
    try {
      process.kill(marker.pid, 0);
      marker.running = true;
    } catch {
      marker.running = false;
    }
    return marker;
  } catch {
    return null;
  }
}

// Finds the most recent run directory linked to this idea: prefer an
// `impl-<id-without-prefix>-*` implementation run (matches
// implementation_next_run_id's naming in bin/e3d-pilot) since that run's
// directory has findings/candidates copied forward alongside spec-final.md
// and the implementation-stage-log; fall back to the idea's original
// discover/ideate run when no implementation run exists yet.
export function findLatestRunDir(ws, id, sourceRunId) {
  const runsRoot = path.join(workspaceDir(ws), 'runs');
  const strippedId = id.startsWith('idea-') ? id.slice('idea-'.length) : id;
  const prefix = `impl-${strippedId}-`;
  let entries = [];
  try {
    entries = fs.readdirSync(runsRoot, { withFileTypes: true });
  } catch {
    return null;
  }
  const implRuns = entries
    .filter((e) => e.isDirectory() && e.name.startsWith(prefix))
    .map((e) => {
      const full = path.join(runsRoot, e.name);
      return { name: e.name, full, mtime: fs.statSync(full).mtimeMs };
    })
    .sort((a, b) => b.mtime - a.mtime);
  if (implRuns.length > 0) return implRuns[0].full;
  if (sourceRunId) {
    const fallback = path.join(runsRoot, sourceRunId);
    if (fs.existsSync(fallback)) return fallback;
  }
  return null;
}

export function readImplementationLog(ws, id) {
  const runDir = findLatestRunDir(ws, id);
  if (!runDir) return null;
  const logFile = path.join(runDir, 'implementation-stage-log.md');
  if (!fs.existsSync(logFile)) return null;
  const content = fs.readFileSync(logFile, 'utf8');
  const MAX = 20000;
  return content.length > MAX ? `... (truncated, showing last ${MAX} chars)\n${content.slice(-MAX)}` : content;
}

const ARTIFACT_ALLOWLIST = ['findings.md', 'candidates.md', 'negotiation-log.md', 'spec-final.md'];

export function listAvailableArtifacts(ws, id, sourceRunId) {
  const runDir = findLatestRunDir(ws, id, sourceRunId);
  if (!runDir) return [];
  return ARTIFACT_ALLOWLIST.filter((name) => fs.existsSync(path.join(runDir, name)));
}

export function readArtifact(ws, id, sourceRunId, file) {
  if (!ARTIFACT_ALLOWLIST.includes(file)) return null;
  const runDir = findLatestRunDir(ws, id, sourceRunId);
  if (!runDir) return null;
  const full = path.join(runDir, file);
  const resolved = path.resolve(full);
  if (!resolved.startsWith(path.resolve(runDir) + path.sep)) return null;
  if (!fs.existsSync(resolved)) return null;
  return fs.readFileSync(resolved, 'utf8');
}

export { CliError };
