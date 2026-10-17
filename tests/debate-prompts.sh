#!/usr/bin/env bash
# e3d-debate prompt v2: a speaker sees its own prior answer labelled YOU (not as a peer), rounds are
# stated to be simultaneous, and the transcript records the prompt version.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/lib/providers"
cp "$ROOT/bin/e3d-debate" "$T/bin/"
cp "$ROOT/lib/providers/jev.sh" "$ROOT/lib/providers/common.sh" "$T/lib/providers/"
for n in alpha beta; do
  cat > "$T/lib/providers/$n" <<STUB
#!/usr/bin/env bash
cp "\$1" "$T/seen-$n-\$(grep -c . "$T/count-$n" 2>/dev/null || echo 0).md"
echo x >> "$T/count-$n"
printf 'Answer from $n.\nPOSITION: $n position\nstatus: revise\n'
STUB
  chmod +x "$T/lib/providers/$n"
done
cat > "$T/lib/providers/synth" <<STUB
#!/usr/bin/env bash
cp "\$1" "$T/seen-synth.md"
printf 'FINAL ANSWER: ok\nCONSENSUS: split\nDISSENT: none\n'
STUB
chmod +x "$T/lib/providers/synth"

env -u TYPESAFE_API_KEY "$T/bin/e3d-debate" "q?" --providers alpha,beta --rounds 2 --synthesizer synth --out-dir "$T/out" > "$T/stdout" 2> "$T/stderr" || { cat "$T/stderr"; exit 1; }

r2="$T/seen-alpha-1.md"
[[ -f "$r2" ]] || { echo "FAIL: no round-2 prompt captured"; ls "$T"; exit 1; }
grep -q -- '--- YOU (your own answer in the previous round) ---' "$r2" || { echo "FAIL: own answer not labelled YOU"; exit 1; }
grep -q -- '--- beta (previous round) ---' "$r2" || { echo "FAIL: peer answer missing"; exit 1; }
if grep -q -- '--- alpha (previous round) ---' "$r2"; then echo "FAIL: speaker still sees its own answer labelled as a peer"; exit 1; fi
grep -q 'at the same time' "$r2" || { echo "FAIL: simultaneity not stated in round 2"; exit 1; }
grep -q 'wrote at the same time' "$T/seen-synth.md" || { echo "FAIL: simultaneity not stated to synthesizer"; exit 1; }
grep -q '^\*\*Prompt version:\*\* v2' "$T/out/transcript.md" || { echo "FAIL: prompt version missing from transcript"; exit 1; }
echo "debate-prompts: ok"
