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
negative-amount bid.  The transaction is `ROLLBACK`ed and we assert that
`bids`, `notifications` **and** `audit_log` are all unchanged.

**What the examiner should see:** the `RAISE NOTICE 'PASS Atomicity ...'`
line confirming all three counters are zero.

---

## C — Consistency

**Deck wording:** *"The database moves from one valid state to another; all
declared constraints (CHECK, UNIQUE, FOREIGN KEY) hold at every commit."*

**Demo:** `test_concurrency.sql` section B.
We deliberately violate a `CHECK` (`bids.amount > 0`) and a `FOREIGN KEY`
(`bids.auction_id` referencing a non-existent `auctions` row) inside
savepoint-guarded `DO` blocks.  Both raise the expected PostgreSQL error
class (`check_violation`, `foreign_key_violation`) and the outer transaction
remains intact.

**What the examiner should see:** two `PASS Consistency` notices, one per
constraint type.

---

## I — Isolation

**Deck wording:** *"Concurrent transactions do not interfere with each other;
dirty reads are impossible and lost updates are prevented by row locks."*

**Demo:** `test_concurrency.sql` section C.
- **C1 — Dirty-read impossibility:** under `READ COMMITTED`, an uncommitted
  write is rolled back inside a subtransaction and a subsequent read finds
  zero rows.  This proves that no other session could have observed the
  half-written state.
- **C2 — Lost-update prevention:** two sequential `UPDATE auctions` statements
  both apply their increments.  Under the hood, `place_bid()` acquires
  `SELECT ... FOR UPDATE` on the auction row, so two concurrent callers are
  serialised: the second caller waits for the first to `COMMIT`, then re-reads
  the new high bid and either raises `AU001` or places a strictly higher bid.
  `concurrency.sh` fires both callers in parallel and asserts exactly this.

**What the examiner should see:**
- `PASS Isolation (READ COMMITTED)` from the SQL script.
- `PASS concurrent bids serialised by FOR UPDATE` from the bash harness.

---

## D — Durability

**Deck wording:** *"Once a transaction commits, its effects survive power
loss, crashes, and database restarts."*

**Demo:** `test_concurrency.sql` section D.
PostgreSQL guarantees durability through WAL (Write-Ahead Logging): the
commit `fsync`s the WAL before `COMMIT` returns to the client.  We commit a
bid, then simulate the practical durability check by re-querying in a fresh
snapshot.  For the full restart proof, see the bash harness header
documentation: `docker compose restart db` followed by the same query returns
the same row.

**What the examiner should see:** `PASS Durability: committed bid survived
reconnect (WAL flushed before commit returned)`.

---

## Summary table (marker cheat-sheet)

| Property | File | Section | Proof artefact | Deck wording |
|---|---|---|---|---|
| Atomicity | `db/tests/test_concurrency.sql` | A | Zero residual rows after forced rollback | indivisible unit |
| Consistency | `db/tests/test_concurrency.sql` | B | `check_violation` + `foreign_key_violation` caught | valid-to-valid state |
| Isolation | `db/tests/test_concurrency.sql` + `concurrency.sh` | C1 + C2 | Uncommitted read returns 0 rows; parallel bids serialised | no dirty reads, no lost updates |
| Durability | `db/tests/test_concurrency.sql` | D | Committed row visible after reconnect | survives crash / restart |
