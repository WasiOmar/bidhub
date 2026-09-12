#!/usr/bin/env bash
set -euo pipefail
DATABASE_URL="${DATABASE_URL:-postgresql://bidhub:bidhub@localhost:5433/bidhub}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
if ! command -v psql &>/dev/null; then
    echo "FAIL  psql client not found in PATH"
    exit 1
fi
if ! pg_isready -d "$DATABASE_URL" &>/dev/null; then
    echo "FAIL  database not reachable at $DATABASE_URL"
    exit 1
fi
HAS_PLACE_BID=$(psql "$DATABASE_URL" -At -c \
    "SELECT COUNT(*) FROM pg_proc WHERE proname = 'place_bid'")
if [ "$HAS_PLACE_BID" -eq 0 ]; then
    echo "SKIP  place_bid() not found — merge db/procedures (P2-01) first."
    exit 0
fi
psql "$DATABASE_URL" -q -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
-- Clean previous fixtures. auctions has no `title` column — only items does —
-- so both lookups below join through items rather than guessing at
-- auctions.title (a bare `WHERE title = ...` against auctions would raise
-- "column does not exist" and, under ON_ERROR_STOP=1 with this script's
-- `set -e`, abort the whole run before any concurrency test even started).
DELETE FROM bids        WHERE auction_id IN (
    SELECT a.auction_id FROM auctions a JOIN items i ON i.item_id = a.item_id
     WHERE i.title = 'Concurrency Test Item'
);
DELETE FROM auctions    WHERE auction_id IN (
    SELECT a.auction_id FROM auctions a JOIN items i ON i.item_id = a.item_id
     WHERE i.title = 'Concurrency Test Item'
);
DELETE FROM items       WHERE title = 'Concurrency Test Item';
DELETE FROM categories  WHERE slug = 'concurrency-test';
-- Users are reused across runs, never deleted: audit_log.actor_id is
-- ON DELETE SET NULL, and that UPDATE on the append-only audit_log is
-- rejected by trg_audit_immutable, which would abort every second run.
INSERT INTO users (full_name, email, password_hash, role)
VALUES
    ('Concurrency Seller', 'con-seller@bidhub.local',   'x', 'SELLER'),
    ('Bidder A',           'con-bidder-a@bidhub.local', 'x', 'BUYER'),
    ('Bidder B',           'con-bidder-b@bidhub.local', 'x', 'BUYER')
ON CONFLICT (email) DO NOTHING;
INSERT INTO categories (name, slug) VALUES ('Concurrency Test', 'concurrency-test');
-- A separate seller, so neither concurrent bidder trips the AU003 self-bid guard.
INSERT INTO items (seller_id, category_id, title, condition)
SELECT us.user_id, c.category_id, 'Concurrency Test Item', 'USED'
FROM users us, categories c
WHERE us.email = 'con-seller@bidhub.local' AND c.slug = 'concurrency-test';
INSERT INTO auctions (item_id, starting_price, bid_increment, end_time, status)
SELECT item_id, 100.00, 10.00, now() + interval '1 day', 'ACTIVE'
FROM items WHERE title = 'Concurrency Test Item';
COMMIT;
SQL
AUCTION_ID=$(psql "$DATABASE_URL" -At -c "
    SELECT a.auction_id
      FROM auctions a
      JOIN items i ON i.item_id = a.item_id
     WHERE i.title = 'Concurrency Test Item'
")
BIDDER_A=$(psql "$DATABASE_URL" -At -c \
    "SELECT user_id FROM users WHERE email = 'con-bidder-a@bidhub.local'")
BIDDER_B=$(psql "$DATABASE_URL" -At -c \
    "SELECT user_id FROM users WHERE email = 'con-bidder-b@bidhub.local'")
if [ -z "$AUCTION_ID" ] || [ -z "$BIDDER_A" ] || [ -z "$BIDDER_B" ]; then
    echo "FAIL  fixture setup failed"
    exit 1
fi
# Both sessions bid the same 110.00 at once. place_bid locks the auction row
# FOR UPDATE, so the second waits, then re-reads the high bid (now 110.00) and
# must reject its own 110.00 with AU001. VERBOSITY=verbose puts the SQLSTATE
# in the error text.
psql "$DATABASE_URL" -v ON_ERROR_STOP=0 -v VERBOSITY=verbose -c \
    "CALL place_bid($BIDDER_A, $AUCTION_ID, 110.00)" \
    > "${SCRIPT_DIR}/.con_result_a.txt" 2>&1 &
psql "$DATABASE_URL" -v ON_ERROR_STOP=0 -v VERBOSITY=verbose -c \
    "CALL place_bid($BIDDER_B, $AUCTION_ID, 110.00)" \
    > "${SCRIPT_DIR}/.con_result_b.txt" 2>&1 &
wait
RESULT_A=$(cat "${SCRIPT_DIR}/.con_result_a.txt")
RESULT_B=$(cat "${SCRIPT_DIR}/.con_result_b.txt")
BID_COUNT=$(psql "$DATABASE_URL" -At -c \
    "SELECT COUNT(*) FROM bids WHERE auction_id = $AUCTION_ID")
HIGH_BID=$(psql "$DATABASE_URL" -At -c \
    "SELECT MAX(amount) FROM bids WHERE auction_id = $AUCTION_ID")
ACCEPTED=0
REJECTED=0
for RESULT in "$RESULT_A" "$RESULT_B"; do
    if echo "$RESULT" | grep -q '^CALL'; then
        ACCEPTED=$((ACCEPTED + 1))
    elif echo "$RESULT" | grep -q 'AU001'; then
        REJECTED=$((REJECTED + 1))
    fi
done
ISOLATION_PASS=1
if [ "$BID_COUNT" -eq 1 ] && [ "$HIGH_BID" = "110.00" ] && [ "$ACCEPTED" -eq 1 ] && [ "$REJECTED" -eq 1 ]; then
    echo "PASS  Isolation: two concurrent 110.00 bids serialised by FOR UPDATE: one accepted, the other rejected (AU001)"
else
    echo "FAIL  Isolation: expected 1 accepted bid at 110.00 and 1 AU001, got $BID_COUNT bid(s), high bid $HIGH_BID"
    echo "       Result A: $RESULT_A"
    echo "       Result B: $RESULT_B"
    ISOLATION_PASS=0
fi
rm -f "${SCRIPT_DIR}/.con_result_a.txt" "${SCRIPT_DIR}/.con_result_b.txt"
DURABILITY_PASS=1
DOCKER_COMPOSE=""
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
fi
if [ -z "$DOCKER_COMPOSE" ]; then
    echo "SKIP  Durability: docker compose not available in this environment — cannot restart db"
else
    MARKER_AMOUNT="777.77"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c \
        "CALL place_bid($BIDDER_A, $AUCTION_ID, $MARKER_AMOUNT)" >/dev/null
    PRE_RESTART_COUNT=$(psql "$DATABASE_URL" -At -c \
        "SELECT COUNT(*) FROM bids WHERE auction_id = $AUCTION_ID AND amount = $MARKER_AMOUNT")
    if [ "$PRE_RESTART_COUNT" -ne 1 ]; then
        echo "FAIL  Durability: marker bid was not committed before restart"
        DURABILITY_PASS=0
    else
        echo "       Durability: marker bid $MARKER_AMOUNT committed, restarting db container..."
        if ! (cd "$REPO_ROOT" && $DOCKER_COMPOSE restart db >/dev/null 2>&1); then
            echo "FAIL  Durability: '$DOCKER_COMPOSE restart db' failed"
            DURABILITY_PASS=0
        fi
        if [ "$DURABILITY_PASS" -eq 1 ]; then
            RETRIES=30
            until pg_isready -d "$DATABASE_URL" &>/dev/null || [ "$RETRIES" -eq 0 ]; do
                sleep 1
                RETRIES=$((RETRIES - 1))
            done
            if ! pg_isready -d "$DATABASE_URL" &>/dev/null; then
                echo "FAIL  Durability: db did not come back up after restart"
                DURABILITY_PASS=0
            else
                POST_RESTART_COUNT=$(psql "$DATABASE_URL" -At -c \
                    "SELECT COUNT(*) FROM bids WHERE auction_id = $AUCTION_ID AND amount = $MARKER_AMOUNT")
                if [ "$POST_RESTART_COUNT" -eq 1 ]; then
                    echo "PASS  Durability: committed bid $MARKER_AMOUNT survived '$DOCKER_COMPOSE restart db' (WAL guarantee)"
                else
                    echo "FAIL  Durability: marker bid missing after restart (found $POST_RESTART_COUNT row(s))"
                    DURABILITY_PASS=0
                fi
            fi
        fi
    fi
fi
psql "$DATABASE_URL" -c "
    DELETE FROM bids        WHERE auction_id = $AUCTION_ID;
    DELETE FROM auctions    WHERE auction_id = $AUCTION_ID;
    DELETE FROM items       WHERE title = 'Concurrency Test Item';
    DELETE FROM categories  WHERE slug = 'concurrency-test';
" >/dev/null 2>&1 || true
if [ "$ISOLATION_PASS" -eq 1 ] && [ "$DURABILITY_PASS" -eq 1 ]; then
    echo "concurrency.sh: PASS"
else
    echo "concurrency.sh: FAIL"
    exit 1
fi
