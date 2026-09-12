# BidHub — technique report

BidHub is a general-purpose auction marketplace on PostgreSQL 16, Express and React. The
lab grades ten PostgreSQL techniques. This report maps each one to the feature it powers,
the exact code, why we chose it, and how to watch it work. Line numbers refer to the files
as committed on this branch.

`bash scripts/verify-all.sh` proves all ten at once (10/10 PASS, output in
[integration-notes.md](integration-notes.md)). The *Demo* column refers to the timed
walkthrough in [demo-script.md](demo-script.md).

## Summary

| # | Technique | Platform feature | Where | Demo | `verify-all` |
|---|---|---|---|---|---|
| 01 | TRIGGER | Outbid notification | `db/02_triggers.sql` 14–60 | 3:30 | 01 |
| 02 | TRIGGER + PROCEDURE | Auction auto-close and settlement | `db/02_triggers.sql` 124–201, `db/03_procedures.sql` 74–117 | 6:30 | 02 |
| 03 | STORED PROCEDURE | Place bid, with validation | `db/03_procedures.sql` 6–65 | 3:00, 4:30 | 03 |
| 04 | CTE + ROW_NUMBER() | Auction leaderboard | `db/04_queries.sql` 1–50 | 2:00 | 04 |
| 05 | WINDOW FUNCTIONS | Bidder, seller and momentum analytics | `db/04_queries.sql` 140–195 | 7:30 | 05 |
| 06 | CURSOR | Batch expiry of auctions | `db/03_procedures.sql` 127–166 | 6:30 | 06 |
| 07 | RECURSIVE CTE | Category tree and breadcrumb | `db/04_queries.sql` 51–139 | 1:00 | 07 |
| 08 | ACID TRANSACTION | Concurrent bid safety | `db/03_procedures.sql` 25–30, `db/tests/test_concurrency.sql`, `db/tests/concurrency.sh` 71–152 | 3:00 | 08 |
| 09 | COMPOSITE INDEX | Fast top-bid lookup | `db/05_indexes.sql` 37–61 | 8:30 | 09 |
| 10 | MATERIALIZED VIEW | Live auction report | `db/06_views.sql` 121–161 | 2:00 | 10 |
| ✚ | TRIGGER, append-only | Tamper-evident audit trail | `db/02_triggers.sql` 71–115 | 5:30 | 01 |

---

## 01 · TRIGGER — outbid notification

**Feature.** When someone is outbid, they get a notification (the bell in the header)
without any application code writing it.

**Where.** `db/02_triggers.sql` lines 14–60: function `fn_trg_outbid()` (14–55) and
trigger `trg_outbid` (57–60).

```sql
    SELECT b.bidder_id
      INTO v_prev_bidder_id
    FROM bids b
    WHERE b.auction_id = NEW.auction_id
      AND b.bidder_id <> NEW.bidder_id
      AND b.bid_id <> NEW.bid_id
    ORDER BY b.amount DESC, b.placed_at ASC
    LIMIT 1;
```
```sql
CREATE TRIGGER trg_outbid
    AFTER INSERT ON bids
    FOR EACH ROW
    EXECUTE FUNCTION fn_trg_outbid();
```

The trigger reads `NEW` (the bid just inserted) and finds the best earlier bid by a
*different* bidder: the person just displaced. It then inserts an `OUTBID` notification
for them (lines 43–51). If there was no previous leader, it returns without writing
anything (33–35).

**Why a trigger.** The alternative is for the API to insert the notification after
calling `place_bid`. Then every future code path that inserts a bid (the seed, an admin
tool, a batch import) would have to remember to do it, and a crash between the two writes
would lose it. A row-level `AFTER INSERT` trigger runs inside the same transaction as the
bid, so a bid without its notification cannot exist. `AFTER`, not `BEFORE`, because the
bid must already have its `bid_id` and have passed every constraint.

**Observe it.** Two browsers, one auction: B outbids A, and A's bell goes up within one
30-second poll. In psql:
`SELECT type, message FROM notifications ORDER BY notification_id DESC LIMIT 3;`

---

## 02 · TRIGGER + PROCEDURE — auction auto-close

**Feature.** When an auction closes, the sale settles by itself: a `transactions` row, a
`WON` notification to the winner and a `SOLD` notification to the seller. If there were no
bids, or the reserve was not met, the seller gets an `AUCTION_CLOSED` notice instead.

**Where.** `db/02_triggers.sql` lines 124–201 (`fn_trg_close_auction()` 124–195,
trigger 197–201). `db/03_procedures.sql` lines 74–117 (`award_winner`).

```sql
CREATE TRIGGER trg_close_auction
    AFTER UPDATE ON auctions
    FOR EACH ROW
    WHEN (OLD.status = 'ACTIVE' AND NEW.status = 'CLOSED')
    EXECUTE FUNCTION fn_trg_close_auction();
```
```sql
    INSERT INTO transactions (auction_id, buyer_id, seller_id, item_id, final_amount, status)
    VALUES (NEW.auction_id, v_winning_bid.bidder_id, v_seller_id, NEW.item_id, v_winning_bid.amount, 'PENDING')
    ON CONFLICT ON CONSTRAINT uq_transactions_auction DO NOTHING;
```

The trigger picks the winner with the platform-wide tie-break (highest amount, then
earliest `placed_at`, lines 139–144), checks the reserve (157–167) and writes the sale. The
procedure `award_winner(p_auction_id)` then stamps `auctions.winning_bid_id` (113–115).

**Why this split.** The `WHEN (OLD.status = 'ACTIVE' AND NEW.status = 'CLOSED')` clause
means settlement fires on the *transition* however it happens: the cursor job, a manual
`UPDATE` by an admin, or a future API route. The work lives in one place.
`uq_transactions_auction` plus `ON CONFLICT DO NOTHING` makes a double close harmless.
`award_winner` is a separate procedure because it updates `auctions` itself. Doing that
inside an `AFTER UPDATE` trigger on the same table would re-fire the trigger.

**Observe it.** `UPDATE auctions SET status = 'CLOSED' WHERE auction_id = N;` then
`SELECT * FROM transactions WHERE auction_id = N;` and the new `WON`/`SOLD` rows in
`notifications`.

---

## 03 · STORED PROCEDURE — place a bid

**Feature.** The only way to bid. `POST /api/auctions/:id/bids` does nothing but
`CALL place_bid($1, $2, $3)`. All validation lives in the database, and the API does
none of its own.

**Where.** `db/03_procedures.sql` lines 6–65.

```sql
    SELECT a.status, a.end_time, a.starting_price, a.bid_increment, i.seller_id
      INTO v_status, v_end_time, v_starting_price, v_increment, v_seller_id
    FROM auctions a
    JOIN items i ON i.item_id = a.item_id
    WHERE a.auction_id = p_auction_id
    FOR UPDATE OF a;
```
```sql
    v_max_amount := COALESCE(
        (SELECT MAX(b.amount) FROM bids b WHERE b.auction_id = p_auction_id),
        v_starting_price - v_increment
    );
    v_min_required := v_max_amount + v_increment;

    IF p_amount < v_min_required THEN
        RAISE EXCEPTION 'bid % is below the minimum required bid of %', p_amount, v_min_required
            USING ERRCODE = 'AU001';
    END IF;
```

The checks run in order: the auction exists (`AU004`, line 34), it is `ACTIVE` and not
past `end_time` (`AU002`, 40), the bidder is not the seller (`AU003`, 45), and the amount
clears the floor (`AU001`, 56). `COALESCE` makes the first bid's floor exactly the
starting price.

**Why a procedure.** Validating in Node would mean reading the high bid, deciding, then
inserting: three round trips with a race between them. Inside the procedure, the check
and the insert happen under one row lock, in one transaction. The typed `SQLSTATE`s
(`AU001`–`AU004`) reach the client unchanged. `server/src/middleware/errors.js` maps
them to HTTP 400/409/403/404, and `client/src/api/client.js` turns AU001 into "Your bid is
too low — minimum is X". We used a `PROCEDURE`, not a `FUNCTION`, because it returns
nothing and is called for its effect.

**Observe it.** Bid below the minimum in the UI, or run
`CALL place_bid(7, 3, 1);` in psql with `\set VERBOSITY verbose` and read
`ERROR: AU001: bid 1 is below the minimum required bid of …`.

---

## 04 · CTE + ROW_NUMBER() — auction leaderboard

**Feature.** The ranked leaderboard on every auction page: one row per bidder, their best
bid, position 1 highlighted as leading.

**Where.** `db/04_queries.sql` lines 1–50, `get_leaderboard(p_auction_id)`.

```sql
    ranked_bids AS (
        SELECT
            bidder_id,
            bidder_name,
            item_title,
            amount,
            placed_at,
            ROW_NUMBER() OVER (
                ORDER BY amount DESC, placed_at ASC
            ) AS position
        FROM max_bids_per_user
    )
```

The first CTE, `max_bids_per_user` (lines 14–27), reduces the auction's bids to each
bidder's best. The second, `ranked_bids` (28–39), numbers them. The outer query marks
`position = 1` as `is_leading` (47).

**Why these constructs.** CTEs make the two steps readable top to bottom (first
"best per bidder", then "rank them") instead of a nested subquery. `ROW_NUMBER()`, not
`RANK()`: a leaderboard needs exactly one leader and consecutive positions, even if two
amounts ever tied. `placed_at ASC` is the same tie-break used by `place_bid`, the triggers
and `award_winner`, so every component agrees on who leads.

**Observe it.** The auction page's leaderboard table (the `#` column is `position`).
In psql: `SELECT * FROM get_leaderboard(3);`

---

## 05 · WINDOW FUNCTIONS — analytics

**Feature.** The Analytics page: top bidders ranked by total value, and each seller's
running revenue. Bid-to-bid momentum is also available as a view.

**Where.** `db/04_queries.sql` lines 140–195: `v_top_bidders` (140–149), `v_seller_revenue`
(150–164), `v_bid_momentum` (165–180), `v_category_leaderboard` (181–195).

`v_top_bidders`, line 146:
```sql
    RANK() OVER (ORDER BY SUM(b.amount) DESC) AS rank
```
`v_seller_revenue`, lines 157–161:
```sql
    SUM(t.final_amount) OVER (
        PARTITION BY t.seller_id
        ORDER BY t.created_at
        ROWS UNBOUNDED PRECEDING
    ) AS running_revenue
```
`v_bid_momentum`, lines 172–175:
```sql
    LAG(b.amount) OVER (
        PARTITION BY b.auction_id
        ORDER BY b.placed_at
    ) AS previous_amount,
```

**Why window functions.** Each of these needs a value computed *across* rows while keeping
every row. `GROUP BY` would collapse them; self-joins or correlated subqueries would
re-scan the table for every row. `RANK()` lets tied bidders share a place (which is
honest for a ranking). `ROWS UNBOUNDED PRECEDING` makes the running total explicit
instead of relying on the default `RANGE` frame. `LAG()` reads the previous bid in the
same auction without a self-join. `v_category_leaderboard` uses `DENSE_RANK()` for
per-category price rankings.

**Observe it.** The Analytics page captions name the function under each table
(`GET /api/analytics/top-bidders`, `/seller-revenue`). For `LAG()`:
`SELECT amount, previous_amount, amount_jump FROM v_bid_momentum WHERE auction_id = 3 ORDER BY placed_at;`

*Limitation:* the auction page's "Bid momentum" panel is captioned `v_bid_momentum`, but
it is computed in the browser from the leaderboard rows; no API route serves the view
yet. The view itself is shown in psql during the demo.

---

## 06 · CURSOR — batch expiry

**Feature.** Auctions whose time is up are closed in a batch, by the Node job every
60 s (`server/src/jobs/closeAuctions.js`) or by hand. Each close triggers settlement (02).

**Where.** `db/03_procedures.sql` lines 127–166, `close_expired_auctions()`.
Lines 132–155, blank lines omitted:

```sql
    cur_expired CURSOR FOR
        SELECT auction_id, item_id
          FROM auctions
         WHERE end_time < now() AND status = 'ACTIVE'
         ORDER BY end_time
           FOR UPDATE;
    OPEN cur_expired;
    LOOP
        FETCH cur_expired INTO rec;
        EXIT WHEN NOT FOUND;
        UPDATE auctions SET status = 'CLOSED' WHERE CURRENT OF cur_expired;
        CALL award_winner(rec.auction_id);
        v_count := v_count + 1;
    END LOOP;
    CLOSE cur_expired;
```

The full lifecycle is explicit: `DECLARE` (132), `OPEN` (142), `FETCH` (146),
`EXIT WHEN NOT FOUND` (147), process (148–151), `CLOSE` (155). After the loop, it refreshes
`mv_leaderboard` concurrently (160–162) and raises a `NOTICE` with the count (164).

**Why a cursor.** Each auction needs its own side effects: the trigger's settlement and
`award_winner`. An explicit cursor processes them one at a time while `FOR UPDATE` keeps
the rows locked, so a late bid can't slip in between "found expired" and "closed".
`WHERE CURRENT OF` updates exactly the fetched row without a second index lookup.
`ORDER BY end_time` closes the longest-overdue first, and it matches the partial index
`idx_auctions_active_end`. A single set-based `UPDATE ... WHERE end_time < now()` would
also fire the trigger per row. The cursor makes the per-row lifecycle visible, which is
what this technique is here to show.

**Observe it.** The seed creates auctions that end 3, 5, 8, 12 and 15 minutes after
seeding. After they expire: `CALL close_expired_auctions();` prints
`NOTICE: close_expired_auctions: closed 2 auction(s)`, and `transactions` gains the new
rows.

---

## 07 · RECURSIVE CTE — category tree

**Feature.** The Browse page's collapsible category tree (any depth, with subtree item
counts) and the breadcrumb above each item.

**Where.** `db/04_queries.sql`: `get_category_tree` 51–84 (downward walk),
`get_category_breadcrumb` 85–109 (upward walk), `get_category_item_counts` 110–139
(subtree roll-up). Lines 69–80:

```sql
        WHERE (p_root_id IS NULL AND c.parent_id IS NULL)
           OR (p_root_id IS NOT NULL AND c.category_id = p_root_id)
        UNION ALL
        SELECT
            child.category_id, child.name, child.slug, child.parent_id,
            parent.depth + 1,
            parent.path || child.name
        FROM categories child
        JOIN cat_tree parent ON child.parent_id = parent.category_id
        WHERE parent.depth < 20
          AND NOT (parent.path @> ARRAY[child.name]::TEXT[])
    )
```

The anchor selects the roots (or one subtree root). The recursive member joins children
onto the rows found so far, carrying `depth` and the `path` array. The final
`ORDER BY path` returns the tree in display order. The depth cap and the path check stop
a malformed cycle from recursing forever.

**Why a recursive CTE.** `categories` is an adjacency list (`parent_id` references
`categories`), so the depth is data, not schema (see [normalization.md](normalization.md)).
Only a recursive query can walk an unknown depth in one statement. The alternative, one
query per level from Node, costs N round trips. `idx_categories_parent` serves the join in
each recursive step.

**Observe it.** Browse → Electronics → Computers → Laptops → Gaming Laptops.
In psql: `SELECT repeat('  ', depth) || name FROM get_category_tree();`

---

## 08 · ACID TRANSACTION — concurrent bid safety

**Feature.** Two people bidding on the same auction at the same instant can't both win
the same position, a half-finished bid never persists, and an accepted bid survives a
crash.

**Where.** The mechanism is the transaction around `place_bid` and its row lock,
`db/03_procedures.sql` lines 25–30 (`FOR UPDATE OF a`, excerpt under 03). The proofs:

- `db/tests/test_concurrency.sql`: atomicity 72–111, consistency 123–149, isolation
  177–236, durability 253–272;
- `db/tests/concurrency.sh`: real concurrent sessions 71–105, and a container restart
  107–152.

`db/tests/concurrency.sh` lines 75–80:
```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=0 -v VERBOSITY=verbose -c \
    "CALL place_bid($BIDDER_A, $AUCTION_ID, 110.00)" \
    > "${SCRIPT_DIR}/.con_result_a.txt" 2>&1 &
psql "$DATABASE_URL" -v ON_ERROR_STOP=0 -v VERBOSITY=verbose -c \
    "CALL place_bid($BIDDER_B, $AUCTION_ID, 110.00)" \
    > "${SCRIPT_DIR}/.con_result_b.txt" 2>&1 &
```

| Property | How BidHub gets it | Proof |
|---|---|---|
| Atomicity | The bid, its notification (trigger) and its audit row are one transaction | A failure injected after `place_bid` is rolled back; zero bids, notifications or audit rows remain |
| Consistency | `CHECK (amount > 0)`, foreign keys, `place_bid`'s floor | A negative bid and an orphan bid are both rejected |
| Isolation | `FOR UPDATE` on the auction row serialises bidders under READ COMMITTED | Two simultaneous 110.00 bids: one accepted, the other re-reads the new high bid and gets AU001 |
| Durability | Write-ahead log | A committed marker bid is still there after `docker compose restart db` |

**Why this design.** READ COMMITTED (PostgreSQL's default) plus an explicit row lock.
SERIALIZABLE would also prevent the race, but the loser would get a serialization failure
that the API must catch and retry. With `FOR UPDATE` the second bidder simply waits a few
milliseconds, then gets a meaningful business error (AU001, "minimum is now X"). The lock
covers one auction row, so bids on different auctions never wait for each other.

**Observe it.** `bash db/tests/concurrency.sh` (it restarts the database container), and
`psql "$DATABASE_URL" -f db/tests/test_concurrency.sql` (7 PASS lines, all rolled back).

---

## 09 · COMPOSITE INDEX — fast top-bid lookup

**Feature.** Every bid, every auction page and the homepage need "the highest bid for
auction N". The composite index makes that an index-only read of one entry.

**Where.** `db/05_indexes.sql` lines 37–41 (composite) and 56–61 (the partial index
alongside it). The other seven secondary indexes are in the same file.

```sql
CREATE INDEX idx_bids_auction_amount
    ON bids (auction_id, amount DESC);
```
```sql
CREATE INDEX idx_auctions_active_end
    ON auctions (end_time)
    WHERE status = 'ACTIVE';
```

**Why this index.** Column order is the point. `auction_id` is the equality predicate, so
it leads. Within one auction, `amount DESC` stores the bids already sorted
highest-first, so `MAX(amount)` and `ORDER BY amount DESC LIMIT 1` read the first entry
and never sort. `(amount, auction_id)` would be useless for these queries. The same index
covers the foreign key `fk_bids_auction`. The partial index holds only `ACTIVE` auctions,
the only ones the close cursor and the homepage look up by `end_time`, so it stays small
as closed auctions accumulate.

**Measured** (`db/tests/benchmark.sql`, 50,446 bids, [performance.md](performance.md)):

| Query | Before | After |
|---|---|---|
| Top bid for one auction (`place_bid`'s floor) | Seq Scan, 2.658 ms | Index Only Scan, 0.013 ms (204.5×) |
| Homepage grid, high bid + count per live auction | 3,129.107 ms | 16.772 ms (186.6×) |
| Close-job cursor, expired `ACTIVE` auctions | 0.598 ms | 0.031 ms (19.3×), partial index |

**Observe it.** `EXPLAIN ANALYZE SELECT MAX(amount) FROM bids WHERE auction_id = 3;`
shows `Index Only Scan using idx_bids_auction_amount`. Drop the index inside
`BEGIN … ROLLBACK` to see the `Seq Scan` it replaces (demo step 8:30).

---

## 10 · MATERIALIZED VIEW — live auction report

**Feature.** A pre-joined, pre-ranked report with one row per auction: item, category,
seller, current high bid, leader, bid and bidder counts, time left. It is built for pages
that poll every few seconds.

**Where.** `db/06_views.sql`: `v_auction_summary` 57–104 (the query), `mv_leaderboard`
121–123, `uq_mv_leaderboard_auction` 137–138, `refresh_leaderboard()` 154–161. Also refreshed
at the end of `close_expired_auctions`, `db/03_procedures.sql` 160–162.

```sql
CREATE MATERIALIZED VIEW mv_leaderboard AS
SELECT * FROM v_auction_summary
WITH DATA;
```
```sql
CREATE UNIQUE INDEX uq_mv_leaderboard_auction
    ON mv_leaderboard (auction_id);
```
```sql
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_leaderboard;
```

**Why a materialized view.** The report runs `ROW_NUMBER()` over every bid,
`COUNT(DISTINCT bidder_id)` per auction and five joins. As a plain view, it pays that cost
on every read. Stored, a read is a scan of finished rows:

| Read (5,040 auctions, 50,446 bids) | Plain view | Materialized view |
|---|---|---|
| Full report | 104.910 ms | 0.578 ms (181.5×) |
| Live auctions, `ORDER BY end_time` | 74.263 ms | 0.865 ms (85.9×) |

One refresh costs about as much as 1–2 plain-view reads (135 ms), so any page read more
than once per refresh interval is cheaper from the snapshot. The unique index is what
`REFRESH ... CONCURRENTLY` requires: it diffs old and new rows by key, and without that
index PostgreSQL refuses (`SQLSTATE 55000`, checked in `db/tests/test_views.sql`). In
exchange, readers keep reading the old snapshot during a refresh instead of being blocked
by an `ACCESS EXCLUSIVE` lock. The price is freshness, so anything that must be exact
(`place_bid`'s floor, settlement) reads the base tables.

**Observe it.** `SELECT auction_id, current_high_bid, computed_at FROM mv_leaderboard
WHERE auction_id = 3;`, place a bid, run it again (unchanged), then `CALL
refresh_leaderboard();` and run it once more (updated, new `computed_at`).

---

## ✚ Append-only audit trail (TRIGGER)

`db/02_triggers.sql` 71–115. `trg_audit_bid` (`AFTER INSERT ON bids`, 90–93) writes a
`BID_PLACED` row with a JSONB snapshot for every bid. `trg_audit_immutable`
(`BEFORE UPDATE OR DELETE ON audit_log`, 112–115) raises on any attempt to change or
remove a row, even from the database owner in psql:

```sql
    RAISE EXCEPTION 'audit_log is append-only: % on audit_id % is not permitted', TG_OP, OLD.audit_id
        USING ERRCODE = 'raise_exception';
```

---

## Current limits, and what we would do next

The design is honest about its edges. Notifications and the live auction page are
*polled* (every 30 s and 5 s), which costs a request per client per interval even when
nothing changed. The next step is `LISTEN/NOTIFY`: the existing triggers would add a
`pg_notify('auction_' || NEW.auction_id, …)` call, and the API would push the change over
a WebSocket, so the database would still decide *what* happened and only the transport
would change. `bids` grows fastest and is only ever queried by auction or recent time, so
it is the natural candidate for **declarative partitioning by month** (`PARTITION BY
RANGE (placed_at)`), which keeps the composite index per partition small and lets old
months be detached and archived. Read-heavy pages (the homepage grid, analytics) could be
served from a **streaming read replica**, and `mv_leaderboard` is already the right shape
for them. Right now the API still computes the homepage itself instead of reading the
snapshot. Smaller gaps we know about: nothing promotes `SCHEDULED` auctions to `ACTIVE`
when `start_time` arrives (a second cursor pass or `pg_cron` would), `watchlist` has a
table but no routes, and the auction page's momentum panel should read `v_bid_momentum`
through an API route instead of recomputing in the browser.
