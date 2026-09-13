

DROP PROCEDURE IF EXISTS place_bid(INT, INT, NUMERIC);


CREATE PROCEDURE place_bid(
    p_user_id     INT,
    p_auction_id  INT,
    p_amount      NUMERIC
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status        auction_status;
    v_start_time    TIMESTAMPTZ;
    v_end_time      TIMESTAMPTZ;
    v_seller_id     INT;
    v_starting_price NUMERIC(12,2);
    v_increment     NUMERIC(12,2);
    v_max_amount    NUMERIC(12,2);
    v_min_required  NUMERIC(12,2);
BEGIN
    
    
    
    SELECT a.status, a.start_time, a.end_time, a.starting_price, a.bid_increment, i.seller_id
      INTO v_status, v_start_time, v_end_time, v_starting_price, v_increment, v_seller_id
    FROM auctions a
    JOIN items i ON i.item_id = a.item_id
    WHERE a.auction_id = p_auction_id
    FOR UPDATE OF a;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'auction % does not exist', p_auction_id
            USING ERRCODE = 'AU004';
    END IF;

    
    IF v_status = 'SCHEDULED' AND now() >= v_start_time THEN
        UPDATE auctions SET status = 'ACTIVE' WHERE auction_id = p_auction_id;
        v_status := 'ACTIVE';
    END IF;

    IF v_status <> 'ACTIVE' OR now() >= v_end_time THEN
        RAISE EXCEPTION 'auction % is not open for bidding', p_auction_id
            USING ERRCODE = 'AU002';
    END IF;

    IF p_user_id = v_seller_id THEN
        RAISE EXCEPTION 'seller % cannot bid on their own auction %', p_user_id, p_auction_id
            USING ERRCODE = 'AU003';
    END IF;
    
    v_max_amount := COALESCE(
        (SELECT MAX(b.amount) FROM bids b WHERE b.auction_id = p_auction_id),
        v_starting_price - v_increment
    );
    v_min_required := v_max_amount + v_increment;

    IF p_amount < v_min_required THEN
        RAISE EXCEPTION 'bid % is below the minimum required bid of %', p_amount, v_min_required
            USING ERRCODE = 'AU001';
    END IF;

    
    
    
    INSERT INTO bids (auction_id, bidder_id, amount)
    VALUES (p_auction_id, p_user_id, p_amount);
END;
$$;

COMMENT ON PROCEDURE place_bid(INT, INT, NUMERIC) IS
    'Locks the auction row FOR UPDATE, opens it first if it is SCHEDULED and its start_time '
    'has passed (so the first bid never waits for open_scheduled_auctions), validates '
    'status/self-bid/minimum-amount in that order with typed SQLSTATEs (AU001-AU004), then '
    'inserts the bid. Notification and audit writes are left entirely to trg_outbid / '
    'trg_audit_bid (db/02_triggers.sql).';

DROP PROCEDURE IF EXISTS award_winner(INT);

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
        RETURN; 
    END IF;

    
    
    
    SELECT b.bid_id, b.amount
      INTO v_winning_bid_id, v_winning_amount
    FROM bids b
    WHERE b.auction_id = p_auction_id
    ORDER BY b.amount DESC, b.placed_at ASC
    LIMIT 1;

    IF NOT FOUND THEN
        
        
        RETURN;
    END IF;

    IF v_reserve_price IS NOT NULL AND v_winning_amount < v_reserve_price THEN
        
        
        
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

CREATE PROCEDURE close_expired_auctions()
LANGUAGE plpgsql
AS $$
DECLARE
    
    cur_expired CURSOR FOR
        SELECT auction_id, item_id
          FROM auctions
         WHERE end_time < now() AND status = 'ACTIVE'
         ORDER BY end_time
           FOR UPDATE;
    rec      RECORD;
    v_count  INT := 0;
BEGIN
    
    OPEN cur_expired;

    LOOP
        
        FETCH cur_expired INTO rec;
        EXIT WHEN NOT FOUND;
        UPDATE auctions SET status = 'CLOSED' WHERE CURRENT OF cur_expired;     
        CALL award_winner(rec.auction_id);

        v_count := v_count + 1;
    END LOOP;

    
    CLOSE cur_expired;

    
    
    
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

DROP PROCEDURE IF EXISTS open_scheduled_auctions();

CREATE PROCEDURE open_scheduled_auctions()
LANGUAGE plpgsql
AS $$
DECLARE
    v_count  INT;
BEGIN
    UPDATE auctions
       SET status = 'ACTIVE'
     WHERE status = 'SCHEDULED' AND start_time <= now();
    GET DIAGNOSTICS v_count = ROW_COUNT;

    IF v_count > 0 AND EXISTS (SELECT 1 FROM pg_matviews WHERE matviewname = 'mv_leaderboard') THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_leaderboard;
    END IF;

    RAISE NOTICE 'open_scheduled_auctions: opened % auction(s)', v_count;
END;
$$;

COMMENT ON PROCEDURE open_scheduled_auctions() IS
    'Set-based batch open: one UPDATE flips every SCHEDULED auction whose start_time has passed '
    'to ACTIVE. The server job calls it before close_expired_auctions(), so an auction whose whole '
    'window passed while the job was down is opened and then settled in the same run. place_bid '
    'also opens a due auction on its first bid. Refreshes mv_leaderboard when anything opened.';