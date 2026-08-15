import http from 'node:http';
import path from 'node:path';
import { URL } from 'node:url';
import { loadWebCredentials, checkBasicAuth } from './auth.js';
import { generateCsrfToken, csrfCookieHeader, verifyCsrf, parseCookies, CSRF_COOKIE_NAME } from './csrf.js';
import {
  listIdeas,
  showIdea,
  approveIdea,
  rejectIdea,
  requestChangesIdea,
  approveMergeIdea,
  syncIdea,
  implementIdea,
  implementMarker,
  readImplementationLog,
  listAvailableArtifacts,
  readArtifact,
  CliError
} from './cli.js';
import { renderPage, renderIdeasList, renderIdeaDetail, escapeHtml } from './render.js';

const MAX_BODY_BYTES = 1_000_000;

function parseArgs(argv) {
  let port = 4173;
  const repos = [];
  let i = 0;
  while (i < argv.length) {
    if (argv[i] === '--port') {
      port = Number(argv[i + 1]);
      i += 2;
    } else if (argv[i] === '--') {
      i += 1;
    } else {
      repos.push(argv[i]);
      i += 1;
    }
  }
  return { port, repos };
}

function buildRepoAliases(repos) {
  const aliasToRepo = new Map();
  const used = new Set();
  for (const repo of repos) {
    let alias = path.basename(repo) || 'repo';
    let candidate = alias;
    let n = 2;
    while (used.has(candidate)) {
      candidate = `${alias}-${n}`;
      n += 1;
    }
    used.add(candidate);
    aliasToRepo.set(candidate, repo);
  }
  return aliasToRepo;
}

async function readRequestBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      throw new Error('Request body too large');
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

async function parseFormBody(req) {
  const contentType = req.headers['content-type'] ?? '';
  if (!contentType.includes('application/x-www-form-urlencoded')) {
    return new URLSearchParams();
  }
  const body = await readRequestBody(req);
  return new URLSearchParams(body);
}

function ensureCsrfCookie(req, res) {
  const cookies = parseCookies(req.headers.cookie);
  let token = cookies[CSRF_COOKIE_NAME];
  if (!token) {
    token = generateCsrfToken();
    res.setHeader('Set-Cookie', csrfCookieHeader(token));
  }
  return token;
}

function sendHtml(res, status, html) {
  res.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(html);
}

function sendText(res, status, text) {
  res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(text);
}

function notFound(res) {
  sendHtml(res, 404, renderPage('Not found', '<p>Not found.</p>'));
}

async function requireCsrf(req, res) {
  const form = await parseFormBody(req);
  if (!verifyCsrf(req, form.get('_csrf'))) {
    sendHtml(res, 403, renderPage('Forbidden', '<p class="error">CSRF validation failed.</p>'));
    return null;
  }
  return form;
}

function actorFromRequest(req) {
  const header = req.headers['authorization'];
  if (typeof header !== 'string' || !header.startsWith('Basic ')) return 'web';
  try {
    const decoded = Buffer.from(header.slice('Basic '.length), 'base64').toString('utf8');
    return decoded.split(':')[0] || 'web';
  } catch {
    return 'web';
  }
}

function handleIdeasList(req, res, aliasToRepo, url) {
  const repoFilter = url.searchParams.get('repo') || undefined;
  const status = url.searchParams.get('status') || undefined;
  const rows = [];
  for (const [alias, repo] of aliasToRepo) {
    if (repoFilter && repoFilter !== alias) continue;
    let ideas;
    try {
      ideas = listIdeas(repo, { status });
    } catch (error) {
      rows.push({
        repoAlias: alias,
        idea_id: '',
        title: `error listing ${alias}: ${error.message}`,
        status: 'error',
        scores: {},
        updated_at: ''
      });
      continue;
    }
    for (const idea of ideas) {
      rows.push({ ...idea, repoAlias: alias });
    }
  }
  rows.sort((a, b) => (b.updated_at || '').localeCompare(a.updated_at || ''));
  sendHtml(
    res,
    200,
    renderPage('Ideas', renderIdeasList(rows, { repo: repoFilter, status }, [...aliasToRepo.keys()]))
  );
}

function handleIdeaDetail(req, res, aliasToRepo, repoAlias, id, options = {}) {
  const repo = aliasToRepo.get(repoAlias);
  if (!repo) return notFound(res);
  let idea;
  try {
    idea = showIdea(repo, id);
  } catch {
    return notFound(res);
  }
  const marker = implementMarker(repo, id);
  const artifacts = listAvailableArtifacts(repo, id, idea.source_run_id);
  const logTail = idea.status === 'implementing' ? readImplementationLog(repo, id) : null;
  const csrfToken = ensureCsrfCookie(req, res);
  sendHtml(
    res,
    options.error ? 400 : 200,
    renderPage(
      idea.title,
      renderIdeaDetail(idea, repoAlias, {
        csrfToken,
        error: options.error,
        info: options.info,
        marker,
        artifacts,
        logTail
      })
    )
  );
}

async function handleMutation(req, res, aliasToRepo, repoAlias, id, action) {
  const repo = aliasToRepo.get(repoAlias);
  if (!repo) return notFound(res);
  const form = await requireCsrf(req, res);
  if (!form) return;
  const actor = actorFromRequest(req);

  try {
    switch (action) {
      case 'approve':
        approveIdea(repo, id, actor);
        break;
      case 'reject':
        rejectIdea(repo, id, form.get('reason') || '(no reason given)', actor);
        break;
      case 'request-changes':
        requestChangesIdea(repo, id, form.get('reason') || '(no reason given)', actor);
        break;
      case 'approve-merge':
        approveMergeIdea(repo, id, actor);
        break;
      case 'sync':
        syncIdea(repo, id);
        break;
      case 'implement':
        implementIdea(repo, id);
        break;
      default:
        return notFound(res);
    }
  } catch (error) {
    const message = error instanceof CliError ? error.message : error.message;
    return handleIdeaDetail(req, res, aliasToRepo, repoAlias, id, { error: message });
  }

  res.writeHead(302, { Location: `/ideas/${encodeURIComponent(repoAlias)}/${encodeURIComponent(id)}` });
  res.end();
}

export function createRequestListener({ repos, credentials }) {
  const aliasToRepo = buildRepoAliases(repos);

  return async function requestListener(req, res) {
    try {
      if (!checkBasicAuth(req, credentials)) {
        res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="e3d-pilot"', 'Content-Type': 'text/plain' });
        res.end('Authentication required');
        return;
      }

      const url = new URL(req.url, 'http://localhost');
      const segments = url.pathname.split('/').filter(Boolean);

      if (req.method === 'GET' && segments.length === 0) {
        res.writeHead(302, { Location: '/ideas' });
        res.end();
        return;
      }

      if (req.method === 'GET' && segments[0] === 'ideas' && segments.length === 1) {
        return handleIdeasList(req, res, aliasToRepo, url);
      }
      if (req.method === 'GET' && segments[0] === 'ideas' && segments.length === 3) {
        return handleIdeaDetail(req, res, aliasToRepo, segments[1], segments[2]);
      }
      if (req.method === 'GET' && segments[0] === 'ideas' && segments.length === 4 && segments[3] === 'log') {
        const repo = aliasToRepo.get(segments[1]);
        if (!repo) return notFound(res);
        return sendText(res, 200, readImplementationLog(repo, segments[2]) || 'No log yet.');
      }
      if (
        req.method === 'GET' &&
        segments[0] === 'ideas' &&
        segments.length === 5 &&
        segments[3] === 'artifact'
      ) {
        const repo = aliasToRepo.get(segments[1]);
        if (!repo) return notFound(res);
        let sourceRunId;
        try {
          sourceRunId = showIdea(repo, segments[2]).source_run_id;
        } catch {
          return notFound(res);
        }
        const content = readArtifact(repo, segments[2], sourceRunId, segments[4]);
        if (content === null) return notFound(res);
        return sendText(res, 200, content);
      }
      if (
        req.method === 'POST' &&
        segments[0] === 'ideas' &&
        segments.length === 4 &&
        ['approve', 'reject', 'request-changes', 'approve-merge', 'sync', 'implement'].includes(segments[3])
      ) {
        return await handleMutation(req, res, aliasToRepo, segments[1], segments[2], segments[3]);
      }

      notFound(res);
    } catch (error) {
      if (error.message === 'Request body too large') {
        sendHtml(res, 400, renderPage('Bad request', `<p class="error">${escapeHtml(error.message)}</p>`));
        return;
      }
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end(`Internal error: ${error.message}`);
    }
  };
}

function main() {
  const { port, repos } = parseArgs(process.argv.slice(2));
  if (repos.length === 0) {
    process.stderr.write('error: e3d-pilot web requires at least one repo path\n');
    process.exit(1);
  }
  let credentials;
  try {
    credentials = loadWebCredentials();
  } catch (error) {
    process.stderr.write(`error: ${error.message}\n`);
    process.exit(1);
  }
  const listener = createRequestListener({ repos, credentials });
  const server = http.createServer(listener);
  server.listen(port, () => {
    process.stdout.write(`e3d-pilot web listening on http://127.0.0.1:${port} (${repos.length} repo(s))\n`);
  });
}

main();
