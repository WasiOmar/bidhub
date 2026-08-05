-- =============================================================================
-- db/03_procedures.sql
-- BidHub — procedural SQL: bid placement, batch auction close, and validation.
-- Owner: Person 2 (Procedural SQL & Performance)
--
-- Technique 03 (STORED PROCEDURE), technique 06 (EXPLICIT CURSOR, in
-- close_expired_auctions), and half of technique 02 (the PROCEDURE half of
-- auction auto-close — the TRIGGER half, trg_close_auction, is P1's in
-- db/02_triggers.sql; the PROCEDURE half — award_winner() and
-- close_expired_auctions() — is below).
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

DROP PROCEDURE IF EXISTS award_winner(INT);

-- ---------------------------------------------------------------------------
-- award_winner(p_auction_id)
--
-- Division of responsibility with trg_close_auction (db/02_triggers.sql):
-- that trigger already writes the `transactions` row and the WON/SOLD/
-- AUCTION_CLOSED notifications the instant an auction's status flips
-- ACTIVE -> CLOSED. This procedure's ONLY job is to resolve the winning bid
-- and stamp it onto auctions.winning_bid_id. It must NOT insert into
-- transactions or notifications itself — trg_close_auction already did, and
-- doing so again here would duplicate both.
--
-- Deliberately a no-op (winning_bid_id stays NULL) in two cases, mirroring
-- exactly the two "no sale" branches trg_close_auction itself takes:
--   - no bids were ever placed
--   - the highest bid fell short of reserve_price
-- ---------------------------------------------------------------------------
CREATE PROCEDURE award_winner(p_auction_id INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_reserve_price   NUMERIC(12,2);
    v_winning_bid_id  INT;
    v_winning_amount  NUMERIC(12,2);
BEGIN
    SELECT reserve_price INTO v_reserve_price
    FROM auctions
    WHERE auction_id = p_auction_id;

    IF NOT FOUND THEN
        RETURN; -- auction does not exist; nothing to award
    END IF;

    -- Highest bid on this auction. Tie-broken identically to
    -- trg_close_auction's own lookup: earliest placed_at wins a tie on
    -- amount, so both objects agree on who the "winner" is.
    SELECT b.bid_id, b.amount
      INTO v_winning_bid_id, v_winning_amount
    FROM bids b
    WHERE b.auction_id = p_auction_id
    ORDER BY b.amount DESC, b.placed_at ASC
    LIMIT 1;

    IF NOT FOUND THEN
        -- No bids at all: trg_close_auction already sent the seller the
        -- "closed with no bids" notification. Nothing to award.
        RETURN;
    END IF;

    IF v_reserve_price IS NOT NULL AND v_winning_amount < v_reserve_price THEN
        -- Reserve not met: trg_close_auction already sent the seller the
        -- "reserve not met" notification and wrote no transaction. Leaving
        -- winning_bid_id NULL keeps that consistent — there is no winner.
        RETURN;
    END IF;

    UPDATE auctions
       SET winning_bid_id = v_winning_bid_id
     WHERE auction_id = p_auction_id;
END;
$$;

COMMENT ON PROCEDURE award_winner(INT) IS
    'Resolves the highest bid on an auction (same tie-break as trg_close_auction) and sets '
    'auctions.winning_bid_id. Never writes transactions or notifications — that is entirely '
    'trg_close_auction''s job (db/02_triggers.sql) — so this stays a no-op on no-bids and '
    'reserve-not-met, exactly where that trigger also declines to settle the sale.';

DROP PROCEDURE IF EXISTS close_expired_auctions();

-- ---------------------------------------------------------------------------
-- close_expired_auctions()
--
-- Batch-closes every ACTIVE auction whose end_time has passed. Written with
-- an EXPLICIT cursor (technique 06) rather than a `FOR rec IN SELECT ...`
-- loop so every stage of the cursor lifecycle is visible on its own line:
-- DECLARE, OPEN, FETCH, process, CLOSE.
-- ---------------------------------------------------------------------------
CREATE PROCEDURE close_expired_auctions()
LANGUAGE plpgsql
AS $$
DECLARE
    -- ---- DECLARE stage --------------------------------------------------
    -- FOR UPDATE takes a row lock on each expired auction as it is fetched
    -- below, so a concurrent place_bid() (which itself locks the auction row
    -- FOR UPDATE) can never land a bid on a row this cursor is mid-way
    -- through closing, and two overlapping runs of this same procedure can
    -- never both close the same auction.
    cur_expired CURSOR FOR
        SELECT auction_id, item_id
          FROM auctions
         WHERE end_time < now() AND status = 'ACTIVE'
         ORDER BY end_time
           FOR UPDATE;
    rec      RECORD;
    v_count  INT := 0;
BEGIN
    -- ---- OPEN stage -------------------------------------------------------
    OPEN cur_expired;

    LOOP
        -- ---- FETCH stage ---------------------------------------------------
        FETCH cur_expired INTO rec;
        EXIT WHEN NOT FOUND;

        -- ---- process stage --------------------------------------------------
        -- WHERE CURRENT OF updates the row the cursor is already positioned
        -- on (and already holds the FOR UPDATE lock for) instead of a second
        -- `WHERE auction_id = ...` index scan. This UPDATE is what fires
        -- trg_close_auction (db/02_triggers.sql), writing the transactions
        -- row and the WON/SOLD/AUCTION_CLOSED notifications.
        UPDATE auctions SET status = 'CLOSED' WHERE CURRENT OF cur_expired;

        -- This procedure's own remaining job: stamp the winning bid onto the
        -- auction trg_close_auction just settled.
        CALL award_winner(rec.auction_id);

        v_count := v_count + 1;
    END LOOP;

    -- ---- CLOSE stage --------------------------------------------------------
    CLOSE cur_expired;

    -- Refresh the leaderboard materialized view if P2-06 has created it yet;
    -- skip quietly otherwise so this procedure works standalone before that
    -- prompt lands.
    IF EXISTS (SELECT 1 FROM pg_matviews WHERE matviewname = 'mv_leaderboard') THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_leaderboard;
    END IF;

    RAISE NOTICE 'close_expired_auctions: closed % auction(s)', v_count;
END;
$$;

COMMENT ON PROCEDURE close_expired_auctions() IS
    'Explicit-cursor (DECLARE/OPEN/FETCH/process/CLOSE) batch close: FOR UPDATE locks each '
    'expired ACTIVE auction as it is fetched, WHERE CURRENT OF flips it to CLOSED (firing '
    'trg_close_auction) without a second index scan, then award_winner() stamps the winning '
    'bid. Refreshes mv_leaderboard if it exists (P2-06) and RAISE NOTICEs the closed count.';
