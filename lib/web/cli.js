import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// Every read and every mutation goes through the installed `e3d-pilot`
// binary on PATH -- the exact same entrypoint a human types at a terminal.
// This file never reimplements ledger logic (approval-digest checks,
// transition guards, etc.); it only shells out and parses/streams output.
// That keeps "one implementation, two front doors" true even more strictly
// than an in-process function call would.

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

export function listIdeas(repo, { status } = {}) {
  const args = ['ideas', 'list', '--repo', repo, '--json'];
  if (status) args.push('--status', status);
  return runJson(args);
}

export function showIdea(repo, id) {
  return runJson(['ideas', 'show', '--repo', repo, id, '--json']);
}

export function approveIdea(repo, id, actor, note) {
  const args = ['ideas', 'approve', '--repo', repo, id];
  if (actor) args.push('--actor', actor);
  if (note) args.push('--note', note);
  run(args);
}

export function rejectIdea(repo, id, reason, actor) {
  const args = ['ideas', 'reject', '--repo', repo, id, '--reason', reason];
  if (actor) args.push('--actor', actor);
  run(args);
}

export function requestChangesIdea(repo, id, reason, actor) {
  const args = ['ideas', 'request-changes', '--repo', repo, id, '--reason', reason];
  if (actor) args.push('--actor', actor);
  run(args);
}

export function approveMergeIdea(repo, id, actor, note) {
  const args = ['ideas', 'approve-merge', '--repo', repo, id];
  if (actor) args.push('--actor', actor);
  if (note) args.push('--note', note);
  run(args);
}

export function syncIdea(repo, id) {
  run(['ideas', 'sync', '--repo', repo, id]);
}

function ideaMarkerPath(repo, id, ext) {
  return path.join(repo, '.e3d-pilot', `web-implement-${id}.${ext}`);
}

// Spawns `ideas implement` detached so the HTTP request doesn't block for
// the ~30-40+ minute draft/negotiate/execute/review/publish pipeline. The
// pid+startedAt marker lets the detail page show "in progress since HH:MM"
// across page loads without the Node process itself needing to stay alive
// or track anything in memory.
export function implementIdea(repo, id) {
  const logPath = ideaMarkerPath(repo, id, 'log');
  const markerPath = ideaMarkerPath(repo, id, 'json');
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const logFd = fs.openSync(logPath, 'a');
  const child = spawn('e3d-pilot', ['ideas', 'implement', '--repo', repo, id], {
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

export function implementMarker(repo, id) {
  const markerPath = ideaMarkerPath(repo, id, 'json');
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
export function findLatestRunDir(repo, id, sourceRunId) {
  const runsRoot = path.join(repo, '.e3d-pilot', 'runs');
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

export function readImplementationLog(repo, id) {
  const runDir = findLatestRunDir(repo, id);
  if (!runDir) return null;
  const logFile = path.join(runDir, 'implementation-stage-log.md');
  if (!fs.existsSync(logFile)) return null;
  const content = fs.readFileSync(logFile, 'utf8');
  const MAX = 20000;
  return content.length > MAX ? `... (truncated, showing last ${MAX} chars)\n${content.slice(-MAX)}` : content;
}

const ARTIFACT_ALLOWLIST = ['findings.md', 'candidates.md', 'negotiation-log.md', 'spec-final.md'];

export function listAvailableArtifacts(repo, id, sourceRunId) {
  const runDir = findLatestRunDir(repo, id, sourceRunId);
  if (!runDir) return [];
  return ARTIFACT_ALLOWLIST.filter((name) => fs.existsSync(path.join(runDir, name)));
}

export function readArtifact(repo, id, sourceRunId, file) {
  if (!ARTIFACT_ALLOWLIST.includes(file)) return null;
  const runDir = findLatestRunDir(repo, id, sourceRunId);
  if (!runDir) return null;
  const full = path.join(runDir, file);
  const resolved = path.resolve(full);
  if (!resolved.startsWith(path.resolve(runDir) + path.sep)) return null;
  if (!fs.existsSync(resolved)) return null;
  return fs.readFileSync(resolved, 'utf8');
}

export { CliError };
