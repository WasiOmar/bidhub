-- =============================================================================
-- db/tests/test_queries.sql
-- Exercises db/04_queries.sql: the leaderboard CTE, the recursive category
-- tree (both directions, plus the roll-up), and the window-function views.
-- Owner: Person 2 (Procedural SQL & Performance)
--
-- Run:  psql "$DATABASE_URL" -f db/tests/test_queries.sql
-- Read the RAISE NOTICE lines: every one must say PASS.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Fixtures: a 4-level category tree (Electronics -> Computers -> Laptops ->
-- Gaming Laptops), one item in the deepest leaf, one live auction on it,
-- three bids from two bidders, and a couple of settled transactions for the
-- window-function views that read off `transactions` rather than `bids`.
-- ---------------------------------------------------------------------------
INSERT INTO users (full_name, email, password_hash, role) VALUES
    ('Queries Seller',  'queries-seller@bidhub.local',  'x', 'SELLER'),
    ('Queries Bidder 1','queries-bidder1@bidhub.local', 'x', 'BUYER'),
    ('Queries Bidder 2','queries-bidder2@bidhub.local', 'x', 'BUYER');

INSERT INTO categories (name, slug, parent_id) VALUES
    ('QT Electronics', 'qt-electronics', NULL);
INSERT INTO categories (name, slug, parent_id)
    SELECT 'QT Computers', 'qt-computers', category_id FROM categories WHERE slug = 'qt-electronics';
INSERT INTO categories (name, slug, parent_id)
    SELECT 'QT Laptops', 'qt-laptops', category_id FROM categories WHERE slug = 'qt-computers';
INSERT INTO categories (name, slug, parent_id)
    SELECT 'QT Gaming Laptops', 'qt-gaming-laptops', category_id FROM categories WHERE slug = 'qt-laptops';

INSERT INTO items (seller_id, category_id, title)
SELECT u.user_id, c.category_id, 'Queries Test Laptop'
FROM users u, categories c
WHERE u.email = 'queries-seller@bidhub.local' AND c.slug = 'qt-gaming-laptops';

INSERT INTO auctions (item_id, starting_price, bid_increment, end_time, status)
SELECT item_id, 500.00, 50.00, now() + interval '1 day', 'ACTIVE'
FROM items WHERE title = 'Queries Test Laptop';

-- Three bids via place_bid (already-merged P2-01), so trg_outbid/trg_audit_bid
-- fire naturally: Bidder 1 opens at 500, Bidder 2 outbids at 600, Bidder 1
-- retakes the lead at 700.
DO $$
DECLARE
    v_auction_id INT;
    v_bidder1_id INT;
    v_bidder2_id INT;
BEGIN
    SELECT a.auction_id INTO v_auction_id
    FROM auctions a JOIN items i ON i.item_id = a.item_id
    WHERE i.title = 'Queries Test Laptop';

    SELECT user_id INTO v_bidder1_id FROM users WHERE email = 'queries-bidder1@bidhub.local';
    SELECT user_id INTO v_bidder2_id FROM users WHERE email = 'queries-bidder2@bidhub.local';

    CALL place_bid(v_bidder1_id, v_auction_id, 500.00);
    CALL place_bid(v_bidder2_id, v_auction_id, 600.00);
    CALL place_bid(v_bidder1_id, v_auction_id, 700.00);

    -- now() is frozen for the whole transaction in Postgres, so all three
    -- bids just landed with the SAME placed_at -- fine for get_leaderboard
    -- (amount alone already disambiguates 500/600/700), but v_bid_momentum's
    -- ORDER BY placed_at needs real, distinct instants to be deterministic.
    -- Stagger by bid_id, which DOES reflect true insertion order (SERIAL PK).
    UPDATE bids
       SET placed_at = placed_at
           + (bid_id - (SELECT MIN(bid_id) FROM bids WHERE auction_id = v_auction_id)) * interval '1 second'
     WHERE auction_id = v_auction_id;
END $$;

-- Two settled transactions for the same seller, seeded directly (no auction
-- close flow needed here -- these exist purely to exercise v_seller_revenue
-- and v_category_leaderboard, which read `transactions`, not `bids`).
-- created_at is set explicitly (now() is frozen for the whole transaction in
-- Postgres, so two plain DEFAULT now() rows here would tie) so the running
-- total in v_seller_revenue has an unambiguous first/second row to check.
INSERT INTO transactions (auction_id, buyer_id, seller_id, item_id, final_amount, status, created_at)
SELECT a.auction_id,
       (SELECT user_id FROM users WHERE email = 'queries-bidder1@bidhub.local'),
       (SELECT user_id FROM users WHERE email = 'queries-seller@bidhub.local'),
       a.item_id, 700.00, 'COMPLETED', now() - interval '1 minute'
FROM auctions a JOIN items i ON i.item_id = a.item_id
WHERE i.title = 'Queries Test Laptop';

-- A second item/auction/transaction for the same seller so v_seller_revenue
-- has two rows to accumulate across.
INSERT INTO items (seller_id, category_id, title)
SELECT u.user_id, c.category_id, 'Queries Test Laptop 2'
FROM users u, categories c
WHERE u.email = 'queries-seller@bidhub.local' AND c.slug = 'qt-gaming-laptops';

INSERT INTO auctions (item_id, starting_price, bid_increment, end_time, status)
SELECT item_id, 300.00, 25.00, now() + interval '1 day', 'ACTIVE'
FROM items WHERE title = 'Queries Test Laptop 2';

INSERT INTO transactions (auction_id, buyer_id, seller_id, item_id, final_amount, status, created_at)
SELECT a.auction_id,
       (SELECT user_id FROM users WHERE email = 'queries-bidder2@bidhub.local'),
       (SELECT user_id FROM users WHERE email = 'queries-seller@bidhub.local'),
       a.item_id, 350.00, 'COMPLETED', now()
FROM auctions a JOIN items i ON i.item_id = a.item_id
WHERE i.title = 'Queries Test Laptop 2';

-- ---------------------------------------------------------------------------
-- Test 1 — get_category_tree(root): 4 rows, depth 0..3, in path order.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_root_id    INT;
    v_row_count  INT;
    v_depths     INT[];
    v_raw_paths  TEXT[][];
    v_sorted_paths TEXT[][];
BEGIN
    SELECT category_id INTO v_root_id FROM categories WHERE slug = 'qt-electronics';

    SELECT count(*) INTO v_row_count FROM get_category_tree(v_root_id);

    SELECT array_agg(depth ORDER BY depth) INTO v_depths FROM get_category_tree(v_root_id);

    -- The function itself must already return path order -- no ORDER BY
    -- added here by the caller. Compare the function's raw row order
    -- against the same rows explicitly re-sorted by path; they must match.
    SELECT array_agg(path) INTO v_raw_paths FROM get_category_tree(v_root_id);
    SELECT array_agg(path ORDER BY path) INTO v_sorted_paths FROM get_category_tree(v_root_id);

    IF v_row_count = 4
       AND v_depths = ARRAY[0,1,2,3]
       AND v_raw_paths = v_sorted_paths
    THEN
        RAISE NOTICE 'PASS  get_category_tree returns exactly 4 rows, depth 0..3, already in path order';
    ELSE
        RAISE NOTICE 'FAIL  test_category_tree: row_count=% (want 4), depths=% (want {0,1,2,3}), already_ordered=%',
            v_row_count, v_depths, (v_raw_paths = v_sorted_paths);
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 2 — get_category_breadcrumb(leaf): 4 rows, root first, leaf last.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_leaf_id   INT;
    v_row_count INT;
    v_first_name VARCHAR(100);
    v_last_name  VARCHAR(100);
BEGIN
    SELECT category_id INTO v_leaf_id FROM categories WHERE slug = 'qt-gaming-laptops';

    SELECT count(*) INTO v_row_count FROM get_category_breadcrumb(v_leaf_id);

    SELECT name INTO v_first_name FROM get_category_breadcrumb(v_leaf_id) ORDER BY depth DESC LIMIT 1;
    SELECT name INTO v_last_name  FROM get_category_breadcrumb(v_leaf_id) ORDER BY depth ASC  LIMIT 1;

    IF v_row_count = 4 AND v_first_name = 'QT Electronics' AND v_last_name = 'QT Gaming Laptops' THEN
        RAISE NOTICE 'PASS  get_category_breadcrumb returns 4 rows, root (%) first, leaf (%) last', v_first_name, v_last_name;
    ELSE
        RAISE NOTICE 'FAIL  test_breadcrumb: row_count=% (want 4), first=%, last=%', v_row_count, v_first_name, v_last_name;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 3 — get_category_item_counts(): the roll-up. Gaming Laptops has 2
-- direct items and no children of its own, so every ancestor up to
-- Electronics must report subtree_items = 2 too, by rolling those same 2
-- items up through the chain (nothing else exists anywhere in this tree).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_leaf_direct    BIGINT;
    v_root_subtree   BIGINT;
BEGIN
    SELECT direct_items INTO v_leaf_direct
    FROM get_category_item_counts() ic
    JOIN categories c ON c.category_id = ic.category_id
    WHERE c.slug = 'qt-gaming-laptops';

    SELECT subtree_items INTO v_root_subtree
    FROM get_category_item_counts() ic
    JOIN categories c ON c.category_id = ic.category_id
    WHERE c.slug = 'qt-electronics';

    IF v_leaf_direct = 2 AND v_root_subtree = 2 THEN
        RAISE NOTICE 'PASS  get_category_item_counts rolls up: Gaming Laptops direct=%, Electronics subtree=%', v_leaf_direct, v_root_subtree;
    ELSE
        RAISE NOTICE 'FAIL  test_item_counts: leaf_direct=% (want 2), root_subtree=% (want 2)', v_leaf_direct, v_root_subtree;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 4 — get_leaderboard(auction): row 1 is the highest bid (700.00 by
-- Bidder 1), and is_leading is true only for that row.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_auction_id   INT;
    v_top_amount   NUMERIC(12,2);
    v_top_leading  BOOLEAN;
    v_leading_count INT;
BEGIN
    SELECT a.auction_id INTO v_auction_id
    FROM auctions a JOIN items i ON i.item_id = a.item_id
    WHERE i.title = 'Queries Test Laptop';

    SELECT amount, is_leading INTO v_top_amount, v_top_leading
    FROM get_leaderboard(v_auction_id) WHERE position = 1;

    SELECT count(*) INTO v_leading_count FROM get_leaderboard(v_auction_id) WHERE is_leading;

    IF v_top_amount = 700.00 AND v_top_leading AND v_leading_count = 1 THEN
        RAISE NOTICE 'PASS  get_leaderboard: row 1 is the highest bid (%), exactly one is_leading row', v_top_amount;
    ELSE
        RAISE NOTICE 'FAIL  test_leaderboard: top_amount=% (want 700.00), top_leading=%, leading_count=% (want 1)',
            v_top_amount, v_top_leading, v_leading_count;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 5 — v_bid_momentum: LAG returns NULL for each auction's first bid.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_auction_id      INT;
    v_first_previous  NUMERIC(12,2);
    v_first_jump      NUMERIC(12,2);
    v_second_previous NUMERIC(12,2);
BEGIN
    SELECT a.auction_id INTO v_auction_id
    FROM auctions a JOIN items i ON i.item_id = a.item_id
    WHERE i.title = 'Queries Test Laptop';

    SELECT previous_amount, amount_jump INTO v_first_previous, v_first_jump
    FROM v_bid_momentum WHERE auction_id = v_auction_id ORDER BY placed_at ASC LIMIT 1;

    SELECT previous_amount INTO v_second_previous
    FROM v_bid_momentum WHERE auction_id = v_auction_id ORDER BY placed_at ASC OFFSET 1 LIMIT 1;

    IF v_first_previous IS NULL AND v_first_jump IS NULL AND v_second_previous IS NOT NULL THEN
        RAISE NOTICE 'PASS  v_bid_momentum: LAG is NULL for the first bid, populated from the second bid onward';
    ELSE
        RAISE NOTICE 'FAIL  test_bid_momentum: first_previous=% (want NULL), first_jump=% (want NULL), second_previous=% (want NOT NULL)',
            v_first_previous, v_first_jump, v_second_previous;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 6 — v_top_bidders: Bidder 1 (500+700=1200 total) outranks Bidder 2
-- (600 total) with a strictly lower (better) rank number.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_rank1 INT;
    v_rank2 INT;
    v_total1 NUMERIC(12,2);
    v_total2 NUMERIC(12,2);
BEGIN
    SELECT rank, total_bid_value INTO v_rank1, v_total1
    FROM v_top_bidders WHERE full_name = 'Queries Bidder 1';

    SELECT rank, total_bid_value INTO v_rank2, v_total2
    FROM v_top_bidders WHERE full_name = 'Queries Bidder 2';

    IF v_total1 = 1200.00 AND v_total2 = 600.00 AND v_rank1 < v_rank2 THEN
        RAISE NOTICE 'PASS  v_top_bidders: Bidder 1 (total=%, rank=%) outranks Bidder 2 (total=%, rank=%)',
            v_total1, v_rank1, v_total2, v_rank2;
    ELSE
        RAISE NOTICE 'FAIL  test_top_bidders: total1=%, rank1=%, total2=%, rank2=%', v_total1, v_rank1, v_total2, v_rank2;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 7 — v_seller_revenue: running total across the seller's two
-- transactions (700.00 then 350.00, by created_at) accumulates correctly:
-- 700.00 after the first, 1050.00 after the second.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_seller_id      INT;
    v_first_running  NUMERIC(12,2);
    v_second_running NUMERIC(12,2);
BEGIN
    SELECT user_id INTO v_seller_id FROM users WHERE email = 'queries-seller@bidhub.local';

    SELECT running_revenue INTO v_first_running
    FROM v_seller_revenue WHERE seller_id = v_seller_id ORDER BY created_at ASC LIMIT 1;

    SELECT running_revenue INTO v_second_running
    FROM v_seller_revenue WHERE seller_id = v_seller_id ORDER BY created_at ASC OFFSET 1 LIMIT 1;

    IF v_first_running = 700.00 AND v_second_running = 1050.00 THEN
        RAISE NOTICE 'PASS  v_seller_revenue: running total accumulates correctly (% -> %)', v_first_running, v_second_running;
    ELSE
        RAISE NOTICE 'FAIL  test_seller_revenue: first_running=% (want 700.00), second_running=% (want 1050.00)', v_first_running, v_second_running;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- No residue: undo every fixture.
-- ---------------------------------------------------------------------------
ROLLBACK;

SELECT 'test_queries.sql: leaderboard CTE, recursive category tree, and window-function views all exercised — verify every line above says PASS' AS result;
