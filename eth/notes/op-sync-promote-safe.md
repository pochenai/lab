## How to sync gap and promote safe when local unsafe head < CL head

Context: op-node, CL-sync mode. Node's local EL fell behind (its unsafe head is K blocks
behind the network tip), e.g. after a restart. How does the gap get filled, and how does that
interact with the payload builder. Code paths are repo-root-relative (xlayer-reth), i.e.
`deps/optimism/op-node/...`.

### The unsafe head (`e.unsafeHead`) — where it comes from

`onPendingSafeUpdate` decides consolidate-vs-build using `x.Unsafe`, which is `e.unsafeHead`
(`rollup/engine/engine_controller.go` emits `PendingSafeUpdateEvent{ Unsafe: e.unsafeHead, PendingSafe }`
at ~L860/L880; the field's comment: "tip … to determine if there are existing blocks to consolidate").

`e.unsafeHead` lifecycle:
- **Startup**: loaded from the EL's local persisted head — `engine_controller.go:460-466`
  (`if e.unsafeHead == empty { SetUnsafeHead(ref); "Loaded initial local-unsafe block ref" }`).
  So after a restart-behind it starts at the **stale local head**.
- **Advanced** via `SetUnsafeHead`, called from `insertUnsafePayload` (`engine_controller.go:649`) —
  driven by **both** CL gossip and req/resp altSync — and by local block building.

### Two ways forward blocks arrive: gossip vs altSync

- **CL gossip** (`p2p` → `OnUnsafeL2Payload`) delivers the **live tip going forward** (tip+1, tip+2…),
  NOT the historical gap. A gossiped tip block whose **parent is missing** can't be inserted
  (`NewPayload` can't apply it) → it's buffered and triggers a gap check. So gossip alone does **not**
  advance `unsafeHead` across a gap.
- **req/resp altSync** backfills the gap: `checkForGapInUnsafeQueue` (`rollup/driver/driver.go:466`)
  detects `end.Number > start.Number+1` and calls `s.altSync.RequestL2Range(...)` (driver.go:473/476)
  to fetch the missing unsafe blocks from peers. They come back via `OnUnsafeL2Payload` (driver.go:495)
  → `InsertUnsafePayload` (engine_controller.go:577) → `SetUnsafeHead` (:649) → `unsafeHead` advances.

### The race: two `select` arms in the driver event loop

Both "racing events" are `case` arms of the single `select` in the driver event loop
(`rollup/driver/driver.go:337-374`). Single-threaded, so it's really "which channel is ready and
picked (Go `select` is random among ready) per iteration".

- **altSync arm** (advances `unsafeHead` → consolidate, safe):
  - `driver.go:358  case <-altSyncTicker.C:` — ticker fires every `syncCheckInterval = 2×block_time`
    (`driver.go:302-303`)
  - `driver.go:361  s.checkForGapInUnsafeQueue(ctx)` → `RequestL2Range` → (peer) → `OnUnsafeL2Payload`
    → `InsertUnsafePayload` → `SetUnsafeHead`.

- **derivation arm** (builds from L1 → build path):
  - `driver.go:368/370  case <-s.sched.NextStep() / NextDelayedStep():` — ready whenever there is a
    scheduled derivation step
  - `driver.go:369/371  s.sched.AttemptStep(...)` → steps the pipeline → produces attributes →
    `PendingSafeUpdateEvent` → `onPendingSafeUpdate`.

### consolidate vs build decision

`rollup/attributes/attributes.go`, `onPendingSafeUpdate`:
- `:139  if x.Unsafe.Number < x.PendingSafe.Number { reset }` — unsafe must not be behind pending-safe.
- inner (`~:185`): `if x.PendingSafe.Number < x.Unsafe.Number { consolidateNextSafeAttributes(...) }`
  `else { eq.emitter.Emit(BuildStartEvent) }` (`:191`).

So:
- `Unsafe > PendingSafe` → **consolidate** (an unsafe block already exists at that height → compare &
  promote; goes through the block executor). `consolidateNextSafeAttributes` also compares via
  `AttributesMatchBlock` (engine_consolidate.go) and only builds on mismatch.
- `Unsafe == PendingSafe` → **build** (no unsafe block ahead; derivation caught up to the unsafe tip)
  → `BuildStartEvent` → EL builds via the payload builder.

### Why derivation tends to win after a restart-behind

- altSync arm is throttled by `altSyncTicker` (**only every 2×block_time**) and additionally waits for a
  peer network round-trip before `unsafeHead` moves.
- derivation arm (`s.sched.NextStep()`) is ready as soon as there's work and **L1 data is already local**,
  so it steps fast and often.

Net: after a restart-behind, derivation usually catches `PendingSafe` up to the **stale** `unsafeHead`
before altSync backfills the gap → `PendingSafe == Unsafe` → **build path**. During normal following
(gossip keeps `unsafeHead` at the live tip, well ahead of pending-safe) the node stays on consolidate
and this path is rarely hit.

### Why this matters — the gasless build path

The build path (`BuildStartEvent`) runs the EL payload builder with `no_tx_pool=true` and the block's
full tx set (deposits + user txs) in the attributes. On flashblocks-enabled nodes that goes through
`FlashblocksBuilderCtx::execute_sequencer_transactions`, which historically used a raw `evm.transact`
(no `is_gasless`) → gasless (zero-priced, whitelisted) user txs were dropped at the base-fee check →
block diverged from canonical (missing txs), and op-node even promoted it to safe (no re-verification of
a derivation-built block against the attributes). See `gasless-fix.md`.

Takeaway: the build path is legitimate and cannot be fully avoided (altSync-slow / gap-present forces
derivation to build), so the correct fix is to make the build path itself gasless-correct — not to rely
on "gossip/altSync winning the race".
