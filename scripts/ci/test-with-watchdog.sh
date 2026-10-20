#!/usr/bin/env bash
# Runs `swift test` with a deadline. On failure or timeout, prints GitHub annotations for
# failed tests and for tests that started but never finished (likely hangs), so the cause
# is readable through the public annotations API without opening the raw log.
set -uo pipefail
deadline="${TEST_DEADLINE_SECONDS:-1500}"
log="${TEST_LOG:-test.log}"
swift test --skip-build > "$log" 2>&1 &
pid=$!
start=$(date +%s)
while kill -0 "$pid" 2>/dev/null; do
  if (( $(date +%s) - start > deadline )); then
    echo "::error title=swift test::timed out after ${deadline}s"
    # Swift Testing: "Test name() started." / "passed" / "failed"; XCTest: "Test Case '…' started."
    grep -oE "Test [^ ]+\(\)? started|Test Case '[^']+' started" "$log" | sed -E "s/ started//; s/^Test Case //; s/^Test //" | sort > started.txt
    grep -oE "Test [^ ]+\(\)? (passed|failed|skipped)|Test Case '[^']+' (passed|failed|skipped)" "$log" \
      | sed -E "s/ (passed|failed|skipped)$//; s/^Test Case //; s/^Test //" | sort > finished.txt
    comm -23 started.txt finished.txt | head -20 | while IFS= read -r t; do
      echo "::error title=still running at timeout::${t}"
    done
    tail -5 "$log" | while IFS= read -r line; do echo "::warning title=log tail::${line}"; done
    pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
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
grep -E "Test run with" "$log" | while IFS= read -r line; do echo "::notice title=tests::${line}"; done
exit $status
