// Deterministic source tiers for web-search citations. The tier says what KIND of source a domain is, not whether a claim is true:
//   primary      government, military, court or international-body sites, and the military's own news service
//   reputable    established news organisations and research outlets (a curated list, so it errs toward "unclassified")
//   low          user-generated platforms and blogging hosts: anyone can post there
//   unclassified everything else, including reference sites such as Wikipedia, company sites and unknown outlets
// A tier is a prompt for scrutiny, not a verdict. The list is deliberately short and public.

const PRIMARY_PATTERN = /(^|\.)(gov|mil|int)(\.[a-z]{2})?$/;
const PRIMARY_EXACT = ['dvidshub.net', 'europa.eu', 'sec.gov'];
const REPUTABLE = [
  'reuters.com', 'apnews.com', 'bbc.com', 'bbc.co.uk', 'nytimes.com', 'washingtonpost.com', 'wsj.com', 'ft.com', 'bloomberg.com',
  'cnn.com', 'nbcnews.com', 'cbsnews.com', 'abcnews.com', 'abcnews.go.com', 'npr.org', 'theguardian.com', 'aljazeera.com', 'euronews.com',
  'politico.com', 'axios.com', 'thehill.com', 'foxnews.com', 'foxbusiness.com', 'usatoday.com', 'cnbc.com', 'newsweek.com',
  'securityweek.com', 'bleepingcomputer.com', 'theregister.com', 'wired.com', 'arstechnica.com', 'theconversation.com',
  'nature.com', 'science.org', 'scientificamerican.com', 'defensenews.com', 'twz.com', 'stripes.com', 'airandspaceforces.com',
  'defensescoop.com', 'usnews.com', 'timesofisrael.com', 'wired.co.uk', 'economist.com', 'time.com', 'forbes.com', 'theverge.com',
];
const LOW = [
  'x.com', 'twitter.com', 'reddit.com', 'medium.com', 'substack.com', 'blogspot.com', 'wordpress.com', 'facebook.com', 'instagram.com',
  'youtube.com', 'youtu.be', 'tiktok.com', 't.me', 'telegram.org', 'quora.com', 'tumblr.com', 'linkedin.com', 'pinterest.com',
];

const onList = (host, list) => list.some((d) => host === d || host.endsWith(`.${d}`));

export function tierOfDomain(domain) {
  const host = String(domain ?? '').toLowerCase().replace(/^www\./, '');
  if (!host) return 'unclassified';
  if (PRIMARY_PATTERN.test(host) || onList(host, PRIMARY_EXACT)) return 'primary';
  if (onList(host, LOW)) return 'low';
  if (onList(host, REPUTABLE)) return 'reputable';
  return 'unclassified';
}

export function tierCounts(citations) {
  const counts = { primary: 0, reputable: 0, low: 0, unclassified: 0 };
  for (const c of citations ?? []) counts[tierOfDomain(c?.domain)] += 1;
  return counts;
}
