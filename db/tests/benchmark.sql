-- =============================================================================
-- db/tests/benchmark.sql  ·  BidHub  ·  Owner: P2 (Procedural SQL & Performance)
--
-- Evidence for technique 09 (and every other index in db/05_indexes.sql):
-- EXPLAIN (ANALYZE, BUFFERS) of the platform's real hot queries, first with
-- none of the secondary indexes, then with exactly the definitions from
-- db/05_indexes.sql. Section 9 adds technique 10: the same report read from a
-- plain view and from the materialized view (db/06_views.sql).
-- The numbers in docs/performance.md come from this script.
--
--   psql "$DATABASE_URL" -f db/tests/benchmark.sql
--
-- Run it after 01 → 07 have been loaded. Takes roughly a minute.
--
-- SAFE TO RUN ON THE DEMO DATABASE: everything happens inside one transaction
-- that ends in ROLLBACK — the synthetic rows, the dropped/recreated indexes and
-- the disabled triggers all disappear. The only lasting trace is that the id
-- sequences advance (sequence increments are never rolled back), leaving a gap
-- in future ids. Do not run it during a live demo: it holds table locks on
-- bids/auctions/items/notifications/categories for its whole duration.
--
-- Method:
--   1. Drop the secondary indexes (inside the transaction).
--   2. Load synthetic data: 50,000 bids on 500 live auctions, 5,000 auctions in
--      total (90% already CLOSED, as on any real marketplace — that is what
--      gives the partial index something to leave out), 50,000 items in a
--      4-level, 2,925-node category tree, 2,000 users, 100,000 notifications
--      (6% unread). All generated with generate_series, deterministically.
--   3. ANALYZE, then time every query: one warm-up run to load the pages into
--      shared_buffers, then the median of 3 EXPLAIN (ANALYZE, BUFFERS) runs.
--   4. \ir ../05_indexes.sql — the real file, so what is measured is what ships.
--   5. Time every query again, print the comparison and the index sizes.
--   6. Technique 10, if db/06_views.sql is loaded: time the same report read
--      from the plain view v_auction_summary and from the materialized view
--      mv_leaderboard, and time both kinds of REFRESH.
--   7. ROLLBACK.
-- =============================================================================

\set ON_ERROR_STOP on
\pset pager off
\timing off

BEGIN;

-- JIT compilation would add a variable compile-time cost to the slow no-index
-- runs and muddy the comparison. It is unrelated to indexing, so it is off here.
SET LOCAL jit = off;


-- -----------------------------------------------------------------------------
-- 1. Start from "no secondary indexes"
-- -----------------------------------------------------------------------------
DROP INDEX IF EXISTS
    idx_bids_auction_amount,
    idx_auctions_active_end,
    idx_items_category,
    idx_items_seller,
    idx_bids_bidder_placed,
    idx_notifications_user_unread,
    idx_categories_parent,
    idx_items_attributes,
    idx_items_title_trgm;


-- -----------------------------------------------------------------------------
-- 2. Synthetic load
-- -----------------------------------------------------------------------------

-- The bid triggers would write 50,000 audit_log and ~50,000 notification rows
-- and slow the load down a lot. This script measures reads, not the trigger path,
-- so they are switched off for the load (the ALTER is rolled back with everything else).
ALTER TABLE bids DISABLE TRIGGER USER;

-- 2,000 users: 200 sellers, 1,800 buyers.
INSERT INTO users (full_name, email, password_hash, role)
SELECT format('Bench User %s', g),
       format('bench-user-%s@bench.local', g),
       'x',
       (CASE WHEN g <= 200 THEN 'SELLER' ELSE 'BUYER' END)::user_role
FROM generate_series(1, 2000) g;

-- Category tree, 4 levels: 5 roots × 8 × 8 × 8 = 2,925 nodes, 2,560 leaves.
-- Slugs encode the path (bench-r3-4-5-1) so each level can be selected by pattern.
INSERT INTO categories (name, slug, parent_id)
SELECT format('Bench Root %s', g), format('bench-r%s', g), NULL
FROM generate_series(1, 5) g;

INSERT INTO categories (name, slug, parent_id)
SELECT format('%s / %s', p.name, g), p.slug || '-' || g, p.category_id
FROM categories p CROSS JOIN generate_series(1, 8) g
WHERE p.slug ~ '^bench-r[0-9]+$';

INSERT INTO categories (name, slug, parent_id)
SELECT format('%s / %s', p.name, g), p.slug || '-' || g, p.category_id
FROM categories p CROSS JOIN generate_series(1, 8) g
WHERE p.slug ~ '^bench-r[0-9]+-[0-9]+$';

INSERT INTO categories (name, slug, parent_id)
SELECT format('%s / %s', p.name, g), p.slug || '-' || g, p.category_id
FROM categories p CROSS JOIN generate_series(1, 8) g
WHERE p.slug ~ '^bench-r[0-9]+-[0-9]+-[0-9]+$';

-- 50,000 items spread over the 2,560 leaves and 200 sellers. Brand names are built
-- from two syllable lists (100 brands) so a keyword search matches ~1% of titles.
WITH sellers AS (
    SELECT array_agg(user_id ORDER BY user_id) AS ids
    FROM users WHERE email LIKE 'bench-user-%' AND role = 'SELLER'
), leaves AS (
    SELECT array_agg(category_id ORDER BY category_id) AS ids
    FROM categories WHERE slug ~ '^bench-r[0-9]+-[0-9]+-[0-9]+-[0-9]+$'
), words AS (
    SELECT ARRAY['Ka','Lo','Ve','Tri','Zen','Mor','Qua','Ul','Bri','Fen']              AS s1,
           ARRAY['dora','vix','tron','mela','sko','pex','rion','bell','nara','quist']   AS s2,
           ARRAY['Laptop','Guitar','Painting','Camera','Novel','Amplifier','Tablet',
                 'Sculpture','Turntable','Drone']                                        AS nouns,
           ARRAY['Vintage','Pristine','Rare','Limited','Classic','Modern','Signed',
                 'Restored','Compact','Deluxe','Studio','Travel']                        AS adjs
), gen AS (
    SELECT g,
           w.s1[((g / 200) % 100) / 10 + 1] || w.s2[((g / 200) % 100) % 10 + 1] AS brand,
           w.nouns[(g / 13) % 10 + 1]                                             AS noun,
           w.adjs[(g / 3) % 12 + 1]                                               AS adj,
           (1990 + (g / 11) % 35)::TEXT                                           AS yr
    FROM generate_series(1, 50000) g CROSS JOIN words w
)
INSERT INTO items (seller_id, category_id, title, description, condition, attributes, created_at)
SELECT s.ids[1 + (gen.g % array_length(s.ids, 1))],
       l.ids[1 + ((gen.g * 7) % array_length(l.ids, 1))],
       format('Bench %s %s %s %s', gen.adj, gen.brand, gen.noun, gen.g),
       format('Synthetic benchmark item %s.', gen.g),
       (ARRAY['NEW','LIKE_NEW','USED','REFURBISHED'])[1 + gen.g % 4]::item_condition,
       jsonb_build_object('brand', gen.brand, 'year', gen.yr, 'colour',
                          (ARRAY['black','white','red','blue','green'])[1 + gen.g % 5]),
       now() - gen.g * interval '1 minute'
FROM gen, sellers s, leaves l;

-- 5,000 auctions on the first 5,000 bench items: 500 ACTIVE (the first 49 already
-- past end_time, waiting for the close job), 4,500 CLOSED historical auctions.
INSERT INTO auctions (item_id, starting_price, bid_increment, start_time, end_time, status)
SELECT item_id,
       100.00,
       5.00,
       CASE WHEN rn <= 500 THEN now() - interval '2 days'
            ELSE now() - interval '90 days' + rn * interval '10 minutes' END,
       CASE WHEN rn <= 500 THEN now() + (rn - 50) * interval '20 minutes'
            ELSE now() - interval '83 days' + rn * interval '10 minutes' END,
       (CASE WHEN rn <= 500 THEN 'ACTIVE' ELSE 'CLOSED' END)::auction_status
FROM (
    SELECT item_id, row_number() OVER (ORDER BY item_id) AS rn
    FROM items WHERE title LIKE 'Bench %'
    ORDER BY item_id
    LIMIT 5000
) x;

-- 50,000 bids: 100 strictly increasing bids on each of the 500 live auctions,
-- from the 1,800 buyers (≈28 bids each).
WITH buyers AS (
    SELECT array_agg(user_id ORDER BY user_id) AS ids
    FROM users WHERE email LIKE 'bench-user-%' AND role = 'BUYER'
)
INSERT INTO bids (auction_id, bidder_id, amount, placed_at)
SELECT a.auction_id,
       b.ids[1 + ((a.auction_id * 97 + n * 13) % array_length(b.ids, 1))],
       a.starting_price + (n - 1) * a.bid_increment,
       a.start_time + n * interval '1 minute'
FROM auctions a
JOIN items i ON i.item_id = a.item_id AND i.title LIKE 'Bench %'
CROSS JOIN generate_series(1, 100) n
CROSS JOIN buyers b
WHERE a.status = 'ACTIVE';

-- 100,000 notifications: 50 per bench user, 3 of each user's 50 unread (6%).
WITH u AS (
    SELECT array_agg(user_id ORDER BY user_id) AS ids
    FROM users WHERE email LIKE 'bench-user-%'
)
INSERT INTO notifications (user_id, type, title, message, is_read, created_at)
SELECT u.ids[1 + (g % 2000)],
       (ARRAY['OUTBID','WON','SOLD','AUCTION_CLOSED'])[1 + g % 4]::notification_type,
       'Bench notification',
       format('Synthetic benchmark notification %s.', g),
       ((g / 2000) % 20) <> 0,
       now() - g * interval '1 minute'
FROM generate_series(0, 99999) g, u;

ALTER TABLE bids ENABLE TRIGGER USER;

-- Fair statistics for the no-index run.
ANALYZE;


-- -----------------------------------------------------------------------------
-- 3. Query parameters — concrete ids picked from the synthetic data
-- -----------------------------------------------------------------------------
SELECT
    (SELECT a.auction_id FROM auctions a JOIN items i ON i.item_id = a.item_id
      WHERE i.title LIKE 'Bench %' AND a.status = 'ACTIVE'
      ORDER BY a.auction_id OFFSET 250 LIMIT 1)                         AS auction,
    (SELECT b.bidder_id FROM bids b JOIN users u ON u.user_id = b.bidder_id
      WHERE u.email LIKE 'bench-user-%'
      GROUP BY b.bidder_id ORDER BY count(*) DESC, b.bidder_id LIMIT 1) AS bidder,
    (SELECT user_id FROM users WHERE email = 'bench-user-1000@bench.local') AS notif_user,
    (SELECT user_id FROM users WHERE email = 'bench-user-37@bench.local')   AS seller,
    (SELECT category_id FROM categories WHERE slug = 'bench-r3')          AS root_category,
    (SELECT category_id FROM categories WHERE slug = 'bench-r3-4-5')      AS sub_category,
    'zenpex'                                                              AS term,
    (SELECT jsonb_build_object('brand', attributes->>'brand', 'year', attributes->>'year')::TEXT
       FROM items WHERE title LIKE 'Bench %' ORDER BY item_id OFFSET 777 LIMIT 1) AS attrs
\gset bench_

\echo
\echo 'Benchmark parameters:'
\echo '  auction=' :bench_auction ' bidder=' :bench_bidder ' notif_user=' :bench_notif_user ' seller=' :bench_seller
\echo '  root_category=' :bench_root_category ' sub_category=' :bench_sub_category ' term=' :bench_term ' attrs=' :bench_attrs


-- -----------------------------------------------------------------------------
-- 4. The queries. Wherever the API or a routine runs a query, the text below is
--    that query verbatim (with its bind parameters filled in).
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE bench_query (
    id        INT PRIMARY KEY,
    label     TEXT NOT NULL,
    source    TEXT NOT NULL,     -- where the platform runs this query
    serves    TEXT NOT NULL,     -- index(es) expected to help
    key_query BOOLEAN NOT NULL,  -- one of the four headline queries (full plans printed)
    sql       TEXT NOT NULL,
    suite     TEXT NOT NULL DEFAULT 'index'   -- 'index' (05_indexes.sql) | 'views' (06_views.sql)
) ON COMMIT DROP;

INSERT INTO bench_query VALUES
(1, 'Homepage: active auctions + high bid + bid count', 'GET /api/auctions?status=ACTIVE',
    'idx_auctions_active_end, idx_bids_auction_amount', true,
 $q$SELECT a.auction_id, a.item_id, a.starting_price, a.reserve_price, a.bid_increment,
       a.start_time, a.end_time, a.status, a.winning_bid_id, a.created_at,
       i.title AS item_title, i.image_url, i.category_id,
       COALESCE(hb.high_bid, a.starting_price) AS current_high_bid,
       COALESCE(bc.bid_count, 0)::INT AS bid_count
  FROM auctions a
  JOIN items i ON i.item_id = a.item_id
  LEFT JOIN LATERAL (SELECT MAX(amount) AS high_bid FROM bids WHERE bids.auction_id = a.auction_id) hb ON true
  LEFT JOIN LATERAL (SELECT COUNT(*) AS bid_count FROM bids WHERE bids.auction_id = a.auction_id) bc ON true
 WHERE a.status = 'ACTIVE'
 ORDER BY a.end_time ASC$q$),

(2, 'Top bid for one auction', 'place_bid() floor; every bid',
    'idx_bids_auction_amount', true,
 format($q$SELECT MAX(b.amount) FROM bids b WHERE b.auction_id = %s$q$, :bench_auction)),

(3, 'Leading bid (tie-break)', 'trg_close_auction, award_winner, trg_outbid',
    'idx_bids_auction_amount', false,
 format($q$SELECT b.bid_id, b.amount FROM bids b WHERE b.auction_id = %s
 ORDER BY b.amount DESC, b.placed_at ASC LIMIT 1$q$, :bench_auction)),

(4, 'My bids history', 'GET /api/me/bids',
    'idx_bids_bidder_placed', true,
 format($q$SELECT b.bid_id, b.auction_id, b.amount, b.placed_at,
       a.status AS auction_status, a.end_time, a.winning_bid_id,
       i.title AS item_title,
       (a.winning_bid_id IS NOT NULL AND b.bid_id = a.winning_bid_id) AS won
  FROM bids b
  JOIN auctions a ON a.auction_id = b.auction_id
  JOIN items i ON i.item_id = a.item_id
 WHERE b.bidder_id = %s
 ORDER BY b.placed_at DESC$q$, :bench_bidder)),

(5, 'Expired-auction cursor', 'close_expired_auctions()',
    'idx_auctions_active_end', true,
 $q$SELECT auction_id, item_id FROM auctions
 WHERE end_time < now() AND status = 'ACTIVE'
 ORDER BY end_time$q$),

(6, 'Unread notifications', 'bell count (unread only)',
    'idx_notifications_user_unread', false,
 format($q$SELECT notification_id, type, title, created_at FROM notifications
 WHERE user_id = %s AND is_read = false
 ORDER BY created_at DESC$q$, :bench_notif_user)),

(7, 'Notification list (current route)', 'GET /api/notifications',
    'none — no is_read predicate', false,
 format($q$SELECT notification_id, type, title, message, auction_id, is_read, created_at
  FROM notifications
 WHERE user_id = %s
 ORDER BY is_read ASC, created_at DESC$q$, :bench_notif_user)),

(8, 'Category tree (recursive CTE)', 'GET /api/categories/tree',
    'idx_categories_parent', false,
 format($q$SELECT * FROM get_category_tree(%s)$q$, :bench_root_category)),

(9, 'Items in a category subtree', 'GET /api/items?category=',
    'idx_items_category, idx_categories_parent', false,
 format($q$SELECT i.item_id, i.seller_id, i.category_id, i.title, i.description, i.condition,
       i.attributes, i.image_url, i.created_at, c.name AS category_name, u.full_name AS seller_name
  FROM items i
  JOIN categories c ON c.category_id = i.category_id
  JOIN users u ON u.user_id = i.seller_id
 WHERE i.category_id IN (SELECT category_id FROM get_category_tree(%s))
 ORDER BY i.created_at DESC
 LIMIT 20 OFFSET 0$q$, :bench_sub_category)),

(10, 'Items by seller', 'GET /api/items?seller=',
    'idx_items_seller', false,
 format($q$SELECT i.item_id, i.seller_id, i.category_id, i.title, i.description, i.condition,
       i.attributes, i.image_url, i.created_at, c.name AS category_name, u.full_name AS seller_name
  FROM items i
  JOIN categories c ON c.category_id = i.category_id
  JOIN users u ON u.user_id = i.seller_id
 WHERE i.seller_id = %s
 ORDER BY i.created_at DESC
 LIMIT 20 OFFSET 0$q$, :bench_seller)),

(11, 'Keyword search', 'GET /api/items?q=',
    'idx_items_title_trgm', false,
 format($q$SELECT i.item_id, i.seller_id, i.category_id, i.title, i.description, i.condition,
       i.attributes, i.image_url, i.created_at, c.name AS category_name, u.full_name AS seller_name
  FROM items i
  JOIN categories c ON c.category_id = i.category_id
  JOIN users u ON u.user_id = i.seller_id
 WHERE i.title ILIKE %L
 ORDER BY i.created_at DESC
 LIMIT 20 OFFSET 0$q$, '%' || :'bench_term' || '%')),

(12, 'JSONB attribute search', 'attributes @> filter',
    'idx_items_attributes', false,
 format($q$SELECT item_id, title FROM items WHERE attributes @> %L::jsonb$q$, :'bench_attrs'));


-- -----------------------------------------------------------------------------
-- 5. Measurement helper. For each query: one warm-up execution, then p_runs
--    EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) runs (median execution time kept),
--    then one text-format EXPLAIN (ANALYZE, BUFFERS) kept for printing.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE bench_result (
    id           INT,
    phase        TEXT,           -- 'before' | 'after'
    exec_ms      NUMERIC,        -- median execution time
    planning_ms  NUMERIC,
    buffers      BIGINT,         -- shared hit + read blocks, whole plan
    scans        TEXT,           -- scan nodes on tables / indexes
    plan_text    TEXT
) ON COMMIT DROP;

CREATE FUNCTION pg_temp.bench_run(p_phase TEXT, p_suite TEXT DEFAULT 'index', p_runs INT DEFAULT 3)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    q        RECORD;
    r        RECORD;
    v_plan   JSONB;
    v_times  NUMERIC[];
    v_text   TEXT;
BEGIN
    FOR q IN SELECT * FROM bench_query WHERE suite = p_suite ORDER BY id LOOP
        EXECUTE q.sql;                                   -- warm-up, result discarded

        v_times := '{}';
        FOR i IN 1..p_runs LOOP
            EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || q.sql INTO v_plan;
            v_times := v_times || (v_plan->0->>'Execution Time')::NUMERIC;
        END LOOP;

        v_text := '';
        FOR r IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS) ' || q.sql LOOP
            v_text := v_text || r."QUERY PLAN" || E'\n';
        END LOOP;

        INSERT INTO bench_result
        SELECT q.id,
               p_phase,
               (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY t) FROM unnest(v_times) t),
               (v_plan->0->>'Planning Time')::NUMERIC,
               (v_plan->0->'Plan'->>'Shared Hit Blocks')::BIGINT
                 + (v_plan->0->'Plan'->>'Shared Read Blocks')::BIGINT,
               (SELECT string_agg(DISTINCT
                           (n->>'Node Type')
                           || COALESCE(' on ' || (n->>'Relation Name'), '')
                           || COALESCE(' using ' || (n->>'Index Name'), '')
                           || COALESCE(' ' || (n->>'Function Name') || '()', ''),
                       '; ')
                  FROM jsonb_path_query(v_plan->0->'Plan', 'strict $.**') n
                 WHERE jsonb_typeof(n) = 'object'
                   AND (n ? 'Relation Name' OR n ? 'Index Name' OR n ? 'Function Name')),
               v_text;
    END LOOP;
END;
$$;


-- -----------------------------------------------------------------------------
-- 6. BEFORE — no secondary indexes
-- -----------------------------------------------------------------------------
\echo
\echo '== BEFORE: timing every query with no secondary indexes...'
SELECT pg_temp.bench_run('before');


-- -----------------------------------------------------------------------------
-- 7. AFTER — the exact index definitions that ship in db/05_indexes.sql
-- -----------------------------------------------------------------------------
\echo '== Creating indexes from db/05_indexes.sql...'
\ir ../05_indexes.sql

\echo '== AFTER: timing every query with the indexes...'
SELECT pg_temp.bench_run('after');


-- -----------------------------------------------------------------------------
-- 8. Results
-- -----------------------------------------------------------------------------
\echo
\echo '== Synthetic data volume'
SELECT 'users' AS table_name, count(*) AS rows FROM users
UNION ALL SELECT 'categories',    count(*) FROM categories
UNION ALL SELECT 'items',         count(*) FROM items
UNION ALL SELECT 'auctions',      count(*) FROM auctions
UNION ALL SELECT 'auctions (ACTIVE)', count(*) FROM auctions WHERE status = 'ACTIVE'
UNION ALL SELECT 'bids',          count(*) FROM bids
UNION ALL SELECT 'notifications', count(*) FROM notifications
UNION ALL SELECT 'notifications (unread)', count(*) FROM notifications WHERE NOT is_read;

\echo
\echo '== Before / after (median of 3 runs, warm cache)'
SELECT q.id,
       q.label,
       b.exec_ms::NUMERIC(10,3)                          AS before_ms,
       a.exec_ms::NUMERIC(10,3)                          AS after_ms,
       round(b.exec_ms / NULLIF(a.exec_ms, 0), 1)        AS speedup,
       b.buffers                                         AS before_buf,
       a.buffers                                         AS after_buf,
       b.planning_ms::NUMERIC(10,3)                      AS before_plan_ms,
       a.planning_ms::NUMERIC(10,3)                      AS after_plan_ms
  FROM bench_query q
  JOIN bench_result b ON b.id = q.id AND b.phase = 'before'
  JOIN bench_result a ON a.id = q.id AND a.phase = 'after'
 ORDER BY q.id;

\echo
\echo '== Scan nodes chosen by the planner'
\x on
SELECT q.id, q.label, q.serves, b.scans AS before_scans, a.scans AS after_scans
  FROM bench_query q
  JOIN bench_result b ON b.id = q.id AND b.phase = 'before'
  JOIN bench_result a ON a.id = q.id AND a.phase = 'after'
 ORDER BY q.id;
\x off

\echo
\echo '== Index sizes (plus two throwaway full indexes, to show what the partial ones save)'
CREATE INDEX bench_full_auctions_end_time ON auctions (end_time);
CREATE INDEX bench_full_notifications_user ON notifications (user_id);
SELECT c.relname                              AS index_name,
       t.relname                              AS on_table,
       pg_size_pretty(pg_relation_size(c.oid)) AS size,
       pg_relation_size(c.oid)                AS bytes
  FROM pg_class c
  JOIN pg_index x ON x.indexrelid = c.oid
  JOIN pg_class t ON t.oid = x.indrelid
 WHERE c.relname IN ('idx_bids_auction_amount', 'idx_auctions_active_end', 'idx_items_category',
                     'idx_items_seller', 'idx_bids_bidder_placed', 'idx_notifications_user_unread',
                     'idx_categories_parent', 'idx_items_attributes', 'idx_items_title_trgm',
                     'bench_full_auctions_end_time', 'bench_full_notifications_user')
 ORDER BY t.relname, c.relname;

\echo
\echo '== Full EXPLAIN (ANALYZE, BUFFERS) for the four headline queries'
\pset format unaligned
\pset tuples_only on
SELECT format(E'---- Q%s %s — %s ----\n%s', q.id, q.label, upper(r.phase), r.plan_text)
  FROM bench_query q
  JOIN bench_result r ON r.id = q.id
 WHERE q.key_query
 ORDER BY q.id, r.phase DESC;
\pset tuples_only off
\pset format aligned


-- -----------------------------------------------------------------------------
-- 9. Technique 10: plain view vs materialized view (db/06_views.sql).
--    The same report read two ways: v_auction_summary recomputes it on every
--    SELECT, mv_leaderboard returns the result stored at its last REFRESH.
--    Skipped if db/06_views.sql has not been loaded.
-- -----------------------------------------------------------------------------
SELECT EXISTS (SELECT 1 FROM pg_matviews WHERE matviewname = 'mv_leaderboard') AS has_mv
\gset bench_

\if :bench_has_mv

-- Bring the snapshot up to date with the synthetic rows before reading it.
REFRESH MATERIALIZED VIEW mv_leaderboard;
ANALYZE mv_leaderboard;

INSERT INTO bench_query (id, label, source, serves, key_query, sql, suite) VALUES
(101, 'Full report: plain view', 'v_auction_summary', 'recomputed on every read', false,
 $q$SELECT * FROM v_auction_summary$q$, 'views'),
(102, 'Full report: materialized view', 'mv_leaderboard', 'stored result', false,
 $q$SELECT * FROM mv_leaderboard$q$, 'views'),
(103, 'Live auctions page: plain view', 'v_auction_summary', 'recomputed on every read', false,
 $q$SELECT * FROM v_auction_summary WHERE status = 'ACTIVE' ORDER BY end_time$q$, 'views'),
(104, 'Live auctions page: materialized view', 'mv_leaderboard', 'stored result', false,
 $q$SELECT * FROM mv_leaderboard WHERE status = 'ACTIVE' ORDER BY end_time$q$, 'views'),
(105, 'Live auctions page: lean v_active_auctions', 'v_active_auctions', 'recomputed, index-backed', false,
 $q$SELECT * FROM v_active_auctions ORDER BY end_time$q$, 'views'),
(106, 'One auction: plain view', 'v_auction_summary', 'recomputed on every read', false,
 format($q$SELECT * FROM v_auction_summary WHERE auction_id = %s$q$, :bench_auction), 'views'),
(107, 'One auction: materialized view', 'mv_leaderboard', 'stored result', false,
 format($q$SELECT * FROM mv_leaderboard WHERE auction_id = %s$q$, :bench_auction), 'views');

\echo
\echo '== Plain view vs materialized view: timing reads...'
SELECT pg_temp.bench_run('views', 'views');

-- The other side of the trade-off: what a REFRESH costs. Both kinds, 3 runs
-- each, nothing changed in between (steady state).
CREATE TEMP TABLE bench_refresh (kind TEXT, ms NUMERIC) ON COMMIT DROP;
DO $$
DECLARE
    t0 TIMESTAMPTZ;
BEGIN
    FOR i IN 1..3 LOOP
        t0 := clock_timestamp();
        REFRESH MATERIALIZED VIEW mv_leaderboard;
        INSERT INTO bench_refresh VALUES ('REFRESH', 1000 * EXTRACT(EPOCH FROM clock_timestamp() - t0));

        t0 := clock_timestamp();
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_leaderboard;
        INSERT INTO bench_refresh VALUES ('REFRESH CONCURRENTLY', 1000 * EXTRACT(EPOCH FROM clock_timestamp() - t0));
    END LOOP;
END $$;

\echo
\echo '== Plain view vs materialized view (median of 3 runs, warm cache)'
SELECT q.id, q.label, r.exec_ms::NUMERIC(10,3) AS median_ms, r.buffers, r.scans
  FROM bench_query q
  JOIN bench_result r ON r.id = q.id AND r.phase = 'views'
 ORDER BY q.id;

\echo '== REFRESH cost (median of 3 runs)'
SELECT kind, (percentile_cont(0.5) WITHIN GROUP (ORDER BY ms))::NUMERIC(10,3) AS median_ms
  FROM bench_refresh
 GROUP BY kind
 ORDER BY kind;

SELECT (SELECT count(*) FROM mv_leaderboard)                   AS mv_rows,
       pg_size_pretty(pg_total_relation_size('mv_leaderboard')) AS mv_size_with_index;

\echo '== EXPLAIN (ANALYZE, BUFFERS): full report, plain view vs materialized view'
\pset format unaligned
\pset tuples_only on
SELECT format(E'---- Q%s %s ----\n%s', q.id, q.label, r.plan_text)
  FROM bench_query q
  JOIN bench_result r ON r.id = q.id AND r.phase = 'views'
 WHERE q.id IN (101, 102)
 ORDER BY q.id;
\pset tuples_only off
\pset format aligned

\else
\echo
\echo '== mv_leaderboard not found (db/06_views.sql not loaded): skipping plain view vs materialized view.'
\endif

ROLLBACK;

\echo
\echo 'Benchmark complete. Transaction rolled back: no synthetic data, index or trigger change remains.'
