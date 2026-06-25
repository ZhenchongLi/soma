# [cc] v0.6.3: wire runtime event store to opt-in disk_log persistence via app env

## Current state

`soma_sup:init/1` starts its `soma_event_store` child with a hardcoded
`{soma_event_store, start_link, []}` spec. That always calls `start_link/0`,
which is the in-memory store. #96 already taught `soma_event_store` to persist:
`start_link/1` with `#{log => Path}` opens a `halt` `disk_log` at `Path`, writes
every appended event to it, and replays the log on boot. But nothing in the
runtime ever calls `start_link/1`, so a deployed release still keeps all its
events in memory and loses them on restart.

The runtime app (`soma_runtime.app.src`) declares `{env, []}` — no app env keys
today. `soma_app:start/2` just calls `soma_sup:start_link/0`, so the supervisor's
`init/1` is the one place that decides how the store starts.

## Approach

`soma_sup:init/1` reads `application:get_env(soma_runtime, event_store_log,
undefined)` and builds the `soma_event_store` child spec from the result:

- a path `P` → `start => {soma_event_store, start_link, [#{log => P}]}` (persistent)
- `undefined` → `start => {soma_event_store, start_link, []}` (in-memory, the
  spec it has today, byte for byte)

The other three children — `soma_tool_registry`, `soma_session_sup`,
`soma_run_sup` — and the child order, the sup flags, and the `id` of every child
all stay exactly as they are. Only the `start` tuple of the first child changes,
and only when the env is set.

Default stays in-memory. Tests and dev set no env, so they keep getting
`start_link/0` and write no file. The decision lives in the supervisor's `init/1`
rather than in `soma_app:start/2` so that reading `which_children(soma_sup)` in a
test sees the real, configured child.

One thing to watch in the order tests: `supervisor:which_children/1` returns
children in the **reverse** of their start order. The existing
`test_sup_has_four_live_children` sidesteps this by only checking set membership,
not order. The two new order proofs must reverse `which_children`'s output (or
assert against the reversed expected list) so they actually pin start order, not
the order the supervisor happens to report.

A new CT suite drives all four runtime-wiring proofs because each one needs to
boot and stop the `soma_runtime` application with the env set or unset, and CT's
per-testcase setup/teardown is where that belongs. The suite sets
`application:set_env(soma_runtime, event_store_log, Path)` (or leaves it unset)
in `init_per_testcase`, boots the app, asserts, then stops the app and unsets the
env in `end_per_testcase` so no leak reaches another suite.

`docs/release.md` gets a short section on turning persistence on through the
`event_store_log` app env, with the `sys.config` snippet from the issue.

## Acceptance criteria → tests

All four runtime-wiring proofs go in a new suite
`apps/soma_runtime/test/soma_event_store_wiring_SUITE.erl`. The store-internals
proofs from #96 are not retouched.

### Criterion 1 — unset env boots an in-memory store, no file on disk
- Call chain: `application:ensure_all_started(soma_runtime)` → `soma_app:start/2`
  → `soma_sup:start_link/0` → `soma_sup:init/1` → child spec built from
  `get_env(.., event_store_log, undefined)` → `soma_event_store:start_link/0`
- Test entry: the CT case boots the app with no `event_store_log` env set, then
  reads the live `soma_event_store` child out of `which_children(soma_sup)`. It
  drives an `append/2` through that child and asserts no file appeared in a fresh
  temp dir it watches — the same on-disk check #96 used, but against the
  sup-owned store rather than a directly started one.
- Test: `test_unset_env_store_is_in_memory_writes_no_file` in
  `apps/soma_runtime/test/soma_event_store_wiring_SUITE.erl`

### Criterion 2 — env set to a path boots a persistent store, append lands on disk
- Call chain: `set_env(soma_runtime, event_store_log, Path)` →
  `application:ensure_all_started(soma_runtime)` → `soma_app:start/2` →
  `soma_sup:start_link/0` → `soma_sup:init/1` → child spec built from the path →
  `soma_event_store:start_link(#{log => Path})`
- Test entry: the CT case sets the env to a temp path before booting, boots the
  app, finds the `soma_event_store` child via `which_children(soma_sup)`, appends
  one event through it, and asserts a `disk_log` exists at that path holding the
  event. To read the term back it stops the app first so the log handle flushes,
  then opens its own short-lived `disk_log` at the path — the read-back-around-
  the-store technique #96 used.
- Test: `test_set_env_store_persists_append_to_log` in
  `apps/soma_runtime/test/soma_event_store_wiring_SUITE.erl`

### Criterion 3 — four children in order when env is unset
- Call chain: `application:ensure_all_started(soma_runtime)` →
  `soma_sup:start_link/0` → `soma_sup:init/1` (env unset)
- Test entry: the CT case boots the app with no env set and reads
  `which_children(soma_sup)`. It reverses that list to recover start order and
  asserts the ids are `[soma_event_store, soma_tool_registry, soma_session_sup,
  soma_run_sup]` with `soma_event_store` first. No layer is skipped; the test
  reads the supervisor's own child list.
- Test: `test_unset_env_boot_order` in
  `apps/soma_runtime/test/soma_event_store_wiring_SUITE.erl`

### Criterion 4 — same four children in the same order when env is set
- Call chain: `set_env(soma_runtime, event_store_log, Path)` →
  `application:ensure_all_started(soma_runtime)` → `soma_sup:start_link/0` →
  `soma_sup:init/1` (env set)
- Test entry: the CT case sets the env to a temp path, boots the app, and runs
  the same reversed-`which_children` order assertion as Criterion 3. This proves
  the persistent branch changes only the store's `start` tuple, not the child
  set or its order.
- Test: `test_set_env_boot_order` in
  `apps/soma_runtime/test/soma_event_store_wiring_SUITE.erl`

### Criterion 5 — docs/release.md documents enabling persistence via the env
- Call chain: none (direct source-file read)
- Test entry: the doc is the artifact. The proof is reading `docs/release.md` and
  confirming it has a section that names the `event_store_log` app env, explains
  it makes the store durable, and shows the `sys.config` snippet
  `{soma_runtime, [{event_store_log, "/var/lib/soma/events.log"}]}`. A reviewer
  checks this on the diff; if a string assertion is wanted it can read the file
  for `event_store_log` and the snippet, matching how #96's
  `test_usage_doc_documents_start_link_1_and_durability` checks doc prose.
- Test: doc review of `docs/release.md` (optionally
  `test_release_doc_documents_event_store_log` in the wiring suite, same
  read-the-file shape as #96's doc proofs)

### Criterion 6 — full suite green, every existing suite still in-memory
- Call chain: none (build/test-run assertion)
- Test entry: `rebar3 eunit && rebar3 ct`. The gate passing is the proof. No
  existing suite sets `event_store_log`, so every one keeps booting the in-memory
  store. The new wiring suite unsets the env in `end_per_testcase`, so its
  persistent case leaks no env into a later suite.
- Test: the relay merge gate (`rebar3 eunit && rebar3 ct`)

## Risks & trade-offs

- `which_children/1` reporting reverse start order is an easy thing to get wrong.
  If the order proofs assert against the raw `which_children` list they pass for
  the wrong reason. The design calls this out so the order tests reverse before
  asserting.
- The persistent CT case writes a real file under a temp dir and must clean it
  up, including stopping the app so the `disk_log` handle is released before the
  dir is removed. If teardown is sloppy a leftover log or a still-set env could
  taint the next suite. `end_per_testcase` stopping the app and unsetting the env
  is the guard.
- Reading the env inside `soma_sup:init/1` means the store mode is fixed at boot.
  Changing `event_store_log` after the runtime is up has no effect until a
  restart. That is the intended behaviour for a release config knob, not a
  limitation to work around here.
- Dialyzer: the only file this slice changes is `soma_sup.erl`, adding a
  `get_env` read and a child-spec branch — no new type surface. The pre-existing
  warnings in `soma_lfe_reader.erl` and `soma_tool_call.erl` are out of scope;
  the build runs `rebar3 dialyzer` and reports whether the count moved.
