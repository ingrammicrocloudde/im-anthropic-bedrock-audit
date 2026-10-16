#!/usr/bin/env bash
# CloudShell compatibility: if invoked with `sh script.sh`, re-run in Bash.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# Ingram Micro Amazon Bedrock Audit Script
# Investigates missing Anthropic model access or quota problems despite an
# Anthropic reselling agreement provided by Ingram Micro.
#
# Copyright (c) 2026 Tobias Tomandl / Ingram Micro
# Extended by inQdo (v0.22): use case submission, agreement and quota
# requests, multi-region, parallel checks, summary and exit codes.
# Version: 0.22
#
# Behavior:
# - Read-only by default. Nothing is changed and no model is invoked unless
#   the matching option is passed.
# - Runs per region (--region accepts a comma-separated list). Per region:
#     [2] model inventory        [6] runtime quotas
#     [3] inference profiles     [7] quota request history
#     [4] use case (account)     [8] agreement requests   (--request-agreement)
#     [5] model availability     [9] quota increases      (--request-quota)
#                                [10] runtime test        (--invoke)
#   Requests ([8], [9]) run BEFORE the runtime test, so the test sees the
#   state after the requests.
# - --submit-use-case: submits the Anthropic use case (FTU) if none exists.
# - --request-agreement: creates model agreements with the offer token from
#   ListFoundationModelAgreementOffers (private / reseller offer preferred).
#   LEGACY models are skipped unless --include-legacy.
# - --request-quota: requests the quota's AWS default value (or --quota-value N,
#   never below that default; AWS rejects lower values) for
#   Anthropic runtime quotas at 0, only for models that have an agreement.
#   Scope follows the test scope (EU/regional; Global with --global), or
#   --quota-scope eu|global|all.
# - Ends with a summary per region and model, and an exit code:
#     0 = every ACTIVE model is usable, 2 = issues found,
#     3 = audit incomplete (AWS API errors), 1 = fatal error / usage.
# - Produces EXACTLY ONE output file: the complete terminal transcript as the
#   report. All intermediate data is kept in a temporary directory and removed
#   on exit.
#

set -u
export AWS_PAGER=""

VERSION="0.22"
PROFILE=""
REGIONS_ARG="eu-central-1"
INVOKE="false"
TEST_GLOBAL="false"
REQUEST_AGREEMENT="false"
PRIVATE_ONLY="false"
INCLUDE_LEGACY="false"
SUBMIT_USE_CASE="false"
USE_CASE_FILE=""
REQUEST_QUOTA="false"
QUOTA_VALUE=""          # empty = the quota's AWS default value
QUOTA_SCOPE=""          # eu | global | all ; empty = follows --global
AUTO_YES="false"
PARALLEL=6
# Poll interval (seconds) while waiting for agreement activation. Overridable
# for tests via IM_AUDIT_POLL_SECONDS.
POLL_SECONDS="${IM_AUDIT_POLL_SECONDS:-5}"

PARTNER=""
CUSTOMER=""

usage() {
cat <<EOF
Ingram Micro Amazon Bedrock Audit Script v${VERSION}

Usage:
  $0 [--profile NAME] [--region R1[,R2,...]] [--invoke] [--global]
     [--submit-use-case [--use-case-file FILE]]
     [--request-agreement [--private-only] [--include-legacy]]
     [--request-quota [--quota-value N] [--quota-scope eu|global|all]]
     [--yes] [--parallel N]

Audit options (read-only):
  --profile NAME       AWS CLI profile. If omitted, current CloudShell/session
                       credentials are offered first, then named profiles.
  --region R1,R2       One or more regions, comma-separated.
                       Default: eu-central-1
  --invoke             Runtime test: a minimal model call (max 8 tokens) per
                       usable model. Creates minimal Bedrock usage/cost.
  --global             With --invoke, also test Global inference profiles.
                       Also widens the default --quota-scope to 'all'.
  --parallel N         Parallel AWS calls for availability and offer lookups.
                       Default 6; 1 = sequential.

Change options (each CHANGES the account; off by default):
  --submit-use-case    If no Anthropic use case (FTU) exists, submit one
                       (PutUseCaseForModelAccess). Fields are asked
                       interactively and confirmed separately.
  --use-case-file FILE Read the use case from a JSON file (implies
                       --submit-use-case):
                       {"companyName":"..","companyWebsite":"https://..",
                        "intendedUsers":"0","industryOption":"Technology",
                        "otherIndustryOption":"","useCases":".."}
                       intendedUsers: 0=Internal, 1=External, 2=Both.
  --request-agreement  Create model agreements for models whose agreement is
                       NOT_AVAILABLE or ERROR (interactive selection).
  --private-only       With --request-agreement: only accept private offers
                       (e.g. Ingram Micro reselling).
  --include-legacy     With --request-agreement / --request-quota: also
                       include LEGACY models (skipped by default).
  --request-quota      Request a quota increase for Anthropic runtime quotas
                       at 0 (AWS default > 0) of models with an agreement.
  --quota-value N      Request N instead of the AWS default. AWS refuses values
                       below the default; those are raised to the default.
  --quota-scope S      eu (EU/regional, default), global or all.
                       Default is 'all' when --global is passed.

Confirmation:
  --yes                No interactive selection: request everything for the
                       change options you passed. In a terminal, you confirm
                       the list of changes once at the start.

Exit codes:
  0 every ACTIVE model is usable   2 issues found
  3 audit incomplete (API errors)  1 fatal error / usage

  -h, --help           Show help.
EOF
}

die(){ echo "ERROR: $*" >&2; exit 1; }

short(){
  local s="${1:-}" n="${2:-70}"
  [[ ${#s} -gt $n ]] && printf "%s..." "${s:0:$n}" || printf "%s" "$s"
}

num_gt_zero(){
  local v="${1:-0}"
  [[ "$v" != "-" && "$v" != "None" && "$v" != "null" && -n "$v" ]] || return 1
  awk -v x="$v" 'BEGIN { exit !(x+0 > 0) }'
}

# "10000000.0" -> "10000000"
strip0(){ printf "%s" "${1:-}" | sed -E 's/\.0+$//'; }

# One-line, shortened error text from a file.
err_text(){ short "$(tr '\n' ' ' < "$1" 2>/dev/null | sed 's/[[:space:]][[:space:]]*/ /g;s/^ //;s/ $//')" "${2:-180}"; }

safe_name(){
  printf "%s" "$1" | tr ' ' '_' | tr -cd '[:alnum:]_.-'
}

json_escape(){
  printf '%s' "$1" | tr '\t' ' ' | tr -d '\r\n' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Quota value for a model in a scope. Exact model-name boundary, so
# "Claude Sonnet 4" never matches "Claude Sonnet 4.5".
# Args: <scope-prefix-regex> <model-name> <quota-tsv: CODE NAME ACTUAL DEF>
quota_value_for_model(){
  awk -F'\t' -v scope="$1" -v name="$2" '
    BEGIN { lname=tolower(name) }
    {
      q=$2; lq=tolower(q)
      if (q !~ scope) next
      pos=index(lq,lname); if (pos==0) next
      nextc=substr(lq,pos+length(lname),1)
      if (nextc=="" || nextc !~ /[0-9.]/) { print $3; exit }
    }' "$3"
}

# Scope of a quota by its name: GLOBAL, or EU (cross-region EU / regional).
quota_scope_of(){
  case "$1" in
    Global*) printf "GLOBAL" ;;
    *) printf "EU" ;;
  esac
}

# AWS CLI wrapper. No empty arrays (macOS Bash 3.2 + set -u).
awsx() {
  if [[ -n "${PROFILE:-}" ]]; then
    command aws --profile "$PROFILE" "$@"
  else
    command aws "$@"
  fi
}

# Run an AWS call into a file; stderr into <file>.err. Drops "None" lines.
# Returns the AWS CLI exit code. Usage: aws_fetch <outfile> <aws args...>
aws_fetch(){
  local out="$1"; shift
  awsx "$@" > "$out.raw" 2> "$out.err" < /dev/null
  local rc=$?
  grep -v '^None$' "$out.raw" | sed '/^[[:space:]]*$/d' > "$out" 2>/dev/null
  rm -f "$out.raw"
  return $rc
}

# Mark the audit as incomplete (exit code 3) and print a FAIL line.
api_fail(){
  API_ERRORS=$((API_ERRORS+1))
  echo "  [FAIL] $1"
  [[ -n "${2:-}" && -s "$2" ]] && echo "         $(err_text "$2")"
}

# --- Parallel helper (Bash 3.2: no `wait -n`; waits on explicit PIDs only,
#     never on the tee process that writes the report). ---
BG_PIDS=""; BG_N=0
bg_run(){
  "$@" &
  BG_PIDS="$BG_PIDS $!"; BG_N=$((BG_N+1))
  if [[ "$BG_N" -ge "$PARALLEL" ]]; then bg_wait; fi
}
bg_wait(){
  if [[ -n "$BG_PIDS" ]]; then wait $BG_PIDS 2>/dev/null; fi
  BG_PIDS=""; BG_N=0
}

# Interactive y/N confirmation on the terminal. Returns 0 on yes.
confirm(){
  local ans=""
  [[ -t 0 ]] || return 1
  sync_report
  printf "  %s [y/N]: " "$1" >&"$TTY_FD"
  read -r ans < /dev/tty
  case "$(printf "%s" "$ans" | tr '[:upper:]' '[:lower:]')" in y|yes) return 0 ;; esac
  return 1
}

# Selection helper. Args: <question> <selectable numbers> <what>
# Sets CHOSEN. --yes selects all.
choose_items(){
  local question="$1" selectable="$2" what="$3" sel="" s
  if [[ "$AUTO_YES" == "true" ]]; then
    sel="all"
  elif [[ -t 0 ]]; then
    sync_report
    printf "\n  %s\n" "$question" >&"$TTY_FD"
    printf "  Requestable: %s\n" "$selectable" >&"$TTY_FD"
    printf "  Enter 'all', 'none' or numbers (e.g. 1,3) [none]: " >&"$TTY_FD"
    read -r sel < /dev/tty
  else
    echo
    echo "  Non-interactive session without --yes: no ${what} was requested."
  fi
  sel="$(printf "%s" "${sel:-none}" | tr '[:upper:]' '[:lower:]' | tr ',;' '  ')"

  CHOSEN=""
  case "$sel" in
    all|a|yes|y) CHOSEN="$selectable" ;;
    none|n|no|"") CHOSEN="" ;;
    *)
      for s in $sel; do
        if [[ " $selectable " == *" $s "* ]]; then
          [[ " $CHOSEN " == *" $s "* ]] || CHOSEN="$CHOSEN $s"
        else
          echo "  [WARN] Ignoring '$s': not a requestable number."
        fi
      done
      CHOSEN="${CHOSEN# }"
      ;;
  esac
  echo
  echo "  Selection: ${CHOSEN:-none}"
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --region) REGIONS_ARG="${2:-}"; shift 2 ;;
    --invoke) INVOKE="true"; shift ;;
    --global) TEST_GLOBAL="true"; shift ;;
    --request-agreement) REQUEST_AGREEMENT="true"; shift ;;
    --private-only) PRIVATE_ONLY="true"; shift ;;
    --include-legacy) INCLUDE_LEGACY="true"; shift ;;
    --allow-public) shift ;;  # accepted for compatibility; public offers are allowed by default.
    --request-quota) REQUEST_QUOTA="true"; shift ;;
    --quota-value) QUOTA_VALUE="${2:-}"; shift 2 ;;
    --quota-scope) QUOTA_SCOPE="${2:-}"; shift 2 ;;
    --submit-use-case) SUBMIT_USE_CASE="true"; shift ;;
    --use-case-file) USE_CASE_FILE="${2:-}"; SUBMIT_USE_CASE="true"; shift 2 ;;
    --yes|-y) AUTO_YES="true"; shift ;;
    --parallel) PARALLEL="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

REGIONS="$(printf "%s" "$REGIONS_ARG" | tr ',;' '  ' | tr -s ' ')"
REGIONS="${REGIONS# }"; REGIONS="${REGIONS% }"
[[ -n "$REGIONS" ]] || die "--region needs at least one region."
FIRST_REGION="${REGIONS%% *}"
[[ "$PARALLEL" =~ ^[0-9]+$ && "$PARALLEL" -ge 1 ]] || die "--parallel must be a number >= 1."
if [[ -z "$QUOTA_SCOPE" ]]; then
  if [[ "$TEST_GLOBAL" == "true" ]]; then QUOTA_SCOPE="all"; else QUOTA_SCOPE="eu"; fi
fi
case "$QUOTA_SCOPE" in eu|global|all) ;; *) die "--quota-scope must be eu, global or all." ;; esac
if [[ -n "$QUOTA_VALUE" ]] && ! num_gt_zero "$QUOTA_VALUE"; then
  die "--quota-value must be a number > 0."
fi
if [[ -n "$USE_CASE_FILE" && ! -s "$USE_CASE_FILE" ]]; then
  die "--use-case-file not found or empty: $USE_CASE_FILE"
fi

# ---------------------------------------------------------------------------
# Report capture. stdout/stderr go through a FIFO into tee, so the script can
# wait for tee to finish before the report file is moved (no lost last lines).
# Prompts go to the terminal (TTY_FD) and never into the report.
# ---------------------------------------------------------------------------
TMP_REPORT="$(mktemp "${TMPDIR:-/tmp}/im-anthropic-bedrock-audit.XXXXXX")" || exit 1
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/im-anthropic-bedrock-work.XXXXXX")" || exit 1

if [ -e /dev/tty ] && exec 3>/dev/tty 2>/dev/null; then
  TTY_FD=3
else
  TTY_FD=2
fi

exec 4>&1 5>&2
REPORT_SEQ=0
# Start a tee that appends to the report and echoes to the terminal (fd 4).
open_report(){
  REPORT_SEQ=$((REPORT_SEQ+1))
  local fifo="$WORKDIR/report.fifo.$REPORT_SEQ"
  mkfifo "$fifo" || exit 1
  tee -a "$TMP_REPORT" < "$fifo" >&4 &
  TEE_PID=$!
  exec > "$fifo" 2>&1
}
open_report

cleanup(){
  rm -rf "$WORKDIR" 2>/dev/null
}
trap cleanup EXIT

# Stop writing into the report and wait until tee has flushed everything.
close_report(){
  exec 1>&4 2>&5
  wait "$TEE_PID" 2>/dev/null
}

# Before an interactive prompt: let tee write every pending line to the
# screen first, so a prompt never appears above output that belongs before it.
sync_report(){
  [[ -t 0 ]] || return 0
  close_report
  open_report
}

API_ERRORS=0

cat <<EOF

==============================================================================
  Ingram Micro Amazon Bedrock Audit Script
  Investigates missing Anthropic model access or quota problems despite an
  Anthropic reselling agreement provided by Ingram Micro.
  Version ${VERSION}
  Copyright (c) 2026 Tobias Tomandl / Ingram Micro
  Extended by inQdo (use case, agreements, quotas, multi-region, summary)
==============================================================================

EOF

# ---------------------------------------------------------------------------
# [0] Pre-flight and credentials
# ---------------------------------------------------------------------------
echo "[0/10] PRE-FLIGHT"
command -v aws >/dev/null 2>&1 || {
  echo "  [FAIL] AWS CLI not installed or not in PATH."
  echo "         Install AWS CLI v2 and run the script again."
  close_report; exit 1
}
echo "  [ OK ] $(aws --version 2>&1)"
echo "  [ OK ] bash ${BASH_VERSION:-unknown}"
if command -v python3 >/dev/null 2>&1; then
  echo "  [ OK ] python3 (use case details)"
else
  echo "  [INFO] python3 not found: use case details are shown less readable."
fi

PROFILE_FILE="$WORKDIR/profiles.txt"
aws configure list-profiles 2>/dev/null | sed '/^[[:space:]]*$/d' > "$PROFILE_FILE"
PROFILE_COUNT="$(wc -l < "$PROFILE_FILE" | tr -d ' ')"
CREDENTIAL_SOURCE=""

if [[ -n "$PROFILE" ]]; then
  CREDENTIAL_SOURCE="AWS profile: $PROFILE"
else
  AMBIENT_OK="false"
  command aws sts get-caller-identity --region "$FIRST_REGION" >/dev/null 2>&1 && AMBIENT_OK="true"

  if [[ "$AMBIENT_OK" != "true" && "${PROFILE_COUNT:-0}" -le 0 ]]; then
    echo
    echo "  [FAIL] No usable current AWS session and no AWS CLI profiles found."
    echo "         In CloudShell, refresh/reopen the shell and try again."
    close_report; exit 1
  fi

  # Build the choice list: 1 = ambient session (if usable), then profiles.
  sync_report
  OFFSET=0
  {
    printf "\n  Available credential sources:\n"
    if [[ "$AMBIENT_OK" == "true" ]]; then
      printf "     1) Current AWS session / CloudShell credentials\n"; OFFSET=1
    fi
    N=$((OFFSET+1))
    while IFS= read -r PNAME; do
      printf "    %2d) AWS profile: %s\n" "$N" "$PNAME"; N=$((N+1))
    done < "$PROFILE_FILE"
    printf "\n"
  } >&"$TTY_FD"
  MAX_CHOICE=$((PROFILE_COUNT + OFFSET))

  if [[ ! -t 0 ]]; then
    N=1
  else
    while true; do
      printf "  Select credentials [1-%s] (default 1): " "$MAX_CHOICE" >&"$TTY_FD"
      read -r N < /dev/tty
      N="${N:-1}"
      [[ "$N" =~ ^[0-9]+$ ]] && ((N>=1 && N<=MAX_CHOICE)) && break
      printf "  Invalid selection.\n" >&"$TTY_FD"
    done
  fi
  if [[ "$AMBIENT_OK" == "true" && "$N" -eq 1 ]]; then
    PROFILE=""; CREDENTIAL_SOURCE="Current AWS session / CloudShell"
  else
    PROFILE="$(sed -n "$((N-OFFSET))p" "$PROFILE_FILE")"
    CREDENTIAL_SOURCE="AWS profile: $PROFILE"
  fi
  echo "  Credentials selected: $CREDENTIAL_SOURCE"
fi

# ---------------------------------------------------------------------------
# [1] Account (one STS call)
# ---------------------------------------------------------------------------
echo
echo "[1/10] ACCOUNT"
if ! aws_fetch "$WORKDIR/sts.txt" sts get-caller-identity --region "$FIRST_REGION" \
       --query '[Account,Arn]' --output text; then
  echo "  [FAIL] Authentication failed."
  echo "         Credential source: $CREDENTIAL_SOURCE"
  echo "         $(err_text "$WORKDIR/sts.txt.err" 300)"
  [[ -n "$PROFILE" ]] && echo "  For SSO try: aws sso login --profile \"$PROFILE\""
  close_report; exit 1
fi
IFS=$'\t' read -r ACCOUNT_ID CALLER_ARN < "$WORKDIR/sts.txt"
TS="$(date -u +'%Y%m%d%H%M%S')"
TS_FILE="${TS:0:8}-${TS:8:6}"

printf "  %-12s %s\n" "Account:" "$ACCOUNT_ID"
printf "  %-12s %s\n" "Credentials:" "$CREDENTIAL_SOURCE"
printf "  %-12s %s\n" "Region(s):" "$REGIONS"
printf "  %-12s %s\n" "Caller:" "$CALLER_ARN"
printf "  %-12s %s UTC\n" "Timestamp:" "$TS"

# Changes enabled in this run (point of no surprise).
CHANGES=""
[[ "$SUBMIT_USE_CASE" == "true" ]] && CHANGES="$CHANGES use-case"
[[ "$REQUEST_AGREEMENT" == "true" ]] && CHANGES="$CHANGES agreements"
[[ "$REQUEST_QUOTA" == "true" ]] && CHANGES="$CHANGES quota-increases"
CHANGES="${CHANGES# }"
if [[ -z "$CHANGES" ]]; then
  printf "  %-12s %s\n" "Mode:" "read-only$([[ "$INVOKE" == true ]] && echo ' + runtime test (--invoke)')"
else
  printf "  %-12s %s\n" "Mode:" "CHANGES enabled: $CHANGES"
  if [[ "$AUTO_YES" == "true" ]]; then
    printf "  %-12s %s\n" "" "--yes: everything that qualifies will be requested."
    if [[ -t 0 ]]; then
      if confirm "This run will change account $ACCOUNT_ID ($CHANGES) in $REGIONS. Continue?"; then
        echo "  Confirmed by operator."
      else
        echo "  Not confirmed: continuing READ-ONLY (no changes will be made)."
        SUBMIT_USE_CASE="false"; REQUEST_AGREEMENT="false"; REQUEST_QUOTA="false"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# [4] Use case (account-wide; run once, in the first region)
# ---------------------------------------------------------------------------
FTU="N/A"

submit_use_case(){
  local f="$WORKDIR/use-case-submit.json" err="$WORKDIR/use-case-submit.err"
  local cn cw iu ind oind uc

  echo
  echo "  SUBMIT USE CASE (--submit-use-case)"

  if [[ -n "$USE_CASE_FILE" ]]; then
    cp "$USE_CASE_FILE" "$f"
    echo "  Source: $USE_CASE_FILE"
  elif [[ -t 0 ]]; then
    sync_report
    printf "\n  Anthropic use case (shown to Anthropic for model access)\n" >&"$TTY_FD"
    printf "  Company name: " >&"$TTY_FD"; read -r cn < /dev/tty
    printf "  Company website (https://...): " >&"$TTY_FD"; read -r cw < /dev/tty
    printf "  Intended users: 0=Internal, 1=External, 2=Internal + External [0]: " >&"$TTY_FD"
    read -r iu < /dev/tty
    printf "  Industry (e.g. Technology, Retail, Finance) [Technology]: " >&"$TTY_FD"
    read -r ind < /dev/tty
    printf "  Other industry (optional): " >&"$TTY_FD"; read -r oind < /dev/tty
    printf "  Use case (one line, what the models are used for): " >&"$TTY_FD"
    read -r uc < /dev/tty
    iu="${iu:-0}"; ind="${ind:-Technology}"
    case "$iu" in 0|1|2) ;; *) echo "  [FAIL] Intended users must be 0, 1 or 2."; return 1 ;; esac
    if [[ -z "$cn" || -z "$cw" || ${#uc} -lt 10 ]]; then
      echo "  [FAIL] Company name, website and a use case (>= 10 chars) are required."
      return 1
    fi
    printf '{"companyName":"%s","companyWebsite":"%s","intendedUsers":"%s","industryOption":"%s","otherIndustryOption":"%s","useCases":"%s"}' \
      "$(json_escape "$cn")" "$(json_escape "$cw")" "$iu" \
      "$(json_escape "$ind")" "$(json_escape "$oind")" "$(json_escape "$uc")" > "$f"
  else
    echo "  Non-interactive session without --use-case-file: nothing submitted."
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$f" <<'PYUC' || { echo "  [FAIL] Use case is not valid JSON."; return 1; }
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
users = {"0": "Internal", "1": "External", "2": "Internal + External"}
for k, label in [("companyName", "Company"), ("companyWebsite", "Website"),
                 ("intendedUsers", "Intended users"), ("industryOption", "Industry"),
                 ("otherIndustryOption", "Other industry"), ("useCases", "Use case")]:
    v = str(d.get(k, ""))
    if k == "intendedUsers":
        v = users.get(v, v)
    if v or k != "otherIndustryOption":
        print("  %-15s %s" % (label + ":", v))
PYUC
  else
    sed 's/^/  /' "$f"; echo
  fi

  # Separate confirmation for the use case. Skipped only for a file given
  # together with --yes (both are explicit operator choices).
  if [[ -n "$USE_CASE_FILE" && "$AUTO_YES" == "true" ]]; then
    :
  elif ! confirm "Submit this use case to AWS/Anthropic?"; then
    echo "  Not submitted."
    return 0
  fi

  # fileb:// passes the raw JSON bytes (CLI v1 and v2, any cli_binary_format).
  if awsx bedrock put-use-case-for-model-access \
       --form-data "fileb://$f" --region "$REGION" \
       > /dev/null 2> "$err" < /dev/null; then
    echo "  [ OK ] Use case submitted."
    if awsx bedrock get-use-case-for-model-access --region "$REGION" \
         > /dev/null 2>&1 < /dev/null; then
      echo "  [ OK ] Verified: use case is now readable."
    fi
    FTU="PRESENT (submitted)"
  else
    echo "  [FAIL] Use case submission failed."
    echo "         $(err_text "$err")"
    grep -qiE "AccessDenied|not authorized" "$err" && \
      echo "         The caller needs bedrock:PutUseCaseForModelAccess."
  fi
}

step_use_case(){
  local raw="$WORKDIR/use-case.json" err="$WORKDIR/use-case.err" dec="$WORKDIR/use-case-decoded.json"
  echo
  echo "[4/10] ANTHROPIC FTU / USE CASE (account-wide, checked in $REGION)"

  if awsx bedrock get-use-case-for-model-access --region "$REGION" --output json \
       > "$raw" 2> "$err" < /dev/null; then
    FTU="PRESENT"
    echo "  [ OK ] Stored Anthropic use-case returned."

    local rc=127
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$raw" "$dec" <<'PY'
import sys, json, base64, binascii
src, dst = sys.argv[1], sys.argv[2]
try:
    outer = json.load(open(src, encoding="utf-8"))
except Exception:
    raise SystemExit(2)
value = outer.get("formData")
if value is None:
    raise SystemExit(3)
current = value if isinstance(value, bytes) else str(value).encode("utf-8")
parsed = None
# The blob can carry more than one Base64 layer: try JSON, then decode.
for depth in range(4):
    try:
        txt = current.decode("utf-8").strip()
    except Exception:
        txt = ""
    if txt:
        try:
            c = json.loads(txt)
            if isinstance(c, dict):
                parsed = c
                break
        except Exception:
            pass
    if depth == 3:
        break
    try:
        current = base64.b64decode(current + b"=" * ((4 - len(current) % 4) % 4), validate=False)
    except (binascii.Error, ValueError):
        break
if parsed is None:
    raise SystemExit(4)
json.dump(parsed, open(dst, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
PY
      rc=$?
    fi

    if [[ $rc -eq 0 && -s "$dec" ]]; then
      python3 - "$dec" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
users = {"0": "Internal", "1": "External", "2": "Internal + External"}
print("  Company:        " + str(d.get("companyName", "-")))
print("  Website:        " + str(d.get("companyWebsite", "-")))
print("  Intended users: " + users.get(str(d.get("intendedUsers", "")), str(d.get("intendedUsers", "-"))))
print("  Industry:       " + str(d.get("industryOption", "-")))
if d.get("otherIndustryOption", ""):
    print("  Other industry: " + str(d.get("otherIndustryOption")))
uc = str(d.get("useCases", "-")).replace("\n", " ").strip()
print("  Use case:")
print("    " + (uc if len(uc) <= 500 else uc[:500] + "..."))
PY
    else
      echo "  [WARN] Use-case exists, but formData could not be decoded as JSON."
    fi

    # Best-effort date: GetUseCase has no timestamp; CloudTrail may have one.
    local ftu_date="UNKNOWN"
    if aws_fetch "$WORKDIR/ct.txt" cloudtrail lookup-events \
         --lookup-attributes AttributeKey=EventName,AttributeValue=PutUseCaseForModelAccess \
         --region "$REGION" --max-results 50 \
         --query 'reverse(sort_by(Events,&EventTime))[0].EventTime' --output text; then
      [[ -s "$WORKDIR/ct.txt" ]] && ftu_date="$(head -n 1 "$WORKDIR/ct.txt")"
    fi
    if [[ "$ftu_date" != "UNKNOWN" ]]; then
      echo "  Last PutUseCase event: $ftu_date (CloudTrail, $REGION)"
    else
      echo "  Last PutUseCase event: UNKNOWN (no retained CloudTrail event in $REGION)"
    fi
  else
    FTU="NOT FOUND / NOT READABLE"
    echo "  [WARN] $FTU"
    echo "         $(err_text "$err")"

    if [[ "$SUBMIT_USE_CASE" != "true" ]]; then
      echo
      echo "  No use case submitted. Re-run with --submit-use-case to submit one"
      echo "  (interactive, or from a JSON file with --use-case-file FILE)."
    elif grep -qiE "AccessDenied|not authorized" "$err" 2>/dev/null; then
      echo
      echo "  [SKIP] Use case not submitted: the caller cannot read it (AccessDenied),"
      echo "         so it may already exist. Check bedrock:GetUseCaseForModelAccess /"
      echo "         PutUseCaseForModelAccess permissions first."
    else
      submit_use_case
    fi
  fi

  echo
  echo "  Note: the use case is account-wide. This audit only submits one when"
  echo "        none exists and --submit-use-case is passed. Mixed-customer"
  echo "        Organizations should be checked account-by-account."
}

# ---------------------------------------------------------------------------
# Per-region building blocks
# ---------------------------------------------------------------------------

# One availability lookup (runs in the background). Writes <dir>/<i>.{out,err,rc}
avail_one(){
  local dir="$1" i="$2" mid="$3"
  awsx bedrock get-foundation-model-availability --model-id "$mid" --region "$REGION" \
    --query '[agreementAvailability.status, authorizationStatus, entitlementAvailability, regionAvailability]' \
    --output text > "$dir/$i.out" 2> "$dir/$i.err" < /dev/null
  echo $? > "$dir/$i.rc"
}

# Build one ACCESS row (NAME MID LIFE AGR AUT ENT REG RESULT) from avail files.
# RESULT = READY, or every failing check joined with '+'.
access_row(){
  local dir="$1" i="$2" name="$3" mid="$4" life="$5"
  local agr="-" aut="-" ent="-" reg="-" res=""
  if [[ "$(cat "$dir/$i.rc" 2>/dev/null)" == "0" ]]; then
    IFS=$'\t' read -r agr aut ent reg < "$dir/$i.out"
    [[ -z "$agr" || "$agr" == None ]] && agr="-"
    [[ -z "$aut" || "$aut" == None ]] && aut="-"
    [[ -z "$ent" || "$ent" == None ]] && ent="-"
    [[ -z "$reg" || "$reg" == None ]] && reg="-"
    [[ "$reg" != AVAILABLE ]] && res="$res+REGION"
    [[ "$agr" != AVAILABLE ]] && res="$res+AGREEMENT"
    [[ "$aut" != AUTHORIZED ]] && res="$res+AUTH"
    [[ "$ent" != AVAILABLE ]] && res="$res+ENTITLEMENT"
    res="${res#+}"; [[ -z "$res" ]] && res="READY"
  else
    res="API-ERROR"
  fi
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$name" "$mid" "$life" "$agr" "$aut" "$ent" "$reg" "$res"
}

# Availability for every model in <model-tsv> (NAME MID LIFE), in parallel.
# Writes ACCESS rows to <out>.
check_availability(){
  local models="$1" out="$2" dir="$OUT/avail.$RANDOM"
  local i=0 name mid life
  mkdir -p "$dir"; : > "$out"
  while IFS=$'\t' read -r name mid life; do
    [[ -z "${mid:-}" ]] && continue
    i=$((i+1)); bg_run avail_one "$dir" "$i" "$mid"
  done < "$models"
  bg_wait
  i=0
  while IFS=$'\t' read -r name mid life; do
    [[ -z "${mid:-}" ]] && continue
    i=$((i+1)); access_row "$dir" "$i" "$name" "$mid" "$life" >> "$out"
    [[ "$(cat "$dir/$i.rc")" == "0" ]] || API_ERRORS=$((API_ERRORS+1))
  done < "$models"
}

print_access_table(){
  printf "  %-28s %-9s %-13s %-12s %-12s %-12s %s\n" \
    "MODEL" "LIFECYCLE" "AGREEMENT" "AUTH" "ENTITLEMENT" "REGION" "RESULT"
  printf "  %-28s %-9s %-13s %-12s %-12s %-12s %s\n" \
    "----------------------------" "---------" "-------------" "------------" \
    "------------" "------------" "------------"
  local name mid life agr aut ent reg res
  while IFS=$'\t' read -r name mid life agr aut ent reg res; do
    printf "  %-28s %-9s %-13s %-12s %-12s %-12s %s\n" \
      "$(short "$name" 28)" "$life" "$agr" "$aut" "$ent" "$reg" "$res"
  done < "$1"
}

# Applied quotas joined with AWS defaults (2 calls in total, not 1 per quota).
# Writes Q (CODE NAME ACTUAL DEFAULT). Returns 1 if the applied list failed.
fetch_quotas(){
  local q="$1" applied="$OUT/quotas-applied.tsv" defaults="$OUT/quotas-default.tsv"
  local query="Quotas[?(contains(QuotaName, 'tokens per minute') || contains(QuotaName, 'requests per minute')) && (contains(QuotaName, 'Anthropic') || contains(QuotaName, 'Claude'))].[QuotaCode,QuotaName,Value]"
  : > "$q"
  aws_fetch "$applied" service-quotas list-service-quotas --service-code bedrock \
    --region "$REGION" --query "$query" --output text || return 1
  aws_fetch "$defaults" service-quotas list-aws-default-service-quotas --service-code bedrock \
    --region "$REGION" --query 'Quotas[].[QuotaCode,Value]' --output text || true
  awk -F'\t' -v OFS='\t' '
    NR==FNR { def[$1]=$2; next }
    { d = ($1 in def) ? def[$1] : "-"; a=$3; sub(/\.0+$/,"",a); sub(/\.0+$/,"",d); print $1, $2, a, d }
  ' "$defaults" "$applied" > "$q"
  return 0
}

# Find the model (from ACCESS rows) a quota name belongs to; prints
# "NAME<TAB>LIFE<TAB>AGR" or nothing. Longest matching name wins.
model_for_quota(){
  awk -F'\t' -v qn="$1" '
    BEGIN { lq=tolower(qn) }
    {
      ln=tolower($1); pos=index(lq,ln); if (pos==0) next
      nextc=substr(lq,pos+length(ln),1)
      if (nextc!="" && nextc ~ /[0-9.]/) next
      if (length($1) > best) { best=length($1); out=$1 "\t" $3 "\t" $4 }
    }
    END { if (best) print out }' "$2"
}

# --- Offer lookup for one agreement candidate (background). ---
offers_one(){
  local dir="$1" i="$2" mid="$3"
  local q='offers[].[offerId,offerToken,termDetails.legalTerm.url]'
  : > "$dir/$i.err"
  awsx bedrock list-foundation-model-agreement-offers --model-id "$mid" --region "$REGION" \
    --query "$q" --output text > "$dir/$i.def" 2>> "$dir/$i.err" < /dev/null
  local r1=$?
  awsx bedrock list-foundation-model-agreement-offers --model-id "$mid" --offer-type ALL \
    --region "$REGION" --query "$q" --output text > "$dir/$i.all" 2>> "$dir/$i.err" < /dev/null
  local r2=$?
  if awsx bedrock list-foundation-model-agreement-offers --model-id "$mid" --offer-type PUBLIC \
       --region "$REGION" --query 'offers[].offerId' --output text > "$dir/$i.pubraw" 2>/dev/null < /dev/null; then
    tr '\t' '\n' < "$dir/$i.pubraw" | sed '/^[[:space:]]*$/d;/^None$/d' > "$dir/$i.pub"
    echo ok > "$dir/$i.pubok"
  fi
  if [[ $r1 -eq 0 || $r2 -eq 0 ]]; then echo ok > "$dir/$i.apiok"; fi
}

# ---------------------------------------------------------------------------
# Audit one region
# ---------------------------------------------------------------------------
SUMMARY_TSV="$WORKDIR/summary.tsv"      # REGION NAME LIFE ACCESS QUOTA TEST STATUS
SUMMARY_LINES="$WORKDIR/summary-lines.txt"
: > "$SUMMARY_TSV"; : > "$SUMMARY_LINES"

audit_region(){
  REGION="$1"
  OUT="$WORKDIR/$REGION"; mkdir -p "$OUT"
  local MODEL_TSV="$OUT/models.tsv" PROFILE_TSV="$OUT/profiles.tsv"
  local ACCESS_TSV="$OUT/access.tsv" Q="$OUT/quotas.tsv" HIST_TSV="$OUT/history.tsv"
  local AGREEMENT_SUMMARY="not requested" QUOTA_SUMMARY="not requested"
  local REQUESTED_MIDS="" name mid life agr aut ent reg res

  echo
  echo "##############################################################################"
  echo "  REGION: $REGION"
  echo "##############################################################################"

  # [2] Inventory -----------------------------------------------------------
  echo
  echo "[2/10] FOUNDATION MODEL INVENTORY ($REGION)"
  if ! aws_fetch "$MODEL_TSV" bedrock list-foundation-models --by-provider Anthropic \
         --region "$REGION" --query 'modelSummaries[*].[modelName,modelId,modelLifecycle.status]' \
         --output text; then
    api_fail "list-foundation-models failed; region skipped." "$MODEL_TSV.err"
    echo "$REGION: audit failed (model inventory not readable)" >> "$SUMMARY_LINES"
    return
  fi
  if [[ ! -s "$MODEL_TSV" ]]; then
    echo "  [WARN] AWS returned no Anthropic models in $REGION; region skipped."
    echo "$REGION: no Anthropic models offered" >> "$SUMMARY_LINES"
    return
  fi
  printf "  %-30s  %-45s  %s\n" "MODEL" "MODEL ID" "LIFECYCLE"
  printf "  %-30s  %-45s  %s\n" "------------------------------" \
    "---------------------------------------------" "----------"
  while IFS=$'\t' read -r name mid life; do
    printf "  %-30s  %-45s  %s\n" "$name" "$mid" "$life"
  done < "$MODEL_TSV"
  echo "  $(wc -l < "$MODEL_TSV" | tr -d ' ') model(s)."

  # [3] Inference profiles --------------------------------------------------
  echo
  echo "[3/10] SYSTEM INFERENCE PROFILES ($REGION)"
  if aws_fetch "$PROFILE_TSV" bedrock list-inference-profiles --type-equals SYSTEM_DEFINED \
       --region "$REGION" \
       --query "inferenceProfileSummaries[?contains(inferenceProfileId, '.anthropic.')].[inferenceProfileName,inferenceProfileId,status]" \
       --output text; then
    printf "  %-52s  %-52s  %s\n" "PROFILE NAME" "PROFILE ID" "STATUS"
    printf "  %-52s  %-52s  %s\n" "----------------------------------------------------" \
      "----------------------------------------------------" "--------"
    local pn pid ps
    while IFS=$'\t' read -r pn pid ps; do
      printf "  %-52s  %-52s  %s\n" "$pn" "$pid" "$ps"
    done < "$PROFILE_TSV"
    [[ -s "$PROFILE_TSV" ]] || echo "  [WARN] No Anthropic system inference profiles returned."
  else
    api_fail "list-inference-profiles failed (runtime test cannot use profiles)." "$PROFILE_TSV.err"
  fi

  # [4] Use case (once) -----------------------------------------------------
  if [[ "$REGION" == "$FIRST_REGION" ]]; then
    step_use_case
  else
    echo
    echo "[4/10] ANTHROPIC FTU / USE CASE"
    echo "  Account-wide; see $FIRST_REGION. Status: $FTU"
  fi

  # [5] Availability (parallel) ---------------------------------------------
  echo
  echo "[5/10] MODEL ACCESS / AVAILABILITY ($REGION)"
  echo "      Base model availability for this account + region. RESULT lists"
  echo "      every failing check (e.g. AGREEMENT+AUTH), not only the first."
  echo
  check_availability "$MODEL_TSV" "$ACCESS_TSV"
  print_access_table "$ACCESS_TSV"

  # [6] Quotas --------------------------------------------------------------
  echo
  echo "[6/10] RELEVANT RUNTIME QUOTAS ($REGION)"
  if fetch_quotas "$Q"; then
    local code qn a d
    while IFS=$'\t' read -r code qn a d; do
      echo
      printf "  %-12s  Actual: %-12s  Default: %-12s  Scope: %s\n" "$code" "$a" "$d" "$(quota_scope_of "$qn")"
      echo "               $qn"
    done < "$Q"
    [[ -s "$Q" ]] || echo "  [WARN] No Anthropic runtime quotas returned."
  else
    api_fail "list-service-quotas failed (quota checks unavailable)." "$OUT/quotas-applied.tsv.err"
  fi

  # [7] Quota request history (one call; reused in [9]) ---------------------
  echo
  echo "[7/10] QUOTA REQUEST HISTORY ($REGION)"
  if aws_fetch "$HIST_TSV" service-quotas list-requested-service-quota-change-history \
       --service-code bedrock --region "$REGION" \
       --query "RequestedQuotas[?contains(QuotaName, 'Anthropic') || contains(QuotaName, 'Claude')].[QuotaCode,QuotaName,DesiredValue,Status,CaseId,Created]" \
       --output text; then
    if [[ -s "$HIST_TSV" ]]; then
      printf "  %-10s  %-12s  %-12s  %-14s  %s\n" "CREATED" "QUOTA CODE" "DESIRED" "STATUS" "CASE ID"
      printf "  %-10s  %-12s  %-12s  %-14s  %s\n" "----------" "------------" "------------" "--------------" "----------"
      local hc hn hv hs hcase hcr
      while IFS=$'\t' read -r hc hn hv hs hcase hcr; do
        printf "  %-10s  %-12s  %-12s  %-14s  %s\n" "${hcr:0:10}" "$hc" "$(strip0 "$hv")" "$hs" "$hcase"
        echo "              $hn"
      done < "$HIST_TSV"
    else
      echo "  No relevant Service Quotas request history returned."
    fi
  else
    api_fail "quota request history not readable." "$HIST_TSV.err"
  fi

  # [8] Agreement requests --------------------------------------------------
  echo
  echo "[8/10] MODEL AGREEMENT REQUESTS ($REGION)"
  echo "      Candidates: agreement NOT_AVAILABLE or ERROR, model offered in this"
  echo "      region. PENDING is not re-requested. LEGACY models are skipped"
  echo "      unless --include-legacy."

  local CAND_TSV="$OUT/agr-candidates.tsv" LEGACY_SKIPPED=""
  : > "$CAND_TSV"
  while IFS=$'\t' read -r name mid life agr aut ent reg res; do
    case "$agr" in NOT_AVAILABLE|ERROR) ;; *) continue ;; esac
    [[ "$reg" == AVAILABLE ]] || continue
    if [[ "$life" == LEGACY && "$INCLUDE_LEGACY" != "true" ]]; then
      LEGACY_SKIPPED="$LEGACY_SKIPPED, $name"; continue
    fi
    printf "%s\t%s\t%s\t%s\n" "$name" "$mid" "$life" "$agr" >> "$CAND_TSV"
  done < "$ACCESS_TSV"
  LEGACY_SKIPPED="${LEGACY_SKIPPED#, }"
  local CAND_COUNT; CAND_COUNT="$(wc -l < "$CAND_TSV" | tr -d ' ')"
  [[ -n "$LEGACY_SKIPPED" ]] && echo "  LEGACY skipped: $LEGACY_SKIPPED"

  if [[ "$CAND_COUNT" -eq 0 ]]; then
    echo
    echo "  [ OK ] No models that need an agreement. Nothing to request."
    AGREEMENT_SUMMARY="no candidates"
  elif [[ "$REQUEST_AGREEMENT" != "true" ]]; then
    echo
    echo "  ${CAND_COUNT} model(s) without an agreement:"
    while IFS=$'\t' read -r name mid life agr; do
      printf "    - %-28s  %-45s  %s\n" "$(short "$name" 28)" "$mid" "$agr"
    done < "$CAND_TSV"
    echo
    echo "  Read-only: no agreement requested. Use --request-agreement to request them."
  else
    if [[ "$FTU" != PRESENT* ]]; then
      echo
      echo "  [WARN] No readable Anthropic use case (FTU). Agreement requests may"
      echo "         fail or stay PENDING until it is submitted (--submit-use-case)."
    fi

    # Offer lookups in parallel (3 calls per model).
    local ODIR="$OUT/offers"; mkdir -p "$ODIR"
    local IDX=0
    while IFS=$'\t' read -r name mid life agr; do
      IDX=$((IDX+1)); bg_run offers_one "$ODIR" "$IDX" "$mid"
    done < "$CAND_TSV"
    bg_wait

    # Classify: an offer id also returned for PUBLIC is PUBLIC, else PRIVATE.
    # Columns: IDX NAME MID LIFE AGR OTYPE OFFER_ID TOKEN LEGAL_URL NPRIV NPUB
    local OFFER_TSV="$OUT/agr-offers.tsv"; : > "$OFFER_TSV"
    echo
    printf "  %-3s %-28s %-10s %-14s %-9s %-5s %-5s %s\n" \
      "#" "MODEL" "LIFECYCLE" "AGREEMENT" "OFFER" "PRIV" "PUB" "OFFER ID"
    printf "  %-3s %-28s %-10s %-14s %-9s %-5s %-5s %s\n" \
      "---" "----------------------------" "----------" "--------------" \
      "---------" "-----" "-----" "--------------------"
    IDX=0
    local OTYPE OFFER_ID TOKEN LURL NPRIV NPUB FIRST_PRIV FIRST_ANY FIRST_ANY_TYPE SEEN LINE T OID OTOK OURL
    while IFS=$'\t' read -r name mid life agr; do
      IDX=$((IDX+1))
      OTYPE="NONE"; OFFER_ID="-"; TOKEN="-"; LURL="-"; NPRIV=0; NPUB=0
      FIRST_PRIV=""; FIRST_ANY=""; FIRST_ANY_TYPE=""; SEEN=" "
      while IFS=$'\t' read -r OID OTOK OURL; do
        [[ -z "${OTOK:-}" || "$OTOK" == None ]] && continue
        [[ "$SEEN" == *" $OTOK "* ]] && continue
        SEEN="$SEEN$OTOK "
        [[ -z "${OID:-}" ]] && OID="None"
        LINE="$OID"$'\t'"$OTOK"$'\t'"${OURL:-None}"
        if [[ ! -f "$ODIR/$IDX.pubok" || "$OID" == None ]]; then T="UNKNOWN"
        elif grep -qxF "$OID" "$ODIR/$IDX.pub"; then T="PUBLIC"
        else T="PRIVATE"; fi
        case "$T" in
          PRIVATE) NPRIV=$((NPRIV+1)); [[ -z "$FIRST_PRIV" ]] && FIRST_PRIV="$LINE" ;;
          PUBLIC)  NPUB=$((NPUB+1)) ;;
        esac
        if [[ -z "$FIRST_ANY" ]]; then FIRST_ANY="$LINE"; FIRST_ANY_TYPE="$T"; fi
      done < <(cat "$ODIR/$IDX.def" "$ODIR/$IDX.all" 2>/dev/null)

      if [[ -n "$FIRST_PRIV" ]]; then
        OTYPE="PRIVATE"; IFS=$'\t' read -r OFFER_ID TOKEN LURL <<< "$FIRST_PRIV"
      elif [[ -n "$FIRST_ANY" && "$PRIVATE_ONLY" == "true" ]]; then
        OTYPE="PUB-ONLY"
      elif [[ -n "$FIRST_ANY" ]]; then
        OTYPE="$FIRST_ANY_TYPE"; IFS=$'\t' read -r OFFER_ID TOKEN LURL <<< "$FIRST_ANY"
      elif [[ ! -f "$ODIR/$IDX.apiok" ]]; then
        OTYPE="API-ERROR"; API_ERRORS=$((API_ERRORS+1))
      fi

      printf "  %-3s %-28s %-10s %-14s %-9s %-5s %-5s %s\n" \
        "$IDX" "$(short "$name" 28)" "$life" "$agr" "$OTYPE" "$NPRIV" "$NPUB" "$OFFER_ID"
      [[ "$OTYPE" == "API-ERROR" ]] && echo "        Error: $(err_text "$ODIR/$IDX.err" 160)"
      [[ "$NPRIV" -gt 1 && "$OTYPE" == "PRIVATE" ]] && \
        echo "        Note: ${NPRIV} private offers found; the first one is used."
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$IDX" "$name" "$mid" "$life" "$agr" "$OTYPE" "$OFFER_ID" "$TOKEN" "$LURL" "$NPRIV" "$NPUB" >> "$OFFER_TSV"
    done < "$CAND_TSV"

    echo
    echo "  OFFER: PRIVATE  = private offer (reseller, e.g. Ingram Micro); preferred."
    echo "         PUBLIC   = public offer returned for this account."
    echo "         UNKNOWN  = offer returned, type could not be determined."
    echo "         PUB-ONLY = only a public offer; skipped because of --private-only."
    echo "         NONE / API-ERROR = AWS returned no offer token; cannot request."

    local SELECTABLE
    SELECTABLE="$(awk -F'\t' '$6=="PRIVATE" || $6=="PUBLIC" || $6=="UNKNOWN" {printf "%s ", $1}' "$OFFER_TSV")"
    SELECTABLE="${SELECTABLE% }"

    if [[ -z "$SELECTABLE" ]]; then
      echo
      echo "  No requestable offers found. No agreement was requested."
      AGREEMENT_SUMMARY="no requestable offers"
    else
      choose_items "Request agreement for which models? ($REGION)" "$SELECTABLE" "agreement"
      if [[ -z "$CHOSEN" ]]; then
        AGREEMENT_SUMMARY="none selected"
      else
        # 1) Create all agreements first ...
        local REQ_TSV="$OUT/agr-requests.tsv"; : > "$REQ_TSV"
        local N_OK=0 N_FAIL=0 DENIED="false" I ROW CERR REQ
        for I in $CHOSEN; do
          ROW="$(awk -F'\t' -v i="$I" '$1==i {print; exit}' "$OFFER_TSV")"
          IFS=$'\t' read -r _ name mid life agr OTYPE OFFER_ID TOKEN LURL NPRIV NPUB <<< "$ROW"
          CERR="$OUT/agr-create-$I.err"
          if awsx bedrock create-foundation-model-agreement --model-id "$mid" \
               --offer-token "$TOKEN" --region "$REGION" --output json \
               > /dev/null 2> "$CERR" < /dev/null; then
            REQ="REQUESTED"; N_OK=$((N_OK+1)); REQUESTED_MIDS="$REQUESTED_MIDS $mid"
          else
            REQ="FAILED"; N_FAIL=$((N_FAIL+1))
            grep -qiE "AccessDenied|not authorized" "$CERR" && DENIED="true"
          fi
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$I" "$name" "$mid" "$OTYPE" "$REQ" "$agr" "$LURL" >> "$REQ_TSV"
        done

        # 2) ... then poll all requested models together (max ~60s in total).
        if [[ "$N_OK" -gt 0 ]]; then
          echo
          echo "  Waiting for agreement activation (max ~60s for all models)..."
          local try pending m st
          for try in 1 2 3 4 5 6 7 8 9 10 11 12; do
            pending=""
            for m in $REQUESTED_MIDS; do
              st="$(cat "$OUT/agr-status-$(safe_name "$m")" 2>/dev/null)"
              [[ "$st" == AVAILABLE || "$st" == ERROR ]] && continue
              pending="$pending $m"
            done
            [[ -z "$pending" ]] && break
            sleep "$POLL_SECONDS"
            for m in $pending; do
              awsx bedrock get-foundation-model-availability --model-id "$m" --region "$REGION" \
                --query 'agreementAvailability.status' --output text \
                > "$OUT/agr-status-$(safe_name "$m")" 2>/dev/null < /dev/null || true
            done
          done
        fi

        echo
        printf "  %-3s %-28s %-8s %-10s %s\n" "#" "MODEL" "OFFER" "REQUEST" "STATUS NOW"
        printf "  %-3s %-28s %-8s %-10s %s\n" "---" "----------------------------" "--------" "----------" "--------------"
        local NOW
        while IFS=$'\t' read -r I name mid OTYPE REQ agr LURL; do
          if [[ "$REQ" == REQUESTED ]]; then
            NOW="$(cat "$OUT/agr-status-$(safe_name "$mid")" 2>/dev/null)"; NOW="${NOW:-PENDING}"
          else
            NOW="$agr"
          fi
          printf "  %-3s %-28s %-8s %-10s %s\n" "$I" "$(short "$name" 28)" "$OTYPE" "$REQ" "$NOW"
          [[ "$LURL" != "-" && "$LURL" != None ]] && echo "        Legal terms: $LURL"
          [[ "$REQ" == FAILED ]] && echo "        Error: $(err_text "$OUT/agr-create-$I.err")"
        done < "$REQ_TSV"

        AGREEMENT_SUMMARY="${N_OK} requested, ${N_FAIL} failed"
        echo
        echo "  Note: PENDING is normal right after a request; activation can take"
        echo "        a few minutes. Re-run the audit (read-only) to verify."
        if [[ "$DENIED" == "true" ]]; then
          echo "  AccessDenied: the caller needs bedrock:CreateFoundationModelAgreement,"
          echo "        bedrock:ListFoundationModelAgreementOffers and"
          echo "        aws-marketplace:Subscribe / ViewSubscriptions."
        fi

        # Refresh availability of the requested models, so [9] and [10] see
        # the new state.
        if [[ -n "$REQUESTED_MIDS" ]]; then
          local RQ_MODELS="$OUT/requested-models.tsv" RQ_ACCESS="$OUT/requested-access.tsv"
          awk -F'\t' -v list="$REQUESTED_MIDS " 'index(list, " " $2 " ") {print $1 "\t" $2 "\t" $3}' \
            "$ACCESS_TSV" > "$RQ_MODELS"
          check_availability "$RQ_MODELS" "$RQ_ACCESS"
          awk -F'\t' 'NR==FNR {upd[$2]=$0; next} ($2 in upd) {print upd[$2]; next} {print}' \
            "$RQ_ACCESS" "$ACCESS_TSV" > "$ACCESS_TSV.new" && mv "$ACCESS_TSV.new" "$ACCESS_TSV"
          echo
          echo "  Availability after the requests:"
          print_access_table "$RQ_ACCESS"
        fi
      fi
    fi
  fi

  # [9] Quota increase requests ---------------------------------------------
  echo
  echo "[9/10] RUNTIME QUOTA INCREASE REQUESTS ($REGION)"
  echo "      Candidates: quotas at 0 with an AWS default > 0, scope '$QUOTA_SCOPE',"
  if [[ -n "$QUOTA_VALUE" ]]; then
    echo "      requested value: $QUOTA_VALUE (--quota-value; never below the AWS default),"
  else
    echo "      requested value: the AWS default of each quota,"
  fi
  echo "      only for models with an agreement (AVAILABLE or PENDING)."

  local QCAND_TSV="$OUT/quota-candidates.tsv" QIDX=0
  : > "$QCAND_TSV"
  local code qn a d sc mline mname mlife magr want state NOMATCH=$'-\t-\t-'
  while IFS=$'\t' read -r code qn a d; do
    [[ -z "${code:-}" ]] && continue
    [[ "$a" == "0" ]] || continue
    num_gt_zero "$d" || continue
    sc="$(quota_scope_of "$qn")"
    case "$QUOTA_SCOPE" in
      eu) [[ "$sc" == EU ]] || continue ;;
      global) [[ "$sc" == GLOBAL ]] || continue ;;
    esac
    mline="$(model_for_quota "$qn" "$ACCESS_TSV")"
    [[ -n "$mline" ]] || mline="$NOMATCH"
    IFS=$'\t' read -r mname mlife magr <<< "$mline"
    # Request the AWS default, or --quota-value. AWS refuses a value below
    # the default (IllegalArgumentException), so a lower value is raised.
    want="$d"
    if [[ -n "$QUOTA_VALUE" ]] && awk -v a="$QUOTA_VALUE" -v b="$d" 'BEGIN { exit !(a+0 > b+0) }'; then
      want="$QUOTA_VALUE"
    fi
    if awk -F'\t' -v c="$code" '$1==c && ($4=="PENDING" || $4=="CASE_OPENED") {f=1} END {exit !f}' "$HIST_TSV" 2>/dev/null; then
      state="OPEN-REQ"
    elif [[ "$mlife" == LEGACY && "$INCLUDE_LEGACY" != "true" ]]; then
      state="LEGACY"
    elif [[ "$magr" != AVAILABLE && "$magr" != PENDING && "$mname" != "-" ]]; then
      state="NO-AGREEMENT"
    else
      state="CANDIDATE"
    fi
    QIDX=$((QIDX+1))
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$QIDX" "$code" "$qn" "$a" "$d" "$want" "$state" "$sc" >> "$QCAND_TSV"
  done < "$Q"

  if [[ "$QIDX" -eq 0 ]]; then
    echo
    echo "  [ OK ] No Anthropic runtime quotas at 0 in scope '$QUOTA_SCOPE'."
    QUOTA_SUMMARY="no candidates"
  else
    echo
    printf "  %-3s %-12s %-7s %-8s %-10s %-10s %-13s %s\n" \
      "#" "QUOTA CODE" "SCOPE" "ACTUAL" "DEFAULT" "REQUEST" "STATE" "QUOTA NAME"
    printf "  %-3s %-12s %-7s %-8s %-10s %-10s %-13s %s\n" \
      "---" "------------" "-------" "--------" "----------" "----------" "-------------" "--------------------"
    local qi qcode qname qa qd qwant qstate qsc
    while IFS=$'\t' read -r qi qcode qname qa qd qwant qstate qsc; do
      printf "  %-3s %-12s %-7s %-8s %-10s %-10s %-13s %s\n" \
        "$qi" "$qcode" "$qsc" "$qa" "$qd" "$qwant" "$qstate" "$qname"
    done < "$QCAND_TSV"
    echo
    echo "  STATE: CANDIDATE = can be requested; OPEN-REQ = request already open;"
    echo "         NO-AGREEMENT = model has no agreement yet; LEGACY = skipped"
    echo "         (use --include-legacy)."

    if [[ "$REQUEST_QUOTA" != "true" ]]; then
      echo
      echo "  Read-only: no quota increase requested. Use --request-quota to request them."
    else
      local QSEL
      QSEL="$(awk -F'\t' '$7=="CANDIDATE" {printf "%s ", $1}' "$QCAND_TSV")"; QSEL="${QSEL% }"
      if [[ -z "$QSEL" ]]; then
        echo
        echo "  Nothing requestable. No quota increase was requested."
        QUOTA_SUMMARY="nothing requestable"
      else
        choose_items "Request a quota increase for which quotas? ($REGION)" "$QSEL" "quota increase"
        if [[ -z "$CHOSEN" ]]; then
          QUOTA_SUMMARY="none selected"
        else
          echo
          printf "  %-3s %-12s %-12s %-10s %-14s %s\n" "#" "QUOTA CODE" "REQUESTED" "RESULT" "STATUS" "CASE / REQUEST ID"
          printf "  %-3s %-12s %-12s %-10s %-14s %s\n" "---" "------------" "------------" \
            "----------" "--------------" "--------------------"
          local QN_OK=0 QN_FAIL=0 QDENIED="false" I ROW QERR QRES QST QCASE QID QRC
          for I in $CHOSEN; do
            ROW="$(awk -F'\t' -v i="$I" '$1==i {print; exit}' "$QCAND_TSV")"
            IFS=$'\t' read -r _ qcode qname qa qd qwant qstate qsc <<< "$ROW"
            QERR="$OUT/quota-request-$qcode.err"
            QRES="$(awsx service-quotas request-service-quota-increase \
                  --service-code bedrock --quota-code "$qcode" --desired-value "$qwant" \
                  --region "$REGION" \
                  --query '[RequestedQuota.Status, RequestedQuota.CaseId, RequestedQuota.Id]' \
                  --output text 2> "$QERR" < /dev/null)"
            QRC=$?
            # If AWS demands a value strictly above the default, retry once
            # with default + 1.
            if [[ $QRC -ne 0 && "$qwant" == "$qd" && "$qd" =~ ^[0-9]+$ ]] && grep -qi "greater than the default" "$QERR"; then
              echo "        AWS requires more than the default ($qd); retrying with $((qd + 1))."
              qwant=$((qd + 1))
              QRES="$(awsx service-quotas request-service-quota-increase \
                    --service-code bedrock --quota-code "$qcode" --desired-value "$qwant" \
                    --region "$REGION" \
                    --query '[RequestedQuota.Status, RequestedQuota.CaseId, RequestedQuota.Id]' \
                    --output text 2> "$QERR" < /dev/null)"
              QRC=$?
            fi
            if [[ $QRC -eq 0 ]]; then
              IFS=$'\t' read -r QST QCASE QID <<< "$QRES"
              [[ -z "$QCASE" || "$QCASE" == None ]] && QCASE="$QID"
              printf "  %-3s %-12s %-12s %-10s %-14s %s\n" "$I" "$qcode" "$qwant" "REQUESTED" "${QST:-PENDING}" "${QCASE:--}"
              QN_OK=$((QN_OK+1))
            else
              printf "  %-3s %-12s %-12s %-10s %-14s %s\n" "$I" "$qcode" "$qwant" "FAILED" "-" "-"
              echo "        Error: $(err_text "$QERR" 400)"
              grep -qiE "AccessDenied|not authorized" "$QERR" && QDENIED="true"
              QN_FAIL=$((QN_FAIL+1))
            fi
            echo "        $qname"
          done
          QUOTA_SUMMARY="${QN_OK} requested, ${QN_FAIL} failed"
          echo
          echo "  Note: AWS reviews quota requests; this can take hours to days."
          echo "        A quota at 0 is often an account-level restriction: if a"
          echo "        request is denied or stalls, open an AWS Support case"
          echo "        (Service limit increase > Bedrock) and attach this report."
          if [[ "$QDENIED" == "true" ]]; then
            echo "  AccessDenied: the caller needs servicequotas:RequestServiceQuotaIncrease."
          fi
          # Some requests are approved at once: refresh quotas for [10].
          [[ "$QN_OK" -gt 0 ]] && fetch_quotas "$Q" >/dev/null 2>&1
        fi
      fi
    fi
  fi

  # [10] Runtime test + per-model status ------------------------------------
  echo
  echo "[10/10] RUNTIME TEST AND MODEL STATUS ($REGION)"
  if [[ "$INVOKE" == "true" ]]; then
    if [[ "$TEST_GLOBAL" == "true" ]]; then
      echo "      Testing EU and Global inference profiles (--global)."
    else
      echo "      Testing EU inference profiles (use --global to add Global)."
    fi
  else
    echo "      Runtime test off (read-only). Pass --invoke to call the models;"
    echo "      the status below is based on access and quota only."
  fi
  echo "      STATUS: OK = usable; ISSUE = not usable (see reason); LEGACY ="
  echo "      not counted; CHECK = no dedicated quota found, verify with --invoke."
  echo

  printf "  %-28s %-9s %-24s %-8s %-8s %-22s %s\n" \
    "MODEL" "LIFECYCLE" "ACCESS" "EU TPM" "GL TPM" "TEST" "STATUS"
  printf "  %-28s %-9s %-24s %-8s %-8s %-22s %s\n" \
    "----------------------------" "---------" "------------------------" \
    "--------" "--------" "----------------------" "------------"

  local TEST_BAD RETENTION_SEEN="false" EU_PID GL_PID EU_Q GL_Q EU_OK GL_OK TEST STATUS REASON
  local PROBE_ERRS="$OUT/probe-errors.txt"; : > "$PROBE_ERRS"
  while IFS=$'\t' read -r name mid life agr aut ent reg res; do
    EU_PID="$(awk -F'\t' -v m="eu.$mid" '$2==m {print $2; exit}' "$PROFILE_TSV" 2>/dev/null)"
    GL_PID="$(awk -F'\t' -v m="global.$mid" '$2==m {print $2; exit}' "$PROFILE_TSV" 2>/dev/null)"
    EU_Q="$(quota_value_for_model "^Cross-region model inference tokens per minute" "$name" "$Q")"
    GL_Q="$(quota_value_for_model "^Global cross-region model inference tokens per minute" "$name" "$Q")"
    EU_OK="false"; GL_OK="false"
    [[ -n "$EU_PID" ]] && num_gt_zero "${EU_Q:-0}" && EU_OK="true"
    [[ -n "$GL_PID" ]] && num_gt_zero "${GL_Q:-0}" && GL_OK="true"
    TEST="-"; REASON=""; TEST_BAD="false"

    if [[ "$res" != READY ]]; then
      TEST="SKIP"; REASON="$res"
    elif [[ "$INVOKE" == "true" ]]; then
      TEST=""
      local scope pid rc e
      for scope in EU GLOBAL; do
        if [[ "$scope" == EU ]]; then [[ "$EU_OK" == true ]] || continue; pid="$EU_PID"
        else [[ "$TEST_GLOBAL" == true && "$GL_OK" == true ]] || continue; pid="$GL_PID"; fi
        awsx bedrock-runtime converse --model-id "$pid" \
          --messages '[{"role":"user","content":[{"text":"Reply exactly with: OK"}]}]' \
          --inference-config '{"maxTokens":8}' --region "$REGION" --output json \
          > /dev/null 2> "$OUT/probe.err" < /dev/null
        rc=$?
        if [[ $rc -eq 0 ]]; then
          e="OK"
        else
          if grep -qiE "data retention|retention mode" "$OUT/probe.err"; then e="RETENTION-REQ"; RETENTION_SEEN="true"
          elif grep -qiE "not supported|unsupported|does not support|not available for this api" "$OUT/probe.err"; then e="API-N/A"
          elif grep -qiE "AccessDenied|not authorized|not available for this account|registration is incomplete|entitlement" "$OUT/probe.err"; then e="ACCESS-FAIL"
          elif grep -qiE "Throttl|TooManyRequests|quota|rate" "$OUT/probe.err"; then e="THROTTLED"
          else e="FAILED"; fi
          [[ "$e" != RETENTION-REQ ]] && echo "  $name ($scope, $pid): $(err_text "$OUT/probe.err" 150)" >> "$PROBE_ERRS"
        fi
        [[ "$e" == OK ]] || TEST_BAD="true"
        TEST="$TEST${TEST:+/}${scope:0:2}:$e"
      done
      [[ -z "$TEST" ]] && TEST="SKIP"
    fi

    # Status (ACTIVE models count towards the exit code).
    if [[ "$res" != READY ]]; then
      STATUS="ISSUE"
    elif [[ "$EU_OK" != true && ( "$TEST_GLOBAL" != true || "$GL_OK" != true ) ]]; then
      if [[ -n "$EU_Q" || -n "$GL_Q" ]]; then
        STATUS="ISSUE"; REASON="QUOTA0"
        [[ "$TEST_GLOBAL" != true && "$GL_OK" == true ]] && REASON="EU-QUOTA0 (Global ok, --global)"
      else
        STATUS="CHECK"; REASON="NO-QUOTA"
      fi
    elif [[ "$TEST_BAD" == "true" ]]; then
      STATUS="ISSUE"; REASON="TEST"
    else
      STATUS="OK"
    fi
    [[ "$life" == LEGACY && "$STATUS" != OK ]] && STATUS="LEGACY"

    printf "  %-28s %-9s %-24s %-8s %-8s %-22s %s\n" \
      "$(short "$name" 28)" "$life" "$(short "$res" 24)" "${EU_Q:--}" "${GL_Q:--}" \
      "$(short "$TEST" 22)" "$STATUS${REASON:+ ($REASON)}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$REGION" "$name" "$life" "$res" \
      "${EU_Q:--}/${GL_Q:--}" "$TEST" "$STATUS" "$REASON" >> "$SUMMARY_TSV"
  done < "$ACCESS_TSV"

  if [[ -s "$PROBE_ERRS" ]]; then
    echo
    echo "  Test errors:"
    cat "$PROBE_ERRS"
  fi
  if [[ "$RETENTION_SEEN" == "true" ]]; then
    echo
    echo "  Note (RETENTION-REQ): one or more models require an account-wide data"
    echo "    retention opt-in before they can be invoked. This audit changes no"
    echo "    such setting; enable it separately, then re-run."
  fi

  echo "$REGION: agreements: $AGREEMENT_SUMMARY; quotas: $QUOTA_SUMMARY" >> "$SUMMARY_LINES"
}

# ---------------------------------------------------------------------------
# Run all regions
# ---------------------------------------------------------------------------
for R in $REGIONS; do
  audit_region "$R"
done

# ---------------------------------------------------------------------------
# Summary and exit code
# ---------------------------------------------------------------------------
N_OK="$(awk -F'\t' '$7=="OK"' "$SUMMARY_TSV" | wc -l | tr -d ' ')"
N_ISSUE="$(awk -F'\t' '$7=="ISSUE"' "$SUMMARY_TSV" | wc -l | tr -d ' ')"
N_CHECK="$(awk -F'\t' '$7=="CHECK"' "$SUMMARY_TSV" | wc -l | tr -d ' ')"
N_LEGACY="$(awk -F'\t' '$7=="LEGACY"' "$SUMMARY_TSV" | wc -l | tr -d ' ')"

if [[ "$API_ERRORS" -gt 0 ]]; then
  EXIT_CODE=3; VERDICT="INCOMPLETE ($API_ERRORS AWS API error(s); see [FAIL] lines)"
elif [[ "$N_ISSUE" -gt 0 || ! -s "$SUMMARY_TSV" ]]; then
  EXIT_CODE=2; VERDICT="ISSUES FOUND"
else
  EXIT_CODE=0; VERDICT="ALL ACTIVE MODELS USABLE"
fi

echo
echo "=============================================================================="
echo "  AUDIT COMPLETE"
echo "=============================================================================="
echo "  Account:    $ACCOUNT_ID"
echo "  Region(s):  $REGIONS"
echo "  Timestamp:  $TS UTC"
echo "  Use case:   $FTU"
while IFS= read -r L; do echo "  $L"; done < "$SUMMARY_LINES"
echo
if [[ -s "$SUMMARY_TSV" ]]; then
  printf "  %-14s %-28s %-24s %s\n" "REGION" "MODEL" "ACCESS" "STATUS"
  printf "  %-14s %-28s %-24s %s\n" "--------------" "----------------------------" \
    "------------------------" "------------"
  while IFS=$'\t' read -r sr sn sl sres sq st ss sreason; do
    [[ "$ss" == OK ]] && continue
    printf "  %-14s %-28s %-24s %s\n" "$sr" "$(short "$sn" 28)" "$(short "$sres" 24)" "$ss${sreason:+ ($sreason)}"
  done < "$SUMMARY_TSV"
  [[ "$N_ISSUE$N_CHECK$N_LEGACY" == "000" ]] && echo "  (all models OK)"
  echo
fi
echo "  Models:     $N_OK OK, $N_ISSUE issue(s), $N_CHECK to check, $N_LEGACY legacy"
echo "  Result:     $VERDICT (exit code $EXIT_CODE)"
echo

# Report naming (prompts on the terminal only).
if [[ -t 0 ]]; then
  sync_report
  printf "\n  Report naming\n  -------------\n" >&"$TTY_FD"
  printf "  Partner name  [Partner]: " >&"$TTY_FD"; read -r PARTNER < /dev/tty
  printf "  Customer name [Customer]: " >&"$TTY_FD"; read -r CUSTOMER < /dev/tty
fi
PARTNER="${PARTNER:-Partner}"
CUSTOMER="${CUSTOMER:-Customer}"
DEFAULT_FILE="IM_Bedrock_Audit_$(safe_name "$PARTNER")_$(safe_name "$CUSTOMER")_${ACCOUNT_ID}_${TS_FILE}.txt"
USER_FILE=""
if [[ -t 0 ]]; then
  printf "  Report filename [%s]: " "$DEFAULT_FILE" >&"$TTY_FD"
  read -r USER_FILE < /dev/tty
fi
FINAL_REPORT="${USER_FILE:-$DEFAULT_FILE}"
[[ "$FINAL_REPORT" == *.txt ]] || FINAL_REPORT="${FINAL_REPORT}.txt"

echo "  Report naming"
echo "  -------------"
echo "  Partner:  $PARTNER"
echo "  Customer: $CUSTOMER"
echo
echo "  Complete report (single file):"
echo "    $FINAL_REPORT"
echo
echo "  Please send this report file to Ingram Micro for technical review."
echo

# Flush the report completely, then move it into place.
close_report
mv "$TMP_REPORT" "$FINAL_REPORT"
exit "$EXIT_CODE"
