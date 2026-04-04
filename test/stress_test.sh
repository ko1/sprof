#!/bin/bash
# Stress test: alternate rake test and multiprocess integration test
# Usage: bash test/stress_test.sh [iterations]
set -e

ITERATIONS=${1:-1000}
FAIL_COUNT=0

for i in $(seq 1 $ITERATIONS); do
  echo "=== Iteration $i / $ITERATIONS ==="

  echo "  rake test..."
  if ! rake test > /dev/null 2>&1; then
    echo "  FAIL: rake test failed on iteration $i"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    rake test 2>&1 | grep -E "(Failure|Error)" | head -5
    break
  fi

  echo "  multiprocess test..."
  if ! bash test/test_rperf_multiprocess.sh > /dev/null 2>&1; then
    echo "  FAIL: multiprocess test failed on iteration $i"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    bash test/test_rperf_multiprocess.sh 2>&1 | grep FAIL | head -5
    break
  fi

  echo "  OK"
done

echo
if [ $FAIL_COUNT -eq 0 ]; then
  echo "=== All $ITERATIONS iterations passed ==="
else
  echo "=== FAILED after $FAIL_COUNT failure(s) ==="
  exit 1
fi
