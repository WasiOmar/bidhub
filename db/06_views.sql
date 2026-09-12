-- =============================================================================
-- db/06_views.sql  ·  BidHub  ·  Owner: P2 (Procedural SQL & Performance)
--
-- Technique 10 — MATERIALIZED VIEW. mv_leaderboard is the live auction report:
-- one pre-joined row per auction with the leading bid already resolved.
-- Alongside it are two ordinary views, for contrast. The measured plain-view vs
-- matview timing is in docs/performance.md (produced by db/tests/benchmark.sql).
--
-- Idempotent: everything is dropped and recreated. Run after 01–05 and before
-- 07_seed.sql. The seed ends with CALL close_expired_auctions(), which refreshes
-- mv_leaderboard CONCURRENTLY, so this view must already exist by then.
-- Run order: 01 → 02 → 03 → 04 → 05 → 06 → 07.
--
-- ─── WHEN DOES A MATERIALIZED VIEW BEAT A PLAIN VIEW? ─────────────────────────
-- A plain VIEW is a stored query. Every SELECT from it re-runs the joins,
-- the window function and the aggregates, so it is always exactly current and
-- always pays the full cost.
-- A MATERIALIZED VIEW is a stored *result*. The query runs once, at REFRESH, and
-- reads afterwards are a scan of a small ready-made table. That makes it fast,
-- but only as fresh as the last REFRESH.
--
-- So the materialized view wins when:
--   * reads vastly outnumber changes: an auction page polled every few seconds
--     by many viewers, while the report only needs to be as fresh as the last
--     refresh cycle;
--   * the query is expensive: here, ROW_NUMBER() over every bid plus a
--     COUNT(DISTINCT) per auction;
--   * slightly stale is acceptable: seconds, not "must see my own bid now".
-- The plain view wins when a read must be current (the bidder's own confirmation,
-- place_bid()'s floor check), or when the query is cheap anyway. v_active_auctions
-- below is cheap because idx_bids_auction_amount answers its per-auction MAX/COUNT.
-- Break-even: once reads per refresh interval × plain-view cost exceeds
-- one refresh, the materialized view is cheaper overall.
-- =============================================================================

DROP PROCEDURE         IF EXISTS refresh_leaderboard();
DROP MATERIALIZED VIEW IF EXISTS mv_leaderboard;
DROP VIEW              IF EXISTS v_auction_summary;
DROP VIEW              IF EXISTS v_active_auctions;


-- -----------------------------------------------------------------------------
-- 1. v_auction_summary — PLAIN VIEW: the full live-auction report payload,
--    recomputed on every read.
--
--    This is the query mv_leaderboard stores. Keeping it as a plain view too
--    gives the cleanest possible comparison: the SAME query, once as a stored
--    query (always fresh, full cost per read) and once as a stored result
--    (instant read, fresh as of the last REFRESH).
--
--    The leading bid is picked with the CTE + ROW_NUMBER() pattern from
--    get_leaderboard() (db/04_queries.sql), not with a correlated subquery per
--    auction. One pass numbers every auction's bids at once, and position = 1 is
--    the leader: highest amount, earliest bid wins a tie. That is the same
--    tie-break as place_bid(), trg_close_auction and award_winner.
-- -----------------------------------------------------------------------------
CREATE VIEW v_auction_summary AS
WITH ranked_bids AS (
    SELECT
        b.auction_id,
        b.bidder_id,
        b.amount,
        ROW_NUMBER() OVER (
            PARTITION BY b.auction_id
            ORDER BY b.amount DESC, b.placed_at ASC
        ) AS position
    FROM bids b
),
bid_stats AS (
    SELECT
        auction_id,
        COUNT(*)                  AS bid_count,
        COUNT(DISTINCT bidder_id) AS distinct_bidders
    FROM bids
    GROUP BY auction_id
)
SELECT
    a.auction_id,
    i.title                                     AS item_title,
    c.name                                      AS category_name,
    s.full_name                                 AS seller_name,
    a.starting_price,
    -- Same convention as GET /api/auctions: no bids yet → the starting price.
    COALESCE(lb.amount, a.starting_price)       AS current_high_bid,
    hb.full_name                                AS high_bidder_name,
    COALESCE(bs.bid_count, 0)::INT              AS bid_count,
    COALESCE(bs.distinct_bidders, 0)::INT       AS distinct_bidders,
    a.end_time,
    a.status,
    -- Countdown at the moment the row was computed. In mv_leaderboard this is
    -- frozen at REFRESH time, so a client showing a live timer should count down
    -- from end_time itself; computed_at says how old the number is.
    CASE WHEN a.status IN ('ACTIVE', 'SCHEDULED')
         THEN GREATEST(0, floor(EXTRACT(EPOCH FROM a.end_time - now())))::INT
         ELSE 0
    END                                         AS seconds_remaining,
    now()                                       AS computed_at
FROM auctions a
JOIN items i       ON i.item_id = a.item_id
JOIN categories c  ON c.category_id = i.category_id
JOIN users s       ON s.user_id = i.seller_id
LEFT JOIN ranked_bids lb ON lb.auction_id = a.auction_id AND lb.position = 1
LEFT JOIN users hb       ON hb.user_id = lb.bidder_id
LEFT JOIN bid_stats bs   ON bs.auction_id = a.auction_id;

COMMENT ON VIEW v_auction_summary IS
    'Plain view: full live-auction report (leader via CTE + ROW_NUMBER), recomputed on every read. '
    'mv_leaderboard stores this exact result.';


-- -----------------------------------------------------------------------------
-- 2. mv_leaderboard — MATERIALIZED VIEW                              [technique 10]
--
--    The stored snapshot of v_auction_summary: one row per auction with auction_id,
--    item title, category, seller, starting_price, current_high_bid,
--    high_bidder_name, bid_count, distinct_bidders, end_time, status,
--    seconds_remaining, plus computed_at, which here means "last refreshed at".
--    WITH DATA populates it immediately. REFRESH ... CONCURRENTLY refuses to run
--    on a never-populated view.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_leaderboard AS
SELECT * FROM v_auction_summary
WITH DATA;

-- UNIQUE INDEX — REQUIRED for REFRESH MATERIALIZED VIEW CONCURRENTLY.
-- A concurrent refresh builds the new result on the side, then diffs it against
-- the current contents row by row. It has to match old and new rows by key, so
-- PostgreSQL insists on at least one UNIQUE index on plain columns (no WHERE
-- clause, no expression). Without it you get:
--   ERROR: cannot refresh materialized view "public.mv_leaderboard" concurrently
--   HINT:  Create a unique index with no WHERE clause on one or more columns ...
-- The payoff: a plain REFRESH takes an ACCESS EXCLUSIVE lock, so every reader
-- blocks until it finishes. A CONCURRENTLY refresh takes only an EXCLUSIVE lock,
-- so SELECTs keep being served from the old contents throughout. The price is a
-- slower refresh (the diff), which is why it needs the key.
-- The index also serves the live auction page's WHERE auction_id = N lookup.
CREATE UNIQUE INDEX uq_mv_leaderboard_auction
    ON mv_leaderboard (auction_id);

COMMENT ON MATERIALIZED VIEW mv_leaderboard IS
    'Technique 10: stored snapshot of v_auction_summary. Refreshed CONCURRENTLY by '
    'refresh_leaderboard() and by close_expired_auctions() (db/03_procedures.sql).';
COMMENT ON INDEX uq_mv_leaderboard_auction IS
    'Unique key REFRESH MATERIALIZED VIEW CONCURRENTLY needs to diff old vs new rows.';


-- -----------------------------------------------------------------------------
-- 3. refresh_leaderboard() — one place that knows how to refresh the report,
--    so the API or a scheduled job can CALL it without repeating the SQL.
--    close_expired_auctions() (db/03_procedures.sql) already issues this exact
--    REFRESH ... CONCURRENTLY after closing auctions, guarded so that it is a
--    no-op until this file has been run.
-- -----------------------------------------------------------------------------
CREATE PROCEDURE refresh_leaderboard()
LANGUAGE plpgsql
AS $$
BEGIN
    -- CONCURRENTLY: readers keep getting the previous snapshot while this runs.
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_leaderboard;
END;
$$;

COMMENT ON PROCEDURE refresh_leaderboard() IS
    'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_leaderboard: rebuilds the report without '
    'blocking readers (relies on uq_mv_leaderboard_auction).';


-- -----------------------------------------------------------------------------
-- 4. v_active_auctions — PLAIN VIEW, the always-fresh, cheap counterpart.
--
--    Only live auctions, with current high bid and bid count computed per row by
--    a LATERAL lookup. Each lookup is an index-only probe on
--    idx_bids_auction_amount, and the status filter matches the partial
--    idx_auctions_active_end (db/05_indexes.sql). The query is cheap, so a
--    snapshot would buy nothing, and it can never be stale. No ORDER BY in the
--    view: callers sort, e.g. ORDER BY end_time.
-- -----------------------------------------------------------------------------
CREATE VIEW v_active_auctions AS
SELECT
    a.auction_id,
    a.item_id,
    i.title                                     AS item_title,
    i.category_id,
    a.starting_price,
    a.bid_increment,
    COALESCE(hb.high_bid, a.starting_price)     AS current_high_bid,
    hb.bid_count::INT                           AS bid_count,
    a.end_time,
    GREATEST(0, floor(EXTRACT(EPOCH FROM a.end_time - now())))::INT AS seconds_remaining
FROM auctions a
JOIN items i ON i.item_id = a.item_id
CROSS JOIN LATERAL (
    SELECT MAX(b.amount) AS high_bid, COUNT(*) AS bid_count
    FROM bids b
    WHERE b.auction_id = a.auction_id
) hb
WHERE a.status = 'ACTIVE';

COMMENT ON VIEW v_active_auctions IS
    'Plain view: live auctions with high bid and bid count, always current; cheap thanks to '
    'idx_bids_auction_amount and idx_auctions_active_end.';
