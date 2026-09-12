#!/usr/bin/env bash
# Rebuild the database from nothing, exactly as an examiner would: db/01 → db/07
# in numeric order, stopping at the first error. Every file is idempotent, so
# this is also the way to reset the demo data.
#
#   bash scripts/rebuild-db.sh                 # uses $DATABASE_URL (default: port 5433)
#
# For a truly empty volume first:  docker compose down -v && docker compose up -d
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

wait_for_db

FILES=(
    01_schema.sql
    02_triggers.sql
    03_procedures.sql
    04_queries.sql
    05_indexes.sql
    06_views.sql
    07_seed.sql
)

for f in "${FILES[@]}"; do
    printf '%-22s' "db/$f"
    if out=$(PGOPTIONS='-c client_min_messages=warning' psql_q -f "$REPO_ROOT/db/$f" 2>&1); then
        echo "ok"
    else
        echo "FAILED"
        echo "$out" | grep -E 'ERROR|FATAL' -A2 | head -20
        exit 1
    fi
done

echo
echo "Row counts after seeding:"
psql_q -c "
    SELECT 'users' AS table_name, count(*) AS rows FROM users
    UNION ALL SELECT 'categories',    count(*) FROM categories
    UNION ALL SELECT 'items',         count(*) FROM items
    UNION ALL SELECT 'auctions',      count(*) FROM auctions
    UNION ALL SELECT 'bids',          count(*) FROM bids
    UNION ALL SELECT 'transactions',  count(*) FROM transactions
    UNION ALL SELECT 'notifications', count(*) FROM notifications
    UNION ALL SELECT 'audit_log',     count(*) FROM audit_log
    UNION ALL SELECT 'mv_leaderboard', count(*) FROM mv_leaderboard"
