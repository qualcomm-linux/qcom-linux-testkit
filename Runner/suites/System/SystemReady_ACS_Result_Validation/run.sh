#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"

while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
TESTNAME="SystemReady_ACS_Result_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

RESULTS=""
REQUIRED_SUITES=""
SUMMARY_SHA256=""

# usage
# Print supported options without executing validation.
usage() {
    cat <<EOF
Usage: $0 [options]
Validate and import the compliance verdicts of an existing Arm SystemReady ACS report.
  --results <value>  Explicit ACS results directory containing acs_summary/acs_jsons
  --required-suites <value>  Optional comma-separated suite names required by the validation job
  --summary-sha256 <value>  Optional expected merged_results.json digest from the producing job
EOF
}

# parse_args <arguments>...
# Parse explicit values before accessing runtime evidence.
parse_args() {
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --help ]; then
            usage
            test_result_finish SKIP "Help requested, no test executed"
        fi
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
            test_result_finish FAIL "Missing value for $1"
        fi
        case "$2" in
            --*)
                test_result_finish FAIL "Missing value for $1 before option=$2"
                ;;
        esac
        case "$1" in
            --results)
                RESULTS="$2"
                ;;
            --required-suites)
                REQUIRED_SUITES="$2"
                ;;
            --summary-sha256)
                SUMMARY_SHA256="$2"
                ;;
            *)
                test_result_finish FAIL "Unknown option=$1"
                ;;
        esac
        shift 2
    done
}

parse_args "$@"

# shellcheck disable=SC2034 # Read by the shared dependency helper.
CHECK_DEPS_RECOVER=0
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies cat awk grep sed tr uname mkdir mktemp date; then
    test_result_finish SKIP "Required shell tools are absent, provision them in the image"
fi
OUT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") ||
    test_result_finish FAIL "Cannot create retained evidence under CWD=$PWD"


if [ -n "$SUMMARY_SHA256" ] && ! printf '%s\n' "$SUMMARY_SHA256" | grep -Eq '^[0-9a-fA-F]{64}$'; then
    test_result_finish FAIL "--summary-sha256 must contain exactly 64 hexadecimal characters"
fi
if [ -z "$RESULTS" ] || [ ! -d "$RESULTS" ]; then
    test_result_finish SKIP "Provide --results from a completed ACS job, this suite does not boot or run the ACS image"
fi
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies python3; then
    test_result_finish SKIP "ACS report ingestion requires image-provided python3"
fi
summary="$RESULTS/acs_summary/acs_jsons/merged_results.json"
if [ ! -r "$summary" ]; then
    test_result_finish FAIL "Selected ACS result directory has no readable merged_results.json, finish the ACS parser or correct --results"
fi
# shellcheck disable=SC2034 # Shared finish invokes owned parser cleanup.
TEST_RESULT_CLEANUP=bounded_timeout_cancel
trap 'test_result_finish FAIL "ACS report ingestion interrupted"' HUP INT TERM
run_with_bounded_timeout 30 python3 - "$summary" "$OUT_DIR" "$REQUIRED_SUITES" "$SUMMARY_SHA256" <<'PY' >"$OUT_DIR/parser.log" 2>&1
import hashlib
import json
from pathlib import Path
import re
import sys

source, output, required, expected_hash = sys.argv[1:]
output = Path(output)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON key: ' + key)
        result[key] = value
    return result


def verdict(value, mandatory=False):
    if not isinstance(value, str) or not value.strip():
        raise ValueError('Missing or non-string compliance verdict')
    value = value.strip()
    if re.fullmatch(r'Compliant(?: with waivers(?::.*)?)?', value, re.I):
        return 'PASS'
    if re.fullmatch(r'Not Run', value, re.I):
        return 'FAIL' if mandatory else 'SKIP'
    if re.match(r'^Not Compliant(?:\s*:|$)', value, re.I):
        return 'FAIL'
    raise ValueError('Unknown compliance verdict: ' + value)


try:
    with open(source, 'rb') as stream:
        raw = stream.read(67108865)
    if len(raw) > 67108864:
        raise ValueError('ACS summary exceeds the 64 MiB ingestion limit')
    digest = hashlib.sha256(raw).hexdigest()
    (output / 'source.json').write_bytes(raw)
    (output / 'source.sha256').write_text(digest + '\n')
    if expected_hash and digest.lower() != expected_hash.lower():
        raise ValueError('ACS summary does not match the producing-job SHA256')
    report = json.loads(raw, object_pairs_hook=unique_object)
    summary = report['Suite_Name: acs_info']['ACS Results Summary']
    for field in ['Band', 'Date']:
        if not isinstance(summary.get(field), str) or not summary[field].strip():
            raise ValueError('ACS summary lacks provenance field: ' + field)
    rows = []
    names = set()
    states = {}
    for key, value in summary.items():
        match = re.fullmatch(r'Suite_Name:\s*(Mandatory|Conditional-Mandatory|Recommended|Extension)\s*:\s*(.+?)_compliance', key)
        if not match:
            if key.startswith('Suite_Name:') or key.endswith('_compliance'):
                raise ValueError('Unrecognized suite compliance field: ' + key)
            continue
        requirement, name = match.groups()
        if name in names:
            raise ValueError('Duplicate suite identity: ' + name)
        names.add(name)
        states[name] = verdict(value, requirement == 'Mandatory')
        rows.append((states[name], requirement + ' ' + name, value))
    if not rows:
        raise ValueError('ACS summary contains no per-suite compliance results')
    expected_names = [name.strip() for name in required.split(',')] if required else []
    if len(set(expected_names)) != len(expected_names) or '' in expected_names:
        raise ValueError('Required suite names must be unique and nonempty')
    missing = sorted(set(expected_names) - names)
    if missing:
        raise ValueError('Required ACS results are absent: ' + ', '.join(missing))
    for name in expected_names:
        if states[name] == 'SKIP':
            raise ValueError('Required ACS suite did not run: ' + name)
    overall = verdict(summary.get('Overall Compliance Result'), True)
    # Keep source waivers visible and do not turn a failed suite into PASS merely
    # because the producer considers it optional for certification.
    rows.append((overall, 'Overall compliance', summary['Overall Compliance Result']))
    with (output / 'compliance.tsv').open('w') as stream:
        for state, title, reason in rows:
            detail = ' '.join((title + ': ' + reason).replace(';', ',').split())
            stream.write(state + '\t' + detail + '\n')
    (output / 'provenance.json').write_text(json.dumps({
        'source': str(Path(source).resolve()), 'sha256': digest,
        'band': summary['Band'], 'date': summary['Date'],
        'reported_suites': sorted(names), 'required_suites': expected_names}, indent=2))
except (ValueError, TypeError, KeyError, OSError) as error:
    print(str(error))
    sys.exit(1)
PY
parser_status=$?
if [ "$parser_status" -ne 0 ] || [ ! -s "$OUT_DIR/compliance.tsv" ]; then
    test_result_finish FAIL "ACS summary is incomplete, malformed or mismatched, inspect $OUT_DIR/parser.log"
fi
while IFS="$(printf '\t')" read -r verdict detail; do
    case "$detail" in
        *[Ww]aiver*)
            log_warn "Imported ACS result uses waivers, $detail"
            ;;
    esac
    test_result_record "$verdict" "Imported ACS result, $detail"
done <"$OUT_DIR/compliance.tsv"

test_result_finish
