# ER diagram and trigger flow

Drawn from `db/01_schema.sql` (tables, keys, constraints) and `db/02_triggers.sql` /
`db/03_procedures.sql` (the event flow). Column-level detail is in
[data-dictionary.md](data-dictionary.md); the design reasoning is in
[normalization.md](normalization.md).

## 1. Entity-relationship diagram

Nine tables, sixteen foreign keys. Crow's-foot notation: `||` exactly one, `o|` zero or
one, `o{` zero or many. Every foreign key in the schema appears once below, labelled with
its constraint name.

```mermaid
erDiagram
    USERS {
        serial      user_id        PK
        varchar     full_name
        varchar     email          UK "uq_users_email, chk_users_email_format"
        text        password_hash       "bcrypt"
        user_role   role                "BUYER | SELLER | ADMIN"
        timestamptz created_at
    }
    CATEGORIES {
        serial      category_id    PK
        varchar     name
        varchar     slug           UK "uq_categories_slug"
        int         parent_id      FK "NULL = root; chk_categories_no_self_parent"
        timestamptz created_at
    }
    ITEMS {
        serial         item_id     PK
        int            seller_id   FK
        int            category_id FK
        varchar        title
        text           description
        item_condition condition        "NEW | LIKE_NEW | USED | REFURBISHED"
        jsonb          attributes       "domain-specific spec"
        text           image_url
        timestamptz    created_at
    }
    AUCTIONS {
        serial         auction_id     PK
        int            item_id        FK "UK uq_auctions_item"
        numeric        starting_price    "> 0"
        numeric        reserve_price     "NULL or >= starting_price"
        numeric        bid_increment     "> 0"
        timestamptz    start_time
        timestamptz    end_time          "> start_time"
        auction_status status            "SCHEDULED | ACTIVE | CLOSED | CANCELLED"
        int            winning_bid_id FK "set by award_winner"
        timestamptz    created_at
    }
    BIDS {
        serial      bid_id     PK
        int         auction_id FK
        int         bidder_id  FK
        numeric     amount        "> 0"
        timestamptz placed_at
    }
    TRANSACTIONS {
        serial             transaction_id PK
        int                auction_id     FK "UK uq_transactions_auction"
        int                buyer_id       FK
        int                seller_id      FK
        int                item_id        FK
        numeric            final_amount      "> 0"
        transaction_status status            "PENDING | PAID | SHIPPED | COMPLETED | CANCELLED"
        timestamptz        created_at
    }
    NOTIFICATIONS {
        serial            notification_id PK
        int               user_id         FK
        notification_type type               "OUTBID | WON | SOLD | AUCTION_CLOSED"
        varchar           title
        text              message
        int               auction_id      FK "nullable"
        boolean           is_read
        timestamptz       created_at
    }
    AUDIT_LOG {
        bigserial   audit_id    PK
        int         actor_id    FK "nullable"
        varchar     action          "e.g. BID_PLACED"
        varchar     entity_type     "e.g. auction"
        int         entity_id       "no FK: any entity"
        jsonb       payload
        timestamptz occurred_at
    }
    WATCHLIST {
        int         user_id    PK, FK
        int         auction_id PK, FK
        timestamptz created_at
    }

    CATEGORIES   |o--o{ CATEGORIES    : "fk_categories_parent (parent of)"
    USERS        ||--o{ ITEMS         : "fk_items_seller (lists)"
    CATEGORIES   ||--o{ ITEMS         : "fk_items_category (classifies)"
    ITEMS        ||--o| AUCTIONS      : "fk_auctions_item (sold through)"
    BIDS         |o--o| AUCTIONS      : "fk_auctions_winning_bid (wins)"
    AUCTIONS     ||--o{ BIDS          : "fk_bids_auction (receives)"
    USERS        ||--o{ BIDS          : "fk_bids_bidder (places)"
    AUCTIONS     ||--o| TRANSACTIONS  : "fk_transactions_auction (settles as)"
    USERS        ||--o{ TRANSACTIONS  : "fk_transactions_buyer (buys)"
    USERS        ||--o{ TRANSACTIONS  : "fk_transactions_seller (sells)"
    ITEMS        ||--o{ TRANSACTIONS  : "fk_transactions_item (sold in)"
    USERS        ||--o{ NOTIFICATIONS : "fk_notifications_user (receives)"
    AUCTIONS     |o--o{ NOTIFICATIONS : "fk_notifications_auction (about)"
    USERS        |o--o{ AUDIT_LOG     : "fk_audit_log_actor (acts in)"
    USERS        ||--o{ WATCHLIST     : "fk_watchlist_user (watches)"
    AUCTIONS     ||--o{ WATCHLIST     : "fk_watchlist_auction (watched in)"
```

### Reading the cardinalities

| Relationship | Why this cardinality |
|---|---|
| category → parent category | `parent_id` is nullable: a root has no parent, every other category has exactly one. Any depth is possible. |
| item → auction, **0..1** | `uq_auctions_item`: an item is auctioned at most once. Relisting means a new item row. |
| auction → transaction, **0..1** | `uq_transactions_auction`: a sale settles exactly once, even if two sessions close the auction together. |
| auction → winning bid, **0..1** | `winning_bid_id` is NULL until `award_winner()` runs, and stays NULL with no bids or when the reserve is not met. |
| auction ↔ bids | This is a cycle: bids reference auctions, and an auction references its winning bid. `fk_auctions_winning_bid` is therefore added with `ALTER TABLE` after `bids` exists. |
| notification → auction, **0..1** | Every notification today is about an auction, but the column is nullable so account-level messages remain possible. |
| audit row → actor, **0..1** | `actor_id` is nullable (`ON DELETE SET NULL`). `entity_id` has **no** foreign key: the log must be able to point at any table and outlive the row it describes. |
| user ↔ auction (watchlist) | A many-to-many junction table; the composite primary key stops a user from watching the same auction twice. |

### Delete behaviour

| Foreign key | On delete | Effect |
|---|---|---|
| `fk_bids_auction`, `fk_notifications_*`, `fk_watchlist_*` | CASCADE | Rows that only make sense with their parent go with it. |
| `fk_auctions_winning_bid`, `fk_audit_log_actor` | SET NULL | The parent survives and just loses the link. |
| every other foreign key | RESTRICT | History (listings, bids, sales) can't be deleted out from under a user, item or category. |

`audit_log` is append-only (`trg_audit_immutable`), so the UPDATE that `SET NULL` would
perform is itself refused. In practice, any user who appears in the audit log can't be
deleted.

## 2. Trigger and procedure flow

This is the architecture in one picture. The application does two things: it calls
`place_bid()`, and it calls `close_expired_auctions()` on a timer. Every other write in this
diagram is done by the database itself.

```mermaid
flowchart LR
    subgraph bidpath["Placing a bid"]
        API["POST /api/auctions/:id/bids"] -->|CALL| PB["place_bid<br/>locks auction FOR UPDATE<br/>AU001-AU004 on failure"]
        PB -->|INSERT| BIDS[("bids")]
        BIDS -->|AFTER INSERT| TO["trg_outbid"]
        BIDS -->|AFTER INSERT| TA["trg_audit_bid"]
        TO -->|"INSERT type = OUTBID<br/>for the displaced leader"| N[("notifications")]
        TA -->|"INSERT action = BID_PLACED"| AL[("audit_log")]
        AL -.->|"any UPDATE or DELETE"| TI["trg_audit_immutable<br/>RAISE EXCEPTION"]
    end

    subgraph closepath["Closing auctions"]
        JOB["close_expired_auctions<br/>explicit cursor, FOR UPDATE"] -->|"UPDATE status ACTIVE to CLOSED<br/>WHERE CURRENT OF"| AU[("auctions")]
        AU -->|"AFTER UPDATE<br/>WHEN ACTIVE to CLOSED"| TC["trg_close_auction"]
        TC -->|"INSERT winner, price"| TX[("transactions")]
        TC -->|"INSERT WON + SOLD,<br/>or AUCTION_CLOSED"| N
        JOB -->|"CALL per auction"| AW["award_winner"]
        AW -->|"SET winning_bid_id"| AU
        JOB -->|"REFRESH CONCURRENTLY"| MV[("mv_leaderboard")]
    end

    N -->|"GET /api/notifications/unread-count<br/>every 30 s"| BELL["header bell"]
```

### The bid → notification path in words

1. The API calls `place_bid(user, auction, amount)`. The procedure locks the auction row
   (`FOR UPDATE`). It checks that the auction exists (AU004), that it is open (AU002), that
   the bidder is not the seller (AU003), and that the amount is at least the high bid plus
   the increment (AU001). Then it inserts one row into `bids`.
2. That INSERT fires two `AFTER INSERT` triggers on `bids`:
   - `trg_outbid` finds the best earlier bid by a *different* bidder, the person just
     displaced, and inserts an `OUTBID` notification for them;
   - `trg_audit_bid` appends a `BID_PLACED` row to `audit_log` with the bid's id, amount
     and time.
3. Everything above is one transaction. If any step fails, the bid, the notification and
   the audit row all roll back together.
4. The displaced bidder's header bell polls `unread-count` and goes up by one. No
   application code wrote that notification.

### The close path in words

1. `close_expired_auctions()` opens a cursor over `ACTIVE` auctions whose `end_time` has
   passed, locking each row as it is fetched.
2. For each row it runs `UPDATE ... SET status = 'CLOSED' WHERE CURRENT OF` the cursor. That
   status flip fires `trg_close_auction`, which:
   - writes the `transactions` row and the `WON` / `SOLD` notifications if there is a
     winning bid that meets the reserve;
   - otherwise writes a single `AUCTION_CLOSED` notification to the seller.
3. `award_winner()` then stamps `auctions.winning_bid_id`, and after the loop the procedure
   refreshes `mv_leaderboard` concurrently, so readers are never blocked.

A manual `UPDATE auctions SET status = 'CLOSED'` fires the same trigger. Settlement doesn't
depend on which code path closed the auction.
