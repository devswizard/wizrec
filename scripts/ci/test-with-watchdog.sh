#!/usr/bin/env bash
# Runs `swift test` with a deadline and a stall detector. On failure, timeout or stall it prints
# GitHub annotations: failed tests, tests that started but never finished, and the stack of
# every thread of the stuck test process (`sample`), so a hang is readable through the public
# annotations API without opening the raw log.
#
#   TEST_DEADLINE_SECONDS  whole run (default 1500)
#   TEST_STALL_SECONDS     no test finished for this long → treat as a hang (default 300)
#   TEST_LOG               log file (default test.log)
# Extra arguments go to `swift test` (e.g. --filter, --skip, --no-parallel).
set -uo pipefail
deadline="${TEST_DEADLINE_SECONDS:-1500}"
stall="${TEST_STALL_SECONDS:-300}"
log="${TEST_LOG:-test.log}"
here="$(cd "$(dirname "$0")" && pwd)"

swift test --skip-build "$@" > "$log" 2>&1 &
pid=$!
start=$(date +%s)
last_count=0
last_change=$start
reason=""
while kill -0 "$pid" 2>/dev/null; do
  now=$(date +%s)
  count=$(grep -cE " (passed|failed|skipped)" "$log" 2>/dev/null || true)
  if [ "${count:-0}" != "$last_count" ]; then last_count=$count; last_change=$now; fi
  if (( now - start > deadline )); then reason="timed out after ${deadline}s"; fi
  if (( now - last_change > stall )); then reason="no test finished for ${stall}s (hang)"; fi
  if [ -n "$reason" ]; then
    echo "::error title=swift test::${reason}; ${last_count} test results so far"
    # Stacks of the test processes (xctest / swiftpm-testing-helper) before killing them.
    for p in $(pgrep -f "xctest|swiftpm-testing-helper|PackageTests" || true); do
      sample "$p" 3 -file "sample-$p.txt" >/dev/null 2>&1 || true
      [ -f "sample-$p.txt" ] && python3 "$here/annotate-sample.py" "sample-$p.txt"
    done
    python3 "$here/annotate-tests.py" "$log"
    pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
    pkill -f "xctest|swiftpm-testing-helper" 2>/dev/null
    exit 1
  fi
  sleep 10
done
wait "$pid"; status=$?
if (( status != 0 )); then
  grep -E "(error:|✘)" "$log" | sort -u | head -40 | while IFS= read -r line; do
    echo "::error title=swift test::${line}"
  done
fi
grep -E "Test run with|Executed [0-9]+ tests" "$log" | sort -u | while IFS= read -r line; do echo "::notice title=tests::${line}"; done
exit $status
