#!/usr/bin/env bash
#
# mayhem/test.sh — RUN jq's OWN functional test suite (tests/*test, run against the normal-flags
# build/test/jq that mayhem/build.sh produced), plus known-answer checks.
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

JQ_BIN="$SRC/build/test/jq"
[ -x "$JQ_BIN" ] || { echo "missing $JQ_BIN — mayhem/build.sh must build it" >&2; emit_ctrf "jq-tests" 0 1 0; exit 1; }

passed=0 failed=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"; ln -s "$JQ_BIN" "$WORK/bin/jq"   # tests/shtest runs jq-f-test.sh, which wants `jq` on PATH
export PATH="$WORK/bin:$PATH" JQ="$JQ_BIN"

# Known-answer checks: exact output for exact input.
check() { # <name> <expected> <jq args...> ; stdin is the input
  local name="$1" want="$2"; shift 2
  local got; got="$("$JQ_BIN" "$@" 2>&1)" || true
  if [ "$got" = "$want" ]; then passed=$((passed+1)); else failed=$((failed+1)); echo "FAIL $name: want [$want] got [$got]"; fi
}
check add        '6'                  -c '.a|add'               <<<'{"a":[1,2,3]}'
check keys       '["a","b"]'          -c 'keys'                 <<<'{"b":1,"a":2}'
check regex      '{"x":"abc"}'        -c 'capture("(?<x>a.c)")' <<<'"zabcz"'
check bignum     '100000000000000000000' -c '.'                 <<<'100000000000000000000'
check tojson     '"[1,{\"a\":null}]"' -c 'tojson'               <<<'[1,{"a":null}]'

# Upstream's suite (tests/*test). The --run-tests drivers must print "N of N tests passed".
for t in jqtest mantest optionaltest onigtest manonigtest; do
  [ -f "tests/$t" ] || continue
  out="$(sh "tests/$t" 2>&1)"; rc=$?
  line="$(printf '%s\n' "$out" | grep -E '^[0-9]+ of [0-9]+ tests passed' | tail -n1)"
  if [ -n "$line" ]; then
    n="$(sed -E 's/^([0-9]+) of ([0-9]+) tests passed.*/\1/' <<<"$line")"
    m="$(sed -E 's/^([0-9]+) of ([0-9]+) tests passed.*/\2/' <<<"$line")"
    passed=$((passed+n)); failed=$((failed+m-n))
    [ "$rc" -eq 0 ] || { failed=$((failed+1)); echo "FAIL tests/$t exited $rc"; }
  else
    failed=$((failed+1)); echo "FAIL tests/$t: no 'N of M tests passed' line"; printf '%s\n' "$out" | tail -5
  fi
done
for t in shtest utf8test base64test uritest; do
  [ -f "tests/$t" ] || continue
  if sh "tests/$t" >"$WORK/$t.log" 2>&1; then passed=$((passed+1)); else failed=$((failed+1)); echo "FAIL tests/$t"; tail -20 "$WORK/$t.log"; fi
done

emit_ctrf "jq-tests" "$passed" "$failed" 0
