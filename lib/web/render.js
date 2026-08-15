export function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (char) => {
    switch (char) {
      case '&':
        return '&amp;';
      case '<':
        return '&lt;';
      case '>':
        return '&gt;';
      case '"':
        return '&quot;';
      default:
        return '&#39;';
    }
  });
}

const STYLE = `
  body { font-family: -apple-system, system-ui, sans-serif; max-width: 960px; margin: 2rem auto; padding: 0 1rem; color: #1a1a1a; }
  nav a { margin-right: 1rem; }
  table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
  th, td { text-align: left; padding: 0.4rem 0.6rem; border-bottom: 1px solid #ddd; font-size: 0.9rem; vertical-align: top; }
  form.inline { display: inline-block; margin-right: 0.5rem; }
  fieldset { margin: 1rem 0; }
  .error { color: #b00020; }
  .info { color: #0a6b2f; }
  .badge { display: inline-block; padding: 0.1rem 0.5rem; border-radius: 0.3rem; background: #eee; font-size: 0.8rem; }
  .badge.proposed { background: #fff3cd; }
  .badge.approved_for_implementation, .badge.approved_for_merge { background: #d4edda; }
  .badge.implementing { background: #cce5ff; }
  .badge.implemented, .badge.merged { background: #d1e7dd; }
  .badge.rejected, .badge.implementation_failed, .badge.merge_failed { background: #f8d7da; }
  .muted { color: #666; font-size: 0.85rem; }
  pre.log { background: #111; color: #ddd; padding: 0.75rem; overflow-x: auto; max-height: 24rem; font-size: 0.8rem; }
  .field { margin: 0.5rem 0; }
  .field dt { font-weight: 600; }
  .field dd { margin: 0 0 0.5rem 0; }
`;

export function renderPage(title, bodyHtml) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${escapeHtml(title)} - e3d-pilot</title>
<style>${STYLE}</style>
</head>
<body>
<nav><a href="/ideas">Ideas</a></nav>
<h1>${escapeHtml(title)}</h1>
${bodyHtml}
</body>
</html>`;
}

function statusBadge(status) {
  return `<span class="badge ${escapeHtml(status)}">${escapeHtml(status)}</span>`;
}

function csrfField(csrfToken) {
  return `<input type="hidden" name="_csrf" value="${escapeHtml(csrfToken)}">`;
}

export function renderIdeasList(rows, filters, repoAliases) {
  const repoOptions = repoAliases
    .map((a) => `<option value="${escapeHtml(a)}" ${filters.repo === a ? 'selected' : ''}>${escapeHtml(a)}</option>`)
    .join('');

  const tableRows = rows
    .map(
      (r) => `<tr>
        <td>${escapeHtml(r.repoAlias)}</td>
        <td><a href="/ideas/${encodeURIComponent(r.repoAlias)}/${encodeURIComponent(r.idea_id)}">${escapeHtml(r.title)}</a></td>
        <td>${statusBadge(r.status)}</td>
        <td>${escapeHtml(r.scores?.attraction ?? '-')} / ${escapeHtml(r.scores?.retention ?? '-')}</td>
        <td class="muted">${escapeHtml((r.updated_at || '').slice(0, 10))}</td>
      </tr>`
    )
    .join('\n');

  return `
<form method="get" action="/ideas">
  <label>Repo <select name="repo"><option value="">(all)</option>${repoOptions}</select></label>
  <label>Status <input type="text" name="status" value="${escapeHtml(filters.status ?? '')}" placeholder="e.g. proposed"></label>
  <button type="submit">Filter</button>
</form>
<table>
  <thead><tr><th>Repo</th><th>Title</th><th>Status</th><th>Attr/Ret</th><th>Updated</th></tr></thead>
  <tbody>${tableRows || '<tr><td colspan="5">No ideas found.</td></tr>'}</tbody>
</table>`;
}

function renderEvents(events) {
  if (!Array.isArray(events) || events.length === 0) return '<p class="muted">No events.</p>';
  const items = events
    .map(
      (e) =>
        `<li>${escapeHtml(e.occurred_at || e.created_at || '')} &mdash; <strong>${escapeHtml(e.event || e.type)}</strong> actor=${escapeHtml(e.actor ?? '-')}${e.note ? ` &mdash; ${escapeHtml(e.note)}` : ''}</li>`
    )
    .join('\n');
  return `<ol>${items}</ol>`;
}

function actionForm(action, label, csrfToken, { confirmText, extraFields = '', buttonClass = '' } = {}) {
  const confirmAttr = confirmText ? ` onsubmit="return confirm(${JSON.stringify(confirmText)})"` : '';
  return `<form class="inline" method="post" action="${escapeHtml(action)}"${confirmAttr}>
    ${csrfField(csrfToken)}
    ${extraFields}
    <button type="submit" class="${buttonClass}">${escapeHtml(label)}</button>
  </form>`;
}

export function renderIdeaDetail(idea, repoAlias, { csrfToken, error, info, logTail, marker, artifacts = [] } = {}) {
  const base = `/ideas/${encodeURIComponent(repoAlias)}/${encodeURIComponent(idea.idea_id)}`;
  const messages = `${error ? `<p class="error">${escapeHtml(error)}</p>` : ''}${info ? `<p class="info">${escapeHtml(info)}</p>` : ''}`;

  const fields = `
<dl class="field">
  <dt>Status</dt><dd>${statusBadge(idea.status)}</dd>
  <dt>Repo</dt><dd>${escapeHtml(repoAlias)} (${escapeHtml(idea.workspace_path ?? '')})</dd>
  <dt>Summary</dt><dd>${escapeHtml(idea.summary)}</dd>
  <dt>Category</dt><dd>${escapeHtml(idea.category)}</dd>
  <dt>Scores</dt><dd>attraction=${escapeHtml(idea.scores?.attraction ?? '-')} retention=${escapeHtml(idea.scores?.retention ?? '-')} revenue=${escapeHtml(idea.scores?.revenue ?? '-')} effort=${escapeHtml(idea.scores?.effort ?? '-')}</dd>
  <dt>Analogy</dt><dd>${escapeHtml(idea.analogy ?? '-')}</dd>
  <dt>Dedup rationale</dt><dd>${escapeHtml(idea.dedup_rationale ?? '-')}</dd>
  <dt>Implementation approval</dt><dd>${idea.implementation_approval ? `${escapeHtml(idea.implementation_approval.actor)} at ${escapeHtml(idea.implementation_approval.approved_at)}` : '<span class="muted">none</span>'}</dd>
  <dt>Merge approval</dt><dd>${idea.merge_approval ? `${escapeHtml(idea.merge_approval.actor)} at ${escapeHtml(idea.merge_approval.approved_at)}` : '<span class="muted">none</span>'}</dd>
</dl>`;

  const actions = [];
  if (idea.status === 'proposed') {
    actions.push(actionForm(`${base}/approve`, 'Approve implementation', csrfToken));
    actions.push(actionForm(
      `${base}/reject`,
      'Reject',
      csrfToken,
      { confirmText: 'Reject this idea?', extraFields: '<input type="text" name="reason" placeholder="reason" required>' }
    ));
  }
  if (['implemented', 'approved_for_merge', 'partially_merged', 'merge_failed'].includes(idea.status)) {
    actions.push(actionForm(`${base}/approve-merge`, 'Approve merge', csrfToken));
  }
  if (idea.status === 'implemented') {
    actions.push(actionForm(
      `${base}/request-changes`,
      'Request changes',
      csrfToken,
      { extraFields: '<input type="text" name="reason" placeholder="reason" required>' }
    ));
  }
  if (['approved_for_implementation', 'changes_requested', 'implementation_failed'].includes(idea.status)) {
    const running = marker?.running;
    actions.push(
      running
        ? '<span class="muted">implement already running</span>'
        : actionForm(`${base}/implement`, 'Implement', csrfToken, {
            confirmText: 'Kick off draft/negotiate/execute/review/publish? This can take 30-40+ minutes.'
          })
    );
  }
  actions.push(actionForm(`${base}/sync`, 'Sync forge state', csrfToken));

  const artifactLinks = artifacts.length
    ? `<ul>${artifacts.map((f) => `<li><a href="${base}/artifact/${encodeURIComponent(f)}">${escapeHtml(f)}</a></li>`).join('')}</ul>`
    : '<p class="muted">No run artifacts yet.</p>';

  const progressBlock =
    idea.status === 'implementing'
      ? `<h2>Implementation progress</h2>
${marker ? `<p class="muted">started ${escapeHtml(marker.startedAt)}${marker.running ? '' : ' (process no longer running)'}</p>` : ''}
<pre class="log" id="log">${escapeHtml(logTail || 'No log yet.')}</pre>
<script>
setInterval(function () {
  fetch(window.location.pathname + '/log').then(function (r) { return r.text(); }).then(function (t) {
    document.getElementById('log').textContent = t;
  });
}, 4000);
</script>`
      : '';

  return `
${messages}
${fields}
<h2>Actions</h2>
${actions.join('\n')}
${progressBlock}
<h2>Run artifacts</h2>
${artifactLinks}
<h2>Event history</h2>
${renderEvents(idea.events)}
`;
}
