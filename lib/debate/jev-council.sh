#!/usr/bin/env bash
# Jev council signal, Phase 1 (docs/jev-council.md, issue #66). SHADOW ONLY: sourced by bin/e3d-debate when
# --jev-propositions is given. It asks Jev (TypeSafe System One, a typed non-generative judge) about explicit
# yes/no statements BEFORE round 1, never shows the answer to any model, and changes no output. Every failure
# is "no signal", never a guess.
#
# Input: a JSON file, an array of {"id": "p1", "text": "<statement>", "negation": "<optional plain-language opposite>"}.
# The statements are supplied by the caller: no model writes them, so there is no framing call and no framing bias
# from a vendor model. Giving a negation turns on a polarity check (a statement and its opposite should land on
# opposite sides).
#
# Output (jev_council_run): a JSON artifact with, per statement, the raw Noul values as Jev returned them, whether
# the pair was consistent, a combined value and a band. The thresholds below are PROVISIONAL, chosen from a 10-debate
# replay (docs/jev-council.md), and must be recalibrated against outcomes. Noul is not a calibrated probability.

JEV_COUNCIL_MAX_PROPOSITIONS=5
JEV_COUNCIL_MAX_TEXT_CHARS=500
JEV_COUNCIL_DECISIVE_HI="0.7"
JEV_COUNCIL_DECISIVE_LO="0.3"

# jev_council_validate <file>: prints the problem on stderr and returns 1 when the file cannot be used.
jev_council_validate() {
  local f="$1" err
  [[ -n "$f" && -f "$f" ]] || { echo "error: --jev-propositions: file not found: ${f:-<empty>}" >&2; return 1; }
  err="$(jq -r --argjson max "$JEV_COUNCIL_MAX_PROPOSITIONS" --argjson maxc "$JEV_COUNCIL_MAX_TEXT_CHARS" '
    def nonempty: type == "string" and (gsub("\\s"; "") | length) > 0;
    if type != "array" then "must be a JSON array of {id, text, negation?}"
    elif length < 1 or length > $max then "must hold 1 to \($max) statements"
    elif any(.[]; type != "object") then "every entry must be an object"
    elif any(.[]; (.id // "") | (type != "string" or (test("^[a-z0-9_-]{1,32}$") | not))) then "every id must match [a-z0-9_-]{1,32}"
    elif (map(.id) | unique | length) != length then "ids must be unique"
    elif any(.[]; (.text // null) | (nonempty | not)) then "every entry needs a non-empty text"
    elif any(.[]; (.text | length) > $maxc) then "text is limited to \($maxc) characters"
    elif any(.[]; has("negation") and ((.negation | nonempty | not) or (.negation | length) > $maxc)) then "negation, when given, must be non-empty text of at most \($maxc) characters"
    else empty end' "$f" 2>/dev/null)" || { echo "error: --jev-propositions: $f is not valid JSON" >&2; return 1; }
  [[ -z "$err" ]] || { echo "error: --jev-propositions: $err" >&2; return 1; }
}

# jev_council_ask <question> <statement>: prints one JSON line {noul, model, input, output}; returns 1 on any failure.
jev_council_ask() {
  local question="$1" statement="$2" state qs resp out
  state="$(jq -ncS --arg q "$question" --arg s "$statement" '{question:$q, statement:$s}')" || return 1
  qs="$(jq -ncS '{p: {type: "noul",
    instructions: "Read the question and the statement. Given the question and the context it provides, is the statement the right position to take? Judge the statement on its merits.",
    criteria: {"true": "The statement is the right position to take.", "false": "The statement is not the right position to take."}}}')" || return 1
  resp="$(jev_call "jev-latest" "$state" "$qs")" || return 1
  out="$(jq -c '{noul: .answers.p.noul, model: (.model // null), input: (.usage.input_tokens // 0), output: (.usage.output_tokens // 0)}
    | select((.noul | type) == "number" and .noul >= 0 and .noul <= 1)' <<< "$resp" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# jev_council_run <question> <propositions-file> <out-file>
# Writes the artifact to <out-file>. Always returns 0: a missing key, a vendor failure or a malformed response gives
# status "no_signal" (or "partial") and the debate carries on unchanged.
jev_council_run() {
  local question="$1" file="$2" out="$3" n i id text neg p_line n_line p_json n_json recs="[]" rec calls=0 tin=0 tout=0 model="" ok=0 total
  n="$(jq 'length' "$file")"
  for ((i = 0; i < n; i++)); do
    id="$(jq -r ".[$i].id" "$file")"; text="$(jq -r ".[$i].text" "$file")"; neg="$(jq -r ".[$i].negation // empty" "$file")"
    p_json=null; n_json=null
    calls=$((calls + 1))
    if p_line="$(jev_council_ask "$question" "$text")"; then
      p_json="$(jq -c .noul <<< "$p_line")"; model="$(jq -r '.model // empty' <<< "$p_line")"
      tin=$((tin + $(jq -r .input <<< "$p_line"))); tout=$((tout + $(jq -r .output <<< "$p_line")))
    fi
    if [[ -n "$neg" ]]; then
      calls=$((calls + 1))
      if n_line="$(jev_council_ask "$question" "$neg")"; then
        n_json="$(jq -c .noul <<< "$n_line")"
        tin=$((tin + $(jq -r .input <<< "$n_line"))); tout=$((tout + $(jq -r .output <<< "$n_line")))
      fi
    fi
    rec="$(jq -nc --arg id "$id" --arg text "$text" --arg neg "$neg" --argjson p "$p_json" --argjson n "$n_json" \
      --argjson hi "$JEV_COUNCIL_DECISIVE_HI" --argjson lo "$JEV_COUNCIL_DECISIVE_LO" '
      def r3: if . == null then null else ((. * 1000) | round) / 1000 end;
      def band($c): if $c == null then "no_signal" elif $c >= $hi then "decisive_yes" elif $c <= $lo then "decisive_no" else "undecided" end;
      ($neg != "") as $paired
      | (if $p == null then null elif ($paired | not) then $p elif $n == null then null else (($p + (1 - $n)) / 2) end) as $combined
      | (if $paired and $p != null and $n != null then (($p > 0.5) != ($n > 0.5)) else null end) as $consistent
      | {id: $id, text: $text} + (if $paired then {negation: $neg} else {} end)
      + {noul: ({statement: ($p | r3)} + (if $paired then {negation: ($n | r3)} else {} end)),
         basis: (if $paired then "paired" else "single" end), consistent: $consistent, combined: ($combined | r3),
         band: (if $consistent == false then "undecided" else band($combined) end)}')" || rec=""
    [[ -z "$rec" ]] || recs="$(jq -c --argjson r "$rec" '. + [$r]' <<< "$recs")"
  done
  total="$(jq 'length' <<< "$recs")"
  ok="$(jq '[.[] | select(.band != "no_signal")] | length' <<< "$recs")"
  jq -n --argjson recs "$recs" --arg model "$model" --argjson calls "$calls" --argjson tin "$tin" --argjson tout "$tout" \
    --argjson hi "$JEV_COUNCIL_DECISIVE_HI" --argjson lo "$JEV_COUNCIL_DECISIVE_LO" --argjson ok "$ok" --argjson total "$total" '
    {schema: 1, status: (if $total == 0 or $ok == 0 then "no_signal" elif $ok < $total then "partial" else "ok" end),
     mode: "shadow", hidden_from_models: true, framing: "supplied",
     model: (if $model == "" then null else $model end),
     score_semantics: "noul as returned by Jev; not a calibrated probability",
     thresholds: {decisive_yes_at_or_above: $hi, decisive_no_at_or_below: $lo, provisional: true},
     usage: {calls: $calls, input_tokens: $tin, output_tokens: $tout},
     propositions: $recs}' > "$out" 2>/dev/null || return 0
  return 0
}

# jev_council_skipped <out-file> <status> <reason>: writes a minimal artifact when no Jev call was made.
jev_council_skipped() {
  local out="$1" status="$2" reason="$3"
  jq -n --arg status "$status" --arg reason "$reason" \
    '{schema: 1, status: $status, mode: "shadow", hidden_from_models: true, reason: $reason, propositions: []}' > "$out" 2>/dev/null || true
}

# jev_council_log_summary <artifact>: a one-line object with NO statement text, for the decision log.
jev_council_log_summary() {
  jq -c '{status, mode, propositions: (.propositions | length),
          bands: ([.propositions[].band] | group_by(.) | map({(.[0]): length}) | add // {})}' "$1" 2>/dev/null || echo null
}

# jev_council_transcript_line <artifact>: the labelled record line for transcript.md (never the prompt copy).
jev_council_transcript_line() {
  jq -r '"**Jev council signal (shadow, hidden from the models, informational only):** " +
    (if .status == "ok" or .status == "partial" then
       ([.propositions[] | .id + ": " + .band + (if .consistent == false then " (statement and negation disagree)" else "" end)] | join("; "))
     else (.status + (if .reason then " (" + .reason + ")" else "" end)) end) + ".\n"' "$1" 2>/dev/null
}
