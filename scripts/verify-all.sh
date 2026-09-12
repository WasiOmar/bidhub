#!/usr/bin/env bash
# Prove that all ten graded PostgreSQL techniques are present AND firing.
# Prints one PASS/FAIL line per technique and exits non-zero unless all ten pass.
#
#   bash scripts/verify-all.sh              # against $DATABASE_URL as it is now
#   bash scripts/verify-all.sh --rebuild    # first rebuild db/01 → db/07 (resets demo data)
#
# Every check except 08 runs inside a transaction that is rolled back, so the
# fixtures it creates never reach the demo data. 08 runs db/tests/concurrency.sh,
# which needs real concurrent sessions and restarts the db container to prove
# durability; point DATABASE_URL at the docker compose database for that.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${1:-}" = "--rebuild" ]; then
    bash "$REPO_ROOT/scripts/rebuild-db.sh" || exit 1
    echo
fi
wait_for_db || exit 1

# A seller, two bidders and one ACTIVE auction (start 100.00, increment 10.00).
# Ids land in the temp table _fx so DO blocks can read them.
read -r -d '' FIXTURE <<'SQL'
INSERT INTO users (full_name, email, password_hash, role) VALUES
    ('Verify Seller',   'verify-seller@bidhub.local', 'x', 'SELLER'),
    ('Verify Bidder A', 'verify-a@bidhub.local',      'x', 'BUYER'),
    ('Verify Bidder B', 'verify-b@bidhub.local',      'x', 'BUYER');
INSERT INTO categories (name, slug) VALUES ('Verify Fixture', 'verify-fixture');
INSERT INTO items (seller_id, category_id, title)
SELECT u.user_id, c.category_id, 'Verify Fixture Item'
  FROM users u, categories c
 WHERE u.email = 'verify-seller@bidhub.local' AND c.slug = 'verify-fixture';
INSERT INTO auctions (item_id, starting_price, bid_increment, end_time, status)
SELECT item_id, 100.00, 10.00, now() + interval '1 day', 'ACTIVE'
  FROM items WHERE title = 'Verify Fixture Item';
CREATE TEMP TABLE _fx ON COMMIT DROP AS
SELECT (SELECT user_id FROM users WHERE email = 'verify-seller@bidhub.local') AS seller_id,
       (SELECT user_id FROM users WHERE email = 'verify-a@bidhub.local')      AS bidder_a,
       (SELECT user_id FROM users WHERE email = 'verify-b@bidhub.local')      AS bidder_b,
       (SELECT category_id FROM categories WHERE slug = 'verify-fixture')     AS category_id,
       (SELECT a.auction_id FROM auctions a JOIN items i USING (item_id)
         WHERE i.title = 'Verify Fixture Item')                               AS auction_id;
SQL

# Runs the SQL on stdin after the fixture, inside BEGIN ... ROLLBACK. The SQL
# must INSERT exactly one 'PASS ...' or 'FAIL ...' line into _verify.
run_check() {
    local body out
    body=$(cat)
    out=$(psql "$DATABASE_URL" -X -q -At -v ON_ERROR_STOP=1 2>&1 <<EOF
SET client_min_messages = warning;
BEGIN;
CREATE TEMP TABLE _verify (msg TEXT) ON COMMIT DROP;
$FIXTURE
$body
SELECT msg FROM _verify;
ROLLBACK;
EOF
)
    if [ $? -ne 0 ]; then
        echo "FAIL $(grep -m1 'ERROR' <<<"$out" | sed 's/.*ERROR: *//')"
    elif [ -z "$out" ]; then
        echo "FAIL the check produced no result"
    else
        tail -n1 <<<"$out"
    fi
}

PASSED=0
report() {
    local id="$1" label="$2" result="$3"
    if [[ "$result" == PASS* ]]; then
        PASSED=$((PASSED + 1))
        printf 'PASS  %s %-19s %s\n' "$id" "$label" "${result#PASS }"
    else
        printf 'FAIL  %s %-19s %s\n' "$id" "$label" "${result#FAIL }"
    fi
}

echo "BidHub ten-technique verification — $(psql "$DATABASE_URL" -X -At -c \
    "SELECT current_database() || ' on PostgreSQL ' || current_setting('server_version')")"
echo


# 01 TRIGGER — a bid INSERT alone produces the OUTBID notification and audit row.
report 01 "TRIGGER" "$(run_check <<'SQL'
DO $$
DECLARE
    f        RECORD;
    n_outbid INT;
    n_audit  INT;
BEGIN
    SELECT * INTO f FROM _fx;
    CALL place_bid(f.bidder_a, f.auction_id, 100.00);
    CALL place_bid(f.bidder_b, f.auction_id, 110.00);
    SELECT count(*) INTO n_outbid FROM notifications
     WHERE user_id = f.bidder_a AND auction_id = f.auction_id AND type = 'OUTBID';
    SELECT count(*) INTO n_audit FROM audit_log
     WHERE entity_type = 'auction' AND entity_id = f.auction_id AND action = 'BID_PLACED';
    INSERT INTO _verify VALUES (CASE
        WHEN n_outbid = 1 AND n_audit = 2
        THEN 'PASS B outbid A: trg_outbid wrote 1 OUTBID row for A, trg_audit_bid wrote 2 audit rows'
        ELSE format('FAIL OUTBID rows for A = %s (want 1), BID_PLACED audit rows = %s (want 2)', n_outbid, n_audit)
    END);
END $$;
SQL
)"


# 02 TRIGGER + PROCEDURE — the ACTIVE → CLOSED flip settles the sale.
report 02 "TRIGGER+PROC" "$(run_check <<'SQL'
DO $$
DECLARE
    f        RECORD;
    v_buyer  INT;
    v_amount NUMERIC;
    n_notes  INT;
    v_winner INT;
BEGIN
    SELECT * INTO f FROM _fx;
    CALL place_bid(f.bidder_a, f.auction_id, 100.00);
    CALL place_bid(f.bidder_b, f.auction_id, 110.00);
    UPDATE auctions SET status = 'CLOSED' WHERE auction_id = f.auction_id;
    SELECT buyer_id, final_amount INTO v_buyer, v_amount FROM transactions WHERE auction_id = f.auction_id;
    SELECT count(*) INTO n_notes FROM notifications
     WHERE auction_id = f.auction_id AND type IN ('WON', 'SOLD');
    CALL award_winner(f.auction_id);
    SELECT b.bidder_id INTO v_winner
      FROM auctions a JOIN bids b ON b.bid_id = a.winning_bid_id
     WHERE a.auction_id = f.auction_id;
    INSERT INTO _verify VALUES (CASE
        WHEN v_buyer = f.bidder_b AND v_amount = 110.00 AND n_notes = 2 AND v_winner = f.bidder_b
        THEN 'PASS status flip: trg_close_auction wrote a 110.00 transaction + WON/SOLD; award_winner set winning_bid_id'
        ELSE format('FAIL transaction buyer ok=%s amount=%s (want 110.00), WON/SOLD rows=%s (want 2), winner ok=%s',
                    v_buyer = f.bidder_b, v_amount, n_notes, v_winner = f.bidder_b)
    END);
END $$;
SQL
)"


# 03 PROCEDURE — place_bid validates inside the database with a typed SQLSTATE.
report 03 "PROCEDURE" "$(run_check <<'SQL'
DO $$
DECLARE
    f       RECORD;
    v_state TEXT;
    v_msg   TEXT;
    n_bids  INT;
BEGIN
    SELECT * INTO f FROM _fx;
    CALL place_bid(f.bidder_a, f.auction_id, 100.00);
    BEGIN
        CALL place_bid(f.bidder_b, f.auction_id, 105.00);
    EXCEPTION WHEN OTHERS THEN
        v_state := SQLSTATE;
        v_msg   := SQLERRM;
    END;
    SELECT count(*) INTO n_bids FROM bids WHERE auction_id = f.auction_id;
    INSERT INTO _verify VALUES (CASE
        WHEN v_state = 'AU001' AND n_bids = 1
        THEN format('PASS underbid rejected with SQLSTATE AU001: "%s"', v_msg)
        ELSE format('FAIL got SQLSTATE %s (want AU001), bids on auction = %s (want 1)',
                    coalesce(v_state, 'none'), n_bids)
    END);
END $$;
SQL
)"


# 04 CTE + ROW_NUMBER — get_leaderboard row 1 is the highest bid.
report 04 "CTE+ROW_NUMBER" "$(run_check <<'SQL'
DO $$
DECLARE
    f         RECORD;
    v_auction INT;
    v_top     NUMERIC;
    v_max     NUMERIC;
    v_rows    INT;
    v_bidders INT;
    v_seq     BOOLEAN;
    v_leaders INT;
BEGIN
    SELECT * INTO f FROM _fx;
    CALL place_bid(f.bidder_a, f.auction_id, 100.00);
    CALL place_bid(f.bidder_b, f.auction_id, 110.00);
    CALL place_bid(f.bidder_a, f.auction_id, 120.00);

    -- The most contested auction in the database (seeded or the fixture).
    SELECT auction_id INTO v_auction FROM bids
     GROUP BY auction_id ORDER BY count(DISTINCT bidder_id) DESC, auction_id LIMIT 1;

    SELECT amount INTO v_top FROM get_leaderboard(v_auction) WHERE "position" = 1;
    SELECT max(amount), count(DISTINCT bidder_id) INTO v_max, v_bidders FROM bids WHERE auction_id = v_auction;
    SELECT count(*), bool_and("position" = rn), count(*) FILTER (WHERE is_leading)
      INTO v_rows, v_seq, v_leaders
      FROM (SELECT "position", is_leading, row_number() OVER (ORDER BY "position") AS rn
              FROM get_leaderboard(v_auction)) l;

    INSERT INTO _verify VALUES (CASE
        WHEN v_top = v_max AND v_rows = v_bidders AND v_seq AND v_leaders = 1
        THEN format('PASS auction %s: row 1 = %s = MAX(amount); positions 1..%s, one per bidder, one leader',
                    v_auction, v_top, v_rows)
        ELSE format('FAIL auction %s: row 1 = %s, MAX = %s, rows = %s (bidders %s), consecutive = %s, leaders = %s',
                    v_auction, v_top, v_max, v_rows, v_bidders, v_seq, v_leaders)
    END);
END $$;
SQL
)"


# 05 WINDOW FUNCTIONS — RANK(), SUM() OVER and LAG() all hold their definitions.
report 05 "WINDOW FUNCTIONS" "$(run_check <<'SQL'
DO $$
DECLARE
    n_bidders INT;
    min_rank  INT;
    bad_rank  INT;
    bad_rev   INT;
    n_sellers INT;
    n_first   INT;
    n_auct    INT;
BEGIN
    SELECT count(*), min(rank) INTO n_bidders, min_rank FROM v_top_bidders;

    -- RANK(): 1 + the number of bidders with a strictly larger total. Ties share
    -- a rank and the next rank skips, which is exactly what RANK() promises.
    SELECT count(*) INTO bad_rank FROM v_top_bidders t
     WHERE t.rank <> 1 + (SELECT count(*) FROM v_top_bidders o WHERE o.total_bid_value > t.total_bid_value);

    -- SUM() OVER: each seller's running total peaks at their total revenue.
    SELECT count(*), count(*) FILTER (WHERE r.peak <> s.total) INTO n_sellers, bad_rev
      FROM (SELECT seller_id, max(running_revenue) AS peak FROM v_seller_revenue GROUP BY seller_id) r
      JOIN (SELECT seller_id, sum(final_amount) AS total FROM transactions
             WHERE status <> 'CANCELLED' GROUP BY seller_id) s USING (seller_id);

    -- LAG(): exactly one bid per auction has no previous bid.
    SELECT count(*) FILTER (WHERE previous_amount IS NULL), count(DISTINCT auction_id)
      INTO n_first, n_auct FROM v_bid_momentum;

    INSERT INTO _verify VALUES (CASE
        WHEN n_bidders = 0 THEN 'FAIL v_top_bidders is empty — seed the database (db/07_seed.sql)'
        WHEN min_rank = 1 AND bad_rank = 0 AND bad_rev = 0 AND n_first = n_auct
        THEN format('PASS RANK() consistent for %s bidders; SUM() OVER totals match for %s sellers; LAG() NULL once per auction',
                    n_bidders, n_sellers)
        ELSE format('FAIL min rank %s, bad ranks %s, bad running totals %s, LAG first bids %s vs %s auctions',
                    min_rank, bad_rank, bad_rev, n_first, n_auct)
    END);
END $$;
SQL
)"


# 06 CURSOR — close_expired_auctions closes the expired ones and nothing else.
report 06 "CURSOR" "$(run_check <<'SQL'
INSERT INTO items (seller_id, category_id, title)
SELECT f.seller_id, f.category_id, v.title
  FROM _fx f, (VALUES ('Verify Expired 1'), ('Verify Expired 2')) AS v(title);
INSERT INTO auctions (item_id, starting_price, bid_increment, start_time, end_time, status)
SELECT item_id, 50.00, 5.00, now() - interval '2 days',
       CASE title WHEN 'Verify Expired 1' THEN now() - interval '1 hour' ELSE now() - interval '2 hours' END,
       'ACTIVE'
  FROM items WHERE title LIKE 'Verify Expired %';

DO $$
DECLARE
    v_expired INT[];
    v_live    INT[];
    n_closed  INT;
    n_live    INT;
BEGIN
    SELECT array_agg(auction_id) INTO v_expired FROM auctions WHERE status = 'ACTIVE' AND end_time <  now();
    SELECT array_agg(auction_id) INTO v_live    FROM auctions WHERE status = 'ACTIVE' AND end_time >= now();
    CALL close_expired_auctions();
    SELECT count(*) INTO n_closed FROM auctions WHERE auction_id = ANY (v_expired) AND status = 'CLOSED';
    SELECT count(*) INTO n_live   FROM auctions WHERE auction_id = ANY (v_live)    AND status = 'ACTIVE';
    INSERT INTO _verify VALUES (CASE
        WHEN cardinality(v_expired) >= 2
         AND n_closed = cardinality(v_expired)
         AND n_live = coalesce(cardinality(v_live), 0)
        THEN format('PASS cursor closed all %s expired ACTIVE auctions, left all %s live ones ACTIVE',
                    n_closed, n_live)
        ELSE format('FAIL closed %s of %s expired, %s of %s live still ACTIVE',
                    n_closed, cardinality(v_expired), n_live, coalesce(cardinality(v_live), 0))
    END);
END $$;
SQL
)"


# 07 RECURSIVE CTE — the category tree goes at least four levels deep.
report 07 "RECURSIVE CTE" "$(run_check <<'SQL'
DO $$
DECLARE
    v_depth  INT;
    v_path   TEXT;
    v_leaf   INT;
    n_crumbs INT;
BEGIN
    SELECT depth, array_to_string(path, ' > '), category_id INTO v_depth, v_path, v_leaf
      FROM get_category_tree() ORDER BY depth DESC, path LIMIT 1;
    SELECT count(*) INTO n_crumbs FROM get_category_breadcrumb(v_leaf);
    INSERT INTO _verify VALUES (CASE
        WHEN v_depth >= 3 AND n_crumbs = v_depth + 1
        THEN format('PASS depth %s: %s (breadcrumb walks back up %s levels)', v_depth, v_path, n_crumbs)
        ELSE format('FAIL deepest depth = %s (want >= 3), breadcrumb rows = %s', v_depth, n_crumbs)
    END);
END $$;
SQL
)"


# 08 ACID — real concurrent sessions plus a container restart, then the
#    single-session atomicity/consistency/isolation checks.
check_acid() {
    local out_sh rc_sh out_sql pass fail err durability
    out_sh=$(bash "$REPO_ROOT/db/tests/concurrency.sh" 2>&1)
    rc_sh=$?
    wait_for_db || { echo "FAIL database did not come back after concurrency.sh"; return; }
    out_sql=$(psql "$DATABASE_URL" -X -q -f "$REPO_ROOT/db/tests/test_concurrency.sql" 2>&1)
    pass=$(grep -c 'NOTICE:  PASS' <<<"$out_sql")
    fail=$(grep -c 'NOTICE:  FAIL' <<<"$out_sql")
    err=$(grep -c 'ERROR:' <<<"$out_sql")
    if grep -q 'PASS  Durability' <<<"$out_sh"; then
        durability="a committed bid survived a container restart"
    else
        durability="durability restart skipped (no docker compose)"
    fi
    if [ "$rc_sh" -eq 0 ] && grep -q 'concurrency.sh: PASS' <<<"$out_sh" \
       && [ "$fail" -eq 0 ] && [ "$err" -eq 0 ] && [ "$pass" -gt 0 ]; then
        echo "PASS concurrent bids serialised by FOR UPDATE, $durability; test_concurrency.sql $pass/$pass"
    else
        echo "FAIL $(grep -m1 -hE 'FAIL|ERROR' <<<"$out_sh"$'\n'"$out_sql")"
    fi
}
report 08 "ACID" "$(check_acid)"


# 09 COMPOSITE INDEX — the top-bid lookup is answered from idx_bids_auction_amount.
report 09 "COMPOSITE INDEX" "$(run_check <<'SQL'
DO $$
DECLARE
    v_auction INT;
    v_cols    INT;
    v_plan    TEXT;
    v_node    TEXT;
BEGIN
    SELECT auction_id INTO v_auction FROM bids GROUP BY auction_id ORDER BY count(*) DESC LIMIT 1;
    SELECT indnatts INTO v_cols FROM pg_index WHERE indexrelid = 'idx_bids_auction_amount'::regclass;
    EXECUTE format('EXPLAIN (FORMAT JSON) SELECT MAX(amount) FROM bids WHERE auction_id = %s', v_auction)
       INTO v_plan;
    SELECT string_agg(DISTINCT n ->> 'Node Type', ', ') INTO v_node
      FROM jsonb_path_query(v_plan::jsonb, 'strict $.**') AS n
     WHERE jsonb_typeof(n) = 'object' AND n ? 'Relation Name' AND n ->> 'Relation Name' = 'bids';
    INSERT INTO _verify VALUES (CASE
        WHEN v_cols = 2 AND v_plan LIKE '%idx_bids_auction_amount%' AND v_plan NOT LIKE '%Seq Scan%'
        THEN format('PASS MAX(amount) for auction %s: %s on idx_bids_auction_amount (auction_id, amount DESC), no Seq Scan',
                    v_auction, v_node)
        ELSE format('FAIL index columns = %s, plan on bids = %s', v_cols, v_node)
    END);
END $$;
SQL
)"


# 10 MATERIALIZED VIEW — a concurrent refresh succeeds and leaves the snapshot current.
report 10 "MATERIALIZED VIEW" "$(run_check <<'SQL'
DO $$
DECLARE
    f        RECORD;
    v_before NUMERIC;
    v_after  NUMERIC;
    v_diff   INT;
BEGIN
    SELECT * INTO f FROM _fx;
    CALL place_bid(f.bidder_a, f.auction_id, 150.00);
    SELECT current_high_bid INTO v_before FROM mv_leaderboard WHERE auction_id = f.auction_id;

    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_leaderboard;

    SELECT current_high_bid INTO v_after FROM mv_leaderboard WHERE auction_id = f.auction_id;
    SELECT count(*) INTO v_diff FROM (
        (SELECT auction_id, current_high_bid, high_bidder_name, bid_count, distinct_bidders, status FROM mv_leaderboard
         EXCEPT
         SELECT auction_id, current_high_bid, high_bidder_name, bid_count, distinct_bidders, status FROM v_auction_summary)
        UNION ALL
        (SELECT auction_id, current_high_bid, high_bidder_name, bid_count, distinct_bidders, status FROM v_auction_summary
         EXCEPT
         SELECT auction_id, current_high_bid, high_bidder_name, bid_count, distinct_bidders, status FROM mv_leaderboard)
    ) d;
    INSERT INTO _verify VALUES (CASE
        WHEN v_before IS NULL AND v_after = 150.00 AND v_diff = 0
        THEN 'PASS REFRESH ... CONCURRENTLY succeeded; new bid absent before, 150.00 after; mv = live view'
        ELSE format('FAIL before refresh = %s (want absent), after = %s (want 150.00), rows differing from live view = %s',
                    v_before, v_after, v_diff)
    END);
END $$;
SQL
)"


echo
echo "$PASSED/10 PASS"
[ "$PASSED" -eq 10 ]
