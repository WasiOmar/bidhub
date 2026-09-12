#!/usr/bin/env bash
# Run every db/tests/test_*.sql against $DATABASE_URL and summarise the result.
# Each file works inside one transaction and rolls back, so this is safe on the
# demo database. The docker-restart durability proof is separate:
#   bash db/tests/concurrency.sh
#
#   bash scripts/run-tests.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
wait_for_db || exit 1

failed_files=0
total_checks=0

for f in "$REPO_ROOT"/db/tests/test_*.sql; do
    name=$(basename "$f")
    out=$(psql "$DATABASE_URL" -X -q -f "$f" 2>&1)
    pass=$(grep -c 'NOTICE:  PASS' <<<"$out")
    fail=$(grep -c 'NOTICE:  FAIL' <<<"$out")
    err=$(grep -c 'ERROR:' <<<"$out")
    total_checks=$((total_checks + pass))

    if [ "$fail" -eq 0 ] && [ "$err" -eq 0 ] && [ "$pass" -gt 0 ]; then
        printf 'PASS  %-22s %2d checks\n' "$name" "$pass"
    else
        printf 'FAIL  %-22s %2d passed, %d failed, %d errors\n' "$name" "$pass" "$fail" "$err"
        grep -E 'NOTICE:  FAIL|ERROR:' <<<"$out" | head -5 | sed 's/^/        /'
        failed_files=$((failed_files + 1))
    fi
done

echo
if [ "$failed_files" -eq 0 ]; then
    echo "run-tests.sh: all test files passed ($total_checks checks)"
else
    echo "run-tests.sh: $failed_files test file(s) failed"
    exit 1
fi
