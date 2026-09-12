# Viva demo script

A timed walkthrough, roughly ten minutes, that fires all ten graded techniques in one
sitting. Each step lists what to click, one sentence to say, what the examiner should
see, and the psql fallback if the UI misbehaves. The technique behind each step is
explained in [technique-report.md](technique-report.md).

## Before the examiner arrives (T−10 min)

1. **Database up:** `docker compose up -d`, then `docker compose ps` until it shows
   `healthy`.
2. **API with the auto-close job off**, so the cursor step (6:30) is done by hand in front
   of the examiner and not silently by the job. In `.env`, set
   `ENABLE_AUCTION_JOB=false`, then run `cd server && npm run dev`.
3. **Client:** `cd client && npm run dev`, then open http://localhost:5173.
4. **Two browsers**, side by side. Every seed account's password is `password123`.
   - **Browser A** (normal window): log in as `buyer1@bidhub.local` (Liam Chen).
   - **Browser B** (private window): log in as `buyer2@bidhub.local` (Olivia Brooks).
5. **A psql window:**
   ```bash
   psql postgresql://bidhub:bidhub@localhost:5433/bidhub
   ```
   ```sql
   \set VERBOSITY verbose
   ```
6. **Rehearse the reset once.** The seed starts five auctions that end 3, 5, 8, 12 and
   15 minutes after seeding. Their clocks start at step 0:00, so do the real reset at
   the start of the viva, not earlier.

## Timeline

| Time | Step | Technique |
|---|---|---|
| 0:00 | Reset and seed, show the row counts | (setup) |
| 1:00 | Browse the four-level category tree | 07 RECURSIVE CTE |
| 2:00 | Open an auction, show the leaderboard and the report | 04 CTE + ROW_NUMBER, 10 MATERIALIZED VIEW |
| 3:00 | Browser A bids, Browser B outbids | 03 PROCEDURE, 08 ACID |
| 3:30 | Browser A's bell goes up | 01 TRIGGER |
| 4:30 | Underbid, and the AU001 message | 03 typed RAISE EXCEPTION |
| 5:30 | Show audit_log, then fail to change it | ✚ append-only TRIGGER |
| 6:30 | An auction has expired: run the job | 06 CURSOR, 02 TRIGGER + PROCEDURE |
| 7:30 | Analytics page | 05 WINDOW FUNCTIONS |
| 8:30 | EXPLAIN before and after the index | 09 COMPOSITE INDEX |
| 9:30 | Close with `verify-all.sh` | all ten |

---

### 0:00 — Reset and seed

- **Do:** in a terminal at the repo root, run `bash scripts/rebuild-db.sh`.
- **Say:** "Seven SQL files, in order, build the whole system. The seed places its bids
  through `place_bid`, so every notification and audit row you see was written by a
  trigger, not by the seed."
- **Examiner sees:** seven `ok` lines, then row counts. Roughly: users 20, categories 20,
  items 60, auctions 40, bids 400–500 (random), transactions 15, notifications about
  equal to bids, audit_log exactly equal to bids, mv_leaderboard 40.
- **If it breaks:** run the files one at a time to find the failing one:
  `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/01_schema.sql` (then 02 … 07). Check
  `docker compose ps` for `healthy`, and check that `DATABASE_URL` points at port 5433.

Then, in psql, pick the demo auction: the busiest live auction that won't end during the
viva. `\gset` stores its columns as psql variables for the later steps.

```sql
SELECT auction_id, item_title, current_high_bid, bid_count
  FROM mv_leaderboard
 WHERE status = 'ACTIVE' AND end_time > now() + interval '1 day'
 ORDER BY bid_count DESC
 LIMIT 1 \gset
\echo demo auction :auction_id :item_title
```

### 1:00 — Category tree (RECURSIVE CTE)

- **Do:** Browser A → **Browse**. Expand **Electronics → Computers → Laptops → Gaming
  Laptops**. Point at the numbers in brackets, then click a category to filter the grid.
- **Say:** "One `WITH RECURSIVE` query returns the whole tree at any depth. Adding a fifth
  level is an INSERT, not a schema change, and that's what makes this platform
  general-purpose. The counts are subtree totals."
- **Examiner sees:** a tree expanding four levels, across five unrelated domains.
- **If it breaks:**
  ```sql
  SELECT repeat('    ', depth) || name AS category FROM get_category_tree();
  ```

### 2:00 — Auction page: leaderboard and report (CTE + ROW_NUMBER, MATERIALIZED VIEW)

- **Do:** Browser A → **Home**, open the demo auction (title from `\echo`). Point at:
  - the breadcrumb (a recursive CTE walking *up*);
  - the specification table (the item's JSONB `attributes`);
  - the **Leaderboard**: the `#` column is `ROW_NUMBER()`, and the highlighted row is the
    leader.

  Then in psql:
  ```sql
  SELECT auction_id, item_title, current_high_bid, high_bidder_name, bid_count, computed_at
    FROM mv_leaderboard WHERE auction_id = :auction_id;
  ```
- **Say:** "The leaderboard is two CTEs: best bid per bidder, then `ROW_NUMBER()` over
  them. `mv_leaderboard` stores that whole report pre-joined. `computed_at` says when it
  was last refreshed, and a concurrent refresh never blocks readers."
- **Examiner sees:** a ranked table with position 1 highlighted, and the same auction as
  one row in the materialized view.
- **If it breaks:** `SELECT * FROM get_leaderboard(:auction_id);`

### 3:00 — Two bidders (PROCEDURE, ACID)

- **Do:** Browser A places the pre-filled minimum bid on the demo auction, so A now
  leads. Browser B opens the same auction and places *its* pre-filled minimum. Within
  5 seconds, Browser A's leaderboard updates to show B on top.
- **Say:** "The API does exactly one thing: `CALL place_bid`. The procedure locks this
  auction's row `FOR UPDATE`, validates, and inserts. If two bids arrive at the same
  instant, the second waits and then gets 'too low', so nobody can win with a stale
  price."
- **Examiner sees:** the two windows racing; B leading in both after a poll.
- **Optional, if asked about concurrency:** `bash db/tests/concurrency.sh` fires two
  simultaneous bids from two sessions and prints `PASS Isolation`. It then restarts the
  database container to prove durability, so warn the examiner about the 5-second pause.
- **If it breaks:**
  ```sql
  SELECT user_id AS buyer2 FROM users WHERE email = 'buyer2@bidhub.local' \gset
  CALL place_bid(:buyer2, :auction_id, <amount>);
  ```

### 3:30 — The bell (TRIGGER)

- **Do:** watch Browser A's 🔔. It goes up by one within 30 seconds (reload to force it).
  Click it to open **Notifications**, and point at the caption.
- **Say:** "No application code wrote that. `trg_outbid` fired `AFTER INSERT` on `bids`,
  found who was displaced, and inserted the notification in the same transaction as the
  bid."
- **Examiner sees:** a new "You have been outbid" row, and the caption "Every row here was
  written by a database trigger".
- **If it breaks:**
  ```sql
  SELECT type, title, message, created_at FROM notifications
   WHERE user_id = (SELECT user_id FROM users WHERE email = 'buyer1@bidhub.local')
   ORDER BY created_at DESC LIMIT 3;
  ```

### 4:30 — Underbid (typed RAISE EXCEPTION)

- **Do:** in Browser A, type an amount *below* the shown minimum (for example the current
  high bid) and submit.
- **Say:** "That message starts as `RAISE EXCEPTION ... USING ERRCODE = 'AU001'` inside
  `place_bid`. The API maps SQLSTATE AU001 to HTTP 400, and the client reads the minimum
  out of the message."
- **Examiner sees:** "Your bid is too low — minimum is X."
- **If it breaks:**
  ```sql
  SELECT user_id AS buyer1 FROM users WHERE email = 'buyer1@bidhub.local' \gset
  CALL place_bid(:buyer1, :auction_id, 1);
  ```
  This prints `ERROR: AU001: bid 1 is below the minimum required bid of …`.

### 5:30 — Audit trail you cannot edit (append-only TRIGGER)

- **Do:** in psql:
  ```sql
  SELECT audit_id, actor_id, action, entity_id, payload
    FROM audit_log ORDER BY audit_id DESC LIMIT 3;

  UPDATE audit_log SET payload = '{}' WHERE audit_id = (SELECT max(audit_id) FROM audit_log);
  DELETE FROM audit_log WHERE audit_id = (SELECT max(audit_id) FROM audit_log);
  ```
- **Say:** "Every bid, including the two we just placed, is logged with a JSONB snapshot.
  Even the database owner can't rewrite it: a `BEFORE UPDATE OR DELETE` trigger refuses."
- **Examiner sees:** the latest `BID_PLACED` rows, then
  `ERROR: audit_log is append-only: UPDATE on audit_id … is not permitted` (and the same
  for DELETE).
- **If it breaks:** there is no UI for this step; it is psql only.

### 6:30 — Expire and close (CURSOR, TRIGGER + PROCEDURE)

- **Do:** by now the seed's 3-minute and 5-minute auctions (*Vortex X15 Gaming Laptop*,
  *1969 Chevrolet Camaro SS*) have ended but are still `ACTIVE`, because the job is off.
  Optionally open one in Browser B and try to bid: "This auction has ended" (AU002). Then
  in psql:
  ```sql
  SELECT a.auction_id, i.title, a.end_time
    FROM auctions a JOIN items i USING (item_id)
   WHERE a.status = 'ACTIVE' AND a.end_time < now();

  CALL close_expired_auctions();

  SELECT t.auction_id, i.title, t.final_amount, u.full_name AS buyer
    FROM transactions t
    JOIN items i ON i.item_id = t.item_id
    JOIN users u ON u.user_id = t.buyer_id
   ORDER BY t.transaction_id DESC LIMIT 3;
  ```
- **Say:** "An explicit cursor: declare it `FOR UPDATE`, open, fetch one auction, update it
  `WHERE CURRENT OF`, repeat, close. Each status flip fires `trg_close_auction`, which
  writes the transaction and the WON and SOLD notifications. `award_winner` then records
  the winning bid, and the materialized view is refreshed."
- **Examiner sees:** `NOTICE: close_expired_auctions: closed 2 auction(s)`, then the new
  transaction rows. Reload the auction page and its status is CLOSED.
- **If it breaks** (nothing had expired yet, for example because the reset was late), end
  the soonest live auction by hand, then run the `CALL` again:
  ```sql
  UPDATE auctions SET end_time = now() - interval '1 second'
   WHERE auction_id = (SELECT auction_id FROM auctions
                        WHERE status = 'ACTIVE' AND auction_id <> :auction_id
                        ORDER BY end_time LIMIT 1);
  ```

### 7:30 — Analytics (WINDOW FUNCTIONS)

- **Do:** Browser A → **Analytics**. Point at the caption under each table. Then in psql:
  ```sql
  SELECT bid_id, amount, previous_amount, amount_jump
    FROM v_bid_momentum WHERE auction_id = :auction_id
   ORDER BY placed_at DESC LIMIT 5;
  ```
- **Say:** "Window functions compute across rows without collapsing them: `RANK()` over
  every bidder's total, a running `SUM() OVER` per seller, and `LAG()` for the previous
  bid in the same auction."
- **Examiner sees:** ranked bidders (ties share a rank), running seller revenue, and in
  psql each bid next to the one before it.
- **Note:** the auction page's "Bid momentum" panel is computed in the browser from the
  leaderboard. For the real `LAG()`, show `v_bid_momentum` in psql as above.
- **If it breaks:** `SELECT * FROM v_top_bidders ORDER BY rank LIMIT 5;` and
  `SELECT * FROM v_seller_revenue ORDER BY seller_id, created_at;`

### 8:30 — EXPLAIN before and after the index (COMPOSITE INDEX)

- **Do:** in psql:
  ```sql
  BEGIN;
  DROP INDEX idx_bids_auction_amount;
  EXPLAIN ANALYZE SELECT MAX(amount) FROM bids WHERE auction_id = :auction_id;
  ROLLBACK;

  EXPLAIN ANALYZE SELECT MAX(amount) FROM bids WHERE auction_id = :auction_id;
  ```
- **Say:** "Without the index, PostgreSQL reads the whole bids table. With
  `(auction_id, amount DESC)`, the highest bid is the first index entry. At demo size both
  are fast. At 50,000 bids we measured 2.7 ms against 0.013 ms per bid, and 3.1 seconds
  against 17 ms for the homepage."
- **Examiner sees:** `Seq Scan on bids` inside the rolled-back transaction, then
  `Index Only Scan using idx_bids_auction_amount` after it. `docs/performance.md` has
  the full before/after table.
- **If it breaks:** `bash scripts/verify-all.sh` check 09 prints the plan node.

### 9:30 — Close

- **Do:** `bash scripts/verify-all.sh` (about 30 seconds; check 08 restarts the database).
- **Say:** "And that's all ten, checked automatically against the live database."
- **Examiner sees:** ten PASS lines and `10/10 PASS`.

---

## After the demo

Run `bash scripts/rebuild-db.sh` to put everything back, including fresh 3–15-minute
auctions for the next rehearsal. Every test and check in this script either rolls back
or cleans up after itself, apart from the bids you placed by hand.
