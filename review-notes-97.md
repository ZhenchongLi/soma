### Claude

## Verdict
approve

## Real issues

None.

## Questions

None.

## Nits

- `test_unset_env_store_is_in_memory_writes_no_file` watches a fresh `/tmp` dir
  the store never knows about. When the env is unset the store gets no path at
  all, so "no file appeared in TmpDir" cannot fail regardless of store behavior —
  the assertion is structurally trivial. The criterion's real intent (no disk
  log) is still proven by contrast with the persistent case, and the memory-serve
  assertion (`by_run` returns `[a1]`) carries weight. Leave it; the wiring is
  what matters and it is correct.
- `read_one_log_term/1` accepts `{repaired, _, {badbytes, 0}}` on reopen. Fine
  for reading one halt-log term, but if a future change writes more than one term
  before stop, a non-zero `badbytes` would crash the case rather than report.
  Out of scope here.

## Functional evidence
- Criterion 1 — pass: `event_store_start/0` returns `{soma_event_store, start_link, []}` when `get_env(soma_runtime, event_store_log, undefined)` is `undefined` (`soma_sup.erl:38`); `test_unset_env_store_is_in_memory_writes_no_file` boots the app with no env, resolves the `soma_event_store` worker out of `which_children(soma_sup)`, appends an event, reads it back from memory (`[a1]`), and asserts the temp dir listing is unchanged. Green in the wiring suite.
- Criterion 2 — pass: `event_store_start/0` returns `{soma_event_store, start_link, [#{log => Path}]}` when the env holds a path (`soma_sup.erl:39`), matching `soma_event_store:start_link/1`'s `#{log := Path}` head (`soma_event_store.erl:20`); `test_set_env_store_persists_append_to_log` sets the env to a temp path before boot, appends through the sup-owned store, stops the app to flush, asserts `filelib:is_regular(Path)`, opens its own disk_log at the path, and asserts the read-back term equals the store's normalized event. Green.
- Criterion 3 — pass: `test_unset_env_boot_order` reads `which_children(soma_sup)`, reverses it to recover start order, asserts `[soma_event_store, soma_tool_registry, soma_session_sup, soma_run_sup]`. The reversal is correct — `supervisor:which_children/1` reports reverse start order. Green.
- Criterion 4 — pass: `test_set_env_boot_order` runs the same reversed-`which_children` assertion with the env set to a path, proving the persistent branch changes only the store child's `start` tuple, not the child set or order. Green.
- Criterion 5 — pass: `docs/release.md` adds an "Enabling event persistence" section naming `event_store_log`, stating it makes the store **durable**, and showing the verbatim snippet `{soma_runtime, [{event_store_log, "/var/lib/soma/events.log"}]}`. `test_release_doc_documents_event_store_log` asserts all three strings present and the env mention precedes the snippet.
- Criterion 6 — pass: `rebar3 eunit` → 154 tests, 0 failures; `rebar3 ct` → All 198 tests passed. No suite other than `soma_event_store_wiring_SUITE` references `event_store_log` (grep over `apps/*/test`, `apps/*/src`), so every existing suite still boots the in-memory store.
