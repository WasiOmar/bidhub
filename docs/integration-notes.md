# INT-01 integration notes

What the integration pass found and fixed, and the evidence that the build now works
from zero. This is the raw material for the INT-01 pull request description.

## 1. Clean rebuild from an empty volume

A throwaway `postgres:16` container with a new, empty volume, then `db/01 → db/07` in
numeric order with `ON_ERROR_STOP=1`:

```
db/01_schema.sql      ok
db/02_triggers.sql    ok
db/03_procedures.sql  ok
db/04_queries.sql     ok
db/05_indexes.sql     ok
db/06_views.sql       ok
db/07_seed.sql        ok      close_expired_auctions: closed 20 auction(s)
```

No ordering or dependency errors on the first try. `bash scripts/rebuild-db.sh` now does
exactly this run and prints the row counts.

## 2. Ten-technique verification

`bash scripts/verify-all.sh --rebuild` against a fresh database in the docker compose
cluster. The compose cluster matters for 08, because `concurrency.sh` restarts that
container to prove durability.

```
PASS  01 TRIGGER             B outbid A: trg_outbid wrote 1 OUTBID row for A, trg_audit_bid wrote 2 audit rows
PASS  02 TRIGGER+PROC        status flip: trg_close_auction wrote a 110.00 transaction + WON/SOLD; award_winner set winning_bid_id
PASS  03 PROCEDURE           underbid rejected with SQLSTATE AU001: "bid 105.00 is below the minimum required bid of 110.00"
PASS  04 CTE+ROW_NUMBER      auction 31: row 1 = 1425.00 = MAX(amount); positions 1..13, one per bidder, one leader
PASS  05 WINDOW FUNCTIONS    RANK() consistent for 14 bidders; SUM() OVER totals match for 5 sellers; LAG() NULL once per auction
PASS  06 CURSOR              cursor closed all 2 expired ACTIVE auctions, left all 16 live ones ACTIVE
PASS  07 RECURSIVE CTE       depth 3: Art & Collectibles > Paintings > Oil Paintings > Landscape Oil Paintings (breadcrumb walks back up 4 levels)
PASS  08 ACID                concurrent bids serialised by FOR UPDATE, a committed bid survived a container restart; test_concurrency.sql 7/7
PASS  09 COMPOSITE INDEX     MAX(amount) for auction 15: Index Only Scan on idx_bids_auction_amount (auction_id, amount DESC), no Seq Scan
PASS  10 MATERIALIZED VIEW   REFRESH ... CONCURRENTLY succeeded; new bid absent before, 150.00 after; mv = live view

10/10 PASS
```

The numbers (auction ids, bid totals) vary between runs because the seed draws bids
at random. Every check except 08 runs inside a transaction that is rolled back.

## 3. Test suites

| Suite | Before INT-01 | After |
|---|---|---|
| `db/tests/test_schema.sql` | pass | 4/4 |
| `db/tests/test_triggers.sql` | pass | 5/5 |
| `db/tests/test_procedures.sql` | aborted after check 1 (`chk_auctions_end_after_start`) | 6/6 |
| `db/tests/test_queries.sql` | aborted after check 1 (`cannot accumulate arrays of different dimensionality`) | 7/7 |
| `db/tests/test_concurrency.sql` | every `\gset`/`:var` broken (CR-only line endings), then `syntax error at or near ":"` in every DO block | 7/7 |
| `db/tests/test_views.sql` | pass | 7/7 |
| `db/tests/concurrency.sh` | isolation check could never pass; second run always aborted | pass, re-runnable |
| `server/test-api.sh` | 1/9 (item creation failed) | 9/9 |

`bash scripts/run-tests.sh` runs every SQL suite and summarises: 36 checks, all passing.

## 4. What was broken, and the fix

| Problem | Cause | Fix |
|---|---|---|
| psql meta-commands ignored in five test files | Files committed with CR-only line endings; psql does not treat a bare CR as a line break | Converted to LF; `.gitattributes` forces LF from now on. Server and client sources had the same endings and were normalised too (no content change, verified byte for byte). |
| `test_concurrency.sql` DO blocks fail | psql never interpolates `:auction_id` inside a dollar-quoted body | Ids handed over with `SET acid.* = :'var'` and read with `current_setting()` |
| `test_procedures.sql` aborts | Past `end_time` with the default `start_time = now()` violates `chk_auctions_end_after_start` | Explicit `start_time` one day back |
| `test_queries.sql` aborts | `array_agg` over `TEXT[]` paths of different lengths | Compare the `category_id` order instead |
| `concurrency.sh` isolation always FAIL | The item's seller was also Bidder A, so A got AU003 and there was only one bid | Dedicated seller; the check now requires exactly one accepted bid and one AU001 |
| `concurrency.sh` aborts on the second run | Deleting fixture users sets `audit_log.actor_id` to NULL, an UPDATE that `trg_audit_immutable` rejects | Fixture users are reused (`ON CONFLICT DO NOTHING`), never deleted |
| `POST /api/items` always 500 | `COALESCE($5, 'USED')` is `text`, not `item_condition` | `$5::item_condition` |
| Raw SQL in API errors | Integrity errors echoed PostgreSQL's message (`duplicate key value violates unique constraint "uq_users_email"`) | Per-constraint sentences; only the typed `AU00x` messages pass through |
| Bad input returned 500 | `/api/auctions/abc`, `?status=FOO`, bad dates, malformed JSON bodies | 400 `VALIDATION_ERROR` |
| Bell polled the full notification list | No count endpoint; `idx_notifications_user_unread` could never be used | `GET /api/notifications/unread-count`; the bell uses it |

## 5. Vocabulary check

A repo-wide search for `watch`, `brand`, `Rolex`, `LuxBid`, `horology` and `luxury`,
outside the seed data, found nothing left to generalize:

- `db/01_schema.sql` mentions a "luxury-watch-only schema" only to explain why
  `items.attributes` is JSONB. That sentence is about the generalization, so it stays.
- `watchlist` / "watches a given auction" is the generic save-for-later feature.
- `brand` appears as a JSONB attribute key in the guitar seed rows and the synthetic
  benchmark data, plus the `app-brand` CSS class for the logo, all domain-neutral.

## 6. API surface vs. contract

`docs/contract.md` §7 lists every difference between the Phase 0 plan and the code:
the 5433 port, the extra routines and views, `get_category_tree`'s `DEFAULT NULL`, the
`health` and `unread-count` routes, `POST /api/auctions` creating `ACTIVE` auctions,
and the database objects the API does not expose (`watchlist`, `v_bid_momentum`,
`v_category_leaderboard`).

## 7. Environment notes

- On Windows, Git Bash's `grep -P` refuses to run under a non-UTF-8 locale, which
  makes `server/test-api.sh` report false failures. Run it with
  `LC_ALL=en_US.UTF-8 bash server/test-api.sh`.
- `scripts/lib.sh` adds the newest `C:\Program Files\PostgreSQL\*\bin` to `PATH` when
  `psql` is missing, so the scripts run from Git Bash without setup.
