// MCP prompts: slash-command style entry points (for example /e3d-debate in VS Code) so a person does not have to
// know a tool's name. Each prompt only produces a message asking the agent to use a tool; it never runs anything.
const PROMPTS = [
  {
    name: 'e3d-debate',
    description: 'Get a multi-model second opinion on a decision (costs model credits).',
    arguments: [{ name: 'question', description: 'The decision or question, with context.', required: true }],
    tools: ['e3d_debate'],
    build: (a) => `Use the e3d_debate tool to get a multi-model second opinion on this question, then report the answer, the consensus level, any dissent, and any warnings exactly as the tool gives them (do not drop dissent or warnings when summarizing):\n\n${a.question ?? '(no question given: ask the user what to decide)'}`,
  },
  {
    name: 'e3d-propose',
    description: 'Record an idea in a repository\'s e3d-pilot ledger as proposed (free; a human approves it later).',
    arguments: [
      { name: 'repo', description: 'Absolute path to the repository.', required: true },
      { name: 'title', description: 'Short title.', required: true },
      { name: 'rationale', description: 'What to build and why.', required: true },
    ],
    tools: ['e3d_pilot_propose'],
    build: (a) => `Use the e3d_pilot_propose tool to record this idea as proposed. Do not approve it; a human approves it separately.\n\nRepository: ${a.repo ?? '(ask the user)'}\nTitle: ${a.title ?? '(ask the user)'}\nRationale: ${a.rationale ?? '(ask the user)'}`,
  },
  {
    name: 'e3d-budget',
    description: 'Show today\'s model-call budget and what is left (free).',
    arguments: [],
    tools: ['e3d_usage'],
    build: () => 'Use the e3d_usage tool and tell me how many model calls and estimated tokens are used and left today, and when the budget resets.',
  },
];

const visible = (allowed) => PROMPTS.filter((p) => !allowed || p.tools.every((t) => allowed.has(t)));

export function listPrompts(allowed) {
  return visible(allowed).map(({ name, description, arguments: args }) => ({ name, description, arguments: args }));
}

// Returns { description, messages }, null when the prompt is unknown or hidden from this connection, or { error } when a
// required argument is missing. Unknown arguments are ignored and every value is clipped, so a prompt cannot be used to
// smuggle in a large or unexpected payload.
export function getPrompt(name, args, allowed) {
  const p = visible(allowed).find((x) => x.name === name);
  if (!p) return null;
  const given = args && typeof args === 'object' && !Array.isArray(args) ? args : {};
  const a = Object.fromEntries(p.arguments.filter((d) => given[d.name] !== undefined && given[d.name] !== null).map((d) => [d.name, String(given[d.name]).slice(0, 4000)]));
  const missing = p.arguments.filter((d) => d.required && !String(a[d.name] ?? '').trim()).map((d) => d.name);
  if (missing.length) return { error: `missing required argument(s): ${missing.join(', ')}` };
  return { description: p.description, messages: [{ role: 'user', content: { type: 'text', text: p.build(a) } }] };
}
