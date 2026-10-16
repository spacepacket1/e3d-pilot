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
];

export function redact(value) {
  if (typeof value !== 'string') return value;
  return PATTERNS.reduce((s, [re, rep]) => s.replace(re, rep), value);
}
