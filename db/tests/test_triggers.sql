-- =============================================================================
-- db/tests/test_triggers.sql
-- Exercises every trigger in db/02_triggers.sql: outbid notification, bid audit
-- log, audit_log immutability, and auction auto-close (win / reserve-not-met /
-- no-bids). Runs inside one transaction, rolled back at the end — safe to
-- re-run against a live database with no residue.
-- Owner: Person 1 (Database Core)
--
-- Run:  psql "$DATABASE_URL" -f db/tests/test_triggers.sql
-- Read the RAISE NOTICE lines: every one must say PASS.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
INSERT INTO users (full_name, email, password_hash, role) VALUES
    ('Trigger Seller',   'trg-seller@bidhub.local',  'x', 'SELLER'),
    ('Trigger Bidder 1', 'trg-bidder1@bidhub.local', 'x', 'BUYER'),
    ('Trigger Bidder 2', 'trg-bidder2@bidhub.local', 'x', 'BUYER');

INSERT INTO categories (name, slug) VALUES ('Trigger Test Category', 'trg-test-category');

INSERT INTO items (seller_id, category_id, title)
SELECT u.user_id, c.category_id, t.title
FROM users u, categories c,
     (VALUES
        ('Trigger Test Item - No Reserve'),
        ('Trigger Test Item - High Reserve'),
        ('Trigger Test Item - No Bids')
     ) AS t(title)
WHERE u.email = 'trg-seller@bidhub.local' AND c.slug = 'trg-test-category';

-- ACTIVE from the start (bypassing SCHEDULED) so a direct status flip to
-- CLOSED later exercises trg_close_auction without needing close_expired_auctions().
INSERT INTO auctions (item_id, starting_price, reserve_price, bid_increment, end_time, status)
SELECT item_id, 100.00, NULL, 10.00, now() + interval '1 day', 'ACTIVE'
FROM items WHERE title = 'Trigger Test Item - No Reserve';

INSERT INTO auctions (item_id, starting_price, reserve_price, bid_increment, end_time, status)
SELECT item_id, 50.00, 500.00, 10.00, now() + interval '1 day', 'ACTIVE'
FROM items WHERE title = 'Trigger Test Item - High Reserve';

INSERT INTO auctions (item_id, starting_price, reserve_price, bid_increment, end_time, status)
SELECT item_id, 75.00, NULL, 5.00, now() + interval '1 day', 'ACTIVE'
FROM items WHERE title = 'Trigger Test Item - No Bids';

-- ---------------------------------------------------------------------------
-- Test 1 — trg_outbid fires exactly once, targeting the displaced bidder;
--          trg_audit_bid logs both bids. (Bids left in place for Test 4.)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_auction_id    INT;
    v_bidder1_id    INT;
    v_bidder2_id    INT;
    v_outbid_count  INT;
    v_outbid_target INT;
    v_audit_count   INT;
BEGIN
    SELECT a.auction_id INTO v_auction_id
    FROM auctions a JOIN items i ON i.item_id = a.item_id
    WHERE i.title = 'Trigger Test Item - No Reserve';

    SELECT user_id INTO v_bidder1_id FROM users WHERE email = 'trg-bidder1@bidhub.local';
    SELECT user_id INTO v_bidder2_id FROM users WHERE email = 'trg-bidder2@bidhub.local';

    INSERT INTO bids (auction_id, bidder_id, amount) VALUES (v_auction_id, v_bidder1_id, 100.00);
    INSERT INTO bids (auction_id, bidder_id, amount) VALUES (v_auction_id, v_bidder2_id, 110.00);

    SELECT count(*) INTO v_outbid_count
    FROM notifications WHERE auction_id = v_auction_id AND type = 'OUTBID';

    SELECT user_id INTO v_outbid_target
    FROM notifications WHERE auction_id = v_auction_id AND type = 'OUTBID';

    SELECT count(*) INTO v_audit_count
    FROM audit_log WHERE entity_type = 'auction' AND entity_id = v_auction_id AND action = 'BID_PLACED';

    IF v_outbid_count = 1 AND v_outbid_target = v_bidder1_id AND v_audit_count = 2 THEN
        RAISE NOTICE 'PASS  trg_outbid fired once (targeting the displaced bidder) and trg_audit_bid logged both bids';
    ELSE
        RAISE NOTICE 'FAIL  test_outbid_and_audit: outbid_count=%, outbid_target=% (want %), audit_count=% (want 2)',
            v_outbid_count, v_outbid_target, v_bidder1_id, v_audit_count;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 2 — trg_audit_immutable rejects UPDATE and DELETE on audit_log.
-- Uses an internal savepoint (PL/pgSQL's own EXCEPTION block) so a real
-- exception here doesn't abort the surrounding transaction.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_audit_id      BIGINT;
    v_update_passed BOOLEAN := false;
    v_delete_passed BOOLEAN := false;
BEGIN
    SELECT audit_id INTO v_audit_id FROM audit_log ORDER BY audit_id LIMIT 1;

    BEGIN
        UPDATE audit_log SET action = 'TAMPERED' WHERE audit_id = v_audit_id;
    EXCEPTION WHEN raise_exception THEN
        v_update_passed := true;
    END;

    BEGIN
        DELETE FROM audit_log WHERE audit_id = v_audit_id;
    EXCEPTION WHEN raise_exception THEN
        v_delete_passed := true;
    END;

    IF v_update_passed AND v_delete_passed THEN
        RAISE NOTICE 'PASS  trg_audit_immutable rejected both UPDATE and DELETE on audit_log';
    ELSE
        RAISE NOTICE 'FAIL  test_audit_immutable: update_rejected=%, delete_rejected=%',
            v_update_passed, v_delete_passed;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 3 — trg_close_auction settles a winner: one transaction row, WON to
--          the top bidder, SOLD to the seller.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_auction_id   INT;
    v_seller_id    INT;
    v_bidder2_id   INT;
    v_txn_count    INT;
    v_txn_amount   NUMERIC(12,2);
    v_won_count    INT;
    v_sold_count   INT;
BEGIN
    SELECT a.auction_id, i.seller_id INTO v_auction_id, v_seller_id
    FROM auctions a JOIN items i ON i.item_id = a.item_id
    WHERE i.title = 'Trigger Test Item - No Reserve';

    SELECT user_id INTO v_bidder2_id FROM users WHERE email = 'trg-bidder2@bidhub.local';

    UPDATE auctions SET status = 'CLOSED' WHERE auction_id = v_auction_id;

    SELECT count(*), max(final_amount) INTO v_txn_count, v_txn_amount
    FROM transactions WHERE auction_id = v_auction_id;

    SELECT count(*) INTO v_won_count
    FROM notifications WHERE auction_id = v_auction_id AND type = 'WON' AND user_id = v_bidder2_id;

    SELECT count(*) INTO v_sold_count
    FROM notifications WHERE auction_id = v_auction_id AND type = 'SOLD' AND user_id = v_seller_id;

    IF v_txn_count = 1 AND v_txn_amount = 110.00 AND v_won_count = 1 AND v_sold_count = 1 THEN
        RAISE NOTICE 'PASS  trg_close_auction settled the winner: 1 transaction at 110.00, WON+SOLD notified';
    ELSE
        RAISE NOTICE 'FAIL  test_close_with_winner: txn_count=% (want 1), amount=% (want 110.00), won=% sold=% (want 1,1)',
            v_txn_count, v_txn_amount, v_won_count, v_sold_count;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 4 — trg_close_auction with reserve not met: zero transactions, one
--          AUCTION_CLOSED notification to the seller.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_auction_id  INT;
    v_seller_id   INT;
    v_bidder1_id  INT;
    v_txn_count   INT;
    v_closed_count INT;
BEGIN
    SELECT a.auction_id, i.seller_id INTO v_auction_id, v_seller_id
    FROM auctions a JOIN items i ON i.item_id = a.item_id
    WHERE i.title = 'Trigger Test Item - High Reserve';

    SELECT user_id INTO v_bidder1_id FROM users WHERE email = 'trg-bidder1@bidhub.local';

    INSERT INTO bids (auction_id, bidder_id, amount) VALUES (v_auction_id, v_bidder1_id, 60.00);

    UPDATE auctions SET status = 'CLOSED' WHERE auction_id = v_auction_id;

    SELECT count(*) INTO v_txn_count FROM transactions WHERE auction_id = v_auction_id;

    SELECT count(*) INTO v_closed_count
    FROM notifications WHERE auction_id = v_auction_id AND type = 'AUCTION_CLOSED' AND user_id = v_seller_id;

    IF v_txn_count = 0 AND v_closed_count = 1 THEN
        RAISE NOTICE 'PASS  trg_close_auction created no transaction when the reserve was not met';
    ELSE
        RAISE NOTICE 'FAIL  test_close_reserve_not_met: txn_count=% (want 0), closed_notice=% (want 1)',
            v_txn_count, v_closed_count;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Test 5 — trg_close_auction with no bids at all: zero transactions, one
--          AUCTION_CLOSED notification to the seller.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_auction_id   INT;
    v_seller_id    INT;
    v_txn_count    INT;
    v_closed_count INT;
BEGIN
    SELECT a.auction_id, i.seller_id INTO v_auction_id, v_seller_id
    FROM auctions a JOIN items i ON i.item_id = a.item_id
    WHERE i.title = 'Trigger Test Item - No Bids';

    UPDATE auctions SET status = 'CLOSED' WHERE auction_id = v_auction_id;

    SELECT count(*) INTO v_txn_count FROM transactions WHERE auction_id = v_auction_id;

    SELECT count(*) INTO v_closed_count
    FROM notifications WHERE auction_id = v_auction_id AND type = 'AUCTION_CLOSED' AND user_id = v_seller_id;

    IF v_txn_count = 0 AND v_closed_count = 1 THEN
        RAISE NOTICE 'PASS  trg_close_auction created no transaction when there were no bids';
    ELSE
        RAISE NOTICE 'FAIL  test_close_no_bids: txn_count=% (want 0), closed_notice=% (want 1)',
            v_txn_count, v_closed_count;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- No residue: undo every fixture.
-- ---------------------------------------------------------------------------
ROLLBACK;

SELECT 'test_triggers.sql: all trigger paths exercised — verify every line above says PASS' AS result;
