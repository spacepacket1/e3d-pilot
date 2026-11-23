// Advisory scan of a skill's text for patterns aimed at the AGENT that will read it (docs/skills/phase1/adr/0015-mcp-first-skills.md, threat T24).
// Pure and local: no file, network or model. It NEVER refuses a skill and never changes one; it returns findings for a person (and the agent) to see. A skill that
// scans clean is not thereby safe, and a finding is not a verdict: the rules are plain patterns, they match words, not intent, and a determined author can
// avoid them (paraphrase, another language, an encoding). Only a person reading the text can judge it.
//
//   scanSkill(definition) -> { findings: [{ code, severity, where, message, excerpt }], clean: boolean, limit_note }
//
// severity: "warn" = the text asks the agent to do something that bypasses its user or its own safeguards; "notice" = worth a look (a link, a code block).
// Codes are lower-case `scan_*`, are never renamed or reused, and are listed in SCAN_RULES.

const clip = (s, n) => s.replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, n);

// [code, severity, regex, message]. Regexes are case-insensitive and tolerate any whitespace between words.
const R = (words) => new RegExp(words.replace(/ /g, '\\s+'), 'i');
export const SCAN_RULES = Object.freeze([
  ['scan_override', 'warn', R('(ignore|disregard|forget|override|bypass|discard) (all |any |every |the |your |these |those |previous |prior |above |earlier |system |safety )+(instructions?|rules|guidelines|prompts?|polic(y|ies)|restrictions|guardrails)'), 'asks the agent to ignore or override its instructions or rules'],
  ['scan_override', 'warn', R('(you are now|from now on you are|act as if you have no|pretend (that )?you (have|are) no)\\b.{0,60}(restrictions|rules|limits|filters|safeguards|instructions)'), 'asks the agent to drop its restrictions'],
  ['scan_override', 'warn', R('\\b(new|updated|real|actual) (system )?(prompt|instructions)\\s*:'), 'presents itself as new system instructions'],
  ['scan_override', 'warn', R('\\b(developer|god|admin|jailbreak|dan) mode\\b'), 'refers to a special unrestricted mode'],
  ['scan_concealment', 'warn', R('(do not|don\'t|never|without) (tell|inform|mention|reveal|show|notify|alert|ask) (to )?(the )?(user|human|operator|owner)'), 'asks the agent to hide something from its user or act without asking'],
  ['scan_concealment', 'warn', R('(keep|hide) (this|these|that|it) (a )?(secret|hidden|from the (user|human))'), 'asks the agent to keep something secret from its user'],
  ['scan_concealment', 'warn', R('without (asking|requesting|waiting for)( the user\'s| the user| any| their)?( for)? (permission|approval|confirmation|consent)'), 'asks the agent to act without confirmation'],
  ['scan_permission', 'warn', R('(disable|turn off|skip|bypass|remove|circumvent) (the |all |any |your )?(safety|security|sandbox|permission|confirmation|approval|guard|protection)s?( checks?| prompts?| mode| rules?)?'), 'asks the agent to weaken its own safeguards'],
  ['scan_permission', 'warn', R('(auto[- ]?approve|approve (all|everything)|allow all (tools|commands|actions)|bypasspermissions|--dangerously|dangerously[- ]skip)'), 'asks for blanket approval of actions'],
  ['scan_permission', 'warn', R('(you (have|are given|are granted) (full |unrestricted |root |admin )?(permission|access|authority|authori[sz]ation)|grant yourself|you are authori[sz]ed to)'), 'claims permissions the skill cannot grant'],
  ['scan_exec', 'warn', R('(curl|wget|iwr|invoke-webrequest)\\b[^\\n|]{0,200}\\|\\s*(sudo\\s+)?(ba|z|da)?sh\\b'), 'pipes a download into a shell'],
  ['scan_exec', 'warn', R('\\b(rm -rf|rm -fr|chmod (-r )?[0-7]*777|mkfs|dd if=|:\\(\\)\\s*\\{|sudo |eval\\(|powershell(\\.exe)? (-enc|-encodedcommand)|base64 (-d|--decode)[^\\n]{0,80}\\|)'), 'contains a destructive or obfuscated shell command'],
  ['scan_exec', 'warn', R('(run|execute|paste|type|invoke) (this|the following|these) (shell |terminal |bash |powershell |cmd )?(command|script|code|snippet)s?'), 'asks the agent to run a command'],
  ['scan_exfiltration', 'warn', R('(send|post|upload|forward|exfiltrate|transmit|leak|email|copy) .{0,80}(to|at|via) (https?://|an? (external|remote) (server|url|endpoint|address)|the following (url|address|server|endpoint))'), 'asks the agent to send data to an external address'],
  ['scan_exfiltration', 'warn', R('(~|\\$home|%userprofile%)?[/\\\\]?\\.(ssh|aws|gnupg|kube|docker|npmrc|netrc|pypirc)\\b|id_(rsa|ed25519)|/etc/(passwd|shadow)|\\.env\\b|credentials?\\.(json|ya?ml)'), 'mentions a credentials or secret file'],
  ['scan_credentials', 'notice', R('api[_ -]?keys?|secret[_ -]?keys?|private[_ -]?keys?|\\bpasswords?\\b|access[_ -]?tokens?'), 'mentions credentials (a lens about security may do so legitimately)'],
  ['scan_spoof', 'warn', R('(<\\|?(im_start|im_end|system|assistant|endoftext)\\|?>|\\[/?(inst|sys)\\]|<</?sys>>|^\\s*(system|assistant|developer)\\s*:|notice from (pilot|e3d|the system|anthropic|openai)|message from (pilot|the system|your (operator|developer)))'), 'imitates a system, role or Pilot message'],
  ['scan_encoded', 'notice', /[A-Za-z0-9+/]{200,}={0,2}/, 'contains a long encoded-looking block'],
  ['scan_encoded', 'notice', /\bdata:[a-z]+\/[a-z0-9.+-]+;base64,/i, 'contains an embedded data: URI'],
  ['scan_link', 'notice', /\bhttps?:\/\/[^\s)>\]"']+/i, 'contains a link (an agent that can browse may follow it)'],
  ['scan_codeblock', 'notice', /```\s*(bash|sh|zsh|shell|console|powershell|ps1|cmd|bat|python|py|node|js|javascript|ruby|perl)\b/i, 'contains a code block in a language an agent can run'],
]);

// the text fields a reader will see
const fieldsOf = (def) => [['description', def.description], ['instructions.method', def.instructions?.method], ...(def.instructions?.constraints ?? []).map((c, i) => [`instructions.constraints[${i}]`, c]), ['name', def.name]].filter(([, v]) => typeof v === 'string');

export function scanSkill(def) {
  const findings = [];
  const seen = new Set();
  for (const [where, text] of fieldsOf(def)) {
    for (const [code, severity, re, message] of SCAN_RULES) {
      const m = re.exec(text);
      if (!m) continue;
      const key = `${code}|${message}|${where}`;
      if (seen.has(key)) continue;
      seen.add(key);
      findings.push({ code, severity, where, message, excerpt: clip(m[0], 70) });
      if (findings.length >= 30) break;
    }
  }
  findings.sort((a, b) => (a.severity === b.severity ? 0 : a.severity === 'warn' ? -1 : 1));
  return { findings, clean: findings.length === 0, warn: findings.filter((f) => f.severity === 'warn').length, limit_note: 'Advisory only: a pattern scan matches words, not intent. No findings does not mean a skill is safe; findings do not mean it is harmful. Read the text.' };
}

// One line for a header or a list row. "scan: none" is not a safety claim; it states what the pattern scan found.
export const scanSummary = (s) => (s.clean ? 'scan: no patterns found' : `scan: ${s.warn ? `${s.warn} warning${s.warn === 1 ? '' : 's'}` : 'notices only'}${s.findings.length > s.warn ? `, ${s.findings.length - s.warn} notice${s.findings.length - s.warn === 1 ? '' : 's'}` : ''}`);
