// Secret redaction for anything the MCP server logs or returns (log tails, stderr, job output).
// Mirrors the patterns in lib/training/export.sh (training_redact_expr), plus bearer tokens and
// common provider key shapes, so one policy applies to both.
const PATTERNS = [
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, '[REDACTED]'],
  [/\bsk-[A-Za-z0-9_-]{16,}/g, '[REDACTED]'],
  [/\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}/g, '[REDACTED]'],
  [/\bAIza[0-9A-Za-z_-]{30,}/g, '[REDACTED]'],
  [/\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/gi, 'Bearer [REDACTED]'],
  [/((?:api[_-]?key|token|secret|password|authorization)["']?\s*[:=]\s*["']?)[^"'\s,}]+/gi, '$1[REDACTED]'],
  // Named secrets that do not end in one of the words above: AWS_SECRET_ACCESS_KEY=..., access_key, private_key, client_secret.
  // (Not a bare "key", and not "tokens: 12": token COUNTS stay readable.)
  [/((?:secret[_-]?access[_-]?key|secret[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|session[_-]?key)["']?\s*[:=]\s*["']?)[^"'\s,}]+/gi, '$1[REDACTED]'],
  // Credentials inside a URL: scheme://user:password@host (postgres, mongodb, redis, https...): keep the user and host, hide the password.
  [/(\b[a-z][a-z0-9+.-]*:\/\/[^\s/:@]*:)[^\s/]*(@)/gi, '$1[REDACTED]$2'],
  // Provider key shapes seen in logs: AWS access key ids, Stripe, our own keys and tokens, Slack, xAI.
  [/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/g, '[REDACTED]'],
  [/\b(?:sk|rk|pk)_(?:test|live)_[A-Za-z0-9]{8,}/g, '[REDACTED]'],
  [/\bwhsec_[A-Za-z0-9+/=_-]{8,}/g, '[REDACTED]'],
  [/\be3d_(?:pilot|pat|prt|pac)_[A-Za-z0-9_-]{8,}/g, '[REDACTED]'],
  [/\bxox[abprs]-[A-Za-z0-9-]{10,}/g, '[REDACTED]'],
  [/\bxai-[A-Za-z0-9]{20,}/g, '[REDACTED]'],
];

export function redact(value) {
  if (typeof value !== 'string') return value;
  return PATTERNS.reduce((s, [re, rep]) => s.replace(re, rep), value);
}
