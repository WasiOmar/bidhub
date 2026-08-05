-- =============================================================================
-- db/tests/test_schema.sql
-- Proves the CHECK/UNIQUE constraints in db/01_schema.sql actually reject bad
-- data. Everything runs inside one transaction that is rolled back at the end,
-- so this is safe to re-run against a live database with no residue.
-- Owner: Person 1 (Database Core)
--
-- Run:  psql "$DATABASE_URL" -f db/tests/test_schema.sql
-- Read the RAISE NOTICE lines below the four "-- Test" headers: every one
-- must say PASS. A FAIL means the schema stopped enforcing a rule it should.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
INSERT INTO users (full_name, email, password_hash, role) VALUES
    ('Test Seller', 'test-seller@bidhub.local', 'x', 'SELLER'),
    ('Test Buyer',  'test-buyer@bidhub.local',  'x', 'BUYER');

INSERT INTO categories (name, slug) VALUES ('Test Category', 'test-category');

INSERT INTO items (seller_id, category_id, title)
SELECT u.user_id, c.category_id, 'Test Item A'
FROM users u, categories c
WHERE u.email = 'test-seller@bidhub.local' AND c.slug = 'test-category';

INSERT INTO items (seller_id, category_id, title)
SELECT u.user_id, c.category_id, 'Test Item B'
FROM users u, categories c
WHERE u.email = 'test-seller@bidhub.local' AND c.slug = 'test-category';

INSERT INTO auctions (item_id, starting_price, end_time)
SELECT item_id, 100.00, now() + interval '1 day'
FROM items WHERE title = 'Test Item A';

-- ---------------------------------------------------------------------------
-- Test 1 — chk_auctions_end_after_start rejects end_time <= start_time
-- ---------------------------------------------------------------------------
SAVEPOINT test_end_before_start;
DO $$
BEGIN
    INSERT INTO auctions (item_id, starting_price, start_time, end_time)
    SELECT item_id, 50.00, now(), now() - interval '1 hour'
    FROM items WHERE title = 'Test Item B';

    RAISE EXCEPTION 'BIDHUB_TEST_FAILED: end_time <= start_time was accepted';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'PASS  chk_auctions_end_after_start rejected end_time <= start_time (%)', SQLERRM;
    WHEN OTHERS THEN
        RAISE NOTICE 'FAIL  test_end_before_start: unexpected result — %', SQLERRM;
END $$;
ROLLBACK TO SAVEPOINT test_end_before_start;

-- ---------------------------------------------------------------------------
-- Test 2 — chk_bids_amount_positive rejects amount <= 0
-- ---------------------------------------------------------------------------
SAVEPOINT test_negative_bid;
DO $$
BEGIN
    INSERT INTO bids (auction_id, bidder_id, amount)
    SELECT a.auction_id, u.user_id, -25.00
    FROM auctions a
    JOIN items i ON i.item_id = a.item_id AND i.title = 'Test Item A'
    JOIN users u ON u.email = 'test-buyer@bidhub.local';

    RAISE EXCEPTION 'BIDHUB_TEST_FAILED: a negative bid amount was accepted';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'PASS  chk_bids_amount_positive rejected a negative bid (%)', SQLERRM;
    WHEN OTHERS THEN
        RAISE NOTICE 'FAIL  test_negative_bid: unexpected result — %', SQLERRM;
END $$;
ROLLBACK TO SAVEPOINT test_negative_bid;

-- ---------------------------------------------------------------------------
-- Test 3 — chk_categories_no_self_parent rejects a category parenting itself
-- ---------------------------------------------------------------------------
SAVEPOINT test_self_parent_category;
DO $$
BEGIN
    UPDATE categories
    SET parent_id = category_id
    WHERE slug = 'test-category';

    RAISE EXCEPTION 'BIDHUB_TEST_FAILED: a category was allowed to parent itself';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'PASS  chk_categories_no_self_parent rejected self-parenting (%)', SQLERRM;
    WHEN OTHERS THEN
        RAISE NOTICE 'FAIL  test_self_parent_category: unexpected result — %', SQLERRM;
END $$;
ROLLBACK TO SAVEPOINT test_self_parent_category;

-- ---------------------------------------------------------------------------
-- Test 4 — uq_transactions_auction rejects a second transaction for one auction
-- ---------------------------------------------------------------------------
SAVEPOINT test_double_settlement;
DO $$
DECLARE
    v_auction_id INT;
    v_item_id    INT;
    v_seller_id  INT;
    v_buyer_id   INT;
BEGIN
    SELECT a.auction_id, i.item_id, i.seller_id
      INTO v_auction_id, v_item_id, v_seller_id
    FROM auctions a
    JOIN items i ON i.item_id = a.item_id
    WHERE i.title = 'Test Item A';

    SELECT user_id INTO v_buyer_id FROM users WHERE email = 'test-buyer@bidhub.local';

    INSERT INTO transactions (auction_id, buyer_id, seller_id, item_id, final_amount)
    VALUES (v_auction_id, v_buyer_id, v_seller_id, v_item_id, 150.00);

    -- Second settlement of the SAME auction must be rejected.
    INSERT INTO transactions (auction_id, buyer_id, seller_id, item_id, final_amount)
    VALUES (v_auction_id, v_buyer_id, v_seller_id, v_item_id, 175.00);

    RAISE EXCEPTION 'BIDHUB_TEST_FAILED: an auction was settled with two transactions';
EXCEPTION
    WHEN unique_violation THEN
        RAISE NOTICE 'PASS  uq_transactions_auction rejected a second settlement (%)', SQLERRM;
    WHEN OTHERS THEN
        RAISE NOTICE 'FAIL  test_double_settlement: unexpected result — %', SQLERRM;
END $$;
ROLLBACK TO SAVEPOINT test_double_settlement;

-- ---------------------------------------------------------------------------
-- No residue: undo every fixture.
-- ---------------------------------------------------------------------------
ROLLBACK;

SELECT 'test_schema.sql: all constraint checks exercised — verify every line above says PASS' AS result;
