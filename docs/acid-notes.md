# ACID & Concurrency Proof — Slide Mapping

Each row below maps a demo in `db/tests/test_concurrency.sql` or
`db/tests/concurrency.sh` to the exact property wording used on the deck's
ACID slide, so the viva answer is already written down.

---

## A — Atomicity

**Deck wording:** *"A transaction is indivisible: either every effect commits,
or none of them do."*

**Demo:** `test_concurrency.sql` section A.
We `CALL place_bid(...)` (which itself `INSERT`s a `bids` row and fires
`trg_outbid` and `trg_audit_bid`, creating `notifications` and `audit_log`
rows), then immediately inject a `check_violation` by trying to insert a
negative-amount bid. The transaction is rolled back (`ROLLBACK TO SAVEPOINT`)
and we assert that `bids`, `notifications` **and** `audit_log` are all
unchanged — the whole chain rolls back together, not just the bid.

**What the examiner should see:** the `RAISE NOTICE 'PASS Atomicity ...'`
line confirming all three counters are zero.

---

## C — Consistency

**Deck wording:** *"The database moves from one valid state to another; all
declared constraints (CHECK, UNIQUE, FOREIGN KEY) hold at every commit."*

**Demo:** `test_concurrency.sql` section B.
We deliberately violate a `CHECK` (`bids.amount > 0`) and a `FOREIGN KEY`
(`bids.auction_id` referencing a non-existent `auctions` row) inside
savepoint-guarded `DO` blocks. Both raise the expected PostgreSQL error
class (`check_violation`, `foreign_key_violation`) and the outer transaction
remains intact.

**What the examiner should see:** two `PASS Consistency` notices, one per
constraint type.

---

## I — Isolation

**Deck wording:** *"Concurrent transactions do not interfere with each other;
dirty reads are impossible and lost updates are prevented by row locks."*

**Demo:** `test_concurrency.sql` section C (documented under
`SET TRANSACTION ISOLATION LEVEL READ COMMITTED`, declared once as the first
statement of the script's transaction) **and** `concurrency.sh`.

- **C1 — Dirty-read impossibility:** a bid is inserted, then the enclosing
  `DO` block is forced to raise, which undoes the insert via PL/pgSQL's own
  exception-handling (an implicit savepoint) — the same end state a second
  session's `ROLLBACK` would leave. A subsequent read in the same script
  finds zero rows: an uncommitted write is never visible, so a dirty read is
  impossible.
- **C2 — Lost-update prevention:** documented in the SQL file with two
  sequential `UPDATE auctions` statements that both apply their increments,
  and **proven for real** in `concurrency.sh`, which fires two actual
  concurrent `psql` processes calling `place_bid()` for the same auction and
  the same amount at the same instant. `place_bid()` acquires
  `SELECT ... FOR UPDATE` on the auction row, so the second caller blocks
  until the first commits, then re-reads the new high bid and either raises
  `AU001` or places a strictly higher bid — the two callers can never both
  succeed at the same amount.

**What the examiner should see:**

- `PASS Isolation (READ COMMITTED)` from the SQL script (dirty-read demo).
- `PASS Isolation: concurrent bids serialised by FOR UPDATE ...` from
  `concurrency.sh` (lost-update demo, with two live sessions).

---

## D — Durability

**Deck wording:** *"Once a transaction commits, its effects survive power
loss, crashes, and database restarts."*

**Demo:** `test_concurrency.sql` section D documents the WAL guarantee
(a `COMMIT` does not return to the client until its WAL records are fsync'd
to disk) and shows the local half of it — a committed bid is visible to a
fresh read in the same session.

The **practical demo** — the literal restart — lives in `concurrency.sh`:
it commits a marker bid via `place_bid()`, runs `docker compose restart db`,
waits for the container to come back up (`pg_isready`), then re-queries the
marker bid from a brand-new connection.

**What the examiner should see:**

- `PASS Durability: committed bid is visible ...` from the SQL script.
- `PASS Durability: committed bid 777.77 survived 'docker compose restart db'
  (WAL guarantee)` from `concurrency.sh`.

---

## Summary table (marker cheat-sheet)

| Property | File | Section | Proof artefact | Deck wording |
|---|---|---|---|---|
| Atomicity | `db/tests/test_concurrency.sql` | A | Zero residual rows after forced rollback | indivisible unit |
| Consistency | `db/tests/test_concurrency.sql` | B | `check_violation` + `foreign_key_violation` caught | valid-to-valid state |
| Isolation | `db/tests/test_concurrency.sql` + `concurrency.sh` | C | Uncommitted write never visible; two live sessions racing `place_bid()` are serialised by `FOR UPDATE` | no dirty reads, no lost updates |
| Durability | `db/tests/test_concurrency.sql` + `concurrency.sh` | D | Committed row visible after reconnect, and after a real `docker compose restart db` | survives crash / restart |
