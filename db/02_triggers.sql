-- =============================================================================
-- db/02_triggers.sql
-- BidHub — outbid notification, immutable audit trail, and auction auto-close.
-- Owner: Person 1 (Database Core)
--
-- Techniques 01 (outbid TRIGGER), the append-only audit trail, and half of
-- technique 02 (the TRIGGER half — the PROCEDURE half, close_expired_auctions(),
-- is P2's in db/03_procedures.sql). Every path here fires with zero application
-- code involved: bid INSERT -> trg_outbid -> notifications, and -> trg_audit_bid
-- -> audit_log; auctions UPDATE (ACTIVE -> CLOSED) -> trg_close_auction ->
-- transactions + notifications.
--
-- Depends on db/01_schema.sql. Idempotent: safe to re-run.
-- =============================================================================

DROP TRIGGER IF EXISTS trg_close_auction    ON auctions;
DROP TRIGGER IF EXISTS trg_audit_immutable  ON audit_log;
DROP TRIGGER IF EXISTS trg_audit_bid        ON bids;
DROP TRIGGER IF EXISTS trg_outbid           ON bids;

DROP FUNCTION IF EXISTS fn_trg_close_auction();
DROP FUNCTION IF EXISTS fn_trg_audit_immutable();
DROP FUNCTION IF EXISTS fn_trg_audit_bid();
DROP FUNCTION IF EXISTS fn_trg_outbid();

-- ---------------------------------------------------------------------------
-- 1. trg_outbid — AFTER INSERT ON bids, FOR EACH ROW
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_trg_outbid() RETURNS TRIGGER AS $$
DECLARE
    v_prev_bidder_id INT;
    v_item_title     VARCHAR(200);
BEGIN
    -- NEW is the bid just inserted. Find the highest bid on the same auction
    -- placed by anyone OTHER than NEW's own bidder — that person has just been
    -- outbid. Ties broken by earliest placed_at (whoever got there first held
    -- the lead at that amount).
    SELECT b.bidder_id
      INTO v_prev_bidder_id
    FROM bids b
    WHERE b.auction_id = NEW.auction_id
      AND b.bidder_id <> NEW.bidder_id
      AND b.bid_id <> NEW.bid_id
    ORDER BY b.amount DESC, b.placed_at ASC
    LIMIT 1;

    -- First bid on the auction (or a re-bid by the same person): no one to notify.
    IF v_prev_bidder_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT i.title
      INTO v_item_title
    FROM auctions a
    JOIN items i ON i.item_id = a.item_id
    WHERE a.auction_id = NEW.auction_id;

    INSERT INTO notifications (user_id, type, title, message, auction_id)
    VALUES (
        v_prev_bidder_id,
        'OUTBID',
        'You have been outbid',
        format('Someone placed a higher bid of %s on "%s".',
               to_char(NEW.amount, 'FM999,999,990.00'), v_item_title),
        NEW.auction_id
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_outbid
    AFTER INSERT ON bids
    FOR EACH ROW
    EXECUTE FUNCTION fn_trg_outbid();

COMMENT ON FUNCTION fn_trg_outbid() IS
    'Reads NEW (the bid just inserted) to find the bidder it displaced, then INSERTs a '
    'notification for them. place_bid() (db/03_procedures.sql) only inserts the bid — this '
    'is fully decoupled from the API, no application code is on the notification path.';

-- ---------------------------------------------------------------------------
-- 2. trg_audit_bid — AFTER INSERT ON bids  (chains after trg_outbid on the
--    same event — two triggers on one INSERT, each doing exactly one job)
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_trg_audit_bid() RETURNS TRIGGER AS $$
BEGIN
    -- NEW is the bid row just written; there is no OLD on an INSERT.
    INSERT INTO audit_log (actor_id, action, entity_type, entity_id, payload)
    VALUES (
        NEW.bidder_id,
        'BID_PLACED',
        'auction',
        NEW.auction_id,
        jsonb_build_object(
            'bid_id', NEW.bid_id,
            'amount', NEW.amount,
            'placed_at', NEW.placed_at
        )
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_bid
    AFTER INSERT ON bids
    FOR EACH ROW
    EXECUTE FUNCTION fn_trg_audit_bid();

COMMENT ON FUNCTION fn_trg_audit_bid() IS
    'Appends an immutable, timestamped record of every bid placed on the platform.';

-- ---------------------------------------------------------------------------
-- trg_audit_immutable — BEFORE UPDATE OR DELETE ON audit_log
-- Enforces append-only at the database level, not just via API convention.
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_trg_audit_immutable() RETURNS TRIGGER AS $$
BEGIN
    -- OLD is the row being touched; on UPDATE, NEW would be the attempted new
    -- state — neither matters, since the rule is simply "no UPDATE or DELETE".
    RAISE EXCEPTION 'audit_log is append-only: % on audit_id % is not permitted', TG_OP, OLD.audit_id
        USING ERRCODE = 'raise_exception';
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_immutable
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW
    EXECUTE FUNCTION fn_trg_audit_immutable();

COMMENT ON FUNCTION fn_trg_audit_immutable() IS
    'Tamper-evidence guarantee: even a superuser UPDATE/DELETE issued directly from psql is '
    'rejected, not only writes attempted through the API.';

-- ---------------------------------------------------------------------------
-- 3. trg_close_auction — AFTER UPDATE ON auctions, WHEN ACTIVE -> CLOSED
-- ---------------------------------------------------------------------------
CREATE FUNCTION fn_trg_close_auction() RETURNS TRIGGER AS $$
DECLARE
    v_winning_bid   bids%ROWTYPE;
    v_seller_id     INT;
    v_item_title    VARCHAR(200);
BEGIN
    -- The WHEN clause on the trigger already guarantees OLD.status = 'ACTIVE' and
    -- NEW.status = 'CLOSED'; NEW.item_id / NEW.auction_id / NEW.reserve_price
    -- describe the auction that just closed and are all this function reads.
    SELECT i.seller_id, i.title
      INTO v_seller_id, v_item_title
    FROM items i
    WHERE i.item_id = NEW.item_id;

    -- Highest bid on this auction, if any.
    SELECT b.*
      INTO v_winning_bid
    FROM bids b
    WHERE b.auction_id = NEW.auction_id
    ORDER BY b.amount DESC, b.placed_at ASC
    LIMIT 1;

    IF NOT FOUND THEN
        -- No bids at all: nothing to settle. Let the seller know it closed unsold.
        INSERT INTO notifications (user_id, type, title, message, auction_id)
        VALUES (
            v_seller_id, 'AUCTION_CLOSED', 'Auction closed with no bids',
            format('"%s" closed with no bids and was not sold.', v_item_title),
            NEW.auction_id
        );
        RETURN NEW;
    END IF;

    IF NEW.reserve_price IS NOT NULL AND v_winning_bid.amount < NEW.reserve_price THEN
        -- Highest bid fell short of the reserve: no sale.
        INSERT INTO notifications (user_id, type, title, message, auction_id)
        VALUES (
            v_seller_id, 'AUCTION_CLOSED', 'Auction closed — reserve not met',
            format('"%s" closed at %s, below your reserve price. Not sold.',
                   v_item_title, to_char(v_winning_bid.amount, 'FM999,999,990.00')),
            NEW.auction_id
        );
        RETURN NEW;
    END IF;

    -- Settle. This trigger writes the transaction and the WON/SOLD notifications;
    -- it deliberately does NOT set auctions.winning_bid_id — that column is
    -- award_winner()'s job (db/03_procedures.sql, P2), so the two objects never
    -- race to write the same value. ON CONFLICT DO NOTHING makes a concurrent
    -- double-close (two sessions flipping the same row) harmless instead of an
    -- unhandled error, backstopped by uq_transactions_auction.
    INSERT INTO transactions (auction_id, buyer_id, seller_id, item_id, final_amount, status)
    VALUES (NEW.auction_id, v_winning_bid.bidder_id, v_seller_id, NEW.item_id, v_winning_bid.amount, 'PENDING')
    ON CONFLICT ON CONSTRAINT uq_transactions_auction DO NOTHING;

    INSERT INTO notifications (user_id, type, title, message, auction_id)
    VALUES (
        v_winning_bid.bidder_id, 'WON', 'You won the auction!',
        format('You won "%s" for %s.', v_item_title, to_char(v_winning_bid.amount, 'FM999,999,990.00')),
        NEW.auction_id
    );

    INSERT INTO notifications (user_id, type, title, message, auction_id)
    VALUES (
        v_seller_id, 'SOLD', 'Your item sold',
        format('"%s" sold for %s.', v_item_title, to_char(v_winning_bid.amount, 'FM999,999,990.00')),
        NEW.auction_id
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_close_auction
    AFTER UPDATE ON auctions
    FOR EACH ROW
    WHEN (OLD.status = 'ACTIVE' AND NEW.status = 'CLOSED')
    EXECUTE FUNCTION fn_trg_close_auction();

COMMENT ON FUNCTION fn_trg_close_auction() IS
    'Fires on ANY ACTIVE->CLOSED transition, however it happens — a manual UPDATE or the '
    'cursor loop in close_expired_auctions(). Resolves the winning bid from NEW.auction_id, '
    'writes the transaction and WON/SOLD/AUCTION_CLOSED notifications. Does not set '
    'auctions.winning_bid_id — see award_winner() in db/03_procedures.sql.';
