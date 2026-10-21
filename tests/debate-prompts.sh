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

# --- experimental variants: v3b (rewritten rounds) and v3c (v3b + rewritten synthesis) ---
for v in v3b v3c; do
  rm -rf "$T/out-$v" "$T"/seen-* "$T"/count-*
  # stubs that answer in the v3 round-2 shape so the derived POSITION/status lines can be checked
  for n in alpha beta; do
    other=beta; [[ $n == beta ]] && other=alpha
    cat > "$T/lib/providers/$n" <<STUB
#!/usr/bin/env bash
cp "\$1" "$T/seen-$n-\$(grep -c . "$T/count-$n" 2>/dev/null || echo 0).md"
echo x >> "$T/count-$n"
printf 'VERDICT: x\nACTION: do the $n thing\nAGREES_WITH: $other\nCONFIDENCE: high\n'
STUB
  done
  env -u TYPESAFE_API_KEY "$T/bin/e3d-debate" "q?" --providers alpha,beta --rounds 2 --synthesizer synth --prompts "$v" --out-dir "$T/out-$v" > "$T/stdout" 2> "$T/stderr" || { cat "$T/stderr"; exit 1; }
  grep -q "^\*\*Prompt version:\*\* $v" "$T/out-$v/transcript.md" || { echo "FAIL: $v not stamped"; exit 1; }
  grep -q 'You are alpha, one of 2 analysts who will each answer independently' "$T/seen-alpha-0.md" || { echo "FAIL: $v round 1 prompt"; exit 1; }
  grep -q -- '--- YOU (your own previous answer' "$T/seen-alpha-1.md" || { echo "FAIL: $v own-answer label"; exit 1; }
  grep -q 'STEELMAN' "$T/seen-alpha-1.md" || { echo "FAIL: $v round 2 prompt"; exit 1; }
  grep -q '^status: approved' "$T/out-$v/transcript.md" || { echo "FAIL: $v derived status (mutual AGREES_WITH should be approved)"; exit 1; }
  grep -q '^POSITION: do the alpha thing' "$T/out-$v/transcript.md" || { echo "FAIL: $v derived POSITION"; exit 1; }
done

# v3c synthesis prompt: needs a debate that does not converge, otherwise the synthesizer is skipped
for n in alpha beta; do
  cat > "$T/lib/providers/$n" <<STUB
#!/usr/bin/env bash
printf 'VERDICT: x\nACTION: do the $n thing\nAGREES_WITH: none\nCONFIDENCE: low\n'
STUB
done
rm -f "$T/seen-synth.md"
env -u TYPESAFE_API_KEY "$T/bin/e3d-debate" "q?" --providers alpha,beta --rounds 2 --synthesizer synth --prompts v3c --out-dir "$T/out-split" > "$T/stdout" 2> "$T/stderr" || { cat "$T/stderr"; exit 1; }
grep -q '^status: revise' "$T/out-split/transcript.md" || { echo "FAIL: AGREES_WITH none should derive revise"; exit 1; }
grep -q 'You are the judge of a debate' "$T/seen-synth.md" || { echo "FAIL: v3c synthesis prompt not used"; exit 1; }
grep -q 'DISSENT must come before POSITIONS' "$T/seen-synth.md" || { echo "FAIL: v3c field order"; exit 1; }
if grep -q 'wrote at the same time, so a participant' "$T/seen-synth.md"; then echo "FAIL: v3c should use its own simultaneity text only"; exit 1; fi
echo "debate-prompts v3: ok"

# --- date and limits: every prompt (each round, each provider, the synthesizer) states today's UTC date and, with no web
# access, says so; the synthesizer is told to flag questions that need current data ---
NOWEB="You have no web access and your knowledge may be out of date. If the question depends on recent events or current data, say so and give your answer conditionally."
check_dates() { # <prompt files...>
  local f today; today="$(date -u +%Y-%m-%d)"
  for f in "$@"; do
    [[ -f "$f" ]] || { echo "FAIL: prompt not captured: $f"; exit 1; }
    head -1 "$f" | grep -qE "^Today's date \(UTC\): $today\.$" || { echo "FAIL: date line missing or wrong in $f: $(head -1 "$f")"; exit 1; }
    grep -qF "$NOWEB" "$f" || { echo "FAIL: no-web-access wording missing in $f"; exit 1; }
  done
}
for v in v2 v3c; do
  rm -rf "$T"/seen-* "$T"/count-*
  for n in alpha beta; do
    cat > "$T/lib/providers/$n" <<STUB
#!/usr/bin/env bash
cp "\$1" "$T/seen-$n-\$(grep -c . "$T/count-$n" 2>/dev/null || echo 0).md"
echo x >> "$T/count-$n"
printf 'Answer from $n.\nACTION: do the $n thing\nAGREES_WITH: none\nPOSITION: $n position\nstatus: revise\n'
STUB
  done
  env -u TYPESAFE_API_KEY "$T/bin/e3d-debate" "q?" --providers alpha,beta --rounds 2 --synthesizer synth --prompts "$v" --out-dir "$T/out-date-$v" > "$T/stdout" 2> "$T/stderr" || { cat "$T/stderr"; exit 1; }
  check_dates "$T/seen-alpha-0.md" "$T/seen-alpha-1.md" "$T/seen-beta-0.md" "$T/seen-beta-1.md" "$T/seen-synth.md"
  grep -qF 'say so plainly in FINAL ANSWER' "$T/seen-synth.md" || { echo "FAIL: $v synthesizer not told to flag missing current data"; exit 1; }
  # the rest of each prompt is unchanged: stripping the 3-line preamble leaves the original first line
  case "$v" in
    v2) [[ "$(sed -n 4p "$T/seen-alpha-0.md")" == "You are one of several AI models independently answering a question, before comparing notes with the others in later rounds." ]] || { echo "FAIL: v2 round-1 body changed"; exit 1; } ;;
    v3c) [[ "$(sed -n 4p "$T/seen-alpha-0.md")" == "You are alpha, one of 2 analysts who will each answer independently before seeing the others." ]] || { echo "FAIL: v3c round-1 body changed"; exit 1; } ;;
  esac
done
echo "debate-prompts date/limits: ok"
