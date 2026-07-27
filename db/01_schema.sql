-- =============================================================================
-- db/01_schema.sql
-- BidHub — core schema: enum types, tables, keys and integrity constraints.
-- Owner: Person 1 (Database Core)
--
-- Idempotent: safe to re-run against a live database. Drops everything in
-- reverse dependency order, then rebuilds. Every constraint is commented with
-- the business rule it enforces — this file is the "Consistency" leg of the
-- ACID story (technique 08, proven in db/tests/test_concurrency.sql).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Clean slate (reverse dependency order)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS watchlist      CASCADE;
DROP TABLE IF EXISTS audit_log      CASCADE;
DROP TABLE IF EXISTS notifications  CASCADE;
DROP TABLE IF EXISTS transactions   CASCADE;
DROP TABLE IF EXISTS bids           CASCADE;
DROP TABLE IF EXISTS auctions       CASCADE;
DROP TABLE IF EXISTS items          CASCADE;
DROP TABLE IF EXISTS categories     CASCADE;
DROP TABLE IF EXISTS users          CASCADE;

DROP TYPE IF EXISTS transaction_status CASCADE;
DROP TYPE IF EXISTS notification_type  CASCADE;
DROP TYPE IF EXISTS auction_status     CASCADE;
DROP TYPE IF EXISTS item_condition     CASCADE;
DROP TYPE IF EXISTS user_role          CASCADE;

-- ---------------------------------------------------------------------------
-- 1. Enumerated types (guarded so the block is safe to re-run standalone)
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    CREATE TYPE user_role AS ENUM ('BUYER', 'SELLER', 'ADMIN');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE item_condition AS ENUM ('NEW', 'LIKE_NEW', 'USED', 'REFURBISHED');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE auction_status AS ENUM ('SCHEDULED', 'ACTIVE', 'CLOSED', 'CANCELLED');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE notification_type AS ENUM ('OUTBID', 'WON', 'SOLD', 'AUCTION_CLOSED');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE transaction_status AS ENUM ('PENDING', 'PAID', 'SHIPPED', 'COMPLETED', 'CANCELLED');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- 2. users
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    user_id         SERIAL          PRIMARY KEY,
    full_name       VARCHAR(120)    NOT NULL,
    email           VARCHAR(255)    NOT NULL,
    password_hash   TEXT            NOT NULL,
    role            user_role       NOT NULL DEFAULT 'BUYER',
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT uq_users_email UNIQUE (email),
    CONSTRAINT chk_users_email_format
        CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);
COMMENT ON TABLE users IS
    'Buyers, sellers and admins. password_hash is bcrypt (12 rounds) and is never returned by the API.';
COMMENT ON CONSTRAINT uq_users_email ON users IS
    'One account per email address.';
COMMENT ON CONSTRAINT chk_users_email_format ON users IS
    'Rejects an obviously malformed address at the database boundary, not only in the client.';

-- ---------------------------------------------------------------------------
-- 3. categories — self-referencing, arbitrary depth
-- ---------------------------------------------------------------------------
CREATE TABLE categories (
    category_id     SERIAL          PRIMARY KEY,
    name            VARCHAR(100)    NOT NULL,
    slug            VARCHAR(120)    NOT NULL,
    parent_id       INT             NULL,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT uq_categories_slug UNIQUE (slug),
    CONSTRAINT fk_categories_parent
        FOREIGN KEY (parent_id) REFERENCES categories (category_id)
        ON DELETE RESTRICT,
    CONSTRAINT chk_categories_no_self_parent
        CHECK (parent_id IS DISTINCT FROM category_id)
);
COMMENT ON TABLE categories IS
    'Self-referencing, arbitrary-depth category tree — the platform is domain-agnostic '
    '(Electronics > Computers > Laptops > Gaming Laptops, Art > Paintings > Oil Paintings, ...) '
    'rather than a fixed brand/line/variant hierarchy. Traversed by get_category_tree() '
    '(WITH RECURSIVE, technique 07, db/04_queries.sql).';
COMMENT ON CONSTRAINT fk_categories_parent ON categories IS
    'RESTRICT stops a category from being deleted out from under its children.';
COMMENT ON CONSTRAINT chk_categories_no_self_parent ON categories IS
    'A category cannot be its own parent — would make the recursive CTE loop without a depth guard.';

-- ---------------------------------------------------------------------------
-- 4. items
-- ---------------------------------------------------------------------------
CREATE TABLE items (
    item_id         SERIAL          PRIMARY KEY,
    seller_id       INT             NOT NULL,
    category_id     INT             NOT NULL,
    title           VARCHAR(200)    NOT NULL,
    description     TEXT            NULL,
    condition       item_condition  NOT NULL DEFAULT 'USED',
    attributes      JSONB           NOT NULL DEFAULT '{}'::jsonb,
    image_url       TEXT            NULL,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT fk_items_seller
        FOREIGN KEY (seller_id) REFERENCES users (user_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_items_category
        FOREIGN KEY (category_id) REFERENCES categories (category_id)
        ON DELETE RESTRICT
);
COMMENT ON TABLE items IS
    'One item, any domain. attributes is JSONB so a laptop, a painting and a car share one '
    'table: {"ram":"16GB"} vs {"medium":"oil"} vs {"mileage":82000} — this is what makes '
    'BidHub general-purpose rather than a luxury-watch-only schema.';
COMMENT ON CONSTRAINT fk_items_seller ON items IS
    'A seller with listing history cannot be deleted outright — preserves the audit trail.';
COMMENT ON CONSTRAINT fk_items_category ON items IS
    'A category with items in it cannot be deleted; reassign the items first.';

-- ---------------------------------------------------------------------------
-- 5. auctions  (winning_bid_id → bids added after bids exists, see §6)
-- ---------------------------------------------------------------------------
CREATE TABLE auctions (
    auction_id      SERIAL          PRIMARY KEY,
    item_id         INT             NOT NULL,
    starting_price  NUMERIC(12,2)   NOT NULL,
    reserve_price   NUMERIC(12,2)   NULL,
    bid_increment   NUMERIC(12,2)   NOT NULL DEFAULT 1.00,
    start_time      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    end_time        TIMESTAMPTZ     NOT NULL,
    status          auction_status  NOT NULL DEFAULT 'SCHEDULED',
    winning_bid_id  INT             NULL,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT fk_auctions_item
        FOREIGN KEY (item_id) REFERENCES items (item_id)
        ON DELETE RESTRICT,
    CONSTRAINT uq_auctions_item UNIQUE (item_id),
    CONSTRAINT chk_auctions_end_after_start
        CHECK (end_time > start_time),
    CONSTRAINT chk_auctions_starting_price_positive
        CHECK (starting_price > 0),
    CONSTRAINT chk_auctions_bid_increment_positive
        CHECK (bid_increment > 0),
    CONSTRAINT chk_auctions_reserve_at_least_starting
        CHECK (reserve_price IS NULL OR reserve_price >= starting_price)
);
COMMENT ON TABLE auctions IS
    'status is flipped ACTIVE -> CLOSED by close_expired_auctions() (cursor, technique 06); '
    'trg_close_auction (technique 02) reacts to that flip and settles the sale.';
COMMENT ON CONSTRAINT uq_auctions_item ON auctions IS
    'One live/historical auction per item — relist by creating a new item, not by reusing this row.';
COMMENT ON CONSTRAINT chk_auctions_end_after_start ON auctions IS
    'An auction cannot end before or at the moment it starts.';
COMMENT ON CONSTRAINT chk_auctions_starting_price_positive ON auctions IS
    'Free auctions are not supported — every lot starts above zero.';
COMMENT ON CONSTRAINT chk_auctions_bid_increment_positive ON auctions IS
    'A zero or negative increment would let place_bid() accept a tying or lower bid as "higher".';
COMMENT ON CONSTRAINT chk_auctions_reserve_at_least_starting ON auctions IS
    'A reserve below the starting price is meaningless — bid one would always meet it.';

-- ---------------------------------------------------------------------------
-- 6. bids
-- ---------------------------------------------------------------------------
CREATE TABLE bids (
    bid_id      SERIAL          PRIMARY KEY,
    auction_id  INT             NOT NULL,
    bidder_id   INT             NOT NULL,
    amount      NUMERIC(12,2)   NOT NULL,
    placed_at   TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT fk_bids_auction
        FOREIGN KEY (auction_id) REFERENCES auctions (auction_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_bids_bidder
        FOREIGN KEY (bidder_id) REFERENCES users (user_id)
        ON DELETE RESTRICT,
    CONSTRAINT chk_bids_amount_positive
        CHECK (amount > 0)
);
COMMENT ON TABLE bids IS
    'Every INSERT here fires trg_outbid and trg_audit_bid (db/02_triggers.sql) — the '
    'notification and audit paths are fully decoupled from application code.';
COMMENT ON CONSTRAINT fk_bids_auction ON bids IS
    'Bids belong entirely to their auction — deleting an auction takes its bids with it.';
COMMENT ON CONSTRAINT fk_bids_bidder ON bids IS
    'A bidder with bidding history cannot be deleted outright — preserves the audit trail.';
COMMENT ON CONSTRAINT chk_bids_amount_positive ON bids IS
    'A bid of zero or less is not a bid; place_bid() additionally enforces the '
    'starting-price/increment floor above this baseline sanity check.';

-- Deferred FK: auctions.winning_bid_id -> bids.bid_id, added now that bids exists.
ALTER TABLE auctions
    ADD CONSTRAINT fk_auctions_winning_bid
        FOREIGN KEY (winning_bid_id) REFERENCES bids (bid_id)
        ON DELETE SET NULL;
COMMENT ON CONSTRAINT fk_auctions_winning_bid ON auctions IS
    'Circular reference (auctions -> bids -> auctions), added after bids exists. Set by '
    'award_winner(); ON DELETE SET NULL rather than losing the whole auction row if a bid is purged.';

-- ---------------------------------------------------------------------------
-- 7. transactions — settles an auction exactly once
-- ---------------------------------------------------------------------------
CREATE TABLE transactions (
    transaction_id  SERIAL              PRIMARY KEY,
    auction_id      INT                 NOT NULL,
    buyer_id        INT                 NOT NULL,
    seller_id       INT                 NOT NULL,
    item_id         INT                 NOT NULL,
    final_amount    NUMERIC(12,2)       NOT NULL,
    status          transaction_status  NOT NULL DEFAULT 'PENDING',
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT now(),

    CONSTRAINT fk_transactions_auction
        FOREIGN KEY (auction_id) REFERENCES auctions (auction_id)
        ON DELETE RESTRICT,
    CONSTRAINT uq_transactions_auction UNIQUE (auction_id),
    CONSTRAINT fk_transactions_buyer
        FOREIGN KEY (buyer_id) REFERENCES users (user_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_transactions_seller
        FOREIGN KEY (seller_id) REFERENCES users (user_id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_transactions_item
        FOREIGN KEY (item_id) REFERENCES items (item_id)
        ON DELETE RESTRICT,
    CONSTRAINT chk_transactions_amount_positive
        CHECK (final_amount > 0)
);
COMMENT ON TABLE transactions IS
    'Written only by trg_close_auction (db/02_triggers.sql), never directly by the API.';
COMMENT ON CONSTRAINT uq_transactions_auction ON transactions IS
    'An auction settles exactly once — trg_close_auction relies on this to stay safe '
    'under a concurrent double-close attempt.';

-- ---------------------------------------------------------------------------
-- 8. notifications — written only by triggers, read by the API
-- ---------------------------------------------------------------------------
CREATE TABLE notifications (
    notification_id SERIAL              PRIMARY KEY,
    user_id         INT                 NOT NULL,
    type            notification_type   NOT NULL,
    title           VARCHAR(150)        NOT NULL,
    message         TEXT                NOT NULL,
    auction_id      INT                 NULL,
    is_read         BOOLEAN             NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT now(),

    CONSTRAINT fk_notifications_user
        FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_notifications_auction
        FOREIGN KEY (auction_id) REFERENCES auctions (auction_id)
        ON DELETE CASCADE
);
COMMENT ON TABLE notifications IS
    'Populated exclusively by trg_outbid and trg_close_auction (db/02_triggers.sql, '
    'techniques 01/02). The API only reads and marks-as-read; it never inserts.';

-- ---------------------------------------------------------------------------
-- 9. audit_log — append-only (immutability trigger added in db/02_triggers.sql)
-- ---------------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id    BIGSERIAL       PRIMARY KEY,
    actor_id    INT             NULL,
    action      VARCHAR(50)     NOT NULL,
    entity_type VARCHAR(50)     NOT NULL,
    entity_id   INT             NOT NULL,
    payload     JSONB           NOT NULL DEFAULT '{}'::jsonb,
    occurred_at TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT fk_audit_log_actor
        FOREIGN KEY (actor_id) REFERENCES users (user_id)
        ON DELETE SET NULL
);
COMMENT ON TABLE audit_log IS
    'Tamper-evident activity trail. trg_audit_immutable (db/02_triggers.sql) RAISEs on any '
    'UPDATE or DELETE, so the append-only guarantee holds even against a stray manual edit.';

-- ---------------------------------------------------------------------------
-- 10. watchlist — composite key, no surrogate id needed
-- ---------------------------------------------------------------------------
CREATE TABLE watchlist (
    user_id     INT             NOT NULL,
    auction_id  INT             NOT NULL,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT now(),

    CONSTRAINT pk_watchlist PRIMARY KEY (user_id, auction_id),
    CONSTRAINT fk_watchlist_user
        FOREIGN KEY (user_id) REFERENCES users (user_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_watchlist_auction
        FOREIGN KEY (auction_id) REFERENCES auctions (auction_id)
        ON DELETE CASCADE
);
COMMENT ON CONSTRAINT pk_watchlist ON watchlist IS
    'A user watches a given auction at most once; the composite key is the uniqueness rule.';
