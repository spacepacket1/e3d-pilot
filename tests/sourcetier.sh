#!/usr/bin/env bash
set -euo pipefail

# lib/mcp/sourcetier.js: deterministic tiers for citation domains. No model calls, no network.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --input-type=module - "$ROOT" <<'EOF2'
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
const { tierOfDomain, tierCounts } = await import(pathToFileURL(join(process.argv[2], 'lib/mcp/sourcetier.js')).href);
const ok = (m) => console.log(`ok - ${m}`);

for (const d of ['transportation.gov', 'www.faa.gov', 'sec.gov', 'www.gov.uk', 'army.mil', 'www.un.org'.replace('un.org', 'who.int'), 'dvidshub.net', 'ec.europa.eu']) assert.equal(tierOfDomain(d), 'primary', d);
ok('government, military, international-body and military-news domains are primary');
for (const d of ['reuters.com', 'www.cnn.com', 'abcnews.com', 'securityweek.com', 'www.euronews.com', 'nature.com']) assert.equal(tierOfDomain(d), 'reputable', d);
ok('established news and research outlets are reputable');
for (const d of ['x.com', 'mobile.twitter.com', 'old.reddit.com', 'medium.com', 'someone.substack.com', 'foo.blogspot.com', 'youtube.com', 't.me']) assert.equal(tierOfDomain(d), 'low', d);
ok('user-generated platforms are low');
for (const d of ['en.wikipedia.org', 'lunanotes.io', 'investor.nvidia.com', 'example.org', '', undefined, null]) assert.equal(tierOfDomain(d), 'unclassified', String(d));
ok('everything else, including wikipedia, company sites and empty input, is unclassified');
// a look-alike must not inherit a tier from a suffix
for (const d of ['notreuters.com', 'reuters.com.evil.example', 'fakegov.example', 'x.com.evil.example']) assert.equal(tierOfDomain(d), 'unclassified', d);
ok('look-alike domains do not inherit a tier');
assert.deepEqual(tierCounts([{ domain: 'faa.gov' }, { domain: 'cnn.com' }, { domain: 'cnn.com' }, { domain: 'x.com' }, { domain: 'foo.example' }, null]), { primary: 1, reputable: 2, low: 1, unclassified: 2 });
assert.deepEqual(tierCounts([]), { primary: 0, reputable: 0, low: 0, unclassified: 0 }); assert.deepEqual(tierCounts(undefined), { primary: 0, reputable: 0, low: 0, unclassified: 0 });
ok('tierCounts');
EOF2
echo "sourcetier: all passed"
