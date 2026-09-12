-- =============================================================================
-- db/tests/test_views.sql  ·  BidHub  ·  Owner: P2 (Procedural SQL & Performance)
--
-- Acceptance for db/06_views.sql (technique 10, MATERIALIZED VIEW). Each check is
-- a DO block that RAISEs on mismatch, so a clean run means every check passed.
--
--   psql "$DATABASE_URL" -f db/tests/test_views.sql      (after 01 → 07)
--
-- Runs in one transaction that is rolled back — safe on the demo database.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- Start from a fresh snapshot so the checks compare like with like.
CALL refresh_leaderboard();


-- 1. One row per auction.
DO $$
DECLARE
    v_mv       INT;
    v_auctions INT;
BEGIN
    SELECT count(*) INTO v_mv FROM mv_leaderboard;
    SELECT count(*) INTO v_auctions FROM auctions;
    IF v_mv <> v_auctions THEN
        RAISE EXCEPTION 'FAIL one row per auction: mv_leaderboard has % rows, auctions has %', v_mv, v_auctions;
    END IF;
    RAISE NOTICE 'PASS mv_leaderboard has exactly one row per auction (% rows)', v_mv;
END $$;


-- 2. Every row's high bid, leader and counts match the bids table. The leader is
--    recomputed independently: highest amount, earliest placed_at wins a tie.
DO $$
DECLARE
    v_bad INT;
BEGIN
    SELECT count(*) INTO v_bad
    FROM mv_leaderboard m
    LEFT JOIN LATERAL (
        SELECT b.amount, u.full_name
        FROM bids b
        JOIN users u ON u.user_id = b.bidder_id
        WHERE b.auction_id = m.auction_id
        ORDER BY b.amount DESC, b.placed_at ASC
        LIMIT 1
    ) top ON true
    CROSS JOIN LATERAL (
        SELECT count(*) AS n, count(DISTINCT b.bidder_id) AS d
        FROM bids b
        WHERE b.auction_id = m.auction_id
    ) c
    WHERE m.current_high_bid IS DISTINCT FROM COALESCE(top.amount, m.starting_price)
       OR m.high_bidder_name IS DISTINCT FROM top.full_name
       OR m.bid_count        <> c.n
       OR m.distinct_bidders <> c.d;

    IF v_bad > 0 THEN
        RAISE EXCEPTION 'FAIL % auction(s) have a wrong current_high_bid / high_bidder_name / bid counts', v_bad;
    END IF;
    RAISE NOTICE 'PASS current_high_bid, high_bidder_name, bid_count, distinct_bidders correct for every auction';
END $$;


-- 3. Right after a refresh the stored result equals the live view (ignoring the
--    two columns that depend on the clock: seconds_remaining, computed_at).
DO $$
DECLARE
    v_diff INT;
BEGIN
    SELECT count(*) INTO v_diff FROM (
        (SELECT auction_id, item_title, category_name, seller_name, starting_price, current_high_bid,
                high_bidder_name, bid_count, distinct_bidders, end_time, status
           FROM mv_leaderboard
         EXCEPT
         SELECT auction_id, item_title, category_name, seller_name, starting_price, current_high_bid,
                high_bidder_name, bid_count, distinct_bidders, end_time, status
           FROM v_auction_summary)
        UNION ALL
        (SELECT auction_id, item_title, category_name, seller_name, starting_price, current_high_bid,
                high_bidder_name, bid_count, distinct_bidders, end_time, status
           FROM v_auction_summary
         EXCEPT
         SELECT auction_id, item_title, category_name, seller_name, starting_price, current_high_bid,
                high_bidder_name, bid_count, distinct_bidders, end_time, status
           FROM mv_leaderboard)
    ) d;
    IF v_diff > 0 THEN
        RAISE EXCEPTION 'FAIL mv_leaderboard and v_auction_summary differ in % row(s) right after a refresh', v_diff;
    END IF;
    RAISE NOTICE 'PASS mv_leaderboard is an exact snapshot of v_auction_summary';
END $$;


-- 4. v_active_auctions holds exactly the ACTIVE auctions.
DO $$
DECLARE
    v_view   INT;
    v_active INT;
BEGIN
    SELECT count(*) INTO v_view FROM v_active_auctions;
    SELECT count(*) INTO v_active FROM auctions WHERE status = 'ACTIVE';
    IF v_view <> v_active THEN
        RAISE EXCEPTION 'FAIL v_active_auctions has % rows, there are % ACTIVE auctions', v_view, v_active;
    END IF;
    RAISE NOTICE 'PASS v_active_auctions lists all % ACTIVE auctions', v_active;
END $$;


-- 5. Freshness contrast. A new bid shows up in the plain views at once, but the
--    materialized view keeps its snapshot until refresh_leaderboard() runs.
DO $$
DECLARE
    v_auction INT;
    v_bidder  INT;
    v_old     NUMERIC;
    v_new     NUMERIC;
    v_mv      NUMERIC;
    v_summary NUMERIC;
    v_live    NUMERIC;
BEGIN
    SELECT a.auction_id, m.current_high_bid, m.current_high_bid + a.bid_increment
      INTO v_auction, v_old, v_new
    FROM auctions a
    JOIN mv_leaderboard m ON m.auction_id = a.auction_id
    WHERE a.status = 'ACTIVE' AND a.end_time > now() + interval '1 hour'
    ORDER BY a.auction_id
    LIMIT 1;
    IF v_auction IS NULL THEN
        RAISE EXCEPTION 'FAIL no ACTIVE auction ending in more than an hour — run db/07_seed.sql first';
    END IF;

    SELECT user_id INTO v_bidder FROM users WHERE role = 'BUYER' ORDER BY user_id LIMIT 1;

    CALL place_bid(v_bidder, v_auction, v_new);

    SELECT current_high_bid INTO v_mv      FROM mv_leaderboard    WHERE auction_id = v_auction;
    SELECT current_high_bid INTO v_summary FROM v_auction_summary WHERE auction_id = v_auction;
    SELECT current_high_bid INTO v_live    FROM v_active_auctions WHERE auction_id = v_auction;

    IF v_summary <> v_new OR v_live <> v_new THEN
        RAISE EXCEPTION 'FAIL plain views should show the new bid % at once (v_auction_summary %, v_active_auctions %)',
            v_new, v_summary, v_live;
    END IF;
    IF v_mv <> v_old THEN
        RAISE EXCEPTION 'FAIL mv_leaderboard should still show the pre-refresh value %, shows %', v_old, v_mv;
    END IF;
    RAISE NOTICE 'PASS new bid on auction %: plain views show % immediately, mv_leaderboard still shows % (snapshot)',
        v_auction, v_new, v_old;

    CALL refresh_leaderboard();

    SELECT current_high_bid INTO v_mv FROM mv_leaderboard WHERE auction_id = v_auction;
    IF v_mv <> v_new THEN
        RAISE EXCEPTION 'FAIL after refresh_leaderboard() mv_leaderboard shows %, expected %', v_mv, v_new;
    END IF;
    RAISE NOTICE 'PASS after CALL refresh_leaderboard() (REFRESH ... CONCURRENTLY) mv_leaderboard shows %', v_mv;
END $$;


-- 6. The unique index is what makes CONCURRENTLY possible: drop it (inside a
--    savepoint) and PostgreSQL refuses the concurrent refresh.
SAVEPOINT without_unique_index;
DROP INDEX uq_mv_leaderboard_auction;
DO $$
DECLARE
    v_refused BOOLEAN := false;
BEGIN
    BEGIN
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_leaderboard;
    EXCEPTION WHEN OTHERS THEN
        v_refused := true;
        RAISE NOTICE 'PASS without uq_mv_leaderboard_auction the concurrent refresh is refused: % (SQLSTATE %)',
            SQLERRM, SQLSTATE;
    END;
    IF NOT v_refused THEN
        RAISE EXCEPTION 'FAIL REFRESH ... CONCURRENTLY succeeded without a unique index';
    END IF;
END $$;
ROLLBACK TO SAVEPOINT without_unique_index;

ROLLBACK;

\echo 'test_views.sql: all checks passed (transaction rolled back).'
