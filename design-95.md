# v0.6.2: persistent event store via disk_log (opt-in path; survives restart)

## Current state

`soma_event_store` is a `gen_server` that keeps every event in one in-memory
list (`#state{events = [map()]}`). `append/2` normalizes the event and prepends
it; `all/1` reverses the list; `by_run/2`, `by_session/2`, `by_correlation/2`
filter that reversed list. The whole module is in
`apps/soma_event_store/src/soma_event_store.erl`. `init([])` builds an empty
state. `soma_sup` starts it with `start_link, []` (no args).

`normalize/1` is the only place an event is shaped: it fills `event_id` if
absent (`make_event_id/0`, a ref-based binary), fills `timestamp` if absent
(`erlang:system_time(nanosecond)`), and sets every missing mandatory key to
`undefined`. Callers read events back through the `by_*` queries and expect
emission order.

Restart the BEAM and the list is gone. Nothing is written to disk. v0.7 (resume)
needs a trail that outlives a restart, so this slice adds one — without changing
the query API or the normalization rules.

There is no `docs/contracts/v0.6-test-contract.md` yet. The v0.6.1 trace proofs
live in `apps/soma_event_store/test/soma_trace_tests.erl` and are not recorded
in any contract file.

## Approach

Add an opt-in persistent path behind the existing API. Two store modes share one
module.

**Two start functions, one of them new.**

- `start_link/0` stays exactly as it is — in-memory, no file, no opts. `soma_sup`
  and every existing caller and test suite keep working unchanged. This is the
  default and stays the default; pointing a real release at a persistent path is
  out of scope.
- `start_link/1` is new. It takes `#{log => Path}` and opens a `halt`-type
  `disk_log` at `Path`. A store opened this way persists.

**The state carries the log handle, or doesn't.** The state record grows one
field that names the log when persistent and is `undefined` when in-memory. The
in-memory index (`events`) stays as the read path in both modes. So queries never
change — they always read the index. The only behavioural fork is in `init/1`
and `append/2`.

**append on a persistent store does two writes.** It normalizes once, writes the
normalized event to the `disk_log` (`disk_log:log/2`), then prepends it to the
index — same index update as today. The normalized form written to disk is the
same map the index holds, so what you read back from disk equals what a query
returns. Normalize stays the single shaping point; the log never sees a raw
event.

**Boot replays the log to rebuild the index.** A persistent `init/1` opens the
log and reads its terms in order (`disk_log:chunk/2` loop), prepending each into
the index so the index ends up in the same internal order an equivalent sequence
of `append/2` calls would produce. `all/1` then returns them in append order
just like the in-memory case. The log is the source of truth; the index is a
rebuildable cache — that is the principle v0.7 builds on.

**A truncated tail is skipped, not a crash.** An unclean shutdown can leave a
half-written term at the end of the log. `disk_log:chunk/2` reports this as a
`{error, {corrupt_log_file, _}}` / bad-bytes return rather than raising. The
replay loop treats a corrupt tail as end-of-log: it keeps every intact term read
so far and finishes `init/1` cleanly. So a damaged tail costs you the last
partial event, not the boot.

**Docs and contract.** `docs/usage.md` gets `start_link/1` and the
restart-durability behaviour under the events section. A new
`docs/contracts/v0.6-test-contract.md` maps each persistence proof to its suite
and case. Per the issue's open question, folding the v0.6.1 trace proofs into the
same file is allowed but not required; recording only this slice's persistence
proofs satisfies the criterion, and that is what this design plans — the trace
proofs already have their own home in `soma_trace_tests` and folding them risks
churn outside this slice's scope.

**Where the tests live.** All persistence proofs go in
`apps/soma_event_store/test/soma_event_store_persist_tests.erl`, a new EUnit
module beside the existing `soma_event_store_tests`. A persistent store is a
plain `gen_server` started with a temp path, so it needs no supervision tree —
EUnit is the right level, matching how `soma_event_store_tests` already drives
the in-memory store directly. Temp paths come from a per-case fixture so cases
don't collide. The contract-doc proof goes in the same module as a file-read
assertion.

## Acceptance criteria → tests

### Criterion 1 — start_link/0 writes no file, queries unchanged
- Call chain: `soma_event_store:start_link/0` → `gen_server:start_link` →
  `init([])` (in-memory branch); then `append/2` / `all/1` / `by_run/2` /
  `by_session/2` / `by_correlation/2` → the same `handle_call` clauses as today
- Test entry: the public API (`start_link/0` then the `by_*` calls), the real
  caller path
- Test: `test_in_memory_store_writes_no_file_and_queries_unchanged` in
  `apps/soma_event_store/test/soma_event_store_persist_tests.erl`

### Criterion 2 — start_link/1 with a path creates a disk_log file after first append
- Call chain: `soma_event_store:start_link/1` with `#{log => Path}` →
  `init(Opts)` (persistent branch, opens the log) → `append/2` →
  `handle_call({append, _}, ...)` → `disk_log:log/2`
- Test entry: `start_link/1` then `append/2`, the real caller path; the file
  check reads the filesystem at `Path`
- Test: `test_persistent_store_creates_file_after_first_append` in
  `apps/soma_event_store/test/soma_event_store_persist_tests.erl`

### Criterion 3 — an appended event reads back from disk equal to its normalized form
- Call chain: `start_link/1` → `append/2` → `disk_log:log/2` for the write
  side; the test reads the term back with its own short `disk_log:open` +
  `disk_log:chunk` against the same `Path`
- Test entry: `append/2` for the write; a direct `disk_log` read for the
  read-back. The read-back goes around the store on purpose — the criterion is
  about what physically sits in the log, so the test opens the log itself
  instead of trusting a store query
- Test: `test_appended_event_reads_back_from_log_as_normalized` in
  `apps/soma_event_store/test/soma_event_store_persist_tests.erl`

### Criterion 4 — restart recovers events into all/1
- Call chain: `start_link/1` at `Path` → several `append/2` → stop the store →
  `start_link/1` again at the same `Path` → `init(Opts)` replays the log into
  the index → `all/1`
- Test entry: the public API across two store lifetimes (append, stop,
  re-start, `all/1`), the real caller path
- Test: `test_restart_recovers_events_into_all` in
  `apps/soma_event_store/test/soma_event_store_persist_tests.erl`

### Criterion 5 — by_run/2 after restart returns exactly that run's events
- Call chain: same two-lifetime path as criterion 4, ending in `by_run/2`
  against the rebuilt index
- Test entry: the public API after restart (`by_run/2`), the real caller path
- Test: `test_by_run_after_restart_filters_to_one_run` in
  `apps/soma_event_store/test/soma_event_store_persist_tests.erl`

### Criterion 6 — by_correlation/2 after restart returns the full chain
- Call chain: same two-lifetime path, ending in `by_correlation/2` against the
  rebuilt index
- Test entry: the public API after restart (`by_correlation/2`), the real
  caller path
- Test: `test_by_correlation_after_restart_returns_full_chain` in
  `apps/soma_event_store/test/soma_event_store_persist_tests.erl`

### Criterion 7 — a truncated or garbage tail boots without crashing and serves intact events
- Call chain: write intact events through a persistent store and stop it, then
  the test corrupts the log file's tail directly (append garbage bytes / truncate
  mid-term at the filesystem level), then `start_link/1` at that `Path` →
  `init(Opts)` replay hits the corrupt tail and stops cleanly → `all/1`
- Test entry: `start_link/1` then `all/1`, the real caller path; the corruption
  is set up by writing to the file off-chain, because that is the only way to
  produce the damaged-tail condition the criterion names
- Test: `test_truncated_tail_boots_and_serves_intact_events` in
  `apps/soma_event_store/test/soma_event_store_persist_tests.erl`

### Criterion 8 — usage.md documents start_link/1 and restart durability
- Call chain: none (direct source-file read)
- Test entry: a file-read assertion over `docs/usage.md`, off any call chain
  because the criterion is about documentation prose
- Test: `test_usage_doc_documents_start_link_1_and_durability` in
  `apps/soma_event_store/test/soma_event_store_persist_tests.erl`

### Criterion 9 — v0.6-test-contract.md exists and maps each persistence proof
- Call chain: none (direct source-file read)
- Test entry: a file-read assertion over
  `docs/contracts/v0.6-test-contract.md`, off any call chain because the
  criterion is about the contract document
- Test: `test_v0_6_contract_doc_maps_each_persistence_proof` in
  `apps/soma_event_store/test/soma_event_store_persist_tests.erl`

### Criterion 10 — rebar3 eunit && rebar3 ct is green
- Call chain: none (whole-gate check)
- Test entry: the merge gate, not a single case
- Test: the full suite — `rebar3 eunit && rebar3 ct`. Not a single named case;
  it is the green-gate criterion every slice carries

## Risks & trade-offs

- **The index still holds every event in memory.** Persistence does not bound
  memory — a long-lived persistent store grows the in-memory index just like the
  in-memory store does. Bounding the index is node F and stays out of scope. So
  this slice buys durability, not a smaller heap.
- **The halt log grows unbounded.** No rotation, no compaction. A busy
  persistent store's file grows forever until a later rotation topic addresses
  it. Acceptable now because the default store stays in-memory and only tests opt
  into a path.
- **Replay cost is linear in the log.** Boot reads the whole log to rebuild the
  index, so a large log means a slow `init/1`. Fine at this slice's sizes;
  worth flagging for when resume puts real volume through it.
- **The corrupt-tail test depends on disk_log's chunk error shape.** The replay
  loop keys off how `disk_log:chunk/2` reports a bad tail. If that return shape
  is read wrong, a corrupt tail could crash boot instead of being skipped — which
  is exactly why criterion 7 sets up a real damaged file rather than a mocked
  error.
- **Two modes in one module.** `init/1` and `append/2` now branch on
  persistent-vs-memory. The fork is small and the in-memory branch is the
  untouched old code, but it is two code paths to keep honest. The alternative —
  a separate backend module — is more structure than this one fork warrants.
