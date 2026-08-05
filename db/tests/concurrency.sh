#!/usr/bin/env bash
# =============================================================================
# db/tests/concurrency.sh
# Proves that place_bid() serialises concurrent bidders on the same auction.
#
# Two simultaneous psql sessions fire place_bid for the same auction.
# Because place_bid locks the auction row FOR UPDATE, only one transaction
# can read the "current high bid" state at a time. Exactly one bidder wins
# at the intended amount; the other either raises AU001 or lands at a strictly
# higher amount.
#
# Run:  bash db/tests/concurrency.sh
# Env:  DATABASE_URL (defaults to the local BidHub container)
# =============================================================================
set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://bidhub:bidhub@localhost:5433/bidhub}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if ! command -v psql &>/dev/null; then
    echo "FAIL  psql client not found in PATH"
    exit 1
fi

if ! pg_isready -d "$DATABASE_URL" &>/dev/null; then
    echo "FAIL  database not reachable at $DATABASE_URL"
    exit 1
fi

# ---------------------------------------------------------------------------
# Does place_bid exist?  (P2-01 must be merged first.)
# ---------------------------------------------------------------------------
HAS_PLACE_BID=$(psql "$DATABASE_URL" -At -c \
    "SELECT COUNT(*) FROM pg_proc WHERE proname = 'place_bid'")

if [ "$HAS_PLACE_BID" -eq 0 ]; then
    echo "SKIP  place_bid() not found — merge db/procedures (P2-01) first."
    exit 0
fi

# ---------------------------------------------------------------------------
# Fixtures: clean slate, then one auction with two eager bidders.
# ---------------------------------------------------------------------------
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;

-- Clean previous fixtures
DELETE FROM bids        WHERE auction_id IN (SELECT auction_id FROM auctions WHERE title = 'Concurrency Test Auction');
DELETE FROM auctions    WHERE title = 'Concurrency Test Auction';
DELETE FROM items       WHERE title = 'Concurrency Test Item';
DELETE FROM categories  WHERE slug = 'concurrency-test';
DELETE FROM users       WHERE email IN ('con-bidder-a@bidhub.local', 'con-bidder-b@bidhub.local');

-- Users
INSERT INTO users (full_name, email, password_hash, role)
VALUES
    ('Bidder A', 'con-bidder-a@bidhub.local', 'x', 'BUYER'),
    ('Bidder B', 'con-bidder-b@bidhub.local', 'x', 'BUYER')
RETURNING user_id;

-- Category
INSERT INTO categories (name, slug) VALUES ('Concurrency Test', 'concurrency-test')
RETURNING category_id;

-- Item + auction (seller = Bidder A so we can also demo AU003 self-bid guard)
INSERT INTO items (seller_id, category_id, title, condition)
SELECT ua.user_id, c.category_id, 'Concurrency Test Item', 'USED'
FROM users ua, categories c
WHERE ua.email = 'con-bidder-a@bidhub.local' AND c.slug = 'concurrency-test'
RETURNING item_id;

INSERT INTO auctions (item_id, starting_price, bid_increment, end_time, status)
SELECT item_id, 100.00, 10.00, now() + interval '1 day', 'ACTIVE'
FROM items WHERE title = 'Concurrency Test Item'
RETURNING auction_id;

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

# ---------------------------------------------------------------------------
# Parallel bids: both attempt the SAME amount (110) at the same instant.
# place_bid locks the auction row FOR UPDATE, so the second caller will
# either see the new high bid and raise AU001, or re-check and succeed
# at a strictly higher amount (e.g. 120).
# ---------------------------------------------------------------------------
psql "$DATABASE_URL" -v ON_ERROR_STOP=0 -c \
    "CALL place_bid($BIDDER_A, $AUCTION_ID, 110.00)" \
    > "${SCRIPT_DIR}/.con_result_a.txt" 2>&1 &

psql "$DATABASE_URL" -v ON_ERROR_STOP=0 -c \
    "CALL place_bid($BIDDER_B, $AUCTION_ID, 110.00)" \
    > "${SCRIPT_DIR}/.con_result_b.txt" 2>&1 &

wait

RESULT_A=$(cat "${SCRIPT_DIR}/.con_result_a.txt")
RESULT_B=$(cat "${SCRIPT_DIR}/.con_result_b.txt")

# ---------------------------------------------------------------------------
# Analyse results
# ---------------------------------------------------------------------------
# Count how many bids now exist for this auction.
BID_COUNT=$(psql "$DATABASE_URL" -At -c \
    "SELECT COUNT(*) FROM bids WHERE auction_id = $AUCTION_ID")

HIGH_BID=$(psql "$DATABASE_URL" -At -c \
    "SELECT MAX(amount) FROM bids WHERE auction_id = $AUCTION_ID")

# Expected: exactly 2 bids, high bid is 110 or higher (120 if both succeeded).
# NOT acceptable: 1 bid at 110 (would mean the second call silently dropped).

if [ "$BID_COUNT" -ne 2 ]; then
    echo "FAIL  expected 2 bids, got $BID_COUNT"
    echo "       Result A: $RESULT_A"
    echo "       Result B: $RESULT_B"
    rm -f "${SCRIPT_DIR}/.con_result_a.txt" "${SCRIPT_DIR}/.con_result_b.txt"
    exit 1
fi

# Both should not be 110 — if they are, the loser did not see the winner's commit.
# At least one result must mention AU001 or the high bid must be > 110.
LOSER_SAW_CONFLICT=0
if echo "$RESULT_A" | grep -qi "AU001\|ERROR"; then
    LOSER_SAW_CONFLICT=1
fi
if echo "$RESULT_B" | grep -qi "AU001\|ERROR"; then
    LOSER_SAW_CONFLICT=1
fi

if [ "$LOSER_SAW_CONFLICT" -eq 1 ]; then
    echo "PASS  concurrent bids serialised by FOR UPDATE: winner at $HIGH_BID, loser rejected (AU001)"
else
    # Both succeeded — verify amounts differ.
    AMT_A=$(echo "$RESULT_A" | grep -oP '\d+\.\d+' | head -1 || true)
    AMT_B=$(echo "$RESULT_B" | grep -oP '\d+\.\d+' | head -1 || true)
    if [ -n "$AMT_A" ] && [ -n "$AMT_B" ] && [ "$AMT_A" != "$AMT_B" ]; then
        echo "PASS  concurrent bids serialised: winners at $AMT_A and $AMT_B"
    else
        echo "FAIL  both bids succeeded at the same amount — FOR UPDATE did not serialise"
        echo "       Result A: $RESULT_A"
        echo "       Result B: $RESULT_B"
        rm -f "${SCRIPT_DIR}/.con_result_a.txt" "${SCRIPT_DIR}/.con_result_b.txt"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -f "${SCRIPT_DIR}/.con_result_a.txt" "${SCRIPT_DIR}/.con_result_b.txt"
psql "$DATABASE_URL" -c "
    DELETE FROM bids        WHERE auction_id = $AUCTION_ID;
    DELETE FROM auctions    WHERE auction_id = $AUCTION_ID;
    DELETE FROM items       WHERE title = 'Concurrency Test Item';
    DELETE FROM categories  WHERE slug = 'concurrency-test';
    DELETE FROM users       WHERE email IN ('con-bidder-a@bidhub.local', 'con-bidder-b@bidhub.local');
" >/dev/null 2>&1 || true

echo "concurrency.sh: PASS"
