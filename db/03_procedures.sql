-- =============================================================================
-- db/03_procedures.sql
-- BidHub — procedural SQL: bid placement and validation.
-- Owner: Person 2 (Procedural SQL & Performance)
--
-- Technique 03 (STORED PROCEDURE) and half of technique 02 (the PROCEDURE half
-- of auction auto-close — the TRIGGER half, trg_close_auction, is P1's in
-- db/02_triggers.sql; award_winner() and close_expired_auctions() land here in
-- a later prompt).
--
-- place_bid() is the transactional heart of the platform: it locks the
-- auction row FOR UPDATE so two concurrent bidders on the same auction are
-- serialised (the Isolation leg of the ACID story, proven in
-- db/tests/test_concurrency.sql), validates in order, and inserts exactly one
-- bids row. It does NOT insert into notifications or audit_log itself —
-- trg_outbid and trg_audit_bid (db/02_triggers.sql) fire on that INSERT and do
-- both jobs automatically, fully decoupled from application code.
--
-- Depends on db/01_schema.sql and db/02_triggers.sql. Idempotent: safe to re-run.
-- =============================================================================

DROP PROCEDURE IF EXISTS place_bid(INT, INT, NUMERIC);

-- ---------------------------------------------------------------------------
-- place_bid(p_user_id, p_auction_id, p_amount)
--
-- Typed SQLSTATE error codes (CONTRACT.md), mapped to HTTP by the API:
--   AU001  bid below the required minimum                 -> 400
--   AU002  auction is not ACTIVE / has already ended        -> 409
--   AU003  the bidder is the item's own seller              -> 403
--   AU004  auction not found                                -> 404
-- ---------------------------------------------------------------------------
CREATE PROCEDURE place_bid(
    p_user_id     INT,
    p_auction_id  INT,
    p_amount      NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status        auction_status;
    v_end_time      TIMESTAMPTZ;
    v_seller_id     INT;
    v_starting_price NUMERIC(12,2);
    v_increment     NUMERIC(12,2);
    v_max_amount    NUMERIC(12,2);
    v_min_required  NUMERIC(12,2);
BEGIN
    -- Lock the auction row first, before any validation. This is what makes
    -- the Isolation claim true: a second concurrent CALL for the same
    -- auction_id blocks here until this transaction commits or rolls back,
    -- so two bidders can never both read the same "current highest bid" and
    -- both succeed at it. FOR UPDATE also pulls in the auction's own fields
    -- (status, end_time, price/increment) in one round trip.
    SELECT a.status, a.end_time, a.starting_price, a.bid_increment, i.seller_id
      INTO v_status, v_end_time, v_starting_price, v_increment, v_seller_id
    FROM auctions a
    JOIN items i ON i.item_id = a.item_id
    WHERE a.auction_id = p_auction_id
    FOR UPDATE OF a;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'auction % does not exist', p_auction_id
            USING ERRCODE = 'AU004';
    END IF;

    -- Validate in order: not-active/ended, then self-bidding, then the amount.
    IF v_status <> 'ACTIVE' OR now() >= v_end_time THEN
        RAISE EXCEPTION 'auction % is not open for bidding', p_auction_id
            USING ERRCODE = 'AU002';
    END IF;

    IF p_user_id = v_seller_id THEN
        RAISE EXCEPTION 'seller % cannot bid on their own auction %', p_user_id, p_auction_id
            USING ERRCODE = 'AU003';
    END IF;

    -- The floor for the first-ever bid is starting_price. Modelling that as
    -- "as if the previous highest bid were (starting_price - bid_increment)"
    -- lets the same v_min_required formula below cover both the first bid and
    -- every subsequent one — that's why the COALESCE fallback subtracts the
    -- increment rather than just using starting_price directly.
    v_max_amount := COALESCE(
        (SELECT MAX(b.amount) FROM bids b WHERE b.auction_id = p_auction_id),
        v_starting_price - v_increment
    );
    v_min_required := v_max_amount + v_increment;

    IF p_amount < v_min_required THEN
        RAISE EXCEPTION 'bid % is below the minimum required bid of %', p_amount, v_min_required
            USING ERRCODE = 'AU001';
    END IF;

    -- Insert the bid. trg_outbid and trg_audit_bid (db/02_triggers.sql) fire
    -- on this INSERT and handle the OUTBID notification and the audit_log
    -- entry — do NOT duplicate either of those here.
    INSERT INTO bids (auction_id, bidder_id, amount)
    VALUES (p_auction_id, p_user_id, p_amount);
END;
$$;

COMMENT ON PROCEDURE place_bid(INT, INT, NUMERIC) IS
    'Locks the auction row FOR UPDATE, validates status/self-bid/minimum-amount in that '
    'order with typed SQLSTATEs (AU001-AU004), then inserts the bid. Notification and audit '
    'writes are left entirely to trg_outbid / trg_audit_bid (db/02_triggers.sql).';
