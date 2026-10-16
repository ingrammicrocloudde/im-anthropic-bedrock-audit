#!/usr/bin/env bash
#
# Unit / scenario tests for im-anthropic-bedrock-audit.sh
#
# Runs the audit script against a MOCK AWS CLI (no AWS account, no network,
# no cost) and checks output, exit codes and which AWS calls were made.
#
# Usage:
#   bash tests/test-im-anthropic-bedrock-audit.sh [path/to/im-anthropic-bedrock-audit.sh]
#
# Default script path: ../im-anthropic-bedrock-audit.sh relative to this file.
# Requirements: bash, awk, sed, grep, mkfifo. Optional: `script` (util-linux)
# for the terminal-confirmation test; it is skipped when not available.
# Exit code: 0 = all tests passed, 1 = one or more failures.
#

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${1:-$HERE/../im-anthropic-bedrock-audit.sh}"
[[ -f "$SCRIPT" ]] || { echo "Script not found: $SCRIPT" >&2; exit 1; }
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

T="$(mktemp -d "${TMPDIR:-/tmp}/im-audit-tests.XXXXXX")"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run"

PASS=0; FAIL=0; CURRENT=""

# ---------------------------------------------------------------------------
# Mock AWS CLI
#   State dir:  $MOCK_STATE (calls.log = every call, one per line)
#   Switches:   MOCK_ALL_OK=1     all agreements AVAILABLE, all quotas > 0
#               MOCK_AUTH_FAIL=1  Haiku 4.5 is NOT_AUTHORIZED
#   Region eu-west-3 always fails the model inventory (AccessDenied).
#   Models: Opus 5 (agreement), Sonnet 5 (private + public offer),
#           Haiku 4.5 (public offer only; create is denied),
#           Sonnet 4.5 (LEGACY), Fable 5 (offer only from the plain call;
#           runtime call needs a data-retention opt-in).
# ---------------------------------------------------------------------------
cat > "$T/bin/aws" <<'MOCK'
#!/usr/bin/env bash
a="$*"; ST="${MOCK_STATE:?}"; mkdir -p "$ST"
echo "$a" >> "$ST/calls.log"
reg=""; [[ "$a" =~ --region\ ([a-z0-9-]+) ]] && reg="${BASH_REMATCH[1]}"
mid=""; [[ "$a" =~ --model-id\ ([^ ]+) ]] && mid="${BASH_REMATCH[1]}"
case "$a" in
  --version) echo "aws-cli/2.0.0 mock";;
  *"configure list-profiles"*) echo default;;
  *"sts get-caller-identity"*"--query"*) printf '123456789012\tarn:aws:iam::123456789012:user/test\n';;
  *"sts get-caller-identity"*) echo '{}';;
  *"list-foundation-models"*)
     [[ "$reg" == eu-west-3 ]] && { echo "AccessDeniedException: denied in eu-west-3" >&2; exit 254; }
     printf 'Claude Opus 5\tanthropic.claude-opus-5-v1\tACTIVE\n'
     printf 'Claude Sonnet 5\tanthropic.claude-sonnet-5-v1\tACTIVE\n'
     printf 'Claude Haiku 4.5\tanthropic.claude-haiku-4-5-v1\tACTIVE\n'
     printf 'Claude Sonnet 4.5\tanthropic.claude-sonnet-4-5-v1\tLEGACY\n'
     printf 'Claude Fable 5\tanthropic.claude-fable-5-v1\tACTIVE\n';;
  *"list-inference-profiles"*)
     for m in opus-5 sonnet-5 haiku-4-5 sonnet-4-5 fable-5; do
       printf 'EU %s\teu.anthropic.claude-%s-v1\tACTIVE\n' "$m" "$m"
       printf 'GL %s\tglobal.anthropic.claude-%s-v1\tACTIVE\n' "$m" "$m"
     done;;
  *"get-use-case-for-model-access"*)
     if [[ -f "$ST/uc" || -n "${MOCK_ALL_OK:-}" ]]; then echo '{"formData":"eyJjb21wYW55TmFtZSI6IlgifQ=="}'
     else echo "ResourceNotFoundException: no use case" >&2; exit 254; fi;;
  *"put-use-case-for-model-access"*) f="${a#*fileb://}"; f="${f%% *}"; cp "$f" "$ST/uc";;
  *"cloudtrail"*) echo None;;
  *"get-foundation-model-availability"*)
     agr=NOT_AVAILABLE; aut=AUTHORIZED
     [[ $mid == *opus-5* || -f "$ST/agr-$mid" || -n "${MOCK_ALL_OK:-}" ]] && agr=AVAILABLE
     [[ $mid == *haiku* && -n "${MOCK_AUTH_FAIL:-}" ]] && aut=NOT_AUTHORIZED
     if [[ "$a" == *"--query agreementAvailability.status"* ]]; then echo "$agr"
     else printf '%s\t%s\tAVAILABLE\tAVAILABLE\n' "$agr" "$aut"; fi;;
  *"agreement-offers"*"PUBLIC"*)
     case $mid in *sonnet-5*) echo pub-s;; *haiku*) echo pub-h;; *sonnet-4-5*) echo pub-l;; esac;;
  *"agreement-offers"*"--offer-type ALL"*)
     case $mid in
       *sonnet-5*) printf 'pub-s\ttokPUBs\tNone\npriv-s\ttokPRIVs\thttps://legal/priv\n';;
       *haiku*) printf 'pub-h\ttokPUBh\tNone\n';;
       *sonnet-4-5*) printf 'pub-l\ttokL\tNone\n';;
     esac;;
  *"agreement-offers"*)
     case $mid in
       *sonnet-5*) printf 'pub-s\ttokPUBs\tNone\n';;
       *haiku*) printf 'pub-h\ttokPUBh\tNone\n';;
       *fable*) printf 'fab\ttokFAB\thttps://legal/fab\n';;
       *sonnet-4-5*) printf 'pub-l\ttokL\tNone\n';;
     esac;;
  *"create-foundation-model-agreement"*)
     [[ "$a" == *tokPUBh* ]] && { echo "AccessDeniedException: not authorized" >&2; exit 254; }
     touch "$ST/agr-$mid";;
  *"list-service-quotas"*)
     q(){ v="$3"; [[ -n "${MOCK_ALL_OK:-}" ]] && v=10000000.0; [[ -f "$ST/q-$1" ]] && v="$(cat "$ST/q-$1")"; printf '%s\t%s\t%s\n' "$1" "$2" "$v"; }
     q L-OPUS "Cross-region model inference tokens per minute for Anthropic Claude Opus 5" 2000000.0
     q L-OPR  "Cross-region model inference requests per minute for Anthropic Claude Opus 5" 0.0
     q L-SON5 "Cross-region model inference tokens per minute for Anthropic Claude Sonnet 5" 0.0
     q L-SONR "Cross-region model inference requests per minute for Anthropic Claude Sonnet 5" 0.0
     q L-HAI  "Cross-region model inference tokens per minute for Anthropic Claude Haiku 4.5" 0.0
     q L-HAIG "Global cross-region model inference tokens per minute for Anthropic Claude Haiku 4.5" 0.0
     q L-FAB  "Cross-region model inference tokens per minute for Anthropic Claude Fable 5" 0.0
     q L-LEG  "Cross-region model inference tokens per minute for Anthropic Claude Sonnet 4.5" 0.0;;
  *"list-aws-default-service-quotas"*)
     for c in L-OPUS L-SON5 L-HAI L-HAIG L-FAB L-LEG; do printf '%s\t10000000.0\n' "$c"; done
     printf 'L-SONR\t2000.0\nL-OPR\t2000.0\nL-OTHER\t5.0\n';;
  *"get-aws-default-service-quota"*) echo "per-quota default call must not be used" >&2; exit 1;;
  *"list-requested-service-quota-change-history"*)
     printf 'L-SONR\tCross-region model inference requests per minute for Anthropic Claude Sonnet 5\t2000.0\tPENDING\tcase-1\t2026-10-10T10:00:00+02:00\n';;
  *"request-service-quota-increase"*)
     c=""; [[ "$a" =~ --quota-code\ ([^ ]+) ]] && c="${BASH_REMATCH[1]}"
     dv=""; [[ "$a" =~ --desired-value\ ([^ ]+) ]] && dv="${BASH_REMATCH[1]}"
     def=10000000; [[ $c == L-SONR || $c == L-OPR ]] && def=2000
     # Real AWS: a value below the default is refused. MOCK_STRICT_GT=1 also
     # refuses a value equal to the default.
     if awk -v v="$dv" -v d="$def" -v s="${MOCK_STRICT_GT:-}" 'BEGIN { exit !(v+0 < d+0 || (s != "" && v+0 == d+0)) }'; then
       echo "An error occurred (IllegalArgumentException) when calling the RequestServiceQuotaIncrease operation: You must provide a quota value greater than the default quota value." >&2; exit 254
     fi
     if [[ $c == L-SON5 ]]; then echo "$dv" > "$ST/q-$c"; printf 'APPROVED\tNone\treq-1\n'
     else printf 'PENDING\tNone\treq-2\n'; fi;;
  *"converse"*)
     [[ $mid == *fable* ]] && { echo "ValidationException: data retention mode required for this model" >&2; exit 254; }
     echo '{}';;
  *) exit 0;;
esac
MOCK
chmod +x "$T/bin/aws"

# Same use case file for every run that needs one.
cat > "$T/run/usecase.json" <<'JSON'
{"companyName":"Test B.V.","companyWebsite":"https://example.com","intendedUsers":"0","industryOption":"Technology","otherIndustryOption":"","useCases":"Internal assistant for employees"}
JSON

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# run_audit <name> [env assignments...] -- [script args...]
# Leaves output in $OUTF, exit code in $RC, calls in $CALLS.
run_audit(){
  local name="$1"; shift
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  export MOCK_STATE="$T/state-$name"; rm -rf "$MOCK_STATE"; mkdir -p "$MOCK_STATE"
  OUTF="$T/out-$name.txt"; CALLS="$MOCK_STATE/calls.log"; : > "$CALLS"
  ( cd "$T/run" && env PATH="$T/bin:$PATH" IM_AUDIT_POLL_SECONDS=0 ${envs[@]+"${envs[@]}"} \
      bash "$SCRIPT" --profile default "$@" < /dev/null > "$OUTF" 2>&1 )
  RC=$?
}

begin(){ CURRENT="$1"; }
ok(){ PASS=$((PASS+1)); printf "  PASS  %s: %s\n" "$CURRENT" "$1"; }
ko(){ FAIL=$((FAIL+1)); printf "  FAIL  %s: %s\n" "$CURRENT" "$1"; }

assert_rc(){ [[ "$RC" -eq "$1" ]] && ok "exit code $1" || ko "exit code $1 expected, got $RC"; }
assert_out(){ grep -qE -- "$1" "$OUTF" && ok "${2:-output contains /$1/}" || ko "${2:-output contains /$1/}"; }
assert_not_out(){ grep -qE -- "$1" "$OUTF" && ko "${2:-output lacks /$1/}" || ok "${2:-output lacks /$1/}"; }
assert_call(){ grep -qE -- "$1" "$CALLS" && ok "${2:-call made: /$1/}" || ko "${2:-call made: /$1/}"; }
assert_no_call(){ grep -qE -- "$1" "$CALLS" && ko "${2:-no call: /$1/}" || ok "${2:-no call: /$1/}"; }
count_calls(){ grep -cE -- "$1" "$CALLS"; }

echo "Testing: $SCRIPT"
echo

# ---------------------------------------------------------------------------
# 1. Static checks
# ---------------------------------------------------------------------------
begin "static"
bash -n "$SCRIPT" && ok "bash -n syntax check" || ko "bash -n syntax check"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning -e SC2034,SC2155 "$SCRIPT" >/dev/null && ok "shellcheck (warnings)" || ko "shellcheck (warnings)"
else
  echo "  SKIP  static: shellcheck not installed"
fi

# ---------------------------------------------------------------------------
# 2. Help and argument validation
# ---------------------------------------------------------------------------
begin "args"
OUTF="$T/out-help.txt"; bash "$SCRIPT" --help > "$OUTF" 2>&1; RC=$?
assert_rc 0; assert_out "Usage:" "help shows usage"; assert_out "Exit codes" "help documents exit codes"
for bad in "--quota-scope x" "--parallel 0" "--quota-value -5" "--bogus" "--use-case-file /nonexistent.json"; do
  # shellcheck disable=SC2086
  bash "$SCRIPT" $bad > "$T/out-bad.txt" 2>&1; rc=$?
  [[ $rc -eq 1 ]] && ok "rejects '$bad' (exit 1)" || ko "rejects '$bad' (exit 1, got $rc)"
done

# ---------------------------------------------------------------------------
# 3. Read-only run (default)
# ---------------------------------------------------------------------------
begin "read-only"
run_audit ro --
assert_rc 2
assert_no_call "create-foundation-model-agreement|put-use-case|request-service-quota-increase|converse" \
  "makes no changes and invokes no model"
assert_no_call "get-aws-default-service-quota " "no per-quota default calls (opt. 1)"
n="$(wc -l < "$CALLS" | tr -d ' ')"
[[ "$n" -le 16 ]] && ok "total AWS calls <= 16 (got $n) (opt. 1-2)" || ko "total AWS calls <= 16 (got $n)"
[[ "$(count_calls 'list-foundation-models')" -eq 1 ]] && ok "model list fetched once (opt. 2)" || ko "model list fetched once"
[[ "$(count_calls 'list-service-quotas')" -eq 1 ]] && ok "quota list fetched once (opt. 2)" || ko "quota list fetched once"
[[ "$(count_calls 'list-requested-service-quota-change-history')" -eq 1 ]] && ok "quota history fetched once (opt. 2)" || ko "quota history fetched once"
assert_out "Mode: +read-only" "mode shows read-only"
assert_out "L-OPUS +Actual: 2000000 +Default: 10000000 +Scope: EU" "quota joined with default, .0 stripped"
assert_out "L-HAIG .*Scope: GLOBAL" "global quota scope detected"
assert_out "LEGACY skipped: Claude Sonnet 4.5" "LEGACY skipped for agreements (opt. 10)"
assert_out "L-SONR .*OPEN-REQ" "open quota request detected from history"
assert_out "L-SON5 .*NO-AGREEMENT" "quota of model without agreement not requestable (opt. 11)"
assert_out "L-LEG .*LEGACY" "quota of LEGACY model skipped (opt. 10)"
assert_not_out "L-HAIG .*(CANDIDATE|NO-AGREEMENT)" "global quota out of default scope 'eu' (opt. 11)"
assert_out "Claude Opus 5 +ACTIVE +READY +2000000 .* OK" "usable model has status OK"
assert_out "Claude Sonnet 5 .*ISSUE \(AGREEMENT\)" "model without agreement is ISSUE"
assert_out "Result: +ISSUES FOUND \(exit code 2\)" "summary verdict (opt. 12)"
REPORT="$(ls "$T/run"/IM_Bedrock_Audit_Partner_Customer_123456789012_*.txt 2>/dev/null | head -n 1)"
if [[ -n "$REPORT" ]]; then
  ok "report file written"
  tail -n 3 "$REPORT" | grep -q "Please send this report file" && ok "report is complete up to the last line (opt. 8)" \
    || ko "report is complete up to the last line"
  rm -f "$T/run"/IM_Bedrock_Audit_*.txt
else
  ko "report file written"
fi

# ---------------------------------------------------------------------------
# 4. RESULT lists every failing check (opt. 6)
# ---------------------------------------------------------------------------
begin "result-reasons"
run_audit auth MOCK_AUTH_FAIL=1 --
assert_out "Claude Haiku 4.5 .*NOT_AUTHORIZED .*AGREEMENT\+AUTH" "RESULT shows AGREEMENT+AUTH"
rm -f "$T/run"/IM_Bedrock_Audit_*.txt

# ---------------------------------------------------------------------------
# 5. Parallel and sequential give the same availability table (opt. 4)
# ---------------------------------------------------------------------------
begin "parallel"
run_audit par1 -- --parallel 1
sed -n '/\[5\/10\]/,/\[6\/10\]/p' "$OUTF" > "$T/avail-seq.txt"
run_audit par6 -- --parallel 6
sed -n '/\[5\/10\]/,/\[6\/10\]/p' "$OUTF" > "$T/avail-par.txt"
cmp -s "$T/avail-seq.txt" "$T/avail-par.txt" && ok "identical tables for --parallel 1 and 6" \
  || ko "identical tables for --parallel 1 and 6"
rm -f "$T/run"/IM_Bedrock_Audit_*.txt

# ---------------------------------------------------------------------------
# 6. Full change run over three regions (one failing)
# ---------------------------------------------------------------------------
begin "full-run"
run_audit full -- --region eu-central-1,eu-west-3,eu-west-1 --use-case-file usecase.json \
  --request-agreement --request-quota --invoke --yes
assert_rc 3
assert_out "REGION: eu-central-1" "region 1 audited (opt. 13)"
assert_out "REGION: eu-west-1" "region 3 audited (opt. 13)"
assert_out "\[FAIL\] list-foundation-models failed; region skipped" "failing region reported, not silent (opt. 5)"
assert_out "Result: +INCOMPLETE" "API error gives INCOMPLETE / exit 3 (opt. 12)"
# Use case
assert_call "put-use-case-for-model-access --form-data fileb://" "use case submitted as fileb://"
[[ "$(count_calls 'get-use-case-for-model-access')" -le 2 ]] && ok "use case checked once (account-wide) (opt. 13)" \
  || ko "use case checked once (account-wide)"
# Agreements
assert_call "create-foundation-model-agreement --model-id anthropic.claude-sonnet-5-v1 --offer-token tokPRIVs" \
  "private offer preferred over public"
assert_call "create-foundation-model-agreement --model-id anthropic.claude-fable-5-v1 --offer-token tokFAB" \
  "offer from the plain list call is used"
assert_no_call "create-foundation-model-agreement --model-id anthropic.claude-sonnet-4-5" "LEGACY model not requested (opt. 10)"
assert_out "Claude Haiku 4.5 +PUBLIC +FAILED" "failed agreement is reported"
assert_out "AccessDenied: the caller needs bedrock:CreateFoundationModelAgreement" "permission hint shown"
assert_out "Waiting for agreement activation \(max ~60s for all models\)" "agreements polled together (opt. 3)"
assert_out "Availability after the requests:" "availability refreshed after requests (opt. 7)"
# Quotas
assert_call "request-service-quota-increase --service-code bedrock --quota-code L-SON5 --desired-value 10000000 " \
  "quota requested at the AWS default (tokens/min)"
assert_call "quota-code L-OPR --desired-value 2000 " "quota requested at the AWS default (requests/min)"
assert_out "quotas: 3 requested, 0 failed" "all quota requests accepted"
assert_call "quota-code L-FAB" "quota requested for model with new agreement"
assert_no_call "request-service-quota-increase .*L-(HAI|HAIG|SONR|LEG) " "no requests for no-agreement / open / legacy / global quotas (opt. 11)"
# Order and runtime test
s8="$(grep -n '\[8/10\] MODEL AGREEMENT REQUESTS (eu-central-1)' "$OUTF" | cut -d: -f1)"
s10="$(grep -n '\[10/10\] RUNTIME TEST AND MODEL STATUS (eu-central-1)' "$OUTF" | cut -d: -f1)"
[[ -n "$s8" && -n "$s10" && "$s8" -lt "$s10" ]] && ok "requests run before the runtime test (opt. 7)" \
  || ko "requests run before the runtime test"
assert_out "Claude Sonnet 5 +ACTIVE +READY +10000000 .*EU:OK +OK" "approved quota used by the test (opt. 7)"
assert_out "Claude Fable 5 .*ISSUE \(QUOTA0\)" "pending quota still reported as issue"
rm -f "$T/run"/IM_Bedrock_Audit_*.txt

# ---------------------------------------------------------------------------
# 7. --private-only and --include-legacy
# ---------------------------------------------------------------------------
begin "offer-options"
run_audit priv -- --request-agreement --private-only --include-legacy --yes
assert_out "Claude Haiku 4.5 .*PUB-ONLY" "public-only offer marked PUB-ONLY"
assert_no_call "create-foundation-model-agreement --model-id anthropic.claude-haiku" "public-only offer not requested"
assert_out "Claude Sonnet 4.5 +LEGACY .*PUB-ONLY" "LEGACY included with --include-legacy (opt. 10)"
rm -f "$T/run"/IM_Bedrock_Audit_*.txt

# ---------------------------------------------------------------------------
# 8. Quota scope and value
# ---------------------------------------------------------------------------
begin "quota-scope"
run_audit qscope -- --quota-scope global
assert_out "L-HAIG +GLOBAL" "global quota listed with --quota-scope global"
assert_not_out "L-HAI +EU " "EU quota excluded with --quota-scope global"
run_audit qglobal -- --global
assert_out "scope 'all'" "--global widens default scope to all"
run_audit qvalue -- --request-agreement --request-quota --quota-value 500000 --yes
assert_call "quota-code L-OPR --desired-value 500000 " "--quota-value above the default is used"
assert_call "quota-code L-SON5 --desired-value 10000000 " "--quota-value below the default is raised to the default"
assert_no_call "quota-code L-SON5 --desired-value 500000" "no request below the default is sent"
run_audit strict MOCK_STRICT_GT=1 -- --request-agreement --request-quota --yes
assert_call "quota-code L-SON5 --desired-value 10000001 " "retries with default + 1 when AWS demands more than the default"
assert_out "AWS requires more than the default \(10000000\); retrying with 10000001" "retry is reported"
assert_out "quotas: 3 requested, 0 failed" "retried requests succeed"
rm -f "$T/run"/IM_Bedrock_Audit_*.txt

# ---------------------------------------------------------------------------
# 9. Everything usable -> exit 0; data-retention test failure -> exit 2
# ---------------------------------------------------------------------------
begin "exit-codes"
run_audit allok MOCK_ALL_OK=1 --
assert_rc 0
assert_out "Result: +ALL ACTIVE MODELS USABLE \(exit code 0\)" "all usable gives exit 0 (opt. 12)"
run_audit retention MOCK_ALL_OK=1 -- --invoke
assert_rc 2
assert_out "Claude Fable 5 .*EU:RETENTION-REQ +ISSUE \(TEST\)" "failed runtime test is an ISSUE"
assert_out "Note \(RETENTION-REQ\)" "retention note printed"
rm -f "$T/run"/IM_Bedrock_Audit_*.txt

# ---------------------------------------------------------------------------
# 10. Non-interactive without --yes requests nothing
# ---------------------------------------------------------------------------
begin "non-interactive"
run_audit noyes -- --request-agreement --request-quota --submit-use-case
assert_no_call "create-foundation-model-agreement|request-service-quota-increase|put-use-case" "nothing changed without --yes"
assert_out "Non-interactive session without --yes: no agreement was requested" "explains why nothing was requested"
rm -f "$T/run"/IM_Bedrock_Audit_*.txt

# ---------------------------------------------------------------------------
# 11. Terminal: --yes asks one confirmation up front; 'n' = read-only (opt. 9)
# ---------------------------------------------------------------------------
begin "confirmation"
if command -v script >/dev/null 2>&1 && script -qc true /dev/null >/dev/null 2>&1; then
  export MOCK_STATE="$T/state-tty"; rm -rf "$MOCK_STATE"; mkdir -p "$MOCK_STATE"
  OUTF="$T/out-tty.txt"; CALLS="$MOCK_STATE/calls.log"; : > "$CALLS"
  ( cd "$T/run" && (sleep 2; printf 'n\n'; sleep 3; printf '\n\n\n') | \
      env PATH="$T/bin:$PATH" IM_AUDIT_POLL_SECONDS=0 \
      script -qc "bash '$SCRIPT' --profile default --request-agreement --request-quota --yes" /dev/null \
      > "$OUTF" 2>&1 )
  assert_out "Continue\? \[y/N\]" "asks one confirmation up front"
  assert_out "Not confirmed: continuing READ-ONLY" "declining switches to read-only"
  assert_no_call "create-foundation-model-agreement|request-service-quota-increase" "no changes after declining"
  # Prompts must appear after all output that precedes them (report flushed first).
  lr="$(grep -n 'Result: ' "$OUTF" | tail -n 1 | cut -d: -f1)"
  lp="$(grep -n 'Partner name' "$OUTF" | tail -n 1 | cut -d: -f1)"
  [[ -n "$lr" && -n "$lp" && "$lr" -lt "$lp" ]] && ok "summary is printed before the report-naming prompt" \
    || ko "summary is printed before the report-naming prompt"
  lm="$(grep -n 'Mode: ' "$OUTF" | head -n 1 | cut -d: -f1)"
  lc="$(grep -n 'Continue?' "$OUTF" | head -n 1 | cut -d: -f1)"
  [[ -n "$lm" && -n "$lc" && "$lm" -lt "$lc" ]] && ok "account details are printed before the confirmation prompt" \
    || ko "account details are printed before the confirmation prompt"
  rm -f "$T/run"/IM_Bedrock_Audit_*.txt
else
  echo "  SKIP  confirmation: 'script' (pseudo-terminal) not available"
fi

# ---------------------------------------------------------------------------
echo
echo "Result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
