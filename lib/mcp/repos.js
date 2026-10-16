// Which repositories the pipeline tools may operate on.
// Allowed = E3D_MCP_REPOS (':'-separated) + the client's workspace roots (MCP roots/list) + the server's
// own working directory when neither of those exists. A requested repo must be a git repository's top
// level and, after resolving symlinks, lie inside an allowed root; symlink escapes are therefore rejected.
import { realpath } from 'node:fs/promises';
import { delimiter, isAbsolute, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from './util.js';

export function createRepoGuard({ env = process.env, cwd = process.cwd() } = {}) {
  let clientRoots = [];

  const real = async (p) => { try { return await realpath(p); } catch { return null; } };

  async function allowedRoots() {
    const roots = [];
    for (const p of (env.E3D_MCP_REPOS || '').split(delimiter).filter(Boolean)) roots.push(resolve(p));
    roots.push(...clientRoots);
    if (!roots.length) {
      const top = await run('git', ['rev-parse', '--show-toplevel'], { cwd, timeoutMs: 10000 });
      if (top.code === 0 && top.out.trim()) roots.push(top.out.trim());
    }
    return (await Promise.all(roots.map(real))).filter(Boolean);
  }

  return {
    setClientRoots(uris) {
      clientRoots = (uris || []).map((u) => { try { return u.startsWith('file:') ? fileURLToPath(u) : u; } catch { return null; } }).filter(Boolean);
    },
    allowedRoots,
    // Returns the real path of an acceptable repo, or throws an Error whose message says how to fix it.
    async resolveRepo(path) {
      if (typeof path !== 'string' || !path || !isAbsolute(path)) throw new Error('`repo` must be an absolute path to a git repository');
      const repo = await real(path);
      if (!repo) throw new Error(`repo not found: ${path}`);
      const roots = await allowedRoots();
      if (!roots.length) throw new Error('no repositories are allowed yet: set E3D_MCP_REPOS to a ":"-separated list of repo paths in the MCP server config, or open a workspace folder');
      const inside = roots.some((root) => { const rel = relative(root, repo); return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel)); });
      if (!inside) throw new Error(`repo is outside the allowed roots (${roots.join(', ')}); set E3D_MCP_REPOS to allow it`);
      const top = await run('git', ['-C', repo, 'rev-parse', '--show-toplevel'], { timeoutMs: 10000 });
      if (top.code !== 0 || (await real(top.out.trim())) !== repo) throw new Error(`not the top level of a git repository: ${repo}`);
      return repo;
    },
  };
}
