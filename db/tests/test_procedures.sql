-- =============================================================================
-- db/tests/test_procedures.sql
-- Exercises place_bid() (db/03_procedures.sql): first-bid floor, the AU001/
-- AU002/AU003 validation paths, and the proof that a successful call also
-- fires the P1 triggers (one bids row AND one audit_log row per bid).
-- Owner: Person 2 (Procedural SQL & Performance)
--
-- Run:  psql "$DATABASE_URL" -f db/tests/test_procedures.sql
-- Read the RAISE NOTICE lines: every one must say PASS.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
INSERT INTO users (full_name, email, password_hash, role) VALUES
    ('Proc Seller',  'proc-seller@bidhub.local',  'x', 'SELLER'),
    ('Proc Bidder 1','proc-bidder1@bidhub.local', 'x', 'BUYER'),
    ('Proc Bidder 2','proc-bidder2@bidhub.local', 'x', 'BUYER');

INSERT INTO categories (name, slug) VALUES ('Procedure Test Category', 'proc-test-category');

INSERT INTO items (seller_id, category_id, title)
SELECT u.user_id, c.category_id, t.title
FROM users u, categories c,
     (VALUES
        ('Proc Test Item - Active'),
        ('Proc Test Item - Closed')
     ) AS t(title)
WHERE u.email = 'proc-seller@bidhub.local' AND c.slug = 'proc-test-category';

INSERT INTO auctions (item_id, starting_price, bid_increment, end_time, status)
SELECT item_id, 100.00, 10.00, now() + interval '1 day', 'ACTIVE'
FROM items WHERE title = 'Proc Test Item - Active';

INSERT INTO auctions (item_id, starting_price, bid_increment, end_time, status)
SELECT item_id, 50.00, 5.00, now() - interval '1 hour', 'CLOSED'
FROM items WHERE title = 'Proc Test Item - Closed';

-- ---------------------------------------------------------------------------
-- Test 1 — first bid at exactly starting_price succeeds, and it also leaves
--          exactly one bids row AND one audit_log row (proving the P1
--          triggers fired off the back of this one CALL).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_auction_id  INT;
    v_bidder1_id  INT;
    v_bid_count   INT;
    v_audit_count INT;
BEGIN
    SELECT a.auction_id INTO v_auction_id
    FROM auctions a JOIN items i ON i.item_id = a.item_id
    WHERE i.title = 'Proc Test Item - Active';

    SELECT user_id INTO v_bidder1_id FROM users WHERE email = 'proc-bidder1@bidhub.local';

    CALL place_bid(v_bidder1_id, v_auction_id, 100.00);

    SELECT count(*) INTO v_bid_count FROM bids WHERE auction_id = v_auction_id;
    SELECT count(*) INTO v_audit_count
    FROM audit_log WHERE entity_type = 'auction' AND entity_id = v_auction_id AND action = 'BID_PLACED';

    IF v_bid_count = 1 AND v_audit_count = 1 THEN
        RAISE NOTICE 'PASS  place_bid accepted the opening bid at starting_price and fired the triggers (1 bid, 1 audit row)';
    ELSE
        RAISE NOTICE 'FAIL  test_first_bid_at_starting_price: bid_count=% (want 1), audit_count=% (want 1)',
            v_bid_count, v_audit_count;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 2 — a bid below the minimum (max + increment) raises AU001.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_auction_id INT;
    v_bidder2_id INT;
    v_caught     BOOLEAN := false;
BEGIN
    SELECT a.auction_id INTO v_auction_id
    FROM auctions a JOIN items i ON i.item_id = a.item_id
    WHERE i.title = 'Proc Test Item - Active';

    SELECT user_id INTO v_bidder2_id FROM users WHERE email = 'proc-bidder2@bidhub.local';

    BEGIN
        -- current max is 100.00, increment is 10.00 -> minimum is 110.00
        CALL place_bid(v_bidder2_id, v_auction_id, 109.99);
    EXCEPTION
        WHEN SQLSTATE 'AU001' THEN
            v_caught := true;
    END;

    IF v_caught THEN
        RAISE NOTICE 'PASS  place_bid rejected an underbid with AU001';
    ELSE
        RAISE NOTICE 'FAIL  test_underbid_raises_au001: expected AU001, none raised';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 3 — the item's own seller cannot bid on their own auction (AU003).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_auction_id INT;
    v_seller_id  INT;
    v_caught     BOOLEAN := false;
BEGIN
    SELECT a.auction_id INTO v_auction_id
    FROM auctions a JOIN items i ON i.item_id = a.item_id
    WHERE i.title = 'Proc Test Item - Active';

    SELECT user_id INTO v_seller_id FROM users WHERE email = 'proc-seller@bidhub.local';

    BEGIN
        CALL place_bid(v_seller_id, v_auction_id, 200.00);
    EXCEPTION
        WHEN SQLSTATE 'AU003' THEN
            v_caught := true;
    END;

    IF v_caught THEN
        RAISE NOTICE 'PASS  place_bid rejected a self-bid with AU003';
    ELSE
        RAISE NOTICE 'FAIL  test_self_bid_raises_au003: expected AU003, none raised';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 4 — bidding on a CLOSED auction raises AU002.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_auction_id INT;
    v_bidder1_id INT;
    v_caught     BOOLEAN := false;
BEGIN
    SELECT a.auction_id INTO v_auction_id
    FROM auctions a JOIN items i ON i.item_id = a.item_id
    WHERE i.title = 'Proc Test Item - Closed';

    SELECT user_id INTO v_bidder1_id FROM users WHERE email = 'proc-bidder1@bidhub.local';

    BEGIN
        CALL place_bid(v_bidder1_id, v_auction_id, 55.00);
    EXCEPTION
        WHEN SQLSTATE 'AU002' THEN
            v_caught := true;
    END;

    IF v_caught THEN
        RAISE NOTICE 'PASS  place_bid rejected a bid on a CLOSED auction with AU002';
    ELSE
        RAISE NOTICE 'FAIL  test_closed_auction_raises_au002: expected AU002, none raised';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 5 — bidding on a nonexistent auction raises AU004.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_bidder1_id INT;
    v_caught     BOOLEAN := false;
BEGIN
    SELECT user_id INTO v_bidder1_id FROM users WHERE email = 'proc-bidder1@bidhub.local';

    BEGIN
        CALL place_bid(v_bidder1_id, -1, 10.00);
    EXCEPTION
        WHEN SQLSTATE 'AU004' THEN
            v_caught := true;
    END;

    IF v_caught THEN
        RAISE NOTICE 'PASS  place_bid rejected a nonexistent auction with AU004';
    ELSE
        RAISE NOTICE 'FAIL  test_missing_auction_raises_au004: expected AU004, none raised';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- No residue: undo every fixture.
-- ---------------------------------------------------------------------------
ROLLBACK;

SELECT 'test_procedures.sql: place_bid validation and trigger side-effects exercised — verify every line above says PASS' AS result;
